const std = @import("std");
const Builder = std.build.Builder;

const linkPcre = @import("vendor/koino/vendor/libpcre.zig/build.zig").linkPcre;

const pkgs = struct {
    const koino = std.build.Pkg{
        .name = "koino",
        .path = std.build.FileSource{ .path = "vendor/koino/src/koino.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{ .name = "libpcre", .path = std.build.FileSource{ .path = "vendor/koino/vendor/libpcre.zig/src/main.zig" } },
            std.build.Pkg{ .name = "htmlentities", .path = std.build.FileSource{ .path = "vendor/koino/vendor/htmlentities.zig/src/main.zig" } },
            std.build.Pkg{ .name = "clap", .path = std.build.FileSource{ .path = "vendor/koino/vendor/zig-clap/clap.zig" } },
            std.build.Pkg{ .name = "zunicode", .path = std.build.FileSource{ .path = "vendor/koino/vendor/zunicode/src/zunicode.zig" } },
        },
    };
};

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zmd", "src/main.zig");

    exe.addPackage(pkgs.koino);
    try linkPcre(exe);

    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
