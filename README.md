# zig-sql-tui

The application is a keyboard-first Zig terminal interface for SQLite databases. It opens databases read-only by default.

## Database safety

- Rollback-mode and WAL-mode databases use SQLite locking and may be browsed while other connections are active.
- A hot rollback journal requires recovery before read-only access. Run `--recover` and confirm before SQLite modifies the database and journal.
- Enter `:set rw` and confirm the mode change to enable writes. Enabling write mode may also allow SQLite to perform recovery. Use `:set ro` to return to read-only mode.
- Each write statement and cell change requires confirmation and runs in a transaction. Cell edits reject stale data if another connection has committed since the row was loaded.
- Database access requires Linux `openat2` support and a database path without symbolic links. SQLite may create or update the database's SHM sidecar even in read-only WAL mode.

## Current limitations

- Recovery requiring a super-journal is not supported. Super-journals are outside the file allowlist.
- Table names longer than 4096 bytes are skipped. SQLite queries are limited to 2000 columns. A 2000-column rowid table cannot use cell editing. WITHOUT ROWID tables with more than 900 primary-key columns are read-only in the cell editor.
- Table and query pages are re-executed when navigated. Concurrent changes or nondeterministic SQL can change the displayed rows. Search covers the current page only.
- Grid cells show a 255-byte preview. The detail panel re-reads longer text values. A changed or unavailable value may prevent full display.
- Cell editing supports ordinary rowid and WITHOUT ROWID tables. Rowid tables with all aliases shadowed require a non-null primary key. BLOB editing accepts up to 2048 bytes as hexadecimal. Use SQL to insert control characters or edit NUL-containing text, text exceeding 4096 bytes, larger BLOBs, and column names exceeding 255 bytes.
- SQL entry accepts one statement of up to 4096 UTF-8 bytes. SQLite limits schema SQL to 1 MiB, and queries have an execution budget and a 16 MiB value limit. Attachment, extension loading, and SQL PRAGMAs are disabled.
- Non-ASCII code points are shown as Unicode escapes. Invalid UTF-8 and ASCII control bytes use hexadecimal escapes to prevent terminal escape injection.

## Build

Install Zig 0.17.1 at `tools/zig/zig`. The compiler and caches must remain inside the workspace. No download occurs during the build.

```sh
mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true
```

For Termux, replace the target with `aarch64-linux-musl`. Both builds compile the vendored SQLite amalgamation into the executable.

## Run

```sh
./zig-out/bin/zig-sql-tui path/to/database.sqlite
```

Switch panels with Tab or Enter, and move through rows and columns with arrow keys or `hjkl`. Page tables or rows with `[` and `]`, and page columns with `<` and `>`. Press `?` for help and `q` to quit. Search with `/`, then press `n` or `N` to move between matches.

Press `i` to enter SQL. In write mode, select a cell and press `e` to edit it. Use `:null` to set the selected cell to NULL. Editing a NULL cell replaces it with text. Edit BLOB values as hexadecimal bytes. Input is append-only and ignores arrow keys. Press Enter to submit, Esc to cancel, or Ctrl-U to clear the input. Use `:reload` to refresh database contents.

Use `--check path/to/database.sqlite` to check whether the reader can open a database. This is not an integrity check. If a hot journal prevents access, run `--recover path/to/database.sqlite` and confirm recovery.

## Test

Run the security boundary and integration tests with the pinned compiler:

```sh
python3 tools/check_prose.py
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build test -Doptimize=ReleaseSmall
python3 -m unittest discover -s tests -p 'test_*.py'
```

Build the x86_64 executable before running the Python tests. Tests create fixtures under `.zig-cache/tmp`. The [test checklist](TESTING.md) records coverage and remaining validation limits.
