const std = @import("std");

const Db = opaque {};
const Stmt = opaque {};
extern fn app_open([*:0]const u8, *?*Db, [*]u8, usize) c_int;
extern fn app_open_wal([*:0]const u8, c_int, *?*Db, [*]u8, usize) c_int;
extern fn app_reopen_wal(*Db, c_int, *?*Db, [*]u8, usize) c_int;
extern fn app_live_close() void;
extern fn app_execute_write(*Db, [*:0]const u8, [*]u8, usize) c_int;
extern fn app_prepare_tables(*Db, *?*Stmt) c_int;
extern fn app_prepare_rows(*Db, [*:0]const u8, *?*Stmt) c_int;
extern fn app_prepare_editable_rows(*Db, [*:0]const u8, *?*Stmt, *c_int) c_int;
extern fn app_data_version(*Db, c_int, *c_int) c_int;
extern fn app_update_cell(*Db, [*:0]const u8, [*:0]const u8, i64, [*:0]const u8, c_int, c_int, [*]u8, usize) c_int;
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
const Text = struct {
    data: [256]u8 = @splat(0),
    len: usize = 0,
    truncated: bool = false,

    fn set(self: *Text, value: []const u8) void {
        self.len = @min(value.len, self.data.len - 1);
        self.truncated = value.len > self.len;
        @memcpy(self.data[0..self.len], value[0..self.len]);
        self.data[self.len] = 0;
    }
    fn slice(self: *const Text) []const u8 {
        return self.data[0..self.len];
    }
    fn cstr(self: *const Text) [*:0]const u8 {
        return @ptrCast(self.data[0..].ptr);
    }
    fn append(self: *Text, value: []const u8) void {
        const n = @min(value.len, self.data.len - 1 - self.len);
        @memcpy(self.data[self.len..][0..n], value[0..n]);
        if (n < value.len) self.truncated = true;
        self.len += n;
        self.data[self.len] = 0;
    }
};

