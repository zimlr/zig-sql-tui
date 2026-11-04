#define _POSIX_C_SOURCE 200809L
#include "sqlite3.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* The snapshot VFS has no filesystem implementation. Rollback-mode bytes are
 * read explicitly into a bounded, read-only in-memory database. */
static int deny_open(sqlite3_vfs *v, sqlite3_filename n, sqlite3_file *f, int flags, int *out) {
    (void)v; (void)n; (void)f; (void)flags; (void)out;
    return SQLITE_CANTOPEN;
}
static int deny_delete(sqlite3_vfs *v, const char *n, int sync) {
    (void)v; (void)n; (void)sync;
    return SQLITE_IOERR_DELETE;
}
static int deny_access(sqlite3_vfs *v, const char *n, int flags, int *out) {
    (void)v; (void)n; (void)flags; (void)out;
    return SQLITE_IOERR_ACCESS;
}
static int deny_path(sqlite3_vfs *v, const char *n, int len, char *out) {
    (void)v; (void)n; (void)len; (void)out;
    return SQLITE_CANTOPEN;
}
static int randomness(sqlite3_vfs *v, int count, char *out) {
    (void)v;
    int done = 0;
    while (done < count) {
        ssize_t n = getrandom(out + done, (size_t)(count - done), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (int)n;
    }
    return done;
}
static int sleep_us(sqlite3_vfs *v, int us) {
    (void)v;
    struct timespec t = { us / 1000000, (us % 1000000) * 1000 };
    while (nanosleep(&t, &t) && errno == EINTR) {}
    return us;
}
static int current_time(sqlite3_vfs *v, double *out) {
    (void)v;
    struct timespec t;
    if (clock_gettime(CLOCK_REALTIME, &t)) return SQLITE_ERROR;
    *out = 2440587.5 + (double)t.tv_sec / 86400.0 + (double)t.tv_nsec / 86400000000000.0;
    return SQLITE_OK;
}
static sqlite3_vfs vfs = {
    .iVersion = 1, .szOsFile = sizeof(sqlite3_file), .mxPathname = 4096,
    .zName = "no-files", .xOpen = deny_open, .xDelete = deny_delete,
    .xAccess = deny_access, .xFullPathname = deny_path, .xRandomness = randomness,
    .xSleep = sleep_us, .xCurrentTime = current_time,
};
int app_register_snapshot_vfs(void) {
    int rc = sqlite3_initialize();
    return rc == SQLITE_OK ? sqlite3_vfs_register(&vfs, 0) : rc;
}

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

static int fail(char *error, size_t cap, const char *message) {
    if (cap) snprintf(error, cap, "%s", message);
    return 0;
}

/* The lock follows SQLite's shared lock protocol. The snapshot requires a
 * cleanly closed rollback-mode database, since journal access is prohibited. */
int app_open(const char *path, sqlite3 **out, char *error, size_t cap) {
    static const unsigned char magic[16] = "SQLite format 3";
    const off_t max_size = 256 * 1024 * 1024;
    int fd = -1, rc = 0;
    unsigned char *data = NULL;
    sqlite3 *db = NULL;
    struct stat before, after;
    struct flock pending = { .l_type = F_RDLCK, .l_whence = SEEK_SET,
                             .l_start = 1073741824, .l_len = 1 };
    struct flock lock = { .l_type = F_RDLCK, .l_whence = SEEK_SET,
                          .l_start = 1073741826, .l_len = 510 };
    *out = NULL;
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return fail(error, cap, "Cannot open database file without following a symlink");
    if (fstat(fd, &before) || !S_ISREG(before.st_mode) || before.st_size < 100 || before.st_size > max_size) {
        fail(error, cap, "Database must be a regular file between 100 bytes and 256 MiB");
        goto done;
    }
    if (fcntl(fd, F_SETLK, &pending) < 0 || fcntl(fd, F_SETLK, &lock) < 0) {
        fail(error, cap, "Database is locked by another process");
        goto done;
    }
    pending.l_type = F_UNLCK;
    if (fcntl(fd, F_SETLK, &pending) < 0) {
        fail(error, cap, "Cannot release pending lock");
        goto done;
    }
    sqlite3_hard_heap_limit64(320LL * 1024 * 1024);
    data = sqlite3_malloc64((sqlite3_uint64)before.st_size);
    if (!data) { fail(error, cap, "Out of memory"); goto done; }
    size_t offset = 0, length = (size_t)before.st_size;
    while (offset < length) {
        ssize_t n = read(fd, data + offset, length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { fail(error, cap, "Could not read database snapshot"); goto done; }
        offset += (size_t)n;
    }
    if (fstat(fd, &after) || before.st_size != after.st_size ||
        before.st_mtim.tv_sec != after.st_mtim.tv_sec || before.st_mtim.tv_nsec != after.st_mtim.tv_nsec ||
        before.st_ctim.tv_sec != after.st_ctim.tv_sec || before.st_ctim.tv_nsec != after.st_ctim.tv_nsec) {
        fail(error, cap, "Database changed while reading");
        goto done;
    }
    if (memcmp(data, magic, sizeof(magic))) { fail(error, cap, "Not a SQLite database"); goto done; }
    if (data[18] != 1 || data[19] != 1) {
        fail(error, cap, "WAL databases are not supported by this read-only snapshot");
        goto done;
    }
    if (app_register_snapshot_vfs() != SQLITE_OK ||
        sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, "no-files") != SQLITE_OK) {
        fail(error, cap, "Cannot initialize SQLite"); goto done;
    }
    if (sqlite3_db_config(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, NULL) != SQLITE_OK ||
        sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, NULL) != SQLITE_OK) {
        fail(error, cap, "Cannot enable SQLite safety settings"); goto done;
    }
    sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 16 * 1024 * 1024);
    sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 128);
    sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 4096);
    int result = sqlite3_deserialize(db, "main", data, (sqlite3_int64)length, (sqlite3_int64)length,
                                     SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY);
    data = NULL;
    if (result != SQLITE_OK) { fail(error, cap, "Cannot load database snapshot"); goto done; }
    if (sqlite3_set_authorizer(db, authorizer, NULL) != SQLITE_OK) { fail(error, cap, "Cannot enforce read-only mode"); goto done; }
    *out = db;
    db = NULL;
    rc = 1;
