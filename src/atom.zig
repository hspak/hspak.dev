const std = @import("std");
const Posts = @import("posts.zig").Posts;
const time = @import("time.zig");

pub const Atom = struct {
    const Self = @This();

    feed: std.ArrayList(u8),
    output_file: std.fs.File,
    allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator, output_path: []const u8) !*Self {
        std.fs.cwd().deleteFile(output_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        _ = try std.fs.cwd().createFile(output_path, .{});

        var file = try std.fs.cwd().openFile(output_path, .{ .write = true });
        var atom = try allocator.create(Self);
        atom.feed = std.ArrayList(u8).init(allocator);
        atom.output_file = file;
        atom.allocator = allocator;
        return atom;
    }

    pub fn deinit(self: *Self) void {
        self.output_file.close();
        self.allocator.destroy(self);
    }

    pub fn generate(self: *Self, posts: Posts) !void {
        try self.header(posts);
        try self.addEntries(posts);
        try self.footer();
        _ = try self.output_file.writer().write(self.feed.items);
    }

    fn header(self: *Self, posts: Posts) !void {
        const stream = self.feed.writer();
        try stream.print(
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<feed xmlns="http://www.w3.org/2005/Atom">
            \\<title>Hong's Blog</title>
            \\<link href="https://hspak.dev/"/>
            \\<updated>{s}</updated>
            \\<author>
            \\  <name>Hong Shick Pak</name>
            \\</author>
            \\<id>https://hspak.dev/atom.xml</id>
        , .{time.formatUnixTime(self.allocator, try posts.latestUpdatedAt())});
    }

    fn addEntries(self: *Self, posts: Posts) !void {
        const stream = self.feed.writer();
        for (posts.list.items) |item| {
            if (item.meta.draft) continue;

            _ = try stream.write("<entry>\n");
            try stream.print("  <title>{s}</title>\n", .{item.meta.title});
            try stream.print("  <published>{s}</published>\n", .{item.meta.created_at});
            try stream.print("  <updated>{s}</updated>\n", .{item.updated_at});
            try stream.print(
                \\  <link href="https://hspak.dev/post/{s}/" type="text/html"/>
            , .{item.meta.name});
            try stream.print("\n  <id>https://hspak.dev/post/{s}/</id>\n", .{item.meta.name});
            try stream.print(
                \\  <content type="html">
                \\    {s}  </content>
            , .{try htmlreference(self.allocator, item.parsedHTML.items)});
            _ = try stream.write("\n</entry>\n");
        }
    }

    fn footer(self: *Self) !void {
        try self.feed.appendSlice("</feed>\n");
    }
};

fn htmlreference(allocator: *std.mem.Allocator, html_body: []u8) ![]const u8 {
    var encoded_body = std.ArrayList(u8).init(allocator);
    const stream = encoded_body.writer();
    for (html_body) |char| {
        if (char == '<') {
            _ = try stream.write("&lt;");
        } else if (char == '>') {
            _ = try stream.write("&gt;");
        } else if (char == '"') {
            _ = try stream.write("&quot;");
        } else if (char == '&') {
            _ = try stream.write("&amp;");
        } else {
            _ = try stream.writeByte(char);
        }
    }
    return encoded_body.toOwnedSlice();
}
