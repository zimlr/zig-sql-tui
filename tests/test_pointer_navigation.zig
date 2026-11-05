const std = @import("std");
const support = @import("terminal_support.zig");

const setup =
    \\CREATE TABLE a(value TEXT);
    \\WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<39)
    \\INSERT INTO a SELECT printf('item-%02d', i) FROM n;
;

fn fixture() !support.Fixture {
    return support.Fixture.init(setup);
}

test "home end page and buffered redraw" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    const start = t.len;
    try t.send("\x1b[F", "> [item-39]");
    try std.testing.expect(std.mem.indexOf(u8, t.output[start..t.len], "\x1b[2J") == null);
    try t.send("\x1b[H", "> [item-00]");
    try t.send("\x1b[6~", "> [item-17]");
    try t.send("\x1b[5~", "> [item-00]");
    try t.send("\x1b[4~", "> [item-39]");
    try t.send("\x1b[1~", "> [item-00]");
    try t.quit();
}

test "tap tabs items wheel and drag" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.resize(80, 24, "\x1b[3;12HROWS:");
    try t.send("\x1b[<0;11;2M", "[RO] NORMAL | ROWS");
    try t.send("\x1b[<0;14;8M", "> [item-03]");
    try t.send("\x1b[<64;14;8M", "> [item-02]");
    try t.send("\x1b[<65;14;8M", "> [item-03]");
    try t.send("\x1b[<0;14;8M", "> [item-03]");
    try t.send("\x1b[<32;14;5M", "> [item-04]");
    try t.send("\x1b[<0;14;5m", "> [item-04]");
    try t.send("\x1b[<0;3;2M", "[RO] NORMAL | TABLES");
    try t.quit();
}

test "narrow tabs and long mouse sequence" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.resize(40, 24, "Tab: panel");
    try t.send("\x1b[<0;10;2M", "[RO] NORMAL | ROWS");
    try t.send("\x1b[<0;4;6M", "> [item-01]");
    try t.send("\x1b[<9999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999;4;6M", "> [item-01]");
    try t.send("\x1b[<0;18;2M", "[RO] NORMAL | DETAIL");
    try t.send("\x1b[<0;3;2M", "[RO] NORMAL | TABLES");
    try t.quit();
}

test "mouse cannot confirm write" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send(":set rw\r", "Enable write mode");
    try t.send("\x1b[<0;5;22M", "Enable write mode");
    try t.send("n", "Cancelled");
    try std.testing.expect(std.mem.indexOf(u8, t.output[0..t.len], "[RW] NORMAL") == null);
    try t.quit();
}

test "command completion cycles matches and preserves unmatched input" {
    var db = try fixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send(":se", ":se");
    try t.send("\t", ":set ro");
    try t.send("\t", ":set readonly");
    try t.send("\t", ":set rw");
    try t.send("\t", ":set write");
    try t.send("\t", ":set ro");
    try t.send("\x15rel\t", ":reload");
    try t.send("\r", "Database reloaded");
    try t.send(":xyz\t", ":xyz");
    try t.send("\r", "Unknown command");
    try t.send(":set rw\t\r", "Enable write mode");
    try t.send("n", "Cancelled");
    try t.quit();
}
