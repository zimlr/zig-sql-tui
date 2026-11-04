import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

from test_recovery import Terminal, TMP


class PagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.path = Path(self.temp.name) / "pages.sqlite"
        with sqlite3.connect(self.path) as db:
            columns = ",".join(f"c{i} TEXT" for i in range(40))
            db.execute(f"CREATE TABLE a_data({columns})")
            placeholders = ",".join("?" for _ in range(40))
            db.executemany(f"INSERT INTO a_data VALUES ({placeholders})", [tuple(f"r{r}c{c}" for c in range(40)) for r in range(501)])
            for i in range(130):
                db.execute(f"CREATE TABLE t{i:03}(value)")

    def tearDown(self):
        self.temp.cleanup()

    def test_table_row_and_column_pages_and_cell_update(self):
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b"]", b"t127")
            terminal.send(b"[", b"a_data")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"]", b"Row 501")
            terminal.send(b">", b"Column 33/40")
            terminal.send(b"e", b"CELL> r500c32")
            terminal.send(b"\x15changed\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute("SELECT c32 FROM a_data WHERE rowid=501").fetchone()[0], "changed")
                self.assertEqual(db.execute("SELECT c0 FROM a_data WHERE rowid=501").fetchone()[0], "r500c0")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_full_text_detail_scroll(self):
        path = Path(self.temp.name) / "detail.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE data(value TEXT)")
            db.execute("INSERT INTO data VALUES (?)", ("x" * 900 + "END-MARKER",))
        terminal = Terminal(path)
        try:
            terminal.wait(b"More below")
            terminal.send(b"\t\t", b"[RO] NORMAL | DETAIL")
            terminal.send(b"20j", b"END-MARKER")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_more_than_128_columns(self):
        path = Path(self.temp.name) / "wide.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE data(" + ",".join(f"c{i} INTEGER" for i in range(150)) + ")")
            db.execute("INSERT INTO data(c128) VALUES (777)")
        terminal = Terminal(path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b"\t", b"[RO] NORMAL | ROWS")
            terminal.send(b">>>>", b"Column 129/150")
            terminal.wait(b"777")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_table_name_over_255_bytes(self):
        long_path = Path(self.temp.name) / "long-name.sqlite"
        name = 'x' * 300
        with sqlite3.connect(long_path) as db:
            db.execute(f'CREATE TABLE "{name}"(value)')
            db.execute(f'INSERT INTO "{name}" VALUES (\'long name works\')')
        terminal = Terminal(long_path)
        try:
            terminal.wait(b"long name works")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_utf8_sql_and_cell_input(self):
        path = Path(self.temp.name) / "unicode.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE data(value TEXT)")
            db.execute("INSERT INTO data VALUES ('mañana')")
        terminal = Terminal(path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.wait(b"ma\\u{F1}ana")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"e", b"CELL>")
            terminal.send(b"\x15" + "世界".encode() + b"\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchone()[0], "世界")
            terminal.send(b":null\r", b"Set selected cell to NULL?")
            terminal.send(b"n", b"Cancelled")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchone()[0], "世界")
            with sqlite3.connect(path) as db:
                db.execute("UPDATE data SET value='external'")
            terminal.send(b":null\r", b"Set selected cell to NULL?")
            terminal.send(b"y", b"Database changed. Reload before editing")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchone()[0], "external")
            terminal.send(b":null\r", b"Set selected cell to NULL?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(path) as db:
                self.assertIsNone(db.execute("SELECT value FROM data").fetchone()[0])
            terminal.send(b"e", b"CELL>")
            terminal.send("ñ".encode() + b"\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchone()[0], "ñ")
            terminal.send(b"iSELECT '" + "mañana".encode() + b"'\r", b"Query results")
            self.assertIn(b"\\u{4E16}\\u{754C}", terminal.data)
            self.assertNotIn("世界".encode(), terminal.data)
            terminal.send(b"i\x15SELECT '" + "\u009b2J\u202e".encode() + b"'\r", b"\\u{9B}2J\\u{202E}")
            terminal.send(b"i\x15SELECT 'x" + "世".encode() + b"\x7f'\r", b"[x]")
            terminal.send(b"i\x15SELECT '\xff\r", b"Invalid UTF-8")
            terminal.send(b"\x1b", b"[RW] NORMAL")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_text_control_bytes_are_escaped_and_preserved(self):
        path = Path(self.temp.name) / "controls.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE data(value TEXT)")
            db.execute("INSERT INTO data VALUES (?)", ("prefix\x1b[2J",))
            db.execute("INSERT INTO data VALUES (?)", ("with\x00nul",))
        terminal = Terminal(path)
        try:
            terminal.wait(b"prefix\\x1B[2J")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"e", b"CELL> prefix\\x1B[2J")
            terminal.send(b"x\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data WHERE rowid=1").fetchone()[0], "prefix\x1b[2Jx")
            terminal.send(b"j", b"with\\x00nul")
            terminal.send(b"e", b"Cell requires SQL editing")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data WHERE rowid=2").fetchone()[0], "with\x00nul")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_blob_hex_editor(self):
        path = Path(self.temp.name) / "blob.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE data(value BLOB)")
            db.execute("INSERT INTO data VALUES (?)", (bytes.fromhex("00ff7a"),))
        terminal = Terminal(path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"e", b"BLOB hex> 00FF7A")
            terminal.send(b"\x15GG\r", b"Save cell change?")
            terminal.send(b"y", b"Enter an even number of hexadecimal digits")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchone()[0], bytes.fromhex("00ff7a"))
            terminal.send(b"e", b"BLOB hex> 00FF7A")
            terminal.send(b"\x15\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value, typeof(value) FROM data").fetchone(), (b"", "blob"))
            terminal.send(b"e", b"BLOB hex>")
            terminal.send(b"ABCDEF\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data").fetchone()[0], bytes.fromhex("abcdef"))
                db.execute("UPDATE data SET value=?", (b"x" * 2049,))
            terminal.send(b":reload\r", b"Database reloaded")
            terminal.send(b"e", b"BLOB exceeds the hex editor limit")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT length(value) FROM data").fetchone()[0], 2049)
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_readonly_query_pages(self):
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            query = b"SELECT c0, c1 FROM a_data ORDER BY rowid"
            terminal.send(b"i" + query + b"\r", b"Read-only query results")
            terminal.send(b"]", b"r500c0")
            terminal.send(b"[", b"r0c0")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()


if __name__ == "__main__":
    unittest.main()
