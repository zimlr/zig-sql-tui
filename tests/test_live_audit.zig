const std = @import("std");
const c = std.c;
const support = @import("terminal_support.zig");

fn fixture() !support.Fixture {
    return support.Fixture.init("CREATE TABLE data(value TEXT); INSERT INTO data VALUES ('original')");
}

fn writeMode(t: *support.Terminal) !void {
    try t.send(":set rw\r", "Enable write mode");
    try t.send("y", "Write mode enabled");
}

test "malformed schema error cannot inject terminal controls" {
    var db = try fixture();
    defer db.deinit();
    try db.exec("PRAGMA writable_schema=ON; INSERT INTO sqlite_schema VALUES ('table', CAST(x'6576696C1B5D35323B633B6348647507' AS TEXT), CAST(x'6576696C1B5D35323B633B6348647507' AS TEXT), 0, 'CREATE TABLE \"broken\"(')");
    const result = try support.runCheck(@ptrCast(&db.path));
    const output = result.stderr[0..result.stderr_len];
    try std.testing.expect(result.status != 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, output, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, output, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\x1B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\x07") != null);
}

test "write confirmation is blocked below minimum size" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    try t.send("iINSERT INTO data VALUES ('new')\r", "Execute this database write?");
    try t.resize(35, 10, "Resize terminal");
    try t.send("y", "Resize terminal");
    try db.expectValue("SELECT group_concat(value, ',') FROM data", "original");
    try t.resize(100, 24, "Execute this database write?");
    try t.send("y", "Write committed");
    try db.expectValue("SELECT count(*) FROM data", "2");
    try t.quit();
}

test "arrow keys do not cancel SQL entry" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("iSELECT 42", "SQL> SELECT 42");
    try t.send("\x1b[D", "[RO] INSERT");
    try t.send("\r", "Read-only query results");
    try t.wait("[42]", 0);
    try t.quit();
}

test "fragmented escape sequence does not confirm write" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    try t.send("iINSERT INTO data VALUES ('new')\r", "Execute this database write?");
    try t.write("\x1b[");
    var idle = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
    _ = c.poll(&idle, 1, 250);
    try t.send("y", "Execute this database write?");
    try db.expectValue("SELECT group_concat(value, ',') FROM data", "original");
    try t.send("n", "Cancelled");
    try t.quit();
}

test "arrows search and commands" {
    var db = try fixture();
    defer db.deinit();
    try db.exec("INSERT INTO data VALUES ('match-one'), ('match-two')");
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send("\x1b[B", "[match-one]");
    try t.send("/match\r", "Match found");
    try std.testing.expect(std.mem.indexOf(u8, t.output[t.len -| 2000..t.len], "[match-two]") != null);
    try t.send("n", "Match found");
    try std.testing.expect(std.mem.indexOf(u8, t.output[t.len -| 2000..t.len], "[match-one]") != null);
    try t.send("N", "Match found");
    try std.testing.expect(std.mem.indexOf(u8, t.output[t.len -| 2000..t.len], "[match-two]") != null);
    try t.send(":reload\r", "Database reloaded");
    try t.send(":help\r", "HELP | Press any key");
    try t.send("x", "[RO] NORMAL");
    try t.send(":unknown\r", "Unknown command");
    try t.quit();
}

test "escape followed by quit does not drop key" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("iSELECT 42", "SQL> SELECT 42");
    try t.quitWith("\x1bq");
}

test "query error does not hide later page status" {
    var db = try fixture();
    defer db.deinit();
    try db.exec("WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<509) INSERT INTO data SELECT CAST(i AS TEXT) FROM n");
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("iSELECT * FROM missing_table\r", "no such table");
    try t.send("i\x15SELECT * FROM data\r", "Read-only query results");
    try t.send("]", "Row page changed");
    try t.quit();
}

test "rejects file and statement escape attempts" {
    var db = try fixture();
    defer db.deinit();
    var path_buffer: [320]u8 = undefined;
    const name = try std.fmt.bufPrint(&path_buffer, "{s}/victim.sqlite\x00", .{std.mem.sliceTo(&db.dir, 0)});
    const path: [*:0]const u8 = @ptrCast(name.ptr);
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateFailed;
    const content = "unrelated content";
    const written = c.write(fd, content.ptr, content.len);
    _ = c.close(fd);
    if (written != content.len) return error.WriteFailed;
    defer _ = c.unlink(path);
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    for ([_][]const u8{
        "ATTACH 'victim.sqlite' AS victim",
        "PRAGMA writable_schema=ON",
        "SELECT load_extension('victim.sqlite')",
        "SELECT 1; DELETE FROM data",
        "VACUUM INTO 'victim.sqlite'",
    }) |sql| {
        var input: [160]u8 = undefined;
        const text = try std.fmt.bufPrint(&input, "i\x15{s}\r", .{sql});
        if (std.mem.startsWith(u8, sql, "VACUUM")) {
            try t.send(text, "Execute this database write?");
            try t.send("y", "[RW] NORMAL");
        } else {
            try t.send(text, "[RW] NORMAL");
            try std.testing.expect(std.mem.indexOf(u8, t.output[t.len -| 500..t.len], "Execute this database write?") == null);
        }
    }
    const read_fd = c.open(path, .{});
    if (read_fd < 0) return error.OpenFailed;
    var data: [64]u8 = undefined;
    const size = c.read(read_fd, &data, data.len);
    _ = c.close(read_fd);
    if (size < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings(content, data[0..@intCast(size)]);
    try db.expectValue("SELECT group_concat(value, ',') FROM data", "original");
    try t.quit();
}
