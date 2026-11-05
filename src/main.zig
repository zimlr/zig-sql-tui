const std = @import("std");
const build_options = @import("build_options");
extern fn app_diagnostics() c_int;

const Db = opaque {};
const Stmt = opaque {};
extern fn app_open_live([*:0]const u8, c_int, *?*Db, [*]u8, usize) c_int;
extern fn app_reopen_live(*Db, c_int, *?*Db, [*]u8, usize) c_int;
extern fn app_live_close() void;
extern fn app_recover([*:0]const u8, [*]u8, usize) c_int;
extern fn app_execute_write(*Db, [*:0]const u8, [*]u8, usize) c_int;
extern fn app_prepare_tables(*Db, i64, *?*Stmt) c_int;
extern fn app_prepare_rows(*Db, [*:0]const u8, i64, *?*Stmt) c_int;
extern fn app_prepare_editable_rows(*Db, [*:0]const u8, i64, *?*Stmt, *c_int) c_int;
extern fn app_data_version(*Db, c_int, *c_int) c_int;
extern fn app_update_cell(*Db, [*:0]const u8, [*:0]const u8, i64, c_int, i64, c_int, [*:0]const u8, c_int, c_int, [*]u8, usize) c_int;
extern fn app_prepare_statement(*Db, [*:0]const u8, *?*Stmt, c_int, *c_int) c_int;
extern fn app_query_begin(*Db) void;
extern fn app_query_end(*Db) void;
extern fn sqlite3_close(*Db) c_int;
extern fn sqlite3_step(*Stmt) c_int;
extern fn sqlite3_finalize(*Stmt) c_int;
extern fn sqlite3_column_count(*Stmt) c_int;
extern fn sqlite3_column_int64(*Stmt, c_int) i64;
extern fn sqlite3_column_name(*Stmt, c_int) ?[*:0]const u8;
extern fn sqlite3_column_text(*Stmt, c_int) ?[*]const u8;
extern fn sqlite3_column_blob(*Stmt, c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(*Stmt, c_int) c_int;
extern fn sqlite3_column_type(*Stmt, c_int) c_int;
extern fn sqlite3_errmsg(*Db) [*:0]const u8;
extern fn app_terminal_enter() c_int;
extern fn app_terminal_leave() void;
extern fn app_terminal_read() c_int;
extern fn app_terminal_size(*u16, *u16) void;
extern "c" fn write(c_int, [*]const u8, usize) isize;

const sqlite_ok = 0;
const sqlite_row = 100;
const sqlite_done = 101;
const max_tables = 128;
const max_rows = 500;
const max_columns = 32;
const Text = TextBuffer(256);
const InputText = TextBuffer(4097);
const NameText = TextBuffer(4097);
fn TextBuffer(comptime capacity: usize) type {
    return struct {
        data: [capacity]u8 = @splat(0),
        len: usize = 0,
        truncated: bool = false,

        fn set(self: *@This(), value: []const u8) void {
            self.len = @min(value.len, self.data.len - 1);
            self.truncated = value.len > self.len;
            @memcpy(self.data[0..self.len], value[0..self.len]);
            self.data[self.len] = 0;
        }
        fn slice(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
        fn cstr(self: *const @This()) [*:0]const u8 {
            return @ptrCast(self.data[0..].ptr);
        }
        fn append(self: *@This(), value: []const u8) void {
            const n = @min(value.len, self.data.len - 1 - self.len);
            @memcpy(self.data[self.len..][0..n], value[0..n]);
            if (n < value.len) self.truncated = true;
            self.len += n;
            self.data[self.len] = 0;
        }
    };
}

const Focus = enum { tables, rows, details };
const Mode = enum { normal, command, search, insert, cell };
const Pending = enum { none, switch_write, sql_write, cell_write };
const App = struct {
    db: *Db,
    writable: bool = false,
    pending: Pending = .none,
    path: Text = .{},
    tables: [max_tables]NameText = @splat(.{}),
    table_count: usize = 0,
    table_index: usize = 0,
    table_offset: usize = 0,
    tables_next: bool = false,
    row_offset: usize = 0,
    rows_next: bool = false,
    column_offset: usize = 0,
    total_columns: usize = 0,
    cells: [max_rows][max_columns]Text = @splat(@splat(.{})),
    editable_cells: [max_rows][max_columns]bool = @splat(@splat(false)),
    cell_types: [max_rows][max_columns]u8 = @splat(@splat(0)),
    rowids: [max_rows]i64 = @splat(0),
    row_editable: bool = false,
    row_key_kind: c_int = 0,
    row_version: c_int = 0,
    columns: [max_columns]Text = @splat(.{}),
    column_count: usize = 0,
    column_index: usize = 0,
    detail_offset: usize = 0,
    detail_width: usize = 1,
    detail: ?[]u8 = null,
    detail_attempted: bool = false,
    generation: usize = 0,
    detail_generation: usize = 0,
    detail_row: usize = 0,
    detail_column: usize = 0,
    row_count: usize = 0,
    row_index: usize = 0,
    message: Text = .{},
    input: InputText = .{},
    search: InputText = .{},
    query: InputText = .{},
    active_query: InputText = .{},
    cell_value: InputText = .{},
    cell_update_type: c_int = 0,
    query_results: bool = false,
    focus: Focus = .tables,
    mode: Mode = .normal,
    help: bool = false,
    pending_g: bool = false,
    pending_count: usize = 0,
    count: usize = 0,
    running: bool = true,
    failed: bool = false,
    cols: usize = 80,
    height: usize = 24,

    fn setError(self: *App) void {
        self.failed = true;
        self.message.set(std.mem.span(sqlite3_errmsg(self.db)));
    }

    fn loadTables(self: *App) void {
        self.failed = false;
        app_query_begin(self.db);
        defer app_query_end(self.db);
        var stmt: ?*Stmt = null;
        self.table_count = 0;
        self.table_index = 0;
        self.tables_next = false;
        if (app_prepare_tables(self.db, @intCast(self.table_offset), &stmt) != sqlite_ok or stmt == null) {
            self.setError();
            return;
        }
        defer _ = sqlite3_finalize(stmt.?);
        var examined: usize = 0;
        while (true) {
            const rc = sqlite3_step(stmt.?);
            if (rc == sqlite_done) break;
            if (rc != sqlite_row) {
                self.setError();
                break;
            }
            if (examined == max_tables) {
                self.tables_next = true;
                break;
            }
            examined += 1;
            const ptr = sqlite3_column_text(stmt.?, 0) orelse {
                self.setError();
                break;
            };
            const n: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 0)));
            if (n >= self.tables[0].data.len or std.mem.indexOfScalar(u8, ptr[0..n], 0) != null) {
                self.message.set("A table name was skipped because it is too long or contains NUL");
                continue;
            }
            self.tables[self.table_count].set(ptr[0..n]);
            self.table_count += 1;
        }
        if (!self.failed and self.table_count > 0) self.loadRows();
    }

    fn loadRows(self: *App) void {
        self.failed = false;
        self.query_results = false;
        self.row_count = 0;
        self.row_index = 0;
        self.row_editable = false;
        if (self.table_count == 0) return;
        var stmt: ?*Stmt = null;
        var has_rowid: c_int = 0;
        var before: c_int = 0;
        const version_ok = self.writable and app_data_version(self.db, 1, &before) == sqlite_ok;
        app_query_begin(self.db);
        defer app_query_end(self.db);
        const rc = if (self.writable) app_prepare_editable_rows(self.db, self.tables[self.table_index].cstr(), @intCast(self.row_offset), &stmt, &has_rowid) else app_prepare_rows(self.db, self.tables[self.table_index].cstr(), @intCast(self.row_offset), &stmt);
        if (rc != sqlite_ok or stmt == null) {
            self.setError();
            return;
        }
        self.row_key_kind = has_rowid;
        self.row_editable = has_rowid != 0 and version_ok;
        self.readRows(stmt.?, has_rowid == 1);
        _ = sqlite3_finalize(stmt.?);
        if (self.row_editable) {
            var after: c_int = 0;
            if (app_data_version(self.db, 1, &after) != sqlite_ok or before != after) {
                self.row_editable = false;
                self.message.set("Database changed while loading. Reload to edit");
            } else self.row_version = after;
        }
    }

    fn runQuery(self: *App) void {
        self.failed = false;
        self.query.set(self.input.slice());
        var stmt: ?*Stmt = null;
        app_query_begin(self.db);
        defer app_query_end(self.db);
        var is_write: c_int = 0;
        const rc = app_prepare_statement(self.db, self.input.cstr(), &stmt, if (self.writable) 1 else 0, &is_write);
        if (rc != sqlite_ok or stmt == null) {
            if (rc == 23 or rc == 21) {
                self.message.set(if (self.writable) "Enter one permitted SQL statement" else "Enter exactly one read-only SQL statement");
            } else self.setError();
            return;
        }
        defer _ = sqlite3_finalize(stmt.?);
        if (is_write != 0) {
            self.pending = .sql_write;
            self.message.set("Execute this database write? y/n");
            return;
        }
        self.active_query.set(self.query.slice());
        self.query_results = true;
        self.row_offset = 0;
        self.column_offset = 0;
        self.row_editable = false;
        self.focus = .rows;
        self.message.set(if (self.writable) "Query results" else "Read-only query results");
        self.readRows(stmt.?, false);
    }

    fn readRows(self: *App, stmt: *Stmt, has_rowid: bool) void {
        self.generation +%= 1;
        self.row_count = 0;
        self.row_index = 0;
        self.column_index = 0;
        self.detail_offset = 0;
        const offset: usize = if (has_rowid) 1 else 0;
        const ncols: usize = @intCast(@max(0, sqlite3_column_count(stmt) - @as(c_int, @intCast(offset))));
        self.total_columns = ncols;
        if (self.column_offset >= ncols) self.column_offset = 0;
        self.column_count = @min(ncols - self.column_offset, max_columns);
        self.rows_next = false;
        for (0..self.column_count) |i| {
            self.columns[i].set("");
            if (sqlite3_column_name(stmt, @intCast(i + offset + self.column_offset))) |name| self.columns[i].set(std.mem.span(name));
        }
        while (self.row_count < max_rows) {
            const rc = sqlite3_step(stmt);
            if (rc == sqlite_done) break;
            if (rc != sqlite_row) {
                self.setError();
                break;
            }
            if (has_rowid) {
                if (sqlite3_column_type(stmt, 0) != 1) self.row_editable = false else self.rowids[self.row_count] = sqlite3_column_int64(stmt, 0);
            }
            for (0..self.column_count) |i| {
                const col: c_int = @intCast(i + offset + self.column_offset);
                const cell = &self.cells[self.row_count][i];
                const cell_type = sqlite3_column_type(stmt, col);
                self.cell_types[self.row_count][i] = @intCast(cell_type);
                if (cell_type == 5) {
                    cell.set("NULL");
                } else if (cell_type == 4) {
                    var buf: [40]u8 = undefined;
                    const size: usize = @intCast(@max(0, sqlite3_column_bytes(stmt, col)));
                    cell.set(std.fmt.bufPrint(&buf, "[BLOB {d} bytes]", .{size}) catch "[BLOB]");
                } else if (sqlite3_column_text(stmt, col)) |ptr| {
                    const len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt, col)));
                    cell.set(ptr[0..len]);
                } else {
                    self.setError();
                    return;
                }
                var editable = cell_type >= 1 and cell_type <= 3 and !cell.truncated and !self.columns[i].truncated and std.unicode.utf8ValidateSlice(cell.slice());
                for (cell.slice()) |ch| if (ch == 0) {
                    editable = false;
                    break;
                };
                self.editable_cells[self.row_count][i] = editable;
            }
            self.row_count += 1;
        }
        if (self.row_count == max_rows) {
            const rc = sqlite3_step(stmt);
            if (rc == sqlite_row) self.rows_next = true else if (rc != sqlite_done) self.setError();
        }
    }

    fn clearDetail(self: *App) void {
        if (self.detail) |detail| std.heap.page_allocator.free(detail);
        self.detail = null;
        self.detail_attempted = false;
    }

    // Re-read only the selected truncated value, keeping the grid bounded.
    fn refreshDetail(self: *App) void {
        if (self.row_count == 0 or self.column_count == 0) {
            self.clearDetail();
            return;
        }
        const cell = &self.cells[self.row_index][self.column_index];
        if (self.detail_attempted and self.detail_generation == self.generation and
            self.detail_row == self.row_index and self.detail_column == self.column_index) return;
        self.clearDetail();
        self.detail_attempted = true;
        self.detail_generation = self.generation;
        self.detail_row = self.row_index;
        self.detail_column = self.column_index;
        if (!cell.truncated or self.cell_types[self.row_index][self.column_index] != 3) return;
        var before: c_int = 0;
        if (self.row_editable and (app_data_version(self.db, 1, &before) != sqlite_ok or before != self.row_version)) {
            self.row_editable = false;
            self.message.set("Database changed. Reload before editing");
            return;
        }
        var stmt: ?*Stmt = null;
        var is_write: c_int = 0;
        var key_kind: c_int = 0;
        app_query_begin(self.db);
        defer app_query_end(self.db);
        const rc = if (self.query_results)
            app_prepare_statement(self.db, self.active_query.cstr(), &stmt, 0, &is_write)
        else if (self.row_key_kind == 2)
            app_prepare_editable_rows(self.db, self.tables[self.table_index].cstr(), @intCast(self.row_offset), &stmt, &key_kind)
        else
            app_prepare_rows(self.db, self.tables[self.table_index].cstr(), @intCast(self.row_offset), &stmt);
        if (rc != sqlite_ok or stmt == null) return;
        defer _ = sqlite3_finalize(stmt.?);
        if (self.row_key_kind == 2 and !self.query_results and key_kind != 2) return;
        const skip = self.row_index + if (self.query_results) self.row_offset else @as(usize, 0);
        for (0..skip + 1) |_| if (sqlite3_step(stmt.?) != sqlite_row) return;
        const col: c_int = @intCast(self.column_offset + self.column_index);
        if (sqlite3_column_type(stmt.?, col) != 3) return;
        const ptr = sqlite3_column_text(stmt.?, col) orelse return;
        const len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, col)));
        if (len < cell.len or !std.mem.eql(u8, ptr[0..cell.len], cell.slice())) return;
        const copy = std.heap.page_allocator.alloc(u8, len) catch {
            self.message.set("Cannot allocate full cell value");
            return;
        };
        @memcpy(copy, ptr[0..len]);
        if (self.row_editable) {
            var after: c_int = 0;
            if (app_data_version(self.db, 1, &after) != sqlite_ok or after != self.row_version) {
                std.heap.page_allocator.free(copy);
                self.row_editable = false;
                self.message.set("Database changed. Reload before editing");
                return;
            }
        }
        self.detail = copy;
        self.detail_generation = self.generation;
        self.detail_row = self.row_index;
        self.detail_column = self.column_index;
    }

    // Query pages are re-executed. No write statement is permitted here.
    fn loadQueryPage(self: *App) void {
        self.failed = false;
        var stmt: ?*Stmt = null;
        var is_write: c_int = 0;
        app_query_begin(self.db);
        defer app_query_end(self.db);
        if (app_prepare_statement(self.db, self.active_query.cstr(), &stmt, 0, &is_write) != sqlite_ok or stmt == null) {
            self.setError();
            return;
        }
        defer _ = sqlite3_finalize(stmt.?);
        for (0..self.row_offset) |_| {
            const rc = sqlite3_step(stmt.?);
            if (rc == sqlite_done) {
                self.row_count = 0;
                self.rows_next = false;
                return;
            }
            if (rc != sqlite_row) {
                self.setError();
                return;
            }
        }
        self.readRows(stmt.?, false);
    }

    fn page(self: *App, forward: bool) void {
        if (self.focus == .details) {
            self.message.set("Select tables or rows to change pages");
            return;
        }
        if (self.focus == .tables) {
            if (forward) {
                if (!self.tables_next or self.table_offset > std.math.maxInt(i64) - max_tables) return;
                self.table_offset += max_tables;
            } else {
                if (self.table_offset == 0) return;
                self.table_offset -= max_tables;
            }
            self.row_offset = 0;
            self.column_offset = 0;
            self.row_count = 0;
            self.column_count = 0;
            self.total_columns = 0;
            self.query_results = false;
            self.loadTables();
            if (!self.failed) self.message.set("Table page changed");
            return;
        }
        if (forward) {
            if (!self.rows_next or self.row_offset > std.math.maxInt(i64) - max_rows) return;
            self.row_offset += max_rows;
        } else {
            if (self.row_offset == 0) return;
            self.row_offset -= max_rows;
        }
        if (self.query_results) self.loadQueryPage() else self.loadRows();
        if (!self.failed) self.message.set("Row page changed");
    }

    fn pageColumns(self: *App, forward: bool) void {
        if (self.focus != .rows) {
            self.message.set("Select rows to change column pages");
            return;
        }
        if (forward) {
            if (self.column_offset + max_columns >= self.total_columns) return;
            self.column_offset += max_columns;
        } else {
            if (self.column_offset == 0) return;
            self.column_offset -= max_columns;
        }
        const selected = self.row_index;
        if (self.query_results) self.loadQueryPage() else self.loadRows();
        if (self.row_count > 0) self.row_index = @min(selected, self.row_count - 1);
        if (!self.failed) self.message.set("Column page changed");
    }

    fn moveColumn(self: *App, delta: isize) void {
        if (self.column_count == 0) return;
        const next: isize = @as(isize, @intCast(self.column_index)) + delta;
        self.column_index = @intCast(@max(0, @min(next, @as(isize, @intCast(self.column_count - 1)))));
        self.detail_offset = 0;
    }

    fn move(self: *App, delta: isize) void {
        if (self.focus == .details) {
            if (self.row_count == 0 or self.column_count == 0) return;
            const len = if (self.detail) |detail| detail.len else self.cells[self.row_index][self.column_index].len;
            const next = @as(isize, @intCast(self.detail_offset)) + delta * @as(isize, @intCast(self.detail_width));
            self.detail_offset = @intCast(@max(0, @min(next, @as(isize, @intCast(if (len == 0) 0 else len - 1)))));
            const text = if (self.detail) |detail| detail else self.cells[self.row_index][self.column_index].slice();
            while (self.detail_offset > 0 and self.detail_offset < text.len and text[self.detail_offset] & 0xc0 == 0x80) self.detail_offset -= 1;
            return;
        }
        const total = if (self.focus == .tables) self.table_count else self.row_count;
        if (total == 0) return;
        const index = if (self.focus == .tables) &self.table_index else &self.row_index;
        const next: isize = @as(isize, @intCast(index.*)) + delta;
        const previous = index.*;
        index.* = @intCast(@max(0, @min(next, @as(isize, @intCast(total - 1)))));
        if (previous != index.*) self.detail_offset = 0;
        if (self.focus == .tables and previous != index.*) {
            self.row_offset = 0;
            self.column_offset = 0;
            self.loadRows();
        }
    }

    const SearchMatch = struct { page: usize, index: usize, column: usize };

    // Scan the same bounded pages used by the browser without changing selection.
    // Re-preparation preserves the row ordering used for editable tables.
    fn scanSearchPage(self: *App, offset: usize, tables: bool, current: usize, backwards: bool, first: *?SearchMatch, last: *?SearchMatch, nearest: *?SearchMatch) ?bool {
        var stmt: ?*Stmt = null;
        var key_kind: c_int = 0;
        var is_write: c_int = 0;
        const rc = if (tables)
            app_prepare_tables(self.db, @intCast(offset), &stmt)
        else if (self.query_results)
            app_prepare_statement(self.db, self.active_query.cstr(), &stmt, 0, &is_write)
        else if (self.writable)
            app_prepare_editable_rows(self.db, self.tables[self.table_index].cstr(), @intCast(offset), &stmt, &key_kind)
        else
            app_prepare_rows(self.db, self.tables[self.table_index].cstr(), @intCast(offset), &stmt);
        if (rc != sqlite_ok or stmt == null) {
            self.setError();
            return null;
        }
        defer _ = sqlite3_finalize(stmt.?);
        if (!tables and self.query_results) {
            for (0..offset) |_| {
                const step = sqlite3_step(stmt.?);
                if (step == sqlite_done) return false;
                if (step != sqlite_row) {
                    self.setError();
                    return null;
                }
            }
        }
        const limit: usize = if (tables) max_tables else max_rows;
        var count: usize = 0;
        var valid: usize = 0;
        while (count < limit) : (count += 1) {
            const step = sqlite3_step(stmt.?);
            if (step == sqlite_done) return false;
            if (step != sqlite_row) {
                self.setError();
                return null;
            }
            var found: ?usize = null;
            if (tables) {
                const name = sqlite3_column_text(stmt.?, 0) orelse {
                    self.setError();
                    return null;
                };
                const len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 0)));
                if (len >= self.tables[0].data.len or std.mem.indexOfScalar(u8, name[0..len], 0) != null) continue;
                if (std.mem.indexOf(u8, name[0..len], self.search.slice()) != null) found = 0;
            } else {
                const hidden: usize = if (key_kind == 1) 1 else 0;
                const ncols: usize = @intCast(@max(0, sqlite3_column_count(stmt.?) - @as(c_int, @intCast(hidden))));
                for (0..ncols) |col| {
                    const column: c_int = @intCast(col + hidden);
                    const cell_type = sqlite3_column_type(stmt.?, column);
                    var blob_label: [40]u8 = undefined;
                    const value: []const u8 = if (cell_type == 5) "NULL" else if (cell_type == 4)
                        std.fmt.bufPrint(&blob_label, "[BLOB {d} bytes]", .{@max(0, sqlite3_column_bytes(stmt.?, column))}) catch "[BLOB]"
                    else if (sqlite3_column_text(stmt.?, column)) |text|
                        text[0..@intCast(@max(0, sqlite3_column_bytes(stmt.?, column)))]
                    else {
                        self.setError();
                        return null;
                    };
                    if (std.mem.indexOf(u8, value, self.search.slice()) != null) {
                        found = col;
                        break;
                    }
                }
            }
            const index = if (tables) valid else count;
            if (tables) valid += 1;
            if (found) |col| {
                const match = SearchMatch{ .page = offset, .index = index, .column = col };
                if (first.* == null) first.* = match;
                last.* = match;
                const absolute = offset + index;
                if (backwards) {
                    if (absolute < current) nearest.* = match;
                } else if (absolute > current and nearest.* == null) nearest.* = match;
            }
            const absolute = offset + index;
            if (nearest.* != null and ((!backwards) or absolute >= current)) return false;
        }
        const step = sqlite3_step(stmt.?);
        if (step == sqlite_row) return true;
        if (step == sqlite_done) return false;
        self.setError();
        return null;
    }

    fn searchPages(self: *App, tables: bool, current: usize, backwards: bool) ?SearchMatch {
        app_query_begin(self.db);
        defer app_query_end(self.db);
        const page_size: usize = if (tables) max_tables else max_rows;
        var first: ?SearchMatch = null;
        var last: ?SearchMatch = null;
        var nearest: ?SearchMatch = null;
        var offset: usize = 0;
        while (true) {
            const more = self.scanSearchPage(offset, tables, current, backwards, &first, &last, &nearest) orelse return null;
            if (!more or (!backwards and nearest != null) or (backwards and nearest != null and offset + page_size > current)) break;
            if (offset > std.math.maxInt(i64) - page_size) {
                self.failed = true;
                self.message.set("Search exceeded page limit");
                return null;
            }
            offset += page_size;
        }
        return nearest orelse (if (backwards) last else first);
    }

    fn find(self: *App, backwards: bool) void {
        self.failed = false;
        if (self.focus == .details) {
            self.message.set("Select the tables or rows panel to search");
            return;
        }
        if (self.search.len == 0) return;
        const tables = self.focus == .tables;
        if ((if (tables) self.table_count else self.row_count) == 0) return;
        const current = if (tables) self.table_offset + self.table_index else self.row_offset + self.row_index;
        const match = self.searchPages(tables, current, backwards) orelse {
            if (!self.failed) self.message.set("No match");
            return;
        };
        if (tables) {
            self.table_offset = match.page;
            self.row_offset = 0;
            self.column_offset = 0;
            self.loadTables();
            if (self.failed) return;
            if (match.index >= self.table_count) {
                self.message.set("Search results changed. Retry");
                return;
            }
            self.table_index = match.index;
            self.loadRows();
        } else {
            self.row_offset = match.page;
            self.column_offset = (match.column / max_columns) * max_columns;
            if (self.query_results) self.loadQueryPage() else self.loadRows();
            if (self.failed) return;
            if (match.index >= self.row_count or match.column < self.column_offset or match.column - self.column_offset >= self.column_count) {
                self.message.set("Search results changed. Retry");
                return;
            }
            self.row_index = match.index;
            self.column_index = match.column - self.column_offset;
            self.detail_offset = 0;
        }
        if (!self.failed) self.message.set("Match found");
    }

    fn reload(self: *App) void {
        const selected = self.table_index;
        self.row_offset = 0;
        self.column_offset = 0;
        self.table_count = 0;
        self.table_index = 0;
        self.row_count = 0;
        self.column_count = 0;
        self.failed = false;
        self.loadTables();
        if (selected < self.table_count and selected != 0) {
            self.table_index = selected;
            self.loadRows();
        }
    }

    fn switchAccess(self: *App, writable: bool) void {
        var next: ?*Db = null;
        var err: [256]u8 = @splat(0);
        if (app_reopen_live(self.db, if (writable) 1 else 0, &next, &err, err.len) == 0 or next == null) {
            self.message.set(std.mem.sliceTo(&err, 0));
            return;
        }
        self.db = next.?;
        self.writable = writable;
        self.reload();
        if (!self.failed) self.message.set(if (writable) "Write mode enabled" else "Read-only mode enabled");
    }

    fn confirm(self: *App, accepted: bool) void {
        if (accepted) {
            var cols: u16 = 0;
            var rows: u16 = 0;
            app_terminal_size(&cols, &rows);
            if (cols < 40 or rows < 12) return;
        }
        const pending = self.pending;
        self.pending = .none;
        if (!accepted) {
            self.message.set("Cancelled");
            return;
        }
        switch (pending) {
            .switch_write => self.switchAccess(true),
            .sql_write => {
                var err: [256]u8 = @splat(0);
                if (app_execute_write(self.db, self.query.cstr(), &err, err.len) != 0) {
                    self.reload();
                    if (!self.failed) self.message.set("Write committed");
                } else self.message.set(std.mem.sliceTo(&err, 0));
            },
            .cell_write => {
                var err: [256]u8 = @splat(0);
                const ok = app_update_cell(self.db, self.tables[self.table_index].cstr(), self.columns[self.column_index].cstr(), self.rowids[self.row_index], self.row_key_kind, @intCast(self.row_offset), @intCast(self.row_index), self.cell_value.cstr(), self.cell_update_type, self.row_version, &err, err.len) != 0;
                self.reload();
                if (ok) {
                    if (!self.failed) self.message.set("Cell update committed");
                } else self.message.set(std.mem.sliceTo(&err, 0));
            },
            .none => {},
        }
    }

    fn command(self: *App) void {
        const cmd = self.input.slice();
        if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) self.running = false else if (std.mem.eql(u8, cmd, "help")) self.help = true else if (std.mem.eql(u8, cmd, "reload")) {
            self.reload();
            if (!self.failed) self.message.set("Database reloaded");
        } else if (std.mem.eql(u8, cmd, "null")) {
            if (!self.writable or self.query_results or !self.row_editable or self.focus == .tables or self.row_count == 0 or self.column_count == 0 or self.columns[self.column_index].truncated) {
                self.message.set("Select an editable cell in write mode");
            } else {
                self.cell_value.set("");
                self.cell_update_type = 5;
                self.pending = .cell_write;
                self.message.set("Set selected cell to NULL? y/n");
            }
        } else if (std.mem.eql(u8, cmd, "set ro") or std.mem.eql(u8, cmd, "set readonly")) {
            if (self.writable) self.switchAccess(false) else self.message.set("Read-only mode is already active");
        } else if (std.mem.eql(u8, cmd, "set rw") or std.mem.eql(u8, cmd, "set write")) {
            if (self.writable) self.message.set("Write mode is already active") else {
                self.pending = .switch_write;
                self.message.set("Enable write mode and recovery? y/n");
            }
        } else self.message.set("Unknown command. Press ? for help");
    }

    fn loadBlobInput(self: *App) bool {
        var version: c_int = 0;
        if (app_data_version(self.db, 1, &version) != sqlite_ok or version != self.row_version) {
            self.message.set("Database changed. Reload before editing");
            return false;
        }
        var stmt: ?*Stmt = null;
        app_query_begin(self.db);
        defer app_query_end(self.db);
        var key_kind: c_int = 0;
        const rc = if (self.row_key_kind == 2)
            app_prepare_editable_rows(self.db, self.tables[self.table_index].cstr(), @intCast(self.row_offset), &stmt, &key_kind)
        else
            app_prepare_rows(self.db, self.tables[self.table_index].cstr(), @intCast(self.row_offset), &stmt);
        if (rc != sqlite_ok or stmt == null or (self.row_key_kind == 2 and key_kind != 2)) {
            if (stmt) |prepared| _ = sqlite3_finalize(prepared);
            self.message.set("Cannot read BLOB");
            return false;
        }
        defer _ = sqlite3_finalize(stmt.?);
        for (0..self.row_index + 1) |_| if (sqlite3_step(stmt.?) != sqlite_row) {
            self.message.set("Cannot read BLOB");
            return false;
        };
        const col: c_int = @intCast(self.column_offset + self.column_index);
        if (sqlite3_column_type(stmt.?, col) != 4) {
            self.message.set("Cell changed. Reload before editing");
            return false;
        }
        const len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, col)));
        if (len > (self.input.data.len - 1) / 2) {
            self.message.set("BLOB exceeds the hex editor limit");
            return false;
        }
        const ptr = sqlite3_column_blob(stmt.?, col);
        if (len > 0 and ptr == null) {
            self.message.set("Cannot read BLOB");
            return false;
        }
        self.input.set("");
        const hex = "0123456789ABCDEF";
        if (ptr) |bytes| for (bytes[0..len]) |byte| {
            self.input.append(&.{ hex[byte >> 4], hex[byte & 15] });
        };
        if (app_data_version(self.db, 1, &version) != sqlite_ok or version != self.row_version) {
            self.message.set("Database changed. Reload before editing");
            return false;
        }
        return true;
    }

    fn editCell(self: *App) void {
        if (!self.writable) {
            self.message.set("Enable write mode before editing");
            return;
        }
        if (self.query_results or !self.row_editable or self.row_count == 0 or self.column_count == 0 or self.focus == .tables) {
            self.message.set("Select an editable table cell");
            return;
        }
        self.cell_update_type = self.cell_types[self.row_index][self.column_index];
        if (self.cell_update_type == 4 and !self.columns[self.column_index].truncated) {
            if (self.loadBlobInput()) self.mode = .cell;
            return;
        }
        if (self.cell_update_type == 5 and !self.columns[self.column_index].truncated) {
            self.cell_update_type = 3;
            self.mode = .cell;
            self.input.set("");
            self.message.set("Enter text to replace NULL");
            return;
        }
        if (!self.editable_cells[self.row_index][self.column_index]) {
            if (self.detail) |detail| {
                if (self.cell_types[self.row_index][self.column_index] == 3 and
                    !self.columns[self.column_index].truncated and detail.len < self.input.data.len)
                {
                    if (!std.unicode.utf8ValidateSlice(detail)) {
                        self.message.set("Cell requires SQL editing");
                        return;
                    }
                    for (detail) |ch| if (ch == 0) {
                        self.message.set("Cell requires SQL editing");
                        return;
                    };
                    self.mode = .cell;
                    self.input.set(detail);
                    return;
                }
            }
            self.message.set("Cell requires SQL editing: NUL, invalid UTF-8, or long value");
            return;
        }
        self.mode = .cell;
        self.input.set(self.cells[self.row_index][self.column_index].slice());
    }

    fn inputKey(self: *App, ch: u8) void {
        if (ch == 27) {
            self.mode = .normal;
            return;
        }
        if (ch == 10 or ch == 13) {
            if (self.input.truncated) {
                self.message.set("Input limit reached. Shorten or clear input");
                return;
            }
            if (!std.unicode.utf8ValidateSlice(self.input.slice())) {
                self.message.set("Input is not valid UTF-8");
                return;
            }
            switch (self.mode) {
                .command => self.command(),
                .search => {
                    self.search.set(self.input.slice());
                    self.find(false);
                },
                .insert => self.runQuery(),
                .cell => {
                    self.cell_value.set(self.input.slice());
                    self.pending = .cell_write;
                    self.message.set("Save cell change? Triggers may run. y/n");
                },
                .normal => {},
            }
            self.mode = .normal;
        } else if (ch == 21) {
            self.input.set("");
        } else if (ch == 127 or ch == 8) {
            if (self.input.len > 0) {
                self.input.len -= 1;
                while (self.input.len > 0 and self.input.data[self.input.len] & 0xc0 == 0x80) self.input.len -= 1;
                self.input.data[self.input.len] = 0;
                self.input.truncated = false;
            }
        } else if (ch >= 32) {
            self.input.append(&.{ch});
        }
    }

    fn key(self: *App, keycode: c_int) void {
        if (keycode < 0 or keycode > 255) return;
        const k: u8 = @intCast(keycode);
        if (self.pending != .none) {
            if (k == 'y' or k == 'Y') self.confirm(true) else if (k == 'n' or k == 'N' or k == 27) self.confirm(false);
            return;
        }
        if (self.mode != .normal) {
            self.inputKey(k);
            return;
        }
        if (self.help) {
            self.help = false;
            return;
        }
        if (k >= '0' and k <= '9' and (self.count != 0 or k != '0')) {
            self.count = @min(10000, self.count * 10 + (k - '0'));
            return;
        }
        const raw_count = self.count;
        const count: isize = @intCast(if (raw_count == 0) @as(usize, 1) else raw_count);
        self.count = 0;
        if (k == 'g') {
            if (self.pending_g) {
                self.move(-100000);
                if (self.pending_count > 0) self.move(@intCast(self.pending_count - 1));
                self.pending_g = false;
                self.pending_count = 0;
            } else {
                self.pending_g = true;
                self.pending_count = raw_count;
            }
            return;
        }
        self.pending_g = false;
        self.pending_count = 0;
        switch (k) {
            'q' => self.running = false,
            '?' => self.help = true,
            ':' => {
                self.mode = .command;
                self.input.set("");
            },
            '/' => {
                self.mode = .search;
                self.input.set("");
            },
            'i' => {
                self.mode = .insert;
                self.input.set(self.query.slice());
            },
            'e' => self.editCell(),
            'n' => self.find(false),
            'N' => self.find(true),
            '[' => self.page(false),
            ']' => self.page(true),
            '<' => self.pageColumns(false),
            '>' => self.pageColumns(true),
            'j' => self.move(count),
            'k' => self.move(-count),
            'G' => {
                if (raw_count == 0) self.move(100000) else {
                    self.move(-100000);
                    self.move(@intCast(raw_count - 1));
                }
            },
            'h' => switch (self.focus) {
                .tables => {},
                .rows => self.moveColumn(-count),
                .details => self.focus = .rows,
            },
            'l' => switch (self.focus) {
                .tables => self.focus = .rows,
                .rows => self.moveColumn(count),
                .details => {},
            },
            '\t', '\r', '\n' => self.focus = switch (self.focus) {
                .tables => .rows,
                .rows => .details,
                .details => .tables,
            },
            else => {},
        }
    }
};
var app: App = undefined;
var frame: [256 * 1024]u8 = undefined;
var frame_len: usize = 0;
var framing = false;
var drawn_lines: [100]bool = @splat(false);

