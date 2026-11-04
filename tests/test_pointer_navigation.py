import fcntl
import os
from pathlib import Path
import signal
import sqlite3
import struct
import tempfile
import termios
import unittest

from test_recovery import Terminal, TMP


class PointerNavigationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.path = Path(self.temp.name) / "test.sqlite"
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TABLE a(value TEXT)")
            db.executemany("INSERT INTO a VALUES (?)", [(f"item-{i:02d}",) for i in range(40)])
        self.term = Terminal(self.path)
        self.term.wait(b"[RO] NORMAL")

    def tearDown(self):
        self.term.close()
        self.temp.cleanup()

    def test_home_end_page_and_buffered_redraw(self):
        t = self.term
        t.send(b"\t", b"[RO] NORMAL | ROWS")
        start = len(t.data)
        t.send(b"\x1b[F", b"> [item-39]")
        self.assertNotIn(b"\x1b[2J", t.data[start:])
        t.send(b"\x1b[H", b"> [item-00]")
        t.send(b"\x1b[6~", b"> [item-17]")
        t.send(b"\x1b[5~", b"> [item-00]")
        t.send(b"\x1b[4~", b"> [item-39]")
        t.send(b"\x1b[1~", b"> [item-00]")
        os.write(t.master, b"q")
        self.assertEqual(t.proc.wait(timeout=5), 0)
        t.wait(b"\x1b[?1006l")

    def test_tap_tabs_items_wheel_and_drag(self):
        t = self.term
        # Compact table names use ten columns instead of the old fixed 24.
        start = len(t.data)
        fcntl.ioctl(t.master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.kill(t.proc.pid, signal.SIGWINCH)
        t.wait(b"\x1b[3;12HROWS:", start)
        t.send(b"\x1b[<0;11;2M", b"[RO] NORMAL | ROWS")
        t.send(b"\x1b[<0;14;8M", b"> [item-03]")
        t.send(b"\x1b[<64;14;8M", b"> [item-00]")
        t.send(b"\x1b[<65;14;8M", b"> [item-03]")
        t.send(b"\x1b[<0;14;8M", b"> [item-03]")
        t.send(b"\x1b[<32;14;5M", b"> [item-06]")
        t.send(b"\x1b[<0;14;5m", b"> [item-06]")
        t.send(b"\x1b[<0;3;2M", b"[RO] NORMAL | TABLES")

    def test_narrow_tabs_and_long_mouse_sequence(self):
        t = self.term
        start = len(t.data)
        fcntl.ioctl(t.master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 40, 0, 0))
        os.kill(t.proc.pid, signal.SIGWINCH)
        t.wait(b"Tab: panel", start)
        t.send(b"\x1b[<0;10;2M", b"[RO] NORMAL | ROWS")
        t.send(b"\x1b[<0;4;6M", b"> [item-01]")
        t.send(b"\x1b[<" + b"9" * 100 + b";4;6M", b"> [item-01]")
        t.send(b"\x1b[<0;18;2M", b"[RO] NORMAL | DETAIL")
        t.send(b"\x1b[<0;3;2M", b"[RO] NORMAL | TABLES")

    def test_mouse_cannot_confirm_write(self):
        t = self.term
        t.send(b":set rw\r", b"Enable write mode")
        t.send(b"\x1b[<0;5;22M", b"Enable write mode")
        t.send(b"n", b"Cancelled")
        self.assertNotIn(b"[RW] NORMAL", t.data)
