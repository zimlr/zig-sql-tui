const std = @import("std");
const support = @import("terminal_support.zig");

fn pagingFixture() !support.Fixture {
    var db = try support.Fixture.init(
        "CREATE TABLE a_data(c0 TEXT,c1 TEXT,c2 TEXT,c3 TEXT,c4 TEXT,c5 TEXT,c6 TEXT,c7 TEXT,c8 TEXT,c9 TEXT,c10 TEXT,c11 TEXT,c12 TEXT,c13 TEXT,c14 TEXT,c15 TEXT,c16 TEXT,c17 TEXT,c18 TEXT,c19 TEXT,c20 TEXT,c21 TEXT,c22 TEXT,c23 TEXT,c24 TEXT,c25 TEXT,c26 TEXT,c27 TEXT,c28 TEXT,c29 TEXT,c30 TEXT,c31 TEXT,c32 TEXT,c33 TEXT,c34 TEXT,c35 TEXT,c36 TEXT,c37 TEXT,c38 TEXT,c39 TEXT);" ++
            "WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<500) " ++
            "INSERT INTO a_data SELECT printf('r%dc0',i),printf('r%dc1',i),printf('r%dc2',i),printf('r%dc3',i),printf('r%dc4',i),printf('r%dc5',i),printf('r%dc6',i),printf('r%dc7',i),printf('r%dc8',i),printf('r%dc9',i),printf('r%dc10',i),printf('r%dc11',i),printf('r%dc12',i),printf('r%dc13',i),printf('r%dc14',i),printf('r%dc15',i),printf('r%dc16',i),printf('r%dc17',i),printf('r%dc18',i),printf('r%dc19',i),printf('r%dc20',i),printf('r%dc21',i),printf('r%dc22',i),printf('r%dc23',i),printf('r%dc24',i),printf('r%dc25',i),printf('r%dc26',i),printf('r%dc27',i),printf('r%dc28',i),printf('r%dc29',i),printf('r%dc30',i),printf('r%dc31',i),printf('r%dc32',i),printf('r%dc33',i),printf('r%dc34',i),printf('r%dc35',i),printf('r%dc36',i),printf('r%dc37',i),printf('r%dc38',i),printf('r%dc39',i) FROM n;",
    );
    errdefer db.deinit();
    for (0..130) |i| {
        var buffer: [80]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buffer, "CREATE TABLE t{d:0>3}(value);\x00", .{i});
        try db.exec(@ptrCast(sql.ptr));
    }
    return db;
}

fn writeMode(t: *support.Terminal) !void {
    try t.send(":set rw\r", "Enable write mode");
    try t.send("y", "Write mode enabled");
    try t.send("\t", "[RW] NORMAL | ROWS");
}

test "table row and column pages and cell update" {
    var db = try pagingFixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("]", "t127");
    try t.send("[", "a_data");
    try writeMode(t);
    try t.send("]", "Row 501");
    try t.send(">", "Column 33/40");
    try t.send("e", "CELL> r500c32");
    try t.send("\x15changed\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT c32 FROM a_data WHERE rowid=501", "changed");
    try db.expectValue("SELECT c0 FROM a_data WHERE rowid=501", "r500c0");
    try t.quit();
}

test "full text detail scroll" {
    var db = try support.Fixture.init("CREATE TABLE data(value TEXT); INSERT INTO data VALUES(replace(hex(zeroblob(450)),'0','x')||'END-MARKER')");
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.wait("More below", 0);
    try t.send("\t\t", "[RO] NORMAL | DETAIL");
    try t.send("20j", "END-MARKER");
    try t.quit();
}

test "more than 128 columns" {
    var db = try support.Fixture.init("CREATE TABLE placeholder(value)");
    defer db.deinit();
    var buffer: [5000]u8 = undefined;
    var len: usize = 0;
    const start = "CREATE TABLE data(";
    @memcpy(buffer[0..start.len], start);
    len += start.len;
    for (0..150) |i| {
        len += (try std.fmt.bufPrint(buffer[len..], "{s}c{d} INTEGER", .{ if (i == 0) @as([]const u8, "") else ",", i })).len;
    }
    const end = "); INSERT INTO data(c128) VALUES (777);\x00";
    @memcpy(buffer[len..][0..end.len], end);
    try db.exec(@ptrCast(&buffer));
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send(">>>>", "Column 129/150");
    try t.wait("777", 0);
    try t.quit();
}