fn output(fd: c_int, bytes: []const u8) void {
    if (framing and fd == 1) {
        if (bytes.len <= frame.len - frame_len) {
            @memcpy(frame[frame_len..][0..bytes.len], bytes);
            frame_len += bytes.len;
        }
        return;
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return;
        offset += @intCast(n);
    }
}
// Render untrusted text as ASCII. Escape non-ASCII code points and invalid bytes.
fn renderSafe(text: []const u8, rendered: []u8) struct { used: usize, consumed: usize } {
    var used: usize = 0;
    var consumed: usize = 0;
    const limit = rendered.len;
    while (consumed < text.len and used < limit) {
        const ch = text[consumed];
        if (ch >= 32 and ch < 127) {
            rendered[used] = ch;
            used += 1;
            consumed += 1;
            continue;
        }
        var encoded: [16]u8 = undefined;
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(ch) catch 1;
        const codepoint = if (seq_len > 1 and consumed + seq_len <= text.len)
            std.unicode.utf8Decode(text[consumed..][0..seq_len]) catch null
        else
            null;
        const token = if (codepoint) |cp|
            std.fmt.bufPrint(&encoded, "\\u{{{X}}}", .{cp}) catch unreachable
        else
            std.fmt.bufPrint(&encoded, "\\x{X:0>2}", .{ch}) catch unreachable;
        if (token.len > limit - used) {
            if (used == 0) {
                rendered[used] = '?';
                used += 1;
                consumed += if (codepoint != null) seq_len else 1;
            }
            break;
        }
        @memcpy(rendered[used..][0..token.len], token);
        used += token.len;
        consumed += if (codepoint != null) seq_len else 1;
    }
    return .{ .used = used, .consumed = consumed };
}

