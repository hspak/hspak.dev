//! Atom feed written from a `Posts` list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Posts = @import("Posts.zig");
const time = @import("time.zig");

const Atom = @This();

feed: Writer.Allocating,
output_file: Io.File,

pub const InitError = Io.File.OpenError;
pub const GenerateError = Allocator.Error || Io.File.Writer.Error;

/// Initialize fresh storage, creating `output_path` and preparing an empty feed.
/// Pair success with `deinit(io)`. On error, no resources are retained.
pub fn init(atom: *Atom, gpa: Allocator, io: Io, output_path: []const u8) InitError!void {
    const file = try Io.Dir.cwd().createFile(io, output_path, .{});
    errdefer file.close(io);
    atom.* = .{
        .feed = .init(gpa),
        .output_file = file,
    };
}

/// Close the feed file and free the buffer. Does not free `atom` itself.
pub fn deinit(atom: *Atom, io: Io) void {
    atom.feed.deinit();
    atom.output_file.close(io);
    atom.* = undefined;
}

/// Write the Atom XML for `posts` to the file opened in `init`.
pub fn generate(atom: *Atom, io: Io, posts: *const Posts) GenerateError!void {
    // These helpers write only to the allocating buffer, whose write failures mean OOM.
    atom.header(io, posts) catch return error.OutOfMemory;
    atom.addEntries(posts) catch return error.OutOfMemory;
    atom.footer() catch return error.OutOfMemory;
    try atom.output_file.writeStreamingAll(io, atom.feed.writer.buffered());
}

fn header(atom: *Atom, io: Io, posts: *const Posts) !void {
    const w = &atom.feed.writer;
    const timestamp = posts.latestUpdatedAt() orelse Io.Clock.real.now(io);
    const formatted_timestamp = try time.formatTimestamp(atom.feed.allocator, timestamp);
    defer atom.feed.allocator.free(formatted_timestamp);
    try w.print(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Hong's Blog</title>
        \\<link href="https://hspak.dev/"/>
        \\<updated>{s}</updated>
        \\<author>
        \\  <name>Hong Shick Pak</name>
        \\</author>
        \\<id>https://hspak.dev/atom.xml</id>
    , .{formatted_timestamp});
}

fn addEntries(atom: *Atom, posts: *const Posts) !void {
    const w = &atom.feed.writer;
    for (posts.list.items) |item| {
        if (item.meta.draft) continue;

        try w.writeAll("<entry>\n");
        try w.print("  <title>{s}</title>\n", .{item.meta.title});
        try w.print("  <published>{s}</published>\n", .{item.meta.created_at});
        if (!std.mem.eql(u8, item.meta.updated_at, Posts.Post.placeholder_text)) {
            try w.print("  <updated>{s}</updated>\n", .{item.meta.updated_at});
        } else {
            try w.print("  <updated>{s}</updated>\n", .{item.meta.created_at});
        }
        try w.print(
            \\  <link href="https://hspak.dev/post/{s}/" type="text/html"/>
        , .{item.meta.name});
        try w.print("\n  <id>https://hspak.dev/post/{s}/</id>\n", .{item.meta.name});
        try w.writeAll("  <content type=\"html\">\n    ");
        try writeContent(w, item.parsed_html, item.meta.name);
        try w.writeAll("  </content>");
        try w.writeAll("\n</entry>\n");
    }
}

fn footer(atom: *Atom) !void {
    try atom.feed.writer.writeAll("</feed>\n");
}

fn writeContent(w: *Writer, html_body: []const u8, post_name: []const u8) Writer.Error!void {
    var rest = html_body;
    // Generated HTML uses double-quoted attributes; quoted text is already HTML-escaped.
    // Feed readers need the published page URL to resolve fragment navigation.
    const prefix = "href=\"#";
    while (std.mem.indexOf(u8, rest, prefix)) |index| {
        const fragment = index + prefix.len - 1;
        try writeXmlEscaped(w, rest[0..fragment]);
        try w.writeAll("https://hspak.dev/post/");
        try writeXmlEscaped(w, post_name);
        try w.writeByte('/');
        rest = rest[fragment..];
    }
    try writeXmlEscaped(w, rest);
}

fn writeXmlEscaped(w: *Writer, html_body: []const u8) Writer.Error!void {
    for (html_body) |char| {
        switch (char) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '&' => try w.writeAll("&amp;"),
            else => try w.writeByte(char),
        }
    }
}

test "feed fragment links target the post while escaped code stays literal" {
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeContent(
        &output.writer,
        "<a href=\"#fn-post-42-1\">1</a> <a href=\"#fnref-post-42-1-1\">↩</a> " ++
            "<a href=\"#section\">Section</a> <a href=\"https://example.com/#part\">Other</a> " ++
            "<code>href=&quot;#literal&quot;</code>",
        "example",
    );
    try std.testing.expectEqualStrings(
        "&lt;a href=&quot;https://hspak.dev/post/example/#fn-post-42-1&quot;&gt;1&lt;/a&gt; " ++
            "&lt;a href=&quot;https://hspak.dev/post/example/#fnref-post-42-1-1&quot;&gt;↩&lt;/a&gt; " ++
            "&lt;a href=&quot;https://hspak.dev/post/example/#section&quot;&gt;Section&lt;/a&gt; " ++
            "&lt;a href=&quot;https://example.com/#part&quot;&gt;Other&lt;/a&gt; " ++
            "&lt;code&gt;href=&amp;quot;#literal&amp;quot;&lt;/code&gt;",
        output.written(),
    );
}

test "feed generation releases resources on every allocation failure" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const generator = struct {
        fn generate(allocator: Allocator, path: []const u8) !void {
            var atom: Atom = undefined;
            try atom.init(allocator, testing.io, path);
            defer atom.deinit(testing.io);
            const posts: Posts = .{};
            try atom.generate(testing.io, &posts);
            const feed = try Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .unlimited);
            defer allocator.free(feed);
            try testing.expect(std.mem.startsWith(u8, feed, "<?xml"));
            try testing.expect(std.mem.endsWith(u8, feed, "</feed>\n"));
        }
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try Io.Dir.path.join(gpa, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "feed.xml",
    });
    defer gpa.free(path);
    try testing.checkAllAllocationFailures(gpa, generator.generate, .{path});
}