const Focus = enum { tables, rows, details };
const Mode = enum { normal, command, search, insert, cell };
const Pending = enum { none, switch_write, sql_write, cell_write };
const App = struct {
    db: *Db,
    live_wal: bool = false,
    writable: bool = false,
    pending: Pending = .none,
    path: Text = .{},
    tables: [max_tables]Text = @splat(.{}),
    table_count: usize = 0,
    table_index: usize = 0,
    cells: [max_rows][max_columns]Text = @splat(@splat(.{})),
    editable_cells: [max_rows][max_columns]bool = @splat(@splat(false)),
    cell_types: [max_rows][max_columns]u8 = @splat(@splat(0)),
    rowids: [max_rows]i64 = @splat(0),
    row_editable: bool = false,
    row_version: c_int = 0,
    columns: [max_columns]Text = @splat(.{}),
    column_count: usize = 0,
    column_index: usize = 0,
    detail_offset: usize = 0,
    detail_width: usize = 1,
    row_count: usize = 0,
    row_index: usize = 0,
    message: Text = .{},
    input: Text = .{},
    search: Text = .{},
    query: Text = .{},
    cell_value: Text = .{},
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
        app_query_begin(self.db);
        defer app_query_end(self.db);
        var stmt: ?*Stmt = null;
        if (app_prepare_tables(self.db, &stmt) != sqlite_ok or stmt == null) {
            self.setError();
            return;
        }
        defer _ = sqlite3_finalize(stmt.?);
        while (true) {
            const rc = sqlite3_step(stmt.?);
            if (rc == sqlite_done) break;
            if (rc != sqlite_row) {
                self.setError();
                break;
            }
            const ptr = sqlite3_column_text(stmt.?, 0) orelse {
                self.setError();
                break;
            };
            const n: usize = @intCast(@max(0, sqlite3_column_bytes(stmt.?, 0)));
            if (n >= 256 or std.mem.indexOfScalar(u8, ptr[0..n], 0) != null) {
                self.message.set("A table name was skipped because it is too long or contains NUL");
                continue;
            }
            if (self.table_count == max_tables) {
                self.message.set("Table list limited to 128 entries");
                break;
            }
            self.tables[self.table_count].set(ptr[0..n]);
            self.table_count += 1;
        }
        if (self.table_count > 0) self.loadRows();
    }

    fn loadRows(self: *App) void {
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
        const rc = if (self.writable) app_prepare_editable_rows(self.db, self.tables[self.table_index].cstr(), &stmt, &has_rowid) else app_prepare_rows(self.db, self.tables[self.table_index].cstr(), &stmt);
        if (rc != sqlite_ok or stmt == null) {
            self.setError();
            return;
        }
        self.row_editable = has_rowid != 0 and version_ok;
        self.readRows(stmt.?, has_rowid != 0);
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
        self.query_results = true;
        self.row_editable = false;
        self.focus = .rows;
        self.message.set(if (self.writable) "Query results, limited to 500 rows" else "Read-only query results, limited to 500 rows");
        self.readRows(stmt.?, false);
    }

    fn readRows(self: *App, stmt: *Stmt, has_rowid: bool) void {
        self.row_count = 0;
        self.row_index = 0;
        self.column_index = 0;
        self.detail_offset = 0;
        const offset: usize = if (has_rowid) 1 else 0;
        const ncols: usize = @intCast(@max(0, sqlite3_column_count(stmt) - @as(c_int, @intCast(offset))));
        self.column_count = @min(ncols, max_columns);
        if (ncols > max_columns) self.message.set("Only the first 32 columns are shown");
        for (0..self.column_count) |i| {
            self.columns[i].set("");
            if (sqlite3_column_name(stmt, @intCast(i + offset))) |name| self.columns[i].set(std.mem.span(name));
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
                const col: c_int = @intCast(i + offset);
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
                var editable = cell_type >= 1 and cell_type <= 3 and !cell.truncated and !self.columns[i].truncated;
                for (cell.slice()) |ch| if (ch < 32 or ch >= 127) {
                    editable = false;
                    break;
                };
                self.editable_cells[self.row_count][i] = editable;
            }
            self.row_count += 1;
        }
        if (self.row_count == max_rows) {
            self.message.set(if (ncols > max_columns) "Showing at most 500 rows and 32 columns" else "Showing at most 500 rows");
        }
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
            const len = self.cells[self.row_index][self.column_index].len;
            const next = @as(isize, @intCast(self.detail_offset)) + delta * @as(isize, @intCast(self.detail_width));
            self.detail_offset = @intCast(@max(0, @min(next, @as(isize, @intCast(if (len == 0) 0 else len - 1)))));
            return;
        }
        const total = if (self.focus == .tables) self.table_count else self.row_count;
        if (total == 0) return;
        const index = if (self.focus == .tables) &self.table_index else &self.row_index;
        const next: isize = @as(isize, @intCast(index.*)) + delta;
        const previous = index.*;
        index.* = @intCast(@max(0, @min(next, @as(isize, @intCast(total - 1)))));
        if (previous != index.*) self.detail_offset = 0;
        if (self.focus == .tables and previous != index.*) self.loadRows();
    }

    fn find(self: *App, backwards: bool) void {
        if (self.focus == .details) {
            self.message.set("Select the tables or rows panel to search");
            return;
        }
        if (self.search.len == 0) return;
        const total = if (self.focus == .tables) self.table_count else self.row_count;
        if (total == 0) return;
        const selected = if (self.focus == .tables) self.table_index else self.row_index;
        for (1..total + 1) |offset| {
            const idx = if (backwards) (selected + total - offset % total) % total else (selected + offset) % total;
            var found = false;
            var matching_column: usize = 0;
            if (self.focus == .tables) {
                found = std.mem.indexOf(u8, self.tables[idx].slice(), self.search.slice()) != null;
            } else {
                for (self.cells[idx][0..self.column_count], 0..) |*cell, col| {
                    if (std.mem.indexOf(u8, cell.slice(), self.search.slice()) != null) {
                        found = true;
                        matching_column = col;
                        break;
                    }
                }
            }
            if (found) {
                if (self.focus == .tables) {
                    self.table_index = idx;
                    self.loadRows();
                } else {
                    self.row_index = idx;
                    self.column_index = matching_column;
                    self.detail_offset = 0;
                }
                self.message.set("Match found");
                return;
            }
        }
        self.message.set("No match");
    }

    fn reload(self: *App) void {
        const selected = self.table_index;
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
        if (!self.live_wal) {
            self.message.set("Write mode requires an established WAL database");
            return;
        }
        if (app_reopen_wal(self.db, if (writable) 1 else 0, &next, &err, err.len) == 0 or next == null) {
            self.message.set(std.mem.sliceTo(&err, 0));
            return;
        }
        self.db = next.?;
        self.writable = writable;
        self.reload();
        if (!self.failed) self.message.set(if (writable) "Write mode enabled" else "Read-only mode enabled");
    }

    fn confirm(self: *App, accepted: bool) void {
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
                const ok = app_update_cell(self.db, self.tables[self.table_index].cstr(), self.columns[self.column_index].cstr(), self.rowids[self.row_index], self.cell_value.cstr(), self.cell_types[self.row_index][self.column_index], self.row_version, &err, err.len) != 0;
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
        } else if (std.mem.eql(u8, cmd, "set ro") or std.mem.eql(u8, cmd, "set readonly")) {
            if (self.writable) self.switchAccess(false) else self.message.set("Read-only mode is already active");
        } else if (std.mem.eql(u8, cmd, "set rw") or std.mem.eql(u8, cmd, "set write")) {
            if (self.writable) self.message.set("Write mode is already active") else if (!self.live_wal) self.message.set("Write mode requires an established WAL database") else {
                self.pending = .switch_write;
                self.message.set("Enable write mode? y/n");
            }
        } else self.message.set("Unknown command. Press ? for help");
    }

    fn editCell(self: *App) void {
        if (!self.writable) {
            self.message.set("Enable write mode before editing");
            return;
        }
        if (self.query_results or !self.row_editable or self.row_count == 0 or self.column_count == 0 or self.focus == .tables) {
            self.message.set("Select a cell in an ordinary rowid table");
            return;
        }
        if (!self.editable_cells[self.row_index][self.column_index]) {
            self.message.set("Cell requires SQL editing: NULL, BLOB, non-ASCII, or truncated value");
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
                self.input.data[self.input.len] = 0;
            }
        } else if (ch >= 32 and ch < 127 and self.input.len < 255) {
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

fn output(fd: c_int, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return;
        offset += @intCast(n);
    }
}
fn printAt(row: usize, col: usize, width: usize, text: []const u8) void {
    if (width == 0) return;
    var escape: [40]u8 = undefined;
    output(1, std.fmt.bufPrint(&escape, "\x1b[{d};{d}H", .{ row, col }) catch return);
    var sanitized: [512]u8 = undefined;
    const n = @min(@min(width, text.len), sanitized.len);
    for (text[0..n], 0..) |c, i| sanitized[i] = if (c >= 32 and c < 127) c else '?';
    output(1, sanitized[0..n]);
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
        const formatted = std.fmt.bufPrint(&line, "{s}{s}", .{ prefix, text }) catch continue;
        printAt(5 + i - first, start_col, width, formatted);
    }
}

