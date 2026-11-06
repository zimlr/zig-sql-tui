# Security review

This document records an internal white-hat review of the zsqt security boundary. It is an engineering checklist for maintainers, not a public advisory. Every entry cites code, a reproduction, or a regression test.

## Scope

The review covered four areas.

- The SQL authorizer and statement handling in `src/sandbox.c`.
- The restricted VFS and database open path in `src/live.c`.
- The renderer, input parser, and argument handling in `src/main.zig`.
- The self-test fixture handling in `src/diagnostics.c`.

Review date: 2026-11-06. Runtime probing used debug builds of commit `4bc4b82` and of the tree with the sidecar fix, on x86_64 Linux. The probes drove `--check`, `--recover`, and the TUI through a pseudo-terminal harness.

## Method

- Read each boundary module and list its trust assumptions.
- Attack each assumption with hostile input, hostile paths, and hostile SQL.
- Compare the database hash before and after each probe.
- Record only behavior that a probe or a code reference confirms.
- Repeat each boundary probe with malformed databases, hostile sidecars, unusual schemas, and terminal or signal events.
- Add a regression test for every change.

## Checklist

### Verified controls

- [x] C-01 The authorizer denies every write and escape attempt in read-only mode. Probes covered `ATTACH`, `PRAGMA journal_mode=WAL`, `VACUUM INTO`, `load_extension`, `writefile`, `INSERT`, `SELECT 1; DROP TABLE t`, comment-prefixed writes, and `pragma_table_list`. Each probe failed and the database hash was unchanged.
- [x] C-02 The authorizer denies schema and attach attacks in write mode. `ATTACH`, `PRAGMA writable_schema=ON`, `DELETE FROM sqlite_schema`, `VACUUM INTO`, and multi-statement input were rejected. The database hash stayed constant after each rejection. Ordinary `INSERT`, `CREATE`, `DROP`, and `CREATE TRIGGER` statements commit as designed.
- [x] C-03 The VFS rejects every path outside the single-component allowlist. Symlinked database files, symlinked directories, directories, FIFOs, device nodes, missing paths, and trailing slashes all fail with a non-zero status.
- [x] C-04 Sidecar substitution fails closed. A `-wal` symlink and a `-wal` hard link both produce `Cannot read database: disk I/O error` and leave the target untouched.
- [x] C-05 The renderer escapes terminal control data. Fixtures containing `ESC`, OSC 52, C1 `0x9b`, NUL, newline, and zero-length BLOBs produced escaped output only. A scan of 4325 bytes of frame output found no raw escape or C1 byte.
- [x] C-06 Extreme terminal sizes and wide rows do not crash the process. Terminals of 10x1 and 20x5 exit with status 0, and the 2000-column and 100 KB value fixtures browse without a panic.
- [x] C-07 Resource limits hold. `randomblob(20000000)` fails with `too big`, SQL entry is capped at 4096 bytes, and the process heap limit is 320 MiB.
- [x] C-08 Recovery requires an explicit confirmation. Declining the prompt leaves the database hash unchanged.
- [x] C-09 Self-test fixtures use an owner-only directory, `O_NOFOLLOW`, random names, and `unlinkat` cleanup. The checks in `src/diagnostics.c` reject a home directory that another user owns or that group or other users can write.
- [x] C-10 The input parser survives hostile byte sequences. SGR mouse reports, wheel events, a 5000 byte bracketed paste, malformed control sequences, invalid UTF-8, NUL bytes, and six random key runs of sixty events produced no panic and no diagnostic marker.
- [x] C-11 Malformed database files fail closed. Garbage pages, a truncated file, a forged page size, a corrupted schema record, a random body, an empty file, and a header-only file each exit with status 1. No probe left a sidecar or journal file.
- [x] C-12 Sidecar substitution fails closed for every suffix. A `-wal`, `-shm`, or `-journal` entry that is a symlink, a hard link, a directory, or a FIFO is refused with a non-zero status, and the link target stays unchanged. The SHM case requires a WAL database because other tables do not open that file.
- [x] C-13 Recovery matches the documented contract. A hot journal is refused in read-only mode with an `--recover` hint and the database hash is unchanged. Accepting recovery rolls the database back and removes the journal. Declining and running recovery on a healthy database leave every byte in place. A read-only database file and an exclusively locked database both fail with a message and a non-zero status.
- [x] C-14 Write confirmation cannot be bypassed. Esc cancels a pending cell write, a repeated `y` applies one change, a failed write on a read-only file leaves no journal or WAL behind, and an external change between the prompt and the confirmation refuses the write.
- [x] C-15 Statement classification follows SQLite. `ATTACH`, `SAVEPOINT`, `BEGIN`, `VACUUM`, `pragma_journal_mode`, `pragma_table_list`, `sqlite_dbpage`, `readfile`, `writefile`, and `CREATE VIRTUAL TABLE` are refused in read-only and write mode. A query with an unbounded recursive term is interrupted by the progress handler. `REINDEX` asks for confirmation when an index can change and reports query results only when the statement cannot write.
- [x] C-16 The self-test rejects unsafe homes. `--debug` fails with a world-writable `$HOME`, a missing `$HOME`, an unset `$HOME`, and a `.zsqt` entry that is a symlink. A symlink placed inside `.zsqt` is not followed, and a successful run leaves the directory empty.
- [x] C-17 Cell identity is exact for unusual keys. A shadowed `rowid` column falls back to `_rowid_`, an `INTEGER PRIMARY KEY` beside a `rowid` column updates the selected row, a BLOB primary key updates the selected row, and a nullable primary key falls back to the rowid key so a NULL key cannot update several rows.
- [x] C-18 The renderer accepts the whole terminal range. Sizes of 1x1, 5x20, 12x40, 100x240, and 200x400 exit with status 0 and no panic.

