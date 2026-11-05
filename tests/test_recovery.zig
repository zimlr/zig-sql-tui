const std = @import("std");
const c = std.c;
const support = @import("terminal_support.zig");
const Db = opaque {};
extern fn sqlite3_open([*:0]const u8, *?*Db) c_int;
extern fn sqlite3_exec(*Db, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*anyopaque) c_int;
extern "c" fn _exit(c_int) noreturn;

fn fixture() !support.Fixture {
    return support.Fixture.init(
        \\CREATE TABLE data(v TEXT);
        \\WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<200)
        \\INSERT INTO data SELECT printf('%.*c', 4000, 'A') FROM n;
    );
}

fn journalPath(db: *support.Fixture, buffer: []u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buffer, "{s}-journal", .{std.mem.sliceTo(&db.path, 0)}, 0);
}

fn makeHot(db: *support.Fixture) !void {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        var conn: ?*Db = null;
        if (sqlite3_open(@ptrCast(&db.path), &conn) != 0 or conn == null) _exit(1);
        if (sqlite3_exec(conn.?, "PRAGMA cache_size=4; BEGIN IMMEDIATE; UPDATE data SET v=replace(v,'A','B')", null, null, null) != 0) _exit(2);
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
    var path: [350]u8 = undefined;
    const journal = try journalPath(db, &path);
    const fd = c.open(journal.ptr, .{});
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try std.testing.expect(c.lseek(fd, 0, c.SEEK.END) > 0);
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

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

test "hot journal requires confirmed recovery" {
    var db = try fixture();
    defer db.deinit();
    try makeHot(&db);
    var buf: [350]u8 = undefined;
    const journal = try journalPath(&db, &buf);
    const before_db = try digest(@ptrCast(&db.path));
    const before_journal = try digest(journal.ptr);
    const check = try support.runCheck(@ptrCast(&db.path));
    try std.testing.expect(check.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, check.stderr[0..check.stderr_len], "--recover") != null);
    const unconfirmed = try support.runNonInteractive("--recover", @ptrCast(&db.path), "y\n");
    try std.testing.expect(unconfirmed.status != 0);
    try std.testing.expectEqual(before_db, try digest(@ptrCast(&db.path)));
    try std.testing.expectEqual(before_journal, try digest(journal.ptr));
    {
        const t = try support.Terminal.initRecovery(@ptrCast(&db.path));
        defer t.deinit();
        try t.write("n");
        try std.testing.expectEqual(@as(c_int, 0), try t.waitExit());
    }
    try std.testing.expectEqual(before_db, try digest(@ptrCast(&db.path)));
    try std.testing.expectEqual(before_journal, try digest(journal.ptr));
    {
        const t = try support.Terminal.initRecovery(@ptrCast(&db.path));
        defer t.deinit();
        try t.send("y", "Recovery check completed");
        try std.testing.expectEqual(@as(c_int, 0), try t.waitExit());
    }
    try db.expectValue("SELECT count(*) FROM data WHERE substr(v,1,1)='A'", "200");
    try std.testing.expectEqual(@as(c_int, 0), (try support.runCheck(@ptrCast(&db.path))).status);
}

test "recovery confirmation is blocked below minimum size" {
    var db = try fixture();
    defer db.deinit();
    try makeHot(&db);
    var buf: [350]u8 = undefined;
    const journal = try journalPath(&db, &buf);
    const before_db = try digest(@ptrCast(&db.path));
    const before_journal = try digest(journal.ptr);
    const t = try support.Terminal.initRecovery(@ptrCast(&db.path));
    defer t.deinit();
    try t.resize(35, 10, "Resize terminal");
    try t.send("y", "Resize terminal");
    try std.testing.expectEqual(before_db, try digest(@ptrCast(&db.path)));
    try std.testing.expectEqual(before_journal, try digest(journal.ptr));
    try t.resize(100, 24, "Recovery modifies");
    try t.send("y", "Recovery check completed");
    try std.testing.expectEqual(@as(c_int, 0), try t.waitExit());
}