fn outputSafe(fd: c_int, text: []const u8) void {
    var rendered: [512]u8 = undefined;
    var offset: usize = 0;
    while (offset < text.len) {
        const result = renderSafe(text[offset..], &rendered);
        output(fd, rendered[0..result.used]);
        offset += result.consumed;
    }
}

fn clearRow(row: usize) void {
    if (framing and row > 0 and row <= drawn_lines.len and !drawn_lines[row - 1]) {
        drawn_lines[row - 1] = true;
        var escape: [40]u8 = undefined;
        output(1, std.fmt.bufPrint(&escape, "\x1b[{d};1H\x1b[2K", .{row}) catch return);
    }
}

fn printSafeAt(row: usize, col: usize, width: usize, text: []const u8) usize {
    if (width == 0) return 0;
    clearRow(row);
    var escape: [40]u8 = undefined;
    output(1, std.fmt.bufPrint(&escape, "\x1b[{d};{d}H", .{ row, col }) catch return 0);
    var rendered: [512]u8 = undefined;
    const result = renderSafe(text, rendered[0..@min(width, rendered.len)]);
    output(1, rendered[0..result.used]);
    return result.consumed;
}

fn printAt(row: usize, col: usize, width: usize, text: []const u8) void {
    _ = printSafeAt(row, col, width, text);
}

