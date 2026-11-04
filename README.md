# zig-sql-tui

The application is a keyboard-first Zig terminal interface for SQLite databases. Discoverable controls and composable Vim-like commands support browsing and editing. Databases open read-only by default. A Windows port is not planned.

## Database safety

- Rollback-mode and WAL-mode databases use SQLite locking and support concurrent connections.
- A hot rollback journal requires confirmed recovery before read-only access. Run `--recover` to start recovery.
- Enter `:set rw` and confirm the mode change to enable writes. The mode change may allow SQLite to perform recovery. Return to read-only mode with `:set ro`.
- Each write statement and cell change requires confirmation and runs in a transaction. Cell edits reject stale data after another connection commits.
- Database access requires Linux `openat2` support and a path without symbolic links. SQLite may create or update the SHM sidecar in read-only WAL mode.

## Current limitations

- Recovery requiring a super-journal is not supported because super-journals are outside the file allowlist.
- Table names longer than 4096 bytes are skipped. SQLite queries are limited to 2000 columns.
- Cell editing is unavailable for rowid tables with 2000 columns and WITHOUT ROWID tables with more than 900 primary-key columns.
- Table and query pages are re-executed when navigated. Concurrent changes or nondeterministic SQL can change the displayed rows. Search covers the current page only.
- Grid cells show a 255-byte preview. The detail panel re-reads longer text values, but a changed or unavailable value may prevent full display.
- Cell editing supports ordinary rowid and WITHOUT ROWID tables. Rowid tables with shadowed aliases require a non-null primary key. BLOB editing accepts up to 2048 bytes as hexadecimal.
- SQL is required to insert control characters or edit NUL-containing text, text exceeding 4096 bytes, larger BLOBs, and column names exceeding 255 bytes.
- SQL entry accepts one statement of up to 4096 UTF-8 bytes. SQLite limits schema SQL to 1 MiB. Queries have an execution budget and a 16 MiB value limit.
- Attachment, extension loading, and SQL PRAGMAs are disabled.
- Non-ASCII code points are shown as Unicode escapes. Invalid UTF-8 and ASCII control bytes use hexadecimal escapes to prevent terminal escape injection.

## Build

Install Zig 0.17.1 at `tools/zig/zig`. The compiler and caches must remain inside the workspace. No download occurs during the build.

```sh
mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true
```

The `aarch64-linux-musl` target produces a static aarch64 Linux executable. Both builds compile the vendored SQLite amalgamation into the executable.

Native Termux compatibility remains unverified. Android app seccomp policies may block the required `openat2` and `faccessat2` syscalls. A Linux seccomp probe terminates the x86_64 executable when `openat2` is trapped.

## Run

```sh
./zig-out/bin/zig-sql-tui path/to/database.sqlite
```

Switch panels with Tab or Enter. Move through rows and columns with arrow keys or `hjkl`. Page tables or rows with `[` and `]`, and page columns with `<` and `>`. Press `?` for help and `q` to quit. Search with `/`, then press `n` or `N` to move between matches.

Press `i` to enter SQL. In write mode, select a cell and press `e` to edit it. Set the selected cell to NULL with `:null`. Editing a NULL cell replaces it with text. BLOB values use hexadecimal input. Input is append-only and ignores arrow keys. Press Enter to submit, Esc to cancel, or Ctrl-U to clear the input. Refresh database contents with `:reload`.

The `--check path/to/database.sqlite` command checks whether the reader can open a database. It does not check database integrity. If a hot journal prevents access, run `--recover path/to/database.sqlite` and confirm recovery.

## Test

Run the security boundary and integration tests with the pinned compiler:

```sh
python3 tools/check_prose.py
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build test -Doptimize=ReleaseSmall
python3 -m unittest discover -s tests -p 'test_*.py'
```

Build the x86_64 executable before running the Python tests. Fixtures remain under `.zig-cache/tmp`. The [test checklist](TESTING.md) records coverage and validation limits.