fn printDetails(a: *App, col: usize, width: usize) void {
    a.detail_width = @max(1, width);
    var buffer: [512]u8 = undefined;
    printAt(3, col, width, if (a.focus == .details) "> DETAIL / SQL" else "DETAIL / SQL");
    const position = std.fmt.bufPrint(&buffer, "Row {d}/{d}  Column {d}/{d}", .{ if (a.row_count == 0) @as(usize, 0) else a.row_index + 1, a.row_count, if (a.column_count == 0) @as(usize, 0) else a.column_index + 1, a.column_count }) catch "Selection";
    printAt(4, col, width, position);
    if (a.row_count > 0 and a.column_count > 0) {
        printAt(5, col, width, a.columns[a.column_index].slice());
        const cell = &a.cells[a.row_index][a.column_index];
        const text = cell.slice();
        var offset = @min(a.detail_offset, text.len);
        var row: usize = 6;
        while (offset < text.len and row < a.height - 5 and width > 0) : (row += 1) {
            const n = @min(width, text.len - offset);
            printAt(row, col, width, text[offset..][0..n]);
            offset += n;
        }
        if (cell.truncated) {
            printAt(a.height - 5, col, width, "Value truncated at 255 bytes");
        } else if (offset < text.len) {
            printAt(a.height - 5, col, width, "More below");
        }
    }
    printAt(a.height - 4, col, width, if (a.writable) "j/k: scroll  e: edit  i: SQL" else "j/k: scroll  i: SQL");
}

