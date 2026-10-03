//! Build the site generator, production server, and their tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Skip tests that do not match this filter",
    );

    const server_options = b.addOptions();
    const document_root = b.option([]const u8, "document-root", "Production document directory") orelse "docs";
    const acme_root = b.option([]const u8, "acme-root", "Enable HTTP-01 serving from this directory");
    const file_threads = b.option(usize, "file-threads", "File lane threads per transport worker") orelse 1;
    const file_queue = b.option(usize, "file-queue", "File lane waiting slots per transport worker") orelse 64;
    if (document_root.len == 0 or (acme_root != null and acme_root.?.len == 0))
        std.debug.panic("document-root and acme-root must not be empty", .{});
    if (file_threads == 0 or file_queue == 0)
        std.debug.panic("file-threads and file-queue must be positive", .{});
    server_options.addOption([]const u8, "document_root", document_root);
    server_options.addOption(?[]const u8, "acme_root", acme_root);
    server_options.addOption(usize, "file_threads", file_threads);
    server_options.addOption(usize, "file_queue", file_queue);

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
    const run_step = b.step("run", "Generate and serve the site, watching posts/ and docs/index.css");
    run_step.dependOn(&run_cmd.step);

    const zhtps = b.dependency("zhtps", .{
        .target = target,
        .optimize = optimize,
        .@"build-server" = false,
        .@"system-openssl" = b.option(bool, "system-openssl", "Link system OpenSSL") orelse false,
        .@"system-nghttp2" = b.option(bool, "system-nghttp2", "Link system libnghttp2") orelse false,
        .@"system-zstd" = b.option(bool, "system-zstd", "Link system libzstd") orelse false,
    }).module("zhtps");
    const server_module = b.createModule(.{
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zhtps", .module = zhtps }},
    });
    server_module.addOptions("server_options", server_options);
    const server = b.addExecutable(.{ .name = "zserve", .root_module = server_module });
    server.pie = true;
    const install_server = b.addInstallArtifact(server, .{});
    b.step("install-server", "Install the zhtps production server").dependOn(&install_server.step);
    const serve_cmd = b.addRunArtifact(server);
    if (b.args) |args| serve_cmd.addArgs(args);
    b.step("serve", "Serve generated docs/ with zstd compression").dependOn(&serve_cmd.step);

    const test_options = b.addOptions();
    test_options.addOptionPath("zmd_path", exe.getEmittedBin());
    test_options.addOptionPath("zserve_path", server.getEmittedBin());
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("magickwand", magickwand_module);
    test_module.addOptions("test_options", test_options);
    test_module.addOptions("server_options", server_options);
    const tests = b.addTest(.{
        .root_module = test_module,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
