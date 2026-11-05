# Test checklist

Validation uses disposable databases under `.zig-cache/tmp`. Results cover the execution paths listed below.

## Findings

- [x] Build and install an amd64 Debian package into an isolated dpkg root. The installed executable runs terminal and read-only tests without accessing the host package database.
- [x] Reject package architecture mismatches, invalid tags, symbolic links, existing output files, and altered release draft assets. The test uses disposable files and no published release.
- [x] Check Debian version ordering against SemVer prereleases, including alphanumeric identifiers and build metadata.
- [x] Replace repeated page scans during search with a single bounded scan. Terminal fixtures cover distant matches in a 40,000-row, 40-column table and a 373,781-row, 12-column table. The navigation budget remains finite.
- [x] Release-history validation rejects nonregular input without blocking. `tests/test_release_policy.zig` covers a named pipe.
- [x] Markdown scanning rejects symbolic links and nonregular files. `tests/test_prose.zig` covers symlinks and named pipes without following or blocking on them.
- [x] Termux probe setup rejects symbolic links and group-writable or world-writable cache directories. The check assumes the workspace is not modified concurrently by the same user.
- [x] Workspace paths that can be split or expanded by the upstream Termux PIE script are rejected. The Zig probe fails before running the script when its temporary path contains whitespace or glob characters.
- [x] Escape SQLite error text before terminal output. A malformed schema could inject terminal controls through startup errors. `tests/test_live_audit.zig` covers the reported path.
- [x] Synchronize the database directory when SQLite requests it after journal deletion. `tests/security.c` verifies the call and an injected synchronization failure.
- [x] Block confirmation while the terminal is below the minimum size. Terminal tests cover pending writes and recovery.
- [x] Consume complete and fragmented terminal escape sequences without interpreting trailing bytes as commands. Preserve a key following Esc. Terminal tests cover input and confirmation modes.
- [x] Clear stale error state before a new operation. Retain errors from failed table page loads and searches. A terminal test covers paging after a query error.
- [x] Build position-independent executables without an ELF interpreter or shared-library dependencies. The upstream Termux PIE check accepts both Linux candidates.
- [x] Replace `openat2` with an fd-anchored, no-symlink directory walk and single-component sidecar opens. Linux tests exercise the allowlist with restricted syscalls trapped. The native ARM probe passed in [CI run 41926400320](https://github.com/zimlr/zsqt/actions/runs/41926400320).
- [x] Verify basic startup in the Termux app on Android 13. A user reported that `v1.0.0` terminates with `Bad system call`, while the later ARM64 test build opens a database and displays the TUI. The earlier ARM probe failed in [CI run 41917316005](https://github.com/zimlr/zsqt/actions/runs/41917316005).

## Coverage

- [x] Run the mechanical prose check on project-owned Markdown. An earlier manual review missed style violations. Third-party SQLite license text remains unchanged.
- [x] Exercise an x86_64 Linux binary in terminal sessions with rollback and WAL databases.
- [x] Cover navigation, search, help, resizing, queries, access changes, edits, paging, and recovery.
- [x] Check SQL authorization, symlinks and hardlinks, terminal controls, query limits, and SQLite lock handling.
- [x] Run diagnostic fixtures for read-only enforcement, rollback writes, WAL writes, and hot-journal recovery on Linux. Check explicit debug authorization, cleanup, symlink rejection, and restricted syscalls.
- [x] Trace selected filesystem and network syscalls during read checks, cross-page searches, and confirmed writes in rollback and WAL modes on Linux x86_64. These traces cover tested execution paths.
- [x] Verify transferred executable checksums and reject a modified test helper in a local manifest check. These checksums detect mismatches but do not authenticate an artifact and manifest obtained together.
- [x] Run the integration, diagnostic, restricted-syscall, release-policy, completion, and prose suites against the current x86_64 build. The checks cover their tested inputs and paths, not all possible behavior.
- [x] Probe 48 deterministic byte mutations and 16 invalid SQLite headers with the x86_64 `--check` binary. Invalid headers were rejected, and no tested file changed or produced a sidecar. The earlier 48 byte mutations remained readable and do not establish database integrity. `tests/test_app.zig` repeats these checks with a separate fixture.
- [x] Build x86_64 and aarch64 binaries and verify static linkage.
- [x] Test SemVer parsing, precedence, release history, and changed-content checks against isolated Git repositories.
- [x] Run the release workflow on GitHub after an explicit user request. The initial release completed in [CI run 41923948348](https://github.com/zimlr/zsqt/actions/runs/41923948348).
- [x] Run the aarch64 binary and migrated Zig integration suites on native aarch64 Linux. [CI run 41991191779](https://github.com/zimlr/zsqt/actions/runs/41991191779) passed for commit `5e663a5`. Syscall tracing remains limited to x86_64.
- [x] Package the aarch64 Linux executable with the pinned Termux build system and run restricted-syscall tests on native ARM. [Termux compatibility run 41991191752](https://github.com/zimlr/zsqt/actions/runs/41991191752) passed for commit `5e663a5`.
- [x] Open a database and use touch, scrolling, Home, End, Page Up, and Page Down in Termux on Android 13. The result is a user report for a later ARM64 test build.
- [x] Run the isolated diagnostics build in Termux on Android 13. A user reported passing read-only enforcement, rollback writes, WAL writes and reopen, hot-journal recovery, and cleanup.
- [ ] Test TUI confirmation prompts for writes and recovery in the Termux app. The diagnostics flag exercises database operations without the interactive TUI.
- [ ] Test durability under an actual power loss. The directory synchronization test injects a syscall failure instead.

The prose checker covers selected mechanical rules in project-owned Markdown and skips code spans and fenced code. Markdown file symlinks, nonregular Markdown files, and input files exceeding 64 MiB are rejected. Directory symlinks are not traversed. File checks require Linux `statx` and assume the workspace is not modified concurrently. Tone, pacing, and other non-mechanical rules require manual review. The syscall tests require Linux x86_64 and permission to use `ptrace`. They skip when those conditions are unavailable.

## Running tests

The Zig test step runs the Zig suites and the existing C security harness. Linux x86_64 tests also require `dpkg`, `dpkg-deb`, `readelf`, `xz`, and `jq` for Debian package validation. It builds a separate test executable without replacing `zig-out/bin/zsqt`. On Linux x86_64 it also builds a static executable for the syscall audit. The prose and release-policy suites invoke the production Zig tools. Git is required for release-policy tests.

```sh
mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
TMPDIR="$PWD/.zig-cache/tmp" \
./tools/zig/zig build test -Doptimize=ReleaseSmall
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
TMPDIR="$PWD/.zig-cache/tmp" \
./tools/zig/zig build tools -Doptimize=ReleaseSmall
zig-out/tools/check-prose
```

Measure repeated search latency with the disposable 373,781-row benchmark fixture:

```sh
ZSQT_TEST_EXE=zig-out/bin/zsqt \
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
TMPDIR="$PWD/.zig-cache/tmp" \
./tools/zig/zig test -O ReleaseSmall -lc tests/benchmark_search.zig vendor/sqlite/sqlite3.c
```

The benchmark reports initial search and repeated next and previous search times. Results depend on the host, terminal, and storage.

Fixtures use `.zig-cache/tmp`. The diagnostics suite runs against the regular test executable. Current CI configuration also tests the static production executable and its aarch64 counterpart.

CI builds Debian test packages for both architectures. The native ARM job installs the `arm64` package into an isolated root and tests its executable. These checks do not install packages into the runner system or validate Android Termux.

CI also traces the production x86_64 executable with `ZSQT_AUDIT_EXE=zig-out/bin/zsqt`. The aarch64 jobs run the cross-compiled integration suites on native ARM. Compiler setup and build commands are in [building](docs/building.md).

A sample database can be created with Python:

```sh
mkdir -p .zig-cache/tmp
python3 - <<'PY'
import sqlite3

with sqlite3.connect('.zig-cache/tmp/example.sqlite') as db:
    db.execute('CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)')
    db.execute('INSERT OR IGNORE INTO items VALUES (1, ?)', ('example',))
PY
./zig-out/bin/zsqt .zig-cache/tmp/example.sqlite
```

## Android debug self-test

The CI workflow provides a `termux-debug-aarch64` artifact for testing on ARM64 Termux. Artifacts expire after one day. Download the artifact from the workflow run, extract the ZIP file, and verify the included checksum. Extract the resulting archive and run the self-test:

```sh
sha256sum -c SHA256SUMS
tar -xzf zsqt-android-arm64-debug.tar.gz
./zsqt-debug --debug
```

The `--debug` flag authorizes writes only to disposable fixtures under `$HOME/.zsqt`. Results cover read-only enforcement, rollback writes, WAL writes and reopen, hot-journal recovery, and cleanup. The self-test does not open an existing user database or test the TUI confirmation prompts. Copy the complete output for diagnosis.

Regular builds from the current source also include this self-test. The published `v1.0.0` release does not include it.

## Termux diagnostic

The [Termux compatibility workflow](https://github.com/zimlr/zsqt/blob/main/.github/workflows/termux-compat.yml) packages the aarch64 Linux executable with a test-only `termux-packages` recipe. No package is published and no project license is declared by the recipe. An ARM runner executes the upstream PIE check and a Linux seccomp probe against the packaged binary. Detected incompatibilities fail the workflow. Separate testing inside the Termux app remains necessary.

Run the diagnostic locally with an executable matching the Linux host architecture:

```sh
bash tools/fetch_termux_packages.sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
TMPDIR="$PWD/.zig-cache/tmp" \
./tools/zig/zig build tools -Doptimize=ReleaseSmall
zig-out/tools/check-termux-candidate .zig-cache/termux-packages zig-out/bin/zsqt
```

The diagnostic requires `statx` and rejects symlinked or group-writable cache directories during setup. It traps `openat2`, `faccessat2`, and `fchmodat2` with a Linux seccomp filter. Because the upstream PIE script uses unquoted paths, the diagnostic rejects workspace paths containing whitespace or shell glob characters. Android policies and Termux app execution are not reproduced.
