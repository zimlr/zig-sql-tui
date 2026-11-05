const std = @import("std");
const c = std.c;
const process = @import("process_support.zig");
extern "c" fn openpty(*c_int, *c_int, ?[*]u8, ?*anyopaque, ?*const std.posix.winsize) c_int;
extern "c" fn execv([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(c_int) noreturn;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
const Db = opaque {};
extern fn sqlite3_open([*:0]const u8, *?*Db) c_int;
extern fn sqlite3_exec(*Db, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*anyopaque) c_int;
extern fn sqlite3_close(*Db) c_int;
const Stmt = opaque {};
extern fn sqlite3_prepare_v2(*Db, [*:0]const u8, c_int, *?*Stmt, ?*?[*:0]const u8) c_int;
extern fn sqlite3_step(*Stmt) c_int;
extern fn sqlite3_column_text(*Stmt, c_int) ?[*:0]const u8;
extern fn sqlite3_finalize(*Stmt) c_int;

pub const Fixture = struct {
    dir: [256]u8 = @splat(0),
    path: [320]u8 = @splat(0),

    pub fn init(sql: [*:0]const u8) !Fixture {
        if (c.mkdir(".zig-cache/tmp", 0o700) != 0 and c.errno(-1) != .EXIST) return error.TempDirectoryFailed;
        var fixture: Fixture = .{};
        const template = ".zig-cache/tmp/zig-test-XXXXXX";
        @memcpy(fixture.dir[0..template.len], template);
        if (mkdtemp(@ptrCast(&fixture.dir)) == null) return error.MkdtempFailed;
        errdefer fixture.deinit();
        const path = try std.fmt.bufPrint(&fixture.path, "{s}/test.sqlite", .{std.mem.sliceTo(&fixture.dir, 0)});
        if (path.len == fixture.path.len) return error.PathTooLong;
        fixture.path[path.len] = 0;
        var db: ?*Db = null;
        if (sqlite3_open(@ptrCast(&fixture.path), &db) != 0 or db == null) {
            if (db) |opened| _ = sqlite3_close(opened);
            return error.DatabaseOpenFailed;
        }
        defer _ = sqlite3_close(db.?);
        if (sqlite3_exec(db.?, sql, null, null, null) != 0) return error.DatabaseSetupFailed;
        return fixture;
    }

    pub fn exec(self: *Fixture, sql: [*:0]const u8) !void {
        var db: ?*Db = null;
        if (sqlite3_open(@ptrCast(&self.path), &db) != 0 or db == null) {
            if (db) |opened| _ = sqlite3_close(opened);
            return error.DatabaseOpenFailed;
        }
        defer _ = sqlite3_close(db.?);
        if (sqlite3_exec(db.?, sql, null, null, null) != 0) return error.DatabaseSetupFailed;
    }

    pub fn expectValue(self: *Fixture, sql: [*:0]const u8, expected: []const u8) !void {
        var db: ?*Db = null;
        if (sqlite3_open(@ptrCast(&self.path), &db) != 0 or db == null) {
            if (db) |opened| _ = sqlite3_close(opened);
            return error.DatabaseOpenFailed;
        }
        defer _ = sqlite3_close(db.?);
        var stmt: ?*Stmt = null;
        if (sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != 0 or stmt == null) return error.PrepareFailed;
        defer _ = sqlite3_finalize(stmt.?);
        if (sqlite3_step(stmt.?) != 100) return error.MissingRow;
        const value = sqlite3_column_text(stmt.?, 0) orelse return error.MissingValue;
        try std.testing.expectEqualStrings(expected, std.mem.span(value));
    }

    pub fn expectNull(self: *Fixture, sql: [*:0]const u8) !void {
        var db: ?*Db = null;
        if (sqlite3_open(@ptrCast(&self.path), &db) != 0 or db == null) {
            if (db) |opened| _ = sqlite3_close(opened);
            return error.DatabaseOpenFailed;
        }
        defer _ = sqlite3_close(db.?);
        var stmt: ?*Stmt = null;
        if (sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != 0 or stmt == null) return error.PrepareFailed;
        defer _ = sqlite3_finalize(stmt.?);
        if (sqlite3_step(stmt.?) != 100) return error.MissingRow;
        try std.testing.expect(sqlite3_column_text(stmt.?, 0) == null);
    }

    pub fn deinit(self: *Fixture) void {
        if (self.path[0] != 0) {
            var sidecar: [340]u8 = undefined;
            for ([_][]const u8{ "-journal", "-wal", "-shm" }) |suffix| {
                const name = std.fmt.bufPrint(&sidecar, "{s}{s}\x00", .{ std.mem.sliceTo(&self.path, 0), suffix }) catch continue;
                _ = c.unlink(@ptrCast(name.ptr));
            }
            _ = c.unlink(@ptrCast(&self.path));
        }
        if (self.dir[0] != 0) _ = c.rmdir(@ptrCast(&self.dir));
    }
};

pub const Terminal = struct {
    master: c_int,
    pid: c.pid_t,
    exited: bool = false,
    output: [2 * 1024 * 1024]u8 = undefined,
    len: usize = 0,

    pub fn init(path: [*:0]const u8) !*Terminal {
        return initMode(path, false, false);
    }

    pub fn initRecovery(path: [*:0]const u8) !*Terminal {
        return initMode(path, true, false);
    }

    pub fn initRestricted(path: [*:0]const u8, recovery: bool) !*Terminal {
        return initMode(path, recovery, true);
    }

    fn initMode(path: [*:0]const u8, recovery: bool, restricted: bool) !*Terminal {
        const self = try std.testing.allocator.create(Terminal);
        errdefer std.testing.allocator.destroy(self);
        var master: c_int = undefined;
        var slave: c_int = undefined;
        const size = std.posix.winsize{ .row = 24, .col = 100, .xpixel = 0, .ypixel = 0 };
        if (openpty(&master, &slave, null, null, &size) != 0) return error.OpenPtyFailed;
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(master);
            _ = c.close(slave);
            return error.ForkFailed;
        }
        if (pid == 0) {
            _ = c.close(master);
            if (c.dup2(slave, 0) < 0 or c.dup2(slave, 1) < 0 or c.dup2(slave, 2) < 0) _exit(127);
            if (slave > 2) _ = c.close(slave);
            const binary = c.getenv("ZSQT_TEST_EXE") orelse "zig-out/test-bin/zsqt";
            if (restricted and !process.restrictSyscalls()) _exit(77);
            if (recovery) {
                const args = [_:null]?[*:0]const u8{ binary, "--recover", path };
                _ = execv(binary, &args);
            } else {
                const args = [_:null]?[*:0]const u8{ binary, path };
                _ = execv(binary, &args);
            }
            _exit(127);
        }
        _ = c.close(slave);
        self.master = master;
        self.pid = pid;
        self.exited = false;
        self.len = 0;
        self.wait(if (recovery) "Recovery modifies" else "[RO] NORMAL", 0) catch |err| {
            _ = c.kill(pid, .KILL);
            _ = c.waitpid(pid, null, 0);
            _ = c.close(master);
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        if (!self.exited) {
            _ = c.kill(self.pid, .KILL);
            _ = c.waitpid(self.pid, null, 0);
        }
        _ = c.close(self.master);
        std.testing.allocator.destroy(self);
    }

    pub fn wait(self: *Terminal, needle: []const u8, start: usize) !void {
        var start_time: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &start_time) != 0) return error.ClockFailed;
        while (std.mem.indexOf(u8, self.output[start..self.len], needle) == null) {
            var now: c.timespec = undefined;
            if (c.clock_gettime(.MONOTONIC, &now) != 0) return error.ClockFailed;
            if (now.sec - start_time.sec >= 8) {
                std.debug.print("Missing terminal output: {s}\n", .{needle});
                return error.TerminalTimeout;
            }
            if (self.len == self.output.len) return error.TerminalOutputFull;
            var fd = [_]c.pollfd{.{ .fd = self.master, .events = c.POLL.IN, .revents = 0 }};
            const ready = c.poll(&fd, 1, 100);
            if (ready < 0) {
                if (c.errno(ready) == .INTR) continue;
                return error.PollFailed;
            }
            if (ready == 0) continue;
            const n = c.read(self.master, self.output[self.len..].ptr, self.output.len - self.len);
            if (n <= 0) {
                std.debug.print("Terminal closed while waiting for {s}: {s}\n", .{ needle, self.output[self.len -| 2500..self.len] });
                return error.TerminalClosed;
            }
            self.len += @intCast(n);
        }
    }

    pub fn write(self: *Terminal, input: []const u8) !void {
        var offset: usize = 0;
        while (offset < input.len) {
            const n = c.write(self.master, input[offset..].ptr, input.len - offset);
            if (n < 0 and c.errno(n) == .INTR) continue;
            if (n <= 0) return error.TerminalWriteFailed;
            offset += @intCast(n);
        }
    }

    pub fn send(self: *Terminal, input: []const u8, needle: []const u8) !void {
        const start = self.len;
        try self.write(input);
        try self.wait(needle, start);
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16, needle: []const u8) !void {
        const start = self.len;
        const size = std.posix.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (c.ioctl(self.master, c.T.IOCSWINSZ, @intFromPtr(&size)) != 0) return error.ResizeFailed;
        if (c.kill(self.pid, .WINCH) != 0) return error.SignalFailed;
        try self.wait(needle, start);
    }

    pub fn quit(self: *Terminal) !void {
        try self.quitWith("q");
    }

    pub fn quitWith(self: *Terminal, keys: []const u8) !void {
        try self.send(keys, "\x1b[?1006l");
        try std.testing.expectEqual(@as(c_int, 0), try self.waitExit());
    }

    pub fn waitExit(self: *Terminal) !c_int {
        var status: c_int = 0;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            const result = c.waitpid(self.pid, &status, c.W.NOHANG);
            if (result == self.pid) {
                self.exited = true;
                return status;
            }
            if (result < 0) return error.WaitFailed;
            var idle = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = c.poll(&idle, 1, 100);
        }
        return error.ChildTimeout;
    }
};

