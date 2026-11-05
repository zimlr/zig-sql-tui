const std = @import("std");
const c = std.c;
const support = @import("terminal_support.zig");
extern "c" fn mkfifo([*:0]const u8, c.mode_t) c_int;

fn fixture() !support.Fixture {
    return support.Fixture.init(
        \\CREATE TABLE people(name TEXT, age INTEGER);
        \\INSERT INTO people VALUES ('Ada', 42), ('Lin', 31), (char(27) || '[2J injected', 1);
        \\INSERT INTO people SELECT 'long-value-' || printf('%.*c', 300, 'x') || 'endmarker', 5;
        \\CREATE TABLE "quoted""table" (v TEXT);
        \\INSERT INTO "quoted""table" VALUES ('quoted row');
    );
}

fn digest(path: [*:0]const u8) ![32]u8 {
    const fd = c.open(path, .{});
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        hash.update(buffer[0..@intCast(n)]);
    }
    return hash.finalResult();
}

test "read only check leaves database unchanged" {
    var db = try fixture();
    defer db.deinit();
    const before = try digest(@ptrCast(&db.path));
    const result = try support.runCheck(@ptrCast(&db.path));
    try std.testing.expectEqual(@as(c_int, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output[0..result.len], "2 tables") != null);
    try std.testing.expectEqual(before, try digest(@ptrCast(&db.path)));
    const dir = c.opendir(@ptrCast(&db.dir)) orelse return error.OpenFailed;
    defer _ = c.closedir(dir);
    var entries: usize = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        entries += 1;
        try std.testing.expectEqualStrings("test.sqlite", name);
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
    var path: [350]u8 = undefined;
    for ([_][]const u8{ "-wal", "-shm", "-journal" }) |suffix| {
        const name = try std.fmt.bufPrint(&path, "{s}{s}\x00", .{ std.mem.sliceTo(&db.path, 0), suffix });
        try std.testing.expect(c.access(@ptrCast(name.ptr), 0) != 0);
    }
}

