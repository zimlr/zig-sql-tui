import os
import fcntl
import signal
import struct
import termios
from pathlib import Path
import sqlite3
import tempfile
import unittest

from test_recovery import Terminal, TMP


class GlobalSearchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.path = Path(self.temp.name) / 'search.sqlite'
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE data(' + ','.join(f'c{i} TEXT' for i in range(40)) + ')')
            db.executemany('INSERT INTO data(c0) VALUES (?)', [(f'row-{i}',) for i in range(1101)])
            db.execute('UPDATE data SET c39=? WHERE rowid=502', ('x' * 300 + 'needle',))
            db.execute('UPDATE data SET c39=? WHERE rowid=1101', ('needle',))
            for i in range(130):
                db.execute(f'CREATE TABLE tab{i:03}(value)')

    def tearDown(self):
        self.temp.cleanup()

    def test_row_search_crosses_pages_and_columns_and_wraps(self):
        term = Terminal(self.path)
        try:
            term.wait(b'[RO] NORMAL')
            term.send(b'\t', b'[RO] NORMAL | ROWS')
            term.send(b'/needle\r', b'Match found')
            self.assertIn(b'Row 502  Column 40/40', term.data)
            term.send(b'n', b'Row 1101  Column 40/40')
            term.send(b'n', b'Row 502  Column 40/40')
            term.send(b'N', b'Row 1101  Column 40/40')
            term.send(b'/does-not-exist\r', b'No match')
            self.assertIn(b'Row 1101  Column 40/40', term.data)
            os.write(term.master, b'q')
            self.assertEqual(term.proc.wait(timeout=5), 0)
        finally:
            term.close()

    def test_query_search_and_table_name_search(self):
        term = Terminal(self.path)
        try:
            term.wait(b'[RO] NORMAL')
            term.send(b'/tab129\r', b'Match found')
            term.wait(b'> tab129')
            term.send(b':reload\r', b'Database reloaded')
            term.send(b'/data\r', b'Match found')
            term.send(b'iSELECT c0, c39 FROM data ORDER BY rowid\r', b'Read-only query results')
            term.send(b'/needle\r', b'Match found')
            term.wait(b'Row 502  Column 2/2')
            term.send(b'n', b'Row 1101  Column 2/2')
            term.send(b'N', b'Row 502  Column 2/2')
            os.write(term.master, b'q')
            self.assertEqual(term.proc.wait(timeout=5), 0)
        finally:
            term.close()

    def test_search_last_column_at_sqlite_limit(self):
        path = Path(self.temp.name) / 'wide.sqlite'
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE wide(' + ','.join(f'c{i} TEXT' for i in range(2000)) + ')')
            db.execute("INSERT INTO wide(c1999) VALUES ('last-column')")
        term = Terminal(path)
        try:
            term.wait(b'[RO] NORMAL')
            term.send(b'\t', b'[RO] NORMAL | ROWS')
            term.send(b'/last-column\r', b'Row 1  Column 2000/2000')
            term.wait(b'last-column')
            os.write(term.master, b'q')
            self.assertEqual(term.proc.wait(timeout=5), 0)
        finally:
            term.close()

    def test_interrupted_search_does_not_report_no_match(self):
        term = Terminal(self.path)
        try:
            term.wait(b'[RO] NORMAL')
            query = b'iWITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT x FROM n\r'
            term.send(query, b'Read-only query results')
            term.send(b'/not-present\r', b'interrupted')
            self.assertNotIn(b'No match', term.data)
            os.write(term.master, b'q')
            self.assertEqual(term.proc.wait(timeout=5), 0)
        finally:
            term.close()

    def test_search_without_rowid_in_write_mode(self):
        path = Path(self.temp.name) / 'without-rowid.sqlite'
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE data(k TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID')
            db.executemany('INSERT INTO data VALUES (?, ?)',
                           [(f'key-{i:04d}', 'target' if i == 700 else 'other') for i in range(800)])
        term = Terminal(path)
        try:
            term.wait(b'[RO] NORMAL')
            term.send(b':set rw\r', b'Enable write mode')
            term.send(b'y', b'Write mode enabled')
            term.send(b'\t', b'[RW] NORMAL | ROWS')
            term.send(b'/target\r', b'Row 701  Column 2/2')
            term.send(b'e', b'CELL> target')
            term.send(b'\x15changed\r', b'Save cell change?')
            term.send(b'y', b'Cell update committed')
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data WHERE k='key-0700'").fetchone()[0], 'changed')
            os.write(term.master, b'q')
            self.assertEqual(term.proc.wait(timeout=5), 0)
        finally:
            term.close()

    def test_page_buttons_and_centered_resize_warning(self):
        term = Terminal(self.path)
        try:
            term.wait(b'[RO] NORMAL')
            term.send(b'\t', b'[RO] NORMAL | ROWS')
            term.send(b'\x1b[<0;29;2M', b'Row 501')
            term.send(b'\x1b[<0;25;2M', b'Row 1  Column 1/40')
            start = len(term.data)
            fcntl.ioctl(term.master, termios.TIOCSWINSZ, struct.pack('HHHH', 10, 35, 0, 0))
            os.kill(term.proc.pid, signal.SIGWINCH)
            term.wait(b'\x1b[5;1HResize terminal to at least 40 x 12', start)
            start = len(term.data)
            fcntl.ioctl(term.master, termios.TIOCSWINSZ, struct.pack('HHHH', 7, 20, 0, 0))
            os.kill(term.proc.pid, signal.SIGWINCH)
            term.wait(b'\x1b[3;2HResize terminal to', start)
            term.wait(b'\x1b[4;3Hat least 40 x 12', start)
            os.write(term.master, b'q')
            self.assertEqual(term.proc.wait(timeout=5), 0)
        finally:
            term.close()

    def test_write_mode_search_keeps_edit_key(self):
        term = Terminal(self.path)
        try:
            term.wait(b'[RO] NORMAL')
            term.send(b':set rw\r', b'Enable write mode')
            term.send(b'y', b'Write mode enabled')
            term.send(b'\t', b'[RW] NORMAL | ROWS')
            term.send(b'/needle\r', b'Row 502  Column 40/40')
            term.send(b'n', b'Row 1101  Column 40/40')
            term.send(b'e', b'CELL> needle')
            term.send(b'\x15changed\r', b'Save cell change?')
            term.send(b'y', b'Cell update committed')
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute('SELECT c39 FROM data WHERE rowid=1101').fetchone()[0], 'changed')
            os.write(term.master, b'q')
            self.assertEqual(term.proc.wait(timeout=5), 0)
        finally:
            term.close()
