const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const process = @import("process_support.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;

fn productionExe() [*:0]const u8 {
    return c.getenv("ZSQT_TEST_EXE") orelse "zig-out/test-bin/zsqt";
}

fn debugExe() ![*:0]const u8 {
    return c.getenv("ZSQT_DEBUG_EXE") orelse productionExe();
}

fn run(args: []const [*:0]const u8, home: ?[*:0]const u8, restricted: bool) !process.Result {
    var argv: [12:null]?[*:0]const u8 = @splat(null);
    if (args.len > 12) return error.TooManyArguments;
    for (args, 0..) |arg, i| argv[i] = arg;
    return process.runWithOptions(&argv, .{ .home = home, .restricted = restricted, .timeout_seconds = 30 });
}

fn contains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Missing {s} in {s}\n", .{ needle, haystack });
        return error.MissingOutput;
    }
}

const Fixture = struct {
    base: [4096]u8 = @splat(0),
    home: [4200]u8 = @splat(0),
    config: [4300]u8 = @splat(0),
    user_db: [4300]u8 = @splat(0),

    fn init() !Fixture {
        if (c.mkdir(".zig-cache/tmp", 0o700) != 0 and c.errno(-1) != .EXIST) return error.MkdirFailed;
        var cwd_buf: [4096]u8 = undefined;
        const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
        var self: Fixture = .{};
        _ = try std.fmt.bufPrintSentinel(&self.base, "{s}/.zig-cache/tmp/diagnostics-XXXXXX", .{std.mem.sliceTo(cwd, 0)}, 0);
        if (mkdtemp(@ptrCast(&self.base)) == null) return error.MkdtempFailed;
        errdefer self.deinit();
        _ = try std.fmt.bufPrintSentinel(&self.home, "{s}/home", .{std.mem.sliceTo(&self.base, 0)}, 0);
        _ = try std.fmt.bufPrintSentinel(&self.config, "{s}/.zsqt", .{std.mem.sliceTo(&self.home, 0)}, 0);
        _ = try std.fmt.bufPrintSentinel(&self.user_db, "{s}/untouched.sqlite", .{std.mem.sliceTo(&self.home, 0)}, 0);
        if (c.mkdir(@ptrCast(&self.home), 0o700) != 0) return error.MkdirFailed;
        const fd = c.open(@ptrCast(&self.user_db), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        const n = c.write(fd, "do not modify", 13);
        _ = c.close(fd);
        if (n != 13) return error.WriteFailed;
        return self;
    }

    fn deinit(self: *Fixture) void {
        const args = [_:null]?[*:0]const u8{ "rm", "-rf", "--", @ptrCast(&self.base) };
        const result = process.run(&args, null) catch return;
        if (result.status != 0) std.debug.print("Temporary fixture cleanup failed: {s}\n", .{result.err()});
    }

    fn debug(self: *Fixture, args: []const [*:0]const u8, restricted: bool) !process.Result {
        var all: [8][*:0]const u8 = undefined;
        if (args.len > 7) return error.TooManyArguments;
        all[0] = try debugExe();
        @memcpy(all[1..][0..args.len], args);
        return run(all[0 .. args.len + 1], @ptrCast(&self.home), restricted);
    }

    fn unchanged(self: *Fixture) !void {
        const fd = c.open(@ptrCast(&self.user_db), .{});
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        var data: [32]u8 = undefined;
        const n = c.read(fd, &data, data.len);
        if (n < 0) return error.ReadFailed;
        try std.testing.expectEqualStrings("do not modify", data[0..@intCast(n)]);
    }

    fn noConfig(self: *Fixture) !void {
        try std.testing.expect(c.access(@ptrCast(&self.config), 0) != 0);
        try std.testing.expectEqual(c.E.NOENT, c.errno(-1));
    }

    fn emptyDir(path: [*:0]const u8) !void {
        const dir = c.opendir(path) orelse return error.OpenFailed;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |entry| {
            const name = std.mem.sliceTo(&entry.name, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) return error.DirectoryNotEmpty;
        }
    }

    fn passed(self: *Fixture, result: *const process.Result) !void {
        if (result.status != 0) std.debug.print("Diagnostics failed: {s}\n{s}\n", .{ result.out(), result.err() });
        try std.testing.expectEqual(@as(c_int, 0), result.status);
        for ([_][]const u8{ "ROLLBACK WRITE: PASS", "WAL: PASS", "RECOVERY: PASS", "CLEANUP: PASS", "RESULT: PASS" }) |message| try contains(result.out(), message);
        try self.unchanged();
        try emptyDir(@ptrCast(&self.config));
    }
};

test "debug appears in usage and rejects extra arguments" {
    const help = try run(&.{ productionExe(), "--help" }, null, false);
    try std.testing.expectEqual(@as(c_int, 0), help.status);
    try contains(help.out(), "--debug");
    try contains(help.out(), "disposable files");
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for ([_][]const [*:0]const u8{ &.{ "--debug", "extra" }, &.{ "--debug-test", "--confirm" } }) |args| {
        const result = try fixture.debug(args, false);
        try std.testing.expectEqual(@as(c_int, 2 << 8), result.status);
        try contains(result.err(), "Usage: zsqt");
        try fixture.noConfig();
    }
    try fixture.unchanged();
}

test "diagnostics self test and cleanup are repeatable" {
    _ = try debugExe();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for (0..2) |_| {
        const result = try fixture.debug(&.{"--debug"}, false);
        try fixture.passed(&result);
    }
}

test "diagnostics works under restricted syscalls" {
    _ = try debugExe();
    if (builtin.os.tag != .linux or (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64)) return error.SkipZigTest;
    const probe = try run(&.{"/bin/true"}, null, true);
    if (probe.status == 77 << 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), probe.status);
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const result = try fixture.debug(&.{"--debug"}, true);
    try fixture.passed(&result);
}

