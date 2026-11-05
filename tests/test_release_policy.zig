const std = @import("std");
const c = std.c;
const process = @import("process_support.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;

fn run(args: []const [*:0]const u8, cwd: ?[*:0]const u8) !process.Result {
    var argv: [32:null]?[*:0]const u8 = @splat(null);
    if (args.len > 32) return error.TooManyArguments;
    for (args, 0..) |arg, i| argv[i] = arg;
    return process.run(&argv, cwd);
}

fn success(result: *const process.Result) !void {
    if (result.status != 0) std.debug.print("Command failed: {s}\n{s}\n", .{ result.out(), result.err() });
    try std.testing.expectEqual(@as(c_int, 0), result.status);
}

fn expectFailure(result: *const process.Result, message: []const u8) !void {
    try std.testing.expect(result.status != 0);
    if (std.mem.indexOf(u8, result.err(), message) == null) {
        std.debug.print("Missing error {s}: {s}\n", .{ message, result.err() });
        return error.MissingError;
    }
}

fn rootPath(buffer: []u8, suffix: []const u8) ![:0]const u8 {
    var cwd_buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    return std.fmt.bufPrintSentinel(buffer, "{s}/{s}", .{ std.mem.sliceTo(cwd, 0), suffix }, 0);
}

fn policy(args: []const [*:0]const u8) !process.Result {
    var argv: [32][*:0]const u8 = undefined;
    if (args.len > 31) return error.TooManyArguments;
    argv[0] = c.getenv("ZSQT_RELEASE_POLICY") orelse "zig-out/test-bin/release-policy";
    @memcpy(argv[1..][0..args.len], args);
    return run(argv[0 .. args.len + 1], null);
}

test "SemVer precedence and metadata" {
    const tags = [_][*:0]const u8{ "v1.0.0-alpha", "v1.0.0-alpha.1", "v1.0.0-alpha.beta", "v1.0.0-beta", "v1.0.0-beta.2", "v1.0.0-beta.11", "v1.0.0-rc.1", "v1.0.0", "v1.0.1", "v1.1.0", "v2.0.0" };
    for (tags[0 .. tags.len - 1], tags[1..]) |left, right| {
        const result = try policy(&.{ "--compare", left, right });
        try success(&result);
        try std.testing.expectEqualStrings("-1\n", result.out());
    }
    for ([_][2][*:0]const u8{ .{ "v1.2.3+abc", "v1.2.3+42" }, .{ "v1.2.3-alpha+0", "v1.2.3-alpha" } }) |pair| {
        const result = try policy(&.{ "--compare", pair[0], pair[1] });
        try success(&result);
        try std.testing.expectEqualStrings("0\n", result.out());
    }
}

test "invalid and valid SemVer tags" {
    for ([_][*:0]const u8{ "1.0.0", "v01.0.0", "v1.01.0", "v1.0.01", "v1.0", "v1.0.0-01", "v1.0.0-alpha..1", "v1.0.0+", "v1.0.0-", "v1.0.0\n", "v1.0.0-α" }) |tag| {
        const result = try policy(&.{ "--parse", tag });
        try expectFailure(&result, "Invalid SemVer");
    }
    for ([_][*:0]const u8{ "v0.0.0", "v1.0.0-0", "v1.0.0-01a", "v1.0.0+001", "v1.0.0--" }) |tag| {
        const result = try policy(&.{ "--parse", tag });
        try success(&result);
        try std.testing.expectEqualStrings("valid\n", result.out());
    }
}

test "large SemVer numbers do not overflow" {
    var left: [5006]u8 = undefined;
    var right: [5007]u8 = undefined;
    left[0] = 'v';
    @memset(left[1..5001], '9');
    @memcpy(left[5001..], ".0.0\x00");
    @memcpy(right[0..2], "v1");
    @memset(right[2..5002], '0');
    @memcpy(right[5002..], ".0.0\x00");
    const result = try policy(&.{ "--compare", @ptrCast(&left), @ptrCast(&right) });
    try success(&result);
    try std.testing.expectEqualStrings("-1\n", result.out());
}

const Repo = struct {
    path: [4096]u8 = @splat(0),
    script: [4096]u8 = @splat(0),

    fn init() !Repo {
        if (c.mkdir(".zig-cache/tmp", 0o700) != 0 and c.errno(-1) != .EXIST) return error.MkdirFailed;
        var self: Repo = .{};
        const template = try rootPath(&self.path, ".zig-cache/tmp/release-test-XXXXXX");
        if (mkdtemp(@ptrCast(self.path[0..].ptr)) == null) return error.MkdtempFailed;
        _ = template;
        errdefer self.deinit();
        const tool = c.getenv("ZSQT_RELEASE_POLICY") orelse "zig-out/test-bin/release-policy";
        if (tool[0] == '/') {
            _ = try std.fmt.bufPrintSentinel(&self.script, "{s}", .{std.mem.span(tool)}, 0);
        } else {
            _ = try rootPath(&self.script, std.mem.span(tool));
        }
        try self.gitOk(&.{ "init", "-q" });
        try self.write("file", "one");
        try self.gitOk(&.{ "add", "file" });
        try self.commit("initial");
        return self;
    }

    fn deinit(self: *Repo) void {
        const result = run(&.{ "rm", "-rf", "--", @ptrCast(&self.path) }, null) catch return;
        if (result.status != 0) std.debug.print("Temporary repository cleanup failed: {s}\n", .{result.err()});
    }

    fn git(self: *Repo, args: []const [*:0]const u8) !process.Result {
        var argv: [32][*:0]const u8 = undefined;
        if (args.len > 28) return error.TooManyArguments;
        argv[0] = "git";
        argv[1] = "-C";
        argv[2] = @ptrCast(&self.path);
        @memcpy(argv[3..][0..args.len], args);
        return run(argv[0 .. args.len + 3], null);
    }

    fn gitOk(self: *Repo, args: []const [*:0]const u8) !void {
        const result = try self.git(args);
        try success(&result);
    }

    fn commit(self: *Repo, message: [*:0]const u8) !void {
        try self.gitOk(&.{ "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", message });
    }

    fn write(self: *Repo, name: []const u8, contents: []const u8) !void {
        var buf: [4200]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ std.mem.sliceTo(&self.path, 0), name }, 0);
        const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer _ = c.close(fd);
        var offset: usize = 0;
        while (offset < contents.len) {
            const n = c.write(fd, contents[offset..].ptr, contents.len - offset);
            if (n < 0 and c.errno(n) == .INTR) continue;
            if (n <= 0) return error.WriteFailed;
            offset += @intCast(n);
        }
    }

    fn change(self: *Repo, text: []const u8, message: [*:0]const u8) !void {
        try self.write("file", text);
        try self.gitOk(&.{ "add", "file" });
        try self.commit(message);
    }

    fn validate(self: *Repo, tag: [*:0]const u8, pages: []const u8) !process.Result {
        try self.write("releases.json", pages);
        return run(&.{ @ptrCast(&self.script), tag, "--releases", "releases.json", "--commit", "HEAD" }, @ptrCast(&self.path));
    }
};

