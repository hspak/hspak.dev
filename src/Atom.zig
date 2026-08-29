//! Atom feed written from a `Posts` list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Posts = @import("Posts.zig");
const time = @import("time.zig");

const log = std.log.scoped(.atom);

feed: Writer.Allocating,
output_file: Io.File,

const Atom = @This();

/// Create `output_path` and prepare an empty feed.
/// Caller owns the result and must call `deinit`.
pub fn init(gpa: Allocator, io: Io, output_path: []const u8) !Atom {
    const file = try Io.Dir.cwd().createFile(io, output_path, .{});
    errdefer file.close(io);
    return .{
        .feed = .init(gpa),
        .output_file = file,
    };
}

/// Close the feed file and free the buffer. Does not free `atom` itself.
pub fn deinit(atom: *Atom, io: Io) void {
    atom.output_file.close(io);
    atom.feed.deinit();
    atom.* = undefined;
}

/// Write the Atom XML for `posts` to the file opened in `init`.
pub fn generate(atom: *Atom, io: Io, posts: *const Posts) !void {
    try atom.header(posts);
    try atom.addEntries(posts);
    try atom.footer();
    try atom.output_file.writeStreamingAll(io, atom.feed.writer.buffered());
}

fn header(atom: *Atom, posts: *const Posts) !void {
    const w = &atom.feed.writer;
    const timestamp = try posts.latestUpdatedAt();
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
        if (!std.mem.eql(u8, item.meta.updated_at, Posts.placeholder_text)) {
            try w.print("  <updated>{s}</updated>\n", .{item.meta.updated_at});
        } else {
            try w.print("  <updated>{s}</updated>\n", .{item.meta.created_at});
        }
        try w.print(
            \\  <link href="https://hspak.dev/post/{s}/" type="text/html"/>
        , .{item.meta.name});
        try w.print("\n  <id>https://hspak.dev/post/{s}/</id>\n", .{item.meta.name});
        try w.writeAll("  <content type=\"html\">\n    ");
        try writeXmlEscaped(w, item.parsed_html);
        try w.writeAll("  </content>");
        try w.writeAll("\n</entry>\n");
    }
}

fn footer(atom: *Atom) !void {
    try atom.feed.writer.writeAll("</feed>\n");
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
