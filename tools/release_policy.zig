const std = @import("std");
const c = std.c;
const io = @import("tool_io.zig");
const process = @import("process_support.zig");
const Allocator = std.mem.Allocator;

pub const Version = struct { core: [3][]const u8, pre: ?[]const u8 };

fn numeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}
fn identifiers(s: []const u8, prerelease: bool) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
        if (prerelease and numeric(part) and part.len > 1 and part[0] == '0') return false;
    }
    return true;
}
pub fn parseVersion(tag: []const u8) !Version {
    if (tag.len < 2 or tag[0] != 'v') return error.InvalidSemVer;
    const value = tag[1..];
    const plus = std.mem.indexOfScalar(u8, value, '+') orelse value.len;
    const before_metadata = value[0..plus];
    if (plus < value.len and !identifiers(value[plus + 1 ..], false)) return error.InvalidSemVer;
    const dash = std.mem.indexOfScalar(u8, before_metadata, '-') orelse before_metadata.len;
    const pre = if (dash < before_metadata.len) before_metadata[dash + 1 ..] else null;
    if (pre) |p| if (!identifiers(p, true)) return error.InvalidSemVer;
    var core: [3][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, before_metadata[0..dash], '.');
    for (&core) |*part| {
        part.* = it.next() orelse return error.InvalidSemVer;
        if (!numeric(part.*) or (part.*.len > 1 and part.*[0] == '0')) return error.InvalidSemVer;
    }
    if (it.next() != null) return error.InvalidSemVer;
    return .{ .core = core, .pre = pre };
}
fn compareNumeric(a: []const u8, b: []const u8) std.math.Order {
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return std.mem.order(u8, a, b);
}
fn compare(a: Version, b: Version) std.math.Order {
    for (a.core, b.core) |x, y| {
        const order = compareNumeric(x, y);
        if (order != .eq) return order;
    }
    const left = a.pre orelse return if (b.pre == null) .eq else .gt;
    const right = b.pre orelse return .lt;
    var ai = std.mem.splitScalar(u8, left, '.');
    var bi = std.mem.splitScalar(u8, right, '.');
    while (true) {
        const x = ai.next();
        const y = bi.next();
        if (x == null) return if (y == null) .eq else .lt;
        if (y == null) return .gt;
        if (std.mem.eql(u8, x.?, y.?)) continue;
        const xn = numeric(x.?);
        const yn = numeric(y.?);
        if (xn and yn) return compareNumeric(x.?, y.?);
        if (xn != yn) return if (xn) .lt else .gt;
        return std.mem.order(u8, x.?, y.?);
    }
}
const Release = struct { tag: []const u8, draft: bool };