const published = "[{\"tag_name\":\"v1.0.0\",\"draft\":false}]";

test "paginated release API input" {
    var repo = try Repo.init();
    defer repo.deinit();
    const good = try repo.validate("v1.0.0", "[]\n\u{a0}[]\u{2003}");
    try success(&good);
    const empty = try repo.validate("v1.0.0", "");
    try expectFailure(&empty, "empty");
    const malformed = try repo.validate("v1.0.0", "[]\n{");
    try expectFailure(&malformed, "paginated release arrays");
    const escaped = try repo.validate("v1.0.0", "[{\"tag_name\":\"draft\",\"draft\":true,\"body\":\"]}\\\"[\"}]\n[]");
    try success(&escaped);
}

test "first release and existing tag or draft" {
    var repo = try Repo.init();
    defer repo.deinit();
    const first = try repo.validate("v1.0.0", "[]");
    try success(&first);
    try std.testing.expectEqualStrings("prerelease=false\n", first.out());
    for ([_][*:0]const u8{ "v0.1.0", "v1.0.0-rc.1", "v1.0.0+build", "v1.0.1" }) |tag| {
        const result = try repo.validate(tag, "[]");
        try expectFailure(&result, "first published");
    }
    try repo.gitOk(&.{ "tag", "v1.0.0" });
    const existing = try repo.validate("v1.0.0", "[]");
    try expectFailure(&existing, "tag already exists");
    const draft = try repo.validate("v1.0.1", "[{\"tag_name\":\"v1.0.1\",\"draft\":true}]");
    try expectFailure(&draft, "release or draft");
}

test "release requires new contents and increasing precedence" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.gitOk(&.{ "tag", "v1.0.0" });
    const same = try repo.validate("v1.0.1", published);
    try expectFailure(&same, "No tracked changes");
    try repo.change("two", "change");
    const good = try repo.validate("v1.0.1", published);
    try success(&good);
    for ([_][*:0]const u8{ "v1.0.0+new", "v1.0.0-rc.1" }) |tag| {
        const result = try repo.validate(tag, published);
        try expectFailure(&result, "greater SemVer precedence");
    }
}

