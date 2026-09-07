//! A blog post, its metadata, and the pages and assets rendered from its source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Posts = @import("../Posts.zig");
const image = @import("../image.zig");
const markdown = @import("../markdown.zig");
const partials = @import("../partials.zig");

source: []const u8 = "",
/// Markdown body borrowed from `source`.
body: []const u8 = "",
parsed_html: []const u8 = "",
/// Owned sibling-directory path; freed by `deinit` with the post's allocator.
asset_source_path: []const u8 = "",
mtime: Io.Timestamp = .zero,
meta: Meta = .{},
id: u16 = 0,

const Post = @This();
const log = std.log.scoped(.post);

pub const placeholder_text = "missing!!!";

pub const ValidationError = error{
    MissingName,
    MissingTitle,
    MissingDescription,
};

pub const InitError = Allocator.Error || Io.Dir.StatFileError ||
    Io.Dir.ReadFileAllocError || std.fmt.ParseIntError || ValidationError ||
    error{InvalidPostFilename};

pub const WriteError = image.Error || Writer.Error || Io.Dir.OpenError ||
    Io.Dir.Iterator.Error || Io.Dir.CopyFileError || Io.Dir.ReadFileAllocError ||
    Io.Dir.CreateDirPathError || Io.Dir.WriteFileError;

/// Metadata strings borrow slices of the post's source until `deinit`.
pub const Meta = struct {
    name: []const u8 = placeholder_text,
    title: []const u8 = placeholder_text,
    description: []const u8 = placeholder_text,
    draft: bool = true,
    created_at: []const u8 = placeholder_text,
    updated_at: []const u8 = placeholder_text,
};

const Asset = struct {
    path: []const u8,
    has_thumbnail: bool = false,
};

const AssetBatch = struct {
    source_dir: Io.Dir,
    source_path: []const u8,
    output_path: []const u8,
    assets: []Asset,
    next: std.atomic.Value(usize) = .init(0),

    fn run(
        batch: *AssetBatch,
        gpa: Allocator,
        io: Io,
    ) WriteError!void {
        while (true) {
            const index = batch.next.fetchAdd(1, .monotonic);
            if (index >= batch.assets.len) return;
            const asset = &batch.assets[index];
            asset.has_thumbnail = try buildAsset(
                gpa,
                io,
                batch.source_dir,
                batch.source_path,
                batch.output_path,
                asset.path,
            );
        }
    }
};

/// Read `full_path` and parse its header plus markdown body.
/// `file_path` is the directory entry name; the first four characters are
/// the post id. Initialize fresh storage and pair success with `deinit(gpa)`.
/// On error, all allocations are freed and `post` is undefined.
pub fn init(
    post: *Post,
    gpa: Allocator,
    io: Io,
    full_path: []const u8,
    file_path: []const u8,
) InitError!void {
    post.* = .{};
    errdefer post.deinit(gpa);
    const cwd = Io.Dir.cwd();
    const stat = try cwd.statFile(
        io,
        full_path,
        .{},
    );
    if (file_path.len < 4) return error.InvalidPostFilename;
    const id = try std.fmt.parseUnsigned(
        u16,
        file_path[0..4],
        10,
    );
    post.source = try cwd.readFileAlloc(
        io,
        full_path,
        gpa,
        .limited(1024 * 1024),
    );
    post.asset_source_path = try gpa.dupe(
        u8,
        full_path[0 .. full_path.len - ".md".len],
    );

    post.mtime = stat.mtime;
    post.id = id;
    try post.parsePost(gpa);
}

/// Free markdown source, rendered HTML, and asset path. `gpa` must be the allocator
/// passed to `init`.
pub fn deinit(post: *Post, gpa: Allocator) void {
    gpa.free(post.parsed_html);
    gpa.free(post.asset_source_path);
    gpa.free(post.source);
    post.* = undefined;
}