### Fixed findings

- [x] F-01 Sidecar files are now created with owner-only permissions. Before the change, `umask 000; zsqt --check db.sqlite` on a WAL database created `db.sqlite-wal` and `db.sqlite-shm` with mode `0644`. SQLite re-applies its requested mode to a new empty file through `fchmod`, so the mode passed at creation was not enough. A journal, WAL, or SHM file readable by other local users exposes database pages or index state. The fix forces mode `0600` at creation and strips group and other bits in a `fchmod` hook in `src/live.c`. Reproduction after the fix shows `-rw-------` for both sidecars. Regression test: `tests/test_wal_write.zig`, test `read-only sidecars are created owner-only`.

### Accepted risks

- [x] A-01 Read-only access to a WAL database creates an empty WAL and the SHM sidecar. SQLite needs the sidecar for a read-only WAL open, and the files are now owner-only. The behavior is documented in `docs/limitations.md`.
- [x] A-02 The main database file may be a hard link while sidecar files must have a single link. Backups rely on hard links, and a hard link grants no access that the containing directory does not already allow. The rule is documented in `docs/limitations.md`.
- [x] A-03 A writable database in a directory controlled by another user leaves a rename window between the header check and the SQLite open. The header check is advisory because SQLite validates the file it opens. A swap can only replace the database with another SQLite database in the same directory, so the impact stays inside the user's stated choice of path. Sidecar files written in that directory can also change the readable view of a WAL database or enter it during a write open. The trust assumption is documented in `docs/limitations.md`.

## Not covered

- Memory-safety fuzzing of the vendored SQLite library.
- Memory-safety fuzzing of the Zig renderer and input parser beyond the matrices above.
- Kernel and filesystem behavior on every Termux device.
- Multi-user systems where another user already controls the database directory.
- Denial of service through terminal or pseudo-terminal ownership.

## Reproduction notes

The sidecar permission check uses a WAL database with the sidecars removed.

```sh
python3 -c "import sqlite3; c=sqlite3.connect('db.sqlite'); c.execute('PRAGMA journal_mode=WAL'); c.execute('CREATE TABLE t(a)'); c.commit(); c.close()"
rm -f db.sqlite-wal db.sqlite-shm
umask 000; ./zig-out/bin/zsqt --check db.sqlite
ls -l db.sqlite-wal db.sqlite-shm
```

Before the fix the listing shows `-rw-r--r--`. After the fix it shows `-rw-------`.
