<img src="assets/zsqt-logo.png" alt="zsqt logo" width="192">

<a href="https://github.com/zimlr/zsqt/actions/workflows/ci.yml"><img src="https://github.com/zimlr/zsqt/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
<a href="https://github.com/zimlr/zsqt/actions/workflows/termux-compat.yml"><img src="https://github.com/zimlr/zsqt/actions/workflows/termux-compat.yml/badge.svg" alt="Termux compatibility status"></a>

# zsqt

zsqt is a keyboard-first terminal user interface (TUI) for browsing and editing SQLite databases, and it opens databases read-only by default.

## Features

The interface browses tables, rows, columns, and cell details, and it responds to arrow keys, Vim-style keys, counts, search, and commands. SQL queries run in the same view, and their results page in place. Cells and write statements require explicit confirmation, and SQLite locking covers rollback-mode and WAL-mode databases. Static linking keeps SQLite inside the executable, and every feature works offline.

## Installation

Download the archive for x86_64 or aarch64 Linux from [GitHub Releases](https://github.com/zimlr/zsqt/releases). Extract the x86_64 archive and run the executable:

```sh
tar -xzf zsqt-v2.0.0-x86_64-linux-musl.tar.gz
./zsqt path/to/database.sqlite
```

Releases published with the current workflow include Debian packages for `amd64` and `arm64`, while published release `v2.0.0` contains archives only. Install a matching package on Debian-based Linux with `sudo dpkg -i ./zsqt-vX.Y.Z-amd64.deb`, replacing `vX.Y.Z` with the release tag. Debian packages use `/usr` paths and do not target Termux.

The `v1.0.0` release uses the former `zig-sql-tui` project and executable names, and that release fails on Android 13 Termux with `Bad system call`. Termux validation status and remaining device checks appear in [testing](TESTING.md).

The features and controls below describe current source and may differ from published releases, and a Windows port is not planned.

To build from source, install Zig 0.17.1 at `tools/zig/zig` and run:

```sh
mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
TMPDIR="$PWD/.zig-cache/tmp" \
./tools/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true
```

Use `-Dtarget=aarch64-linux-musl` for aarch64 Linux, and the executable is installed at `zig-out/bin/zsqt`. Compiler setup and other build instructions are in [building](docs/building.md).

## Usage

The title shows the access state, interaction mode, focused panel, and database path. `[RO]` marks read-only access, and `[RW]` marks write mode. The mode field shows `NORMAL`, `COMMAND`, `SEARCH`, `INSERT`, `HELP`, or `CONFIRM`.

| Action | Keys |
| --- | --- |
| Cycle panels | Tab or Enter |
| Move from the table list into the rows | `l` |
| Move from the details panel back to the rows | `h` |
| Move through items or columns | Arrow keys or `hjkl` |
| Move by a count | `5j`, `5k`, `5h`, or `5l` |
| Move to the first or last item on a page | `gg`, `G`, Home, or End |
| Move to the fifth item | `5gg` or `5G` |
| Scroll the details value | `j`, `k`, Page Up, or Page Down |
| Move to the start or end of the details value | Home or End |
| Change the table or row page | `[` or `]` |
| Change the column page | `<` or `>` |
| Search the table list or rows | `/`, then `n` or `N` |
| Enter SQL | `i` |
| Edit the selected cell | `e` in write mode |
| Set the selected cell to NULL | `:null` in write mode |
| Show help | `?` or `:help` |
| Reload the database | `:reload` |
| Change access mode | `:set rw` or `:set ro` |
| Quit | `q`, `:q`, or `:quit` |
| Complete a command | `Tab` after `:` |

Counts apply to `hjkl`, `gg`, and `G`, and each page holds 128 tables, 500 rows, or 32 columns. The page label shows `+` while another page exists.

A search wraps across pages and matches text values and BLOB size labels. The table list and rows accept a search, and the details panel reports that one of those panels is required.

The command line accepts `help`, `null`, `reload`, `set ro`, `set readonly`, `set rw`, `set write`, `q`, and `quit`. Tab cycles through commands that match the input, and an unknown command shows a reminder about the help screen. The `help` command or `?` opens the help screen, and any key closes it.

Input accepts up to 4096 UTF-8 bytes and ignores arrow keys. Backspace or Ctrl-H deletes the last character, Ctrl-U clears the input, Enter submits, and Esc cancels. A confirmation accepts `y` or `Y`, and `n`, `N`, or Esc cancels it. Other keys are ignored while a confirmation is pending, including `q`.

Mouse support requires a terminal that reports SGR mouse events. A click selects a panel tab, a row, or a column, and the `[<]` and `[>]` labels change pages. The wheel and drag gestures move at most one item per event.

The interface requires a terminal of at least 40 columns by 12 rows. Below that size only Esc, `n`, `N`, and `q` have an effect.

### Write data

1. Enter `:set rw`, press Enter, and confirm with `y`.
2. Select a table cell and press `e`. Enter a value and press Enter.
3. Confirm the change with `y`. Enter `:set ro` to return to read-only mode.

Write SQL entered with `i` requires confirmation and shows `Execute this database write? y/n`. The `:null` command sets the selected cell to NULL after confirmation. Cell editing applies to eligible table rows and not to query results. A BLOB cell opens as hexadecimal text of up to 2048 bytes, and a NULL cell opens an empty field. The `:reload` command returns to the table view.

### Shell completion

The build installs Bash, Zsh, and Fish completion files under `zig-out/share`. Release archives include the files in `completions` for every release after `v1.0.0`, and Debian packages install them under `/usr/share`.

Source the Bash file, place `_zsqt` in a Zsh `fpath` directory before `compinit`, or copy the Fish file to `~/.config/fish/completions/zsqt.fish`.

### Check or recover a database

```sh
./zsqt --check path/to/database.sqlite
./zsqt --recover path/to/database.sqlite
```

Place `--` before a database path that begins with `--`, for example `zsqt -- --db.sqlite`. The terminator is also accepted after `--check` or `--recover`. A check verifies that the reader can open the database without testing file integrity. Recovery requires a terminal and explicit confirmation before it modifies the database or journal, and entering write mode may also allow SQLite to perform recovery.

Run `zsqt --debug` to exercise rollback writes, WAL, and recovery using disposable fixtures under `$HOME/.zsqt`. This option authorizes fixture writes and does not open an existing user database. Setup and cleanup details for the fixtures appear in [testing](TESTING.md).

## Safety and limitations

- Access is confined to the selected database and its WAL, SHM, and rollback-journal sidecars. Read-only WAL access may create an empty WAL and the SHM sidecar, which requires a writable database directory.
- Attachment, extension loading, and SQL PRAGMAs are disabled, and recovery requiring a super-journal is not supported.
- Database paths must not contain symbolic links at any component.
- The terminal must be at least 40 columns by 12 rows.

See [limitations](docs/limitations.md) for input, display, and editing bounds.

## Documentation

- [Building](docs/building.md)
- [Testing and Android diagnostics](TESTING.md)
- [Dependencies](DEPENDENCIES.md)
- [Release procedure](RELEASING.md)
- [Security policy](SECURITY.md)
