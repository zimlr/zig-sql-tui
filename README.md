# zig-sql-tui

A keyboard-first Zig terminal interface for SQLite databases. The application opens databases read-only by default.

## Database safety

- Rollback-mode databases are opened as read-only snapshots. Open them only after a clean shutdown of all other applications.
- WAL-mode databases use SQLite's WAL locking and may be browsed while other connections are active. Open only established WAL databases with no pending rollback recovery.
- Recovery journals are outside the permitted file allowlist and cannot be inspected. The application requires confirmation of this limitation before interactive use.
- Write mode is available only for WAL databases. Enter `:set rw` and confirm the mode change. Use `:set ro` to return to read-only mode.
- Each write statement and cell change requires confirmation and runs in a transaction. Cell edits reject stale data if another connection has committed since the row was loaded.
- WAL access requires Linux `openat2` support and a database path without symbolic links. SQLite may create or update the database's SHM sidecar even in read-only mode.

## Current limitations

- A rollback-mode database requiring recovery cannot be detected safely. The application never reads its rollback journal.
- Rollback-mode databases cannot be edited. The application does not change a database's journal mode.
- Database files are limited to 256 MiB. Results show at most 500 rows and 32 columns, with cell values truncated to 255 bytes.
- Cell editing supports ordinary rowid tables and ASCII text, integer, and real values. Use SQL for NULL, BLOB, non-ASCII, truncated values, and WITHOUT ROWID tables.
- SQL entry accepts one statement of up to 255 ASCII bytes. Queries have an execution budget and a 16 MiB value limit. Attachment, extension loading, and SQL PRAGMAs are disabled.
- Non-ASCII and control bytes are displayed as `?` to prevent terminal escape injection.

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

Use Tab or Enter to switch panels. Use arrow keys or `hjkl` to move through rows and columns. Press `?` for help and `q` to quit. Search with `/`, then use `n` or `N` to move between matches.

Press `i` to enter SQL. In write mode, select a cell and press `e` to edit it. Press Enter to submit, Esc to cancel, or Ctrl-U to clear the input. Use `:reload` to refresh database contents.

Use `--check path/to/database.sqlite` to check whether the reader can open a database. This is not a database integrity or recovery check.

## Test

Run the security boundary and integration tests with the pinned compiler:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build test -Doptimize=ReleaseSmall
python3 -m unittest discover -s tests -p 'test_*.py'
```

Build the x86_64 executable before running the Python tests. Tests create fixtures under `.zig-cache/tmp`.
