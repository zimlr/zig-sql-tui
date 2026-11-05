const std = @import("std");
const c = std.c;
extern "c" fn _exit(c_int) noreturn;

pub fn write(fd: c_int, text: []const u8) void {
    var offset: usize = 0;
    while (offset < text.len) {
        const n = c.write(fd, text[offset..].ptr, text.len - offset);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) _exit(1);
        offset += @intCast(n);
    }
}

pub fn readFile(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = c.open(path, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    return readRegularFd(allocator, fd);
}

pub fn readMarkdown(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = c.open(path, .{ .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true });
    if (fd < 0) return error.UnsafeMarkdownFile;
    defer _ = c.close(fd);
    return readRegularFd(allocator, fd);
}

fn readRegularFd(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var info: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true }, &info);
    if (rc != 0 or !info.mask.TYPE or info.mode & std.os.linux.S.IFMT != std.os.linux.S.IFREG) return error.UnsafeInputFile;
    return readFromFd(allocator, fd);
}

fn readFromFd(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        // Fail closed instead of accepting a truncated release history or document.
        if (bytes.items.len + @as(usize, @intCast(n)) > 64 * 1024 * 1024) return error.FileTooLarge;
        try bytes.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return bytes.toOwnedSlice(allocator);
}
