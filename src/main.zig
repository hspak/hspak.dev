const std = @import("std");
const fs = std.fs;
const io = std.io;
const Posts = @import("posts.zig").Posts;
const partials = @import("partials.zig");

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    try buildIndex(allocator);
}

fn buildIndex(allocator: *std.mem.Allocator) !void {
    const index_path = try fs.path.join(allocator, &[_][]const u8{ "docs", "index.html" });

    var posts = try Posts.init(allocator, "posts");
    defer posts.deinit();
    try posts.writePost();

    fs.cwd().deleteFile(index_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    _ = try fs.cwd().createFile(index_path, .{});
    var index_file = try fs.cwd().openFile(index_path, .{ .write = true });
    defer index_file.close();
    std.debug.warn("[ ] creating main index: {s}\n", .{index_path});

    try partials.writeHeader(index_file, true);
    try posts.writeIndex(index_file);
    try partials.writeFooter(index_file, true);
}
