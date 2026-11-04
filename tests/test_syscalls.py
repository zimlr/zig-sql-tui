import ctypes
import errno
import fcntl
import os
from pathlib import Path
import platform
import pty
import signal
import sqlite3
import struct
import termios
import tempfile
import unittest

from test_recovery import EXE, TMP


# Linux x86_64 ptrace register order and syscall numbers.
REGISTERS = (
    "r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi "
    "orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs"
).split()


class Registers(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in REGISTERS]


LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.ptrace.restype = ctypes.c_long
NETWORK = {41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 288, 299, 307}
FORBIDDEN = {56, 57, 58, 303, 304, 322, 425, 426, 427, 435}
# Values are the registers containing pathname arguments.
PATH_CALLS = {2: ("rdi",), 4: ("rdi",), 6: ("rdi",), 21: ("rdi",), 59: ("rdi",),
              82: ("rdi", "rsi"), 83: ("rdi",), 84: ("rdi",), 85: ("rdi",),
              86: ("rdi", "rsi"), 87: ("rdi",), 88: ("rdi", "rsi"), 89: ("rdi",),
              90: ("rdi",), 92: ("rdi",), 257: ("rsi",), 258: ("rsi",),
              260: ("rsi",), 262: ("rsi",), 263: ("rsi",), 264: ("rsi", "r10"),
              265: ("rsi", "r10"), 266: ("rdi", "rdx"), 267: ("rsi",),
              268: ("rsi",), 269: ("rsi",), 316: ("rsi", "r10"), 332: ("rsi",),
              437: ("rsi",), 439: ("rsi",)}


def ptrace(request, pid, address=0, data=0):
    ctypes.set_errno(0)
    result = LIBC.ptrace(request, pid, ctypes.c_void_p(address), ctypes.c_void_p(data))
    error = ctypes.get_errno()
    if result == -1 and error:
        raise OSError(error, os.strerror(error))
    return result


def read_string(pid, address):
    data = bytearray()
    while len(data) < 4096:
        word = ptrace(2, pid, address + len(data), 0)
        data.extend((word & ((1 << 64) - 1)).to_bytes(8, "little"))
        if 0 in data:
            return bytes(data).split(b"\0", 1)[0]
    raise AssertionError("Trace path exceeded 4096 bytes")


