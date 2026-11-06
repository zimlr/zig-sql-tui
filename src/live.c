#define _GNU_SOURCE
#include "sqlite3.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

/* The native SQLite VFS never receives a real path. Its path-based system
 * calls are restricted to four synthetic names anchored at one directory fd. */
static int directory_fd = -1;
static int live_writable;
static char main_name[256], wal_name[256], shm_name[256], journal_name[256];
static sqlite3_vfs *unix_vfs;
static sqlite3_vfs restricted_vfs;
static int registered;

int app_set_readonly_authorizer(sqlite3 *db);
int app_set_write_authorizer(sqlite3 *db);

static const char *allowed_name(const char *path) {
    if (!path) return NULL;
    if (!strcmp(path, "/db")) return main_name;
    if (!strcmp(path, "/db-wal")) return wal_name;
    if (!strcmp(path, "/db-shm")) return shm_name;
    if (!strcmp(path, "/db-journal")) return journal_name;
    return NULL;
}
static int safe_open(const char *path, int flags, int mode) {
    const char *name = allowed_name(path);
    if (!name || directory_fd < 0 || (flags & O_TRUNC)) { errno = EACCES; return -1; }
    if (!live_writable && strcmp(path, "/db-shm") && (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC))) {
        errno = EACCES; return -1;
    }
    /* Allowed names are single components, so O_NOFOLLOW covers the only
     * possible symlink without requiring openat2, which Android may trap.
     * Journals, WAL files, and the SHM index carry database pages or index
     * state, so they are created owner-only. SQLite asks for 0644, which
     * safe_fchmod also overrides after creation. */
    int fd = openat(directory_fd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                    (flags & O_CREAT) ? 0600 : mode);
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) || !S_ISREG(st.st_mode) || (strcmp(path, "/db") && st.st_nlink != 1)) {
            close(fd); errno = EACCES; return -1;
        }
    }
    return fd;
}
static int safe_stat(const char *path, struct stat *st) {
    const char *name = allowed_name(path);
    if (!name || directory_fd < 0) { errno = EACCES; return -1; }
    if (fstatat(directory_fd, name, st, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISREG(st->st_mode) || (strcmp(path, "/db") && st->st_nlink != 1)) { errno = EACCES; return -1; }
    return 0;
}
static int safe_access(const char *path, int mode) {
    struct stat st;
    if (safe_stat(path, &st)) return -1;
    /* SQLite uses F_OK for journal existence. Permission probes fail closed:
     * opening and closing another fd could discard the process's POSIX locks. */
    if (mode == F_OK) return 0;
    errno = EACCES;
    return -1;
}
static int safe_unlink(const char *path) {
    const char *name = allowed_name(path);
    if (!name || !strcmp(path, "/db") || directory_fd < 0) { errno = EACCES; return -1; }
    if (!live_writable && strcmp(path, "/db-shm")) { errno = EACCES; return -1; }
    return unlinkat(directory_fd, name, 0);
}
/* robust_open retries the mode it asked for whenever a new sidecar is still
 * empty, which would undo the owner-only mode passed to open. Strip every
 * group and other bit so sidecars stay private to the database owner. */
static int safe_fchmod(int fd, int mode) {
    return fchmod(fd, mode & ~077);
}
static int safe_open_directory(const char *path, int *fd) {
    if (!allowed_name(path) || directory_fd < 0) return SQLITE_CANTOPEN;
    *fd = dup(directory_fd);
    return *fd >= 0 ? SQLITE_OK : SQLITE_CANTOPEN;
}
/* SQLite opens a WAL with READWRITE|CREATE even for a read-only connection.
 * When a cleanly closed database has no sidecars, the read-only open would
 * fail with "unable to open database file". Create the empty WAL ourselves so
 * SQLite can treat it as present; the handle below stays read-only. */
static int create_empty_wal(void) {
    struct stat st;
    if (fstatat(directory_fd, wal_name, &st, AT_SYMLINK_NOFOLLOW) == 0)
        return S_ISREG(st.st_mode) && st.st_nlink == 1 ? 0 : -1;
    if (errno != ENOENT) return -1;
    int fd = openat(directory_fd, wal_name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return errno == EEXIST ? 0 : -1;
    int ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1;
    if (close(fd) != 0) ok = 0;
    return ok ? 0 : -1;
}
static int restricted_open(sqlite3_vfs *v, sqlite3_filename path, sqlite3_file *file, int flags, int *out) {
    (void)v;
    if (!path || (!strcmp(path, "/db") && !(flags & SQLITE_OPEN_MAIN_DB)) ||
        (!strcmp(path, "/db-wal") && !(flags & SQLITE_OPEN_WAL)) ||
        (!strcmp(path, "/db-journal") && !(flags & SQLITE_OPEN_MAIN_JOURNAL)) ||
        (strcmp(path, "/db") && strcmp(path, "/db-wal") && strcmp(path, "/db-journal"))) return SQLITE_CANTOPEN;
    if (!strcmp(path, "/db") && (flags & SQLITE_OPEN_CREATE)) return SQLITE_CANTOPEN;
    if (!live_writable) {
        if (!strcmp(path, "/db-wal") && (flags & SQLITE_OPEN_CREATE) && create_empty_wal()) return SQLITE_CANTOPEN;
        flags &= ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
        flags |= SQLITE_OPEN_READONLY;
    }
    return unix_vfs->xOpen(unix_vfs, path, file, flags, out);
}
static int restricted_delete(sqlite3_vfs *v, const char *path, int sync) {
    (void)v;
    if (safe_unlink(path) == 0) {
        if (sync && fsync(directory_fd) != 0) return SQLITE_IOERR_DIR_FSYNC;
        return SQLITE_OK;
    }
    return errno == ENOENT ? SQLITE_IOERR_DELETE_NOENT : SQLITE_IOERR_DELETE;
}
static int restricted_access(sqlite3_vfs *v, const char *path, int flags, int *result) {
    (void)v;
    if (!allowed_name(path)) return SQLITE_IOERR_ACCESS;
    struct stat st;
    *result = 0;
    if (safe_stat(path, &st) == 0) {
        if (flags == SQLITE_ACCESS_EXISTS) *result = st.st_size > 0;
        else *result = safe_access(path, R_OK | W_OK) == 0;
    } else if (errno != ENOENT) return SQLITE_IOERR_ACCESS;
    return SQLITE_OK;
}
static int restricted_path(sqlite3_vfs *v, const char *path, int size, char *out) {
    (void)v;
    if (!path || strcmp(path, "/db") || size < 4) return SQLITE_CANTOPEN;
    memcpy(out, "/db", 4);
    return SQLITE_OK;
}
static int restricted_random(sqlite3_vfs *v, int n, char *out) {
    (void)v;
    int done = 0;
    while (done < n) {
        ssize_t got = getrandom(out + done, (size_t)(n - done), 0);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        done += (int)got;
    }
    return done;
}
static int prepare_vfs(void) {
    if (registered) return SQLITE_OK;
    if (sqlite3_initialize() != SQLITE_OK) return SQLITE_ERROR;
    unix_vfs = sqlite3_vfs_find("unix");
    if (!unix_vfs || !unix_vfs->xSetSystemCall) return SQLITE_ERROR;
#define HOOK(name, fn) if (unix_vfs->xSetSystemCall(unix_vfs, name, (sqlite3_syscall_ptr)(fn)) != SQLITE_OK) return SQLITE_ERROR
    HOOK("open", safe_open);
    HOOK("stat", safe_stat);
    HOOK("access", safe_access);
    HOOK("unlink", safe_unlink);
    HOOK("fchmod", safe_fchmod);
    HOOK("openDirectory", safe_open_directory);
#undef HOOK
    restricted_vfs = *unix_vfs;
    restricted_vfs.zName = "restricted-wal";
    restricted_vfs.pNext = NULL;
    restricted_vfs.iVersion = 2;
    restricted_vfs.xOpen = restricted_open;
    restricted_vfs.xDelete = restricted_delete;
    restricted_vfs.xAccess = restricted_access;
    restricted_vfs.xFullPathname = restricted_path;
    restricted_vfs.xRandomness = restricted_random;
    restricted_vfs.xDlOpen = NULL;
    restricted_vfs.xDlError = NULL;
    restricted_vfs.xDlSym = NULL;
    restricted_vfs.xDlClose = NULL;
    restricted_vfs.xSetSystemCall = NULL;
    restricted_vfs.xGetSystemCall = NULL;
    restricted_vfs.xNextSystemCall = NULL;
    int rc = sqlite3_vfs_register(&restricted_vfs, 0);
    if (rc == SQLITE_OK) registered = 1;
    return rc;
}
static int fail(char *error, size_t cap, const char *text) {
    if (cap) snprintf(error, cap, "%s", text);
    return 0;
}
void app_live_close(void) {
    if (directory_fd >= 0) close(directory_fd);
    directory_fd = -1;
    live_writable = 0;
}
static int open_connection(int writable, sqlite3 **out, char *error, size_t cap) {
    sqlite3 *db = NULL;
    *out = NULL;
    int previous = live_writable;
    live_writable = writable;
    int flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW;
    if (sqlite3_open_v2("/db", &db, flags, "restricted-wal") != SQLITE_OK || !db ||
        sqlite3_db_readonly(db, "main") != (writable ? 0 : 1)) {
        if (db) sqlite3_close(db);
        live_writable = previous;
        return fail(error, cap, "Cannot open database with requested access");
    }
    int persist = 1;
    if (sqlite3_db_config(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, NULL) != SQLITE_OK ||
        sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, NULL) != SQLITE_OK ||
        sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, NULL) != SQLITE_OK ||
        sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &persist) != SQLITE_OK ||
        (writable ? app_set_write_authorizer(db) : app_set_readonly_authorizer(db)) != SQLITE_OK) {
        sqlite3_close(db);
        live_writable = previous;
        return fail(error, cap, "Cannot enable SQLite safety settings");
    }
    sqlite3_busy_timeout(db, 1000);
    sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 16 * 1024 * 1024);
    sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 2000);
    sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 1024 * 1024);
    *out = db;
    return 1;
}
int app_reopen_live(sqlite3 *current, int writable, sqlite3 **out, char *error, size_t cap) {
    sqlite3 *next = NULL;
    int previous = live_writable;
    *out = NULL;
    if (directory_fd < 0 || !open_connection(writable, &next, error, cap)) return 0;
    if (sqlite3_close(current) != SQLITE_OK) {
        sqlite3_close(next);
        live_writable = previous;
        return fail(error, cap, "Cannot switch access while statements are active");
    }
    *out = next;
    return 1;
}
/* Resolve each directory component from a pinned fd. O_PATH avoids requiring
 * read permission on intermediate directories, and O_NOFOLLOW rejects both
 * ordinary and magic symlinks. The final fd remains usable for fsync. */
