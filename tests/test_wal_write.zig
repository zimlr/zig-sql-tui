const std = @import("std");
const c = std.c;
const support = @import("terminal_support.zig");
const Db = opaque {};
extern fn sqlite3_open([*:0]const u8, *?*Db) c_int;
extern fn sqlite3_close(*Db) c_int;
extern fn sqlite3_exec(*Db, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*anyopaque) c_int;

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

fn enableWrites(t: *support.Terminal) !void {
    try t.send(":set rw\r", "Enable write mode");
    try t.send("y", "Write mode enabled");
}

test "WAL cell edit conflict and cancellation" {
    var db = try support.Fixture.init("SELECT 1");
    defer db.deinit();
    const conn = try open(&db);
    defer _ = sqlite3_close(conn);
    try exec(conn, "PRAGMA journal_mode=WAL; CREATE TABLE data(n TEXT, number INTEGER); INSERT INTO data VALUES ('one', 1)");
    try db.expectValue("PRAGMA journal_mode", "wal");
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try enableWrites(t);
    try t.send("\t", "[RW] NORMAL | ROWS");
    try t.send("e", "CELL> one");
    try t.send("\x15cancelled\r", "Save cell change?");
    try t.send("n", "Cancelled");
    try db.expectValue("SELECT n FROM data", "one");
    try t.send("e", "CELL> one");
    try t.send("\x15edited\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT n FROM data", "edited");
    try t.send("e", "CELL> edited");
    try t.send("\x15stale\r", "Save cell change?");
    try exec(conn, "UPDATE data SET n='outside'");
    try t.send("y", "Database changed. Reload before editing");
    try db.expectValue("SELECT n FROM data", "outside");
    try t.send("e", "CELL> outside");
    try t.send("\x15final\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT n FROM data", "final");
    try t.send("l", "Column 2/2");
    try t.send("e", "CELL> 1");
    try t.send("\x15bad\r", "Save cell change?");
    try t.send("y", "Enter a valid 64-bit integer");
    try db.expectValue("SELECT number FROM data", "1");
    try t.send("l", "Column 2/2");
    try t.send("e", "CELL> 1");
    try t.send("\x1512\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT printf('%d/%s', number, typeof(number)) FROM data", "12/integer");
    try t.quit();
}

test "WAL rowid shadowing and without rowid editing" {
    var db = try support.Fixture.init("SELECT 1");
    defer db.deinit();
    const conn = try open(&db);
    defer _ = sqlite3_close(conn);
    try exec(conn,
        \\PRAGMA journal_mode=WAL;
        \\CREATE TABLE a_shadow(rowid TEXT, _rowid_ TEXT, value TEXT);
        \\INSERT INTO a_shadow VALUES ('r1', 'x1', 'first'), ('r2', 'x2', 'second');
        \\CREATE TABLE b_no_rowid(id TEXT PRIMARY KEY, n TEXT) WITHOUT ROWID;
        \\INSERT INTO b_no_rowid VALUES ('a', 'protected');
    );
    try db.expectValue("PRAGMA journal_mode", "wal");
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try enableWrites(t);
    try t.send("\t", "[RW] NORMAL | ROWS");
    try t.send("j2l", "Column 3/3");
    try t.send("e", "CELL> second");
    try t.send("\x15changed\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT group_concat(rowid || ':' || value, ',') FROM (SELECT * FROM a_shadow ORDER BY rowid)", "r1:first,r2:changed");
    try t.send("\t\t", "[RW] NORMAL | TABLES");
    try t.send("j", "b_no_rowid");
    try t.send("\t", "[RW] NORMAL | ROWS");
    try t.send("l", "Column 2/2");
    try t.send("e", "CELL> protected");
    try t.send("\x15changed without rowid\r", "Save cell change?");
    try t.send("y", "Cell update committed");
    try db.expectValue("SELECT n FROM b_no_rowid", "changed without rowid");
    try t.quit();
}

