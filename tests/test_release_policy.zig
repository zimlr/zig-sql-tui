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

fn python(code: [*:0]const u8, arguments: []const [*:0]const u8) !process.Result {
    var tools_buf: [4096]u8 = undefined;
    const tools = try rootPath(&tools_buf, "tools");
    var argv: [32:null]?[*:0]const u8 = @splat(null);
    argv[0] = "python3";
    argv[1] = "-c";
    argv[2] = code;
    argv[3] = tools.ptr;
    if (arguments.len > 28) return error.TooManyArguments;
    for (arguments, 0..) |arg, i| argv[i + 4] = arg;
    return process.run(&argv, null);
}

const parse_code = "import sys; sys.path.insert(0,sys.argv[1]); import release_policy as p; p.parse_version(sys.argv[2]); print('valid')";
const compare_code = "import sys; sys.path.insert(0,sys.argv[1]); import release_policy as p; print(p.compare(p.parse_version(sys.argv[2]),p.parse_version(sys.argv[3])))";

test "SemVer precedence and metadata" {
    const tags = [_][*:0]const u8{ "v1.0.0-alpha", "v1.0.0-alpha.1", "v1.0.0-alpha.beta", "v1.0.0-beta", "v1.0.0-beta.2", "v1.0.0-beta.11", "v1.0.0-rc.1", "v1.0.0", "v1.0.1", "v1.1.0", "v2.0.0" };
    for (tags[0 .. tags.len - 1], tags[1..]) |left, right| {
        const result = try python(compare_code, &.{ left, right });
        try success(&result);
        try std.testing.expectEqualStrings("-1\n", result.out());
    }
    for ([_][2][*:0]const u8{ .{ "v1.2.3+abc", "v1.2.3+42" }, .{ "v1.2.3-alpha+0", "v1.2.3-alpha" } }) |pair| {
        const result = try python(compare_code, &pair);
        try success(&result);
        try std.testing.expectEqualStrings("0\n", result.out());
    }
}

test "invalid and valid SemVer tags" {
    for ([_][*:0]const u8{ "1.0.0", "v01.0.0", "v1.01.0", "v1.0.01", "v1.0", "v1.0.0-01", "v1.0.0-alpha..1", "v1.0.0+", "v1.0.0-", "v1.0.0\n", "v1.0.0-α" }) |tag| {
        const result = try python(parse_code, &.{tag});
        try expectFailure(&result, "ValueError");
    }
    for ([_][*:0]const u8{ "v0.0.0", "v1.0.0-0", "v1.0.0-01a", "v1.0.0+001", "v1.0.0--" }) |tag| {
        const result = try python(parse_code, &.{tag});
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
    const result = try python(compare_code, &.{ @ptrCast(&left), @ptrCast(&right) });
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
        _ = try rootPath(&self.script, "tools/release_policy.py");
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
        return run(&.{ "python3", @ptrCast(&self.script), tag, "--releases", "releases.json", "--commit", "HEAD" }, @ptrCast(&self.path));
    }
};

const published = "[{\"tag_name\":\"v1.0.0\",\"draft\":false}]";

test "paginated release API input" {
    var repo = try Repo.init();
    defer repo.deinit();
    const read_code = "import sys,json,pathlib; sys.path.insert(0,sys.argv[1]); import release_policy as p; print(json.dumps(p.read_pages(pathlib.Path(sys.argv[2])),separators=(',',':')))";
    var response_buf: [4200]u8 = undefined;
    const response = try std.fmt.bufPrintSentinel(&response_buf, "{s}/releases.json", .{std.mem.sliceTo(&repo.path, 0)}, 0);
    try repo.write("releases.json", "[{\"tag_name\":\"v1.0.0\",\"draft\":false}]\n[]\n");
    const good = try python(read_code, &.{response.ptr});
    try success(&good);
    try std.testing.expectEqualStrings("[[{\"tag_name\":\"v1.0.0\",\"draft\":false}],[]]\n", good.out());
    try repo.write("releases.json", "");
    const empty = try python(read_code, &.{response.ptr});
    try expectFailure(&empty, "empty");
    try repo.write("releases.json", "[]\n{");
    const malformed = try python(read_code, &.{response.ptr});
    try expectFailure(&malformed, "JSONDecodeError");
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
