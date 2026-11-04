# Test checklist

Validation uses disposable databases under `.zig-cache/tmp`. Results cover the execution paths listed below.

## Findings

- [x] Escape SQLite error text before terminal output. A malformed schema could inject terminal controls through startup errors. `tests/test_live_audit.py` covers the reported path.
- [x] Synchronize the database directory when SQLite requests it after journal deletion. `tests/security.c` verifies the call and an injected synchronization failure.
- [x] Block confirmation while the terminal is below the minimum size. Terminal tests cover pending writes and recovery.
- [x] Consume complete and fragmented terminal escape sequences without interpreting trailing bytes as commands. Preserve a key following Esc. Terminal tests cover input and confirmation modes.
- [x] Clear stale error state before a new operation. Retain errors from failed table page loads and searches. A terminal test covers paging after a query error.
- [x] Build position-independent executables without an ELF interpreter or shared-library dependencies. The upstream Termux PIE check accepts both Linux candidates.
- [x] Replace `openat2` with an fd-anchored, no-symlink directory walk and single-component sidecar opens. Linux tests exercise the allowlist with restricted syscalls trapped. The native ARM probe passed in [CI run 41926400320](https://github.com/zimlr/zig-sql-tui/actions/runs/41926400320).
- [x] Verify basic startup in the Termux app on Android 13. A user reported that `v1.0.0` terminates with `Bad system call`, while the later ARM64 test build opens a database and displays the TUI. The earlier ARM probe failed in [CI run 41917316005](https://github.com/zimlr/zig-sql-tui/actions/runs/41917316005).

## Coverage

- [x] Review project-owned Markdown and run the mechanical prose check. Third-party SQLite license text remains unchanged.
- [x] Exercise the x86_64 release binary in terminal sessions with rollback and WAL databases.
- [x] Cover navigation, search, help, resizing, queries, access changes, edits, paging, and recovery.
- [x] Check SQL authorization, symlinks and hardlinks, terminal controls, query limits, and SQLite lock handling.
- [x] Run diagnostic fixtures for read-only enforcement, rollback writes, WAL writes, and hot-journal recovery on Linux. Check confirmation, cleanup, symlink rejection, and restricted syscalls.
- [x] Trace selected filesystem and network syscalls during read checks and confirmed writes in rollback and WAL modes on Linux x86_64. These traces cover tested execution paths.
- [x] Build x86_64 and aarch64 binaries and verify static linkage.
- [x] Test SemVer parsing, precedence, release history, and changed-content checks. Mock the release publication commands and verify archive checksums.
- [x] Run the release workflow on GitHub after an explicit user request. The initial release completed in [CI run 41923948348](https://github.com/zimlr/zig-sql-tui/actions/runs/41923948348).
- [x] Run the aarch64 binary on native aarch64 Linux. The ARM runner job passed in [CI run 41926400379](https://github.com/zimlr/zig-sql-tui/actions/runs/41926400379). Syscall tracing remains limited to x86_64.
- [x] Package the aarch64 Linux executable with the pinned Termux build system. The packaging job passed in [CI run 41917316005](https://github.com/zimlr/zig-sql-tui/actions/runs/41917316005).
- [x] Open a database and display the TUI with the packaged ARM64 test binary in Termux on Android 13. The result is a user report.
- [x] Run the isolated diagnostics build in Termux on Android 13. A user reported passing read-only enforcement, rollback writes, WAL writes and reopen, hot-journal recovery, and cleanup.
- [ ] Test TUI confirmation prompts for writes and recovery in the Termux app. The diagnostics flag exercises database operations without the interactive TUI.
- [ ] Test durability under an actual power loss. The directory synchronization test injects a syscall failure instead.

The prose checker covers project-owned Markdown and skips code spans and fenced code. It checks selected punctuation and phrases. Tone, pacing, and other non-mechanical rules require manual review. The syscall tests require Linux x86_64 and permission to use `ptrace`. They skip when those conditions are unavailable.

## Running tests

Build the x86_64 executable before running the security boundary and integration tests:

```sh
python3 tools/check_prose.py
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
TMPDIR="$PWD/.zig-cache/tmp" \
./tools/zig/zig build test -Doptimize=ReleaseSmall
python3 -m unittest discover -s tests -p 'test_*.py'
```

Fixtures remain under `.zig-cache/tmp`. Compiler setup and build commands are in [building](docs/building.md).

A sample database can be created with Python:

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

## Android debug self-test

The CI workflow provides a `termux-debug-aarch64` artifact for testing on ARM64 Termux. Artifacts expire after one day. Download the artifact from the workflow run, extract the ZIP file, and verify the included checksum. Extract the resulting archive and run the diagnostics build:

```sh
sha256sum -c SHA256SUMS
tar -xzf zig-sql-tui-android-arm64-debug.tar.gz
./zig-sql-tui-debug --debug-test --confirm
```

The flag and confirmation authorize writes only to disposable fixtures under `$HOME/.zig-sql-tui`. Results cover read-only enforcement, rollback writes, WAL writes and reopen, hot-journal recovery, and cleanup. The self-test does not open an existing user database or test the TUI confirmation prompts. Copy the complete output for diagnosis.

The regular release build does not include this self-test.

## Termux diagnostic

The [Termux compatibility workflow](https://github.com/zimlr/zig-sql-tui/blob/main/.github/workflows/termux-compat.yml) packages the aarch64 Linux executable with a test-only `termux-packages` recipe. No package is published and no project license is declared by the recipe. An ARM runner executes the upstream PIE check and a Linux seccomp probe against the packaged binary. Detected incompatibilities fail the workflow. Separate testing inside the Termux app remains necessary.

Run the diagnostic locally with an executable matching the Linux host architecture:

```sh
bash tools/fetch_termux_packages.sh
python3 tools/check_termux_candidate.py .zig-cache/termux-packages zig-out/bin/zig-sql-tui
```

The diagnostic traps `openat2`, `faccessat2`, and `fchmodat2` with a Linux seccomp filter. Android policies and Termux app execution are not reproduced.
