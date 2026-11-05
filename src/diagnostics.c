#define _GNU_SOURCE
#include "sqlite3.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int app_open_directory(const char *path);
int app_open_live(const char *, int, sqlite3 **, char *, size_t);
int app_reopen_live(sqlite3 *, int, sqlite3 **, char *, size_t);
void app_live_close(void);
int app_recover(const char *, char *, size_t);
int app_set_write_authorizer(sqlite3 *);
int app_execute_write(sqlite3 *, const char *, char *, size_t);

static int emit(const char *name, int ok) {
    printf("%s: %s\n", name, ok ? "PASS" : "FAIL");
    fflush(stdout);
    return ok;
}

static int has_value(sqlite3 *db, const char *value) {
    sqlite3_stmt *stmt = NULL;
    int ok = sqlite3_prepare_v2(db, "SELECT value FROM data WHERE id=1", -1, &stmt, NULL) == SQLITE_OK &&
             sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) == SQLITE_TEXT &&
             sqlite3_column_text(stmt, 0) && !strcmp((const char *)sqlite3_column_text(stmt, 0), value);
    if (stmt) sqlite3_finalize(stmt);
    return ok;
}

static int fixture(int dir, const char *name, const unsigned char *bytes, sqlite3_int64 size) {
    int fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    sqlite3_int64 offset = 0;
    while (offset < size) {
        ssize_t n = write(fd, bytes + offset, (size_t)(size - offset));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return 0; }
        offset += n;
    }
    return close(fd) == 0;
}

static int open_fixture(const char *path, int writable, sqlite3 **db) {
    char error[256] = {0};
    return app_open_live(path, writable, db, error, sizeof(error));
}

static void close_fixture(sqlite3 **db) {
    if (*db) sqlite3_close(*db);
    *db = NULL;
    app_live_close();
}

static int test_rollback(const char *path) {
    sqlite3 *db = NULL, *next = NULL;
    char error[256] = {0};
    int ok = open_fixture(path, 0, &db) && has_value(db, "original") &&
             sqlite3_exec(db, "UPDATE data SET value='denied' WHERE id=1", NULL, NULL, NULL) == SQLITE_AUTH &&
             has_value(db, "original") &&
             app_reopen_live(db, 1, &next, error, sizeof(error));
    if (ok) {
        db = next;
        ok = app_execute_write(db, "UPDATE data SET value='updated' WHERE id=1", error, sizeof(error)) &&
             has_value(db, "updated");
    }
    close_fixture(&db);
    if (ok) ok = open_fixture(path, 0, &db) && has_value(db, "updated");
    close_fixture(&db);
    return ok;
}

static int test_wal(const char *path, int dir) {
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    char error[256] = {0};
    int ok = open_fixture(path, 1, &db) && sqlite3_set_authorizer(db, NULL, NULL) == SQLITE_OK &&
             sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &stmt, NULL) == SQLITE_OK &&
             sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_text(stmt, 0) &&
             !sqlite3_stricmp((const char *)sqlite3_column_text(stmt, 0), "wal");
    if (stmt) sqlite3_finalize(stmt);
    if (db && app_set_write_authorizer(db) != SQLITE_OK) ok = 0;
    if (ok) ok = app_execute_write(db, "UPDATE data SET value='wal' WHERE id=1", error, sizeof(error)) && has_value(db, "wal");
    close_fixture(&db);
    struct stat st;
    if (ok) ok = fstatat(dir, "wal.sqlite-wal", &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(st.st_mode) && st.st_size > 0;
    if (ok) ok = open_fixture(path, 0, &db) && has_value(db, "wal");
    close_fixture(&db);
    return ok;
}

