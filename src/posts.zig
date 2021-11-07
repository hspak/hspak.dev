const std = @import("std");
const fs = std.fs;
const partials = @import("partials.zig");
const time = @import("time.zig");
const koino = @import("koino");

const PlaceholderText = "missing!!!";
const PostError = error{
    MissingName,
    MissingTitle,
    MissingDescription,
    MissingPosts,
};

pub const Posts = struct {
    list: std.ArrayList(*Post),

    const Self = @This();

    pub fn init(allocator: *std.mem.Allocator, path: []const u8) !Posts {
        var posts_dir = try fs.cwd().openDir(path, .{ .iterate = true });
        defer posts_dir.close();
        var iter = posts_dir.iterate();

        var list = std.ArrayList(*Post).init(allocator);
        while (try iter.next()) |next| {
            const post_path = try fs.path.join(allocator, &[_][]const u8{ path, next.name });
            const post = try allocator.create(Post);
            post.* = try Post.init(allocator, post_path);
            try list.append(post);
        }
        std.sort.sort(*Post, list.items, {}, newerFile);
        return Posts{
            .list = list,
        };
    }

    pub fn writeIndex(self: Self, output_file: fs.File) !void {
        for (self.list.items) |post| {
            try post.printIndexEntry(output_file);
        }
    }

    pub fn writePost(self: Self) !void {
        for (self.list.items) |post| {
            try post.printPost();
        }
    }

    pub fn latestUpdatedAt(self: Self) !i128 {
        if (self.list.items.len == 0) {
            return PostError.MissingPosts;
        }

        var latest: i128 = self.list.items[0].stat.mtime;
        for (self.list.items) |item| {
            if (latest < item.stat.mtime) {
                latest = item.stat.mtime;
            }
        }
        return latest;
    }

    pub fn deinit(self: Self) void {
        for (self.list.items) |post| {
            post.deinit();
        }
        self.list.deinit();
    }
};

