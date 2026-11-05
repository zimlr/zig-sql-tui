const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const support = @import("terminal_support.zig");
const process = @import("process_support.zig");
const Db = opaque {};
extern fn sqlite3_open([*:0]const u8, *?*Db) c_int;
extern fn sqlite3_close(*Db) c_int;
extern fn sqlite3_exec(*Db, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*anyopaque) c_int;
extern "c" fn _exit(c_int) noreturn;

fn probe() !void {
    if (builtin.os.tag != .linux or (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64)) return error.SkipZigTest;
    const args = [_:null]?[*:0]const u8{"/bin/true"};
    const result = try process.runWithOptions(&args, .{ .restricted = true });
    if (result.status == 77 << 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), result.status);
}

fn fixture() !support.Fixture {
    return support.Fixture.init("CREATE TABLE data(value TEXT); INSERT INTO data VALUES ('initial')");
}

fn open(db: *support.Fixture) !*Db {
    var conn: ?*Db = null;
    if (sqlite3_open(@ptrCast(&db.path), &conn) != 0 or conn == null) {
        if (conn) |opened| _ = sqlite3_close(opened);
        return error.OpenFailed;
    }
    return conn.?;
}

fn exec(db: *Db, sql: [*:0]const u8) !void {
    if (sqlite3_exec(db, sql, null, null, null) != 0) return error.SqlFailed;
}

fn sibling(db: *support.Fixture, buf: []u8, name: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ std.mem.sliceTo(&db.dir, 0), name }, 0);
}

fn sidecar(db: *support.Fixture, buf: []u8, suffix: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ std.mem.sliceTo(&db.path, 0), suffix }, 0);
}

fn targetFile(path: [*:0]const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.write(fd, "untouched", 9) != 9) return error.WriteFailed;
}

fn expectUntouched(path: [*:0]const u8) !void {
    const fd = c.open(path, .{});
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var bytes: [32]u8 = undefined;
    const n = c.read(fd, &bytes, bytes.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("untouched", bytes[0..@intCast(n)]);
}

fn digest(path: [*:0]const u8) ![32]u8 {
    const fd = c.open(path, .{});
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &bytes, bytes.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        hash.update(bytes[0..@intCast(n)]);
    }
    return hash.finalResult();
}

fn makeHot(db: *support.Fixture) !void {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        var conn: ?*Db = null;
        if (sqlite3_open(@ptrCast(&db.path), &conn) != 0 or conn == null) _exit(1);
        if (sqlite3_exec(conn.?, "PRAGMA cache_size=4; BEGIN IMMEDIATE; UPDATE data SET value=replace(value,'A','B')", null, null, null) != 0) _exit(2);
        _exit(0);
    }
    var done = false;
    defer if (!done) {
        _ = c.kill(pid, .KILL);
        _ = c.waitpid(pid, null, 0);
    };
    var status: c_int = 0;
    for (0..100) |_| {
        const result = c.waitpid(pid, &status, c.W.NOHANG);
        if (result == pid) {
            done = true;
            break;
        }
        if (result < 0) return error.WaitFailed;
        var idle = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
        _ = c.poll(&idle, 1, 100);
    }
    if (!done) return error.ChildTimeout;
    try std.testing.expectEqual(@as(c_int, 0), status);
    var journal_buf: [350]u8 = undefined;
    const journal = try sidecar(db, &journal_buf, "-journal");
    const fd = c.open(journal.ptr, .{});
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try std.testing.expect(c.lseek(fd, 0, c.SEEK.END) > 0);
}

test "restricted absolute and relative paths and directory symlinks" {
    try probe();
    var db = try fixture();
    defer db.deinit();
    try std.testing.expectEqual(@as(c_int, 0), (try support.runRestrictedCheck(@ptrCast(&db.path))).status);
    var cwd_buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    var absolute_buf: [4500]u8 = undefined;
    const absolute = try std.fmt.bufPrintSentinel(&absolute_buf, "{s}/{s}", .{ std.mem.sliceTo(cwd, 0), std.mem.sliceTo(&db.path, 0) }, 0);
    try std.testing.expectEqual(@as(c_int, 0), (try support.runRestrictedCheck(absolute.ptr)).status);
    var nested_buf: [350]u8 = undefined;
    const nested = try sibling(&db, &nested_buf, "nested");
    if (c.mkdir(nested.ptr, 0o700) != 0) return error.MkdirFailed;
    defer _ = c.rmdir(nested.ptr);
    var traversal_buf: [400]u8 = undefined;
    const traversal = try std.fmt.bufPrintSentinel(&traversal_buf, "{s}/../test.sqlite", .{nested}, 0);
    try std.testing.expectEqual(@as(c_int, 0), (try support.runRestrictedCheck(traversal.ptr)).status);
    var link_buf: [350]u8 = undefined;
    const link = try sibling(&db, &link_buf, "link");
    if (c.symlink("nested", link.ptr) != 0) return error.SymlinkFailed;
    defer _ = c.unlink(link.ptr);
    var escape_buf: [400]u8 = undefined;
    const escape = try std.fmt.bufPrintSentinel(&escape_buf, "{s}/../test.sqlite", .{link}, 0);
    try std.testing.expect((try support.runRestrictedCheck(escape.ptr)).status != 0);
    var alias_buf: [350]u8 = undefined;
    const alias = try sibling(&db, &alias_buf, "alias.sqlite");
    if (c.symlink("test.sqlite", alias.ptr) != 0) return error.SymlinkFailed;
    defer _ = c.unlink(alias.ptr);
    try std.testing.expect((try support.runRestrictedCheck(alias.ptr)).status != 0);
}