int app_open_directory(const char *path) {
    int current = open(path[0] == '/' ? "/" : ".", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (current < 0) return -1;
    const char *p = path;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        const char *end = p;
        while (*end && *end != '/') end++;
        size_t len = (size_t)(end - p);
        char component[4096];
        if (len >= sizeof(component)) { close(current); errno = ENAMETOOLONG; return -1; }
        memcpy(component, p, len);
        component[len] = 0;
        int next = openat(current, component, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int saved = errno;
        close(current);
        if (next < 0) { errno = saved; return -1; }
        current = next;
        p = end;
    }
    int result = openat(current, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int saved = errno;
    close(current);
    if (result < 0) errno = saved;
    return result;
}

int app_open_live(const char *path, int writable, sqlite3 **out, char *error, size_t cap) {
    char dir[4096];
    const char *slash = strrchr(path, '/');
    const char *base = slash ? slash + 1 : path;
    size_t n = strlen(base);
    sqlite3 *db = NULL;
    *out = NULL;
    if (directory_fd >= 0) return fail(error, cap, "A database is already open");
    if (!n || n > 247 || !strcmp(base, ".") || !strcmp(base, ".."))
        return fail(error, cap, "Invalid database filename");
    size_t dir_len = slash ? (size_t)(slash - path) : 1;
    if (dir_len >= sizeof(dir)) return fail(error, cap, "Database path is too long");
    if (!slash) memcpy(dir, ".", 2);
    else if (!dir_len) memcpy(dir, "/", 2);
    else { memcpy(dir, path, dir_len); dir[dir_len] = 0; }
    memcpy(main_name, base, n + 1);
    snprintf(wal_name, sizeof(wal_name), "%s-wal", base);
    snprintf(shm_name, sizeof(shm_name), "%s-shm", base);
    snprintf(journal_name, sizeof(journal_name), "%s-journal", base);
    directory_fd = app_open_directory(dir);
    if (directory_fd < 0) return fail(error, cap, "Cannot safely open database directory. A path without symlinks is required");
    live_writable = writable;
    int fd = safe_open("/db", O_RDONLY, 0);
    unsigned char hdr[100];
    if (fd < 0 || pread(fd, hdr, sizeof(hdr), 0) != sizeof(hdr) ||
        memcmp(hdr, "SQLite format 3\0", 16)) {
        if (fd >= 0) close(fd);
        app_live_close();
        return fail(error, cap, "A valid SQLite database without symlinks is required");
    }
    close(fd);
    sqlite3_hard_heap_limit64(320LL * 1024 * 1024);
    if (prepare_vfs() != SQLITE_OK) { app_live_close(); return fail(error, cap, "Cannot initialize restricted SQLite VFS"); }
    if (!open_connection(writable, &db, error, cap)) { app_live_close(); return 0; }
    *out = db;
    return 1;
}

/* Recovery is invoked only after explicit confirmation. A schema read makes
 * SQLite perform any necessary hot-journal rollback while holding its locks. */
int app_recover(const char *path, char *error, size_t cap) {
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    if (!app_open_live(path, 1, &db, error, cap)) return 0;
    int rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_schema", -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        rc = sqlite3_step(stmt);
        if (rc == SQLITE_ROW) rc = SQLITE_OK;
    }
    if (stmt) sqlite3_finalize(stmt);
    if (rc != SQLITE_OK && cap) snprintf(error, cap, "Recovery failed: %s", sqlite3_errmsg(db));
    int close_rc = sqlite3_close(db);
    app_live_close();
    if (rc != SQLITE_OK) return 0;
    if (close_rc != SQLITE_OK) return fail(error, cap, "Cannot close recovery connection");
    return 1;
}
