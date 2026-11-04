#define _POSIX_C_SOURCE 200809L
#include "sqlite3.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int app_open_live(const char *, int, sqlite3 **, char *, size_t);
void app_live_close(void);
int app_prepare_query(sqlite3 *, const char *, sqlite3_stmt **);
void app_query_begin(sqlite3 *);
void app_query_end(sqlite3 *);

static int run(sqlite3 *db, const char *sql) {
    return sqlite3_exec(db, sql, NULL, NULL, NULL);
}

int main(void) {
    sqlite3 *source = NULL, *db = NULL;
    unsigned char *bytes = NULL;
    sqlite3_int64 size = 0;
    char error[256] = {0};
    char path[] = ".zig-cache/tmp/security-XXXXXX";
    int fd = -1, ok = 0, created = 0;
    if (sqlite3_open(":memory:", &source) != SQLITE_OK) goto done;
    if (run(source, "CREATE TABLE t(v); INSERT INTO t VALUES(7)") != SQLITE_OK) goto done;
    bytes = sqlite3_serialize(source, "main", &size, 0);
    if (!bytes || size <= 0) goto done;
    fd = mkstemp(path);
    if (fd < 0) goto done;
    created = 1;
    sqlite3_int64 written = 0;
    while (written < size) {
        ssize_t n = write(fd, bytes + written, (size_t)(size - written));
        if (n <= 0) goto done;
        written += n;
    }
    close(fd); fd = -1;
    if (!app_open_live(path, 0, &db, error, sizeof(error))) goto done;
    if (run(db, "SELECT * FROM t") != SQLITE_OK) goto done;
    const char *denied[] = {
        "INSERT INTO t VALUES(8)", "UPDATE t SET v=9", "DELETE FROM t",
        "DROP TABLE t", "CREATE TABLE other(v)", "PRAGMA user_version=1",
        "ATTACH ':memory:' AS other", "VACUUM INTO 'escape.sqlite'",
        "SELECT load_extension('escape')"
    };
    for (size_t i = 0; i < sizeof(denied) / sizeof(denied[0]); ++i) {
        if (run(db, denied[i]) == SQLITE_OK) {
            fprintf(stderr, "Unexpectedly permitted: %s\n", denied[i]);
            goto done;
        }
    }
    sqlite3_stmt *stmt = NULL;
    if (app_prepare_query(db, "SELECT v FROM t", &stmt) != SQLITE_OK || !stmt) goto done;
    if (sqlite3_step(stmt) != SQLITE_ROW || sqlite3_column_int(stmt, 0) != 7) {
        sqlite3_finalize(stmt); goto done;
    }
    sqlite3_finalize(stmt); stmt = NULL;
    if (app_prepare_query(db, "SELECT 1; /* trailing comment */ -- comment", &stmt) != SQLITE_OK || !stmt) goto done;
    sqlite3_finalize(stmt); stmt = NULL;
    const char *bad_queries[] = {
        "SELECT 1; DELETE FROM t", "SELECT 1; /* comment */ SELECT 2", "INSERT INTO t VALUES(9)",
        "ATTACH ':memory:' AS other", "PRAGMA user_version=1", "  "
    };
    for (size_t i = 0; i < sizeof(bad_queries) / sizeof(bad_queries[0]); ++i) {
        if (app_prepare_query(db, bad_queries[i], &stmt) == SQLITE_OK || stmt) {
            if (stmt) sqlite3_finalize(stmt);
            fprintf(stderr, "Unexpected query accepted: %s\n", bad_queries[i]);
            goto done;
        }
    }
    app_query_begin(db);
    if (app_prepare_query(db, "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT sum(x) FROM n", &stmt) != SQLITE_OK || !stmt) {
        app_query_end(db); goto done;
    }
    int step = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    app_query_end(db);
    if (step != SQLITE_INTERRUPT) {
        fprintf(stderr, "Query budget did not interrupt execution\n");
        goto done;
    }
    ok = 1;
done:
    if (!ok) fprintf(stderr, "Security test failed: %s\n", error);
    if (db) sqlite3_close(db);
    app_live_close();
    if (source) sqlite3_close(source);
    if (bytes) sqlite3_free(bytes);
    if (fd >= 0) close(fd);
    if (created) unlink(path);
    return ok ? 0 : 1;
}
