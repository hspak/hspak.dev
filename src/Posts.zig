//! Loaded blog posts and the HTML pages they generate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
pub const Post = @import("Posts/Post.zig");

const Posts = @This();
const log = std.log.scoped(.posts);

list: std.ArrayList(Post) = .empty,

pub const InitError = Post.InitError || Io.Dir.OpenError || Io.Dir.Iterator.Error ||
    error{MissingPosts};
pub const WriteError = Post.WriteError || Io.Dir.DeleteTreeError || Io.Dir.CreateDirError ||
    error{DuplicatePostPath};

const WorkerLimits = struct {
    posts: usize = 0,
    assets: usize = 2,
};

const Batch = struct {
    posts: []Post,
    asset_worker_limit: usize,
    next: std.atomic.Value(usize) = .init(0),

    fn run(batch: *Batch, gpa: Allocator, io: Io) WriteError!void {
        while (true) {
            const index = batch.next.fetchAdd(1, .monotonic);
            if (index >= batch.posts.len) return;
            try batch.posts[index].write(
                gpa,
                io,
                .{ .asset_worker_limit = batch.asset_worker_limit },
            );
        }
    }
};

/// Load every markdown file in `path`.
/// Initialize fresh storage and pair success with `deinit(gpa)`.
/// On error, all loaded posts are freed; do not call `deinit`.
pub fn init(posts: *Posts, gpa: Allocator, io: Io, path: []const u8) InitError!void {
    const started_at = Io.Clock.awake.now(io);
    const cwd = Io.Dir.cwd();
    const posts_dir = cwd.openDir(
        io,
        path,
        .{
            .iterate = true,
            .access_sub_paths = false,
            .follow_symlinks = false,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPosts,
        else => return err,
    };
    defer posts_dir.close(io);

    posts.* = .{};
    errdefer posts.deinit(gpa);

    var iter = posts_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const post_path = try Io.Dir.path.join(gpa, &.{ path, entry.name });
        defer gpa.free(post_path);
        try posts.list.ensureUnusedCapacity(gpa, 1);
        var post: Post = .{};
        try post.init(gpa, io, post_path);
        posts.list.appendAssumeCapacity(post);
    }
    std.sort.insertion(Post, posts.list.items, {}, newerFirst);
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
        try post.writeIndexEntry(w);
    }
}

/// Build assets and HTML, retaining media for current posts and removing obsolete posts.
/// Requires `image.init` and an allocator supporting concurrent calls.
/// Post workers use half the host CPU count, with at least one worker.
/// Each post uses at most two asset workers, including the calling post worker.
/// All workers finish before returning, including on error.
pub fn write(posts: *Posts, gpa: Allocator, io: Io) WriteError!void {
    const started_at = Io.Clock.awake.now(io);
    const cwd = Io.Dir.cwd();
    // Concurrent writers must never share an output directory.
    for (posts.list.items, 0..) |post, index| {
        for (posts.list.items[0..index]) |previous| {
            if (post.meta.draft == previous.meta.draft and std.mem.eql(
                u8,
                post.meta.name,
                previous.meta.name,
            )) return error.DuplicatePostPath;
        }
    }
    for ([_]bool{ false, true }) |draft| {
        const path = if (draft) "docs/draft" else "docs/post";
        try cwd.createDirPath(io, path);
        const dir = try cwd.openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            const keep = for (posts.list.items) |post| {
                if (entry.kind == .directory and post.meta.draft == draft and std.mem.eql(
                    u8,
                    entry.name,
                    post.meta.name,
                )) break true;
            } else false;
            if (!keep) try dir.deleteTree(io, entry.name);
        }
    }
    const elapsed_ns = started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: prune docs/post and docs/draft", .{elapsed_ms});

    const limits = workerLimits(std.Thread.getCpuCount() catch 1, posts.list.items.len);
    if (limits.posts == 0) return;
    log.debug("generate {d} posts with {d} post workers and up to {d} asset workers per post", .{
        posts.list.items.len,
        limits.posts,
        limits.assets,
    });
    var batch: Batch = .{
        .posts = posts.list.items,
        .asset_worker_limit = limits.assets,
    };
    // The caller is one of the post workers.
    const workers = try gpa.alloc(Io.Future(WriteError!void), limits.posts - 1);
    defer gpa.free(workers);
    for (workers) |*worker| {
        const args = .{
            &batch,
            gpa,
            io,
        };
        // Preview connections may occupy the shared pool's async allowance.
        worker.* = io.concurrent(Batch.run, args) catch io.async(Batch.run, args);
    }
    defer for (workers) |*worker| {
        worker.cancel(io) catch {};
    };
    try batch.run(gpa, io);
    for (workers) |*worker| try worker.await(io);
}