fn gridLine(a: *App, row: ?usize) Text {
    var result: Text = .{};
    for (a.column_index..a.column_count) |i| {
        if (i != a.column_index) result.append(" | ");
        const selected = i == a.column_index and (row == null or (row.? == a.row_index and a.focus == .rows));
        if (selected) result.append("[");
        const item = if (row) |r| &a.cells[r][i] else &a.columns[i];
        const value = item.slice();
        result.append(value[0..@min(value.len, 48)]);
        if (value.len > 48 or item.truncated) result.append("~");
        if (selected) result.append("]");
    }
    return result;
}

fn printItems(a: *App, start_col: usize, width: usize, is_tables: bool) void {
    const available = a.height - 7;
    const total = if (is_tables) a.table_count else a.row_count;
    const selected = if (is_tables) a.table_index else a.row_index;
    const first = if (selected >= available) selected - available + 1 else 0;
    const end = @min(total, first + available);
    var line: [512]u8 = undefined;
    for (first..end) |i| {
        const grid = if (is_tables) Text{} else gridLine(a, i);
        const text = if (is_tables) a.tables[i].slice() else grid.slice();
        const prefix: []const u8 = if (selected == i and ((is_tables and a.focus == .tables) or (!is_tables and a.focus == .rows))) "> " else "  ";
        const formatted = std.fmt.bufPrint(&line, "{s}{s}", .{ prefix, text[0..@min(text.len, width)] }) catch continue;
        const active = selected == i and ((is_tables and a.focus == .tables) or (!is_tables and a.focus == .rows));
        clearRow(5 + i - first);
        if (active) output(1, "\x1b[7m");
        printAt(5 + i - first, start_col, width, formatted);
        if (active) output(1, "\x1b[0m");
    }
}

