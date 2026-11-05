const std = @import("std");
const io = @import("tool_io.zig");
const policy = @import("release_policy.zig");

// Encode prerelease identifiers as letters and numeric runs so Debian ordering
// matches SemVer, including ASCII ordering within alphanumeric identifiers.
fn version(alloc: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const parsed = try policy.parseVersion(tag);
    var out: std.ArrayList(u8) = .empty;
    for (parsed.core, 0..) |part, i| {
        if (i != 0) try out.append(alloc, '.');
        try out.appendSlice(alloc, part);
    }
    if (parsed.pre) |pre| {
        try out.append(alloc, '~');
        var parts = std.mem.splitScalar(u8, pre, '.');
        while (parts.next()) |part| {
            var numeric = true;
            for (part) |ch| if (!std.ascii.isDigit(ch)) {
                numeric = false;
                break;
            };
            if (numeric) {
                try out.append(alloc, 'b');
                try out.appendSlice(alloc, part);
            } else {
                try out.append(alloc, 'c');
                for (part) |ch| {
                    try out.append(alloc, 'b');
                    try out.append(alloc, 'a' + (ch >> 4));
                    try out.append(alloc, 'a' + (ch & 15));
                }
            }
            try out.append(alloc, 'a');
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var args = init.args.iterate();
    _ = args.next();
    const tag = args.next() orelse {
        io.write(2, "Usage: deb-version SEMVER_TAG\n");
        return 2;
    };
    if (args.next() != null) return 2;
    const result = version(alloc, tag) catch {
        io.write(2, "Invalid SemVer tag\n");
        return 1;
    };
    io.write(1, result);
    io.write(1, "\n");
    return 0;
}

test "stable versions discard build metadata" {
    const alloc = std.testing.allocator;
    const got = try version(alloc, "v2.3.4+build.7");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("2.3.4", got);
    try std.testing.expectError(error.InvalidSemVer, version(alloc, "v2.03.4"));
}

test "prerelease versions encode identifiers" {
    const alloc = std.testing.allocator;
    const got = try version(alloc, "v1.2.3-A.2+build");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("1.2.3~cbebab2a", got);
}

test "Debian ordering follows SemVer prerelease precedence" {
    const process = @import("process_support.zig");
    const alloc = std.testing.allocator;
    const tags = [_][]const u8{
        "v1.0.0-0",       "v1.0.0-1",        "v1.0.0-10",         "v1.0.0--",
        "v1.0.0-A",       "v1.0.0-a",        "v1.0.0-a.0",        "v1.0.0-a.1",
        "v1.0.0-a-10",    "v1.0.0-a-2",      "v1.0.0-alpha",      "v1.0.0-alpha.1",
        "v1.0.0-alpha.2", "v1.0.0-alpha.10", "v1.0.0-alpha.beta", "v1.0.0-beta",
        "v1.0.0-rc.1",    "v1.0.0",          "v1.0.1",            "v1.1.0",
        "v2.0.0",
    };
    for (tags[0 .. tags.len - 1], tags[1..]) |left, right| {
        const a = try version(alloc, left);
        defer alloc.free(a);
        const b = try version(alloc, right);
        defer alloc.free(b);
        const az = try std.fmt.allocPrintSentinel(alloc, "{s}", .{a}, 0);
        defer alloc.free(az);
        const bz = try std.fmt.allocPrintSentinel(alloc, "{s}", .{b}, 0);
        defer alloc.free(bz);
        const args = [_:null]?[*:0]const u8{ "dpkg", "--compare-versions", az.ptr, "lt", bz.ptr };
        const result = try process.run(&args, null);
        if (result.status != 0) std.debug.print("Wrong Debian order: {s} < {s}\n", .{ left, right });
        try std.testing.expectEqual(@as(c_int, 0), result.status);
    }
}
