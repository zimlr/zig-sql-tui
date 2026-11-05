#define _POSIX_C_SOURCE 200809L
#include "sqlite3.h"
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int authorizer(void *context, int action, const char *a, const char *b,
                      const char *db, const char *origin) {
    (void)a; (void)b; (void)origin;
    int writable = context != NULL;
    switch (action) {
        case SQLITE_SELECT: case SQLITE_READ: case SQLITE_FUNCTION:
        case SQLITE_RECURSIVE:
            return SQLITE_OK;
        case SQLITE_INSERT: case SQLITE_UPDATE: case SQLITE_DELETE:
        case SQLITE_CREATE_TABLE: case SQLITE_CREATE_INDEX: case SQLITE_CREATE_VIEW:
        case SQLITE_CREATE_TRIGGER: case SQLITE_DROP_TABLE: case SQLITE_DROP_INDEX:
        case SQLITE_DROP_VIEW: case SQLITE_DROP_TRIGGER: case SQLITE_ALTER_TABLE:
        case SQLITE_REINDEX: case SQLITE_ANALYZE:
            return writable && db && !strcmp(db, "main") ? SQLITE_OK : SQLITE_DENY;
        default:
            return SQLITE_DENY;
    }
}

int app_set_readonly_authorizer(sqlite3 *db) {
    return sqlite3_set_authorizer(db, authorizer, NULL);
}
int app_set_write_authorizer(sqlite3 *db) {
    return sqlite3_set_authorizer(db, authorizer, db);
}

