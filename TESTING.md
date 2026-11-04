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
- [x] Trace selected filesystem and network syscalls during read checks and confirmed writes in rollback and WAL modes on Linux x86_64. These traces cover tested execution paths.
- [x] Build x86_64 and aarch64 binaries and verify static linkage.
- [x] Test SemVer parsing, precedence, release history, and changed-content checks. Mock the release publication commands and verify archive checksums.
- [x] Run the release workflow on GitHub after an explicit user request. The initial release completed in [CI run 41923948348](https://github.com/zimlr/zig-sql-tui/actions/runs/41923948348).
- [x] Run the aarch64 binary on native aarch64 Linux. The ARM runner job passed in [CI run 41926400379](https://github.com/zimlr/zig-sql-tui/actions/runs/41926400379). Syscall tracing remains limited to x86_64.
- [x] Package the aarch64 Linux executable with the pinned Termux build system. The packaging job passed in [CI run 41917316005](https://github.com/zimlr/zig-sql-tui/actions/runs/41917316005).
- [x] Open a database and display the TUI with the packaged ARM64 test binary in Termux on Android 13. The result is a user report.
- [ ] Test writes, WAL, and recovery in the Termux app on Android. Linux ARM CI does not reproduce Android app seccomp or execution policies.
- [ ] Test durability under an actual power loss. The directory synchronization test injects a syscall failure instead.

The prose checker covers project-owned Markdown and skips code spans and fenced code. It checks selected punctuation and phrases. Tone, pacing, and other non-mechanical rules require manual review. The syscall tests require Linux x86_64 and permission to use `ptrace`. They skip when those conditions are unavailable.

## Termux diagnostic

The [Termux compatibility workflow](.github/workflows/termux-compat.yml) packages the aarch64 Linux executable with a test-only `termux-packages` recipe. No package is published and no project license is declared by the recipe. An ARM runner executes the upstream PIE check and a Linux seccomp probe against the packaged binary. Detected incompatibilities fail the workflow. Separate testing inside the Termux app remains necessary.

Run the diagnostic locally with an executable matching the Linux host architecture:

```sh
bash tools/fetch_termux_packages.sh
python3 tools/check_termux_candidate.py .zig-cache/termux-packages zig-out/bin/zig-sql-tui
```

The diagnostic traps `openat2`, `faccessat2`, and `fchmodat2` with a Linux seccomp filter. Android policies and Termux app execution are not reproduced.
