import fcntl
import os
from pathlib import Path
import pty
import select
import sqlite3
import struct
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "zig-out/bin/zsqt"
TMP = ROOT / ".zig-cache/tmp"


class WalWriteTests(unittest.TestCase):
    def test_cell_edit_conflict_and_cancel(self):
        with tempfile.TemporaryDirectory(dir=TMP) as directory:
            path = Path(directory) / "cells.sqlite"
            db = sqlite3.connect(path)
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE data(n TEXT, number INTEGER)")
            db.execute("INSERT INTO data VALUES ('one', 1)")
            db.commit()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
            proc = subprocess.Popen([EXE, str(path)], stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            data = bytearray()

            def send(command, needle):
                start = len(data)
                if command:
                    os.write(master, command)
                deadline = time.monotonic() + 8
                while needle not in data[start:]:
                    if time.monotonic() > deadline:
                        self.fail(f"missing {needle!r}: {bytes(data[-2500:])!r}")
                    if select.select([master], [], [], 0.1)[0]:
                        data.extend(os.read(master, 65536))

            try:
                send(b"", b"[RO] NORMAL")
                send(b":set rw\r", b"Enable write mode")
                send(b"y", b"Write mode enabled")
                send(b"\t", b"[RW] NORMAL | ROWS")
                send(b"e", b"CELL> one")
                send(b"\x15cancelled\r", b"Save cell change?")
                send(b"n", b"Cancelled")
                self.assertEqual(db.execute("SELECT n FROM data").fetchone()[0], "one")
                send(b"e", b"CELL> one")
                send(b"\x15edited\r", b"Save cell change?")
                send(b"y", b"Cell update committed")
                self.assertEqual(db.execute("SELECT n FROM data").fetchone()[0], "edited")
                send(b"e", b"CELL> edited")
                send(b"\x15stale\r", b"Save cell change?")
                db.execute("UPDATE data SET n='outside'")
                db.commit()
                send(b"y", b"Database changed. Reload before editing")
                self.assertEqual(db.execute("SELECT n FROM data").fetchone()[0], "outside")
                send(b"e", b"CELL> outside")
                send(b"\x15final\r", b"Save cell change?")
                send(b"y", b"Cell update committed")
                self.assertEqual(db.execute("SELECT n FROM data").fetchone()[0], "final")
                send(b"l", b"Column 2/2")
                send(b"e", b"CELL> 1")
                send(b"\x15bad\r", b"Save cell change?")
                send(b"y", b"Enter a valid 64-bit integer")
                self.assertEqual(db.execute("SELECT number FROM data").fetchone()[0], 1)
                send(b"l", b"Column 2/2")
                send(b"e", b"CELL> 1")
                send(b"\x1512\r", b"Save cell change?")
                send(b"y", b"Cell update committed")
                self.assertEqual(db.execute("SELECT number, typeof(number) FROM data").fetchone(), (12, "integer"))
                os.write(master, b"q")
                self.assertEqual(proc.wait(timeout=5), 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                os.close(master)
                db.close()

    def test_rowid_shadowing_and_without_rowid(self):
        with tempfile.TemporaryDirectory(dir=TMP) as directory:
            path = Path(directory) / "rowid.sqlite"
            db = sqlite3.connect(path)
            db.execute("PRAGMA journal_mode=WAL")
            db.execute('CREATE TABLE a_shadow(rowid TEXT, _rowid_ TEXT, value TEXT)')
            db.executemany("INSERT INTO a_shadow VALUES (?, ?, ?)", [("r1", "x1", "first"), ("r2", "x2", "second")])
            db.execute("CREATE TABLE b_no_rowid(id TEXT PRIMARY KEY, n TEXT) WITHOUT ROWID")
            db.execute("INSERT INTO b_no_rowid VALUES ('a', 'protected')")
            db.commit()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
            proc = subprocess.Popen([EXE, str(path)], stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            data = bytearray()

            def send(command, needle):
                start = len(data)
                if command:
                    os.write(master, command)
                deadline = time.monotonic() + 8
                while needle not in data[start:]:
                    if time.monotonic() > deadline:
                        self.fail(f"missing {needle!r}: {bytes(data[-2500:])!r}")
                    if select.select([master], [], [], 0.1)[0]:
                        data.extend(os.read(master, 65536))

            try:
                send(b"", b"[RO] NORMAL")
                send(b":set rw\r", b"Enable write mode")
                send(b"y", b"Write mode enabled")
                send(b"\t", b"[RW] NORMAL | ROWS")
                send(b"j2l", b"Column 3/3")
                send(b"e", b"CELL> second")
                send(b"\x15changed\r", b"Save cell change?")
                send(b"y", b"Cell update committed")
                self.assertEqual(db.execute("SELECT rowid, value FROM a_shadow ORDER BY rowid").fetchall(), [("r1", "first"), ("r2", "changed")])
                send(b"\t\t", b"[RW] NORMAL | TABLES")
                send(b"j", b"b_no_rowid")
                send(b"\t", b"[RW] NORMAL | ROWS")
                send(b"l", b"Column 2/2")
                send(b"e", b"CELL> protected")
                send(b"\x15changed without rowid\r", b"Save cell change?")
                send(b"y", b"Cell update committed")
                self.assertEqual(db.execute("SELECT n FROM b_no_rowid").fetchone()[0], "changed without rowid")
                os.write(master, b"q")
                self.assertEqual(proc.wait(timeout=5), 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                os.close(master)
                db.close()

    def test_confirmed_transaction_and_readonly_switch(self):
        with tempfile.TemporaryDirectory(dir=TMP) as directory:
            path = Path(directory) / "write.sqlite"
            db = sqlite3.connect(path)
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE data(n TEXT UNIQUE)")
            db.execute("INSERT INTO data VALUES ('one')")
            db.commit()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
            proc = subprocess.Popen([EXE, str(path)], stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            data = bytearray()

            def wait_for(needle, start=0):
                deadline = time.monotonic() + 8
                while needle not in data[start:]:
                    if time.monotonic() > deadline:
                        self.fail(f"missing {needle!r}: {bytes(data[-2000:])!r}")
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            data.extend(os.read(master, 65536))
                        except OSError:
                            break
                self.assertIn(needle, data[start:])

            def send(command, needle):
                start = len(data)
                os.write(master, command)
                wait_for(needle, start)

            try:
                wait_for(b"[RO] NORMAL")
                send(b":set rw\r", b"Enable write mode")
                send(b"n", b"Cancelled")
                self.assertEqual(db.execute("SELECT n FROM data").fetchall(), [("one",)])
                send(b":set rw\r", b"Enable write mode")
                send(b"y", b"Write mode enabled")
                self.assertIn(b"[RW] NORMAL", data)
                forbidden = b"ATTACH ':memory:' AS other"
                send(b"i" + forbidden + b"\r", b"Enter one permitted SQL statement")
                query = b"INSERT INTO data VALUES ('two')"
                send(b"i\x15" + query + b"\r", b"Execute this database write? y/n")
                send(b"n", b"Cancelled")
                self.assertEqual(db.execute("SELECT n FROM data ORDER BY n").fetchall(), [("one",)])
                send(b"i\r", b"Execute this database write? y/n")
                send(b"y", b"Write committed")
                self.assertEqual(db.execute("SELECT n FROM data ORDER BY n").fetchall(), [("one",), ("two",)])
                duplicate = b"INSERT INTO data VALUES ('one')"
                send(b"i" + b"\x7f" * len(query) + duplicate + b"\r", b"Execute this database write? y/n")
                send(b"y", b"UNIQUE constraint failed")
                self.assertEqual(db.execute("SELECT n FROM data ORDER BY n").fetchall(), [("one",), ("two",)])
                db.execute("BEGIN IMMEDIATE")
                third = b"INSERT INTO data VALUES ('three')"
                send(b"i\x15" + third + b"\r", b"Execute this database write? y/n")
                send(b"y", b"database is locked")
                db.rollback()
                self.assertEqual(db.execute("SELECT n FROM data ORDER BY n").fetchall(), [("one",), ("two",)])
                send(b"i\r", b"Execute this database write? y/n")
                send(b"y", b"Write committed")
                self.assertEqual(db.execute("SELECT n FROM data ORDER BY n").fetchall(), [("one",), ("three",), ("two",)])
                send(b":set ro\r", b"Read-only mode enabled")
                self.assertIn(b"[RO] NORMAL", data)
                send(b"i\r", b"Enter exactly one read-only SQL statement")
                os.write(master, b"q")
                self.assertEqual(proc.wait(timeout=5), 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                os.close(master)
                db.close()


if __name__ == "__main__":
    unittest.main()