test "prereleases and highest release across pages" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.gitOk(&.{ "tag", "v1.0.0" });
    try repo.change("two", "change");
    try repo.gitOk(&.{ "tag", "v1.1.0-rc.1" });
    try repo.change("three", "another change");
    const pages = "[{\"tag_name\":\"v1.1.0-rc.1\",\"draft\":false}]\n[{\"tag_name\":\"v1.0.0\",\"draft\":false}]";
    const pre = try repo.validate("v1.1.0-rc.2", pages);
    try success(&pre);
    try std.testing.expectEqualStrings("prerelease=true\n", pre.out());
    const final = try repo.validate("v1.1.0", pages);
    try success(&final);
    try std.testing.expectEqualStrings("prerelease=false\n", final.out());
    const lower = try repo.validate("v1.0.9", pages);
    try expectFailure(&lower, "greater SemVer precedence");
}

test "missing invalid or ambiguous published history fails closed" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.change("two", "change");
    for ([_][]const u8{ published, "[{\"tag_name\":\"not-semver\",\"draft\":false}]", "[{\"tag_name\":\"v1.0.0\"}]", "[{}]" }) |pages| {
        const result = try repo.validate("v1.0.1", pages);
        try std.testing.expect(result.status != 0);
    }
    try repo.gitOk(&.{ "tag", "v1.0.0" });
    try repo.gitOk(&.{ "tag", "v1.0.0+other" });
    const result = try repo.validate("v1.0.1", "[{\"tag_name\":\"v1.0.0\",\"draft\":false},{\"tag_name\":\"v1.0.0+other\",\"draft\":false}]");
    try expectFailure(&result, "ambiguous");
}

test "unrelated release is rejected" {
    var repo = try Repo.init();
    defer repo.deinit();
    const tree = try repo.git(&.{ "rev-parse", "HEAD^{tree}" });
    try success(&tree);
    var tree_buf: [100]u8 = undefined;
    const tree_id = try std.fmt.bufPrintSentinel(&tree_buf, "{s}", .{std.mem.trim(u8, tree.out(), "\n\r")}, 0);
    const orphan = try repo.git(&.{ "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_id.ptr, "-m", "unrelated" });
    try success(&orphan);
    var orphan_buf: [100]u8 = undefined;
    const orphan_id = try std.fmt.bufPrintSentinel(&orphan_buf, "{s}", .{std.mem.trim(u8, orphan.out(), "\n\r")}, 0);
    try repo.gitOk(&.{ "tag", "v1.0.0", orphan_id.ptr });
    try repo.change("two", "change");
    const result = try repo.validate("v1.0.1", published);
    try expectFailure(&result, "not an ancestor");
}

test "reverted contents are not a new release" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.gitOk(&.{ "tag", "v1.0.0" });
    try repo.change("two", "change");
    try repo.change("one", "revert contents");
    const result = try repo.validate("v1.0.1", published);
    try expectFailure(&result, "No tracked changes");
}

test "malformed release responses fail closed" {
    var repo = try Repo.init();
    defer repo.deinit();
    for ([_][]const u8{
        "[] trailing",                             "[",                                                          "[{}", "[null]", "[true]", "{}", "[] null",
        "[{\"tag_name\":\"v1.0.0\",\"draft\":0}]", "[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"draft\":true}]",
    }) |pages| {
        const result = try repo.validate("v1.0.0", pages);
        try std.testing.expect(result.status != 0);
    }
}

test "very large prerelease numbers retain precedence" {
    var left: [5012]u8 = undefined;
    var right: [5013]u8 = undefined;
    @memcpy(left[0..7], "v1.0.0-");
    @memset(left[7..5007], '9');
    left[5007] = 0;
    @memcpy(right[0..8], "v1.0.0-1");
    @memset(right[8..5008], '0');
    right[5008] = 0;
    const result = try policy(&.{ "--compare", @ptrCast(&left), @ptrCast(&right) });
    try success(&result);
    try std.testing.expectEqualStrings("-1\n", result.out());
}

test "release history rejects named pipes without blocking" {
    const Native = struct {
        extern "c" fn mkfifo([*:0]const u8, c.mode_t) c_int;
    };
    var repo = try Repo.init();
    defer repo.deinit();
    var path_buf: [4200]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/releases.json", .{std.mem.sliceTo(&repo.path, 0)}, 0);
    if (Native.mkfifo(path.ptr, 0o600) != 0) return error.MkfifoFailed;
    const args = [_:null]?[*:0]const u8{ @ptrCast(&repo.script), "v1.0.0", "--releases", "releases.json", "--commit", "HEAD" };
    const result = try process.runWithOptions(&args, .{ .cwd = @ptrCast(&repo.path), .timeout_seconds = 3 });
    try std.testing.expect(result.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.err(), "UnsafeInputFile") != null);
}