test "reject symlink invalid database and FIFO without blocking" {
    var db = try fixture();
    defer db.deinit();
    var path: [350]u8 = undefined;
    const name = try std.fmt.bufPrint(&path, "{s}/link.sqlite\x00", .{std.mem.sliceTo(&db.dir, 0)});
    const link: [*:0]const u8 = @ptrCast(name.ptr);
    if (c.symlink("test.sqlite", link) != 0) return error.SymlinkFailed;
    defer _ = c.unlink(link);
    try std.testing.expect((try support.runCheck(link)).status != 0);
    var invalid_buf: [350]u8 = undefined;
    const invalid_name = try std.fmt.bufPrint(&invalid_buf, "{s}/invalid.sqlite\x00", .{std.mem.sliceTo(&db.dir, 0)});
    const invalid: [*:0]const u8 = @ptrCast(invalid_name.ptr);
    const fd = c.open(invalid, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    var bytes: [216]u8 = @splat(0);
    @memcpy(bytes[0..16], "SQLite format 3\x00");
    const n = c.write(fd, &bytes, bytes.len);
    _ = c.close(fd);
    defer _ = c.unlink(invalid);
    if (n != bytes.len) return error.WriteFailed;
    try std.testing.expect((try support.runCheck(invalid)).status != 0);
    var fifo_buf: [350]u8 = undefined;
    const fifo_name = try std.fmt.bufPrint(&fifo_buf, "{s}/pipe\x00", .{std.mem.sliceTo(&db.dir, 0)});
    const fifo: [*:0]const u8 = @ptrCast(fifo_name.ptr);
    if (mkfifo(fifo, 0o600) != 0) return error.MkfifoFailed;
    defer _ = c.unlink(fifo);
    try std.testing.expect((try support.runCheck(fifo)).status != 0);
}

test "browser navigation resizing and write refusal" {
    var db = try fixture();
    defer db.deinit();
    const before = try digest(@ptrCast(&db.path));
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.wait("people", 0);
    try t.wait("\\x1B[2J injected", 0);
    try t.wait("Tab: panel", 0);
    try t.wait("DETAIL / SQL", 0);
    try t.send("2gg", "quoted row");
    try t.send("gg", "\\x1B[2J injected");
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send("l", "Column 2/2");
    try t.send("h", "Column 1/2");
    try t.send("G", "endmarker");
    try t.send("/Lin\r", "Match found");
    try t.send("iSELECT count(*) AS total FROM people\r", "Read-only query results");
    try t.wait("> [4]", 0);
    try t.send("i", "[RO] INSERT | ROWS");
    var input: [160]u8 = undefined;
    const previous = "SELECT count(*) AS total FROM people";
    const deletion = "DELETE FROM people\r";
    @memset(input[0..previous.len], 127);
    @memcpy(input[previous.len..][0..deletion.len], deletion);
    try t.send(input[0 .. previous.len + deletion.len], "Enter exactly one read-only SQL statement");
    try t.send("\t", "[RO] NORMAL | DETAIL");
    try t.send("h", "[RO] NORMAL | ROWS");
    try t.send(":set rw\r", "Enable write mode");
    try t.send("n", "Cancelled");
    try t.send("?", "HELP | Press any key");
    try t.send("x", "[RO] NORMAL");
    try t.resize(35, 10, "Resize terminal");
    var start = t.len;
    try t.resize(60, 24, "Tab: panel");
    try std.testing.expect(std.mem.indexOf(u8, t.output[start..t.len], "[RO] NORMAL | ROWS") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.output[start..t.len], "DETAIL / SQL") == null);
    try std.testing.expect(std.mem.indexOf(u8, t.output[start..t.len], "\x1b[3;1HTABLES") == null);
    start = t.len;
    try t.resize(61, 24, "Tab: panel");
    try std.testing.expect(std.mem.indexOf(u8, t.output[start..t.len], "\x1b[3;1HTABLES") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.output[start..t.len], "ROWS:") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.output[start..t.len], "DETAIL / SQL") == null);
    try t.send("i", "[RO] INSERT | ROWS");
    const deleted = "DELETE FROM people";
    @memset(input[0..deleted.len], 127);
    @memcpy(input[deleted.len..][0..8], "SELECT '");
    @memset(input[deleted.len + 8 .. deleted.len + 8 + 70], 'a');
    try t.send(input[0 .. deleted.len + 8 + 70], "SQL> <");
    try t.send("\x1b", "[RO] NORMAL | ROWS");
    try t.quit();
    try std.testing.expectEqual(before, try digest(@ptrCast(&db.path)));
}

const Db = opaque {};
const Stmt = opaque {};
extern fn sqlite3_open([*:0]const u8, *?*Db) c_int;
extern fn sqlite3_close(*Db) c_int;
extern fn sqlite3_exec(*Db, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*anyopaque) c_int;
extern fn sqlite3_prepare_v2(*Db, [*:0]const u8, c_int, *?*Stmt, ?*?[*:0]const u8) c_int;
extern fn sqlite3_step(*Stmt) c_int;
extern fn sqlite3_column_text(*Stmt, c_int) ?[*:0]const u8;
extern fn sqlite3_finalize(*Stmt) c_int;

fn openDb(path: [*:0]const u8) !*Db {
    var db: ?*Db = null;
    if (sqlite3_open(path, &db) != 0 or db == null) {
        if (db) |d| _ = sqlite3_close(d);
        return error.OpenDatabaseFailed;
    }
    return db.?;
}

fn exec(db: *Db, sql: [*:0]const u8) !void {
    if (sqlite3_exec(db, sql, null, null, null) != 0) return error.SqlFailed;
}

