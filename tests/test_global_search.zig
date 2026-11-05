const std = @import("std");
const support = @import("terminal_support.zig");

fn searchFixture() !support.Fixture {
    var db = try support.Fixture.init(
        "CREATE TABLE data(c0 TEXT,c1 TEXT,c2 TEXT,c3 TEXT,c4 TEXT,c5 TEXT,c6 TEXT,c7 TEXT,c8 TEXT,c9 TEXT,c10 TEXT,c11 TEXT,c12 TEXT,c13 TEXT,c14 TEXT,c15 TEXT,c16 TEXT,c17 TEXT,c18 TEXT,c19 TEXT,c20 TEXT,c21 TEXT,c22 TEXT,c23 TEXT,c24 TEXT,c25 TEXT,c26 TEXT,c27 TEXT,c28 TEXT,c29 TEXT,c30 TEXT,c31 TEXT,c32 TEXT,c33 TEXT,c34 TEXT,c35 TEXT,c36 TEXT,c37 TEXT,c38 TEXT,c39 TEXT);" ++
            "WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<1100) " ++
            "INSERT INTO data(c0) SELECT printf('row-%d',i) FROM n;" ++
            "UPDATE data SET c39=replace(hex(zeroblob(150)),'0','x')||'needle' WHERE rowid=502;" ++
            "UPDATE data SET c39='needle' WHERE rowid=1101;",
    );
    errdefer db.deinit();
    for (0..130) |i| {
        var buffer: [80]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buffer, "CREATE TABLE tab{d:0>3}(value);\x00", .{i});
        try db.exec(@ptrCast(sql.ptr));
    }
    return db;
}

test "row search crosses pages and columns and wraps" {
    var db = try searchFixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send("/needle\r", "Match found");
    try t.wait("Row 502  Column 40/40", 0);
    try t.send("n", "Row 1101  Column 40/40");
    try t.send("n", "Row 502  Column 40/40");
    try t.send("N", "Row 1101  Column 40/40");
    const start = t.len;
    try t.send("/does-not-exist\r", "No match");
    try t.wait("Row 1101  Column 40/40", start);
    try t.quit();
}

test "query and table name search" {
    var db = try searchFixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("/tab129\r", "Match found");
    try t.wait("> tab129", 0);
    try t.send(":reload\r", "Database reloaded");
    try t.send("/data\r", "Match found");
    try t.send("iSELECT c0, c39 FROM data ORDER BY rowid\r", "Read-only query results");
    try t.send("/needle\r", "Match found");
    try t.wait("Row 502  Column 2/2", 0);
    try t.send("n", "Row 1101  Column 2/2");
    try t.send("N", "Row 502  Column 2/2");
    try t.quit();
}

test "search last column at SQLite limit" {
    var db = try support.Fixture.init("CREATE TABLE placeholder(v)");
    defer db.deinit();
    var sql: [40000]u8 = undefined;
    var len: usize = 0;
    const first = "CREATE TABLE wide(";
    @memcpy(sql[0..first.len], first);
    len += first.len;
    for (0..2000) |i| {
        const part = try std.fmt.bufPrint(sql[len..], "{s}c{d} TEXT", .{ if (i == 0) @as([]const u8, "") else ",", i });
        len += part.len;
    }
    const end = "); INSERT INTO wide(c1999) VALUES ('last-column');\x00";
    @memcpy(sql[len..][0..end.len], end);
    try db.exec(@ptrCast(&sql));
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("j", "> wide");
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send("/last-column\r", "Row 1  Column 2000/2000");
    try t.wait("last-column", 0);
    try t.quit();
}

test "interrupted search does not report no match" {
    var db = try searchFixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("iWITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT x FROM n\r", "Read-only query results");
    try t.send("/not-present\r", "interrupted");
    try std.testing.expect(std.mem.indexOf(u8, t.output[0..t.len], "No match") == null);
    try t.quit();
}

test "search without rowid in write mode" {
    var db = try support.Fixture.init(
        "CREATE TABLE data(k TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;" ++
            "WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<799) " ++
            "INSERT INTO data SELECT printf('key-%04d',i), CASE WHEN i=700 THEN 'target' ELSE 'other' END FROM n;",
    );
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send(":set rw\r", "Enable write mode");
    try t.send("y", "Write mode enabled");
    try t.send("\t", "[RW] NORMAL | ROWS");
    try t.send("/target\r", "Row 701  Column 2/2");
    try t.send("e", "CELL> target");
    try t.send("\x15changed\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT value FROM data WHERE k='key-0700'", "changed");
    try t.quit();
}