fn printDetails(a: *App, col: usize, width: usize) void {
    a.detail_width = @max(1, width);
    var buffer: [512]u8 = undefined;
    clearRow(3);
    output(1, "\x1b[7m");
    printAt(3, col, width, if (a.focus == .details) "> DETAIL / SQL" else "DETAIL / SQL");
    output(1, "\x1b[0m");
    const position = std.fmt.bufPrint(&buffer, "Row {d}  Column {d}/{d}", .{ if (a.row_count == 0) @as(usize, 0) else a.row_offset + a.row_index + 1, if (a.column_count == 0) @as(usize, 0) else a.column_offset + a.column_index + 1, a.total_columns }) catch "Selection";
    printAt(4, col, width, position);
    if (a.row_count > 0 and a.column_count > 0) {
        printAt(5, col, width, a.columns[a.column_index].slice());
        const cell = &a.cells[a.row_index][a.column_index];
        const text = if (a.detail) |detail| detail else cell.slice();
        var offset = @min(a.detail_offset, text.len);
        var row: usize = 6;
        while (offset < text.len and row < a.height - 5 and width > 0) : (row += 1) {
            const n = printSafeAt(row, col, width, text[offset..]);
            if (n == 0) break;
            offset += n;
        }
        if (cell.truncated and a.detail == null) {
            printAt(a.height - 5, col, width, "Full value unavailable");
        } else if (offset < text.len) {
            printAt(a.height - 5, col, width, "More below");
        }
    }
    printAt(a.height - 4, col, width, if (a.writable) "j/k: scroll  e: edit  i: SQL" else "j/k: scroll  i: SQL");
}