test "table name over 255 bytes" {
    const name = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    var buffer: [900]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buffer, "CREATE TABLE \"{s}\"(value); INSERT INTO \"{s}\" VALUES ('long name works');\x00", .{ name, name });
    var db = try support.Fixture.init(@ptrCast(sql.ptr));
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.wait("long name works", 0);
    try t.quit();
}

test "UTF-8 SQL and cell input" {
    var db = try support.Fixture.init("CREATE TABLE data(value TEXT); INSERT INTO data VALUES ('mañana')");
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.wait("ma\\u{F1}ana", 0);
    try writeMode(t);
    try t.send("e", "CELL>");
    try t.send("\x15世界\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT value FROM data", "世界");
    try t.send(":null\r", "Set selected cell to NULL?");
    try t.send("n", "Cancelled");
    try db.expectValue("SELECT value FROM data", "世界");
    try db.exec("UPDATE data SET value='external'");
    try t.send(":null\r", "Set selected cell to NULL?");
    try t.send("y", "Database changed. Reload before editing");
    try db.expectValue("SELECT value FROM data", "external");
    try t.send(":null\r", "Set selected cell to NULL?");
    try t.send("y", "Cell update committed");
    try db.expectNull("SELECT value FROM data");
    try t.send("e", "CELL>");
    try t.send("ñ\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT value FROM data", "ñ");
    try t.send("iSELECT 'mañana'\r", "Query results");
    try std.testing.expect(std.mem.indexOf(u8, t.output[0..t.len], "\\u{4E16}\\u{754C}") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.output[0..t.len], "世界") == null);
    try t.send("i\x15SELECT '\u{009b}2J\u{202e}'\r", "\\u{9B}2J\\u{202E}");
    try t.send("i\x15SELECT 'x世\x7f'\r", "[x]");
    try t.send("i\x15SELECT '\xff\r", "Invalid UTF-8");
    try t.send("\x1b", "[RW] NORMAL");
    try t.quit();
}

test "text control bytes are escaped and preserved" {
    var db = try support.Fixture.init("CREATE TABLE data(value TEXT); INSERT INTO data VALUES (CAST(x'7072656669781B5B324A' AS TEXT)), (CAST(x'77697468006E756C' AS TEXT))");
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.wait("prefix\\x1B[2J", 0);
    try writeMode(t);
    try t.send("e", "CELL> prefix\\x1B[2J");
    try t.send("x\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT hex(value) FROM data WHERE rowid=1", "7072656669781B5B324A78");
    try t.send("j", "with\\x00nul");
    try t.send("e", "Cell requires SQL editing");
    try db.expectValue("SELECT hex(value) FROM data WHERE rowid=2", "77697468006E756C");
    try t.quit();
}

test "blob hex editor" {
    var db = try support.Fixture.init("CREATE TABLE data(value BLOB); INSERT INTO data VALUES (x'00ff7a')");
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    try t.send("e", "BLOB hex> 00FF7A");
    try t.send("\x15GG\r", "Save cell change?");
    try t.send("y", "Enter an even number of hexadecimal digits");
    try db.expectValue("SELECT hex(value) FROM data", "00FF7A");
    try t.send("e", "BLOB hex> 00FF7A");
    try t.send("\x15\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT hex(value) FROM data", "");
    try db.expectValue("SELECT typeof(value) FROM data", "blob");
    try t.send("e", "BLOB hex>");
    try t.send("ABCDEF\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT hex(value) FROM data", "ABCDEF");
    try db.exec("UPDATE data SET value=zeroblob(2049)");
    try t.send(":reload\r", "Database reloaded");
    try t.send("e", "BLOB exceeds the hex editor limit");
    try db.expectValue("SELECT length(value) FROM data", "2049");
    try t.quit();
}

test "readonly query pages" {
    var db = try pagingFixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("iSELECT c0, c1 FROM a_data ORDER BY rowid\r", "Read-only query results");
    try t.send("]", "r500c0");
    try t.send("[", "r0c0");
    try t.quit();
}
