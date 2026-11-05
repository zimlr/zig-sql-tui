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
        const args = [_:null]?[*:0]const u8{ "python3", "tools/check_prose.py", "--text", text };
        _ = execvp("python3", &args);
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