test "page buttons and centered resize warning" {
    var db = try searchFixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send("\x1b[<0;29;2M", "Row 501");
    try t.send("\x1b[<0;25;2M", "Row 1  Column 1/40");
    try t.resize(35, 10, "\x1b[5;1HResize terminal to at least 40 x 12");
    const start = t.len;
    try t.resize(20, 7, "\x1b[3;2HResize terminal to");
    try t.wait("\x1b[4;3Hat least 40 x 12", start);
    try t.quit();
}

test "write mode search retains edit key" {
    var db = try searchFixture();
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send(":set rw\r", "Enable write mode");
    try t.send("y", "Write mode enabled");
    try t.send("\t", "[RW] NORMAL | ROWS");
    try t.send("/needle\r", "Row 502  Column 40/40");
    try t.send("n", "Row 1101  Column 40/40");
    try t.send("e", "CELL> needle");
    try t.send("\x15changed\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT c39 FROM data WHERE rowid=1101", "changed");
    try t.quit();
}

test "next search finds a distant match in a wide table" {
    var db = try support.Fixture.init(
        "CREATE TABLE data(c0 TEXT,c1 TEXT,c2 TEXT,c3 TEXT,c4 TEXT,c5 TEXT,c6 TEXT,c7 TEXT,c8 TEXT,c9 TEXT,c10 TEXT,c11 TEXT,c12 TEXT,c13 TEXT,c14 TEXT,c15 TEXT,c16 TEXT,c17 TEXT,c18 TEXT,c19 TEXT,c20 TEXT,c21 TEXT,c22 TEXT,c23 TEXT,c24 TEXT,c25 TEXT,c26 TEXT,c27 TEXT,c28 TEXT,c29 TEXT,c30 TEXT,c31 TEXT,c32 TEXT,c33 TEXT,c34 TEXT,c35 TEXT,c36 TEXT,c37 TEXT,c38 TEXT,c39 TEXT);" ++
            "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<40000) " ++
            "INSERT INTO data(c0) SELECT CASE WHEN i IN (2,39000) THEN 'target' ELSE 'other' END FROM n;",
    );
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send("/target\r", "Row 2  Column 1/40");
    try t.send("n", "Row 39000  Column 1/40");
    try t.send("n", "Row 2  Column 1/40");
    try t.send("N", "Row 39000  Column 1/40");
    try t.send("iSELECT * FROM data\r", "Read-only query results");
    try t.send("/target\r", "Row 2  Column 1/40");
    try t.send("n", "Row 39000  Column 1/40");
    try t.send(":reload\r", "Database reloaded");
    try t.send(":set rw\r", "Enable write mode");
    try t.send("y", "Write mode enabled");
    try t.send("/target\r", "Row 2  Column 1/40");
    try t.send("n", "Row 39000  Column 1/40");
    try t.send("e", "CELL> target");
    try t.send("\x15updated\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT c0 FROM data WHERE rowid=39000", "updated");
    try t.quit();
}

test "table search skips oversized names across page boundaries" {
    var db = try searchFixture();
    defer db.deinit();
    var sql: [4300]u8 = undefined;
    const prefix = "CREATE TABLE \"a";
    @memcpy(sql[0..prefix.len], prefix);
    @memset(sql[prefix.len .. prefix.len + 4096], 'x');
    const suffix = "\"(value);\x00";
    @memcpy(sql[prefix.len + 4096 ..][0..suffix.len], suffix);
    try db.exec(@ptrCast(&sql));
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("/tab129\r", "> tab129");
    try t.send("N", "> tab129");
    try t.quit();
}

test "search treats SQL syntax in data as text" {
    var db = try support.Fixture.init("CREATE TABLE data(value TEXT); INSERT INTO data VALUES ('plain'), ('needle'' OR 1=1--');");
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send("/needle' OR 1=1--\r", "Row 2  Column 1/1");
    try t.quit();
    try db.expectValue("SELECT count(*) FROM data", "2");
}
