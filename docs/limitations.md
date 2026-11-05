# Limitations

## Database access

- A hot rollback journal requires confirmed recovery before read-only access. Recovery requiring a super-journal is not supported because super-journals are outside the file allowlist.
- Database paths must not contain symbolic links. SQLite may create or update the SHM sidecar in read-only WAL mode.
- Attachment, extension loading, and SQL PRAGMAs are disabled.

## Navigation and display

- Search spans pages of the selected table, query results, or table list. It matches full text values and BLOB size labels, not BLOB contents. The query execution budget can interrupt a search before all pages are scanned.
- Table and query pages are re-executed when navigated or searched, so concurrent changes or nondeterministic SQL can change the displayed rows.
- Table names longer than 4096 bytes are skipped. SQLite limits tables and query results to 2000 columns. Column pagination changes the displayed subset, not the SQLite limit.
- Grid cells show a 255-byte preview. The detail panel re-reads longer text values, but a changed or unavailable value may prevent full display.
- Non-ASCII code points are shown as Unicode escapes. Invalid UTF-8 and ASCII control bytes use hexadecimal escapes to prevent terminal escape injection.
- The interface requires a terminal of at least 40 columns by 12 rows.
- Pointer and touch interaction requires a terminal that reports SGR mouse events. Each wheel or drag motion event moves at most one item. Terminals can intercept gestures or emit multiple events for one gesture.

## Input and editing

- Input is append-only and ignores arrow keys. Command completion cycles through matching commands with Tab. SQL entry accepts one statement of up to 4096 UTF-8 bytes.
- Cell editing supports ordinary rowid and WITHOUT ROWID tables. Rowid tables with shadowed aliases require a non-null primary key.
- Cell editing is unavailable for rowid tables with 2000 columns and WITHOUT ROWID tables with more than 900 primary-key columns.
- BLOB editing accepts up to 2048 bytes as hexadecimal. Editing a NULL cell replaces it with text.
- SQL is required to insert control characters or edit NUL-containing text, text exceeding 4096 bytes, larger BLOBs, and column names exceeding 255 bytes.
- SQLite limits schema SQL to 1 MiB. Queries have an execution budget and a 16 MiB value limit.