def trace_check(path, steps=None):
    if steps is None:
        read_fd, write_fd = os.pipe()
    else:
        read_fd, write_fd = pty.openpty()
        fcntl.ioctl(write_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        os.set_blocking(read_fd, False)
    pid = os.fork()
    if pid == 0:
        try:
            os.close(read_fd)
            if steps is not None:
                os.dup2(write_fd, 0)
            os.dup2(write_fd, 1)
            os.dup2(write_fd, 2)
            os.close(write_fd)
            try:
                ptrace(0, 0)
            except OSError:
                os._exit(77)
            os.kill(os.getpid(), signal.SIGSTOP)
            args = [str(EXE), "--check", str(path)] if steps is None else [str(EXE), str(path)]
            os.execv(EXE, args)
        finally:
            os._exit(126)
    os.close(write_fd)
    paths, network = [], []
    captured = bytearray()
    step_index, cursor = 0, 0
    finished = False
    previous_handler = signal.getsignal(signal.SIGALRM)

    def timeout(_signum, _frame):
        raise TimeoutError("Traced application did not exit")

    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(20)
    try:
        _, status = os.waitpid(pid, 0)
        if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 77:
            finished = True
            raise unittest.SkipTest("ptrace is not permitted in this environment")
        if not os.WIFSTOPPED(status):
            finished = True
            raise AssertionError(f"Trace child failed to stop: {status}")
        ptrace(0x4200, pid, 0, 1)  # PTRACE_SETOPTIONS, PTRACE_O_TRACESYSGOOD
        entering = True
        while True:
            if steps is not None:
                while True:
                    try:
                        chunk = os.read(read_fd, 65536)
                    except BlockingIOError:
                        break
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    captured.extend(chunk)
                if step_index < len(steps) and steps[step_index][0] in captured[cursor:]:
                    os.write(read_fd, steps[step_index][1])
                    step_index += 1
                    cursor = len(captured)
            ptrace(24, pid)  # PTRACE_SYSCALL
            _, status = os.waitpid(pid, 0)
            if os.WIFEXITED(status):
                finished = True
                code = os.WEXITSTATUS(status)
                break
            if os.WIFSIGNALED(status):
                finished = True
                raise AssertionError(f"Trace child terminated by signal {os.WTERMSIG(status)}")
            if os.WIFSTOPPED(status) and os.WSTOPSIG(status) == signal.SIGTRAP | 0x80:
                if entering:
                    registers = Registers()
                    ptrace(12, pid, 0, ctypes.addressof(registers))  # PTRACE_GETREGS
                    syscall = registers.orig_rax
                    if syscall in NETWORK or syscall in FORBIDDEN:
                        network.append(syscall)
                    if syscall in PATH_CALLS:
                        for register in PATH_CALLS[syscall]:
                            paths.append((syscall, read_string(pid, getattr(registers, register))))
                entering = not entering
        if steps is None:
            output = os.read(read_fd, 65536)
        else:
            output = bytes(captured)
            if step_index != len(steps):
                raise AssertionError(f"Trace stopped after step {step_index}: {output[-1000:]!r}")
        return code, output, paths, network
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_handler)
        if not finished:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os.close(read_fd)


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "x86_64 Linux ptrace is required")
class SyscallAuditTests(unittest.TestCase):
    def test_database_check_uses_no_network_or_unrelated_paths(self):
        with tempfile.TemporaryDirectory(dir=TMP) as directory:
            path = Path(directory) / "sample.sqlite"
            for mode in ("delete", "wal"):
                db = sqlite3.connect(path)
                try:
                    db.execute(f"PRAGMA journal_mode={mode}")
                    db.execute("CREATE TABLE IF NOT EXISTS data(v)")
                    db.execute("INSERT INTO data VALUES ('sample')")
                    db.commit()
                    code, output, paths, network = trace_check(path)
                    self.assertEqual(code, 0, output)
                    self.assertFalse(network, network)
                    permitted = {os.fsencode(EXE), os.fsencode(path.parent), os.fsencode(path.name),
                                 os.fsencode(path.name + "-wal"), os.fsencode(path.name + "-shm"),
                                 os.fsencode(path.name + "-journal"), b""}
                    self.assertTrue(paths)
                    self.assertEqual([item for item in paths if item[1] not in permitted], [])
                    self.assertEqual([item for item in paths if item[0] == 59], [(59, os.fsencode(EXE))])
                finally:
                    db.close()

    def test_confirmed_writes_use_no_network_or_unrelated_paths(self):
        steps = [
            (b"[RO] NORMAL", b":set rw\r"),
            (b"Enable write mode", b"y"),
            (b"Write mode enabled", b"iINSERT INTO data VALUES ('write')\r"),
            (b"Execute this database write?", b"y"),
            (b"Write committed", b":set ro\r"),
            (b"Read-only mode enabled", b"q"),
        ]
        with tempfile.TemporaryDirectory(dir=TMP) as directory:
            path = Path(directory) / "sample.sqlite"
            for mode in ("delete", "wal"):
                db = sqlite3.connect(path)
                try:
                    db.execute(f"PRAGMA journal_mode={mode}")
                    db.execute("CREATE TABLE IF NOT EXISTS data(v)")
                    db.commit()
                    code, output, paths, network = trace_check(path, steps)
                    self.assertEqual(code, 0, output[-1000:])
                    self.assertFalse(network, network)
                    permitted = {os.fsencode(EXE), os.fsencode(path.parent), os.fsencode(path.name),
                                 os.fsencode(path.name + "-wal"), os.fsencode(path.name + "-shm"),
                                 os.fsencode(path.name + "-journal"), b""}
                    self.assertEqual([item for item in paths if item[1] not in permitted], [])
                    self.assertEqual([item for item in paths if item[0] == 59], [(59, os.fsencode(EXE))])
                    self.assertGreater(db.execute("SELECT count(*) FROM data WHERE v='write'").fetchone()[0], 0)
                finally:
                    db.close()


if __name__ == "__main__":
    unittest.main()