test "diagnostics rejects symlinked home and config" {
    _ = try debugExe();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var other_buf: [4300]u8 = undefined;
    const other = try std.fmt.bufPrintSentinel(&other_buf, "{s}/other", .{std.mem.sliceTo(&fixture.home, 0)}, 0);
    if (c.mkdir(other.ptr, 0o700) != 0) return error.MkdirFailed;
    if (c.symlink("other", @ptrCast(&fixture.config)) != 0) return error.SymlinkFailed;
    const config_result = try fixture.debug(&.{"--debug"}, false);
    try std.testing.expect(config_result.status != 0);
    try contains(config_result.out(), "SETUP: FAIL");
    try Fixture.emptyDir(other.ptr);
    try fixture.unchanged();
    if (c.unlink(@ptrCast(&fixture.config)) != 0) return error.UnlinkFailed;
    var alias_buf: [4300]u8 = undefined;
    const alias = try std.fmt.bufPrintSentinel(&alias_buf, "{s}/home-alias", .{std.mem.sliceTo(&fixture.base, 0)}, 0);
    if (c.symlink("home", alias.ptr) != 0) return error.SymlinkFailed;
    const result = try run(&.{ try debugExe(), "--debug" }, alias.ptr, false);
    try std.testing.expect(result.status != 0);
    try contains(result.out(), "SETUP: FAIL");
    try fixture.noConfig();
}

test "diagnostics rejects writable home" {
    _ = try debugExe();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (c.chmod(@ptrCast(&fixture.home), 0o777) != 0) return error.ChmodFailed;
    const result = try fixture.debug(&.{"--debug"}, false);
    try std.testing.expect(result.status != 0);
    try contains(result.out(), "SETUP: FAIL");
    try fixture.noConfig();
    try fixture.unchanged();
}

test "diagnostics rejects writable config" {
    _ = try debugExe();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    if (c.mkdir(@ptrCast(&fixture.config), 0o700) != 0 or c.chmod(@ptrCast(&fixture.config), 0o777) != 0) return error.MkdirFailed;
    const result = try fixture.debug(&.{"--debug"}, false);
    try std.testing.expect(result.status != 0);
    try contains(result.out(), "SETUP: FAIL");
    try Fixture.emptyDir(@ptrCast(&fixture.config));
    try fixture.unchanged();
}