const Layout = struct {
    multi: bool,
    three: bool,
    table_width: usize,
    middle_col: usize,
    detail_width: usize,
    detail_col: usize,
    row_width: usize,
};

fn layout(a: *const App) Layout {
    const multi = a.cols > 60;
    const three = a.cols >= 100;
    var name_width: usize = 6;
    for (a.tables[0..a.table_count]) |*table| {
        var rendered: [128]u8 = undefined;
        const result = renderSafe(table.slice(), &rendered);
        name_width = @max(name_width, result.used);
    }
    const table_width = if (multi) @min(@min(24, a.cols / 3), @max(10, name_width + 3)) else a.cols;
    const middle_col = if (multi) table_width + 2 else 1;
    const detail_width = if (three) @min(35, a.cols / 3) else a.cols - middle_col + 1;
    const detail_col = if (three) a.cols - detail_width + 1 else middle_col;
    return .{ .multi = multi, .three = three, .table_width = table_width, .middle_col = middle_col, .detail_width = detail_width, .detail_col = detail_col, .row_width = if (three) detail_col - middle_col - 1 else a.cols - middle_col + 1 };
}

// Center and wrap the minimum-size warning even in very narrow terminals.
fn centerResize(cols: usize, rows: usize) void {
    if (cols == 0 or rows == 0) return;
    const message = "Resize terminal to at least 40 x 12";
    var lines: [message.len][]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    while (start < message.len and count < lines.len) {
        while (start < message.len and message[start] == ' ') start += 1;
        if (start == message.len) break;
        var end = @min(message.len, start + cols);
        if (end < message.len and message[end] != ' ') {
            var split = end;
            while (split > start and message[split] != ' ') split -= 1;
            if (split > start) end = split;
        }
        lines[count] = message[start..end];
        count += 1;
        start = end;
    }
    const shown = @min(rows, count);
    const top = (rows - shown) / 2 + 1;
    for (0..shown) |i| printAt(top + i, (cols - lines[i].len) / 2 + 1, cols, lines[i]);
}

