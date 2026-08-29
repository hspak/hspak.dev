//! Loaded blog posts and the HTML pages they generate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const partials = @import("partials.zig");
const markdown = @import("markdown.zig");

const log = std.log.scoped(.posts);

list: std.ArrayList(Post) = .empty,

const Posts = @This();

pub const placeholder_text = "missing!!!";

pub const Error = error{
    MissingName,
    MissingTitle,
    MissingDescription,
    MissingPosts,
};

pub const Meta = struct {
    name: []const u8 = placeholder_text,
    title: []const u8 = placeholder_text,
    description: []const u8 = placeholder_text,
    draft: bool = true,
    created_at: []const u8 = placeholder_text,
    updated_at: []const u8 = placeholder_text,
};

pub const Post = struct {
    source: []const u8 = "",
    parsed_html: []const u8 = "",
    mtime: Io.Timestamp = .zero,
    meta: Meta = .{},
    id: u16 = 0,

    /// Read `full_path` and parse its header plus markdown body.
    /// `file_path` is the directory entry name; the first four characters are
    /// the post id. Caller owns the result and must call `deinit`.
    pub fn init(gpa: Allocator, io: Io, full_path: []const u8, file_path: []const u8) !Post {
        const cwd = Io.Dir.cwd();
        const stat = try cwd.statFile(io, full_path, .{});
        const id = try std.fmt.parseUnsigned(u16, file_path[0..4], 10);
        const source = try cwd.readFileAlloc(io, full_path, gpa, .limited(1024 * 1024));
        errdefer gpa.free(source);

        var post: Post = .{
            .source = source,
            .mtime = stat.mtime,
            .id = id,
        };
        try post.parsePost(gpa);
        return post;
    }

    /// Free markdown source and rendered HTML. `gpa` must be the allocator
    /// passed to `init`.
    pub fn deinit(post: *Post, gpa: Allocator) void {
        gpa.free(post.parsed_html);
        gpa.free(post.source);
        post.* = undefined;
    }

    /// Write this post's HTML page under docs/post or docs/draft.
    pub fn printPost(post: *const Post, gpa: Allocator, io: Io) !void {
        const cwd = Io.Dir.cwd();
        const post_state = if (post.meta.draft) "draft" else "post";
        const post_dir_path = try Io.Dir.path.join(gpa, &.{ "docs", post_state, post.meta.name });
        defer gpa.free(post_dir_path);
        const post_index_path = try Io.Dir.path.join(gpa, &.{ post_dir_path, "index.html" });
        defer gpa.free(post_index_path);
        try cwd.createDir(io, post_dir_path, .default_dir);

        log.info("creating {s}", .{post_index_path});
        var output_file = try cwd.createFile(io, post_index_path, .{});
        defer output_file.close(io);

        var buf: [4096]u8 = undefined;
        var writer = output_file.writer(io, &buf);
        const w = &writer.interface;
        try partials.writeHeader(w, false, post.meta.title);

        const has_update = !std.mem.eql(u8, post.meta.created_at, post.meta.updated_at) and
            !std.mem.eql(u8, post.meta.updated_at, placeholder_text);
        const updated: []const u8 = if (has_update)
            try std.fmt.allocPrint(gpa, "(Updated at: {s})", .{post.meta.updated_at})
        else
            "";
        defer if (updated.len != 0) gpa.free(updated);

        try w.print(
            \\      <div class="block">
            \\        <h2>{s}</h2>
            \\        <div class="date">{s} {s}</div>
            \\        <div class="body">
            \\{s}        </div>
            \\      </div>
        , .{ post.meta.title, post.meta.created_at, updated, post.parsed_html });

        try partials.writeFooter(w, false);
        try w.flush();
    }

    /// Write the index listing for a published post. Drafts are skipped.
    pub fn printIndexEntry(post: *const Post, w: *Writer) !void {
        if (post.meta.draft) return;

        try w.print(
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
        , .{ post.meta.name, post.meta.title, post.meta.created_at, post.meta.description });
    }

    fn parsePost(post: *Post, gpa: Allocator) !void {
        var rest = post.source;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            var line = rest[0..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            rest = rest[nl + 1 ..];
            if (!parseHeader(post, line)) break;
        } else {
            _ = parseHeader(post, rest);
            rest = "";
        }

        try post.validate();
        post.parsed_html = try markdown.toHtml(gpa, rest);
    }

    fn parseHeader(post: *Post, line: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "---")) {
            return false;
        } else if (std.mem.startsWith(u8, line, "Name:")) {
            post.meta.name = trimValue(line["Name:".len..]);
        } else if (std.mem.startsWith(u8, line, "Title:")) {
            post.meta.title = trimValue(line["Title:".len..]);
        } else if (std.mem.startsWith(u8, line, "Draft:")) {
            post.meta.draft = !std.mem.eql(u8, trimValue(line["Draft:".len..]), "false");
        } else if (std.mem.startsWith(u8, line, "Description:")) {
            post.meta.description = trimValue(line["Description:".len..]);
        } else if (std.mem.startsWith(u8, line, "Publish Date:")) {
            post.meta.created_at = trimValue(line["Publish Date:".len..]);
        } else if (std.mem.startsWith(u8, line, "Updated Date:")) {
            post.meta.updated_at = trimValue(line["Updated Date:".len..]);
        }
        return true;
    }

    fn validate(post: *Post) Error!void {
        if (std.mem.eql(u8, post.meta.name, placeholder_text)) {
            return error.MissingName;
        }
        if (std.mem.eql(u8, post.meta.title, placeholder_text)) {
            return error.MissingTitle;
        }
        if (std.mem.eql(u8, post.meta.description, placeholder_text)) {
            return error.MissingDescription;
        }
    }
};