pub const CheckResult = struct {
    output: [8192]u8 = undefined,
    len: usize = 0,
    stderr: [8192]u8 = undefined,
    stderr_len: usize = 0,
    status: c_int = 0,
};

pub fn runCheck(path: [*:0]const u8) !CheckResult {
    return runNonInteractiveMode("--check", path, null, false);
}

pub fn runNonInteractive(option: [*:0]const u8, path: [*:0]const u8, input: ?[]const u8) !CheckResult {
    return runNonInteractiveMode(option, path, input, false);
}

pub fn runRestrictedCheck(path: [*:0]const u8) !CheckResult {
    return runNonInteractiveMode("--check", path, null, true);
}

fn runNonInteractiveMode(option: [*:0]const u8, path: [*:0]const u8, input: ?[]const u8, restricted: bool) !CheckResult {
    var stdin_pipe: [2]c_int = undefined;
    if (c.pipe(&stdin_pipe) != 0) return error.PipeFailed;
    defer _ = c.close(stdin_pipe[0]);
    defer if (stdin_pipe[1] >= 0) {
        _ = c.close(stdin_pipe[1]);
    };
    var output_pipe: [2]c_int = undefined;
    var error_pipe: [2]c_int = undefined;
    if (c.pipe(&output_pipe) != 0) return error.PipeFailed;
    if (c.pipe(&error_pipe) != 0) {
        _ = c.close(output_pipe[0]);
        _ = c.close(output_pipe[1]);
        return error.PipeFailed;
    }
    const pid = c.fork();
    if (pid < 0) {
        for (output_pipe) |fd| _ = c.close(fd);
        for (error_pipe) |fd| _ = c.close(fd);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = c.close(output_pipe[0]);
        _ = c.close(error_pipe[0]);
        _ = c.close(stdin_pipe[1]);
        if (c.dup2(stdin_pipe[0], 0) < 0) _exit(127);
        _ = c.close(stdin_pipe[0]);
        if (c.dup2(output_pipe[1], 1) < 0 or c.dup2(error_pipe[1], 2) < 0) _exit(127);
        _ = c.close(output_pipe[1]);
        _ = c.close(error_pipe[1]);
        const binary = c.getenv("ZSQT_TEST_EXE") orelse "zig-out/test-bin/zsqt";
        const args = [_:null]?[*:0]const u8{ binary, option, path };
        if (restricted and !process.restrictSyscalls()) _exit(77);
        _ = execv(binary, &args);
        _exit(127);
    }
    _ = c.close(output_pipe[1]);
    _ = c.close(error_pipe[1]);
    defer _ = c.close(output_pipe[0]);
    defer _ = c.close(error_pipe[0]);
    var completed = false;
    defer if (!completed) {
        _ = c.kill(pid, .KILL);
        _ = c.waitpid(pid, null, 0);
    };
    if (input) |data| {
        // Tests use a short input that fits in the pipe buffer.
        if (data.len > 1024) return error.InputTooLong;
        const n = c.write(stdin_pipe[1], data.ptr, data.len);
        if (n != data.len) return error.WriteFailed;
    }
    _ = c.close(stdin_pipe[1]);
    stdin_pipe[1] = -1;
    var result: CheckResult = .{};
    var started: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &started) != 0) return error.ClockFailed;
    var fds = [_]c.pollfd{
        .{ .fd = output_pipe[0], .events = c.POLL.IN, .revents = 0 },
        .{ .fd = error_pipe[0], .events = c.POLL.IN, .revents = 0 },
    };
    var open: usize = 2;
    while (open > 0) {
        var now: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &now) != 0) return error.ClockFailed;
        if (now.sec - started.sec >= 10) return error.ChildTimeout;
        const ready = c.poll(&fds, fds.len, 100);
        if (ready < 0) {
            if (c.errno(ready) == .INTR) continue;
            return error.PollFailed;
        }
        for (&fds, 0..) |*fd, index| {
            if (fd.fd < 0 or fd.revents == 0) continue;
            const buffer = if (index == 0) &result.output else &result.stderr;
            const len = if (index == 0) &result.len else &result.stderr_len;
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
        if (now.sec - started.sec >= 10) return error.ChildTimeout;
        var idle = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
        _ = c.poll(&idle, 1, 50);
    }
    completed = true;
    return result;
}
