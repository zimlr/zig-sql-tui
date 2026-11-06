const std = @import("std");
const c = std.c;
const process = @import("process_support.zig");
const support = @import("terminal_support.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;

fn run(args: []const [*:0]const u8) !process.Result {
    var argv: [20:null]?[*:0]const u8 = @splat(null);
    if (args.len > 19) return error.TooManyArguments;
    for (args, 0..) |arg, i| argv[i] = arg;
    return process.runWithOptions(&argv, .{ .timeout_seconds = 60 });
}
fn success(result: *const process.Result) !void {
    if (result.status != 0) std.debug.print("Command failed: {s}\n{s}\n", .{ result.out(), result.err() });
    try std.testing.expectEqual(@as(c_int, 0), result.status);
}
fn path(buf: []u8, dir: []const u8, suffix: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, suffix }, 0);
}
fn makeFile(name: [*:0]const u8, data: []const u8, mode: c.mode_t) !void {
    const fd = c.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, mode);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.write(fd, data.ptr, data.len) != data.len) return error.WriteFailed;
}

test "Debian package installation, payload and input rejection" {
    const binary = c.getenv("ZSQT_DEB_BINARY") orelse return error.MissingTestBinary;
    var directory: [256]u8 = @splat(0);
    const template = ".zig-cache/tmp/deb-test-XXXXXX";
    @memcpy(directory[0..template.len], template);
    if (mkdtemp(@ptrCast(&directory)) == null) return error.MkdtempFailed;
    defer {
        const args = [_:null]?[*:0]const u8{ "rm", "-rf", "--", @ptrCast(&directory) };
        _ = process.run(&args, null) catch {};
    }
    const dir = std.mem.sliceTo(&directory, 0);
    var pbuf: [512]u8 = undefined;
    const package = try path(&pbuf, dir, "candidate.deb");
    var p2buf: [512]u8 = undefined;
    const package2 = try path(&p2buf, dir, "repeat.deb");
    var r = try run(&.{ "bash", "tools/package_deb.sh", "v2.3.4-rc.1+build", "amd64", binary, package.ptr });
    try success(&r);
    r = try run(&.{ "bash", "tools/package_deb.sh", "v2.3.4-rc.1+build", "amd64", binary, package2.ptr });
    try success(&r);
    r = try run(&.{ "cmp", package.ptr, package2.ptr });
    try success(&r);
    r = try run(&.{ "dpkg-deb", "--field", package.ptr, "Architecture" });
    try success(&r);
    try std.testing.expectEqualStrings("amd64\n", r.out());
    r = try run(&.{ "dpkg-deb", "--field", package.ptr, "X-Zsqt-Release" });
    try success(&r);
    try std.testing.expectEqualStrings("v2.3.4-rc.1+build\n", r.out());
    r = try run(&.{ "dpkg-deb", "--contents", package.ptr });
    try success(&r);
    try std.testing.expect(std.mem.startsWith(u8, r.out(), "drwxr-xr-x root/root"));
    for ([_][]const u8{ "drwxr-xr-x root/root", "./usr/bin/zsqt", "./usr/share/bash-completion/completions/zsqt", "./usr/share/zsh/site-functions/_zsqt", "./usr/share/fish/vendor_completions.d/zsqt.fish", "./usr/share/doc/zsqt/SQLITE-LICENSE.md" }) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, r.out(), entry) != null);
    }
    var ctrlbuf: [512]u8 = undefined;
    const control = try path(&ctrlbuf, dir, "control");
    r = try run(&.{ "dpkg-deb", "--control", package.ptr, control.ptr });
    try success(&r);
    for ([_][]const u8{ "preinst", "postinst", "prerm", "postrm", "triggers" }) |name| {
        var namebuf: [600]u8 = undefined;
        const script = try path(&namebuf, control, name);
        try std.testing.expect(c.access(script.ptr, 0) != 0);
    }
    // Invalid inputs must fail before creating a package or following a link.
    var badbuf: [512]u8 = undefined;
    const bad = try path(&badbuf, dir, "bad.deb");
    for ([_][2][*:0]const u8{
        .{ "v2.3.4\nDepends: injected", "amd64" },
        .{ "v2.3.4", "arm64" },
        .{ "v2.3.4", "../../escape" },
    }) |pair| {
        r = try run(&.{ "bash", "tools/package_deb.sh", pair[0], pair[1], binary, bad.ptr });
        try std.testing.expect(r.status != 0);
        try std.testing.expect(c.access(bad.ptr, 0) != 0);
    }
    r = try run(&.{ "bash", "tools/package_deb.sh", "v2.3.4", "amd64", binary, package.ptr });
    try std.testing.expect(r.status != 0);
    var linkbuf: [512]u8 = undefined;
    const link = try path(&linkbuf, dir, "link");
    var binary_cwd: [4096]u8 = undefined;
    const binary_dir = c.getcwd(&binary_cwd, binary_cwd.len) orelse return error.GetCwdFailed;
    var absolute_binary: [5000]u8 = undefined;
    const source = if (binary[0] == '/') std.mem.span(binary) else try std.fmt.bufPrint(&absolute_binary, "{s}/{s}", .{ std.mem.sliceTo(binary_dir, 0), std.mem.span(binary) });
    var source_zbuf: [5001]u8 = undefined;
    const source_z = try std.fmt.bufPrintSentinel(&source_zbuf, "{s}", .{source}, 0);
    if (c.symlink(source_z.ptr, link.ptr) != 0) return error.SymlinkFailed;
    try std.testing.expect(c.access(link.ptr, 0) == 0);
    r = try run(&.{ "bash", "tools/package_deb.sh", "v2.3.4", "amd64", link.ptr, bad.ptr });
    try std.testing.expect(r.status != 0);
    var outlinkbuf: [512]u8 = undefined;
    const outlink = try path(&outlinkbuf, dir, "output-link.deb");
    if (c.symlink("candidate.deb", outlink.ptr) != 0) return error.SymlinkFailed;
    r = try run(&.{ "bash", "tools/package_deb.sh", "v2.3.4", "amd64", binary, outlink.ptr });
    try std.testing.expect(r.status != 0);
    r = try run(&.{ "dpkg-deb", "--field", package.ptr, "Architecture" });
    try success(&r);
    try std.testing.expectEqualStrings("amd64\n", r.out());

    // Use a private dpkg database and failing helper stubs. No system install occurs.
    var rootbuf: [512]u8 = undefined;
    const root = try path(&rootbuf, dir, "root");
    var adminbuf: [512]u8 = undefined;
    const admin = try path(&adminbuf, dir, "root/var/lib/dpkg");
    var stubdirbuf: [512]u8 = undefined;
    const stubdir = try path(&stubdirbuf, dir, "bin");
    r = try run(&.{ "mkdir", "-p", admin.ptr, stubdir.ptr });
    try success(&r);
    var statusbuf: [512]u8 = undefined;
    const status = try path(&statusbuf, dir, "root/var/lib/dpkg/status");
    try makeFile(status.ptr, "", 0o600);
    for ([_][]const u8{ "ldconfig", "start-stop-daemon" }) |name| {
        var stubbuf: [512]u8 = undefined;
        const stub = try path(&stubbuf, stubdir, name);
        try makeFile(stub.ptr, "#!/bin/sh\nexit 99\n", 0o700);
    }
    var cwd_buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const current = std.mem.sliceTo(cwd, 0);
    var envbuf: [8192]u8 = undefined;
    const env = try std.fmt.bufPrintSentinel(&envbuf, "PATH={s}/{s}:{s}", .{ current, stubdir, std.mem.span(c.getenv("PATH") orelse "") }, 0);
    var rootargbuf: [5000]u8 = undefined;
    const rootarg = try std.fmt.bufPrintSentinel(&rootargbuf, "--root={s}/{s}", .{ current, root }, 0);
    var logargbuf: [5000]u8 = undefined;
    const logarg = try std.fmt.bufPrintSentinel(&logargbuf, "--log={s}/{s}/dpkg.log", .{ current, dir }, 0);
    r = try run(&.{ "env", env.ptr, "dpkg", rootarg.ptr, logarg.ptr, "--force-not-root", "--install", package.ptr });
    try success(&r);
    var exebuf: [520]u8 = undefined;
    const installed = try path(&exebuf, root, "usr/bin/zsqt");
    r = try run(&.{ "cmp", binary, installed.ptr });
    try success(&r);
    var db = try support.Fixture.init("CREATE TABLE data(value TEXT); INSERT INTO data VALUES ('installed')");
    defer db.deinit();
    if (setenv("ZSQT_TEST_EXE", installed.ptr, 1) != 0) return error.SetenvFailed;
    defer _ = unsetenv("ZSQT_TEST_EXE");
    const t = try support.Terminal.init(@ptrCast(&db.path));
    defer t.deinit();
    try t.send("\t", "[RO] NORMAL | ROWS");
    try t.send("/installed\r", "Match found");
    try t.send("iINSERT INTO data VALUES ('bad')\r", "read-only");
    try t.quit();
    try db.expectValue("SELECT count(*) FROM data", "1");
    r = try run(&.{ "env", env.ptr, "dpkg", rootarg.ptr, logarg.ptr, "--force-not-root", "--remove", "zsqt" });
    try success(&r);
    try std.testing.expect(c.access(installed.ptr, 0) != 0);
}

