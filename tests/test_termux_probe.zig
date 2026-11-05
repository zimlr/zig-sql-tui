const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;

// Exercise the production Python probe in a child so SIGSYS cannot kill the test runner.
const probe_script =
    \\import ctypes, sys
    \\sys.path.insert(0, 'tools')
    \\import check_termux_candidate as probe
    \\try:
    \\    probe.trap_syscalls(probe.ANDROID_RESTRICTED)
    \\except OSError:
    \\    sys.exit(77)
    \\ctypes.CDLL(None).syscall(int(sys.argv[1]), -100, 0, 0, 0)
;

test "Termux probe traps each restricted syscall" {
    if (builtin.os.tag != .linux or (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64)) return error.SkipZigTest;
    for ([_][*:0]const u8{ "437", "439", "452" }) |number| {
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            const args = [_:null]?[*:0]const u8{ "python3", "-c", probe_script, number };
            _ = execvp("python3", &args);
            _exit(127);
        }
        var status: c_int = 0;
        while (c.waitpid(pid, &status, 0) < 0) {
            if (c.errno(-1) != .INTR) return error.WaitFailed;
        }
        if ((status & 0x7f) == 0 and (status >> 8) == 77) return error.SkipZigTest;
        try std.testing.expectEqual(@as(c_int, @intCast(@backingInt(c.SIG.SYS))), status & 0x7f);
    }
}
