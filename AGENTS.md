# Project overview

This project is a Zig TUI for browsing and editing SQLite databases. Primary targets are Linux aarch64 on Termux and Linux x86_64 on desktop. The intended main branch name is `master`, but the current GitHub default branch is `main`.

# Interaction model

- Combine accessible, discoverable TUI controls with composable Vim-like commands.
- Include modal operation, keyboard-first control, composable commands, counts, search, command-line mode, fast navigation, and minimal chrome.
- Show the current location, mode, access state, and relevant next keys on every screen.
- Provide contextual key hints, a help screen, discoverable commands, and predictable focus.
- Make core tasks understandable and reachable without memorizing Vim keys. Vim-style keys provide accelerators, not the sole route to core actions.
- Do not use color as the only indication of mode, selection, errors, or access state.

# Toolchain and build commands

- Pin Zig to version 0.17.1. Keep the toolchain, build caches, temporary files, and build outputs inside the workspace.
- The build implements `-Dstrip` as a boolean option.
- Create the local cache directories with `mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp`.
- Cross-build for aarch64 Linux with `ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true`. Native Termux compatibility requires separate verification.
- Build for desktop x86_64 with `ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true`.
- Provide the pinned Zig executable at `tools/zig/zig` before building. Do not fetch dependencies during a build.

# Dependency policy

- SQLite MUST be statically linked. Vendor `sqlite3.c` and its matching header, and compile the amalgamation in-tree.
- NEVER link SQLite dynamically. Prefer static linking for other native dependencies where feasible.
- Justify each dependency in writing before adding it. Pin artifacts to SHA-256, or to a full commit where the platform requires one.
- Use a version label when no digest or commit pin is available. Record each dependency's version, provenance, pin, and limitations.
- Remove unused dependencies and use `ReleaseSmall` with stripped symbols for release builds.
- Builds and application execution MUST work without internet access. Application code MUST NOT make network syscalls.
- NEVER add telemetry, update checks, remote resources, or runtime downloads.

# File access and security

- The application MUST read and write only the explicitly opened database, its WAL, SHM, and rollback-journal sidecars, and its own config directory.
- Keep the default connection read-only. Require explicit confirmation before recovery modifies a database or its journal.
- NEVER scan or traverse outside the opened database directory without explicit user action. Explicit action does not expand the file-access allowlist.
- Enforce the allowlist across SQLite operations, including SQL, extensions, temporary storage, and path resolution. Keep SQLite temporary storage in memory.
- Reject database attachment, extension loading, and file-producing SQL unless they can be confined to the allowlist.
- Agents MUST modify files only inside the repository and MUST NOT read or write system paths or run shell commands that touch anything outside the workspace.
- Follow [SECURITY_REPORTS.md](SECURITY_REPORTS.md) when handling private vulnerability reports or security advisories.

# Read-only and write modes

- Open databases in read-only mode by default. Show `[RO]` or `[RW]` in the status line at all times.
- Provide `:set readonly` and `:set ro` for read-only mode, and `:set write` and `:set rw` for write mode.
- Require explicit user action and confirmation before entering write mode. Make the changed mode immediately visible.
- In read-only mode, disable cell edits, row insertion and deletion, schema changes, and write SQL. Enforce this at the SQLite connection boundary as well as in the UI.
- Use transactions for writes where practical. Confirm destructive operations and never assign them to an ambiguous key.

# TUI and UX rules

- Support normal, insert, and command modes. Every feature MUST be reachable by keyboard alone. Mouse support is optional.
- In normal mode, support `hjkl` movement, `gg` and `G`, counts such as `5j`, `/` search, `n` and `N`, `:` command mode, `q` quit, and `?` help.
- Use insert mode for cell and query editing. `Esc` returns to normal mode.
- At 60 columns or fewer, use a single-pane stacked layout with one panel visible at a time. Provide keys or tabs to switch panels.
- At 100 columns or more, use a multi-pane layout. Between those widths, drop the least critical pane first and degrade gracefully.
- Handle `SIGWINCH` and recompute layout at runtime. Support terminals down to 40 columns by 12 rows.
- Below 40 columns or 12 rows, show a resize prompt without corrupting the display.

# Release policy

- Create a release only after an explicit user request for that specific release. Do not infer approval from a merge, schedule, or prior request.
- Follow [RELEASING.md](RELEASING.md), review compatibility impact, and use the manual Release workflow on the default branch.
- Use SemVer 2.0.0 with a `v` tag prefix. The first published release MUST be `v1.0.0`.
- Do not publish when tracked contents have not changed since the highest-precedence published release. Never replace a published version.

# Code style and engineering standards

- Use explicit ownership, allocator lifetimes, error propagation, and bounds checks. Release resources on every exit path.
- Validate untrusted database content, SQL results, terminal input, and dimensions. Handle malformed data and allocation failures without undefined behavior.
- Keep changes focused and test behavior at its boundaries. Document non-obvious invariants and security decisions.
- Write new tests in Zig. The existing C security harness remains supported.
- Read and follow [WRITING_STYLE.md](WRITING_STYLE.md) for prose style and enforcement.

# Definition of done

- [ ] Keep this file under 150 lines and retain every required section.
- [ ] Check that interaction rules cover Vim qualities and TUI accessibility.
- [ ] Specify the pinned Zig version and both target build commands.
- [ ] Confirm that static SQLite, offline operation, and file-access rules use MUST or NEVER requirements.
- [ ] Inspect the read-only default, confirmed write mode, command switches, and visible access state.
- [ ] Validate the required Vim keymap, layout breakpoints, resize handling, and minimum terminal size.
- [ ] Run applicable tests and both target builds. Report unavailable checks and their reasons.
- [ ] Audit every line for style violations. Report zero remaining violations before claiming completion.
