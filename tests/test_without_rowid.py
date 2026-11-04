import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

from test_recovery import Terminal, TMP


class WithoutRowidTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.path = Path(self.temp.name) / "keys.sqlite"
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE data("k""odd" TEXT COLLATE NOCASE, b BLOB, value TEXT, PRIMARY KEY("k""odd" COLLATE BINARY, b)) WITHOUT ROWID')
            db.execute("INSERT INTO data VALUES (?, ?, ?)", ("a", b"\x00", "lower"))
            db.execute("INSERT INTO data VALUES (?, ?, ?)", ("A", b"\x00", "upper"))

    def tearDown(self):
        self.temp.cleanup()

    def test_composite_primary_key_and_collation(self):
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"2l", b"Column 3/3")
            terminal.send(b"e", b"CELL> upper")
            terminal.send(b"\x15updated\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(self.path) as db:
                rows = db.execute('SELECT "k""odd", value FROM data ORDER BY "k""odd" COLLATE BINARY').fetchall()
                self.assertEqual(rows, [("A", "updated"), ("a", "lower")])
            terminal.send(b"2l", b"Column 3/3")
            terminal.send(b"e", b"CELL> updated")
            terminal.send(b"\x15stale\r", b"Save cell change?")
            with sqlite3.connect(self.path) as db:
                db.execute('UPDATE data SET value=? WHERE "k""odd" COLLATE BINARY=?', ("external", "A"))
            terminal.send(b"y", b"Database changed. Reload before editing")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute('SELECT value FROM data WHERE "k""odd" COLLATE BINARY=?', ("A",)).fetchone()[0], "external")
            terminal.send(b"l", b"Column 2/3")
            terminal.send(b"e", b"BLOB hex> 00")
            terminal.send(b"\x15ABCD\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(self.path) as db:
                rows = db.execute('SELECT "k""odd", b FROM data ORDER BY "k""odd" COLLATE BINARY').fetchall()
                self.assertEqual(rows, [("A", b"\xab\xcd"), ("a", b"\x00")])
            terminal.send(b"2l", b"Column 3/3")
            terminal.send(b":null\r", b"Set selected cell to NULL?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(self.path) as db:
                rows = db.execute('SELECT "k""odd", value FROM data ORDER BY "k""odd" COLLATE BINARY').fetchall()
                self.assertEqual(rows, [("A", None), ("a", "lower")])
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_shadowed_rowid_uses_nonnull_primary_key(self):
        path = Path(self.temp.name) / "shadowed.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE data(rowid TEXT, _rowid_ TEXT, oid TEXT, k TEXT NOT NULL PRIMARY KEY, value TEXT)")
            db.execute("INSERT INTO data VALUES ('r','u','o','key','before')")
        terminal = Terminal(path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"4l", b"Column 5/5")
            terminal.send(b"e", b"CELL> before")
            terminal.send(b"\x15after\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data WHERE k='key'").fetchone()[0], "after")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_shadowed_rowid_with_nullable_key_is_not_editable(self):
        path = Path(self.temp.name) / "nullable.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE data(rowid TEXT, _rowid_ TEXT, oid TEXT, k TEXT PRIMARY KEY, value TEXT)")
            db.executemany("INSERT INTO data VALUES ('r','u','o',NULL,?)", [("first",), ("second",)])
        terminal = Terminal(path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"4l", b"Column 5/5")
            terminal.send(b"e", b"Select an editable table cell")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value FROM data ORDER BY value").fetchall(), [("first",), ("second",)])
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_descending_key_long_value_and_blob(self):
        path = Path(self.temp.name) / "descending.sqlite"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE data(k INTEGER PRIMARY KEY DESC, value TEXT, blob BLOB) WITHOUT ROWID")
            db.execute("INSERT INTO data VALUES (1, ?, ?)", ("one-" + "x" * 300, b"one"))
            db.execute("INSERT INTO data VALUES (2, ?, ?)", ("two-" + "y" * 300, b"two"))
        terminal = Terminal(path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"l", b"Column 2/3")
            terminal.send(b"e", b"CELL> <")
            terminal.send(b"\x15first row\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            terminal.send(b"2l", b"Column 3/3")
            terminal.send(b"e", b"BLOB hex> 6F6E65")
            terminal.send(b"\x15CAFE\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT value, blob FROM data WHERE k=1").fetchone(), ("first row", b"\xca\xfe"))
                self.assertEqual(db.execute("SELECT value, blob FROM data WHERE k=2").fetchone(), ("two-" + "y" * 300, b"two"))
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_wide_primary_key_falls_back_to_read_only_cell_view(self):
        path = Path(self.temp.name) / "wide-key.sqlite"
        columns = ",".join(f"k{i} INTEGER NOT NULL" for i in range(901))
        keys = ",".join(f"k{i}" for i in range(901))
        with sqlite3.connect(path) as db:
            db.execute(f"CREATE TABLE data({columns}, PRIMARY KEY({keys})) WITHOUT ROWID")
            db.execute("INSERT INTO data VALUES (" + ",".join("1" for _ in range(901)) + ")")
        terminal = Terminal(path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"e", b"Select an editable table cell")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()

    def test_later_page_targets_correct_primary_key(self):
        with sqlite3.connect(self.path) as db:
            db.executemany("INSERT INTO data VALUES (?, ?, ?)", [(f"k{i:04}", b"\x00", f"row{i}") for i in range(500)])
        terminal = Terminal(self.path)
        try:
            terminal.wait(b"[RO] NORMAL")
            terminal.send(b":set rw\r", b"Enable write mode")
            terminal.send(b"y", b"Write mode enabled")
            terminal.send(b"\t", b"[RW] NORMAL | ROWS")
            terminal.send(b"]", b"Row 501")
            terminal.send(b"2l", b"Column 3/3")
            terminal.send(b"e", b"CELL> row498")
            terminal.send(b"\x15page edit\r", b"Save cell change?")
            terminal.send(b"y", b"Cell update committed")
            with sqlite3.connect(self.path) as db:
                self.assertEqual(db.execute('SELECT value FROM data WHERE "k""odd"=?', ("k0498",)).fetchone()[0], "page edit")
                self.assertEqual(db.execute('SELECT value FROM data WHERE "k""odd"=?', ("k0499",)).fetchone()[0], "row499")
            os.write(terminal.master, b"q")
            self.assertEqual(terminal.proc.wait(timeout=5), 0)
        finally:
            terminal.close()


if __name__ == "__main__":
    unittest.main()