/// Build assets and this post's HTML page under docs/post or docs/draft.
/// Requires `image.init`; updates `parsed_html` for subsequent feed rendering.
/// `gpa` must support concurrent calls during asset processing.
pub fn printPost(
    post: *Post,
    gpa: Allocator,
    io: Io,
) WriteError!void {
    const started_at = Io.Clock.awake.now(io);
    const cwd = Io.Dir.cwd();
    const post_state = if (post.meta.draft) "draft" else "post";
    const post_dir_path = try Io.Dir.path.join(gpa, &.{
        "docs",
        post_state,
        post.meta.name,
    });
    defer gpa.free(post_dir_path);
    const post_index_path = try Io.Dir.path.join(gpa, &.{ post_dir_path, "index.html" });
    defer gpa.free(post_index_path);
    try cwd.createDir(
        io,
        post_dir_path,
        .default_dir,
    );
    var thumbnail_paths = try post.buildAssets(
        gpa,
        io,
        post_dir_path,
    );
    defer freeThumbnailPaths(gpa, &thumbnail_paths);
    try post.renderBody(gpa, thumbnail_paths.items);

    var output_file = try cwd.createFile(
        io,
        post_index_path,
        .{},
    );
    defer output_file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = output_file.writer(io, &buf);
    const w = &writer.interface;
    try partials.writeHeader(
        w,
        false,
        post.meta.title,
    );

    const has_update = !std.mem.eql(
        u8,
        post.meta.created_at,
        post.meta.updated_at,
    ) and !std.mem.eql(
        u8,
        post.meta.updated_at,
        placeholder_text,
    );
    const updated: []const u8 = if (has_update)
        try std.fmt.allocPrint(
            gpa,
            "(Updated at: {s})",
            .{post.meta.updated_at},
        )
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
    , .{
        post.meta.title,
        post.meta.created_at,
        updated,
        post.parsed_html,
    });

    try partials.writeFooter(w, false);
    try w.flush();
    const elapsed_ns = started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: create {s}", .{ elapsed_ms, post_index_path });
}

/// Caller owns the returned list and its paths; free with `freeThumbnailPaths`.
fn buildAssets(
    post: *const Post,
    gpa: Allocator,
    io: Io,
    post_dir_path: []const u8,
) !std.ArrayList([]const u8) {
    var thumbnail_paths: std.ArrayList([]const u8) = .empty;
    errdefer freeThumbnailPaths(gpa, &thumbnail_paths);
    const cwd = Io.Dir.cwd();
    const source_dir = cwd.openDir(
        io,
        post.asset_source_path,
        .{
            .iterate = true,
            .follow_symlinks = false,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => return err,
    };
    defer source_dir.close(io);

    var assets: std.ArrayList(Asset) = .empty;
    defer {
        for (assets.items) |asset| gpa.free(asset.path);
        assets.deinit(gpa);
    }
    {
        var walker = try source_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            try assets.ensureUnusedCapacity(gpa, 1);
            assets.appendAssumeCapacity(.{ .path = try gpa.dupe(u8, entry.path) });
        }
    }
    if (assets.items.len == 0) return .empty;
    try thumbnail_paths.ensureTotalCapacity(gpa, assets.items.len);

    var batch: AssetBatch = .{
        .source_dir = source_dir,
        .source_path = post.asset_source_path,
        .output_path = post_dir_path,
        .assets = assets.items,
    };
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_count = @min(assets.items.len, cpu_count);
    // The caller also drains the queue, keeping the total within the CPU count.
    const workers = try gpa.alloc(Io.Future(WriteError!void), worker_count - 1);
    defer gpa.free(workers);
    for (workers) |*worker| {
        const args = .{
            &batch,
            gpa,
            io,
        };
        // HTTP connections can occupy the shared pool's async allowance while waiting for I/O.
        worker.* = io.concurrent(AssetBatch.run, args) catch io.async(AssetBatch.run, args);
    }
    // Workers must finish before their paths, allocator, and source directory are released.
    defer for (workers) |*worker| {
        worker.cancel(io) catch {};
    };
    try batch.run(gpa, io);
    for (workers) |*worker| try worker.await(io);

    for (assets.items) |*asset| {
        if (!asset.has_thumbnail) continue;
        thumbnail_paths.appendAssumeCapacity(asset.path);
        asset.path = ""; // Transfer ownership to the result after all workers have joined.
    }
    return thumbnail_paths;
}

