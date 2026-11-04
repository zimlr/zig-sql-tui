# Test checklist

Validation uses disposable databases under `.zig-cache/tmp`. Results cover the execution paths listed below.

## Findings

- [x] Escape SQLite error text before terminal output. A malformed schema could inject terminal controls through startup errors. `tests/test_live_audit.py` covers the reported path.
- [x] Synchronize the database directory when SQLite requests it after journal deletion. `tests/security.c` verifies the call and an injected synchronization failure.
- [x] Block confirmation while the terminal is below the minimum size. Terminal tests cover pending writes and recovery.
- [x] Consume complete and fragmented terminal escape sequences without interpreting trailing bytes as commands. Preserve a key following Esc. Terminal tests cover input and confirmation modes.
- [x] Clear stale error state before a new operation. Retain errors from failed table page loads and searches. A terminal test covers paging after a query error.
- [ ] Resolve the non-PIE executable reported by the upstream Termux check. The current aarch64 Linux build has ELF type `EXEC`.
- [ ] Preserve the filesystem allowlist when `openat2` is blocked. A Linux seccomp probe terminates the current binary with `SIGSYS`.

## Coverage

- [x] Review project-owned Markdown and run the mechanical prose check. Third-party SQLite license text remains unchanged.
- [x] Exercise the x86_64 release binary in terminal sessions with rollback and WAL databases.
- [x] Cover navigation, search, help, resizing, queries, access changes, edits, paging, and recovery.
- [x] Check SQL authorization, symlinks and hardlinks, terminal controls, query limits, and SQLite lock handling.
- [x] Trace selected filesystem and network syscalls during read checks and confirmed writes in rollback and WAL modes on Linux x86_64. These traces cover tested execution paths.
- [x] Build x86_64 and aarch64 binaries and verify static linkage.
- [x] Run the aarch64 binary on native aarch64 Linux. The ARM runner job passed in [CI run 41912809999](https://github.com/zimlr/zig-sql-tui/actions/runs/41912809999). Syscall tracing remains limited to x86_64.
- [ ] Run the packaged binary in the Termux app on Android. Linux ARM CI does not reproduce Android app seccomp or execution policies.
- [ ] Test durability under an actual power loss. The directory synchronization test injects a syscall failure instead.

The prose checker covers project-owned Markdown and skips code spans and fenced code. It checks selected punctuation and phrases. Tone, pacing, and other non-mechanical rules require manual review. The syscall tests require Linux x86_64 and permission to use `ptrace`. They skip when those conditions are unavailable.

## Termux diagnostic

The [Termux compatibility workflow](.github/workflows/termux-compat.yml) packages the aarch64 Linux executable with a test-only `termux-packages` recipe. No package is published and no project license is declared by the recipe. An ARM runner executes the upstream PIE check and a Linux seccomp probe against the packaged binary. Detected incompatibilities fail the workflow. Execution inside the Termux app remains necessary.

Run the diagnostic locally with an executable matching the Linux host architecture:

```sh
bash tools/fetch_termux_packages.sh
python3 tools/check_termux_candidate.py .zig-cache/termux-packages zig-out/bin/zig-sql-tui
```

The diagnostic uses a single-syscall seccomp filter. Android policies and Termux app execution are not reproduced.