fn expectScalar(db: *Db, sql: [*:0]const u8, expected: []const u8) !void {
    var stmt: ?*Stmt = null;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, null) != 0 or stmt == null) return error.PrepareFailed;
    defer _ = sqlite3_finalize(stmt.?);
    if (sqlite3_step(stmt.?) != 100) return error.MissingRow;
    const text = sqlite3_column_text(stmt.?, 0) orelse return error.MissingValue;
    try std.testing.expectEqualStrings(expected, std.mem.span(text));
}

fn checkContains(path: [*:0]const u8, text: []const u8) !void {
    const result = try support.runCheck(path);
    try std.testing.expectEqual(@as(c_int, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output[0..result.len], text) != null);
}

fn truncate(path: [*:0]const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .RDWR });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.ftruncate(fd, 256 * 1024 * 1024 + 4096) != 0) return error.TruncateFailed;
}

test "WAL check reads committed frames without changes" {
    var fixture_db = try support.Fixture.init("SELECT 1");
    defer fixture_db.deinit();
    const db = try openDb(@ptrCast(&fixture_db.path));
    defer _ = sqlite3_close(db);
    try expectScalar(db, "PRAGMA journal_mode=WAL", "wal");
    try exec(db, "CREATE TABLE data(n); INSERT INTO data VALUES ('committed in WAL')");
    var wal_buf: [350]u8 = undefined;
    const wal = try std.fmt.bufPrint(&wal_buf, "{s}-wal\x00", .{std.mem.sliceTo(&fixture_db.path, 0)});
    const wal_path: [*:0]const u8 = @ptrCast(wal.ptr);
    const before_db = try digest(@ptrCast(&fixture_db.path));
    const before_wal = try digest(wal_path);
    try checkContains(@ptrCast(&fixture_db.path), "Read-only database: 1 tables");
    try std.testing.expectEqual(before_db, try digest(@ptrCast(&fixture_db.path)));
    try std.testing.expectEqual(before_wal, try digest(wal_path));
    try expectScalar(db, "SELECT n FROM data", "committed in WAL");
}

test "large WAL and rollback databases remain readable" {
    var wal_fixture = try support.Fixture.init("SELECT 1");
    defer wal_fixture.deinit();
    {
        const db = try openDb(@ptrCast(&wal_fixture.path));
        defer _ = sqlite3_close(db);
        try expectScalar(db, "PRAGMA journal_mode=WAL", "wal");
        try exec(db, "CREATE TABLE data(n)");
        try truncate(@ptrCast(&wal_fixture.path));
        try checkContains(@ptrCast(&wal_fixture.path), "Read-only database: 1 tables");
    }

    var rollback = try fixture();
    defer rollback.deinit();
    try truncate(@ptrCast(&rollback.path));
    try checkContains(@ptrCast(&rollback.path), "Read-only database: 2 tables");
}