fn buildAsset(
    gpa: Allocator,
    io: Io,
    source_dir: Io.Dir,
    source_path: []const u8,
    post_dir_path: []const u8,
    path: []const u8,
) WriteError!bool {
    const cwd = Io.Dir.cwd();
    const output_path = try Io.Dir.path.join(gpa, &.{
        post_dir_path,
        "assets",
        path,
    });
    defer gpa.free(output_path);
    try source_dir.copyFile(
        path,
        cwd,
        output_path,
        io,
        .{ .make_path = true },
    );
    if (!image.supportsPath(path)) return false;
    const encoded = try source_dir.readFileAlloc(
        io,
        path,
        gpa,
        .unlimited,
    );
    defer gpa.free(encoded);
    const thumbnail = image.thumbnail(
        gpa,
        encoded,
        720,
    ) catch |err| {
        log.err("cannot thumbnail {s}/{s}: {t}", .{
            source_path,
            path,
            err,
        });
        return err;
    } orelse return false;
    defer gpa.free(thumbnail);
    const thumbnail_path = try Io.Dir.path.join(gpa, &.{
        post_dir_path,
        "thumbnails",
        path,
    });
    defer gpa.free(thumbnail_path);
    try cwd.createDirPath(io, Io.Dir.path.dirname(thumbnail_path).?);
    try cwd.writeFile(io, .{
        .sub_path = thumbnail_path,
        .data = thumbnail,
    });
    return true;
}

/// Write the index listing for a published post. Drafts are skipped.
pub fn printIndexEntry(post: *const Post, w: *Writer) Writer.Error!void {
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
    , .{
        post.meta.name,
        post.meta.title,
        post.meta.created_at,
        post.meta.description,
    });
}

