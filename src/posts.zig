const std = @import("std");
const fs = std.fs;
const partials = @import("partials.zig");

const PostError = error{
    MissingName,
    MissingTitle,
    MissingDescription,
    MissingBody,
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
            try post.printBody();
        }
    }

    pub fn deinit(self: Self) void {
        for (self.list.items) |post| {
            post.deinit();
        }
        self.list.deinit();
    }
};

const Post = struct {
    allocator: *std.mem.Allocator,
    full_path: []const u8,
    file: fs.File,
    stat: fs.File.Stat,
    parsedHTML: std.ArrayList(u8),
    meta: struct {
        name: []const u8,
        title: []const u8,
        desc: []const u8,
        body: []const u8,
    },

    const Self = @This();

    pub fn init(allocator: *std.mem.Allocator, full_path: []const u8) !Post {
        var post_file = try fs.cwd().openFile(full_path, .{ .read = true });
        var post = Post{
            .allocator = allocator,
            .full_path = full_path,
            .file = post_file,
            .stat = try post_file.stat(),
            .parsedHTML = std.ArrayList(u8).init(allocator),
            .meta = .{
                .name = "missing",
                .title = "missing",
                .desc = "missing",
                .body = "missing",
            },
        };
        try post.parsePost();
        return post;
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
    }

    pub fn printBody(self: *Self) !void {
        std.debug.warn("wtf: {}\n", .{self.meta});
        const post_dir_path = try fs.path.join(self.allocator, &[_][]const u8{ "docs", "post", self.meta.name });
        const post_index_path = try fs.path.join(self.allocator, &[_][]const u8{ post_dir_path, "index.html" });
        fs.cwd().makeDir(post_dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.debug.warn("this is fine\n", .{});
            },
            else => return err,
        };
        fs.cwd().deleteFile(post_index_path) catch |err| {};
        var output_file = try fs.cwd().createFile(post_index_path, .{});
        defer output_file.close();
        try partials.writeHeader(output_file, false);
        const stream = output_file.outStream();
        try stream.print(
            \\      <div class="block">
            \\        <h2>{}</h2>
            \\        <div class="date">May 19, 2020</div>
            \\        <div class="body">{}</div>
            \\      </div>
        , .{ self.meta.title, self.meta.body });
        // const ignore = try output_file.write(self.meta.body);
        try partials.writeFooter(output_file);
    }

    pub fn printIndexEntry(self: *Self, output_file: fs.File) !void {
        const stream = output_file.outStream();
        try stream.print(
            \\      <div class="block">
            \\        <div class="entry">
            \\        <a href="/post/{}/">
            \\          <h2>{}</h2>
            \\          <div class="date">May 19, 2020</div>
            \\          <div class="preview">{}</div>
            \\        </a>
            \\        </div>
            \\      </div>
            \\
        , .{ self.meta.name, self.meta.title, self.meta.desc });
    }

    fn parsePost(self: *Self) !void {
        var buf = try self.allocator.alloc(u8, self.stat.size);
        var stream = self.file.inStream();
        var in_header = true;
        var body = std.ArrayList(u8).init(self.allocator);
        while (try stream.readUntilDelimiterOrEof(buf, '\n')) |line| {
            std.debug.warn("line: {}\n", .{line});
            if (in_header) {
                if (std.mem.eql(u8, line[0..3], "---")) {
                    in_header = false;
                } else if (line.len < 5) {
                    continue;
                } else if (std.mem.eql(u8, line[0..5], "Name:")) {
                    var iter = std.mem.split(line, ":");
                    const ignored = iter.next().?;
                    self.meta.name = try self.trimWhitespace(iter.next().?);
                } else if (std.mem.eql(u8, line[0..6], "Title:")) {
                    var iter = std.mem.split(line, ":");
                    const ignored = iter.next().?;
                    self.meta.title = try self.trimWhitespace(iter.next().?);
                } else if (std.mem.eql(u8, line[0..12], "Description:")) {
                    var iter = std.mem.split(line, ":");
                    const ignored = iter.next().?;
                    self.meta.desc = try self.trimWhitespace(iter.next().?);
                }
            } else {
                try body.appendSlice(line);
                try body.append('\n');
            }
        }
        self.meta.body = body.toOwnedSlice();
        if (std.mem.eql(u8, self.meta.name, "missing")) {
            return PostError.MissingName;
        } else if (std.mem.eql(u8, self.meta.title, "missing")) {
            return PostError.MissingTitle;
        } else if (std.mem.eql(u8, self.meta.desc, "missing")) {
            return PostError.MissingDescription;
        } else if (std.mem.eql(u8, self.meta.body, "missing")) {
            return PostError.MissingBody;
        }
        std.debug.warn("meta: {}\n", .{self.meta});
    }

    fn valid(self: *Self) bool {
        if (std.mem.eql(u8, self.meta.name, "missing")) {
            return false;
        } else if (std.mem.eql(u8, self.meta.title, "missing")) {
            return false;
        } else if (std.mem.eql(u8, self.meta.desc, "missing")) {
            return false;
        } else if (std.mem.eql(u8, self.meta.body, "missing")) {
            return false;
        }
        return true;
    }

    fn trimWhitespace(self: *Self, raw_value: []const u8) ![]const u8 {
        var value = std.ArrayList(u8).init(self.allocator);
        var non_whitespace = false;
        for (raw_value) |char, i| {
            if (char == ' ' and !non_whitespace) {
                continue;
            }
            non_whitespace = true;
            try value.append(char);
        }
        var i = value.items.len;
        while (i > 0) : (i -= 1) {
            if (value.items[i - 1] == ' ') {
                const ignored = value.pop();
            }
            break;
        }
        return value.toOwnedSlice();
    }
};

fn newerFile(ctx: void, p1: *Post, p2: *Post) bool {
    return p1.stat.mtime < p2.stat.mtime;
}