test "WAL transactions and read only switch" {
    var db = try support.Fixture.init("SELECT 1");
    defer db.deinit();
    const conn = try open(&db);
    defer _ = sqlite3_close(conn);
    try exec(conn, "PRAGMA journal_mode=WAL; CREATE TABLE data(n TEXT UNIQUE); INSERT INTO data VALUES ('one')");
    try db.expectValue("PRAGMA journal_mode", "wal");
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send(":set rw\r", "Enable write mode");
    try t.send("n", "Cancelled");
    try db.expectValue("SELECT group_concat(n, ',') FROM (SELECT n FROM data ORDER BY n)", "one");
    try enableWrites(t);
    try std.testing.expect(std.mem.indexOf(u8, t.output[0..t.len], "[RW] NORMAL") != null);
    try t.send("iATTACH ':memory:' AS other\r", "Enter one permitted SQL statement");
    try t.send("i\x15INSERT INTO data VALUES ('two')\r", "Execute this database write? y/n");
    try t.send("n", "Cancelled");
    try db.expectValue("SELECT group_concat(n, ',') FROM (SELECT n FROM data ORDER BY n)", "one");
    try t.send("i\r", "Execute this database write? y/n");
    try t.send("y", "Write committed");
    try db.expectValue("SELECT group_concat(n, ',') FROM (SELECT n FROM data ORDER BY n)", "one,two");
    var input: [128]u8 = undefined;
    const query = "INSERT INTO data VALUES ('two')";
    const duplicate = "INSERT INTO data VALUES ('one')\r";
    input[0] = 'i';
    @memset(input[1..][0..query.len], 127);
    @memcpy(input[1 + query.len ..][0..duplicate.len], duplicate);
    try t.send(input[0 .. 1 + query.len + duplicate.len], "Execute this database write? y/n");
    try t.send("y", "UNIQUE constraint failed");
    try db.expectValue("SELECT group_concat(n, ',') FROM (SELECT n FROM data ORDER BY n)", "one,two");
    try exec(conn, "BEGIN IMMEDIATE");
    try t.send("i\x15INSERT INTO data VALUES ('three')\r", "Execute this database write? y/n");
    try t.send("y", "database is locked");
    try exec(conn, "ROLLBACK");
    try db.expectValue("SELECT group_concat(n, ',') FROM (SELECT n FROM data ORDER BY n)", "one,two");
    try t.send("i\r", "Execute this database write? y/n");
    try t.send("y", "Write committed");
    try db.expectValue("SELECT group_concat(n, ',') FROM (SELECT n FROM data ORDER BY n)", "one,three,two");
    try t.send(":set ro\r", "Read-only mode enabled");
    try std.testing.expect(std.mem.indexOf(u8, t.output[0..t.len], "[RO] NORMAL") != null);
    try t.send("i\r", "Enter exactly one read-only SQL statement");
    try t.quit();
}

test "clean WAL database opens read-only without sidecars" {
    var db = try support.Fixture.init("SELECT 1");
    defer db.deinit();
    const conn = try open(&db);
    try exec(conn, "PRAGMA journal_mode=WAL; CREATE TABLE data(n TEXT); INSERT INTO data VALUES ('closed')");
    try exec(conn, "PRAGMA wal_checkpoint(TRUNCATE)");
    _ = sqlite3_close(conn);
    var sidecar: [340]u8 = undefined;
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        const name = try std.fmt.bufPrint(&sidecar, "{s}{s}\x00", .{ std.mem.sliceTo(&db.path, 0), suffix });
        try std.testing.expectEqual(@as(c_int, -1), c.access(@ptrCast(name.ptr), c.F_OK));
    }
    const result = try support.runCheck(@ptrCast(&db.path));
    try std.testing.expectEqual(@as(c_int, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output[0..result.len], "Read-only database: 1 tables") != null);
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "ROWS: data");
    try std.testing.expect(std.mem.indexOf(u8, t.output[0..t.len], "closed") != null);
    try t.quit();
}

test "read-only sidecars are created owner-only" {
    var db = try support.Fixture.init("CREATE TABLE data(n TEXT); INSERT INTO data VALUES ('one')");
    defer db.deinit();
    try db.exec("PRAGMA journal_mode=WAL");
    var name_buffer: [340]u8 = undefined;
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        const name = try std.fmt.bufPrint(&name_buffer, "{s}{s}\x00", .{ std.mem.sliceTo(&db.path, 0), suffix });
        _ = c.unlink(@ptrCast(name.ptr));
    }
    const previous = c.umask(0);
    defer _ = c.umask(previous);
    const result = try support.runCheck(@ptrCast(&db.path));
    try std.testing.expectEqual(@as(c_int, 0), result.status);
    var seen: usize = 0;
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        const name = try std.fmt.bufPrint(&name_buffer, "{s}{s}\x00", .{ std.mem.sliceTo(&db.path, 0), suffix });
        var status: std.os.linux.Statx = undefined;
        if (c.statx(c.AT.FDCWD, @ptrCast(name.ptr), 0, .{ .MODE = true }, &status) != 0) continue;
        seen += 1;
        try std.testing.expectEqual(@as(u16, 0), status.mode & 0o077);
    }
    try std.testing.expect(seen > 0);
}
