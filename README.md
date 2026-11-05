<img src="assets/zsqt-logo.png" alt="zsqt logo" width="192">

<a href="https://github.com/zimlr/zsqt/actions/workflows/ci.yml"><img src="https://github.com/zimlr/zsqt/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
<a href="https://github.com/zimlr/zsqt/actions/workflows/termux-compat.yml"><img src="https://github.com/zimlr/zsqt/actions/workflows/termux-compat.yml/badge.svg" alt="Termux compatibility status"></a>

# zsqt

zsqt is a keyboard-first SQLite terminal browser and editor that opens databases read-only by default.

## Features

- Browse tables, rows, columns, and cell details.
- Navigate with arrow keys or Vim-style keys, counts, search, and commands.
- Run SQL queries and page through results.
- Edit cells or execute write statements after confirmation.
- Open rollback-mode and WAL-mode databases with SQLite locking.
- Work offline with statically linked SQLite.

## Installation

Download the archive for x86_64 or aarch64 Linux from [GitHub Releases](https://github.com/zimlr/zsqt/releases). The existing `v1.0.0` release retains the former project and executable names:

```sh
tar -xzf zig-sql-tui-v1.0.0-x86_64-linux-musl.tar.gz
./zig-sql-tui path/to/database.sqlite
```

Version `v1.0.0` fails on Android 13 Termux with `Bad system call`. See [testing](TESTING.md) for the status of the fix. Builds from the current source use the `zsqt` executable name. The features and controls described below apply to current source and may differ from `v1.0.0`. A Windows port is not planned.

To build from source, install Zig 0.17.1 at `tools/zig/zig` and run:

```sh
mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
TMPDIR="$PWD/.zig-cache/tmp" \
./tools/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true
```

Use `-Dtarget=aarch64-linux-musl` for aarch64 Linux. The executable is installed at `zig-out/bin/zsqt`. Compiler setup and other build instructions are in [building](docs/building.md).

## Usage

The title shows the database path, focused panel, interaction mode, and access state. `[RO]` indicates read-only mode, and `[RW]` indicates write mode.

| Action | Keys |
| --- | --- |
| Switch panels | Tab or Enter |
| Move through items or columns | Arrow keys or `hjkl` |
| Move by a count | `5j`, `5k`, `5h`, or `5l` |
| Move to the first or last item on a page | `gg` or `G`, Home or End |
| Scroll by a screen | Page Up or Page Down |
| Change table or row page | `[` or `]` |
| Change column page | `<` or `>` |
| Search all pages in the selected table, query, or table list | `/`, then `n` or `N` |
| Enter SQL | `i` |
| Edit a selected cell | `e` in write mode |
| Show help | `?` or `:help` |
| Reload or quit | `:reload` or `q` |
| Complete commands | `Tab` after `:` and repeat to cycle matches |

Select a table, then press Tab to browse its rows. Mouse users can select tabs and rows, change pages with `[<]` and `[>]`, use the wheel, or drag to scroll when the terminal sends mouse events. Each wheel or drag motion event moves at most one item. The page indicator uses `+` when another page is available. Search wraps across pages in the focused table list or rows. Cycle to the details panel to inspect a cell. SQL and cell input are append-only and ignore arrow keys. Press Ctrl-U to clear input, Enter to submit, or Esc to cancel.

### Write data

1. Enter `:set rw`, press Enter, and confirm with `y`.
2. Select a table cell and press `e`. Enter a value and press Enter.
3. Confirm the change with `y`. Enter `:set ro` to return to read-only mode.

Write SQL entered with `i` also requires confirmation. Use `:null` to set a selected cell to NULL. Cell editing is available for eligible table rows, not query results. Use `:reload` to return to the table view.

### Shell completion

Completion files for Bash, Zsh, and Fish are installed under `zig-out/share` by the build. Archives produced by the current release workflow include the files in `completions`. The published `v1.0.0` archive does not include them. Source the Bash file, place `_zsqt` in a Zsh `fpath` directory before `compinit`, or copy the Fish file to `~/.config/fish/completions/zsqt.fish`.

### Check or recover a database

```sh
./zsqt --check path/to/database.sqlite
./zsqt --recover path/to/database.sqlite
```

For interactive use, place `--` before a database path beginning with `--`. The check verifies that the reader can open the database, not its integrity. Recovery requires a terminal and explicit confirmation before it modifies the database or journal. Entering write mode may also allow SQLite to perform recovery.

Run `zsqt --debug` to exercise rollback writes, WAL, and recovery using disposable fixtures under `$HOME/.zsqt`. This option authorizes fixture writes and does not open an existing user database. See [testing](TESTING.md) for setup and cleanup details.

## Safety and limitations

- Access is confined to the selected database and its WAL, SHM, and rollback-journal sidecars. Read-only WAL access may create or update the SHM sidecar.
- Attachment, extension loading, and SQL PRAGMAs are disabled. Super-journal recovery is not supported.
- Database paths must not contain symbolic links.
- The terminal must be at least 40 columns by 12 rows.

See [limitations](docs/limitations.md) for input, display, and editing bounds.

## Documentation

- [Building](docs/building.md)
- [Testing and Android diagnostics](TESTING.md)
- [Dependencies](DEPENDENCIES.md)
- [Release procedure](RELEASING.md)
- [Security policy](SECURITY.md)
