import fcntl
import hashlib
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import struct
import tempfile
import termios
import time
import unittest

from test_recovery import EXE, Terminal, TMP


class LiveAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.path = Path(self.temp.name) / "sample.sqlite"
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TABLE data(value TEXT)")
            db.execute("INSERT INTO data VALUES ('original')")

    def tearDown(self):
        self.temp.cleanup()

    def test_malformed_schema_error_cannot_inject_terminal_controls(self):
        with sqlite3.connect(self.path) as db:
            db.execute("PRAGMA writable_schema=ON")
            name = "evil\x1b]52;c;cHdu\x07"
            db.execute("INSERT INTO sqlite_schema VALUES (?,?,?,?,?)",
                       ("table", name, name, 0, 'CREATE TABLE "broken"('))
        result = subprocess.run([EXE, "--check", self.path], capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"\x1b", result.stderr)
        self.assertNotIn(b"\x07", result.stderr)
        self.assertIn(b"\\x1B", result.stderr)
        self.assertIn(b"\\x07", result.stderr)

    def test_write_confirmation_is_blocked_below_minimum_size(self):
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"iINSERT INTO data VALUES ('new')\r", b"Execute this database write?")
            start = len(terminal.data)
            fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 10, 35, 0, 0))
            os.kill(terminal.proc.pid, signal.SIGWINCH)
            terminal.wait(b"Resize terminal", start)
            terminal.send(b"y", b"Resize terminal")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchall(), [("original",)])
            start = len(terminal.data)
            fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
            os.kill(terminal.proc.pid, signal.SIGWINCH)
            terminal.wait(b"Execute this database write?", start)
            terminal.send(b"y", b"Write committed")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM data").fetchone()[0], 2)
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_arrow_keys_do_not_cancel_sql_entry(self):
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b"iSELECT 42", b"SQL> SELECT 42")
            terminal.send(b"\x1b[D", b"[RO] INSERT")
            terminal.send(b"\r", b"Read-only query results")
            terminal.wait(b"[42]")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_fragmented_escape_sequence_does_not_confirm_write(self):
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"iINSERT INTO data VALUES ('new')\r", b"Execute this database write?")
            os.write(terminal.master, b"\x1b[")
            time.sleep(0.25)
            terminal.send(b"y", b"Execute this database write?")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchall(), [("original",)])
            terminal.send(b"n", b"Cancelled")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_arrows_search_and_commands(self):
        with sqlite3.connect(self.path) as db:
            db.executemany("INSERT INTO data VALUES (?)", [("match-one",), ("match-two",)])
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b"\t", b"[RO] NORMAL | ROWS")
            terminal.send(b"\x1b[B", b"[match-one]")
            terminal.send(b"/match\r", b"Match found")
            self.assertIn(b"[match-two]", terminal.data[-2000:])
            terminal.send(b"n", b"Match found")
            self.assertIn(b"[match-one]", terminal.data[-2000:])
            terminal.send(b"N", b"Match found")
            self.assertIn(b"[match-two]", terminal.data[-2000:])
            terminal.send(b":reload\r", b"Database reloaded")
            terminal.send(b":help\r", b"HELP | Press any key")
            terminal.send(b"x", b"[RO] NORMAL")
            terminal.send(b":unknown\r", b"Unknown command")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_escape_followed_by_quit_does_not_drop_key(self):
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b"iSELECT 42", b"SQL> SELECT 42")
            os.write(terminal.master, b"\x1bq")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_query_error_does_not_hide_later_page_status(self):
        with sqlite3.connect(self.path) as db:
            db.executemany("INSERT INTO data VALUES (?)", [(str(i),) for i in range(510)])
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b"iSELECT * FROM missing_table\r", b"no such table")
            terminal.send(b"i\x15SELECT * FROM data\r", b"Read-only query results")
            terminal.send(b"]", b"Row page changed")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_rejects_file_and_statement_escape_attempts(self):
        victim = self.path.parent / "victim.sqlite"
        victim.write_bytes(b"unrelated content")
        original = hashlib.sha256(victim.read_bytes()).digest()
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            attempts = [
                b"ATTACH 'victim.sqlite' AS victim",
                b"PRAGMA writable_schema=ON",
                b"SELECT load_extension('victim.sqlite')",
                b"SELECT 1; DELETE FROM data",
                b"VACUUM INTO 'victim.sqlite'",
            ]
            for sql in attempts:
                if sql.startswith(b"VACUUM"):
                    terminal.send(b"i\x15" + sql + b"\r", b"Execute this database write?")
                    terminal.send(b"y", b"[RW] NORMAL")
                else:
                    terminal.send(b"i\x15" + sql + b"\r", b"[RW] NORMAL")
                    self.assertNotIn(b"Execute this database write?", terminal.data[-500:])
            self.assertEqual(hashlib.sha256(victim.read_bytes()).digest(), original)
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchall(), [("original",)])
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()


if __name__ == "__main__":
    unittest.main()