fn parsePost(post: *Post, gpa: Allocator) !void {
    var rest = post.source;
    while (std.mem.indexOfScalar(
        u8,
        rest,
        '\n',
    )) |nl| {
        var line = rest[0..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        rest = rest[nl + 1 ..];
        if (!parseHeader(post, line)) break;
    } else {
        _ = parseHeader(post, rest);
        rest = "";
    }

    try post.validate();
    post.body = rest;
    try post.renderBody(gpa, &.{});
}

fn renderBody(
    post: *Post,
    gpa: Allocator,
    thumbnail_paths: []const []const u8,
) !void {
    const asset_url_prefix = try std.fmt.allocPrint(
        gpa,
        "/{s}/{s}/assets/",
        .{
            if (post.meta.draft) "draft" else "post",
            post.meta.name,
        },
    );
    defer gpa.free(asset_url_prefix);
    const thumbnail_url_prefix = try std.fmt.allocPrint(
        gpa,
        "/{s}/{s}/thumbnails/",
        .{
            if (post.meta.draft) "draft" else "post",
            post.meta.name,
        },
    );
    defer gpa.free(thumbnail_url_prefix);
    const footnote_id_prefix = try std.fmt.allocPrint(
        gpa,
        "post-{d}-",
        .{post.id},
    );
    defer gpa.free(footnote_id_prefix);
    const parsed_html = try markdown.toHtmlWithOptions(
        gpa,
        post.body,
        .{
            .asset_url_prefix = asset_url_prefix,
            .thumbnail_url_prefix = thumbnail_url_prefix,
            .thumbnail_paths = thumbnail_paths,
            .footnote_id_prefix = footnote_id_prefix,
        },
    );
    gpa.free(post.parsed_html);
    post.parsed_html = parsed_html;
}

fn parseHeader(post: *Post, line: []const u8) bool {
    const trimmed = std.mem.trim(
        u8,
        line,
        " \t",
    );
    if (std.mem.eql(
        u8,
        trimmed,
        "---",
    )) {
        return false;
    } else if (std.mem.startsWith(
        u8,
        line,
        "Name:",
    )) {
        post.meta.name = trimValue(line["Name:".len..]);
    } else if (std.mem.startsWith(
        u8,
        line,
        "Title:",
    )) {
        post.meta.title = trimValue(line["Title:".len..]);
    } else if (std.mem.startsWith(
        u8,
        line,
        "Draft:",
    )) {
        post.meta.draft = !std.mem.eql(
            u8,
            trimValue(line["Draft:".len..]),
            "false",
        );
    } else if (std.mem.startsWith(
        u8,
        line,
        "Description:",
    )) {
        post.meta.description = trimValue(line["Description:".len..]);
    } else if (std.mem.startsWith(
        u8,
        line,
        "Publish Date:",
    )) {
        post.meta.created_at = trimValue(line["Publish Date:".len..]);
    } else if (std.mem.startsWith(
        u8,
        line,
        "Updated Date:",
    )) {
        post.meta.updated_at = trimValue(line["Updated Date:".len..]);
    }
    return true;
}

fn validate(post: *Post) ValidationError!void {
    if (std.mem.eql(
        u8,
        post.meta.name,
        placeholder_text,
    )) {
        return error.MissingName;
    }
    if (std.mem.eql(
        u8,
        post.meta.title,
        placeholder_text,
    )) {
        return error.MissingTitle;
    }
    if (std.mem.eql(
        u8,
        post.meta.description,
        placeholder_text,
    )) {
        return error.MissingDescription;
    }
}

fn trimValue(raw_value: []const u8) []const u8 {
    return std.mem.trim(
        u8,
        raw_value,
        " \t",
    );
}

fn freeThumbnailPaths(gpa: Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| gpa.free(path);
    paths.deinit(gpa);
    paths.* = undefined;
}

test "posts copy sibling assets recursively and render published and draft URLs" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    image.init();
    defer image.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "posts/0042-post/nested");
    try tmp.dir.writeFile(io, .{
        .sub_path = "posts/0042-post/screen.png",
        .data = @embedFile("../test_data/thumbnail.png"),
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "posts/0042-post/nested/demo.mp4",
        .data = "video\x00\xffbytes",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/notes.txt", .data = "Not a post" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "posts/0041-no-assets.md",
        .data = "Name: no-assets\nTitle: Plain\nDescription: No media\n---\nHello\n",
    });

    const posts_path = try Io.Dir.path.join(gpa, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "posts",
    });
    defer gpa.free(posts_path);
    const output_path = try Io.Dir.path.join(gpa, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "output",
    });
    defer gpa.free(output_path);

    for ([_]bool{ false, true }) |draft| {
        const source = try std.fmt.allocPrint(
            gpa,
            "Name: custom-slug\nTitle: Media\nDescription: Test\nDraft: {s}\n---\n" ++
                "![Screen](screen.png)\n\n![Demo](./nested/demo.mp4)\n",
            .{if (draft) "true" else "false"},
        );
        defer gpa.free(source);
        try tmp.dir.writeFile(io, .{ .sub_path = "posts/0042-post.md", .data = source });

        var posts: Posts = .{};
        try posts.init(
            gpa,
            io,
            posts_path,
        );
        defer posts.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), posts.list.items.len);
        const post = &posts.list.items[0];
        const expected_image = try std.fmt.allocPrint(
            gpa,
            "<img src=\"/{s}/custom-slug/assets/screen.png\" alt=\"Screen\" />",
            .{if (draft) "draft" else "post"},
        );
        defer gpa.free(expected_image);
        try testing.expect(std.mem.indexOf(
            u8,
            post.parsed_html,
            expected_image,
        ) != null);
        const expected_video = try std.fmt.allocPrint(
            gpa,
            "<video controls preload=\"metadata\" src=\"/{s}/custom-slug/assets/nested/demo.mp4\"",
            .{if (draft) "draft" else "post"},
        );
        defer gpa.free(expected_video);
        try testing.expect(std.mem.indexOf(
            u8,
            post.parsed_html,
            expected_video,
        ) != null);

        var thumbnail_paths = try post.buildAssets(
            gpa,
            io,
            output_path,
        );
        defer freeThumbnailPaths(gpa, &thumbnail_paths);
        try post.renderBody(gpa, thumbnail_paths.items);
        const expected_thumbnail = try std.fmt.allocPrint(
            gpa,
            "<a href=\"/{s}/custom-slug/assets/screen.png\">" ++
                "<img src=\"/{s}/custom-slug/thumbnails/screen.png\" alt=\"Screen\" /></a>",
            .{
                if (draft) "draft" else "post",
                if (draft) "draft" else "post",
            },
        );
        defer gpa.free(expected_thumbnail);
        try testing.expect(std.mem.indexOf(
            u8,
            post.parsed_html,
            expected_thumbnail,
        ) != null);
        const thumbnail_bytes = try tmp.dir.readFileAlloc(
            io,
            "output/thumbnails/screen.png",
            gpa,
            .unlimited,
        );
        defer gpa.free(thumbnail_bytes);
        try testing.expect(thumbnail_bytes.len > 0);
        const image_bytes = try tmp.dir.readFileAlloc(
            io,
            "output/assets/screen.png",
            gpa,
            .unlimited,
        );
        defer gpa.free(image_bytes);
        try testing.expectEqualStrings(@embedFile("../test_data/thumbnail.png"), image_bytes);
        const video_bytes = try tmp.dir.readFileAlloc(
            io,
            "output/assets/nested/demo.mp4",
            gpa,
            .limited(1024),
        );
        defer gpa.free(video_bytes);
        try testing.expectEqualStrings("video\x00\xffbytes", video_bytes);
        var empty_paths = try posts.list.items[1].buildAssets(
            gpa,
            io,
            output_path,
        );
        defer freeThumbnailPaths(gpa, &empty_paths);
        try testing.expectEqual(@as(usize, 0), empty_paths.items.len);
    }
}

