# Limitations

## Database access

- A hot rollback journal requires confirmed recovery before read-only access. Recovery requiring a super-journal is not supported because super-journals are outside the file allowlist.
- Database paths must not contain symbolic links. Read-only WAL access may create an empty WAL and the SHM sidecar, which requires a writable database directory. New sidecar files are created with owner-only permissions. The main database may be a hard link, but sidecar files must have a single link.
- Attachment, extension loading, and SQL PRAGMAs are disabled.
- The table list includes entries of type `table` and omits views and internal `sqlite_` objects. SQLite heap use is limited to 320 MiB for the whole process.

## Navigation and display

- Search spans pages of the selected table, query results, or table list. It matches full text values and BLOB size labels, not BLOB contents. Each search scan and SQL result page reload has a budget of approximately 20 million SQLite instructions. Row searches can run two scans. Complex or larger results can still exhaust a scan budget.
- Table and query pages are re-executed when navigated or searched, so concurrent changes or nondeterministic SQL can change the displayed rows.
- Pages show up to 128 tables, 500 rows, and 32 columns. Table names of 256 bytes or more, or containing NUL bytes, are skipped. SQLite limits tables and query results to 2000 columns. Column pagination changes the displayed subset, not the SQLite limit.
- Grid cells show a 255-byte preview. The detail panel re-reads longer text values, but a changed or unavailable value may prevent full display.
- Non-ASCII code points are shown as Unicode escapes. Invalid UTF-8 and ASCII control bytes use hexadecimal escapes to prevent terminal escape injection.
- The interface requires a terminal of at least 40 columns by 12 rows.
- Pointer and touch interaction requires a terminal that reports SGR mouse events. Each wheel or drag motion event moves at most one item. Terminals can intercept gestures or emit multiple events for one gesture.

## Input and editing

- Input ignores arrow keys and supports deletion of the last character with Backspace or Ctrl-H. Ctrl-U clears the input, Enter submits, and Esc cancels. Command completion cycles through matching commands with Tab. SQL entry accepts one statement of up to 4096 UTF-8 bytes.
- Ordinary rowid and WITHOUT ROWID tables support cell editing. Rowid tables with shadowed aliases require a non-null primary key.
- Cell editing is unavailable for a 2000-column rowid table or a WITHOUT ROWID table with more than 900 primary-key columns.
- BLOB editing accepts up to 2048 bytes as hexadecimal. Editing a NULL cell replaces it with text.
- SQL is required to insert control characters or edit NUL-containing text, text exceeding 4096 bytes, larger BLOBs, and column names exceeding 255 bytes.
- SQLite limits statements, including schema SQL, to 1 MiB. Initial queries and writes have an execution budget of approximately two million SQLite instructions. SQLite values are limited to 16 MiB.