test "restricted journal links are rejected" {
    try probe();
    var db = try fixture();
    defer db.deinit();
    var target_buf: [350]u8 = undefined;
    const target = try sibling(&db, &target_buf, "unrelated");
    try targetFile(target.ptr);
    defer _ = c.unlink(target.ptr);
    var journal_buf: [350]u8 = undefined;
    const journal = try sidecar(&db, &journal_buf, "-journal");
    if (c.symlink("unrelated", journal.ptr) != 0) return error.SymlinkFailed;
    try std.testing.expect((try support.runRestrictedCheck(@ptrCast(&db.path))).status != 0);
    if (c.unlink(journal.ptr) != 0) return error.UnlinkFailed;
    if (c.link(target.ptr, journal.ptr) != 0) return error.LinkFailed;
    try std.testing.expect((try support.runRestrictedCheck(@ptrCast(&db.path))).status != 0);
    try expectUntouched(target.ptr);
}

test "restricted WAL and shm symlinks are rejected" {
    try probe();
    var db = try fixture();
    defer db.deinit();
    const conn = try open(&db);
    defer _ = sqlite3_close(conn);
    try exec(conn, "PRAGMA journal_mode=WAL; INSERT INTO data VALUES ('wal')");
    try db.expectValue("PRAGMA journal_mode", "wal");
    var target_buf: [350]u8 = undefined;
    const target = try sibling(&db, &target_buf, "unrelated");
    try targetFile(target.ptr);
    defer _ = c.unlink(target.ptr);
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        var side_buf: [350]u8 = undefined;
        const side = try sidecar(&db, &side_buf, suffix);
        var saved_buf: [350]u8 = undefined;
        const saved = try std.fmt.bufPrintSentinel(&saved_buf, "{s}/saved{s}", .{ std.mem.sliceTo(&db.dir, 0), suffix }, 0);
        if (c.rename(side.ptr, saved.ptr) != 0) return error.RenameFailed;
        defer _ = c.rename(saved.ptr, side.ptr);
        if (c.symlink("unrelated", side.ptr) != 0) return error.SymlinkFailed;
        defer _ = c.unlink(side.ptr);
        try std.testing.expect((try support.runRestrictedCheck(@ptrCast(&db.path))).status != 0);
        try expectUntouched(target.ptr);
    }
}

test "restricted read-only and confirmed writes in rollback and WAL modes" {
    try probe();
    for ([_]bool{ false, true }) |wal| {
        var db = try fixture();
        defer db.deinit();
        const conn = try open(&db);
        defer _ = sqlite3_close(conn);
        try exec(conn, if (wal) "PRAGMA journal_mode=WAL; INSERT INTO data VALUES ('setup')" else "PRAGMA journal_mode=DELETE; INSERT INTO data VALUES ('setup')");
        try db.expectValue("PRAGMA journal_mode", if (wal) "wal" else "delete");
        try std.testing.expectEqual(@as(c_int, 0), (try support.runRestrictedCheck(@ptrCast(&db.path))).status);
        const t = try support.Terminal.initRestricted(@ptrCast(&db.path), false);
        defer t.deinit();
        try t.send("iINSERT INTO data VALUES ('refused')\r", "Enter exactly one read-only SQL statement");
        try t.send(":set rw\r", "Enable write mode");
        try t.send("y", "Write mode enabled");
        try t.send("i\x15INSERT INTO data VALUES ('confirmed')\r", "Execute this database write?");
        try t.send("n", "Cancelled");
        try db.expectValue("SELECT count(*) FROM data WHERE value='confirmed'", "0");
        try t.send("i\r", "Execute this database write?");
        try t.send("y", "Write committed");
        try db.expectValue("SELECT count(*) FROM data WHERE value='confirmed'", "1");
        try t.send(":set ro\r", "Read-only mode enabled");
        try t.quit();
    }
}

test "restricted hot journal recovery requires confirmation" {
    try probe();
    var db = try fixture();
    defer db.deinit();
    try db.exec("DELETE FROM data; WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<200) INSERT INTO data SELECT printf('%.*c', 4000, 'A') FROM n");
    try makeHot(&db);
    var journal_buf: [350]u8 = undefined;
    const journal = try sidecar(&db, &journal_buf, "-journal");
    const before_db = try digest(@ptrCast(&db.path));
    const before_journal = try digest(journal.ptr);
    try std.testing.expect((try support.runRestrictedCheck(@ptrCast(&db.path))).status != 0);
    {
        const t = try support.Terminal.initRestricted(@ptrCast(&db.path), true);
        defer t.deinit();
        try t.write("n");
        try std.testing.expectEqual(@as(c_int, 0), try t.waitExit());
    }
    try std.testing.expectEqual(before_db, try digest(@ptrCast(&db.path)));
    try std.testing.expectEqual(before_journal, try digest(journal.ptr));
    {
        const t = try support.Terminal.initRestricted(@ptrCast(&db.path), true);
        defer t.deinit();
        try t.send("y", "Recovery check completed");
        try std.testing.expectEqual(@as(c_int, 0), try t.waitExit());
    }
    try db.expectValue("SELECT count(*) FROM data WHERE substr(value,1,1)='A'", "200");
    try std.testing.expectEqual(@as(c_int, 0), (try support.runRestrictedCheck(@ptrCast(&db.path))).status);
}