static int create_hot_journal(const char *path) {
    pid_t child = fork();
    if (child < 0) return 0;
    if (child == 0) {
        sqlite3 *db = NULL;
        int ok = open_fixture(path, 1, &db) && sqlite3_set_authorizer(db, NULL, NULL) == SQLITE_OK &&
                 sqlite3_exec(db, "PRAGMA cache_size=4; BEGIN IMMEDIATE; UPDATE data SET value=replace(value,'A','B')", NULL, NULL, NULL) == SQLITE_OK;
        /* Simulate a crash without closing the connection or committing. */
        _exit(ok ? 0 : 1);
    }
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    return waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int test_recovery(const char *path, int dir) {
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    struct stat st;
    char error[256] = {0};
    int ok = create_hot_journal(path) &&
             fstatat(dir, "recovery.sqlite-journal", &st, AT_SYMLINK_NOFOLLOW) == 0 &&
             S_ISREG(st.st_mode) && st.st_size > 0;
    if (ok) {
        int opened = open_fixture(path, 0, &db);
        int rc = opened ? sqlite3_prepare_v2(db, "SELECT count(*) FROM data", -1, &stmt, NULL) : SQLITE_ERROR;
        if (rc == SQLITE_OK) rc = sqlite3_step(stmt);
        if (stmt) sqlite3_finalize(stmt);
        stmt = NULL;
        ok = rc != SQLITE_ROW && rc != SQLITE_DONE;
        close_fixture(&db);
    }
    if (ok) ok = app_recover(path, error, sizeof(error));
    if (ok) {
        ok = open_fixture(path, 0, &db) && has_value(db, "original") &&
             sqlite3_prepare_v2(db, "SELECT count(*) FROM data WHERE substr(value,1,1)='A'", -1, &stmt, NULL) == SQLITE_OK &&
             sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 200;
        if (stmt) sqlite3_finalize(stmt);
        close_fixture(&db);
    }
    return ok;
}

int app_diagnostics(void) {
    const char *home = getenv("HOME");
    int home_fd = -1, config_fd = -1, dir_fd = -1, success = 0, created_dir = 0, cleanup_ok = 1;
    char dir_name[64] = {0}, paths[3][4096] = {{0}};
    sqlite3 *seed = NULL;
    unsigned char *bytes = NULL;
    sqlite3_int64 size = 0;
    const char *names[] = {"rollback.sqlite", "wal.sqlite", "recovery.sqlite"};
    puts("zsqt debug self-test");
    puts("Uses disposable fixtures in the application's config directory. No user database is opened.");
    puts("Tests database operations, not interactive TUI confirmation prompts.");
    fflush(stdout);
    if (!home || !*home || (home_fd = app_open_directory(home)) < 0) goto setup_failed;
    struct stat st;
    if (fstat(home_fd, &st) || st.st_uid != geteuid() || (st.st_mode & 0022)) goto setup_failed;
    if (mkdirat(home_fd, ".zsqt", 0700) && errno != EEXIST) goto setup_failed;
    config_fd = openat(home_fd, ".zsqt", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (config_fd < 0 || fstat(config_fd, &st) || st.st_uid != geteuid() || (st.st_mode & 0022)) goto setup_failed;
    for (int tries = 0; tries < 10; ++tries) {
        unsigned long long random = 0;
        if (getrandom(&random, sizeof(random), 0) != sizeof(random)) goto setup_failed;
        snprintf(dir_name, sizeof(dir_name), "selftest-%016llx", random);
        if (mkdirat(config_fd, dir_name, 0700) == 0) { created_dir = 1; break; }
        if (errno != EEXIST) goto setup_failed;
    }
    if (!created_dir) goto setup_failed;
    dir_fd = openat(config_fd, dir_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dir_fd < 0 || fstat(dir_fd, &st) || st.st_uid != geteuid() || (st.st_mode & 0077)) goto setup_failed;
    if (sqlite3_open(":memory:", &seed) != SQLITE_OK ||
        sqlite3_exec(seed, "CREATE TABLE data(id INTEGER PRIMARY KEY, value TEXT);"
                           "INSERT INTO data VALUES(1,'original');"
                           "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<200) "
                           "INSERT INTO data(value) SELECT replace(hex(zeroblob(2000)),'0','A') FROM n;", NULL, NULL, NULL) != SQLITE_OK) goto setup_failed;
    bytes = sqlite3_serialize(seed, "main", &size, 0);
    if (!bytes || size <= 0) goto setup_failed;
    for (size_t i = 0; i < 3; ++i) {
        int length = snprintf(paths[i], sizeof(paths[i]), "%s/.zsqt/%s/%s", home, dir_name, names[i]);
        if (length < 0 || (size_t)length >= sizeof(paths[i]) || !fixture(dir_fd, names[i], bytes, size)) goto setup_failed;
    }
    sqlite3_free(bytes); bytes = NULL;
    sqlite3_close(seed); seed = NULL;
    puts("ROLLBACK WRITE: testing read-only enforcement and a committed write"); fflush(stdout);
    int rollback_ok = emit("ROLLBACK WRITE", test_rollback(paths[0]));
    puts("WAL: testing WAL writes and read-only reopen"); fflush(stdout);
    int wal_ok = emit("WAL", test_wal(paths[1], dir_fd));
    puts("RECOVERY: creating a hot journal and testing rollback"); fflush(stdout);
    int recovery_ok = emit("RECOVERY", test_recovery(paths[2], dir_fd));
    success = rollback_ok && wal_ok && recovery_ok;
    goto cleanup;
setup_failed:
    printf("SETUP: FAIL (errno %d)\n", errno);
cleanup:
    if (bytes) sqlite3_free(bytes);
    if (seed) sqlite3_close(seed);
    if (dir_fd >= 0) {
        const char *files[] = {"rollback.sqlite", "rollback.sqlite-journal", "rollback.sqlite-wal", "rollback.sqlite-shm",
                               "wal.sqlite", "wal.sqlite-journal", "wal.sqlite-wal", "wal.sqlite-shm",
                               "recovery.sqlite", "recovery.sqlite-journal", "recovery.sqlite-wal", "recovery.sqlite-shm"};
        for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); ++i)
            if (unlinkat(dir_fd, files[i], 0) && errno != ENOENT) cleanup_ok = 0;
        close(dir_fd);
    }
    if (created_dir && unlinkat(config_fd, dir_name, AT_REMOVEDIR)) cleanup_ok = 0;
    if (config_fd >= 0) close(config_fd);
    if (home_fd >= 0) close(home_fd);
    emit("CLEANUP", cleanup_ok);
    success = success && cleanup_ok;
    printf("RESULT: %s\n", success ? "PASS" : "FAIL");
    fflush(stdout);
    return success ? 0 : 1;
}