done:
    if (data) sqlite3_free(data);
    if (db) sqlite3_close(db);
    if (fd >= 0) close(fd);
    return rc;
}

int app_prepare_tables(sqlite3 *db, sqlite3_stmt **stmt) {
    return sqlite3_prepare_v2(db,
        "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        -1, stmt, NULL);
}
int app_prepare_rows(sqlite3 *db, const char *table, sqlite3_stmt **stmt) {
    char *sql = sqlite3_mprintf("SELECT * FROM \"%w\" LIMIT 500", table);
    if (!sql) return SQLITE_NOMEM;
    int rc = sqlite3_prepare_v2(db, sql, -1, stmt, NULL);
    sqlite3_free(sql);
    return rc;
}

/* Only ordinary rowid tables support cell updates. Metadata queries are
 * internal and run before preparing user-facing statements. */
static int rowid_alias(sqlite3 *db, const char *table, const char **out) {
    static const char *aliases[] = { "_rowid_", "rowid", "oid" };
    sqlite3_stmt *stmt = NULL;
    int ordinary = 0, rc;
    *out = NULL;
    if (sqlite3_set_authorizer(db, NULL, NULL) != SQLITE_OK) return SQLITE_ERROR;
    rc = sqlite3_prepare_v2(db, "PRAGMA main.table_list", -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *schema = sqlite3_column_text(stmt, 0);
            const unsigned char *name = sqlite3_column_text(stmt, 1);
            const unsigned char *type = sqlite3_column_text(stmt, 2);
            if (schema && !strcmp((const char *)schema, "main") && name && type && !sqlite3_stricmp((const char *)name, table) &&
                !strcmp((const char *)type, "table") && sqlite3_column_int(stmt, 4) == 0) {
                ordinary = 1;
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
int app_prepare_editable_rows(sqlite3 *db, const char *table, sqlite3_stmt **stmt, int *has_rowid) {
    const char *alias = NULL;
    *stmt = NULL;
    *has_rowid = 0;
    int rc = rowid_alias(db, table, &alias);
    if (rc != SQLITE_OK) return rc;
    if (alias) {
        char *sql = sqlite3_mprintf("SELECT \"%w\", * FROM \"%w\" LIMIT 500", alias, table);
        if (!sql) return SQLITE_NOMEM;
        rc = sqlite3_prepare_v2(db, sql, -1, stmt, NULL);
        sqlite3_free(sql);
        if (rc == SQLITE_OK && *stmt) { *has_rowid = 1; return SQLITE_OK; }
        if (*stmt) sqlite3_finalize(*stmt);
        *stmt = NULL;
    }
    return app_prepare_rows(db, table, stmt);
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
void app_query_begin(sqlite3 *db) {
    query_budget = 2000;
    sqlite3_progress_handler(db, 1000, progress, &query_budget);
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
static int check_wal_mode(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_set_authorizer(db, NULL, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &stmt, NULL);
    if (rc == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *mode = sqlite3_column_text(stmt, 0);
        if (!mode || strcmp((const char *)mode, "wal")) rc = SQLITE_READONLY;
    } else if (rc == SQLITE_OK) rc = SQLITE_ERROR;
    if (stmt) sqlite3_finalize(stmt);
    if (app_set_write_authorizer(db) != SQLITE_OK && rc == SQLITE_OK) rc = SQLITE_ERROR;
    return rc;
}
int app_execute_write(sqlite3 *db, const char *sql, char *error, size_t cap) {
    sqlite3_stmt *stmt = NULL;
    int mutating = 0;
    int rc = internal_transaction(db, "BEGIN IMMEDIATE");
    if (rc != SQLITE_OK) goto failed;
    /* Hold the write lock while verifying that SQLite still uses WAL. */
    rc = check_wal_mode(db);
    if (rc != SQLITE_OK) goto rollback;
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
    if (cap) snprintf(error, cap, "%s", rc == SQLITE_READONLY ? "Database is not in WAL mode" : sqlite3_errmsg(db));
    if (stmt) sqlite3_finalize(stmt);
    (void)internal_transaction(db, "ROLLBACK");
    return 0;
failed:
    if (cap) snprintf(error, cap, "%s", sqlite3_errmsg(db));
    return 0;
}

int app_update_cell(sqlite3 *db, const char *table, const char *column, sqlite3_int64 rowid,
                    const char *value, int value_type, int expected_version, char *error, size_t cap) {
    sqlite3_stmt *stmt = NULL;
    char *sql = NULL;
    const char *alias = NULL;
    int version = 0, rc = internal_transaction(db, "BEGIN IMMEDIATE");
    if (rc != SQLITE_OK) goto failed;
    rc = check_wal_mode(db);
    if (rc != SQLITE_OK) goto rollback;
    rc = app_data_version(db, 1, &version);
    if (rc != SQLITE_OK) goto rollback;
    if (version != expected_version) {
        if (cap) snprintf(error, cap, "Database changed. Reload before editing");
        goto rollback_message;
    }
    rc = rowid_alias(db, table, &alias);
    if (rc != SQLITE_OK || !alias) {
        if (cap) snprintf(error, cap, "Table cannot be edited by rowid");
        goto rollback_message;
    }
    sql = sqlite3_mprintf("UPDATE main.\"%w\" SET \"%w\"=?1 WHERE \"%w\"=?2", table, column, alias);
    if (!sql) { rc = SQLITE_NOMEM; goto rollback; }
    rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    sqlite3_free(sql); sql = NULL;
    if (rc != SQLITE_OK || !stmt) goto rollback;
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
    } else {
        if (cap) snprintf(error, cap, "Unsupported cell type");
        goto rollback_message;
    }
    if (rc == SQLITE_OK) rc = sqlite3_bind_int64(stmt, 2, rowid);
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
