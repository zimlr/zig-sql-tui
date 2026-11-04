const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFiles(.{
        .files = &.{ "vendor/sqlite/sqlite3.c", "src/sandbox.c", "src/live.c" },
        .flags = &.{
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_OMIT_RANDOMNESS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=0",
        },
    });
    const exe = b.addExecutable(.{ .name = "zig-sql-tui", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run.step);

    const test_module = b.createModule(.{
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addIncludePath(b.path("vendor/sqlite"));
    test_module.addCSourceFiles(.{
        .files = &.{ "vendor/sqlite/sqlite3.c", "src/sandbox.c", "src/live.c", "tests/security.c" },
        .flags = &.{
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_OMIT_RANDOMNESS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=0",
        },
    });
    const security_test = b.addExecutable(.{ .name = "security-test", .root_module = test_module });
    const run_security = b.addRunArtifact(security_test);
    const test_step = b.step("test", "Run security boundary tests");
    test_step.dependOn(&run_security.step);
}
