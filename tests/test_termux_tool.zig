const std = @import("std");
const c = std.c;
const process = @import("process_support.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;

fn write(path: [*:0]const u8, text: []const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.write(fd, text.ptr, text.len) != text.len) return error.WriteFailed;
}

test "Termux probe rejects invalid ELF and unexpected PIE output" {
    if (c.mkdir(".zig-cache/tmp", 0o700) != 0 and c.errno(-1) != .EXIST) return error.MkdirFailed;
    var dir: [128]u8 = @splat(0);
    const template = ".zig-cache/tmp/termux-tool-XXXXXX";
    @memcpy(dir[0..template.len], template);
    if (mkdtemp(@ptrCast(&dir)) == null) return error.MkdtempFailed;
    defer {
        const args = [_:null]?[*:0]const u8{ "rm", "-rf", "--", @ptrCast(&dir) };
        _ = process.run(&args, null) catch {};
    }
    var scripts_buf: [200]u8 = undefined;
    const scripts = try std.fmt.bufPrintSentinel(&scripts_buf, "{s}/scripts", .{std.mem.sliceTo(&dir, 0)}, 0);
    if (c.mkdir(scripts.ptr, 0o700) != 0) return error.MkdirFailed;
    var bin_buf: [220]u8 = undefined;
    const bin = try std.fmt.bufPrintSentinel(&bin_buf, "{s}/bin", .{scripts}, 0);
    if (c.mkdir(bin.ptr, 0o700) != 0) return error.MkdirFailed;
    var pie_buf: [240]u8 = undefined;
    const pie = try std.fmt.bufPrintSentinel(&pie_buf, "{s}/check-pie.sh", .{bin}, 0);
    try write(pie.ptr, "#!/bin/sh\nexit 0\n");
    var invalid_buf: [200]u8 = undefined;
    const invalid = try std.fmt.bufPrintSentinel(&invalid_buf, "{s}/invalid", .{std.mem.sliceTo(&dir, 0)}, 0);
    try write(invalid.ptr, "not an ELF executable");
    const tool = c.getenv("ZSQT_TERMUX_PROBE") orelse "zig-out/test-bin/check-termux-candidate";
    const bad_args = [_:null]?[*:0]const u8{ tool, @ptrCast(&dir), invalid.ptr };
    const bad = try process.run(&bad_args, null);
    try std.testing.expect(bad.status != 0);
    try write(pie.ptr, "#!/bin/sh\necho zsqt\n");
    const exe = c.getenv("ZSQT_TEST_EXE") orelse "zig-out/test-bin/zsqt";
    const pie_args = [_:null]?[*:0]const u8{ tool, @ptrCast(&dir), exe };
    const non_pie = try process.run(&pie_args, null);
    try std.testing.expect(non_pie.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, non_pie.err(), "FAIL: Termux check-pie") != null);

    var unsafe_buf: [240]u8 = undefined;
    const unsafe_dir = try std.fmt.bufPrintSentinel(&unsafe_buf, "{s}/unsafe path", .{std.mem.sliceTo(&dir, 0)}, 0);
    if (c.mkdir(unsafe_dir.ptr, 0o700) != 0) return error.MkdirFailed;
    var cwd_buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const cwd_slice = std.mem.sliceTo(cwd, 0);
    var tool_buf: [5000]u8 = undefined;
    const tool_abs = if (tool[0] == '/') std.mem.span(tool) else try std.fmt.bufPrintSentinel(&tool_buf, "{s}/{s}", .{ cwd_slice, std.mem.span(tool) }, 0);
    var source_buf: [5000]u8 = undefined;
    const source_abs = try std.fmt.bufPrintSentinel(&source_buf, "{s}/{s}", .{ cwd_slice, std.mem.sliceTo(&dir, 0) }, 0);
    var exe_buf: [5000]u8 = undefined;
    const exe_abs = if (exe[0] == '/') std.mem.span(exe) else try std.fmt.bufPrintSentinel(&exe_buf, "{s}/{s}", .{ cwd_slice, std.mem.span(exe) }, 0);
    const unsafe_args = [_:null]?[*:0]const u8{ @ptrCast(tool_abs.ptr), source_abs.ptr, @ptrCast(exe_abs.ptr) };
    const result = try process.runWithOptions(&unsafe_args, .{ .cwd = unsafe_dir.ptr });
    try std.testing.expect(result.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.err(), "UnsafeUpstreamPath") != null);
    try std.testing.expectEqual(@as(usize, 0), result.out().len);

    var other_buf: [240]u8 = undefined;
    const other = try std.fmt.bufPrintSentinel(&other_buf, "{s}/other", .{std.mem.sliceTo(&dir, 0)}, 0);
    if (c.mkdir(other.ptr, 0o700) != 0) return error.MkdirFailed;
    var cache_buf: [260]u8 = undefined;
    const cache = try std.fmt.bufPrintSentinel(&cache_buf, "{s}/.zig-cache", .{other}, 0);
    if (c.symlink(source_abs.ptr, cache.ptr) != 0) return error.SymlinkFailed;
    const symlinked = try process.runWithOptions(&unsafe_args, .{ .cwd = other.ptr });
    try std.testing.expect(symlinked.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, symlinked.err(), "UnsafeTempDirectory") != null);
    if (c.unlink(cache.ptr) != 0 or c.mkdir(cache.ptr, 0o700) != 0 or c.chmod(cache.ptr, 0o777) != 0) return error.MkdirFailed;
    const writable = try process.runWithOptions(&unsafe_args, .{ .cwd = other.ptr });
    try std.testing.expect(writable.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, writable.err(), "UnsafeTempDirectory") != null);
    if (c.chmod(cache.ptr, 0o700) != 0) return error.ChmodFailed;
    var tmp_buf: [280]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}/tmp", .{cache}, 0);
    if (c.symlink(source_abs.ptr, tmp.ptr) != 0) return error.SymlinkFailed;
    const tmp_symlink = try process.runWithOptions(&unsafe_args, .{ .cwd = other.ptr });
    try std.testing.expect(tmp_symlink.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, tmp_symlink.err(), "UnsafeTempDirectory") != null);
}
