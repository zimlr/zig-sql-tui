# Test checklist

Validation uses disposable databases under `.zig-cache/tmp`, and the results cover the execution paths listed below.

## Findings

- [x] Build and install an amd64 Debian package into an isolated dpkg root. The installed executable runs terminal and read-only tests without accessing the host package database.
- [x] Reject package architecture mismatches, invalid tags, symbolic links, existing output files, and altered release draft assets. The test uses disposable files and no published release.
- [x] Check Debian version ordering against SemVer prereleases, including alphanumeric identifiers and build metadata.
- [x] Install the `arm64` package into an isolated root on a native ARM runner and run the installed executable through live, search, and WAL tests. [CI run 42068224415](https://github.com/zimlr/zsqt/actions/runs/42068224415) passed for commit `beccf78`.
- [x] Replace repeated page scans during search with offset-based scans that resume at the current row. Terminal fixtures cover a distant match in a 40,000-row, 40-column table and a 373,781-row, 12-column table. Each scan keeps a finite instruction budget.
- [x] Release-history validation rejects nonregular input without blocking. `tests/test_release_policy.zig` covers a named pipe.
- [x] Markdown scanning rejects symbolic links and nonregular files. `tests/test_prose.zig` covers symlinks and named pipes without following or blocking on them.
- [x] Termux probe setup rejects symbolic links and group-writable or world-writable cache directories. The check assumes the workspace is not modified concurrently by the same user.
- [x] Workspace paths that can be split or expanded by the upstream Termux PIE script are rejected. The Zig probe fails before running the script when its temporary path contains whitespace or glob characters.
- [x] Escape SQLite error text before terminal output. A malformed schema could inject terminal controls through startup errors. `tests/test_live_audit.zig` covers the reported path.
- [x] Synchronize the database directory when SQLite requests it after journal deletion. `tests/security.c` verifies the call and an injected synchronization failure.
- [x] Block recovery confirmation while the terminal is below the minimum size. Below that size, pending cell and SQL write confirmations accept only `n`, `N`, or Esc, and the prompt returns after the terminal grows. No test drives those prompts at that size.
- [x] Consume complete terminal escape sequences without interpreting trailing bytes as commands. A terminal test covers a key following Esc, and another covers a mouse sequence with an oversized numeric field. The input loop retains incomplete sequences across reads, which no dedicated test exercises.
- [x] Clear stale error state before a new operation. Retain errors from failed table page loads and searches. A terminal test covers paging after a query error.
- [x] Build position-independent executables without an ELF interpreter or shared-library dependencies. The upstream Termux PIE check accepts the aarch64 candidate in the compatibility workflow, and `readelf` checks cover both release binaries.
- [x] Replace `openat2` with an fd-anchored, no-symlink directory walk and single-component sidecar opens. Linux tests exercise the allowlist with restricted syscalls trapped. The native ARM probe passed in [CI run 41926400320](https://github.com/zimlr/zsqt/actions/runs/41926400320).
- [x] Verify basic startup in the Termux app on Android 13. A user reported that `v1.0.0` terminates with `Bad system call`, while the later ARM64 test build opens a database and displays the TUI.

## Coverage

- [x] Run the mechanical prose check on project-owned Markdown. It covers rules that an earlier manual review missed, and third-party SQLite license text remains unchanged.
- [x] Exercise an x86_64 Linux binary in terminal sessions with rollback and WAL databases.
- [x] Open a cleanly closed WAL database with no sidecars read-only. `tests/test_wal_write.zig` checks `--check` and the table view after the reader creates an empty WAL and the SHM sidecar, and fails without that handling.
- [x] Cover navigation, search, help, resizing, queries, access changes, edits, paging, and recovery.
- [x] Check SQL authorization, symlinks and hardlinks, terminal controls, query limits, and SQLite lock handling.
- [x] Accept the option terminator before and after `--check` or `--recover`. `tests/test_app.zig` covers a path after the terminator, a missing path, an extra argument, and the help text.
- [x] Run diagnostic fixtures for read-only enforcement, rollback writes, WAL writes, and hot-journal recovery on Linux. Check explicit debug authorization, cleanup, symlink rejection, and restricted syscalls.
- [x] Trace selected filesystem and network syscalls during read checks, cross-page searches, and confirmed writes in rollback and WAL modes on Linux x86_64. These traces cover tested execution paths.
- [x] Verify transferred artifact checksums with `sha256sum -c` and reject an altered asset whose digest does not match the local file. These checksums detect mismatches but do not authenticate an artifact and manifest obtained together.
- [x] Run the integration, diagnostic, restricted-syscall, release-policy, completion, and prose suites against the current x86_64 build. The checks cover their tested inputs and paths without establishing complete coverage.
- [x] Probe 16 header mutations and 48 scattered byte mutations with the x86_64 `--check` binary. Header mutations were rejected, and the 48 mutations remained readable, so database integrity stays unverified. No tested file changed or produced a sidecar. `tests/test_app.zig` repeats these checks with a separate fixture.
- [x] Build x86_64 and aarch64 binaries and verify static linkage.
- [x] Test SemVer parsing, precedence, release history, and changed-content checks against isolated Git repositories.
- [x] Run the release workflow on GitHub after an explicit user request. Releases `v1.0.0` and `v2.0.0` are published, and [CI run 42023815702](https://github.com/zimlr/zsqt/actions/runs/42023815702) published `v2.0.0`. Draft-first publication has not yet run for a published release.
- [x] Run the aarch64 binary and the Zig integration suites on native aarch64 Linux. [CI run 42068224415](https://github.com/zimlr/zsqt/actions/runs/42068224415) passed for commit `beccf78`. Syscall tracing remains limited to x86_64.
- [x] Package the aarch64 Linux executable with the pinned Termux build system and run restricted-syscall tests on native ARM. [Termux compatibility run 42068224377](https://github.com/zimlr/zsqt/actions/runs/42068224377) passed for commit `beccf78`.
- [x] Open a database and use touch, scrolling, Home, End, Page Up, and Page Down in Termux on Android 13. The result is a user report for a later ARM64 test build.
- [x] Run the isolated diagnostics build in Termux on Android 13. A user reported passing read-only enforcement, rollback writes, WAL writes and reopen, hot-journal recovery, and cleanup.
- [ ] Test TUI confirmation prompts for writes and recovery in the Termux app. The diagnostics flag exercises database operations without the interactive TUI.
- [ ] Test durability under an actual power loss. The directory synchronization test injects a syscall failure instead.

The prose checker covers selected mechanical rules in project-owned Markdown and skips code spans and fenced code. Markdown file symlinks, nonregular Markdown files, and input files exceeding 64 MiB are rejected, and directory symlinks are not traversed. File checks require Linux `statx` and assume the workspace is not modified concurrently. Tone, pacing, and other non-mechanical rules require manual review.

The syscall tests require Linux x86_64 and permission to use `ptrace`, and they skip when those conditions are unavailable.

## Running tests

The Zig test step runs the Zig suites and the existing C security harness. Linux x86_64 tests also require `dpkg`, `dpkg-deb`, `readelf`, `xz`, `jq`, `cmp`, and `sha256sum` for Debian package validation. It builds a separate test executable without replacing `zig-out/bin/zsqt`, and on Linux x86_64 it also builds a static executable for the syscall audit. The prose and release-policy suites invoke the production Zig tools, and the release-policy tests require Git.

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

Fixtures use `.zig-cache/tmp`, and the diagnostics suite runs against the regular test executable. Current CI configuration also tests the static production executable and its aarch64 counterpart.

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

The CI workflow provides a `termux-debug-aarch64` artifact for testing on ARM64 Termux, and artifacts expire after one day. Download the artifact from the workflow run, extract the ZIP file, and verify the included checksum. Extract the resulting archive and run the self-test:

```sh
sha256sum -c SHA256SUMS
tar -xzf zsqt-android-arm64-debug.tar.gz
./zsqt-debug --debug
```

The `--debug` flag authorizes writes only to disposable fixtures under `$HOME/.zsqt`. It requires a home directory owned by the current user without group or world write permission. Results cover read-only enforcement, rollback writes, WAL writes and reopen, hot-journal recovery, and cleanup. The self-test does not open an existing user database or test the TUI confirmation prompts, and the complete output supports diagnosis.

Regular builds from the current source also include this self-test. The published `v1.0.0` release does not include it.

## Termux diagnostic

The [Termux compatibility workflow](https://github.com/zimlr/zsqt/blob/main/.github/workflows/termux-compat.yml) packages the aarch64 Linux executable with a test-only `termux-packages` recipe. No package is published and no project license is declared by the recipe. An ARM runner executes the upstream PIE check and a Linux seccomp probe against the packaged binary, and any detected incompatibility fails the workflow. Separate testing inside the Termux app remains necessary.

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