const Post = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    full_path: []const u8,
    file: fs.File,
    updated_at: []const u8,
    stat: fs.File.Stat,
    parsedHTML: std.ArrayList(u8),
    meta: struct {
        name: []const u8,
        title: []const u8,
        desc: []const u8,
        draft: bool,
        created_at: []const u8,
    },

    pub fn init(allocator: *std.mem.Allocator, full_path: []const u8) !Post {
        var post_file = try fs.cwd().openFile(full_path, .{ .read = true });
        const stat = try post_file.stat();
        const updated_at = try time.formatUnixTime(allocator, stat.mtime);

        var post = Post{
            .allocator = allocator,
            .full_path = full_path,
            .file = post_file,
            .parsedHTML = std.ArrayList(u8).init(allocator),
            .updated_at = updated_at,
            .stat = stat,
            .meta = .{
                .name = PlaceholderText,
                .title = PlaceholderText,
                .desc = PlaceholderText,
                .draft = true,
                .created_at = PlaceholderText,
            },
        };
        try post.parsePost();
        return post;
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
    }

    pub fn printPost(self: *Self) !void {
        const postState = if (self.meta.draft) "draft" else "post";
        const post_dir_path = try fs.path.join(self.allocator, &[_][]const u8{ "docs", postState, self.meta.name });
        const post_index_path = try fs.path.join(self.allocator, &[_][]const u8{ post_dir_path, "index.html" });
        fs.cwd().makeDir(post_dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        fs.cwd().deleteFile(post_index_path) catch |err| switch (err) {
            else => {},
        };

        var output_file: std.fs.File = undefined;
        std.debug.warn("[ ] creating: {s}\n", .{post_index_path});
        output_file = try fs.cwd().createFile(post_index_path, .{});
        defer output_file.close();

        try partials.writeHeader(output_file, false);

        var updated = std.ArrayList(u8).init(self.allocator);
        if (!std.mem.eql(u8, self.meta.created_at, self.updated_at)) {
            try updated.writer().print("(Updated at: {s})", .{self.updated_at});
        }
        const stream = output_file.writer();
        try stream.print(
            \\      <div class="block">
            \\        <h2>{s}</h2>
            \\        <div class="date">{s} {s}</div>
            \\        <div class="body">
            \\{s}        </div>
            \\      </div>
        , .{ self.meta.title, self.meta.created_at, updated.items, self.parsedHTML.items });

        try partials.writeFooter(output_file, false);
    }

    pub fn printIndexEntry(self: *Self, output_file: fs.File) !void {
        if (self.meta.draft) return;

        const stream = output_file.writer();
        try stream.print(
            \\      <div class="block">
            \\        <div class="entry">
            \\        <a href="/post/{s}/">
            \\          <h2>{s}</h2>
            \\          <div class="date">{s}</div>
            \\          <div class="preview">{s}</div>
            \\        </a>
            \\        </div>
            \\      </div>
            \\
        , .{ self.meta.name, self.meta.title, self.meta.created_at, self.meta.desc });
    }

    fn parsePost(self: *Self) !void {
        var buf = try self.allocator.alloc(u8, self.stat.size);
        var stream = self.file.reader();

        var in_header = true;
        while (try stream.readUntilDelimiterOrEof(buf, '\n')) |line| {
            in_header = try self.parseHeader(line);
            if (!in_header) break;
        }

        try self.validate();
        var parser = try koino.parser.Parser.init(self.allocator, koino.Options{});
        defer parser.deinit();

        var markdown = try self.file.reader().readAllAlloc(self.allocator, 1024 * 1024);
        try parser.feed(markdown);

        var doc = try parser.finish();
        defer doc.deinit();

        try koino.html.print(self.parsedHTML.writer(), self.allocator, parser.options, doc);
    }

    fn parseHeader(self: *Self, line: []const u8) !bool {
        // TODO: Fix the bad index out-of-bounds error when we check for key equality.
        // The current workaround is to order the if/else with shortest to longest...
        if (std.mem.eql(u8, line[0..3], "---")) {
            return false;
        } else if (line.len < 5) {
            return true;
        } else if (std.mem.eql(u8, line[0..5], "Name:")) {
            var iter = std.mem.split(u8, line, ":");
            _ = iter.next().?;
            self.meta.name = try self.trimWhitespace(iter.next().?);
        } else if (std.mem.eql(u8, line[0..6], "Title:")) {
            var iter = std.mem.split(u8, line, ":");
            _ = iter.next().?;
            self.meta.title = try self.trimWhitespace(iter.next().?);
        } else if (std.mem.eql(u8, line[0..6], "Draft:")) {
            var iter = std.mem.split(u8, line, ":");
            _ = iter.next().?;
            self.meta.draft = if (std.mem.eql(u8, try self.trimWhitespace(iter.next().?), "false")) false else true;
        } else if (std.mem.eql(u8, line[0..12], "Description:")) {
            var iter = std.mem.split(u8, line, ":");
            _ = iter.next().?;
            self.meta.desc = try self.trimWhitespace(iter.next().?);
        } else if (std.mem.eql(u8, line[0..13], "Publish Date:")) {
            var iter = std.mem.split(u8, line, ":");
            _ = iter.next().?;
            self.meta.created_at = try self.trimWhitespace(iter.next().?);
        }
        return true;
    }

    fn validate(self: *Self) !void {
        if (std.mem.eql(u8, self.meta.name, PlaceholderText)) {
            return PostError.MissingName;
        } else if (std.mem.eql(u8, self.meta.title, PlaceholderText)) {
            return PostError.MissingTitle;
        } else if (std.mem.eql(u8, self.meta.desc, PlaceholderText)) {
            return PostError.MissingDescription;
        }
    }

    fn trimWhitespace(self: *Self, raw_value: []const u8) ![]const u8 {
        var value = std.ArrayList(u8).init(self.allocator);
        var non_whitespace = false;
        for (raw_value) |char| {
            if (char == ' ' and !non_whitespace) {
                continue;
            }
            non_whitespace = true;
            try value.append(char);
        }
        var i = value.items.len;
        while (i > 0) : (i -= 1) {
            if (value.items[i - 1] == ' ') {
                _ = value.pop();
            }
            break;
        }
        return value.toOwnedSlice();
    }
};

fn newerFile(_: void, p1: *Post, p2: *Post) bool {
    return p1.stat.mtime > p2.stat.mtime;
}
