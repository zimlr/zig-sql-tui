import fcntl
import hashlib
import os
from pathlib import Path
import pty
import select
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "zig-out/bin/zig-sql-tui"
TMP = ROOT / ".zig-cache/tmp"


def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()


class Terminal:
    def __init__(self, *args):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        self.proc = subprocess.Popen([EXE, *map(str, args)], stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        self.data = bytearray()

    def wait(self, text, start=0):
        deadline = time.monotonic() + 8
        while text not in self.data[start:]:
            if time.monotonic() > deadline:
                raise AssertionError(f"missing {text!r}: {bytes(self.data[-2500:])!r}")
            if select.select([self.master], [], [], 0.1)[0]:
                try:
                    self.data.extend(os.read(self.master, 65536))
                except OSError:
                    break
        if text not in self.data[start:]:
            raise AssertionError(f"missing {text!r}: {bytes(self.data[-2500:])!r}")

    def send(self, data, text):
        start = len(self.data)
        os.write(self.master, data)
        self.wait(text, start)

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        os.close(self.master)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.path = Path(self.temp.name) / "db.sqlite"
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TABLE data(v TEXT)")
            db.executemany("INSERT INTO data VALUES (?)", [("A" * 4000,)] * 200)

    def tearDown(self):
        self.temp.cleanup()

    def make_hot_journal(self):
        script = """import os, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('PRAGMA cache_size=4')
c.execute('BEGIN IMMEDIATE')
c.execute(\"UPDATE data SET v=replace(v,'A','B')\")
os._exit(0)
"""
        subprocess.run([sys.executable, "-c", script, str(self.path)], check=True)
        journal = Path(str(self.path) + "-journal")
        self.assertGreater(journal.stat().st_size, 0)
        return journal

    def test_hot_journal_requires_confirmed_recovery(self):
        journal = self.make_hot_journal()
        before_db, before_journal = digest(self.path), digest(journal)
        check = subprocess.run([EXE, "--check", self.path], capture_output=True, timeout=10)
        self.assertNotEqual(check.returncode, 0)
        unconfirmed = subprocess.run([EXE, "--recover", self.path], input=b"y\n", capture_output=True, timeout=10)
        self.assertNotEqual(unconfirmed.returncode, 0)
        self.assertIn(b"--recover", check.stderr)
        self.assertEqual((digest(self.path), digest(journal)), (before_db, before_journal))
        terminal = Terminal("--recover", self.path)
        try:
            terminal.wait(b"Recovery modifies")
            os.write(terminal.master, b"n")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()
        self.assertEqual((digest(self.path), digest(journal)), (before_db, before_journal))
        terminal = Terminal("--recover", self.path)
        try:
            terminal.wait(b"Recovery modifies")
            terminal.send(b"y", b"Recovery check completed")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM data WHERE substr(v,1,1)='A'").fetchone()[0], 200)
        self.assertEqual(subprocess.run([EXE, "--check", self.path], capture_output=True).returncode, 0)

    def test_recovery_confirmation_is_blocked_below_minimum_size(self):
        journal = self.make_hot_journal()
        before = (digest(self.path), digest(journal))
        terminal = Terminal("--recover", self.path)
        try:
            terminal.wait(b"Recovery modifies")
            start = len(terminal.data)
            fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 10, 35, 0, 0))
            os.kill(terminal.proc.pid, signal.SIGWINCH)
            terminal.wait(b"Resize terminal", start)
            terminal.send(b"y", b"Resize terminal")
            self.assertEqual((digest(self.path), digest(journal)), before)
            start = len(terminal.data)
            fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
            os.kill(terminal.proc.pid, signal.SIGWINCH)
            terminal.wait(b"Recovery modifies", start)
            terminal.send(b"y", b"Recovery check completed")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_superjournal_recovery_fails_without_accessing_other_files(self):
        journal = self.make_hot_journal()
        superjournal = self.path.parent / "other-mj1234569AB"
        superjournal.write_bytes(b"must remain untouched")
        name = os.fsencode(superjournal)
        magic = bytes.fromhex("d9d505f920a163d7")
        with journal.open("ab") as output:
            output.write(struct.pack(">I", 0) + name + struct.pack(">II", len(name), sum(name) & 0xffffffff) + magic)
        before = (digest(self.path), digest(journal), digest(superjournal))
        terminal = Terminal("--recover", self.path)
        try:
            terminal.wait(b"Recovery modifies")
            terminal.send(b"y", b"Recovery failed:")
            self.assertNotEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()
        self.assertEqual((digest(self.path), digest(journal), digest(superjournal)), before)

    def test_rollback_write_is_confirmed_and_transactional(self):
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"e", b"CELL> <")
            terminal.send(b"\x15edited\r", b"Save cell change?")
            terminal.send(b"n", b"Cancelled")
            terminal.send(b"iUPDATE data SET v='changed' WHERE rowid=1\r", b"Execute this database write?")
            terminal.send(b"n", b"Cancelled")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT substr(v,1,1) FROM data WHERE rowid=1").fetchone()[0], "A")
            terminal.send(b"i\r", b"Execute this database write?")
            terminal.send(b"y", b"Write committed")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT v FROM data WHERE rowid=1").fetchone()[0], "changed")
                self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0], "delete")
            long_query = b"UPDATE data SET v='long' WHERE rowid=2 /*" + b"x" * 300 + b"*/"
            terminal.send(b"i\x15" + long_query + b"\r", b"Execute this database write?")
            terminal.send(b"y", b"Write committed")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT v FROM data WHERE rowid=2").fetchone()[0], "long")
            terminal.send(b"2j", b"Row 3")
            terminal.send(b"e", b"CELL> <")
            terminal.send(b"\x15edited long value\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT v FROM data WHERE rowid=3").fetchone()[0], "edited long value")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_journal_hardlink_rejected(self):
        target = self.path.parent / "target"
        target.write_bytes(b"not a journal")
        os.link(target, Path(str(self.path) + "-journal"))
        result = subprocess.run([EXE, "--check", self.path], capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), b"not a journal")

    def test_journal_symlink_rejected(self):
        target = self.path.parent / "target"
        target.write_bytes(b"not a journal")
        Path(str(self.path) + "-journal").symlink_to(target)
        result = subprocess.run([EXE, "--check", self.path], capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), b"not a journal")


if __name__ == "__main__":
    unittest.main()
