const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const exe = b.addExecutable(.{
        .name = "zmd",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const koino_pkg = b.dependency("koino", .{ .optimize = optimize, .target = target });
    exe.root_module.addImport("koino", koino_pkg.module("koino"));

    b.installArtifact(exe);
}
