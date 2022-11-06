const std = @import("std");
const Builder = std.build.Builder;

const linkPcre = @import("vendor/koino/vendor/libpcre/build.zig").linkPcre;

const pkgs = struct {
    const koino = std.build.Pkg{
        .name = "koino",
        .source = std.build.FileSource{ .path = "vendor/koino/src/koino.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{ .name = "libpcre", .source = std.build.FileSource{ .path = "vendor/koino/vendor/libpcre/src/main.zig" } },
            std.build.Pkg{ .name = "htmlentities", .source = std.build.FileSource{ .path = "vendor/koino/vendor/htmlentities/src/main.zig" } },
            std.build.Pkg{ .name = "clap", .source = std.build.FileSource{ .path = "vendor/koino/vendor/zig-clap/clap.zig" } },
            std.build.Pkg{ .name = "zunicode", .source = std.build.FileSource{ .path = "vendor/koino/vendor/zunicode/src/zunicode.zig" } },
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
