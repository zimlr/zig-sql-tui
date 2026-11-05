const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const support = @import("terminal_support.zig");
extern "c" fn ptrace(c_int, c.pid_t, ...) c_long;
extern "c" fn openpty(*c_int, *c_int, ?[*]u8, ?*anyopaque, ?*const std.posix.winsize) c_int;
extern "c" fn execv([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(c_int) noreturn;

const Db = opaque {};
extern fn sqlite3_open([*:0]const u8, *?*Db) c_int;
extern fn sqlite3_close(*Db) c_int;
extern fn sqlite3_exec(*Db, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*anyopaque) c_int;

const Registers = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    orig_rax: u64,
    rip: u64,
    cs: u64,
    eflags: u64,
    rsp: u64,
    ss: u64,
    fs_base: u64,
    gs_base: u64,
    ds: u64,
    es: u64,
    fs: u64,
    gs: u64,
};

fn call(request: c_int, pid: c.pid_t, addr: usize, data: usize) !c_long {
    c._errno().* = 0;
    const result = ptrace(request, pid, addr, data);
    if (result == -1 and c.errno(result) != .SUCCESS) return error.PtraceFailed;
    return result;
}

fn readPath(pid: c.pid_t, address: u64, buffer: *[4096]u8) ![]const u8 {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const word = try call(2, pid, @intCast(address + offset), 0);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @bitCast(word), .little);
        for (bytes) |byte| {
            if (byte == 0) return buffer[0..offset];
            if (offset == buffer.len) return error.PathTooLong;
            buffer[offset] = byte;
            offset += 1;
        }
    }
    return error.PathTooLong;
}

fn prohibited(number: u64) bool {
    const calls = [_]u64{ 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 288, 299, 307, 56, 57, 58, 303, 304, 322, 425, 426, 427, 435, 437, 439, 452 };
    for (calls) |call_number| if (number == call_number) return true;
    return false;
}

fn pathAddresses(r: *const Registers, buffer: *[2]u64) []const u64 {
    switch (r.orig_rax) {
        2, 4, 6, 21, 59, 83, 84, 85, 87, 89, 90, 92 => {
            buffer[0] = r.rdi;
            return buffer[0..1];
        },
        82, 86, 88 => {
            buffer[0] = r.rdi;
            buffer[1] = r.rsi;
            return buffer[0..2];
        },
        257, 258, 260, 262, 263, 267, 268, 269, 332, 437, 439 => {
            buffer[0] = r.rsi;
            return buffer[0..1];
        },
        264, 265, 316 => {
            buffer[0] = r.rsi;
            buffer[1] = r.r10;
            return buffer[0..2];
        },
        266 => {
            buffer[0] = r.rdi;
            buffer[1] = r.rdx;
            return buffer[0..2];
        },
        else => return buffer[0..0],
    }
}

const Step = struct { needle: []const u8, keys: []const u8 };
const write_steps = [_]Step{
    .{ .needle = "[RO] NORMAL", .keys = ":set rw\r" },
    .{ .needle = "Enable write mode", .keys = "y" },
    .{ .needle = "Write mode enabled", .keys = "iINSERT INTO data VALUES ('write')\r" },
    .{ .needle = "Execute this database write?", .keys = "y" },
    .{ .needle = "Write committed", .keys = ":set ro\r" },
    .{ .needle = "Read-only mode enabled", .keys = "q" },
};

