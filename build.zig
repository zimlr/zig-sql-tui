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
        .files = &.{ "vendor/sqlite/sqlite3.c", "src/sandbox.c", "src/live.c", "src/diagnostics.c" },
        .flags = &.{
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_OMIT_RANDOMNESS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=0",
        },
    });
    const exe = b.addExecutable(.{ .name = "zsqt", .root_module = module });
    exe.pie = true;
    b.installArtifact(exe);
    b.installFile("completions/zsqt.bash", "share/bash-completion/completions/zsqt");
    b.installFile("completions/_zsqt", "share/zsh/site-functions/_zsqt");
    b.installFile("completions/zsqt.fish", "share/fish/vendor_completions.d/zsqt.fish");

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
            "-Dfsync=app_test_fsync",
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_OMIT_RANDOMNESS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=0",
        },
    });
    const security_test = b.addExecutable(.{ .name = "security-test", .root_module = test_module });
    const run_security = b.addRunArtifact(security_test);
    const test_step = b.step("test", "Run Zig and security boundary tests");
    test_step.dependOn(&run_security.step);

    const prose_module = b.createModule(.{
        .root_source_file = b.path("tests/test_prose.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const prose_tests = b.addTest(.{ .root_module = prose_module });
    test_step.dependOn(&b.addRunArtifact(prose_tests).step);

    const release_policy_module = b.createModule(.{
        .root_source_file = b.path("tests/test_release_policy.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const release_policy_tests = b.addTest(.{ .root_module = release_policy_module });
    test_step.dependOn(&b.addRunArtifact(release_policy_tests).step);

    const completion_module = b.createModule(.{
        .root_source_file = b.path("tests/test_completion.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const completion_tests = b.addTest(.{ .root_module = completion_module });
    test_step.dependOn(&b.addRunArtifact(completion_tests).step);

    const diagnostics_module = b.createModule(.{
        .root_source_file = b.path("tests/test_diagnostics.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const diagnostics_tests = b.addTest(.{ .root_module = diagnostics_module });
    const run_diagnostics = b.addRunArtifact(diagnostics_tests);
    const termux_tool_module = b.createModule(.{
        .root_source_file = b.path("tools/check_termux_candidate.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    termux_tool_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const termux_tool = b.addExecutable(.{ .name = "check-termux-candidate", .root_module = termux_tool_module });
    const install_termux_tool = b.addInstallArtifact(termux_tool, .{ .dest_dir = .{ .override = .{ .custom = "tools" } } });
    const tools_step = b.step("tools", "Build project tools");
    tools_step.dependOn(&install_termux_tool.step);
    const test_termux_tool = b.addInstallArtifact(termux_tool, .{ .dest_dir = .{ .override = .{ .custom = "test-bin" } } });

    const termux_tool_test_module = b.createModule(.{
        .root_source_file = b.path("tests/test_termux_tool.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const termux_tool_tests = b.addTest(.{ .root_module = termux_tool_test_module });
    const run_termux_tool_tests = b.addRunArtifact(termux_tool_tests);
    run_termux_tool_tests.step.dependOn(&test_termux_tool.step);
    test_step.dependOn(&run_termux_tool_tests.step);

    const probe_module = b.createModule(.{
        .root_source_file = b.path("tests/test_termux_probe.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const probe_tests = b.addTest(.{ .root_module = probe_module });
    const run_probe = b.addRunArtifact(probe_tests);
    run_probe.step.dependOn(&test_termux_tool.step);
    test_step.dependOn(&run_probe.step);

    const test_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "test-bin" } } });
    run_termux_tool_tests.step.dependOn(&test_exe.step);
    run_diagnostics.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_diagnostics.step);
    const pointer_module = b.createModule(.{
        .root_source_file = b.path("tests/test_pointer_navigation.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    pointer_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const pointer_tests = b.addTest(.{ .root_module = pointer_module });
    const run_pointer = b.addRunArtifact(pointer_tests);
    run_pointer.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_pointer.step);

    const search_module = b.createModule(.{
        .root_source_file = b.path("tests/test_global_search.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    search_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const search_tests = b.addTest(.{ .root_module = search_module });
    const run_search = b.addRunArtifact(search_tests);
    run_search.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_search.step);

    const key_module = b.createModule(.{
        .root_source_file = b.path("tests/test_without_rowid.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    key_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const key_tests = b.addTest(.{ .root_module = key_module });
    const run_key = b.addRunArtifact(key_tests);
    run_key.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_key.step);

    const paging_module = b.createModule(.{
        .root_source_file = b.path("tests/test_paging.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    paging_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const paging_tests = b.addTest(.{ .root_module = paging_module });
    const run_paging = b.addRunArtifact(paging_tests);
    run_paging.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_paging.step);
    const live_audit_module = b.createModule(.{
        .root_source_file = b.path("tests/test_live_audit.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    live_audit_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const live_audit_tests = b.addTest(.{ .root_module = live_audit_module });
    const run_live_audit = b.addRunArtifact(live_audit_tests);
    run_live_audit.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_live_audit.step);

    const app_module = b.createModule(.{
        .root_source_file = b.path("tests/test_app.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    app_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const app_tests = b.addTest(.{ .root_module = app_module });
    const run_app = b.addRunArtifact(app_tests);
    run_app.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_app.step);

    const recovery_module = b.createModule(.{
        .root_source_file = b.path("tests/test_recovery.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    recovery_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const recovery_tests = b.addTest(.{ .root_module = recovery_module });
    const run_recovery = b.addRunArtifact(recovery_tests);
    run_recovery.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_recovery.step);

    const wal_write_module = b.createModule(.{
        .root_source_file = b.path("tests/test_wal_write.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    wal_write_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const wal_write_tests = b.addTest(.{ .root_module = wal_write_module });
    const run_wal_write = b.addRunArtifact(wal_write_tests);
    run_wal_write.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_wal_write.step);

    const termux_restrictions_module = b.createModule(.{
        .root_source_file = b.path("tests/test_termux_restrictions.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    termux_restrictions_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
    const termux_restrictions_tests = b.addTest(.{ .root_module = termux_restrictions_module });
    const run_termux_restrictions = b.addRunArtifact(termux_restrictions_tests);
    run_termux_restrictions.step.dependOn(&test_exe.step);
    test_step.dependOn(&run_termux_restrictions.step);

    // The syscall audit traces a static executable to avoid loader accesses.
    if (b.graph.host.result.os.tag == .linux and b.graph.host.result.cpu.arch == .x86_64) {
        const audit_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl });
        const audit_app = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = audit_target,
            .optimize = optimize,
            .link_libc = true,
        });
        audit_app.addIncludePath(b.path("vendor/sqlite"));
        audit_app.addCSourceFiles(.{
            .files = &.{ "vendor/sqlite/sqlite3.c", "src/sandbox.c", "src/live.c", "src/diagnostics.c" },
            .flags = &.{
                "-DSQLITE_TEMP_STORE=3",
                "-DSQLITE_OMIT_RANDOMNESS=1",
                "-DSQLITE_OMIT_LOAD_EXTENSION=1",
                "-DSQLITE_DQS=0",
                "-DSQLITE_THREADSAFE=0",
            },
        });
        const audit_exe = b.addExecutable(.{ .name = "zsqt-audit", .root_module = audit_app });
        audit_exe.pie = true;
        const syscall_module = b.createModule(.{
            .root_source_file = b.path("tests/test_syscalls.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .link_libc = true,
        });
        syscall_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{} });
        const syscall_tests = b.addTest(.{ .root_module = syscall_module });
        const run_syscalls = b.addSystemCommand(&.{"env"});
        run_syscalls.addPrefixedFileArg("ZSQT_AUDIT_EXE=", audit_exe.getEmittedBin());
        run_syscalls.addFileArg(syscall_tests.getEmittedBin());
        test_step.dependOn(&run_syscalls.step);
    }
}