fn whitespaceLen(text: []const u8, pos: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return 0;
    if (pos + len > text.len) return 0;
    const cp = std.unicode.utf8Decode(text[pos .. pos + len]) catch return 0;
    if ((cp >= 0x09 and cp <= 0x0d) or (cp >= 0x1c and cp <= 0x20) or cp == 0x85 or cp == 0xa0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000) return len;
    return 0;
}
// GitHub's paginated output consists of adjacent JSON arrays, not one JSON document.
fn pages(alloc: Allocator, text: []const u8) ![]Release {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidJson;
    var found = false;
    var out: std.ArrayList(Release) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        while (pos < text.len) {
            const len = whitespaceLen(text, pos);
            if (len == 0) break;
            pos += len;
        }
        if (pos == text.len) break;
        found = true;
        if (text[pos] != '[') return error.InvalidReleasePages;
        const start = pos;
        var depth: usize = 0;
        var quoted = false;
        var escaped = false;
        while (pos < text.len) : (pos += 1) {
            const ch = text[pos];
            if (quoted) {
                if (escaped) escaped = false else if (ch == '\\') escaped = true else if (ch == '"') quoted = false;
                continue;
            }
            if (ch == '"') quoted = true else if (ch == '[' or ch == '{') {
                depth += 1;
            } else if (ch == ']' or ch == '}') {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
                if (depth == 0) {
                    pos += 1;
                    break;
                }
            }
        }
        if (depth != 0 or quoted) return error.InvalidJson;
        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, text[start..pos], .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch return error.InvalidJson;
        if (value != .array) return error.InvalidReleasePages;
        for (value.array.items) |item| {
            if (item != .object) return error.InvalidRelease;
            const tag = item.object.get("tag_name") orelse return error.InvalidRelease;
            const draft = item.object.get("draft") orelse return error.InvalidRelease;
            if (tag != .string or draft != .bool) return error.InvalidRelease;
            try out.append(alloc, .{ .tag = tag.string, .draft = draft.bool });
        }
    }
    if (!found) return error.EmptyReleasePages;
    return out.toOwnedSlice(alloc);
}
fn git(args: []const [*:0]const u8) !process.Result {
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    if (args.len > 15) return error.GitFailure;
    argv[0] = "git";
    for (args, 0..) |arg, i| argv[i + 1] = arg;
    return process.run(&argv, null) catch return error.GitFailure;
}
fn trimOutput(alloc: Allocator, result: *const process.Result) ![:0]const u8 {
    const trimmed = std.mem.trim(u8, result.out(), " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.GitFailure;
    return std.fmt.allocPrintSentinel(alloc, "{s}", .{trimmed}, 0);
}
fn validate(alloc: Allocator, tag: []const u8, releases: []Release, commit: []const u8) !Version {
    const candidate = try parseVersion(tag);
    for (releases) |release| if (std.mem.eql(u8, release.tag, tag)) return error.ReleaseAlreadyExists;
    const reference = try std.fmt.allocPrintSentinel(alloc, "refs/tags/{s}", .{tag}, 0);
    const exists = try git(&.{ "show-ref", "--verify", "--quiet", reference.ptr });
    if (exists.status == 0) return error.TagAlreadyExists;
    if (exists.status != 1 << 8) return error.GitFailure;
    const commit_expr = try std.fmt.allocPrintSentinel(alloc, "{s}^{{commit}}", .{commit}, 0);
    const target = try git(&.{ "rev-parse", "--verify", "--end-of-options", commit_expr.ptr });
    if (target.status != 0) return error.CandidateCommitInvalid;
    const target_id = try trimOutput(alloc, &target);
    var latest: ?Version = null;
    var latest_tag: []const u8 = undefined;
    var ties: usize = 0;
    for (releases) |release| {
        if (release.draft) continue;
        const version = try parseVersion(release.tag);
        if (latest == null or compare(version, latest.?) == .gt) {
            latest = version;
            latest_tag = release.tag;
            ties = 1;
        } else if (compare(version, latest.?) == .eq) ties += 1;
    }
    if (latest == null) {
        if (!std.mem.eql(u8, tag, "v1.0.0")) return error.FirstRelease;
        return candidate;
    }
    if (ties != 1) return error.AmbiguousHistory;
    if (compare(candidate, latest.?) != .gt) return error.Precedence;
    const previous_expr = try std.fmt.allocPrintSentinel(alloc, "refs/tags/{s}^{{commit}}", .{latest_tag}, 0);
    const previous = try git(&.{ "rev-parse", "--verify", "--end-of-options", previous_expr.ptr });
    if (previous.status != 0) return error.PublishedTagInvalid;
    const previous_id = try trimOutput(alloc, &previous);
    const ancestor = try git(&.{ "merge-base", "--is-ancestor", previous_id.ptr, target_id.ptr });
    if (ancestor.status == 1 << 8) return error.NotAncestor;
    if (ancestor.status != 0) return error.GitFailure;
    const diff = try git(&.{ "diff", "--no-ext-diff", "--no-textconv", "--quiet", previous_id.ptr, target_id.ptr, "--" });
    if (diff.status == 0) return error.NoChanges;
    if (diff.status != 1 << 8) return error.GitFailure;
    return candidate;
}
fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidSemVer => "Invalid SemVer tag",
        error.InvalidJson => "Invalid JSON release API response",
        error.InvalidReleasePages => "Release API response must contain paginated release arrays",
        error.EmptyReleasePages => "Release API response is empty",
        error.InvalidRelease => "Release API response contains an invalid release",
        error.ReleaseAlreadyExists => "A release or draft already uses this tag",
        error.TagAlreadyExists => "The requested tag already exists",
        error.CandidateCommitInvalid => "Candidate commit cannot be resolved",
        error.FirstRelease => "The first published release must be v1.0.0",
        error.AmbiguousHistory => "Published releases have ambiguous highest SemVer precedence",
        error.Precedence => "Release must have greater SemVer precedence than the latest release",
        error.PublishedTagInvalid => "Published release tag is missing or invalid",
        error.NotAncestor => "The latest published release is not an ancestor of the candidate",
        error.NoChanges => "No tracked changes since the latest published release",
        error.GitFailure => "Could not check Git release history",
        else => @errorName(err),
    };
}
fn run(alloc: Allocator, tag: []const u8, file: [*:0]const u8, commit: []const u8) !void {
    const bytes = try io.readFile(alloc, file);
    const releases = try pages(alloc, bytes);
    const result = try validate(alloc, tag, releases, commit);
    io.write(1, if (result.pre != null) "prerelease=true\n" else "prerelease=false\n");
}
pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var args = init.args.iterate();
    _ = args.next();
    const tag = args.next() orelse {
        io.write(2, "Usage: release-policy VERSION --releases FILE --commit COMMIT\n");
        return 2;
    };
    if (std.mem.eql(u8, tag, "--help")) {
        if (args.next() != null) return 2;
        io.write(1, "Usage: release-policy VERSION --releases FILE --commit COMMIT\nValidates release versions and published history.\n");
        return 0;
    }
    if (std.mem.eql(u8, tag, "--parse")) {
        const value = args.next() orelse return 2;
        if (args.next() != null) return 2;
        _ = parseVersion(value) catch {
            io.write(2, "Invalid SemVer tag\n");
            return 1;
        };
        io.write(1, "valid\n");
        return 0;
    }
    if (std.mem.eql(u8, tag, "--compare")) {
        const left = args.next() orelse return 2;
        const right = args.next() orelse return 2;
        if (args.next() != null) return 2;
        const a = parseVersion(left) catch {
            io.write(2, "Invalid SemVer tag\n");
            return 1;
        };
        const b = parseVersion(right) catch {
            io.write(2, "Invalid SemVer tag\n");
            return 1;
        };
        io.write(1, switch (compare(a, b)) {
            .lt => "-1\n",
            .eq => "0\n",
            .gt => "1\n",
        });
        return 0;
    }
    var file: ?[:0]const u8 = null;
    var commit: ?[:0]const u8 = null;
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--releases") and file == null) file = args.next() orelse return 2 else if (std.mem.eql(u8, flag, "--commit") and commit == null) commit = args.next() orelse return 2 else return 2;
    }
    if (file == null or commit == null) return 2;
    run(alloc, tag, file.?.ptr, commit.?) catch |err| {
        io.write(2, "Release validation failed: ");
        io.write(2, message(err));
        io.write(2, "\n");
        return 1;
    };
    return 0;
}