const Audit = struct {
    expected: [128][]const u8 = undefined,
    expected_len: usize = 0,
    seen: usize = 0,
    exe_count: usize = 0,

    fn init(exe: []const u8, directory: []const u8) !Audit {
        var self: Audit = .{};
        self.expected[0] = exe;
        self.expected[1] = "/";
        self.expected_len = 2;
        var components = std.mem.tokenizeScalar(u8, directory, '/');
        while (components.next()) |component| {
            if (self.expected_len >= self.expected.len - 1) return error.TooManyComponents;
            self.expected[self.expected_len] = component;
            self.expected_len += 1;
        }
        self.expected[self.expected_len] = ".";
        self.expected_len += 1;
        return self;
    }

    fn inspect(self: *Audit, pid: c.pid_t, r: *const Registers) !void {
        if (prohibited(r.orig_rax)) {
            std.debug.print("Forbidden syscall: {d}\n", .{r.orig_rax});
            return error.ForbiddenSyscall;
        }
        var addresses: [2]u64 = undefined;
        for (pathAddresses(r, &addresses)) |addr| {
            var path_buf: [4096]u8 = undefined;
            const path = try readPath(pid, addr, &path_buf);
            if (r.orig_rax == 59) self.exe_count += 1;
            if (self.seen < self.expected_len) {
                if (!std.mem.eql(u8, path, self.expected[self.seen])) {
                    std.debug.print("Unexpected path {s}, expected {s}\n", .{ path, self.expected[self.seen] });
                    return error.UnexpectedPath;
                }
                if (self.seen == 0 and r.orig_rax != 59) return error.UnexpectedPathCall;
                if (self.seen == 1 and r.orig_rax != 2 and r.orig_rax != 257) return error.UnexpectedPathCall;
                if (self.seen >= 2 and r.orig_rax != 257) return error.UnexpectedPathCall;
            } else if (!std.mem.eql(u8, path, "test.sqlite") and !std.mem.eql(u8, path, "test.sqlite-wal") and !std.mem.eql(u8, path, "test.sqlite-shm") and !std.mem.eql(u8, path, "test.sqlite-journal") and path.len != 0) {
                std.debug.print("Unrelated path in syscall {d}: {s}\n", .{ r.orig_rax, path });
                return error.UnexpectedPath;
            }
            self.seen += 1;
        }
    }
};

fn waitTrace(pid: c.pid_t, started: c.timespec) !c_int {
    while (true) {
        var status: c_int = 0;
        const got = c.waitpid(pid, &status, c.W.NOHANG);
        if (got == pid) return status;
        if (got < 0 and c.errno(got) != .INTR) return error.WaitFailed;
        var now: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &now) != 0) return error.ClockFailed;
        if (now.sec - started.sec >= 20) return error.ChildTimeout;
        var idle = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
        _ = c.poll(&idle, 1, 1);
    }
}

fn capture(fd: c_int, output: []u8, len: *usize) !void {
    while (len.* < output.len) {
        const n = c.read(fd, output[len.*..].ptr, output.len - len.*);
        if (n == 0) return;
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            if (c.errno(n) == .AGAIN or c.errno(n) == .IO) return;
            return error.ReadFailed;
        }
        len.* += @intCast(n);
    }
    return error.OutputTooLong;
}