test "asset workers preserve nested media and recover from output errors" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    image.init();
    defer image.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_path = try Io.Dir.path.join(gpa, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "source",
    });
    defer gpa.free(source_path);
    const output_path = try Io.Dir.path.join(gpa, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "output",
    });
    defer gpa.free(output_path);
    const post: Post = .{ .asset_source_path = source_path };
    const original = @embedFile("../test_data/thumbnail.png");
    const expected_thumbnail = (try image.thumbnail(
        gpa,
        original,
        720,
    )).?;
    defer gpa.free(expected_thumbnail);
    const files = [_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = "one/screen.png", .bytes = original },
        .{ .path = "two/screen.png", .bytes = original },
        .{ .path = "two/deep/screen.png", .bytes = original },
        .{ .path = "two/deep/other.png", .bytes = original },
        .{ .path = "three/screen.png", .bytes = original },
        .{ .path = "three/other.png", .bytes = original },
        .{ .path = "three/small.png", .bytes = expected_thumbnail },
        .{ .path = "three/animated.png", .bytes = @embedFile("../test_data/animated.png") },
        .{ .path = "three/demo.mp4", .bytes = "video\x00\xffbytes" },
    };
    for (files) |file| {
        const path = try Io.Dir.path.join(gpa, &.{ "source", file.path });
        defer gpa.free(path);
        try tmp.dir.createDirPath(io, Io.Dir.path.dirname(path).?);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = file.bytes });
    }

    // Exercise real threads and the fallback used when concurrency is unavailable.
    for ([_]Io.Limit{ .unlimited, .nothing }) |limit| {
        var threaded = Io.Threaded.init(gpa, .{ .async_limit = limit, .concurrent_limit = limit });
        defer threaded.deinit();
        const worker_io = threaded.io();
        try tmp.dir.createDirPath(io, "output");
        // A file blocks the workers' output directory creation without a decoder error log.
        try tmp.dir.writeFile(io, .{ .sub_path = "output/assets", .data = "blocked" });
        try testing.expectError(error.NotDir, post.buildAssets(
            gpa,
            worker_io,
            output_path,
        ));
        try tmp.dir.deleteTree(io, "output");

        var paths = try post.buildAssets(
            gpa,
            worker_io,
            output_path,
        );
        defer freeThumbnailPaths(gpa, &paths);
        try testing.expectEqual(@as(usize, 6), paths.items.len);
        for (files, 0..) |file, index| {
            const copied_path = try Io.Dir.path.join(gpa, &.{
                "output/assets",
                file.path,
            });
            defer gpa.free(copied_path);
            const copied = try tmp.dir.readFileAlloc(
                io,
                copied_path,
                gpa,
                .unlimited,
            );
            defer gpa.free(copied);
            try testing.expectEqualStrings(file.bytes, copied);
            const thumbnail_path = try Io.Dir.path.join(gpa, &.{
                "output/thumbnails",
                file.path,
            });
            defer gpa.free(thumbnail_path);
            if (index >= 6) {
                try testing.expectError(error.FileNotFound, tmp.dir.access(
                    io,
                    thumbnail_path,
                    .{},
                ));
                continue;
            }
            var matches: usize = 0;
            for (paths.items) |path| {
                if (std.mem.eql(u8, path, file.path)) matches += 1;
            }
            try testing.expectEqual(@as(usize, 1), matches);
            const thumbnail = try tmp.dir.readFileAlloc(
                io,
                thumbnail_path,
                gpa,
                .unlimited,
            );
            defer gpa.free(thumbnail);
            // Decoding verifies a complete thumbnail without comparing PNG timestamp metadata.
            const resized = try image.thumbnail(
                gpa,
                thumbnail,
                720,
            );
            defer if (resized) |bytes| gpa.free(bytes);
            try testing.expectEqual(null, resized);
        }
        try tmp.dir.deleteTree(io, "output");
    }
}
