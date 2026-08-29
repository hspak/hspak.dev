//! Static site generator for hspak.dev.

const std = @import("std");
const Io = std.Io;
const Atom = @import("Atom.zig");
const Posts = @import("Posts.zig");
const partials = @import("partials.zig");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    try buildIndex(init.gpa, init.io);
}

fn buildIndex(gpa: std.mem.Allocator, io: Io) !void {
    const cwd = Io.Dir.cwd();
    const index_path = try Io.Dir.path.join(gpa, &.{ "docs", "index.html" });
    defer gpa.free(index_path);

    var posts = try Posts.init(gpa, io, "posts");
    defer posts.deinit(gpa);
    try posts.writePost(gpa, io);

    const feed_path = try Io.Dir.path.join(gpa, &.{ "docs", "feed.xml" });
    defer gpa.free(feed_path);
    var atom_feed = try Atom.init(gpa, io, feed_path);
    defer atom_feed.deinit(io);
    try atom_feed.generate(io, &posts);

    var index_file = try cwd.createFile(io, index_path, .{});
    defer index_file.close(io);
    log.info("creating main index: {s}", .{index_path});

    var buf: [4096]u8 = undefined;
    var writer = index_file.writer(io, &buf);
    try partials.writeHeader(&writer.interface, true, "Blog: Hong Shick Pak");
    try posts.writeIndex(&writer.interface);
    try partials.writeFooter(&writer.interface, true);
    try writer.interface.flush();
}

test {
    _ = @import("markdown.zig");
    _ = @import("Posts.zig");
    _ = @import("Atom.zig");
    _ = @import("time.zig");
    _ = @import("partials.zig");
}
