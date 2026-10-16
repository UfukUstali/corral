const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Ghostty's terminal emulator, as a Zig module. Not lazy: corral is
    // useless without it, so paying the fetch up front beats the two-pass
    // "run zig build again" dance.
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"));

    const exe = b.addExecutable(.{
        .name = "corral",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("skills/corral"),
        .install_dir = .prefix,
        .install_subdir = "share/corral/skills/corral",
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run corral");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const integration = b.addSystemCommand(&.{"python3"});
    integration.addFileArg(b.path("tests/agent_cli.py"));
    integration.addArtifactArg(exe);
    const integration_step = b.step("integration-test", "Test agent commands against a real TUI (needs Python 3)");
    integration_step.dependOn(&integration.step);
}
