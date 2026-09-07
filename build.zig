//! Build the zmd static site generator and its tests.

const std = @import("std");

const log = std.log.scoped(.build);

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Skip tests that do not match this filter",
    );

    const magickwand = b.addTranslateC(.{
        .root_source_file = b.path("src/magickwand.h"),
        .target = target,
        .optimize = optimize,
    });
    magickwand.linkSystemLibrary("MagickWand", .{ .use_pkg_config = .force });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const magickwand_module = magickwand.createModule();
    root_module.addImport("magickwand", magickwand_module);

    const exe = b.addExecutable(.{
        .name = "zmd",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Generate and serve the site, watching posts/ for changes");
    run_step.dependOn(&run_cmd.step);

    const test_options = b.addOptions();
    test_options.addOptionPath("zmd_path", exe.getEmittedBin());
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("magickwand", magickwand_module);
    test_module.addOptions("test_options", test_options);
    const tests = b.addTest(.{
        .root_module = test_module,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
