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
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "zig-out/bin/zig-sql-tui"
TMP = ROOT / ".zig-cache/tmp"


class BrowserTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.path = Path(self.temp.name) / "test.sqlite"
        with sqlite3.connect(self.path) as db:
            db.executescript("CREATE TABLE people(name TEXT, age INTEGER); INSERT INTO people VALUES ('Ada', 42), ('Lin', 31), (char(27) || '[2J injected', 1);")
            db.execute("INSERT INTO people VALUES (?, ?)", ("long-value-" + "x" * 300 + "endmarker", 5))
            db.execute('CREATE TABLE "quoted""table" (v TEXT)')
            db.execute('INSERT INTO "quoted""table" VALUES (?)', ("quoted row",))

    def tearDown(self):
        self.temp.cleanup()

    def check(self, path):
        return subprocess.run([EXE, "--check", str(path)], capture_output=True, timeout=10)

    def test_read_only_snapshot_and_quoted_name(self):
        before = hashlib.sha256(self.path.read_bytes()).digest()
        result = self.check(self.path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"2 tables", result.stdout)
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).digest())
        self.assertEqual(sorted(p.name for p in self.path.parent.iterdir()), ["test.sqlite"])

    def test_symlink_and_invalid_database_rejected(self):
        link = self.path.parent / "link.sqlite"
        link.symlink_to(self.path)
        self.assertNotEqual(self.check(link).returncode, 0)
        invalid = self.path.parent / "invalid.sqlite"
        invalid.write_bytes(b"SQLite format 3\0" + bytes(200))
        self.assertNotEqual(self.check(invalid).returncode, 0)

    def test_fifo_is_rejected_without_blocking(self):
        fifo = self.path.parent / "pipe"
        os.mkfifo(fifo)
        self.assertNotEqual(self.check(fifo).returncode, 0)

    def test_wal_database_reads_committed_frames(self):
        wal = self.path.parent / "wal.sqlite"
        db = sqlite3.connect(wal)
        try:
            self.assertEqual(db.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
            db.execute("CREATE TABLE data(n)")
            db.execute("INSERT INTO data VALUES ('committed in WAL')")
            db.commit()
            wal_file = Path(str(wal) + "-wal")
            original_db = hashlib.sha256(wal.read_bytes()).digest()
            original_wal = hashlib.sha256(wal_file.read_bytes()).digest()
            result = self.check(wal)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"Read-only database: 1 tables", result.stdout)
            self.assertEqual(original_db, hashlib.sha256(wal.read_bytes()).digest())
            self.assertEqual(original_wal, hashlib.sha256(wal_file.read_bytes()).digest())
            self.assertEqual(db.execute("SELECT n FROM data").fetchone()[0], "committed in WAL")
        finally:
            db.close()

    def test_large_wal_and_rollback_databases(self):
        wal = self.path.parent / "large-wal.sqlite"
        db = sqlite3.connect(wal)
        try:
            self.assertEqual(db.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
            db.execute("CREATE TABLE data(n)")
            db.commit()
            with wal.open("r+b") as file:
                file.truncate(256 * 1024 * 1024 + 4096)
            result = self.check(wal)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"Read-only database: 1 tables", result.stdout)
        finally:
            db.close()

        with self.path.open("r+b") as db:
            db.truncate(256 * 1024 * 1024 + 4096)
        result = self.check(self.path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"Read-only database: 2 tables", result.stdout)

    def test_wal_sidecar_symlink_is_rejected(self):
        wal = self.path.parent / "wal-symlink.sqlite"
        db = sqlite3.connect(wal)
        try:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE data(n)")
            db.commit()
            sidecar = Path(str(wal) + "-wal")
            saved = self.path.parent / "saved-wal"
            sidecar.rename(saved)
            target = self.path.parent / "target"
            target.write_bytes(b"untouched")
            sidecar.symlink_to(target)
            result = self.check(wal)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_bytes(), b"untouched")
            sidecar.unlink()
            saved.rename(sidecar)
        finally:
            db.close()

    def test_active_exclusive_lock_rejected(self):
        with sqlite3.connect(self.path) as db:
            db.execute("BEGIN EXCLUSIVE")
            result = self.check(self.path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"locked", result.stderr)
            db.rollback()

    def test_pending_lock_rejected(self):
        with self.path.open("r+b") as db:
            fcntl.lockf(db.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 1073741824)
            result = self.check(self.path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"locked", result.stderr)
            fcntl.lockf(db.fileno(), fcntl.LOCK_UN, 1, 1073741824)

    def test_tui_navigation_resize_and_write_refusal(self):
        original = hashlib.sha256(self.path.read_bytes()).digest()
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        proc = subprocess.Popen([EXE, str(self.path)], stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        collected = bytearray()

        def wait_for(needle, start=0):
            deadline = time.monotonic() + 5
            while needle not in collected[start:]:
                if time.monotonic() >= deadline:
                    self.fail(f"missing {needle!r} in {bytes(collected[-1500:])!r}")
                readable, _, _ = select.select([master], [], [], 0.1)
                if readable:
                    try:
                        collected.extend(os.read(master, 65536))
                    except OSError:
                        break
            self.assertIn(needle, collected[start:])

        def send(data, needle):
            start = len(collected)
            os.write(master, data)
            wait_for(needle, start)

        try:
            wait_for(b"[RO] NORMAL")
            wait_for(b"people")
            wait_for(b"\\x1B[2J injected")
            wait_for(b"Tab: panel")
            self.assertIn(b"DETAIL / SQL", collected)
            send(b"2gg", b"quoted row")
            send(b"gg", b"\\x1B[2J injected")
            send(b"\t", b"[RO] NORMAL | ROWS")
            send(b"l", b"Column 2/2")
            send(b"h", b"Column 1/2")
            send(b"G", b"endmarker")
            send(b"/Lin\r", b"Match found")
            query = b"SELECT count(*) AS total FROM people"
            send(b"i" + query + b"\r", b"Read-only query results")
            self.assertIn(b"> [4]", collected)
            send(b"i", b"[RO] INSERT | ROWS")
            send(b"\x7f" * len(query) + b"DELETE FROM people\r", b"Enter exactly one read-only SQL statement")
            send(b"\t", b"[RO] NORMAL | DETAIL")
            send(b"h", b"[RO] NORMAL | ROWS")
            send(b":set rw\r", b"Enable write mode")
            send(b"n", b"Cancelled")
            send(b"?", b"HELP | Press any key")
            send(b"x", b"[RO] NORMAL")
            start = len(collected)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 10, 35, 0, 0))
            os.kill(proc.pid, signal.SIGWINCH)
            wait_for(b"Resize terminal", start)
            start = len(collected)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 60, 0, 0))
            os.kill(proc.pid, signal.SIGWINCH)
            wait_for(b"Tab: panel", start)
            self.assertIn(b"[RO] NORMAL | ROWS", collected[start:])
            self.assertNotIn(b"DETAIL / SQL", collected[start:])
            self.assertNotIn(b"TABLES", collected[start:])
            start = len(collected)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 61, 0, 0))
            os.kill(proc.pid, signal.SIGWINCH)
            wait_for(b"Tab: panel", start)
            self.assertIn(b"TABLES", collected[start:])
            self.assertIn(b"ROWS:", collected[start:])
            self.assertNotIn(b"DETAIL / SQL", collected[start:])
            send(b"i", b"[RO] INSERT | ROWS")
            send(b"\x7f" * len(b"DELETE FROM people") + b"SELECT '" + b"a" * 70, b"SQL> <")
            send(b"\x1b", b"[RO] NORMAL | ROWS")
            os.write(master, b"q")
            self.assertEqual(proc.wait(timeout=5), 0)
            self.assertEqual(original, hashlib.sha256(self.path.read_bytes()).digest())
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)


if __name__ == "__main__":
    unittest.main()