fn draw(a: *App) void {
    var cols: u16 = 0;
    var height: u16 = 0;
    app_terminal_size(&cols, &height);
    a.cols = @min(cols, 240);
    a.height = @min(height, 100);
    output(1, "\x1b[?25l\x1b[H\x1b[2J");
    if (a.cols < 40 or a.height < 12) {
        printAt(1, 1, a.cols, "Resize terminal to at least 40 x 12");
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
    if (a.help) {
        printAt(3, 1, a.cols, "HELP | Press any key to close");
        printAt(4, 1, a.cols, "Tab/Enter: next panel   arrows: move");
        printAt(5, 1, a.cols, "hjkl: move   5j: move five");
        printAt(6, 1, a.cols, "gg/G: first/last   5gg/5G: row five");
        printAt(7, 1, a.cols, "/: search   n/N: next/previous match");
        printAt(8, 1, a.cols, "i: SQL   e: edit cell   Esc: cancel");
        printAt(9, 1, a.cols, ":set rw/ro: access   :reload   q: quit");
        printAt(10, 1, a.cols, "Enter: submit   Ctrl-U: clear input");
        return;
    }
    const multi = a.cols > 60;
    const three = a.cols >= 100;
    const table_width: usize = if (multi) @min(24, a.cols / 3) else a.cols;
    const middle_col: usize = if (multi) table_width + 3 else 1;
    const detail_width: usize = if (three) @min(35, a.cols / 3) else a.cols - middle_col + 1;
    const detail_col: usize = if (three) a.cols - detail_width + 1 else middle_col;
    const row_width: usize = if (three) detail_col - middle_col - 2 else a.cols - middle_col + 1;
    if (multi or a.focus == .tables) {
        printAt(3, 1, table_width, if (a.focus == .tables) "> TABLES" else "TABLES");
        printItems(a, 1, table_width, true);
    }
    if ((multi and (three or a.focus != .details)) or (!multi and a.focus == .rows)) {
        const label: []const u8 = if (a.query_results) "QUERY RESULTS" else if (a.table_count > 0) a.tables[a.table_index].slice() else "No tables";
        const heading = std.fmt.bufPrint(&line, "ROWS: {s}", .{label}) catch "ROWS";
        printAt(3, middle_col, row_width, heading);
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
        printAt(a.height - 1, 1, a.cols, if (a.writable) "Tab: panel e: edit i: SQL ?: help q: quit" else "Tab: panel  i: SQL  ?: help  q: quit");
    } else {
        printAt(a.height - 2, 1, a.cols, "Enter: submit  Esc: cancel  Ctrl-U: clear");
        const label: []const u8 = switch (a.mode) {
            .command => ":",
            .search => "/",
            .insert => "SQL> ",
            .cell => "CELL> ",
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

fn confirmSnapshot(live_wal: bool) bool {
    while (true) {
        var cols: u16 = 0;
        var rows: u16 = 0;
        app_terminal_size(&cols, &rows);
        output(1, "\x1b[?25l\x1b[H\x1b[2J");
        if (cols < 40 or rows < 12) {
            printAt(1, 1, cols, "Resize terminal to at least 40 x 12");
        } else {
            printAt(1, 1, cols, if (live_wal) "[RO] CONFIRM | WAL database" else "[RO] CONFIRM | Database snapshot");
            printAt(3, 1, cols, "Recovery journals are not checked.");
            printAt(4, 1, cols, if (live_wal) "No rollback recovery may be pending." else "Open only a cleanly closed database.");
            if (live_wal) printAt(5, 1, cols, "Open only an established WAL database.");
            printAt(7, 1, cols, "y: confirm   n/q/Esc: cancel");
        }
        while (true) {
            const keycode = app_terminal_read();
            if (keycode == -1) break;
            if (keycode == -3) continue;
            if (keycode == -2 or keycode == 'n' or keycode == 'q' or keycode == 27) return false;
            if (cols >= 40 and rows >= 12 and (keycode == 'y' or keycode == 'Y')) return true;
        }
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = init.args.iterate();
    _ = it.next();
    const first = it.next() orelse {
        output(2, "Usage: zig-sql-tui [--check] DATABASE\n");
        return 2;
    };
    const check = std.mem.eql(u8, first, "--check");
    const path = if (check) it.next() orelse {
        output(2, "Usage: zig-sql-tui [--check] DATABASE\n");
        return 2;
    } else first;
    if (it.next() != null) {
        output(2, "Only one database may be opened\n");
        return 2;
    }
    var db: ?*Db = null;
    var err: [256]u8 = @splat(0);
    var live_wal = false;
    if (app_open(path.ptr, &db, &err, err.len) == 0 or db == null) {
        if (std.mem.eql(u8, std.mem.sliceTo(&err, 0), "WAL databases are not supported by this read-only snapshot")) {
            if (app_open_wal(path.ptr, 0, &db, &err, err.len) != 0 and db != null) live_wal = true;
        }
        if (db == null) {
            output(2, std.mem.sliceTo(&err, 0));
            output(2, "\n");
            return 1;
        }
    }
    defer if (live_wal) app_live_close();
    app = .{ .db = db.?, .live_wal = live_wal };
    defer _ = sqlite3_close(app.db);
    app.path.set(path);
    app.message.set(if (live_wal) "Read-only WAL database. Recovery journals are not checked." else "Read-only snapshot. Open only cleanly closed rollback-mode databases.");
    app.loadTables();
    if (app.failed) {
        output(2, "Cannot read database schema or rows\n");
        return 1;
    }
    if (check) {
        output(2, if (live_wal) "Recovery journals are not checked. Open only established WAL databases.\n" else "Recovery journals are not checked. Open only cleanly closed databases.\n");
        var buf: [100]u8 = undefined;
        output(1, std.fmt.bufPrint(&buf, "Read-only {s}: {d} tables\n", .{ if (live_wal) @as([]const u8, "WAL database") else "snapshot", app.table_count }) catch "Read-only database\n");
        return 0;
    }
    if (app_terminal_enter() == 0) {
        output(2, "A terminal is required\n");
        return 1;
    }
    defer {
        output(1, "\x1b[0m\x1b[?25h\x1b[2J\x1b[H");
        app_terminal_leave();
    }
    if (!confirmSnapshot(live_wal)) return 0;
    draw(&app);
    while (app.running) {
        const keycode = app_terminal_read();
        if (keycode == -2) break;
        if (keycode == -3) continue;
        if (keycode == 27 and app.mode == .normal and app.pending == .none) {
            const next = app_terminal_read();
            if (next == '[') {
                const arrow = app_terminal_read();
                app.key(switch (arrow) {
                    'A' => 'k',
                    'B' => 'j',
                    'C' => 'l',
                    'D' => 'h',
                    else => 0,
                });
            }
        } else app.key(keycode);
        if (app.running) draw(&app);
    }
    return 0;
}