test "WAL sidecar symlink is rejected and target unchanged" {
    var fixture_db = try support.Fixture.init("SELECT 1");
    defer fixture_db.deinit();
    const db = try openDb(@ptrCast(&fixture_db.path));
    defer _ = sqlite3_close(db);
    try expectScalar(db, "PRAGMA journal_mode=WAL", "wal");
    try exec(db, "CREATE TABLE data(n)");
    var wal_buf: [350]u8 = undefined;
    var saved_buf: [350]u8 = undefined;
    var target_buf: [350]u8 = undefined;
    const wal: [*:0]const u8 = @ptrCast((try std.fmt.bufPrint(&wal_buf, "{s}-wal\x00", .{std.mem.sliceTo(&fixture_db.path, 0)})).ptr);
    const saved: [*:0]const u8 = @ptrCast((try std.fmt.bufPrint(&saved_buf, "{s}/saved-wal\x00", .{std.mem.sliceTo(&fixture_db.dir, 0)})).ptr);
    const target: [*:0]const u8 = @ptrCast((try std.fmt.bufPrint(&target_buf, "{s}/target\x00", .{std.mem.sliceTo(&fixture_db.dir, 0)})).ptr);
    const fd = c.open(target, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    const n = c.write(fd, "untouched", 9);
    _ = c.close(fd);
    defer _ = c.unlink(target);
    if (n != 9) return error.WriteFailed;
    if (c.rename(wal, saved) != 0) return error.RenameFailed;
    defer _ = c.rename(saved, wal);
    if (c.symlink("target", wal) != 0) return error.SymlinkFailed;
    defer _ = c.unlink(wal);
    const before = try digest(target);
    try std.testing.expect((try support.runCheck(@ptrCast(&fixture_db.path))).status != 0);
    try std.testing.expectEqual(before, try digest(target));
}

test "exclusive and pending database locks are rejected" {
    var fixture_db = try fixture();
    defer fixture_db.deinit();
    {
        const db = try openDb(@ptrCast(&fixture_db.path));
        defer _ = sqlite3_close(db);
        try exec(db, "BEGIN EXCLUSIVE");
        const exclusive = try support.runCheck(@ptrCast(&fixture_db.path));
        try std.testing.expect(exclusive.status != 0);
        try std.testing.expect(std.mem.indexOf(u8, exclusive.stderr[0..exclusive.stderr_len], "locked") != null);
        try exec(db, "ROLLBACK");
    }

    const fd = c.open(@ptrCast(&fixture_db.path), .{ .ACCMODE = .RDWR });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var lock: c.Flock = .{ .type = c.F.WRLCK, .whence = c.SEEK.SET, .start = 1073741824, .len = 1, .pid = 0, ._unused = {} };
    if (c.fcntl(fd, c.F.SETLK, &lock) != 0) return error.LockFailed;
    const pending = try support.runCheck(@ptrCast(&fixture_db.path));
    try std.testing.expect(pending.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, pending.stderr[0..pending.stderr_len], "locked") != null);
    lock.type = c.F.UNLCK;
    if (c.fcntl(fd, c.F.SETLK, &lock) != 0) return error.UnlockFailed;
}

test "mutated databases cannot crash or change during read-only checks" {
    for (0..64) |index| {
        var db = try fixture();
        defer db.deinit();
        const path: [*:0]const u8 = @ptrCast(&db.path);
        const fd = c.open(path, .{ .ACCMODE = .RDWR });
        if (fd < 0) return error.OpenFailed;
        const length = c.lseek(fd, 0, 2);
        if (length <= 100) {
            _ = c.close(fd);
            return error.FixtureTooSmall;
        }
        const offset: c.off_t = if (index < 16) @intCast(index) else @intCast(100 + ((index - 16) * 157) % @as(usize, @intCast(length - 100)));
        var byte: [1]u8 = undefined;
        if (c.pread(fd, &byte, 1, offset) != 1) {
            _ = c.close(fd);
            return error.ReadFailed;
        }
        byte[0] ^= 0xff;
        if (c.pwrite(fd, &byte, 1, offset) != 1) {
            _ = c.close(fd);
            return error.WriteFailed;
        }
        _ = c.close(fd);
        const before = try digest(path);
        const result = try support.runCheck(path);
        try std.testing.expectEqual(@as(c_int, 0), result.status & 0x7f);
        if (index < 16) try std.testing.expect(result.status != 0);
        try std.testing.expectEqual(before, try digest(path));
        for (result.stderr[0..result.stderr_len]) |ch| {
            try std.testing.expect(ch >= 0x20 or ch == '\n' or ch == '\r' or ch == '\t');
            try std.testing.expect(ch != 0x7f);
        }
        var sidecar: [350]u8 = undefined;
        for ([_][]const u8{ "-wal", "-shm", "-journal" }) |suffix| {
            const name = try std.fmt.bufPrintSentinel(&sidecar, "{s}{s}", .{ std.mem.sliceTo(&db.path, 0), suffix }, 0);
            try std.testing.expect(c.access(name.ptr, 0) != 0);
        }
    }
}
