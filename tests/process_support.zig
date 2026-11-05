const std = @import("std");
const c = std.c;
extern "c" fn execvp([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn prctl(c_int, ...) c_int;
extern "c" fn _exit(c_int) noreturn;

pub const Result = struct {
    stdout: [32768]u8 = undefined,
    stdout_len: usize = 0,
    stderr: [32768]u8 = undefined,
    stderr_len: usize = 0,
    status: c_int = 0,

    pub fn out(self: *const Result) []const u8 {
        return self.stdout[0..self.stdout_len];
    }
    pub fn err(self: *const Result) []const u8 {
        return self.stderr[0..self.stderr_len];
    }
};

pub const Options = struct {
    cwd: ?[*:0]const u8 = null,
    home: ?[*:0]const u8 = null,
    restricted: bool = false,
    timeout_seconds: i64 = 15,
};

const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
const SockProgram = extern struct { len: u16, filter: [*]const SockFilter };

pub fn restrictSyscalls() bool {
    const core_limit: c.rlimit = .{ .cur = 0, .max = 0 };
    if (c.setrlimit(.CORE, &core_limit) != 0) return false;
    const rules = [_]SockFilter{
        .{ .code = 0x20, .jt = 0, .jf = 0, .k = 0 },
        .{ .code = 0x15, .jt = 0, .jf = 1, .k = 437 },
        .{ .code = 0x06, .jt = 0, .jf = 0, .k = 0x00030000 },
        .{ .code = 0x15, .jt = 0, .jf = 1, .k = 439 },
        .{ .code = 0x06, .jt = 0, .jf = 0, .k = 0x00030000 },
        .{ .code = 0x15, .jt = 0, .jf = 1, .k = 452 },
        .{ .code = 0x06, .jt = 0, .jf = 0, .k = 0x00030000 },
        .{ .code = 0x06, .jt = 0, .jf = 0, .k = 0x7fff0000 },
    };
    const prog = SockProgram{ .len = rules.len, .filter = &rules };
    if (prctl(38, @as(usize, 1), @as(usize, 0), @as(usize, 0), @as(usize, 0)) != 0) return false;
    return prctl(22, @as(usize, 2), @intFromPtr(&prog), @as(usize, 0), @as(usize, 0)) == 0;
}

pub fn run(argv: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8) !Result {
    return runWithOptions(argv, .{ .cwd = cwd });
}

pub fn runWithOptions(argv: [*:null]const ?[*:0]const u8, options: Options) !Result {
    var stdout_pipe: [2]c_int = undefined;
    var stderr_pipe: [2]c_int = undefined;
    if (c.pipe(&stdout_pipe) != 0) return error.PipeFailed;
    if (c.pipe(&stderr_pipe) != 0) {
        for (stdout_pipe) |fd| _ = c.close(fd);
        return error.PipeFailed;
    }
    const pid = c.fork();
    if (pid < 0) {
        for (stdout_pipe) |fd| _ = c.close(fd);
        for (stderr_pipe) |fd| _ = c.close(fd);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = c.close(stdout_pipe[0]);
        _ = c.close(stderr_pipe[0]);
        if (c.dup2(stdout_pipe[1], 1) < 0 or c.dup2(stderr_pipe[1], 2) < 0) _exit(127);
        _ = c.close(stdout_pipe[1]);
        _ = c.close(stderr_pipe[1]);
        if (options.cwd) |dir| if (c.chdir(dir) != 0) _exit(127);
        if (options.home) |home| if (setenv("HOME", home, 1) != 0) _exit(127);
        if (setenv("GIT_CONFIG_NOSYSTEM", "1", 1) != 0 or
            setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1) != 0 or
            setenv("GIT_TERMINAL_PROMPT", "0", 1) != 0) _exit(127);
        if (options.restricted and !restrictSyscalls()) _exit(77);
        _ = execvp(argv[0] orelse _exit(127), argv);
        _exit(127);
    }
    _ = c.close(stdout_pipe[1]);
    _ = c.close(stderr_pipe[1]);
    defer _ = c.close(stdout_pipe[0]);
    defer _ = c.close(stderr_pipe[0]);
    var finished = false;
    defer if (!finished) {
        _ = c.kill(pid, .KILL);
        _ = c.waitpid(pid, null, 0);
    };
    var result: Result = .{};
    var started: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &started) != 0) return error.ClockFailed;
    var fds = [_]c.pollfd{
        .{ .fd = stdout_pipe[0], .events = c.POLL.IN, .revents = 0 },
        .{ .fd = stderr_pipe[0], .events = c.POLL.IN, .revents = 0 },
    };
    var open: usize = 2;
    while (open > 0) {
        var now: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &now) != 0) return error.ClockFailed;
        if (now.sec - started.sec >= options.timeout_seconds) return error.ChildTimeout;
        const ready = c.poll(&fds, fds.len, 100);
        if (ready < 0) {
            if (c.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }
        for (&fds, 0..) |*fd, index| {
            if (fd.fd < 0 or fd.revents == 0) continue;
            const buffer = if (index == 0) &result.stdout else &result.stderr;
            const len = if (index == 0) &result.stdout_len else &result.stderr_len;
            if (len.* == buffer.len) return error.OutputTooLong;
            const n = c.read(fd.fd, buffer[len.*..].ptr, buffer.len - len.*);
            if (n == 0) {
                fd.fd = -1;
                open -= 1;
            } else if (n < 0) {
                if (c.errno(n) != .INTR) return error.ReadFailed;
            } else len.* += @intCast(n);
        }
    }
    while (true) {
        const waited = c.waitpid(pid, &result.status, c.W.NOHANG);
        if (waited == pid) break;
        if (waited < 0 and c.errno(waited) != .INTR) return error.WaitFailed;
        var now: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &now) != 0) return error.ClockFailed;
        if (now.sec - started.sec >= options.timeout_seconds) return error.ChildTimeout;
        var idle = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
        _ = c.poll(&idle, 1, 50);
    }
    finished = true;
    return result;
}
