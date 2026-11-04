import hashlib
import os
from pathlib import Path
import platform
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from test_recovery import EXE, ROOT, TMP, Terminal
sys.path.insert(0, str(ROOT / "tools"))
from check_termux_candidate import ANDROID_RESTRICTED, trap_syscalls


def restrict():
    trap_syscalls(ANDROID_RESTRICTED)


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() in ("x86_64", "aarch64"), "Linux seccomp is required")
class RestrictedSyscallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        child = os.fork()
        if child == 0:
            try:
                restrict()
            except OSError:
                os._exit(77)
            os._exit(0)
        _, status = os.waitpid(child, 0)
        if os.waitstatus_to_exitcode(status) == 77:
            raise unittest.SkipTest("seccomp filters are not permitted in this environment")
        if os.waitstatus_to_exitcode(status) != 0:
            raise AssertionError("Could not install seccomp filter")

    def setUp(self):
        TMP.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.directory = Path(self.temp.name)
        self.path = self.directory / "data.sqlite"
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TABLE data(value TEXT)")
            db.execute("INSERT INTO data VALUES ('initial')")

    def tearDown(self):
        self.temp.cleanup()

    def check(self, path):
        return subprocess.run([EXE, "--check", str(path)], cwd=ROOT, capture_output=True,
                              preexec_fn=restrict, timeout=10)

    def test_absolute_and_relative_paths_and_directory_symlinks(self):
        self.assertEqual(self.check(self.path).returncode, 0)
        self.assertEqual(self.check(self.path.relative_to(ROOT)).returncode, 0)
        nested = self.directory / "nested"
        nested.mkdir()
        self.assertEqual(self.check(nested / ".." / self.path.name).returncode, 0)
        link = self.directory / "link"
        link.symlink_to(nested, target_is_directory=True)
        self.assertNotEqual(self.check(link / ".." / self.path.name).returncode, 0)
        alias = self.directory / "alias.sqlite"
        alias.symlink_to(self.path)
        self.assertNotEqual(self.check(alias).returncode, 0)

    def test_journal_symlink_and_hardlink_are_rejected(self):
        target = self.directory / "unrelated"
        target.write_bytes(b"untouched")
        journal = Path(str(self.path) + "-journal")
        journal.symlink_to(target)
        self.assertNotEqual(self.check(self.path).returncode, 0)
        journal.unlink()
        os.link(target, journal)
        self.assertNotEqual(self.check(self.path).returncode, 0)
        self.assertEqual(target.read_bytes(), b"untouched")

    def test_wal_and_shm_symlinks_are_rejected(self):
        db = sqlite3.connect(self.path)
        try:
            self.assertEqual(db.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
            db.execute("INSERT INTO data VALUES ('wal')")
            db.commit()
            target = self.directory / "unrelated"
            target.write_bytes(b"untouched")
            for suffix in ("-wal", "-shm"):
                with self.subTest(suffix=suffix):
                    sidecar = Path(str(self.path) + suffix)
                    saved = self.directory / ("saved" + suffix)
                    sidecar.rename(saved)
                    try:
                        sidecar.symlink_to(target)
                        self.assertNotEqual(self.check(self.path).returncode, 0)
                        self.assertEqual(target.read_bytes(), b"untouched")
                    finally:
                        sidecar.unlink()
                        saved.rename(sidecar)
        finally:
            db.close()

    def test_readonly_and_confirmed_writes_in_rollback_and_wal_modes(self):
        for journal_mode in ("delete", "wal"):
            with self.subTest(journal_mode=journal_mode):
                db = sqlite3.connect(self.path)
                try:
                    self.assertEqual(db.execute(f"PRAGMA journal_mode={journal_mode}").fetchone()[0], journal_mode)
                    db.execute("DELETE FROM data WHERE value='confirmed'")
                    db.execute("INSERT INTO data VALUES ('setup')")
                    db.commit()
                    result = self.check(self.path)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    terminal = Terminal(self.path, preexec_fn=restrict)
                    try:
                        terminal.wait(b"[RO] NORMAL")
                        terminal.send(b"iINSERT INTO data VALUES ('refused')\r", b"Enter exactly one read-only SQL statement")
                        terminal.send(b":set rw\r", b"Enable write mode")
                        terminal.send(b"y", b"Write mode enabled")
                        terminal.send(b"i\x15INSERT INTO data VALUES ('confirmed')\r", b"Execute this database write?")
                        terminal.send(b"n", b"Cancelled")
                        self.assertEqual(db.execute("SELECT count(*) FROM data WHERE value='confirmed'").fetchone()[0], 0)
                        terminal.send(b"i\r", b"Execute this database write?")
                        terminal.send(b"y", b"Write committed")
                        self.assertEqual(db.execute("SELECT count(*) FROM data WHERE value='confirmed'").fetchone()[0], 1)
                        terminal.send(b":set ro\r", b"Read-only mode enabled")
                        os.write(terminal.master, b"q")
                        self.assertEqual(terminal.proc.wait(timeout=5), 0)
                    finally:
                        terminal.close()
                finally:
                    db.close()

    def test_hot_journal_recovery_requires_confirmation(self):
        with sqlite3.connect(self.path) as db:
            db.execute("DELETE FROM data")
            db.executemany("INSERT INTO data VALUES (?)", [("A" * 4000,)] * 200)
        script = """import os, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('PRAGMA cache_size=4')
c.execute('BEGIN IMMEDIATE')
c.execute("UPDATE data SET value=replace(value,'A','B')")
os._exit(0)
"""
        subprocess.run([sys.executable, "-c", script, str(self.path)], check=True)
        journal = Path(str(self.path) + "-journal")
        self.assertGreater(journal.stat().st_size, 0)
        before = tuple(hashlib.sha256(p.read_bytes()).digest() for p in (self.path, journal))
        self.assertNotEqual(self.check(self.path).returncode, 0)
        terminal = Terminal("--recover", self.path, preexec_fn=restrict)
        try:
            terminal.wait(b"Recovery modifies")
            os.write(terminal.master, b"n")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()
        self.assertEqual(tuple(hashlib.sha256(p.read_bytes()).digest() for p in (self.path, journal)), before)
        terminal = Terminal("--recover", self.path, preexec_fn=restrict)
        try:
            terminal.wait(b"Recovery modifies")
            terminal.send(b"y", b"Recovery check completed")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM data WHERE substr(value,1,1)='A'").fetchone()[0], 200)
        self.assertEqual(self.check(self.path).returncode, 0)


if __name__ == "__main__":
    unittest.main()
