const std = @import("std");
const support = @import("terminal_support.zig");

const composite_sql =
    \\CREATE TABLE data("k""odd" TEXT COLLATE NOCASE, b BLOB, value TEXT,
    \\PRIMARY KEY("k""odd" COLLATE BINARY, b)) WITHOUT ROWID;
    \\INSERT INTO data VALUES ('a',x'00','lower'),('A',x'00','upper');
;

fn writeMode(t: *support.Terminal) !void {
    try t.send(":set rw\r", "Enable write mode");
    try t.send("y", "Write mode enabled");
    try t.send("\t", "[RW] NORMAL | ROWS");
}

test "composite primary key and collation" {
    var db = try support.Fixture.init(composite_sql);
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    try t.send("2l", "Column 3/3");
    try t.send("e", "CELL> upper");
    try t.send("\x15updated\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT value FROM data WHERE \"k\"\"odd\" COLLATE BINARY='A'", "updated");
    try db.expectValue("SELECT value FROM data WHERE \"k\"\"odd\" COLLATE BINARY='a'", "lower");
    try t.send("2l", "Column 3/3");
    try t.send("e", "CELL> updated");
    try t.send("\x15stale\r", "Save cell change?");
    try db.exec("UPDATE data SET value='external' WHERE \"k\"\"odd\" COLLATE BINARY='A'");
    try t.send("y", "Database changed. Reload before editing");
    try db.expectValue("SELECT value FROM data WHERE \"k\"\"odd\" COLLATE BINARY='A'", "external");
    try t.send("l", "Column 2/3");
    try t.send("e", "BLOB hex> 00");
    try t.send("\x15ABCD\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT hex(b) FROM data WHERE \"k\"\"odd\" COLLATE BINARY='A'", "ABCD");
    try db.expectValue("SELECT hex(b) FROM data WHERE \"k\"\"odd\" COLLATE BINARY='a'", "00");
    try t.send("2l", "Column 3/3");
    try t.send(":null\r", "Set selected cell to NULL?");
    try t.send("y", "Cell update committed");
    try db.expectNull("SELECT value FROM data WHERE \"k\"\"odd\" COLLATE BINARY='A'");
    try db.expectValue("SELECT value FROM data WHERE \"k\"\"odd\" COLLATE BINARY='a'", "lower");
    try t.quit();
}

test "shadowed rowid uses nonnull primary key" {
    var db = try support.Fixture.init("CREATE TABLE data(rowid TEXT, _rowid_ TEXT, oid TEXT, k TEXT NOT NULL PRIMARY KEY, value TEXT); INSERT INTO data VALUES ('r','u','o','key','before')");
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    try t.send("4l", "Column 5/5");
    try t.send("e", "CELL> before");
    try t.send("\x15after\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT value FROM data WHERE k='key'", "after");
    try t.quit();
}

test "shadowed rowid with nullable key is not editable" {
    var db = try support.Fixture.init("CREATE TABLE data(rowid TEXT, _rowid_ TEXT, oid TEXT, k TEXT PRIMARY KEY, value TEXT); INSERT INTO data VALUES ('r','u','o',NULL,'first'),('r','u','o',NULL,'second')");
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    try t.send("4l", "Column 5/5");
    try t.send("e", "Select an editable table cell");
    try db.expectValue("SELECT group_concat(value, ',') FROM (SELECT value FROM data ORDER BY value)", "first,second");
    try t.quit();
}

test "descending key long value and blob" {
    var db = try support.Fixture.init("CREATE TABLE data(k INTEGER PRIMARY KEY DESC, value TEXT, blob BLOB) WITHOUT ROWID; INSERT INTO data VALUES (1,'one-'||replace(hex(zeroblob(150)),'0','x'),x'6f6e65'), (2,'two-'||replace(hex(zeroblob(150)),'0','y'),x'74776f')");
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    try t.send("l", "Column 2/3");
    try t.send("e", "CELL> <");
    try t.send("\x15first row\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try t.send("2l", "Column 3/3");
    try t.send("e", "BLOB hex> 6F6E65");
    try t.send("\x15CAFE\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT value FROM data WHERE k=1", "first row");
    try db.expectValue("SELECT hex(blob) FROM data WHERE k=1", "CAFE");
    try db.expectValue("SELECT value='two-'||replace(hex(zeroblob(150)),'0','y') FROM data WHERE k=2", "1");
    try db.expectValue("SELECT hex(blob) FROM data WHERE k=2", "74776F");
    try t.quit();
}

test "wide primary key falls back to read only cell view" {
    var db = try support.Fixture.init("CREATE TABLE placeholder(v)");
    defer db.deinit();
    var sql: [60000]u8 = undefined;
    var len: usize = 0;
    const start = "CREATE TABLE data(";
    @memcpy(sql[0..start.len], start);
    len += start.len;
    for (0..901) |i| {
        len += (try std.fmt.bufPrint(sql[len..], "{s}k{d} INTEGER NOT NULL", .{ if (i == 0) @as([]const u8, "") else ",", i })).len;
    }
    const pk = ",PRIMARY KEY(";
    @memcpy(sql[len..][0..pk.len], pk);
    len += pk.len;
    for (0..901) |i| {
        len += (try std.fmt.bufPrint(sql[len..], "{s}k{d}", .{ if (i == 0) @as([]const u8, "") else ",", i })).len;
    }
    const end = ")) WITHOUT ROWID;\x00";
    @memcpy(sql[len..][0..end.len], end);
    try db.exec(@ptrCast(&sql));
    len = 0;
    const insert = "INSERT INTO data VALUES (";
    @memcpy(sql[0..insert.len], insert);
    len += insert.len;
    for (0..901) |i| {
        const part = if (i == 0) "1" else ",1";
        @memcpy(sql[len..][0..part.len], part);
        len += part.len;
    }
    @memcpy(sql[len..][0..3], ");\x00");
    try db.exec(@ptrCast(&sql));
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    // The data table sorts before the placeholder table.
    try writeMode(t);
    try t.send("e", "Select an editable table cell");
    try t.quit();
}

test "later page targets correct primary key" {
    var db = try support.Fixture.init(composite_sql);
    defer db.deinit();
    try db.exec("WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<499) INSERT INTO data SELECT printf('k%04d',i),x'00',printf('row%d',i) FROM n");
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try writeMode(t);
    try t.send("]", "Row 501");
    try t.send("2l", "Column 3/3");
    try t.send("e", "CELL> row498");
    try t.send("\x15page edit\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT value FROM data WHERE \"k\"\"odd\"='k0498'", "page edit");
    try db.expectValue("SELECT value FROM data WHERE \"k\"\"odd\"='k0499'", "row499");
    try t.quit();
}
