const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const process = @import("process_support.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn realpath([*:0]const u8, [*]u8) ?[*:0]u8;
extern "c" fn syscall(c_long, ...) c_long;
const Db = opaque {};
extern fn sqlite3_open([*:0]const u8, *?*Db) c_int;
extern fn sqlite3_exec(*Db, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*anyopaque) c_int;
extern fn sqlite3_close(*Db) c_int;

fn output(fd: c_int, text: []const u8) void {
    var offset: usize = 0;
    while (offset < text.len) {
        const n = c.write(fd, text[offset..].ptr, text.len - offset);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) return;
        offset += @intCast(n);
    }
}

fn child(args: []const [*:0]const u8, restricted: bool) !process.Result {
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    if (args.len > 16) return error.TooManyArguments;
    for (args, 0..) |arg, i| argv[i] = arg;
    return process.runWithOptions(&argv, .{ .restricted = restricted, .timeout_seconds = 20 });
}

fn checked(args: []const [*:0]const u8) !process.Result {
    const result = try child(args, false);
    if (result.status != 0) {
        output(2, result.err());
        return error.SubprocessFailed;
    }
    return result;
}

fn save(path: [*:0]const u8, text: []const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var offset: usize = 0;
    while (offset < text.len) {
        const n = c.write(fd, text[offset..].ptr, text.len - offset);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn safeDirectory(fd: c_int) bool {
    var info: std.os.linux.Statx = undefined;
    const mask: std.os.linux.STATX = .{ .UID = true, .MODE = true };
    const rc = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, mask, &info);
    return rc == 0 and info.mask.UID and info.mask.MODE and info.uid == c.geteuid() and info.mode & 0o022 == 0;
}

fn prepareTemp() !void {
    if (c.mkdir(".zig-cache", 0o700) != 0 and c.errno(-1) != .EXIST) return error.MkdirFailed;
    const cache = c.open(".zig-cache", .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (cache < 0) return error.UnsafeTempDirectory;
    defer _ = c.close(cache);
    if (!safeDirectory(cache)) return error.UnsafeTempDirectory;
    if (c.mkdirat(cache, "tmp", 0o700) != 0 and c.errno(-1) != .EXIST) return error.MkdirFailed;
    const tmp = c.openat(cache, "tmp", .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (tmp < 0) return error.UnsafeTempDirectory;
    defer _ = c.close(tmp);
    if (!safeDirectory(tmp)) return error.UnsafeTempDirectory;
}

fn probe(source: [*:0]const u8, binary: [*:0]const u8) !bool {
    if (builtin.os.tag != .linux or (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64)) return error.UnsupportedPlatform;
    var source_buf: [4096]u8 = undefined;
    var binary_buf: [4096]u8 = undefined;
    const source_abs = realpath(source, &source_buf) orelse return error.SourceNotFound;
    const binary_abs = realpath(binary, &binary_buf) orelse return error.BinaryNotFound;
    try prepareTemp();
    var cwd_buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    var work_buf: [4600]u8 = undefined;
    _ = try std.fmt.bufPrintSentinel(&work_buf, "{s}/.zig-cache/tmp/termux-probe-XXXXXX", .{std.mem.sliceTo(cwd, 0)}, 0);
    if (mkdtemp(@ptrCast(&work_buf)) == null) return error.MkdtempFailed;
    const work = std.mem.sliceTo(&work_buf, 0);
    // The upstream script expands its own path and TERMUX_PREFIX without quotes.
    // Reject shell splitting or glob characters before running it.
    const result = if (std.mem.indexOfAny(u8, work, " \t\r\n*?[") != null)
        error.UnsafeUpstreamPath
    else
        probeWork(work, source_abs, binary_abs);
    const cleanup = try child(&.{ "rm", "-rf", "--", @ptrCast(&work_buf) }, false);
    if (cleanup.status != 0) return error.CleanupFailed;
    return result;
}

fn probeWork(work: []const u8, source_abs: [*:0]const u8, binary_abs: [*:0]const u8) !bool {
    var source_script_buf: [4600]u8 = undefined;
    const source_script = try std.fmt.bufPrintSentinel(&source_script_buf, "{s}/scripts/bin/check-pie.sh", .{std.mem.span(source_abs)}, 0);
    var scripts_buf: [4700]u8 = undefined;
    const scripts = try std.fmt.bufPrintSentinel(&scripts_buf, "{s}/scripts", .{work}, 0);
    var prefix_buf: [4700]u8 = undefined;
    const prefix = try std.fmt.bufPrintSentinel(&prefix_buf, "{s}/prefix", .{work}, 0);
    var bin_buf: [4800]u8 = undefined;
    const bin = try std.fmt.bufPrintSentinel(&bin_buf, "{s}/bin", .{prefix}, 0);
    _ = try checked(&.{ "mkdir", "-p", "--", scripts.ptr, bin.ptr });
    var script_buf: [4800]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(&script_buf, "{s}/check-pie.sh", .{scripts}, 0);
    var copy_buf: [4900]u8 = undefined;
    const copy = try std.fmt.bufPrintSentinel(&copy_buf, "{s}/zsqt", .{bin}, 0);
    _ = try checked(&.{ "cp", "-p", "--", source_script.ptr, script.ptr });
    _ = try checked(&.{ "cp", "-p", "--", binary_abs, copy.ptr });
    var properties_buf: [4800]u8 = undefined;
    const properties = try std.fmt.bufPrintSentinel(&properties_buf, "{s}/properties.sh", .{scripts}, 0);
    var content: [20000]u8 = undefined;
    var used: usize = 0;
    const start = "TERMUX_PREFIX='";
    @memcpy(content[0..start.len], start);
    used = start.len;
    for (prefix) |byte| {
        if (byte == '\'') {
            @memcpy(content[used..][0..4], "'\\''");
            used += 4;
        } else {
            content[used] = byte;
            used += 1;
        }
    }
    @memcpy(content[used..][0..2], "'\n");
    used += 2;
    try save(properties.ptr, content[0..used]);
    _ = try checked(&.{ "readelf", "-h", binary_abs });
    const pie = try checked(&.{ "bash", script.ptr });
    var ok = true;
    const trimmed = std.mem.trim(u8, pie.out(), " \t\n\r");
    var found_binary = false;
    var lines = std.mem.splitScalar(u8, pie.out(), '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, line, "zsqt")) {
        found_binary = true;
    };
    if (found_binary) {
        output(2, "FAIL: Termux check-pie reports a non-PIE executable\n");
        ok = false;
    } else if (trimmed.len > 0) {
        output(2, "FAIL: Unexpected check-pie output: ");
        output(2, trimmed);
        output(2, "\n");
        ok = false;
    } else output(1, "Termux check-pie did not report a non-PIE executable\n");
    var db_buf: [4800]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_buf, "{s}/sample.sqlite", .{work}, 0);
    var db: ?*Db = null;
    if (sqlite3_open(db_path.ptr, &db) != 0 or db == null) {
        if (db) |opened| _ = sqlite3_close(opened);
        return error.DatabaseOpenFailed;
    }
    const rc = sqlite3_exec(db.?, "CREATE TABLE data(value TEXT); INSERT INTO data VALUES ('sample')", null, null, null);
    _ = sqlite3_close(db.?);
    if (rc != 0) return error.DatabaseSetupFailed;
    const result = try child(&.{ binary_abs, "--check", db_path.ptr }, true);
    if (result.status != 0) {
        output(2, "FAIL: Application failed under the restricted syscall filter\n");
        output(2, result.err());
        ok = false;
    } else output(1, "Application opened the database with openat2, faccessat2 and fchmodat2 trapped\n");
    output(if (ok) 1 else 2, "This probe does not emulate Android or verify Termux app execution.\n");
    return ok;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.next();
    const first = args.next() orelse {
        output(2, "Usage: check-termux-candidate TERMUX_PACKAGES BINARY\n");
        return 2;
    };
    const second = args.next() orelse {
        output(2, "Usage: check-termux-candidate TERMUX_PACKAGES BINARY\n");
        return 2;
    };
    if (args.next() != null) return 2;
    if (std.mem.eql(u8, first, "--probe-filter")) {
        const number = std.fmt.parseInt(c_long, second, 10) catch return 2;
        if (number != 437 and number != 439 and number != 452) return 2;
        if (!process.restrictSyscalls()) return 77;
        _ = syscall(number, @as(c_long, -100), @as(usize, 0), @as(usize, 0), @as(usize, 0));
        return 1;
    }
    const result = probe(first.ptr, second.ptr) catch |err| {
        var buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "Termux probe failed: {s}\n", .{@errorName(err)}) catch "Termux probe failed\n";
        output(2, message);
        return 1;
    };
    return if (result) 0 else 1;
}
