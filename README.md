<img src="assets/zig-sql-tui-logo.png" alt="zig-sql-tui logo" width="192">

# zig-sql-tui

The application provides a keyboard-first terminal interface for browsing and editing SQLite databases. Databases open read-only by default. A Windows port is not planned.

## Features

- Browse tables, rows, columns, and cell details in a resizable terminal layout.
- Navigate with arrow keys or Vim-style keys, counts, commands, and search.
- Page through tables, rows, columns, and SQL results. Search covers the current page.
- Run read-only SQL and inspect the resulting rows.
- Enable write mode with confirmation to execute write SQL or edit eligible cells.
- Edit text, numbers, and hexadecimal BLOB values, or set a cell to NULL.
- Use SQLite locking with rollback-mode and WAL-mode databases, including concurrent connections.
- Confirm recovery of a hot rollback journal before database access.
- Operate offline with a statically linked, vendored SQLite engine.

The TUI is implemented in this repository. `src/main.zig` handles rendering and interaction, while `src/sandbox.c` manages terminal input and state. No third-party TUI library is currently used. In particular, [libvaxis](https://github.com/rockorager/libvaxis) is not a dependency.

## Requirements

The desktop build targets x86_64 Linux. An aarch64 Linux build is also available, but native Termux compatibility remains unverified. Version `v1.0.0` terminates with `Bad system call` on Android 13 Termux. Later builds avoid syscalls identified by the Linux seccomp probe, but require testing in the Termux app.

The interface requires a terminal of at least 40 columns by 12 rows. Database paths must not contain symbolic links.

## Build

Zig 0.17.1 is required at `tools/zig/zig`. The following setup provisions the pinned x86_64 Linux compiler. Python 3, `tar`, `xz`, and `sha256sum` are required for these steps.

```sh
(
set -eu
mkdir -p tools/zig .zig-cache/download .zig-cache/global .zig-cache/local .zig-cache/tmp
python3 - <<'PY'
import hashlib
from pathlib import Path
from urllib.request import urlopen

url = 'https://registry.npmjs.org/@zigpm/zig-linux-x64/-/zig-linux-x64-0.17.1.tgz'
path = Path('.zig-cache/download/zig.tgz')
with urlopen(url) as response, path.open('wb') as output:
    while chunk := response.read(1024 * 1024):
        output.write(chunk)
expected = 'fa23b02630bf478a588e66aa049236e1f5b0d920e7a84dc7979400ac3eee6346'
if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
    raise SystemExit('Zig package SHA-256 mismatch')
PY
tar -xzf .zig-cache/download/zig.tgz -C tools/zig --strip-components=1
echo '3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a  tools/zig/zig.tar.xz' | sha256sum -c
tar -xJf tools/zig/zig.tar.xz -C tools/zig --strip-components=1
./tools/zig/zig version
)
```

On other build hosts, provide a matching Zig 0.17.1 compiler and its accompanying libraries at the same path. See [dependencies](DEPENDENCIES.md) for compiler provenance and checksums.

Build the x86_64 executable with the local compiler and caches:

```sh
mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true
```

For aarch64 Linux, use the same command with `-Dtarget=aarch64-linux-musl`. Both builds compile the vendored SQLite amalgamation into the executable. Builds do not download dependencies.

## Open a database

Run the application from a terminal with a path to an existing SQLite database:

```sh
./zig-out/bin/zig-sql-tui path/to/database.sqlite
```

The title displays the path, access state, interaction mode, and focused panel. Access state is `[RO]` for read-only access or `[RW]` for write mode.

For a local example, create a database with Python and open it:

```sh
mkdir -p .zig-cache/tmp
python3 - <<'PY'
import sqlite3

with sqlite3.connect('.zig-cache/tmp/example.sqlite') as db:
    db.execute('CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)')
    db.execute('INSERT OR IGNORE INTO items VALUES (1, ?)', ('example',))
PY
./zig-out/bin/zig-sql-tui .zig-cache/tmp/example.sqlite
```

## Navigate

The bottom line displays context-sensitive controls. Press `?` or enter `:help` for the in-application key reference.

| Key | Action |
| --- | --- |
| Tab or Enter | Cycle through tables, rows, and details. |
| Arrow keys or `hjkl` | Move through the focused panel or select a column. |
| `5j`, `5k`, `5h`, `5l` | Repeat a movement by a count. |
| `gg` or `G` | Move to the first or last item in the current page. |
| `[` or `]` | Move to the previous or next table or row page. |
| `<` or `>` | Move to the previous or next column page from the rows panel. |
| `/` | Enter a search for the current table or row page. |
| `n` or `N` | Find the next or previous match. |
| `:reload` | Reload the database view. |
| `q` or `:q` | Quit the application. |

Select a table in the tables panel and press Tab to browse its rows. Move to a cell and cycle to the details panel to inspect its value. Use Up and Down or `k` and `j` to scroll long details.

For the example database, select `items`, press Tab, then press Right to select its `name` column.

## Run SQL

Press `i`, enter one SQL statement, and press Enter. Read-only statements display results in the rows panel. For the example database, enter `SELECT id, name FROM items`. The previous SQL statement is retained when the input opens again.

Input is append-only and ignores arrow keys. Press Backspace to remove the previous character, Ctrl-U to clear input, or Esc to cancel. SQL statements are limited to 4096 UTF-8 bytes.

In write mode, write statements require confirmation before execution. Attachment, extension loading, and SQL PRAGMAs are disabled.

## Edit data

Cell editing applies to table rows, not SQL results. Enter `:reload` to return from query results to the table view.

1. Enter `:set rw` and press Enter. Confirm the write mode and possible recovery with `y`, or cancel with `n` or Esc.
2. Select a table and move to the rows panel with Tab. Use the arrow keys or `hjkl` to select an editable cell.
3. Press `e` to edit the cell. Use Ctrl-U to clear the existing value, enter the replacement, and press Enter.
4. Confirm the change with `y`, or cancel with `n` or Esc. Each cell update runs in a transaction and rejects stale data.
5. Enter `:set ro` and press Enter to return to read-only mode.

Use `:null` to set the selected editable cell to NULL. Editing a NULL cell replaces it with text. BLOB values use hexadecimal input. The longer forms `:set write` and `:set readonly` are also supported.

## Database safety

- A hot rollback journal requires confirmed recovery before read-only access. Run `--recover` to start recovery.
- Entering write mode may allow SQLite to perform recovery. Each write statement and cell change requires confirmation and runs in a transaction.
- Database access is confined to the explicitly opened database and its WAL, SHM, and rollback-journal sidecars. SQLite may create or update the SHM sidecar in read-only WAL mode.
- The `--check` option checks whether the reader can open a database. It does not check database integrity.

```sh
./zig-out/bin/zig-sql-tui --check path/to/database.sqlite
./zig-out/bin/zig-sql-tui --recover path/to/database.sqlite
```

Recovery requires a terminal and explicit confirmation. Super-journal recovery is not supported because super-journals are outside the file allowlist.

## Current limitations

- Table names longer than 4096 bytes are skipped. SQLite queries are limited to 2000 columns.
- Cell editing is unavailable for rowid tables with 2000 columns and WITHOUT ROWID tables with more than 900 primary-key columns.
- Table and query pages are re-executed when navigated. Concurrent changes or nondeterministic SQL can change the displayed rows. Search covers the current page only.
- Grid cells show a 255-byte preview. The detail panel re-reads longer text values, but a changed or unavailable value may prevent full display.
- Cell editing supports ordinary rowid and WITHOUT ROWID tables. Rowid tables with shadowed aliases require a non-null primary key. BLOB editing accepts up to 2048 bytes as hexadecimal.
- SQL is required to insert control characters or edit NUL-containing text, text exceeding 4096 bytes, larger BLOBs, and column names exceeding 255 bytes.
- SQLite limits schema SQL to 1 MiB. Queries have an execution budget and a 16 MiB value limit.
- Non-ASCII code points are shown as Unicode escapes. Invalid UTF-8 and ASCII control bytes use hexadecimal escapes to prevent terminal escape injection.

## Releases

Release tags follow Semantic Versioning 2.0.0, starting at `v1.0.0`. The manual [release procedure](RELEASING.md) requires an explicit user request and validates unreleased changes.

## Test

Run the security boundary and integration tests with the pinned compiler:

```sh
python3 tools/check_prose.py
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build test -Doptimize=ReleaseSmall
python3 -m unittest discover -s tests -p 'test_*.py'
```

Build the x86_64 executable before running the Python tests. Fixtures remain under `.zig-cache/tmp`. The [test checklist](TESTING.md) records coverage and validation limits.
