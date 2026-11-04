#!/usr/bin/env python3
"""Run Termux's ELF check and a restricted Linux syscall probe."""

import ctypes
from pathlib import Path
import platform
import resource
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile


class SockFilter(ctypes.Structure):
    _fields_ = [("code", ctypes.c_ushort), ("jt", ctypes.c_ubyte),
                ("jf", ctypes.c_ubyte), ("k", ctypes.c_uint32)]


class SockProgram(ctypes.Structure):
    _fields_ = [("length", ctypes.c_ushort), ("filter", ctypes.POINTER(SockFilter))]


def trap_syscall(number):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    # Load the syscall number and trap it. Allow all other calls.
    rules = (SockFilter * 4)(
        SockFilter(0x20, 0, 0, 0),
        SockFilter(0x15, 0, 1, number),
        SockFilter(0x06, 0, 0, 0x00030000),
        SockFilter(0x06, 0, 0, 0x7fff0000),
    )
    program = SockProgram(len(rules), rules)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(38, 1, 0, 0, 0) != 0:  # PR_SET_NO_NEW_PRIVS
        raise OSError(ctypes.get_errno(), "PR_SET_NO_NEW_PRIVS failed")
    if libc.prctl(22, 2, ctypes.byref(program), 0, 0) != 0:  # PR_SET_SECCOMP
        raise OSError(ctypes.get_errno(), "PR_SET_SECCOMP failed")


def main():
    if len(sys.argv) != 3:
        print("Usage: check_termux_candidate.py TERMUX_PACKAGES BINARY", file=sys.stderr)
        return 2
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "aarch64"):
        print("The seccomp probe requires Linux x86_64 or aarch64", file=sys.stderr)
        return 2
    source = Path(sys.argv[1]).resolve()
    binary = Path(sys.argv[2]).resolve()
    root = Path(__file__).resolve().parent.parent
    tmp = root / ".zig-cache/tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=tmp) as directory:
        work = Path(directory)
        scripts = work / "scripts"
        prefix = work / "prefix"
        scripts.mkdir()
        (prefix / "bin").mkdir(parents=True)
        shutil.copy2(source / "scripts/bin/check-pie.sh", scripts / "check-pie.sh")
        (scripts / "properties.sh").write_text(f"TERMUX_PREFIX={shlex.quote(str(prefix))}\n")
        shutil.copy2(binary, prefix / "bin/zig-sql-tui")
        check = subprocess.run(["bash", scripts / "check-pie.sh"], text=True,
                               capture_output=True, check=True)
        failures = []
        if "zig-sql-tui" in check.stdout.splitlines():
            failures.append("Termux check-pie reports a non-PIE executable")
        elif check.stdout.strip():
            failures.append(f"Unexpected check-pie output: {check.stdout.strip()}")
        else:
            print("Termux check-pie did not report a non-PIE executable")
        db_path = work / "sample.sqlite"
        with sqlite3.connect(db_path) as db:
            db.execute("CREATE TABLE data(value TEXT)")
            db.execute("INSERT INTO data VALUES ('sample')")
        probe = subprocess.run([binary, "--check", db_path], capture_output=True,
                               preexec_fn=lambda: trap_syscall(437), timeout=20)
        if probe.returncode == -signal.SIGSYS:
            failures.append("Application terminated with SIGSYS when openat2 was trapped")
        elif probe.returncode != 0:
            failures.append(f"Application returned {probe.returncode} with openat2 trapped: {probe.stderr!r}")
        else:
            print("Application opened the database with openat2 trapped")
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        if failures:
            print("Termux app execution remains unverified. This probe does not emulate Android.", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