fn trace(db: *support.Fixture, interactive: bool) !void {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var cwd_buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const current = std.mem.sliceTo(cwd, 0);
    const exe_arg = c.getenv("ZSQT_AUDIT_EXE") orelse "zig-out/bin/zsqt";
    var exe_buf: [4600]u8 = undefined;
    const exe = if (exe_arg[0] == '/') std.mem.span(exe_arg) else try std.fmt.bufPrint(&exe_buf, "{s}/{s}", .{ current, std.mem.span(exe_arg) });
    var exe_zbuf: [4600]u8 = undefined;
    const exe_z = try std.fmt.bufPrintSentinel(&exe_zbuf, "{s}", .{exe}, 0);
    var dir_buf: [4600]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ current, std.mem.sliceTo(&db.dir, 0) });
    var path_buf: [4800]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/test.sqlite", .{dir}, 0);
    var audit = try Audit.init(exe_z, dir);
    var read_fd: c_int = undefined;
    var write_fd: c_int = undefined;
    if (interactive) {
        const size = std.posix.winsize{ .row = 24, .col = 100, .xpixel = 0, .ypixel = 0 };
        if (openpty(&read_fd, &write_fd, null, null, &size) != 0) return error.OpenPtyFailed;
    } else {
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return error.PipeFailed;
        read_fd = fds[0];
        write_fd = fds[1];
    }
    defer _ = c.close(read_fd);
    const flags = c.fcntl(read_fd, c.F.GETFL);
    if (flags < 0 or c.fcntl(read_fd, c.F.SETFL, flags | @as(c_int, @bitCast(@as(c.O, .{ .NONBLOCK = true })))) != 0) {
        _ = c.close(write_fd);
        return error.FcntlFailed;
    }
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(write_fd);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = c.close(read_fd);
        if (interactive and c.dup2(write_fd, 0) < 0) _exit(126);
        if (c.dup2(write_fd, 1) < 0 or c.dup2(write_fd, 2) < 0) _exit(126);
        _ = c.close(write_fd);
        if (ptrace(0, 0, @as(usize, 0), @as(usize, 0)) == -1) _exit(77);
        if (c.kill(c.getpid(), .STOP) != 0) _exit(126);
        if (interactive) {
            const args = [_:null]?[*:0]const u8{ exe_z.ptr, path.ptr };
            _ = execv(exe_z.ptr, &args);
        } else {
            const args = [_:null]?[*:0]const u8{ exe_z.ptr, "--check", path.ptr };
            _ = execv(exe_z.ptr, &args);
        }
        _exit(126);
    }
    _ = c.close(write_fd);
    var finished = false;
    defer if (!finished) {
        _ = c.kill(pid, .KILL);
        _ = c.waitpid(pid, null, 0);
    };
    var started: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &started) != 0) return error.ClockFailed;
    var status = try waitTrace(pid, started);
    if (status == 77 << 8) {
        finished = true;
        return error.SkipZigTest;
    }
    if (status & 0xff != 0x7f) {
        finished = true;
        return error.ChildDidNotStop;
    }
    _ = try call(0x4200, pid, 0, 1);
    const output = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(output);
    var len: usize = 0;
    var step: usize = 0;
    var cursor: usize = 0;
    var entering = true;
    while (true) {
        try capture(read_fd, output, &len);
        if (interactive and step < write_steps.len and std.mem.indexOf(u8, output[cursor..len], write_steps[step].needle) != null) {
            const keys = write_steps[step].keys;
            if (c.write(read_fd, keys.ptr, keys.len) != keys.len) return error.WriteFailed;
            step += 1;
            cursor = len;
        }
        _ = try call(24, pid, 0, 0);
        status = try waitTrace(pid, started);
        if (status & 0x7f == 0) {
            finished = true;
            break;
        }
        if (status & 0xff != 0x7f) {
            finished = true;
            return error.ChildSignaled;
        }
        if ((status >> 8) & 0xff == (5 | 0x80)) {
            if (entering) {
                var regs: Registers = undefined;
                _ = try call(12, pid, 0, @intFromPtr(&regs));
                try audit.inspect(pid, &regs);
            }
            entering = !entering;
        }
    }
    try capture(read_fd, output, &len);
    if (status != 0) std.debug.print("Traced application exited {d}: {s}\n", .{ status, output[len -| 1000..len] });
    try std.testing.expectEqual(@as(c_int, 0), status);
    if (interactive) try std.testing.expectEqual(write_steps.len, step);
    try std.testing.expect(audit.seen >= audit.expected_len);
    try std.testing.expectEqual(@as(usize, 1), audit.exe_count);
}

fn runModes(interactive: bool) !void {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    for ([_]bool{ false, true }) |wal| {
        var db = try support.Fixture.init("CREATE TABLE data(v)");
        defer db.deinit();
        var conn: ?*Db = null;
        if (sqlite3_open(@ptrCast(&db.path), &conn) != 0 or conn == null) {
            if (conn) |opened| _ = sqlite3_close(opened);
            return error.OpenFailed;
        }
        defer _ = sqlite3_close(conn.?);
        const sql = if (wal) "PRAGMA journal_mode=WAL; INSERT INTO data VALUES ('sample')" else "PRAGMA journal_mode=DELETE; INSERT INTO data VALUES ('sample')";
        if (sqlite3_exec(conn.?, sql, null, null, null) != 0) return error.SqlFailed;
        try trace(&db, interactive);
        if (interactive) try db.expectValue("SELECT count(*) FROM data WHERE v='write'", "1");
    }
}

test "database check has no network or unrelated paths" {
    try runModes(false);
}

test "confirmed writes have no network or unrelated paths" {
    try runModes(true);
}
