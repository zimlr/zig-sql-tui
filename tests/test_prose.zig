const std = @import("std");
const c = std.c;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;

const Result = struct {
    output: [8192]u8,
    len: usize,
    exit_code: u8,
};

fn check(text: [*:0]const u8) !Result {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = c.close(fds[0]);
        if (c.dup2(fds[1], 1) < 0) _exit(127);
        _ = c.close(fds[1]);
        const tool = c.getenv("ZSQT_PROSE_TOOL") orelse "zig-out/test-bin/check-prose";
        const args = [_:null]?[*:0]const u8{ tool, "--text", text };
        _ = execvp(tool, &args);
        _exit(127);
    }
    _ = c.close(fds[1]);
    defer _ = c.close(fds[0]);
    var result: Result = .{ .output = undefined, .len = 0, .exit_code = 0 };
    while (result.len < result.output.len) {
        const n = c.read(fds[0], result.output[result.len..].ptr, result.output.len - result.len);
        if (n == 0) break;
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            _ = c.kill(pid, .KILL);
            _ = c.waitpid(pid, null, 0);
            return error.ReadFailed;
        }
        result.len += @intCast(n);
    }
    if (result.len == result.output.len) {
        _ = c.kill(pid, .KILL);
        _ = c.waitpid(pid, null, 0);
        return error.OutputTooLong;
    }
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0) {
        if (c.errno(-1) != .INTR) return error.WaitFailed;
    }
    if (status & 0x7f != 0) return error.ChildTerminated;
    result.exit_code = @intCast((status >> 8) & 0xff);
    return result;
}

test "flags prohibited prose" {
    const result = try check("We provide a bulletproof tool!\nIs this safe?\nUse this; continue.\n");
    try std.testing.expectEqual(1, result.exit_code);
    const output = result.output[0..result.len];
    for ([_][]const u8{ "1: prohibited", "2: prohibited", "3: prohibited" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
    }
}

test "ignores code and link targets" {
    const result = try check("Use `SELECT 1;` and [the reference](https://example.invalid/a?b=c).\n```sql\nSELECT 1;\n```\n");
    try std.testing.expectEqual(0, result.exit_code);
    try std.testing.expectEqual(0, result.len);
}

test "flags repeated sentence openings" {
    const invalid = try check("The reader opens a database. The reader displays its tables.\n");
    try std.testing.expectEqual(1, invalid.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, invalid.output[0..invalid.len], "repeated sentence opening") != null);
    const valid = try check("The reader opens a database. Tables remain visible.\n");
    try std.testing.expectEqual(0, valid.exit_code);
}

test "flags unclosed fences" {
    const result = try check("```sh\necho test\n");
    try std.testing.expectEqual(1, result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output[0..result.len], "unclosed code fence") != null);
}

test "matches Unicode boundaries and line separators" {
    const result = try check("Certaınly helpful.\rWe—work.\nHello.\u{a0}Hello again.\n");
    try std.testing.expectEqual(1, result.exit_code);
    const output = result.output[0..result.len];
    for ([_][]const u8{ "1: prohibited phrase: Certaınly", "2: prohibited punctuation: —", "2: prohibited phrase: We", "3: repeated sentence opening: hello" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
    }
}

test "fence lengths and inline code spans are respected" {
    const result = try check("````text\nThis; is you!\n```\nstill; ignored\n````\nUse ``you ` ;`` safely.\n");
    try std.testing.expectEqual(0, result.exit_code);
    try std.testing.expectEqual(0, result.len);
}

test "project scan checks Markdown and excludes vendored paths" {
    const process = @import("process_support.zig");
    const Native = struct {
        extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
    };
    var dir: [128]u8 = @splat(0);
    const template = ".zig-cache/tmp/prose-test-XXXXXX";
    @memcpy(dir[0..template.len], template);
    if (Native.mkdtemp(@ptrCast(&dir)) == null) return error.MkdtempFailed;
    defer {
        const cleanup = [_:null]?[*:0]const u8{ "rm", "-rf", "--", @ptrCast(&dir) };
        _ = process.run(&cleanup, null) catch {};
    }
    var vendor_buf: [200]u8 = undefined;
    const vendor = try std.fmt.bufPrintSentinel(&vendor_buf, "{s}/vendor", .{std.mem.sliceTo(&dir, 0)}, 0);
    if (c.mkdir(vendor.ptr, 0o700) != 0) return error.MkdirFailed;
    var ignored_buf: [220]u8 = undefined;
    const ignored = try std.fmt.bufPrintSentinel(&ignored_buf, "{s}/ignored.md", .{vendor}, 0);
    var main_buf: [220]u8 = undefined;
    const main = try std.fmt.bufPrintSentinel(&main_buf, "{s}/README.md", .{std.mem.sliceTo(&dir, 0)}, 0);
    for ([_]struct { path: [*:0]const u8, text: []const u8 }{ .{ .path = ignored.ptr, .text = "You!" }, .{ .path = main.ptr, .text = "Valid project prose.\n" } }) |file| {
        const fd = c.open(file.path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        const written = c.write(fd, file.text.ptr, file.text.len);
        _ = c.close(fd);
        if (written != file.text.len) return error.WriteFailed;
    }
    const tool = c.getenv("ZSQT_PROSE_TOOL") orelse "zig-out/test-bin/check-prose";
    const args = [_:null]?[*:0]const u8{ tool, "--root", @ptrCast(&dir) };
    const clean = try process.run(&args, null);
    try std.testing.expectEqual(@as(c_int, 0), clean.status);
    const fd = c.open(main.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true });
    if (fd < 0) return error.OpenFailed;
    const written = c.write(fd, "You!\n", 5);
    _ = c.close(fd);
    if (written != 5) return error.WriteFailed;
    const bad = try process.run(&args, null);
    try std.testing.expect(bad.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, bad.out(), "README.md:1: prohibited") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad.out(), "ignored.md") == null);
}