static int prepare_tables(sqlite3 *db, sqlite3_int64 offset, int scan, sqlite3_stmt **stmt) {
    int rc = sqlite3_prepare_v2(db,
        "SELECT name FROM sqlite_schema WHERE type='table' AND substr(name,1,7) COLLATE NOCASE != 'sqlite_' ORDER BY name LIMIT ?2 OFFSET ?1",
        -1, stmt, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_bind_int64(*stmt, 1, offset);
    if (rc == SQLITE_OK) rc = sqlite3_bind_int(*stmt, 2, scan ? -1 : 129);
    if (rc != SQLITE_OK && *stmt) { sqlite3_finalize(*stmt); *stmt = NULL; }
    return rc;
}
int app_prepare_tables(sqlite3 *db, sqlite3_int64 offset, sqlite3_stmt **stmt) {
    return prepare_tables(db, offset, 0, stmt);
}
int app_prepare_search_tables(sqlite3 *db, sqlite3_stmt **stmt) {
    return prepare_tables(db, 0, 1, stmt);
}
static int prepare_rows(sqlite3 *db, const char *table, sqlite3_int64 offset, int scan, sqlite3_stmt **stmt) {
    char *sql = sqlite3_mprintf("SELECT * FROM \"%w\" LIMIT ?2 OFFSET ?1", table);
    if (!sql) return SQLITE_NOMEM;
    int rc = sqlite3_prepare_v2(db, sql, -1, stmt, NULL);
    sqlite3_free(sql);
    if (rc == SQLITE_OK) rc = sqlite3_bind_int64(*stmt, 1, offset);
    if (rc == SQLITE_OK) rc = sqlite3_bind_int(*stmt, 2, scan ? -1 : 501);
    if (rc != SQLITE_OK && *stmt) { sqlite3_finalize(*stmt); *stmt = NULL; }
    return rc;
}
int app_prepare_rows(sqlite3 *db, const char *table, sqlite3_int64 offset, sqlite3_stmt **stmt) {
    return prepare_rows(db, table, offset, 0, stmt);
}

/* Only ordinary rowid tables support cell updates. Metadata queries are
 * internal and run before preparing user-facing statements. */
static int rowid_alias(sqlite3 *db, const char *table, const char **out, int *without_rowid, int *ordinary_table) {
    static const char *aliases[] = { "_rowid_", "rowid", "oid" };
    sqlite3_stmt *stmt = NULL;
    int ordinary = 0, rc;
    *out = NULL;
    *without_rowid = 0;
    *ordinary_table = 0;
    if (sqlite3_set_authorizer(db, NULL, NULL) != SQLITE_OK) return SQLITE_ERROR;
    rc = sqlite3_prepare_v2(db, "PRAGMA main.table_list", -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *schema = sqlite3_column_text(stmt, 0);
            const unsigned char *name = sqlite3_column_text(stmt, 1);
            const unsigned char *type = sqlite3_column_text(stmt, 2);
            if (schema && !strcmp((const char *)schema, "main") && name && type && !sqlite3_stricmp((const char *)name, table) &&
                !strcmp((const char *)type, "table")) {
                *ordinary_table = 1;
                if (sqlite3_column_int(stmt, 4)) *without_rowid = 1;
                else ordinary = 1;
                break;
            }
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    if (app_set_write_authorizer(db) != SQLITE_OK) return SQLITE_ERROR;
    if (!ordinary) return SQLITE_OK;
    char *sql = sqlite3_mprintf("SELECT * FROM \"%w\" LIMIT 0", table);
    if (!sql) return SQLITE_NOMEM;
    stmt = NULL;
    rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    sqlite3_free(sql);
    if (rc != SQLITE_OK || !stmt) { if (stmt) sqlite3_finalize(stmt); return rc; }
    int used[3] = {0, 0, 0};
    for (int i = 0; i < sqlite3_column_count(stmt); ++i) {
        const char *name = sqlite3_column_name(stmt, i);
        if (!name) { sqlite3_finalize(stmt); return SQLITE_NOMEM; }
        for (int j = 0; j < 3; ++j) if (!sqlite3_stricmp(name, aliases[j])) used[j] = 1;
    }
    sqlite3_finalize(stmt);
    for (int i = 0; i < 3; ++i) if (!used[i]) { *out = aliases[i]; break; }
    return SQLITE_OK;
}
/* Order by every primary-key component with binary collation. This gives a
 * unique, repeatable row order even when the declared key uses another collation. */
struct primary_key { int count; char *names[2000]; };
static void free_primary_key(struct primary_key *key) {
    for (int i = 0; i < key->count; ++i) sqlite3_free(key->names[i]);
    key->count = 0;
}
static int get_primary_key(sqlite3 *db, const char *table, struct primary_key *key, int require_nonnull) {
    sqlite3_stmt *stmt = NULL;
    char *sql = NULL;
    int rc = sqlite3_set_authorizer(db, NULL, NULL);
    key->count = 0;
    if (rc != SQLITE_OK) return rc;
    sql = sqlite3_mprintf("PRAGMA main.table_xinfo(\"%w\")", table);
    if (!sql) rc = SQLITE_NOMEM;
    if (rc == SQLITE_OK) rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    sqlite3_free(sql);
    if (rc == SQLITE_OK) {
        while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
            if (sqlite3_column_int(stmt, 5) == 0) continue;
            if (require_nonnull && !sqlite3_column_int(stmt, 3)) { rc = SQLITE_CONSTRAINT; break; }
            const unsigned char *name = sqlite3_column_text(stmt, 1);
            if (!name || key->count == 2000) { rc = SQLITE_ERROR; break; }
            char *copy = sqlite3_mprintf("%s", name);
            if (!copy) { rc = SQLITE_NOMEM; break; }
            key->names[key->count++] = copy;
        }
        if (rc == SQLITE_DONE) rc = SQLITE_OK;
    }
    if (stmt) sqlite3_finalize(stmt);
    if (app_set_write_authorizer(db) != SQLITE_OK && rc == SQLITE_OK) rc = SQLITE_ERROR;
    if (rc == SQLITE_OK && !key->count) rc = SQLITE_ERROR;
    if (rc != SQLITE_OK) free_primary_key(key);
    return rc;
}
static int prepare_key_rows(sqlite3 *db, const char *table, sqlite3_int64 offset,
                            const struct primary_key *key, int scan, sqlite3_stmt **stmt) {
    sqlite3_str *builder = sqlite3_str_new(db);
    sqlite3_str_appendf(builder, "SELECT * FROM main.\"%w\" ORDER BY ", table);
    for (int i = 0; i < key->count; ++i)
        sqlite3_str_appendf(builder, "%s\"%w\" COLLATE BINARY", i ? "," : "", key->names[i]);
    sqlite3_str_appendall(builder, " LIMIT ?2 OFFSET ?1");
    char *sql = sqlite3_str_finish(builder);
    if (!sql) return SQLITE_NOMEM;
    int rc = sqlite3_prepare_v2(db, sql, -1, stmt, NULL);
    sqlite3_free(sql);
    if (rc == SQLITE_OK) rc = sqlite3_bind_int64(*stmt, 1, offset);
    if (rc == SQLITE_OK) rc = sqlite3_bind_int(*stmt, 2, scan ? -1 : 501);
    if (rc != SQLITE_OK && *stmt) { sqlite3_finalize(*stmt); *stmt = NULL; }
    return rc;
}
static int prepare_editable_rows(sqlite3 *db, const char *table, sqlite3_int64 offset, int scan, sqlite3_stmt **stmt, int *has_rowid) {
    const char *alias = NULL;
    *stmt = NULL;
    *has_rowid = 0;
    int without_rowid = 0, ordinary_table = 0;
    int rc = rowid_alias(db, table, &alias, &without_rowid, &ordinary_table);
    if (rc != SQLITE_OK) return rc;
    if (without_rowid || (ordinary_table && !alias)) {
        struct primary_key key;
        rc = get_primary_key(db, table, &key, !without_rowid);
        if (rc == SQLITE_CONSTRAINT || rc == SQLITE_ERROR) return prepare_rows(db, table, offset, scan, stmt);
        if (rc != SQLITE_OK) return rc;
        if (key.count > 900) {
            free_primary_key(&key);
            return prepare_rows(db, table, offset, scan, stmt);
        }
        rc = prepare_key_rows(db, table, offset, &key, scan, stmt);
        free_primary_key(&key);
        if (rc == SQLITE_OK && *stmt) {
            *has_rowid = 2;
            return SQLITE_OK;
        }
        if (rc == SQLITE_TOOBIG || rc == SQLITE_ERROR) return prepare_rows(db, table, offset, scan, stmt);
        return rc;
    }
    if (alias) {
        char *sql = sqlite3_mprintf("SELECT \"%w\", * FROM \"%w\" LIMIT ?2 OFFSET ?1", alias, table);
        if (!sql) return SQLITE_NOMEM;
        rc = sqlite3_prepare_v2(db, sql, -1, stmt, NULL);
        sqlite3_free(sql);
        if (rc == SQLITE_OK && *stmt) rc = sqlite3_bind_int64(*stmt, 1, offset);
        if (rc == SQLITE_OK && *stmt) rc = sqlite3_bind_int(*stmt, 2, scan ? -1 : 501);
        if (rc == SQLITE_OK && *stmt) { *has_rowid = 1; return SQLITE_OK; }
        if (*stmt) sqlite3_finalize(*stmt);
        *stmt = NULL;
    }
    return prepare_rows(db, table, offset, scan, stmt);
}
int app_prepare_editable_rows(sqlite3 *db, const char *table, sqlite3_int64 offset, sqlite3_stmt **stmt, int *has_rowid) {
    return prepare_editable_rows(db, table, offset, 0, stmt, has_rowid);
}
int app_prepare_search_rows(sqlite3 *db, const char *table, int writable, sqlite3_stmt **stmt, int *has_rowid) {
    *has_rowid = 0;
    return writable ? prepare_editable_rows(db, table, 0, 1, stmt, has_rowid)
                    : prepare_rows(db, table, 0, 1, stmt);
}
int app_data_version(sqlite3 *db, int writable, int *version) {
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_set_authorizer(db, NULL, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_prepare_v2(db, "PRAGMA main.data_version", -1, &stmt, NULL);
    if (rc == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) *version = sqlite3_column_int(stmt, 0);
    else if (rc == SQLITE_OK) rc = SQLITE_ERROR;
    if (stmt) sqlite3_finalize(stmt);
    int restore = writable ? app_set_write_authorizer(db) : app_set_readonly_authorizer(db);
    return rc != SQLITE_OK ? rc : restore;
}

/* Only one read-only statement may reach execution. The authorizer and the
 * file-denying VFS remain active independently of this check. */
int app_prepare_statement(sqlite3 *db, const char *sql, sqlite3_stmt **stmt, int allow_write, int *is_write) {
    const char *tail = NULL;
    *stmt = NULL;
    if (is_write) *is_write = 0;
    int rc = sqlite3_prepare_v2(db, sql, -1, stmt, &tail);
    if (rc != SQLITE_OK) {
        if (*stmt) sqlite3_finalize(*stmt);
        *stmt = NULL;
        return rc;
    }
    if (!*stmt) return SQLITE_MISUSE;
    for (;;) {
        while (*tail == ' ' || *tail == '\t' || *tail == '\r' || *tail == '\n') ++tail;
        if (tail[0] == '-' && tail[1] == '-') {
            tail += 2;
            while (*tail && *tail != '\n') ++tail;
        } else if (tail[0] == '/' && tail[1] == '*') {
            tail += 2;
            while (*tail && !(tail[0] == '*' && tail[1] == '/')) ++tail;
            if (*tail) tail += 2;
        } else break;
    }
    int mutating = !sqlite3_stmt_readonly(*stmt);
    if (*tail || (mutating && !allow_write)) {
        sqlite3_finalize(*stmt);
        *stmt = NULL;
        return SQLITE_AUTH;
    }
    if (is_write) *is_write = mutating;
    return SQLITE_OK;
}
int app_prepare_query(sqlite3 *db, const char *sql, sqlite3_stmt **stmt) {
    return app_prepare_statement(db, sql, stmt, 0, NULL);
}

static int progress(void *remaining) {
    int *budget = remaining;
    return --*budget <= 0;
}
static int query_budget;
static void query_begin(sqlite3 *db, int budget) {
    query_budget = budget;
    sqlite3_progress_handler(db, 1000, progress, &query_budget);
}
void app_query_begin(sqlite3 *db) {
    query_begin(db, 2000);
}
/* A full scan or a distant query page can require more work than a single
 * query page. The larger navigation budget remains finite and independent
 * of the limits used for initial user queries and writes. */
void app_navigation_begin(sqlite3 *db) {
    query_begin(db, 20000);
}
void app_query_end(sqlite3 *db) {
    sqlite3_progress_handler(db, 0, NULL, NULL);
}

static int internal_transaction(sqlite3 *db, const char *sql) {
    int rc = sqlite3_set_authorizer(db, NULL, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_exec(db, sql, NULL, NULL, NULL);
    int restore = app_set_write_authorizer(db);
    return rc != SQLITE_OK ? rc : restore;
}
int app_execute_write(sqlite3 *db, const char *sql, char *error, size_t cap) {
    sqlite3_stmt *stmt = NULL;
    int mutating = 0;
    int rc = internal_transaction(db, "BEGIN IMMEDIATE");
    if (rc != SQLITE_OK) goto failed;
    rc = app_prepare_statement(db, sql, &stmt, 1, &mutating);
    if (rc != SQLITE_OK || !stmt || !mutating) {
        if (rc == SQLITE_OK) rc = SQLITE_AUTH;
        goto rollback;
    }
    app_query_begin(db);
    do { rc = sqlite3_step(stmt); } while (rc == SQLITE_ROW);
    app_query_end(db);
    if (rc != SQLITE_DONE) goto rollback;
    rc = sqlite3_finalize(stmt);
    stmt = NULL;
    if (rc != SQLITE_OK) goto rollback;
    rc = internal_transaction(db, "COMMIT");
    if (rc != SQLITE_OK) goto rollback;
    return 1;
rollback:
    if (cap) snprintf(error, cap, "%s", sqlite3_errmsg(db));
    if (stmt) sqlite3_finalize(stmt);
    (void)internal_transaction(db, "ROLLBACK");
    return 0;
failed:
    if (cap) snprintf(error, cap, "%s", sqlite3_errmsg(db));
    return 0;
}

static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

int app_update_cell(sqlite3 *db, const char *table, const char *column, sqlite3_int64 rowid,
                    int key_kind, sqlite3_int64 page_offset, int page_row,
                    const char *value, int value_type, int expected_version, char *error, size_t cap) {
    sqlite3_stmt *stmt = NULL, *row = NULL;
    struct primary_key key = { .count = 0 };
    char *sql = NULL;
    const char *alias = NULL;
    int without_rowid = 0, ordinary_table = 0;
    int version = 0, rc = internal_transaction(db, "BEGIN IMMEDIATE");
    if (rc != SQLITE_OK) goto failed;
    rc = app_data_version(db, 1, &version);
    if (rc != SQLITE_OK) goto rollback;
    if (version != expected_version) {
        if (cap) snprintf(error, cap, "Database changed. Reload before editing");
        goto rollback_message;
    }
    rc = rowid_alias(db, table, &alias, &without_rowid, &ordinary_table);
    if (rc != SQLITE_OK || (key_kind == 1 && !alias) || (key_kind == 2 && !ordinary_table) ||
        (key_kind != 1 && key_kind != 2)) {
        if (cap) snprintf(error, cap, "Table cannot be edited with the selected key");
        goto rollback_message;
    }
    if (key_kind == 1) {
        sql = sqlite3_mprintf("UPDATE main.\"%w\" SET \"%w\"=?1 WHERE \"%w\"=?2", table, column, alias);
    } else {
        if (page_offset < 0 || page_row < 0 || page_row >= 500) {
            if (cap) snprintf(error, cap, "Invalid selected row");
            goto rollback_message;
        }
        rc = get_primary_key(db, table, &key, !without_rowid);
        if (rc != SQLITE_OK) goto rollback;
        rc = prepare_key_rows(db, table, page_offset, &key, 0, &row);
        if (rc != SQLITE_OK) goto rollback;
        app_query_begin(db);
        for (int i = 0; i <= page_row; ++i) {
            rc = sqlite3_step(row);
            if (rc != SQLITE_ROW) break;
        }
        app_query_end(db);
        if (rc != SQLITE_ROW) {
            if (rc == SQLITE_DONE) {
                if (cap) snprintf(error, cap, "Selected row no longer exists");
                goto rollback_message;
            }
            goto rollback;
        }
        sqlite3_str *builder = sqlite3_str_new(db);
        sqlite3_str_appendf(builder, "UPDATE main.\"%w\" SET \"%w\"=?1 WHERE ", table, column);
        for (int i = 0; i < key.count; ++i)
            sqlite3_str_appendf(builder, "%s\"%w\" COLLATE BINARY IS ?%d", i ? " AND " : "", key.names[i], i + 2);
        sql = sqlite3_str_finish(builder);
    }
    if (!sql) { rc = SQLITE_NOMEM; goto rollback; }
    rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    sqlite3_free(sql); sql = NULL;
    if (rc != SQLITE_OK || !stmt) goto rollback;
    if (key_kind == 2) {
        for (int i = 0; i < key.count; ++i) {
            int col = -1;
            for (int j = 0; j < sqlite3_column_count(row); ++j) {
                const char *name = sqlite3_column_name(row, j);
                if (name && !strcmp(name, key.names[i])) { col = j; break; }
            }
            if (col < 0) { rc = SQLITE_ERROR; goto rollback; }
            rc = sqlite3_bind_value(stmt, i + 2, sqlite3_column_value(row, col));
            if (rc != SQLITE_OK) goto rollback;
        }
        sqlite3_finalize(row); row = NULL;
        free_primary_key(&key);
    }
    if (value_type == SQLITE_INTEGER) {
        char *end = NULL;
        errno = 0;
        long long number = strtoll(value, &end, 10);
        if (errno == ERANGE || !*value || *value == ' ' || *value == '\t' || end == value || *end) {
            if (cap) snprintf(error, cap, "Enter a valid 64-bit integer");
            goto rollback_message;
        }
        rc = sqlite3_bind_int64(stmt, 1, (sqlite3_int64)number);
    } else if (value_type == SQLITE_FLOAT) {
        char *end = NULL;
        errno = 0;
        double number = strtod(value, &end);
        if (errno == ERANGE || !*value || *value == ' ' || *value == '\t' || end == value || *end || !isfinite(number)) {
            if (cap) snprintf(error, cap, "Enter a finite floating-point number");
            goto rollback_message;
        }
        rc = sqlite3_bind_double(stmt, 1, number);
    } else if (value_type == SQLITE_TEXT) {
        rc = sqlite3_bind_text(stmt, 1, value, -1, SQLITE_TRANSIENT);
    } else if (value_type == SQLITE_BLOB) {
        unsigned char bytes[2048];
        size_t len = strlen(value);
        if (len > sizeof(bytes) * 2 || len % 2) {
            if (cap) snprintf(error, cap, "Enter an even number of hexadecimal digits");
            goto rollback_message;
        }
        for (size_t i = 0; i < len; i += 2) {
            int hi = hex_digit((unsigned char)value[i]);
            int lo = hex_digit((unsigned char)value[i + 1]);
            if (hi < 0 || lo < 0) {
                if (cap) snprintf(error, cap, "Enter an even number of hexadecimal digits");
                goto rollback_message;
            }
            bytes[i / 2] = (unsigned char)((hi << 4) | lo);
        }
        rc = sqlite3_bind_blob(stmt, 1, bytes, (int)(len / 2), SQLITE_TRANSIENT);
    } else if (value_type == SQLITE_NULL) {
        rc = sqlite3_bind_null(stmt, 1);
    } else {
        if (cap) snprintf(error, cap, "Unsupported cell type");
        goto rollback_message;
    }
    if (rc == SQLITE_OK && key_kind == 1) rc = sqlite3_bind_int64(stmt, 2, rowid);
    if (rc != SQLITE_OK) goto rollback;
    app_query_begin(db);
    rc = sqlite3_step(stmt);
    app_query_end(db);
    if (rc != SQLITE_DONE || sqlite3_changes(db) != 1) {
        if (rc == SQLITE_DONE) {
            if (cap) snprintf(error, cap, "Selected row no longer exists");
            goto rollback_message;
        }
        goto rollback;
    }
    rc = sqlite3_finalize(stmt); stmt = NULL;
    if (rc != SQLITE_OK) goto rollback;
    rc = internal_transaction(db, "COMMIT");
    if (rc == SQLITE_OK) return 1;
rollback:
    if (cap) snprintf(error, cap, "%s", sqlite3_errmsg(db));
rollback_message:
    if (sql) sqlite3_free(sql);
    if (stmt) sqlite3_finalize(stmt);
    if (row) sqlite3_finalize(row);
    free_primary_key(&key);
    (void)internal_transaction(db, "ROLLBACK");
    return 0;
failed:
    if (cap) snprintf(error, cap, "%s", sqlite3_errmsg(db));
    return 0;
}

#include <signal.h>
#include <sys/ioctl.h>
#include <termios.h>
static struct termios original_termios;
static volatile sig_atomic_t resized, interrupted;
static int terminal_active;
static void on_resize(int sig) { (void)sig; resized = 1; }
static void on_interrupt(int sig) { (void)sig; interrupted = 1; }
int app_terminal_enter(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) || tcgetattr(STDIN_FILENO, &original_termios)) return 0;
    struct termios raw = original_termios;
    raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 1;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)) return 0;
    terminal_active = 1;
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_handler = on_resize;
    sigaction(SIGWINCH, &action, NULL);
    action.sa_handler = on_interrupt;
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    return 1;
}
void app_terminal_leave(void) {
    if (terminal_active) tcsetattr(STDIN_FILENO, TCSAFLUSH, &original_termios);
    terminal_active = 0;
}
int app_terminal_read(void) {
    unsigned char c;
    if (interrupted) return -2;
    if (resized) { resized = 0; return -1; }
    ssize_t n = read(STDIN_FILENO, &c, 1);
    if (n == 1) return c;
    if (n == 0) return -3;
    if (errno == EINTR) {
        if (interrupted) return -2;
        resized = 0;
        return -1;
    }
    return -2;
}
void app_terminal_size(unsigned short *columns, unsigned short *rows) {
    struct winsize size = {0};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) || !size.ws_col || !size.ws_row) {
        *columns = 0; *rows = 0;
    } else {
        *columns = size.ws_col; *rows = size.ws_row;
    }
}