test "superjournal recovery fails without accessing other files" {
    var db = try fixture();
    defer db.deinit();
    try makeHot(&db);
    var journal_buf: [350]u8 = undefined;
    const journal = try journalPath(&db, &journal_buf);
    var target_buf: [350]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&target_buf, "{s}/other-mj1234569AB", .{std.mem.sliceTo(&db.dir, 0)}, 0);
    const fd = c.open(target.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.unlink(target.ptr);
    {
        defer _ = c.close(fd);
        try writeAll(fd, "must remain untouched");
    }
    var cwd_buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    var name_buf: [4600]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ std.mem.sliceTo(cwd, 0), target });
    var checksum: u32 = 0;
    for (name) |byte| checksum +%= byte;
    var field: [4]u8 = undefined;
    const jf = c.open(journal.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true });
    if (jf < 0) return error.OpenFailed;
    {
        defer _ = c.close(jf);
        try writeAll(jf, &[_]u8{ 0, 0, 0, 0 });
        try writeAll(jf, name);
        std.mem.writeInt(u32, &field, @intCast(name.len), .big);
        try writeAll(jf, &field);
        std.mem.writeInt(u32, &field, checksum, .big);
        try writeAll(jf, &field);
        try writeAll(jf, &[_]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 });
    }
    const before_db = try digest(@ptrCast(&db.path));
    const before_journal = try digest(journal.ptr);
    const before_target = try digest(target.ptr);
    const t = try support.Terminal.initRecovery(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("y", "Recovery failed:");
    try std.testing.expect((try t.waitExit()) != 0);
    try std.testing.expectEqual(before_db, try digest(@ptrCast(&db.path)));
    try std.testing.expectEqual(before_journal, try digest(journal.ptr));
    try std.testing.expectEqual(before_target, try digest(target.ptr));
}

test "rollback writes require confirmation and are transactional" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send(":set rw\r", "Enable write mode");
    try t.send("y", "Write mode enabled");
    try t.send("\t", "[RW] NORMAL | ROWS");
    try t.send("e", "CELL> <");
    try t.send("\x15edited\r", "Save cell change?");
    try t.send("n", "Cancelled");
    try t.send("iUPDATE data SET v='changed' WHERE rowid=1\r", "Execute this database write?");
    try t.send("n", "Cancelled");
    try db.expectValue("SELECT substr(v,1,1) FROM data WHERE rowid=1", "A");
    try t.send("i\r", "Execute this database write?");
    try t.send("y", "Write committed");
    try db.expectValue("SELECT v FROM data WHERE rowid=1", "changed");
    try db.expectValue("PRAGMA journal_mode", "delete");
    var input: [400]u8 = undefined;
    const prefix = "i\x15UPDATE data SET v='long' WHERE rowid=2 /*";
    @memcpy(input[0..prefix.len], prefix);
    @memset(input[prefix.len..][0..300], 'x');
    @memcpy(input[prefix.len + 300 ..][0..3], "*/\r");
    try t.send(input[0 .. prefix.len + 303], "Execute this database write?");
    try t.send("y", "Write committed");
    try db.expectValue("SELECT v FROM data WHERE rowid=2", "long");
    try t.send("2j", "Row 3");
    try t.send("e", "CELL> <");
    try t.send("\x15edited long value\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT v FROM data WHERE rowid=3", "edited long value");
    try t.quit();
}

test "journal hardlink and symlink are rejected" {
    for ([_]bool{ false, true }) |symlink| {
        var db = try fixture();
        defer db.deinit();
        var journal_buf: [350]u8 = undefined;
        const journal = try journalPath(&db, &journal_buf);
        var target_buf: [350]u8 = undefined;
        const target = try std.fmt.bufPrintSentinel(&target_buf, "{s}/target", .{std.mem.sliceTo(&db.dir, 0)}, 0);
        const fd = c.open(target.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer _ = c.unlink(target.ptr);
        {
            defer _ = c.close(fd);
            try writeAll(fd, "not a journal");
        }
        if ((if (symlink) c.symlink("target", journal.ptr) else c.link(target.ptr, journal.ptr)) != 0) return error.LinkFailed;
        const before = try digest(target.ptr);
        try std.testing.expect((try support.runCheck(@ptrCast(&db.path))).status != 0);
        try std.testing.expectEqual(before, try digest(target.ptr));
    }
}