test "release draft requires exact uploaded assets and digests" {
    var directory: [256]u8 = @splat(0);
    const template = ".zig-cache/tmp/draft-test-XXXXXX";
    @memcpy(directory[0..template.len], template);
    if (mkdtemp(@ptrCast(&directory)) == null) return error.MkdtempFailed;
    defer {
        const args = [_:null]?[*:0]const u8{ "rm", "-rf", "--", @ptrCast(&directory) };
        _ = process.run(&args, null) catch {};
    }
    const dir = std.mem.sliceTo(&directory, 0);
    const tag = "v2.3.4";
    const files = [_][]const u8{ "zsqt-v2.3.4-x86_64-linux-musl.tar.gz", "zsqt-v2.3.4-aarch64-linux-musl.tar.gz", "zsqt-v2.3.4-amd64.deb", "zsqt-v2.3.4-arm64.deb", "zsqt-v2.3.4-aarch64-termux.deb" };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(std.testing.allocator);
    for (files) |name| {
        var buf: [512]u8 = undefined;
        const file = try path(&buf, dir, name);
        try makeFile(file.ptr, "fixture", 0o600);
        const line = try std.fmt.allocPrint(std.testing.allocator, "{s}  {s}\n", .{ hex, name });
        defer std.testing.allocator.free(line);
        try manifest.appendSlice(std.testing.allocator, line);
    }
    var manifest_buf: [512]u8 = undefined;
    const manifest_path = try path(&manifest_buf, dir, "SHA256SUMS");
    try makeFile(manifest_path.ptr, manifest.items, 0o600);
    std.crypto.hash.sha2.Sha256.hash(manifest.items, &digest, .{});
    const manifest_hex = std.fmt.bytesToHex(digest, .lower);
    const draft = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"draft":true,"tag_name":"{s}","assets":[
        \\{{"name":"{s}","state":"uploaded","digest":"sha256:{s}"}},
        \\{{"name":"{s}","state":"uploaded","digest":"sha256:{s}"}},
        \\{{"name":"{s}","state":"uploaded","digest":"sha256:{s}"}},
        \\{{"name":"{s}","state":"uploaded","digest":"sha256:{s}"}},
        \\{{"name":"{s}","state":"uploaded","digest":"sha256:{s}"}},
        \\{{"name":"SHA256SUMS","state":"uploaded","digest":"sha256:{s}"}}]}}
    , .{ tag, files[0], hex, files[1], hex, files[2], hex, files[3], hex, files[4], hex, manifest_hex });
    defer std.testing.allocator.free(draft);
    var json_buf: [512]u8 = undefined;
    const json = try path(&json_buf, dir, "draft.json");
    try makeFile(json.ptr, draft, 0o600);
    var r = try run(&.{ "bash", "tools/verify_release_draft.sh", tag, @ptrCast(&directory), json.ptr });
    try success(&r);
    var altered_buf: [512]u8 = undefined;
    const altered = try path(&altered_buf, dir, "altered.json");
    var mutated = try std.testing.allocator.dupe(u8, draft);
    defer std.testing.allocator.free(mutated);
    const uploaded = std.mem.indexOf(u8, mutated, "uploaded") orelse return error.MissingField;
    @memcpy(mutated[uploaded..][0..8], "modified");
    try makeFile(altered.ptr, mutated, 0o600);
    r = try run(&.{ "bash", "tools/verify_release_draft.sh", tag, @ptrCast(&directory), altered.ptr });
    try std.testing.expect(r.status != 0);
    @memcpy(mutated, draft);
    const published = std.mem.indexOf(u8, mutated, "true") orelse return error.MissingField;
    @memcpy(mutated[published..][0..4], "null");
    var pub_buf: [512]u8 = undefined;
    const pub_json = try path(&pub_buf, dir, "published.json");
    try makeFile(pub_json.ptr, mutated, 0o600);
    r = try run(&.{ "bash", "tools/verify_release_draft.sh", tag, @ptrCast(&directory), pub_json.ptr });
    try std.testing.expect(r.status != 0);
    r = try run(&.{ "bash", "tools/verify_release_draft.sh", "v2.3.5", @ptrCast(&directory), json.ptr });
    try std.testing.expect(r.status != 0);
    r = try run(&.{ "bash", "tools/verify_release_draft.sh", "v2.3.4/../../escape", @ptrCast(&directory), json.ptr });
    try std.testing.expect(r.status != 0);
    var file_buf: [512]u8 = undefined;
    const victim = try path(&file_buf, dir, files[0]);
    if (c.unlink(victim.ptr) != 0) return error.UnlinkFailed;
    try makeFile(victim.ptr, "tampered", 0o600);
    r = try run(&.{ "bash", "tools/verify_release_draft.sh", tag, @ptrCast(&directory), json.ptr });
    try std.testing.expect(r.status != 0);
    if (c.unlink(victim.ptr) != 0) return error.UnlinkFailed;
    if (c.symlink("SHA256SUMS", victim.ptr) != 0) return error.SymlinkFailed;
    r = try run(&.{ "bash", "tools/verify_release_draft.sh", tag, @ptrCast(&directory), json.ptr });
    try std.testing.expect(r.status != 0);
}