fn workerLimits(cpu_count: usize, post_count: usize) WorkerLimits {
    return .{ .posts = @min(post_count, @max(1, cpu_count / 2)) };
}

/// Latest file-modification time among loaded posts, or `null` when empty.
pub fn latestUpdatedAt(posts: *const Posts) ?Io.Timestamp {
    if (posts.list.items.len == 0) return null;

    var latest = posts.list.items[0].mtime;
    for (posts.list.items) |item| {
        if (latest.nanoseconds < item.mtime.nanoseconds) {
            latest = item.mtime;
        }
    }
    return latest;
}

fn newerFirst(_: void, p1: Post, p2: Post) bool {
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

test "post worker limits use half the host CPUs and two asset workers per post" {
    const cases = [_]struct {
        cpus: usize,
        posts: usize,
        expected: WorkerLimits,
    }{
        .{
            .cpus = 8,
            .posts = 0,
            .expected = .{ .posts = 0, .assets = 2 },
        },
        .{
            .cpus = 0,
            .posts = 5,
            .expected = .{ .posts = 1, .assets = 2 },
        },
        .{
            .cpus = 1,
            .posts = 5,
            .expected = .{ .posts = 1, .assets = 2 },
        },
        .{
            .cpus = 3,
            .posts = 5,
            .expected = .{ .posts = 1, .assets = 2 },
        },
        .{
            .cpus = 8,
            .posts = 1,
            .expected = .{ .posts = 1, .assets = 2 },
        },
        .{
            .cpus = 8,
            .posts = 2,
            .expected = .{ .posts = 2, .assets = 2 },
        },
        .{
            .cpus = 8,
            .posts = 3,
            .expected = .{ .posts = 3, .assets = 2 },
        },
        .{
            .cpus = 9,
            .posts = 8,
            .expected = .{ .posts = 4, .assets = 2 },
        },
        .{
            .cpus = 32,
            .posts = 20,
            .expected = .{ .posts = 16, .assets = 2 },
        },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, workerLimits(case.cpus, case.posts));
    }
}

test "posts initialization releases resources on allocation and metadata errors" {
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;
    const loader = struct {
        fn load(allocator: Allocator, path: []const u8) !void {
            var posts: Posts = .{};
            try posts.init(allocator, testing.io, path);
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
    try testing.checkAllAllocationFailures(gpa, loader.load, .{path});

    try tmp.dir.writeFile(io, .{
        .sub_path = "0002-second.md",
        .data = "Name: example\nDescription: Incomplete\n---\nHello\n",
    });
    var posts: Posts = .{};
    try testing.expectError(error.MissingTitle, posts.init(gpa, io, path));
}

test "posts reject names that cannot be a single output directory" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try Io.Dir.path.join(gpa, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(path);
    for ([_][]const u8{
        "",
        ".",
        "..",
        "../outside",
        "/absolute",
        "nested/name",
        "nested\\name",
        "bad\x00name",
    }) |name| {
        const source = try std.fmt.allocPrint(
            gpa,
            "Name: {s}\nTitle: Test\nDescription: Preview\n---\nHello\n",
            .{name},
        );
        defer gpa.free(source);
        try tmp.dir.writeFile(io, .{ .sub_path = "0001-test.md", .data = source });
        var posts: Posts = .{};
        if (posts.init(gpa, io, path)) |_| {
            posts.deinit(gpa);
            return error.InvalidNameAccepted;
        } else |err| {
            try testing.expectEqual(error.InvalidName, err);
        }
    }
}