fn draw(a: *App) void {
    frame_len = 0;
    framing = true;
    drawn_lines = @splat(false);
    defer {
        var clear: [40]u8 = undefined;
        for (0..a.height) |row| {
            if (!drawn_lines[row]) output(1, std.fmt.bufPrint(&clear, "\x1b[{d};1H\x1b[2K", .{row + 1}) catch continue);
        }
        output(1, "\x1b[?2026l");
        framing = false;
        output(1, frame[0..frame_len]);
    }
    output(1, "\x1b[?2026h\x1b[?25l");
    var cols: u16 = 0;
    var height: u16 = 0;
    app_terminal_size(&cols, &height);
    a.cols = @min(cols, 240);
    a.height = @min(height, 100);
    if (a.cols < 40 or a.height < 12) {
        centerResize(a.cols, a.height);
        return;
    }
    var line: [512]u8 = undefined;
    const mode_name: []const u8 = if (a.pending != .none) "CONFIRM" else if (a.help) "HELP" else switch (a.mode) {
        .normal => "NORMAL",
        .command => "COMMAND",
        .search => "SEARCH",
        .insert, .cell => "INSERT",
    };
    const focus_name: []const u8 = switch (a.focus) {
        .tables => "TABLES",
        .rows => "ROWS",
        .details => "DETAIL",
    };
    const title = std.fmt.bufPrint(&line, "[{s}] {s} | {s} | {s}", .{ if (a.writable) @as([]const u8, "RW") else "RO", mode_name, focus_name, a.path.slice() }) catch "[RO]";
    printAt(1, 1, a.cols, title);
    if (!a.help and a.pending == .none and a.mode == .normal) {
        clearRow(2);
        output(1, "\x1b[7m");
        const page_number = if (a.focus == .tables) a.table_offset / max_tables + 1 else a.row_offset / max_rows + 1;
        const more = if (a.focus == .tables) a.tables_next else a.rows_next;
        const tabs = std.fmt.bufPrint(&line, " TABLES  ROWS  DETAIL  [<] [>] p{d}{s}", .{ page_number, if (more) @as([]const u8, "+") else "" }) catch " TABLES  ROWS  DETAIL  [<] [>]";
        printAt(2, 1, a.cols, tabs);
        output(1, "\x1b[0m");
    }
    if (a.help) {
        printAt(3, 1, a.cols, "HELP | Press any key to close");
        printAt(4, 1, a.cols, "Tab/Enter: next panel   arrows: move");
        printAt(5, 1, a.cols, "hjkl: move   5j: move five");
        printAt(6, 1, a.cols, "gg/G or Home/End: first/last");
        printAt(7, 1, a.cols, "/: search   n/N: next/previous match");
        printAt(8, 1, a.cols, "i: SQL   e: edit cell   Esc: cancel");
        printAt(9, 1, a.cols, ":set rw/ro  :null  :reload  q: quit");
        printAt(10, 1, a.cols, "PgUp/PgDn: scroll   []: page   <>: columns");
        printAt(11, 1, a.cols, "Mouse: tabs, rows, wheel, drag to scroll");
        return;
    }
    const geometry = layout(a);
    const multi = geometry.multi;
    const three = geometry.three;
    const table_width = geometry.table_width;
    const middle_col = geometry.middle_col;
    const detail_width = geometry.detail_width;
    const detail_col = geometry.detail_col;
    const row_width = geometry.row_width;
    if (multi or a.focus == .tables) {
        clearRow(3);
        output(1, "\x1b[7m");
        printAt(3, 1, table_width, if (a.focus == .tables) "> TABLES" else "TABLES");
        output(1, "\x1b[0m");
        printItems(a, 1, table_width, true);
    }
    if ((multi and (three or a.focus != .details)) or (!multi and a.focus == .rows)) {
        const label: []const u8 = if (a.query_results) "QUERY RESULTS" else if (a.table_count > 0) a.tables[a.table_index].slice() else "No tables";
        const heading = std.fmt.bufPrint(&line, "ROWS: {s}", .{label}) catch "ROWS";
        clearRow(3);
        output(1, "\x1b[7m");
        printAt(3, middle_col, row_width, heading);
        output(1, "\x1b[0m");
        const columns = gridLine(a, null);
        printAt(4, middle_col, row_width, columns.slice());
        printItems(a, middle_col, row_width, false);
    }
    if (three or a.focus == .details) printDetails(a, detail_col, detail_width);
    if (a.pending != .none) {
        printAt(a.height - 2, 1, a.cols, a.message.slice());
        printAt(a.height - 1, 1, a.cols, "y: confirm  n/Esc: cancel");
    } else if (a.mode == .normal) {
        printAt(a.height - 2, 1, a.cols, a.message.slice());
        printAt(a.height - 1, 1, a.cols, if (a.writable) "Tab: panel []:page e:edit ?:help q:quit" else "Tab: panel []:page i:SQL ?:help q:quit");
    } else {
        const prompt: []const u8 = if (a.input.truncated) "Input limit reached. Shorten or clear input" else if (!std.unicode.utf8ValidateSlice(a.input.slice())) "Invalid UTF-8. Correct or clear input" else "Append-only Enter:go Esc:cancel ^U:clear";
        printAt(a.height - 2, 1, a.cols, prompt);
        const label: []const u8 = switch (a.mode) {
            .command => ":",
            .search => "/",
            .insert => "SQL> ",
            .cell => if (a.cell_update_type == 4) "BLOB hex> " else "CELL> ",
            .normal => "",
        };
        const room = a.cols - label.len;
        const text = a.input.slice();
        const clipped = text.len > room;
        const visible = if (clipped) text[text.len - (room - 1) ..] else text;
        const input = std.fmt.bufPrint(&line, "{s}{s}{s}", .{ label, if (clipped) "<" else "", visible }) catch label;
        printAt(a.height - 1, 1, a.cols, input);
    }
}

var drag_y: ?usize = null;

fn pointer(a: *App, sequence: []const u8, final: c_int) void {
    if (a.pending != .none or a.mode != .normal or a.help or sequence.len < 2 or sequence[0] != '<') return;
    var parts = std.mem.splitScalar(u8, sequence[1..], ';');
    const button = std.fmt.parseInt(u16, parts.next() orelse return, 10) catch return;
    const x = std.fmt.parseInt(u16, parts.next() orelse return, 10) catch return;
    const y = std.fmt.parseInt(u16, parts.next() orelse return, 10) catch return;
    if (parts.next() != null or x == 0 or y == 0 or x > a.cols or y > a.height) return;
    if (final == 'm') {
        drag_y = null;
        return;
    }
    if ((button & 64) != 0) {
        const geometry = layout(a);
        if (geometry.multi and x <= geometry.table_width) a.focus = .tables else if (geometry.three and x >= geometry.detail_col) a.focus = .details else if (geometry.multi and a.focus != .details) a.focus = .rows;
        a.move(if ((button & 1) == 0) -3 else 3);
        return;
    }
    if ((button & 32) != 0) {
        if (drag_y) |previous| {
            const delta = @as(isize, @intCast(previous)) - @as(isize, @intCast(y));
            if (delta != 0) a.move(delta);
            drag_y = y;
        }
        return;
    }
    if ((button & 3) != 0) return;
    drag_y = y;
    if (y == 2) {
        if (x <= 8) a.focus = .tables else if (x <= 14) a.focus = .rows else if (x <= 22) a.focus = .details else if (x >= 24 and x <= 26) a.page(false) else if (x >= 28 and x <= 30) a.page(true);
        drag_y = null;
        return;
    }
    const geometry = layout(a);
    const focus: Focus = if (!geometry.multi) a.focus else if (x <= geometry.table_width) .tables else if (geometry.three and x >= geometry.detail_col) .details else if (!geometry.three and a.focus == .details) .details else .rows;
    a.focus = focus;
    if (y < 5 or y >= a.height - 2 or focus == .details) return;
    const available = a.height - 7;
    if (y >= 5 + available) return;
    const selected = if (focus == .tables) a.table_index else a.row_index;
    const total = if (focus == .tables) a.table_count else a.row_count;
    const first = if (selected >= available) selected - available + 1 else 0;
    const target = first + y - 5;
    if (target >= total) return;
    a.move(@as(isize, @intCast(target)) - @as(isize, @intCast(selected)));
    if (focus == .rows and x >= geometry.middle_col + 2) {
        var cursor: usize = geometry.middle_col + 2;
        for (a.column_index..a.column_count) |i| {
            if (i != a.column_index) cursor += 3;
            const item = &a.cells[a.row_index][i];
            var rendered: [256]u8 = undefined;
            const value = item.slice();
            const width = renderSafe(value[0..@min(value.len, 48)], &rendered).used + @as(usize, if (value.len > 48 or item.truncated) 1 else 0) + @as(usize, if (i == a.column_index) 2 else 0);
            if (x >= cursor and x < cursor + width) {
                a.column_index = i;
                a.detail_offset = 0;
                break;
            }
            cursor += width;
        }
    }
}