/// Load every markdown file in `path`.
/// Caller owns the result and must call `deinit` with the same `gpa`.
pub fn init(gpa: Allocator, io: Io, path: []const u8) !Posts {
    const cwd = Io.Dir.cwd();
    var posts_dir = cwd.openDir(io, path, .{
        .iterate = true,
        .access_sub_paths = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPosts,
        else => |e| return e,
    };
    defer posts_dir.close(io);

    var posts: Posts = .{};
    errdefer posts.deinit(gpa);

    var iter = posts_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const post_path = try Io.Dir.path.join(gpa, &.{ path, entry.name });
        defer gpa.free(post_path);
        try posts.list.ensureUnusedCapacity(gpa, 1);
        const post = try Post.init(gpa, io, post_path, entry.name);
        posts.list.appendAssumeCapacity(post);
    }
    std.sort.insertion(Post, posts.list.items, {}, newerFirst);
    return posts;
}

/// Free every post and the list. `gpa` must be the allocator passed to `init`.
pub fn deinit(posts: *Posts, gpa: Allocator) void {
    for (posts.list.items) |*post| {
        post.deinit(gpa);
    }
    posts.list.deinit(gpa);
    posts.* = undefined;
}

/// Write index listings for every published post.
pub fn writeIndex(posts: *const Posts, w: *Writer) !void {
    for (posts.list.items) |*post| {
        try post.printIndexEntry(w);
    }
}

/// Write each post's HTML page, replacing docs/post and docs/draft.
pub fn writePost(posts: *const Posts, gpa: Allocator, io: Io) !void {
    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(io, "docs/draft");
    try cwd.deleteTree(io, "docs/post");
    try cwd.createDir(io, "docs/draft", .default_dir);
    try cwd.createDir(io, "docs/post", .default_dir);

    for (posts.list.items) |*post| {
        try post.printPost(gpa, io);
    }
}

/// Latest file-modification time among loaded posts.
pub fn latestUpdatedAt(posts: *const Posts) Error!Io.Timestamp {
    if (posts.list.items.len == 0) {
        return error.MissingPosts;
    }

    var latest = posts.list.items[0].mtime;
    for (posts.list.items) |item| {
        if (latest.nanoseconds < item.mtime.nanoseconds) {
            latest = item.mtime;
        }
    }
    return latest;
}

fn trimValue(raw_value: []const u8) []const u8 {
    return std.mem.trim(u8, raw_value, " \t");
}

fn newerFirst(_: void, p1: Post, p2: Post) bool {
    if (p1.id >= 9000 and p2.id >= 9000) {
        return p1.id > p2.id;
    }
    if (p2.id >= 9000) return true;
    if (p1.id >= 9000) return false;
    return p1.id > p2.id;
}
