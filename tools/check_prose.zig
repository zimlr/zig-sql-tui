const std = @import("std");
const c = std.c;
const io = @import("tool_io.zig");
const Allocator = std.mem.Allocator;
extern "c" fn iswalnum(c_uint) c_int;
extern "c" fn realpath([*:0]const u8, [*]u8) ?[*:0]u8;
extern "c" fn setlocale(c_int, [*:0]const u8) ?[*:0]const u8;

fn report(alloc: Allocator, prefix: []const u8, line: usize, kind: []const u8, value: []const u8) !void {
    const text = try std.fmt.allocPrint(alloc, "{s}{d}: {s}{s}\n", .{ prefix, line, kind, value });
    io.write(1, text);
}
fn scalarAt(text: []const u8, i: usize) ?struct { cp: u21, len: usize } {
    if (i >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
    if (i + len > text.len) return null;
    return .{ .cp = std.unicode.utf8Decode(text[i .. i + len]) catch return null, .len = len };
}
fn whitespaceAt(text: []const u8, i: usize) usize {
    const value = scalarAt(text, i) orelse return 0;
    const cp = value.cp;
    if ((cp >= 0x09 and cp <= 0x0d) or (cp >= 0x1c and cp <= 0x20) or cp == 0x85 or cp == 0xa0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000) return value.len;
    return 0;
}
fn skipSpace(text: []const u8, pos: *usize) void {
    while (pos.* < text.len) {
        const n = whitespaceAt(text, pos.*);
        if (n == 0) break;
        pos.* += n;
    }
}
fn regexFold(cp: u21) ?u8 {
    if (cp < 128) return std.ascii.toLower(@intCast(cp));
    return switch (cp) {
        0x130, 0x131 => 'i',
        0x17f => 's',
        0x212a => 'k',
        else => null,
    };
}
fn phraseEnd(text: []const u8, start: usize, phrase: []const u8) ?usize {
    var pos = start;
    for (phrase) |expected| {
        const value = scalarAt(text, pos) orelse return null;
        if (regexFold(value.cp) != expected) return null;
        pos += value.len;
    }
    return pos;
}
fn wordAt(text: []const u8, i: usize) bool {
    if (i >= text.len) return false;
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return false;
    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch return false;
    return cp == '_' or iswalnum(cp) != 0;
}
fn wordBefore(text: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    var i = pos - 1;
    while (i > 0 and text[i] & 0xc0 == 0x80) : (i -= 1) {}
    return wordAt(text, i);
}
fn nextLine(text: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= text.len) return null;
    const start = pos.*;
    while (pos.* < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[pos.*]) catch unreachable;
        const cp = std.unicode.utf8Decode(text[pos.* .. pos.* + len]) catch unreachable;
        if (cp == '\n' or cp == '\r' or cp == 0x0b or cp == 0x0c or (cp >= 0x1c and cp <= 0x1e) or cp == 0x85 or cp == 0x2028 or cp == 0x2029) {
            const end = pos.*;
            pos.* += len;
            if (cp == '\r' and pos.* < text.len and text[pos.*] == '\n') pos.* += 1;
            return text[start..end];
        }
        pos.* += len;
    }
    return text[start..];
}