fn navigation(a: *App, sequence: []const u8, final: c_int) void {
    if (a.pending != .none or a.mode != .normal or a.help) return;
    if (sequence.len > 0 and sequence[0] == '<') {
        pointer(a, sequence, final);
        return;
    }
    if (sequence.len == 0) {
        switch (final) {
            'A' => a.key('k'),
            'B' => a.key('j'),
            'C' => a.key('l'),
            'D' => a.key('h'),
            'H' => a.move(-100000),
            'F' => a.move(100000),
            else => {},
        }
    } else if (final == '~') {
        const number = std.fmt.parseInt(u8, sequence, 10) catch return;
        switch (number) {
            1, 7 => a.move(-100000),
            4, 8 => a.move(100000),
            5 => a.move(-@as(isize, @intCast(a.height - 7))),
            6 => a.move(@intCast(a.height - 7)),
            else => {},
        }
    }
}

fn confirmRecovery() bool {
    while (true) {
        var cols: u16 = 0;
        var rows: u16 = 0;
        app_terminal_size(&cols, &rows);
        output(1, "\x1b[?25l\x1b[H\x1b[2J");
        if (cols < 40 or rows < 12) {
            centerResize(cols, rows);
        } else {
            printAt(1, 1, cols, "CONFIRM | Database recovery");
            printAt(3, 1, cols, "Recovery modifies database and journal.");
            printAt(5, 1, cols, "y: confirm   n/q/Esc: cancel");
        }
        while (true) {
            const keycode = app_terminal_read();
            if (keycode == -1) break;
            if (keycode == -3) continue;
            if (keycode == -2 or keycode == 'n' or keycode == 'N' or keycode == 'q' or keycode == 27) return false;
            app_terminal_size(&cols, &rows);
            if (cols >= 40 and rows >= 12 and (keycode == 'y' or keycode == 'Y')) return true;
            break;
        }
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = init.args.iterate();
    _ = it.next();
    const first = it.next() orelse {
        output(2, "Usage: zsqt [--check | --recover] DATABASE\n");
        return 2;
    };
    if (std.mem.eql(u8, first, "--debug-test")) {
        const confirmation = it.next() orelse {
            output(2, "Usage: zsqt --debug-test --confirm\n");
            return 2;
        };
        if (!std.mem.eql(u8, confirmation, "--confirm") or it.next() != null) {
            output(2, "Usage: zsqt --debug-test --confirm\n");
            return 2;
        }
        if (comptime build_options.diagnostics) {
            return if (app_diagnostics() == 0) 0 else 1;
        } else {
            output(2, "Self-test is available only in a diagnostics build\n");
            return 2;
        }
    }
    const check = std.mem.eql(u8, first, "--check");
    const recover = std.mem.eql(u8, first, "--recover");
    const path = if (check or recover) it.next() orelse {
        output(2, "Usage: zsqt [--check | --recover] DATABASE\n");
        return 2;
    } else first;
    if (it.next() != null) {
        output(2, "Only one database may be opened\n");
        return 2;
    }
    var err: [256]u8 = @splat(0);
    if (recover) {
        if (app_terminal_enter() == 0) {
            output(2, "A terminal is required for recovery confirmation\n");
            return 1;
        }
        const accepted = confirmRecovery();
        output(1, "\x1b[0m\x1b[?25h\x1b[2J\x1b[H");
        app_terminal_leave();
        if (!accepted) return 0;
        if (app_recover(path.ptr, &err, err.len) == 0) {
            outputSafe(2, std.mem.sliceTo(&err, 0));
            output(2, "\n");
            return 1;
        }
        output(1, "Recovery check completed\n");
        return 0;
    }
    var db: ?*Db = null;
    if (app_open_live(path.ptr, 0, &db, &err, err.len) == 0 or db == null) {
        outputSafe(2, std.mem.sliceTo(&err, 0));
        output(2, "\n");
        return 1;
    }
    defer app_live_close();
    app = .{ .db = db.? };
    defer _ = sqlite3_close(app.db);
    defer app.clearDetail();
    app.path.set(path);
    app.message.set("Read-only database");
    app.loadTables();
    if (app.failed) {
        output(2, "Cannot read database: ");
        outputSafe(2, app.message.slice());
        output(2, "\nIf recovery is required, run --recover and confirm.\n");
        return 1;
    }
    if (check) {
        var buf: [100]u8 = undefined;
        output(1, std.fmt.bufPrint(&buf, "Read-only database: {d}{s} tables\n", .{ app.table_count, if (app.tables_next) @as([]const u8, "+") else "" }) catch "Read-only database\n");
        return 0;
    }
    if (app_terminal_enter() == 0) {
        output(2, "A terminal is required\n");
        return 1;
    }
    defer {
        output(1, "\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[2J\x1b[H");
        app_terminal_leave();
    }
    output(1, "\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[2J");
    app.refreshDetail();
    draw(&app);
    while (app.running) {
        const keycode = app_terminal_read();
        if (keycode == -2) break;
        if (keycode == -3) continue;
        var cols: u16 = 0;
        var rows: u16 = 0;
        app_terminal_size(&cols, &rows);
        if (cols < 40 or rows < 12) {
            // Only cancellation and quitting are safe when confirmations are hidden.
            if (app.pending != .none and (keycode == 'n' or keycode == 'N' or keycode == 27)) {
                app.confirm(false);
            } else if (app.pending == .none and app.mode != .normal and keycode == 27) {
                app.mode = .normal;
            } else if (app.pending == .none and app.mode == .normal and keycode == 'q') {
                app.running = false;
            }
        } else if (keycode == 27) {
            const next = app_terminal_read();
            if (next == '[' or next == 'O') {
                // Retain incomplete sequences across input timeouts and resize events.
                // Their trailing bytes must not become independent commands.
                var final: c_int = -3;
                var sequence: [64]u8 = undefined;
                var length: usize = 0;
                var overflow = false;
                while (true) {
                    const c = app_terminal_read();
                    if (c == -3) continue;
                    if (c == -2) {
                        app.running = false;
                        break;
                    }
                    if (c == -1) {
                        draw(&app);
                        continue;
                    }
                    if (c == 27) {
                        app.key(27);
                        break;
                    }
                    if (c >= 0x40 and c <= 0x7e) {
                        final = c;
                        break;
                    }
                    if (c >= 0x20 and c <= 0x3f) {
                        if (length < sequence.len) {
                            sequence[length] = @intCast(c);
                            length += 1;
                        } else overflow = true;
                    } else overflow = true;
                }
                app_terminal_size(&cols, &rows);
                if (cols >= 40 and rows >= 12 and app.mode == .normal and app.pending == .none) {
                    if (!overflow) navigation(&app, sequence[0..length], final);
                }
            } else {
                app.key(27);
                if (next >= 0 and app.running) app.key(next);
            }
        } else app.key(keycode);
        if (app.running) {
            app.refreshDetail();
            draw(&app);
        }
    }
    return 0;
}
