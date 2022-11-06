const std = @import("std");
const builtin = @import("builtin");
const Pkg = std.build.Pkg;
const string = []const u8;

pub const cache = ".zigmod/deps";

pub fn addAllTo(exe: *std.build.LibExeObjStep) void {
    checkMinZig(builtin.zig_version, exe);
    @setEvalBranchQuota(1_000_000);
    for (packages) |pkg| {
        exe.addPackage(pkg.pkg.?);
    }
    var llc = false;
    var vcpkg = false;
    inline for (comptime std.meta.declarations(package_data)) |decl| {
        const pkg = @as(Package, @field(package_data, decl.name));
        for (pkg.system_libs) |item| {
            exe.linkSystemLibrary(item);
            llc = true;
        }
        for (pkg.frameworks) |item| {
            if (!std.Target.current.isDarwin()) @panic(exe.builder.fmt("a dependency is attempting to link to the framework {s}, which is only possible under Darwin", .{item}));
            exe.linkFramework(item);
            llc = true;
        }
        inline for (pkg.c_include_dirs) |item| {
            exe.addIncludeDir(@field(dirs, decl.name) ++ "/" ++ item);
            llc = true;
        }
        inline for (pkg.c_source_files) |item| {
            exe.addCSourceFile(@field(dirs, decl.name) ++ "/" ++ item, pkg.c_source_flags);
            llc = true;
        }
        vcpkg = vcpkg or pkg.vcpkg;
    }
    if (llc) exe.linkLibC();
    if (builtin.os.tag == .windows and vcpkg) exe.addVcpkgPaths(.static) catch |err| @panic(@errorName(err));
}

pub const Package = struct {
    directory: string,
    pkg: ?Pkg = null,
    c_include_dirs: []const string = &.{},
    c_source_files: []const string = &.{},
    c_source_flags: []const string = &.{},
    system_libs: []const string = &.{},
    frameworks: []const string = &.{},
    vcpkg: bool = false,
};

fn checkMinZig(current: std.SemanticVersion, exe: *std.build.LibExeObjStep) void {
    const min = std.SemanticVersion.parse("null") catch return;
    if (current.order(min).compare(.lt)) @panic(exe.builder.fmt("Your Zig version v{} does not meet the minimum build requirement of v{}", .{current, min}));
}

pub const dirs = struct {
    pub const _root = "";
    pub const _qqo54zxu6pnz = cache ++ "/../..";
    pub const _mr0i9fhju8jh = cache ++ "/git/github.com/kivikakk/htmlentities.zig";
    pub const _qoedvk82xtp0 = cache ++ "/git/github.com/kivikakk/libpcre.zig";
    pub const _8z7q0m81vvex = cache ++ "/git/github.com/nektro/pcre-8.45";
    pub const _bzqgr4iuk0o2 = cache ++ "/git/github.com/kivikakk/zunicode";
    pub const _aoe2l16htlue = cache ++ "/git/github.com/Hejsil/zig-clap";
};

pub const package_data = struct {
    pub const _mr0i9fhju8jh = Package{
        .directory = dirs._mr0i9fhju8jh,
        .pkg = Pkg{ .name = "htmlentities", .path = .{ .path = dirs._mr0i9fhju8jh ++ "/src/main.zig" }, .dependencies = null },
    };
    pub const _qoedvk82xtp0 = Package{
        .directory = dirs._qoedvk82xtp0,
        .pkg = Pkg{ .name = "libpcre", .path = .{ .path = dirs._qoedvk82xtp0 ++ "/src/main.zig" }, .dependencies = null },
    };
    pub const _8z7q0m81vvex = Package{
        .directory = dirs._8z7q0m81vvex,
        .c_include_dirs = &.{ "" },
        .c_source_files = &.{ "pcre_byte_order.c", "pcre_chartables.c", "pcre_compile.c", "pcre_config.c", "pcre_dfa_exec.c", "pcre_exec.c", "pcre_fullinfo.c", "pcre_get.c", "pcre_globals.c", "pcre_jit_compile.c", "pcre_maketables.c", "pcre_newline.c", "pcre_ord2utf8.c", "pcreposix.c", "pcre_printint.c", "pcre_refcount.c", "pcre_string_utils.c", "pcre_study.c", "pcre_tables.c", "pcre_ucd.c", "pcre_valid_utf8.c", "pcre_version.c", "pcre_xclass.c" },
        .c_source_flags = &.{ "-Wno-implicit-function-declaration", "-DHAVE_CONFIG_H" },
    };
    pub const _bzqgr4iuk0o2 = Package{
        .directory = dirs._bzqgr4iuk0o2,
        .pkg = Pkg{ .name = "zunicode", .path = .{ .path = dirs._bzqgr4iuk0o2 ++ "/src/zunicode.zig" }, .dependencies = null },
    };
    pub const _qqo54zxu6pnz = Package{
        .directory = dirs._qqo54zxu6pnz,
        .pkg = Pkg{ .name = "koino", .path = .{ .path = dirs._qqo54zxu6pnz ++ "/src/koino.zig" }, .dependencies = &.{ _mr0i9fhju8jh.pkg.?, _qoedvk82xtp0.pkg.?, _bzqgr4iuk0o2.pkg.? } },
    };
    pub const _aoe2l16htlue = Package{
        .directory = dirs._aoe2l16htlue,
        .pkg = Pkg{ .name = "clap", .path = .{ .path = dirs._aoe2l16htlue ++ "/clap.zig" }, .dependencies = null },
    };
    pub const _root = Package{
        .directory = dirs._root,
    };
};

pub const packages = &[_]Package{
    package_data._qqo54zxu6pnz,
    package_data._aoe2l16htlue,
};

pub const pkgs = struct {
    pub const koino = package_data._qqo54zxu6pnz;
    pub const clap = package_data._aoe2l16htlue;
};

pub const imports = struct {
};