// Remove inline code spans before reducing links to their visible labels.
fn visible(alloc: Allocator, line: []const u8) ![]const u8 {
    var code: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            var count: usize = 0;
            while (i + count < line.len and line[i + count] == '`') : (count += 1) {}
            var n = count;
            var end: ?usize = null;
            while (n > 0 and end == null) : (n -= 1) {
                var j = i + n;
                while (j < line.len) : (j += 1) {
                    if (line[j] != '`') continue;
                    var run: usize = 0;
                    while (j + run < line.len and line[j + run] == '`') : (run += 1) {}
                    if (run >= n) {
                        end = j + n;
                        break;
                    }
                    j += run - 1;
                }
            }
            if (end) |finish| {
                i = finish;
                continue;
            }
        }
        try code.append(alloc, line[i]);
        i += 1;
    }
    var result: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < code.items.len) {
        if (code.items[i] == '[') {
            const close_rel = std.mem.indexOfScalar(u8, code.items[i + 1 ..], ']');
            if (close_rel) |rel| {
                const close = i + 1 + rel;
                if (close > i + 1 and close + 1 < code.items.len and code.items[close + 1] == '(') {
                    if (std.mem.indexOfScalar(u8, code.items[close + 2 ..], ')')) |end_rel| {
                        try result.appendSlice(alloc, code.items[i + 1 .. close]);
                        i = close + 3 + end_rel;
                        continue;
                    }
                }
            }
        }
        try result.append(alloc, code.items[i]);
        i += 1;
    }
    return result.items;
}
fn punctuation(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == ';' or ch == '!' or ch == '?') return text[i .. i + 1];
        if (std.mem.startsWith(u8, text[i..], "...")) return text[i .. i + 3];
        const len = std.unicode.utf8ByteSequenceLength(ch) catch return null;
        if (i + len > text.len) return null;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch return null;
        if (cp == 0x2013 or cp == 0x2014 or cp == 0x2026 or (cp >= 0x1f000 and cp <= 0x1faff)) return text[i .. i + len];
        i += len;
    }
    return null;
}
fn banned(text: []const u8) ?[]const u8 {
    const phrases = [_][]const u8{ "we", "our", "ours", "us", "you", "your", "yours", "let's", "certainly", "great question", "here's the thing", "it's worth noting", "in conclusion", "battle-tested", "bulletproof", "blazing", "supercharge", "unlock", "journey" };
    var i: usize = 0;
    while (i < text.len) {
        if (!wordBefore(text, i)) for (phrases) |phrase| {
            if (phraseEnd(text, i, phrase)) |end| {
                if (!wordAt(text, end)) return text[i..end];
            }
        };
        i += scalarAt(text, i).?.len;
    }
    return null;
}
fn opening(sentence: []const u8) ?[]const u8 {
    var i: usize = 0;
    skipSpace(sentence, &i);
    if (i < sentence.len and (sentence[i] == '-' or sentence[i] == '*') and whitespaceAt(sentence, i + 1) != 0) {
        i += 1;
        skipSpace(sentence, &i);
    }
    if (i + 2 < sentence.len and sentence[i] == '[' and (sentence[i + 1] == ' ' or sentence[i + 1] == 'x') and sentence[i + 2] == ']') {
        i += 3;
        skipSpace(sentence, &i);
    }
    const start = i;
    while (i < sentence.len and std.ascii.isAlphabetic(sentence[i])) : (i += 1) {}
    if (i == start or wordAt(sentence, i)) return null;
    return sentence[start..i];
}
fn check(alloc: Allocator, text: []const u8, prefix: []const u8) !bool {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var failed = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;
    var number: usize = 0;
    var position: usize = 0;
    while (nextLine(text, &position)) |line| {
        number += 1;
        var skip: usize = 0;
        skipSpace(line, &skip);
        const stripped = line[skip..];
        if (stripped.len > 0 and (stripped[0] == '`' or stripped[0] == '~')) {
            var count: usize = 0;
            while (count < stripped.len and stripped[count] == stripped[0]) : (count += 1) {}
            if (count >= 3) {
                if (fence_char == 0) {
                    fence_char = stripped[0];
                    fence_len = count;
                } else if (fence_char == stripped[0] and count >= fence_len) {
                    fence_char = 0;
                }
                continue;
            }
        }
        if (fence_char != 0 or std.mem.startsWith(u8, line, "    ")) continue;
        const prose = try visible(alloc, line);
        if (punctuation(prose)) |p| {
            try report(alloc, prefix, number, "prohibited punctuation: ", p);
            failed = true;
        }
        if (banned(prose)) |p| {
            try report(alloc, prefix, number, "prohibited phrase: ", p);
            failed = true;
        }
        var start: usize = 0;
        var i: usize = 0;
        var previous: ?[]const u8 = null;
        while (true) {
            if (i == prose.len or (i > 0 and whitespaceAt(prose, i) != 0 and (prose[i - 1] == '.' or prose[i - 1] == '!' or prose[i - 1] == '?'))) {
                const current = if (opening(prose[start..i])) |word| try std.ascii.allocLowerString(alloc, word) else null;
                if (current != null and previous != null and std.mem.eql(u8, current.?, previous.?)) {
                    try report(alloc, prefix, number, "repeated sentence opening: ", current.?);
                    failed = true;
                }
                previous = current;
                if (i == prose.len) break;
                skipSpace(prose, &i);
                start = i;
                continue;
            }
            i += scalarAt(prose, i).?.len;
        }
    }
    if (fence_char != 0) {
        try report(alloc, prefix, number, "unclosed code fence", "");
        failed = true;
    }
    return failed;
}
const Entry = struct { name: []const u8, is_dir: bool };
fn less(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}
fn excluded(name: []const u8, parent: []const u8) bool {
    for ([_][]const u8{ ".git", ".zig-cache", "zig-out", "vendor", "__pycache__" }) |skip| if (std.mem.eql(u8, name, skip)) return true;
    return std.mem.eql(u8, parent, "tools") and std.mem.eql(u8, name, "zig");
}
fn walk(alloc: Allocator, parent: []const u8, failed: *bool) !void {
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}", .{if (parent.len == 0) "." else parent}, 0);
    const dir = c.opendir(path.ptr) orelse return error.DirectoryOpenFailed;
    defer _ = c.closedir(dir);
    var entries: std.ArrayList(Entry) = .empty;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const full = try std.fmt.allocPrintSentinel(alloc, "{s}{s}{s}", .{ parent, if (parent.len == 0) "" else "/", name }, 0);
        var link_buf: [1]u8 = undefined;
        const is_link = c.readlink(full.ptr, &link_buf, link_buf.len) >= 0;
        var is_dir = false;
        if (!is_link) {
            if (c.opendir(full.ptr)) |child| {
                is_dir = true;
                _ = c.closedir(child);
            }
        }
        try entries.append(alloc, .{ .name = try alloc.dupe(u8, name), .is_dir = is_dir });
    }
    std.mem.sort(Entry, entries.items, {}, less);
    for (entries.items) |entry| {
        if (entry.is_dir or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const full = try std.fmt.allocPrintSentinel(alloc, "{s}{s}{s}", .{ parent, if (parent.len == 0) "" else "/", entry.name }, 0);
        const data = try io.readMarkdown(alloc, full.ptr);
        const prefix = try std.fmt.allocPrint(alloc, "{s}:", .{full});
        if (try check(alloc, data, prefix)) failed.* = true;
    }
    for (entries.items) |entry| {
        if (!entry.is_dir or excluded(entry.name, parent)) continue;
        const child = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ parent, if (parent.len == 0) "" else "/", entry.name });
        try walk(alloc, child, failed);
    }
}
// Installed tools reside below the repository root. Locate it independently of
// the caller's working directory, as the original script did.
fn findRoot(program: [*:0]const u8) ?[:0]const u8 {
    var resolved: [4096]u8 = undefined;
    const absolute = realpath(program, &resolved) orelse return null;
    var path: []u8 = std.mem.sliceTo(absolute, 0);
    while (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash == 0) break;
        path = path[0..slash];
        var build_buf: [4200]u8 = undefined;
        var style_buf: [4200]u8 = undefined;
        const build = std.fmt.bufPrintSentinel(&build_buf, "{s}/build.zig", .{path}, 0) catch return null;
        const style = std.fmt.bufPrintSentinel(&style_buf, "{s}/WRITING_STYLE.md", .{path}, 0) catch return null;
        if (c.access(build.ptr, 0) == 0 and c.access(style.ptr, 0) == 0) {
            // Change directory while the local buffer remains alive.
            resolved[slash] = 0;
            if (c.chdir(@ptrCast(&resolved)) == 0) return ".";
            return null;
        }
    }
    return null;
}
pub fn main(init: std.process.Init.Minimal) u8 {
    _ = setlocale(0, "C.UTF-8");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var args = init.args.iterate();
    const program = args.next() orelse return 2;
    if (args.next()) |first| {
        if (std.mem.eql(u8, first, "--text")) {
            const text = args.next() orelse return 2;
            if (args.next() != null) return 2;
            const failed = check(alloc, text, "") catch {
                io.write(2, "Could not check prose\n");
                return 1;
            };
            return if (failed) 1 else 0;
        }
        if (std.mem.eql(u8, first, "--root")) {
            const root = args.next() orelse return 2;
            if (args.next() != null or c.chdir(root.ptr) != 0) return 2;
        } else {
            io.write(2, "Usage: check-prose [--text TEXT | --root DIRECTORY]\n");
            return 2;
        }
    } else {
        _ = findRoot(program.ptr);
    }
    var failed = false;
    walk(alloc, "", &failed) catch {
        io.write(2, "Could not read project Markdown\n");
        return 1;
    };
    if (failed) return 1;
    io.write(1, "Project Markdown passed the mechanical prose check.\n");
    return 0;
}
