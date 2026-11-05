const std = @import("std");
const support = @import("terminal_support.zig");
const c = std.c;

fn milliseconds(start: c.timespec, end: c.timespec) f64 {
    return @as(f64, @floatFromInt(end.sec - start.sec)) * 1000.0 +
        @as(f64, @floatFromInt(end.nsec - start.nsec)) / 1_000_000.0;
}

// Run against a selected executable with ZSQT_TEST_EXE. Timings are reported,
// not asserted, because terminal scheduling and storage vary between hosts.
test "benchmark repeated forward search near the end of a large table" {
    var db = try support.Fixture.init(
        "CREATE TABLE data(c0 TEXT,c1 TEXT,c2 TEXT,c3 TEXT,c4 TEXT,c5 TEXT,c6 TEXT,c7 TEXT,c8 TEXT,c9 TEXT,c10 TEXT,c11 TEXT);" ++
            "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<373781) " ++
            "INSERT INTO data SELECT CASE WHEN i BETWEEN 373700 AND 373721 THEN 'target' ELSE 'ordinary' END, " ++
            "'abcdefghijklmnopqrstuvwxyz012345','abcdefghijklmnopqrstuvwxyz012345','abcdefghijklmnopqrstuvwxyz012345'," ++
            "'abcdefghijklmnopqrstuvwxyz012345','abcdefghijklmnopqrstuvwxyz012345','abcdefghijklmnopqrstuvwxyz012345'," ++
            "'abcdefghijklmnopqrstuvwxyz012345','abcdefghijklmnopqrstuvwxyz012345','abcdefghijklmnopqrstuvwxyz012345'," ++
            "'abcdefghijklmnopqrstuvwxyz012345','abcdefghijklmnopqrstuvwxyz012345' FROM n;",
    );
    defer db.deinit();
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    var start: c.timespec = undefined;
    var end: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &start) != 0) return error.ClockFailed;
    try t.send("/target\r", "Row 373700  Column 1/12");
    if (c.clock_gettime(.MONOTONIC, &end) != 0) return error.ClockFailed;
    const first_ms = milliseconds(start, end);
    var total_ms: f64 = 0;
    for (373701..373706) |row| {
        var needle: [80]u8 = undefined;
        const expected = try std.fmt.bufPrint(&needle, "Row {d}  Column 1/12", .{row});
        if (c.clock_gettime(.MONOTONIC, &start) != 0) return error.ClockFailed;
        try t.send("n", expected);
        if (c.clock_gettime(.MONOTONIC, &end) != 0) return error.ClockFailed;
        total_ms += milliseconds(start, end);
    }
    var previous_ms: f64 = 0;
    for (0..5) |i| {
        var needle: [80]u8 = undefined;
        const expected = try std.fmt.bufPrint(&needle, "Row {d}  Column 1/12", .{@as(usize, 373704) - i});
        if (c.clock_gettime(.MONOTONIC, &start) != 0) return error.ClockFailed;
        try t.send("N", expected);
        if (c.clock_gettime(.MONOTONIC, &end) != 0) return error.ClockFailed;
        previous_ms += milliseconds(start, end);
    }
    std.debug.print("Initial: {d:.1} ms; mean next: {d:.1} ms; mean previous: {d:.1} ms\n", .{ first_ms, total_ms / 5, previous_ms / 5 });
    try t.quit();
}
