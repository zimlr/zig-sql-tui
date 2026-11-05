# Project overview

This project is a Zig terminal user interface for browsing and editing SQLite databases. Its primary targets are Linux aarch64 under Termux and Linux x86_64 on desktop systems, and the GitHub default branch is `main`.

# Interaction model

- Combine accessible, discoverable terminal controls with composable Vim-like commands.
- Include modal operation, keyboard-first control, composable commands, counts, search, command-line mode, fast navigation, and minimal chrome.
- Show the current location, mode, access state, and relevant next keys on every screen.
- Provide contextual key hints, a help screen, discoverable commands, and predictable focus.
- Make core tasks understandable and reachable without memorizing Vim keys. Vim-style keys accelerate those tasks, and the help screen documents equivalent controls.
- Do not use color as the only indication of mode, selection, errors, or access state.

# Toolchain and build commands

- Pin the Zig compiler to version 0.17.1, and keep the toolchain, build caches, temporary files, and build outputs inside the workspace.
- Implement `-Dstrip` as a boolean build option that defaults to false.
- Create the local cache directories with `mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp`.
- Cross-build the aarch64 Linux executable with `ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true`, and verify native Termux compatibility on a device.
- Build the desktop x86_64 executable with `ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" TMPDIR="$PWD/.zig-cache/tmp" ./tools/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true`.
- Provide the pinned Zig executable at `tools/zig/zig` before building, and do not fetch dependencies during a build.

# Dependency policy

- SQLite MUST be statically linked into every build, with vendored `sqlite3.c` and its matching header compiled in-tree.
- NEVER link SQLite dynamically through a shared library, and prefer static linking for other native dependencies where feasible.
- Justify each dependency in writing before adding it to the build, and pin artifacts to SHA-256 or a full commit where the platform requires one.
- Use a version label when no digest or commit pin is available, and record each dependency's version, provenance, pin, and limitations.
- Remove unused dependencies, and use `ReleaseSmall` with stripped symbols for release builds.
- Builds and application execution MUST work without internet access, and application code MUST NOT make network syscalls.
- NEVER add telemetry, update checks, remote resources, or runtime downloads.

# File access and security

- The application MUST limit reads and writes to the explicitly opened database, its WAL, SHM, and rollback-journal sidecars, and the debug fixtures under `$HOME/.zsqt`.
- Keep the default connection read-only, and require explicit confirmation before recovery modifies a database or its journal.
- NEVER scan or traverse outside the opened database directory without explicit user action, and do not let explicit action expand the file-access allowlist.
- Enforce the allowlist across SQLite operations, including SQL, extensions, temporary storage, and path resolution, and keep temporary storage in memory.
- The application MUST reject database attachment, extension loading, and file-producing SQL unless they can be confined to the allowlist.
- Agents MUST modify files only inside the repository. They MUST NOT read or write system paths or run shell commands that touch anything outside the workspace.
- Follow [SECURITY_REPORTS.md](SECURITY_REPORTS.md) when handling private vulnerability reports or security advisories.

# Read-only and write modes

- Open databases in read-only mode by default, and show `[RO]` or `[RW]` in the title line whenever the interface is drawn.
- Provide `:set readonly` and `:set ro` for read-only mode, and `:set write` and `:set rw` for write mode.
- Require explicit user action and confirmation before entering write mode, and make the changed mode immediately visible.
- In read-only mode, disable cell edits, row insertion and deletion, schema changes, and write SQL. Enforce the restriction at the SQLite connection boundary as well as in the interface.
- Use transactions for writes where practical, confirm destructive operations, and never assign them to an ambiguous key.

# TUI and UX rules

- Support normal, insert, command, search, help, and confirmation modes, and make every feature reachable by keyboard alone with optional pointer support.
- In normal mode, support `hjkl` movement, counts, `gg` and `G`, `/` search with `n` and `N`, and `[` and `]` paging. Also support `<` and `>` column paging, `i` for SQL, `e` for cell edits, `:` command mode, `q` quit, and `?` help.
- Use insert mode for cell and query editing, and return to normal mode on `Esc`.
- At 60 columns or fewer, use a single-pane stacked layout with one panel visible at a time, and provide keys or tabs to switch panels.
- At 100 columns or more, use a multi-pane layout, and drop the least critical pane first between those widths.
- Handle `SIGWINCH`, recompute layout at runtime, and support terminals down to 40 columns by 12 rows.
- Below 40 columns or 12 rows, show a resize prompt without corrupting the display.

# Release policy

- Create a release only after an explicit user request for that specific release, and do not infer approval from a merge, schedule, or prior request.
- Follow [RELEASING.md](RELEASING.md), review compatibility impact, and use the manual Release workflow on the default branch.
- Use SemVer 2.0.0 with a `v` tag prefix, and treat the published releases `v1.0.0` and `v2.0.0` as immutable.
- Do not publish when tracked contents have not changed since the highest-precedence published release, and never replace a published version.

# Code style and engineering standards

- Use explicit ownership, allocator lifetimes, error propagation, and bounds checks, and release resources on every exit path.
- Validate untrusted database content, SQL results, terminal input, and dimensions, and handle malformed data or allocation failures without undefined behavior.
- Keep changes focused, test behavior at its boundaries, and document non-obvious invariants and security decisions.
- Write new tests in Zig, and keep the existing C security harness supported.
- Read and follow [WRITING_STYLE.md](WRITING_STYLE.md) for prose style and enforcement.

# Definition of done

- [ ] Keep this file under 150 lines and retain every required section.
- [ ] Check that interaction rules cover Vim qualities and TUI accessibility.
- [ ] Specify the pinned Zig version and both target build commands.
- [ ] Confirm that static SQLite, offline operation, and file-access rules use MUST or NEVER requirements.
- [ ] Inspect the read-only default, confirmed write mode, command switches, and visible access state.
- [ ] Validate the required Vim keymap, layout breakpoints, resize handling, and minimum terminal size.
- [ ] Run applicable tests and both target builds, and report unavailable checks with their reasons.
- [ ] Audit every line for style violations, and report zero remaining violations before claiming completion.
