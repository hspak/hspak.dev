//! Loaded blog posts and the HTML pages they generate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

list: std.ArrayList(Post) = .empty,

const Posts = @This();
const log = std.log.scoped(.posts);

pub const Post = @import("Posts/Post.zig");
pub const Meta = Post.Meta;
pub const placeholder_text = Post.placeholder_text;
pub const Error = Post.ValidationError || error{MissingPosts};
pub const InitError = Post.InitError || Io.Dir.OpenError || Io.Dir.Iterator.Error ||
    error{MissingPosts};
pub const WriteError = Post.WriteError || Io.Dir.DeleteTreeError || Io.Dir.CreateDirError;

/// Load every markdown file in `path`.
/// Initialize fresh storage and pair success with `deinit(gpa)`.
/// On error, all loaded posts are freed; do not call `deinit`.
pub fn init(
    posts: *Posts,
    gpa: Allocator,
    io: Io,
    path: []const u8,
) InitError!void {
    const started_at = Io.Clock.awake.now(io);
    const cwd = Io.Dir.cwd();
    var posts_dir = cwd.openDir(
        io,
        path,
        .{
            .iterate = true,
            .access_sub_paths = false,
            .follow_symlinks = false,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPosts,
        else => |e| return e,
    };
    defer posts_dir.close(io);

    posts.* = .{};
    errdefer posts.deinit(gpa);

    var iter = posts_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(
            u8,
            entry.name,
            ".md",
        )) continue;
        const post_path = try Io.Dir.path.join(gpa, &.{ path, entry.name });
        defer gpa.free(post_path);
        try posts.list.ensureUnusedCapacity(gpa, 1);
        var post: Post = .{};
        try post.init(
            gpa,
            io,
            post_path,
            entry.name,
        );
        posts.list.appendAssumeCapacity(post);
    }
    std.sort.insertion(
        Post,
        posts.list.items,
        {},
        newerFirst,
    );
    const elapsed_ns = started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: load {s}", .{ elapsed_ms, path });
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
pub fn writeIndex(posts: *const Posts, w: *Writer) Writer.Error!void {
    for (posts.list.items) |*post| {
        try post.printIndexEntry(w);
    }
}

/// Build assets and HTML, replacing docs/post and docs/draft. Requires `image.init`.
/// `gpa` must support concurrent calls during asset processing.
pub fn writePost(
    posts: *Posts,
    gpa: Allocator,
    io: Io,
) WriteError!void {
    const started_at = Io.Clock.awake.now(io);
    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(io, "docs/draft");
    try cwd.deleteTree(io, "docs/post");
    try cwd.createDir(
        io,
        "docs/draft",
        .default_dir,
    );
    try cwd.createDir(
        io,
        "docs/post",
        .default_dir,
    );
    const elapsed_ns = started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: reset docs/post and docs/draft", .{elapsed_ms});

    for (posts.list.items) |*post| {
        try post.printPost(
            gpa,
            io,
        );
    }
}

/// Latest file-modification time among loaded posts; `MissingPosts` when empty.
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

fn newerFirst(
    _: void,
    p1: Post,
    p2: Post,
) bool {
    if (p1.id >= 9000 and p2.id >= 9000) {
        return p1.id > p2.id;
    }
    if (p2.id >= 9000) return true;
    if (p1.id >= 9000) return false;
    return p1.id > p2.id;
}

test {
    _ = Post;
}

test "posts initialization releases resources on allocation and metadata errors" {
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;
    const loader = struct {
        fn load(allocator: Allocator, path: []const u8) !void {
            var posts: Posts = .{};
            try posts.init(
                allocator,
                testing.io,
                path,
            );
            defer posts.deinit(allocator);
            try testing.expectEqual(@as(usize, 2), posts.list.items.len);
            try testing.expectEqualStrings("<p>Hello</p>\n", posts.list.items[0].parsed_html);
        }
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "Name: example\nTitle: Example\nDescription: Preview\n---\nHello\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "0001-first.md", .data = source });
    try tmp.dir.writeFile(io, .{ .sub_path = "0002-second.md", .data = source });
    const path = try Io.Dir.path.join(gpa, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(path);
    try testing.checkAllAllocationFailures(
        gpa,
        loader.load,
        .{path},
    );

    try tmp.dir.writeFile(io, .{
        .sub_path = "0002-second.md",
        .data = "Name: example\nDescription: Incomplete\n---\nHello\n",
    });
    var posts: Posts = .{};
    try testing.expectError(error.MissingTitle, posts.init(
        gpa,
        io,
        path,
    ));
}
