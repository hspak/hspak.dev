//! End-to-end checks for site generation, preview, and live rebuilds.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const test_options = @import("test_options");

const Site = struct {
    dir: Io.Dir = .cwd(),
    log_offset: usize = 0,
    port: u16 = 0,

    const PostOptions = struct {
        name: []const u8 = "test",
        body: []const u8 = "Alpha",
        title: []const u8 = "Test post",
        draft: bool = false,
    };

    const Events = struct {
        client: std.http.Client,
        request: std.http.Client.Request,
        reader: *Io.Reader,
        url_buffer: [128]u8,
        transfer_buffer: [1024]u8,

        const ReadError = Io.Reader.DelimiterError || std.fmt.ParseIntError;

        // The request and reader borrow these buffers, so initialize in their final storage.
        fn init(events: *Events, port: u16) !void {
            events.* = .{
                .client = .{ .allocator = testing.allocator, .io = testing.io },
                .request = undefined,
                .reader = undefined,
                .url_buffer = undefined,
                .transfer_buffer = undefined,
            };
            errdefer events.client.deinit();
            const url = try std.fmt.bufPrint(
                &events.url_buffer,
                "http://127.0.0.1:{d}/__zmd/events",
                .{port},
            );
            events.request = try events.client.request(
                .GET,
                try std.Uri.parse(url),
                .{ .keep_alive = false },
            );
            errdefer events.request.deinit();
            try events.request.sendBodiless();
            var response = try events.request.receiveHead(&.{});
            try testing.expectEqual(.ok, response.head.status);
            events.reader = response.reader(&events.transfer_buffer);
        }

        fn deinit(events: *Events) void {
            events.request.deinit();
            events.client.deinit();
            events.* = undefined;
        }

        fn readRevision(events: *Events) ReadError!u64 {
            while (try events.reader.takeDelimiter('\n')) |line| {
                if (!std.mem.startsWith(u8, line, "data: ")) continue;
                return std.fmt.parseInt(u64, line[6..], 10);
            }
            return error.EndOfStream;
        }

        fn next(events: *Events) !u64 {
            const Completion = union(enum) {
                revision: ReadError!u64,
                timeout: Io.Cancelable!void,
            };
            var completions: [2]Completion = undefined;
            var completion: Io.Select(Completion) = .init(testing.io, &completions);
            defer completion.cancelDiscard();
            try completion.concurrent(.revision, readRevision, .{events});
            completion.async(
                .timeout,
                Io.sleep,
                .{
                    testing.io,
                    .fromSeconds(5),
                    .awake,
                },
            );
            return switch (try completion.await()) {
                .revision => |received| try received,
                .timeout => |result| {
                    try result;
                    return error.WatchTimeout;
                },
            };
        }
    };

    fn read(site: Site, path: []const u8) ![]u8 {
        return site.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
    }

    fn write(site: Site, path: []const u8, data: []const u8) !void {
        try site.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn writePost(site: Site, path: []const u8, options: PostOptions) !void {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "Name: {s}\nTitle: {s}\nDescription: Preview\nDraft: {s}\n" ++
                "Publish Date: 2026-09-05\n---\n{s}\n",
            .{
                options.name,
                options.title,
                if (options.draft) "true" else "false",
                options.body,
            },
        );
        defer testing.allocator.free(source);
        try site.write(path, source);
    }

    fn expectText(site: Site, path: []const u8, expected: []const u8) !void {
        const content = try site.read(path);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, expected) != null);
    }

    fn expectAbsent(site: Site, path: []const u8, unexpected: []const u8) !void {
        const content = try site.read(path);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, unexpected) == null);
    }

    // Keep the markup assertions while allowing the build's variable version parameter.
    fn expectVersionedText(
        site: Site,
        path: []const u8,
        comptime template: []const u8,
        asset_path: []const u8,
    ) !void {
        const content = try site.read(path);
        defer testing.allocator.free(content);
        const start = (std.mem.indexOf(
            u8,
            content,
            "?v=",
        ) orelse return error.MissingAssetVersion) + "?v=".len;
        const version = content[start .. start + 64];
        const url = try std.fmt.allocPrint(
            testing.allocator,
            "{s}?v={s}",
            .{ asset_path, version },
        );
        defer testing.allocator.free(url);
        const expected = try std.fmt.allocPrint(testing.allocator, template, .{url});
        defer testing.allocator.free(expected);
        try testing.expect(std.mem.indexOf(u8, content, expected) != null);
    }

    fn expectMissing(site: Site, path: []const u8) !void {
        try testing.expectError(error.FileNotFound, site.dir.statFile(testing.io, path, .{}));
    }

    fn preview(site: Site, path: []const u8, event: bool) ![]u8 {
        var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
        defer client.deinit();
        var url_buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buffer,
            "http://127.0.0.1:{d}{s}",
            .{ site.port, path },
        );
        var request = try client.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
        defer request.deinit();
        try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        try testing.expectEqual(.ok, response.head.status);
        var buffer: [4096]u8 = undefined;
        const reader = response.reader(&buffer);
        if (event) return testing.allocator.dupe(u8, try reader.takeDelimiterExclusive('\n'));
        return reader.allocRemaining(testing.allocator, .limited(1024 * 1024));
    }

    fn revision(site: Site) !u64 {
        const event = try site.preview("/__zmd/events", true);
        defer testing.allocator.free(event);
        try testing.expect(std.mem.startsWith(u8, event, "data: "));
        return std.fmt.parseInt(u64, event[6..], 10);
    }

    fn expectPreview(site: Site, path: []const u8, expected: []const u8) !void {
        const content = try site.preview(path, false);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, expected) != null);
    }

    fn stylesheetUrl(site: Site) ![]u8 {
        const html = try site.read("docs/index.html");
        defer testing.allocator.free(html);
        const attribute = "<link rel=\"stylesheet\" href=\"";
        const start = (std.mem.indexOf(
            u8,
            html,
            attribute,
        ) orelse return error.MissingStylesheet) + attribute.len;
        const end = std.mem.indexOfScalarPos(
            u8,
            html,
            start,
            '"',
        ) orelse return error.MissingStylesheet;
        return testing.allocator.dupe(u8, html[start..end]);
    }

    fn waitFor(site: *Site, expected: []const u8) !void {
        const deadline = Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(8));
        while (Io.Clock.awake.now(testing.io).nanoseconds < deadline.nanoseconds) {
            const content = try site.read("watch.log");
            defer testing.allocator.free(content);
            if (std.mem.indexOfPos(u8, content, site.log_offset, expected)) |offset| {
                site.log_offset = offset + expected.len;
                return;
            }
            try Io.sleep(testing.io, .fromMilliseconds(50), .awake);
        }
        const content = try site.read("watch.log");
        defer testing.allocator.free(content);
        std.debug.print("Timed out waiting for {s}:\n{s}\n", .{ expected, content });
        return error.WatchTimeout;
    }
};

test "cache busting versions URLs without retaining asset copies" {
    if (comptime builtin.os.tag == .windows or !std.process.can_spawn) {
        return error.SkipZigTest;
    }
    const site_builder = struct {
        fn build(dir: Io.Dir, executable: []const u8) !void {
            const io = testing.io;
            const file = try dir.createFile(io, "build.log", .{});
            defer file.close(io);
            var child = try std.process.spawn(io, .{
                .argv = &.{
                    executable,
                    "--port",
                    "0",
                },
                .cwd = .{ .dir = dir },
                .stdin = .ignore,
                .stdout = .{ .file = file },
                .stderr = .{ .file = file },
            });
            defer child.kill(io);
            const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(8));
            while (Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
                const output = try dir.readFileAlloc(
                    io,
                    "build.log",
                    testing.allocator,
                    .unlimited,
                );
                defer testing.allocator.free(output);
                if (std.mem.indexOf(u8, output, "build complete") != null) return;
                if (std.mem.indexOf(u8, output, "build failed") != null) {
                    std.debug.print("{s}\n", .{output});
                    return error.InvalidSite;
                }
                try Io.sleep(io, .fromMilliseconds(25), .awake);
            }
            const output = try dir.readFileAlloc(io, "build.log", testing.allocator, .unlimited);
            defer testing.allocator.free(output);
            std.debug.print("{s}\n", .{output});
            return error.BuildTimeout;
        }

        fn read(dir: Io.Dir, path: []const u8) ![]u8 {
            return dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
        }

        fn url(html: []const u8, suffix: []const u8) ![]const u8 {
            const end = std.mem.indexOf(u8, html, suffix) orelse return error.MissingAssetUrl;
            const start = (std.mem.lastIndexOfScalar(u8, html[0..end], '"') orelse
                return error.MissingAssetUrl) + 1;
            const close = std.mem.indexOfScalarPos(
                u8,
                html,
                end + suffix.len,
                '"',
            ) orelse return error.MissingAssetUrl;
            return html[start..close];
        }

        fn expectAsset(dir: Io.Dir, asset_url: []const u8, expected: []const u8) !void {
            const end = std.mem.indexOfAny(u8, asset_url, "?#") orelse asset_url.len;
            const path = try std.fmt.allocPrint(testing.allocator, "docs{s}", .{asset_url[0..end]});
            defer testing.allocator.free(path);
            const bytes = try read(dir, path);
            defer testing.allocator.free(bytes);
            try testing.expectEqualStrings(expected, bytes);
        }
    };
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/fonts/test");
    try tmp.dir.createDirPath(io, "posts/0001-test");
    const css = "@font-face { src: url(\"fonts/test/font.woff2\"); } body { color: red; }";
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/index.css", .data = css });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/theme.js", .data = "// theme one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/fonts/test/font.woff2", .data = "font one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/0001-test/clip.mp4", .data = "video one" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "posts/0001-test.md",
        .data = "Name: test\nTitle: Test\nDescription: Test\nDraft: false\n---\n" ++
            "![Clip](clip.mp4?download=1#t=2)\n\n`href=\"/index.css\"`\n",
    });
    const executable = try Io.Dir.cwd().realPathFileAlloc(io, test_options.zmd_path, gpa);
    defer gpa.free(executable);
    try site_builder.build(tmp.dir, executable);
    const first = try site_builder.read(tmp.dir, "docs/post/test/index.html");
    defer gpa.free(first);
    const first_css = try site_builder.url(first, ".css");
    try testing.expect(std.mem.startsWith(u8, first_css, "/site.css?v="));
    const first_video = try site_builder.url(first, "/post/test/assets/clip.mp4");
    try testing.expect(std.mem.startsWith(
        u8,
        first_video,
        "/post/test/assets/clip.mp4?download=1&amp;v=",
    ));
    try testing.expect(std.mem.endsWith(u8, first_video, "#t=2"));
    try site_builder.expectAsset(tmp.dir, first_video, "video one");
    try testing.expect(std.mem.indexOf(
        u8,
        first,
        "<code>href=&quot;/index.css&quot;</code>",
    ) != null);
    const first_stylesheet = try site_builder.read(tmp.dir, "docs/site.css");
    defer gpa.free(first_stylesheet);
    const first_font = try site_builder.url(first_stylesheet, "fonts/test/font.woff2");
    try testing.expect(std.mem.startsWith(u8, first_font, "fonts/test/font.woff2?v="));
    try testing.expectEqualStrings(first_css["/site.css?v=".len..], first_font["fonts/test/font.woff2?v=".len..]);
    const source_css = try site_builder.read(tmp.dir, "docs/index.css");
    defer gpa.free(source_css);
    try testing.expectEqualStrings(css, source_css);

    try site_builder.build(tmp.dir, executable);
    const same = try site_builder.read(tmp.dir, "docs/post/test/index.html");
    defer gpa.free(same);
    try testing.expectEqualStrings(first, same);
    const same_stylesheet = try site_builder.read(tmp.dir, "docs/site.css");
    defer gpa.free(same_stylesheet);
    try testing.expectEqualStrings(first_stylesheet, same_stylesheet);

    // Equal-size edits with unchanged timestamps must still invalidate URLs, including CSS fonts.
    const font_stat = try tmp.dir.statFile(io, "docs/fonts/test/font.woff2", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/fonts/test/font.woff2", .data = "font two" });
    try tmp.dir.setTimestamps(
        io,
        "docs/fonts/test/font.woff2",
        .{
            .modify_timestamp = .{ .new = font_stat.mtime },
        },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/theme.js", .data = "// theme two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/0001-test/clip.mp4", .data = "video two" });
    try site_builder.build(tmp.dir, executable);
    const second = try site_builder.read(tmp.dir, "docs/post/test/index.html");
    defer gpa.free(second);
    const second_css = try site_builder.url(second, ".css");
    const second_video = try site_builder.url(second, "/post/test/assets/clip.mp4");
    try testing.expect(!std.mem.eql(u8, first_css, second_css));
    try testing.expect(!std.mem.eql(u8, first_video, second_video));
    try site_builder.expectAsset(tmp.dir, second_video, "video two");
    // Query versions change cache keys; the server keeps only the current bytes at each path.
    try site_builder.expectAsset(tmp.dir, first_video, "video two");
    const second_stylesheet = try site_builder.read(tmp.dir, "docs/site.css");
    defer gpa.free(second_stylesheet);
    const second_font = try site_builder.url(second_stylesheet, "fonts/test/font.woff2");
    try testing.expect(!std.mem.eql(u8, first_font, second_font));
    try testing.expectEqualStrings(second_css["/site.css?v=".len..], second_font["fonts/test/font.woff2?v=".len..]);
    try site_builder.expectAsset(tmp.dir, try site_builder.url(second, "/theme.js"), "// theme two");
    const index = try site_builder.read(tmp.dir, "docs/index.html");
    defer gpa.free(index);
    try testing.expectEqualStrings(second_css, try site_builder.url(index, ".css"));
    const feed = try site_builder.read(tmp.dir, "docs/feed.xml");
    defer gpa.free(feed);
    const feed_video = try std.mem.replaceOwned(u8, gpa, second_video, "&", "&amp;");
    defer gpa.free(feed_video);
    try testing.expect(std.mem.indexOf(u8, feed, feed_video) != null);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "docs/versioned", .{}));
}

test "watch rebuilds the site and recovers from invalid posts" {
    if (comptime builtin.os.tag == .windows or !std.process.can_spawn) {
        return error.SkipZigTest;
    }

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var site: Site = .{ .dir = tmp.dir };
    try tmp.dir.createDirPath(io, "posts");
    const source = "posts/0001-test.md";
    const page = "docs/post/test/index.html";
    const feed = "docs/feed.xml";
    const index = "docs/index.html";
    const image_source = "posts/0001-test/nested/screen.png";
    const image_original = "docs/post/test/assets/nested/screen.png";
    const image_thumbnail = "docs/post/test/thumbnails/nested/screen.png";
    try tmp.dir.createDirPath(io, "posts/0001-test/nested");
    try site.write(image_source, @embedFile("test_data/thumbnail.png"));
    try site.writePost(source, .{});
    const batch_count = 20;
    for (0..batch_count) |number| {
        var path_buffer: [128]u8 = undefined;
        const directory = try std.fmt.bufPrint(
            &path_buffer,
            "posts/{d}-batch/nested",
            .{1000 + number},
        );
        try tmp.dir.createDirPath(io, directory);
        const asset_path = try std.fmt.bufPrint(
            &path_buffer,
            "posts/{d}-batch/nested/screen.png",
            .{1000 + number},
        );
        try site.write(asset_path, @embedFile("test_data/thumbnail.png"));
        const post_path = try std.fmt.bufPrint(
            &path_buffer,
            "posts/{d}-batch.md",
            .{1000 + number},
        );
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "batch-{d}", .{number});
        try site.writePost(post_path, .{
            .name = name,
            .body = "![Batch image](nested/screen.png)",
            .draft = number % 2 == 0,
        });
    }
    const log_file = try tmp.dir.createFile(io, "watch.log", .{});
    defer log_file.close(io);
    const executable = try Io.Dir.cwd().realPathFileAlloc(
        io,
        test_options.zmd_path,
        testing.allocator,
    );
    defer testing.allocator.free(executable);
    var child = try std.process.spawn(io, .{
        .argv = &.{
            executable,
            "--port",
            "0",
        },
        .cwd = .{ .dir = tmp.dir },
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    });
    defer child.kill(io);

    try site.waitFor("watching posts/");
    {
        const content = try site.read("watch.log");
        defer testing.allocator.free(content);
        const prefix = "http://127.0.0.1:";
        const start = (std.mem.indexOf(
            u8,
            content,
            prefix,
        ) orelse return error.MissingAddress) + prefix.len;
        const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        site.port = try std.fmt.parseInt(u16, content[start..end], 10);
    }
    const initial_revision = try site.revision();
    var first_tab: Site.Events = undefined;
    try first_tab.init(site.port);
    defer first_tab.deinit();
    try testing.expectEqual(initial_revision, try first_tab.next());
    var second_tab: Site.Events = undefined;
    try second_tab.init(site.port);
    defer second_tab.deinit();
    try testing.expectEqual(initial_revision, try second_tab.next());
    try site.expectPreview("/", "Test post");
    try site.expectPreview("/post/test/", "Alpha");
    try site.expectPreview("/post/test/", "/__zmd/reload.js");
    try site.expectAbsent(page, "/__zmd/");
    try site.expectText(page, "Alpha");
    try site.expectText(feed, "Alpha");
    try site.expectText(index, "Test post");
    const initial_thumbnail = try site.read(image_thumbnail);
    defer testing.allocator.free(initial_thumbnail);
    for (0..batch_count) |number| {
        const kind = if (number % 2 == 0) "draft" else "post";
        var path_buffer: [128]u8 = undefined;
        const batch_page = try std.fmt.bufPrint(
            &path_buffer,
            "docs/{s}/batch-{d}/index.html",
            .{ kind, number },
        );
        var url_buffer: [128]u8 = undefined;
        const thumbnail_url = try std.fmt.bufPrint(
            &url_buffer,
            "/{s}/batch-{d}/thumbnails/nested/screen.png",
            .{ kind, number },
        );
        try site.expectText(batch_page, thumbnail_url);
        if (number % 2 == 0) {
            try site.expectAbsent(feed, thumbnail_url);
        } else {
            try site.expectText(feed, thumbnail_url);
        }
        const batch_thumbnail = try std.fmt.bufPrint(&path_buffer, "docs{s}", .{thumbnail_url});
        const thumbnail = try site.read(batch_thumbnail);
        defer testing.allocator.free(thumbnail);
        try testing.expectEqualStrings(initial_thumbnail, thumbnail);
    }
    try tmp.dir.setTimestamps(io, image_thumbnail, .{ .modify_timestamp = .{ .new = .zero } });
    try Io.sleep(io, .fromMilliseconds(800), .awake);
    {
        const content = try site.read("watch.log");
        defer testing.allocator.free(content);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "build complete"));
    }

    try site.writePost(source, .{ .body = "Bravo", .title = "Edited post" });
    try site.waitFor("build complete");
    try site.expectText(page, "Bravo");
    try site.expectText(feed, "Bravo");
    try site.expectText(index, "Edited post");
    try site.expectPreview("/post/test/", "Bravo");
    const reused_thumbnail = try site.read(image_thumbnail);
    defer testing.allocator.free(reused_thumbnail);
    try testing.expectEqualStrings(initial_thumbnail, reused_thumbnail);
    const thumbnail_stat = try tmp.dir.statFile(io, image_thumbnail, .{});
    try testing.expectEqual(Io.Timestamp.zero, thumbnail_stat.mtime);
    try testing.expectEqual(initial_revision +% 1, try site.revision());
    try testing.expectEqual(initial_revision +% 1, try first_tab.next());
    try testing.expectEqual(initial_revision +% 1, try second_tab.next());

    // Editors can replace a file while preserving its length and timestamp.
    const stat = try tmp.dir.statFile(io, source, .{});
    try site.writePost("posts/save.tmp", .{ .body = "Gamma", .title = "Edited post" });
    try tmp.dir.setTimestamps(
        io,
        "posts/save.tmp",
        .{ .modify_timestamp = .{ .new = stat.mtime } },
    );
    try tmp.dir.rename("posts/save.tmp", tmp.dir, source, io);
    try site.waitFor("build complete");
    try site.expectText(page, "Gamma");

    const asset = "posts/0001-test/nested/demo.mp4";
    const copied = "docs/post/test/assets/nested/demo.mp4";
    try tmp.dir.createDirPath(io, "posts/0001-test/nested");
    try site.write(asset, "video one");
    try site.writePost(source, .{ .body = "![Demo](nested/demo.mp4)" });
    try site.waitFor("build complete");
    try site.expectText(copied, "video one");
    try site.expectText(page, "<video controls preload=\"metadata\"");
    try site.writePost(source, .{
        .body = "![Demo](nested/demo.mp4 \"Build & run\"){gif}",
    });
    try site.waitFor("build complete");
    try site.expectVersionedText(page, "<figure>\n<video autoplay loop muted playsinline " ++
        "src=\"{s}\" aria-label=\"Demo\"", "/post/test/assets/nested/demo.mp4");
    try site.expectText(page, "<figcaption>Build &amp; run</figcaption>");
    try site.expectVersionedText(page, "<a href=\"{s}\">Demo</a>", "/post/test/assets/nested/demo.mp4");
    try site.expectAbsent(page, "<video controls");
    try site.expectAbsent(page, "{gif}");
    try site.expectText(feed, "&lt;video autoplay loop muted playsinline");
    try site.expectVersionedText(feed, "src=&quot;{s}&quot;", "/post/test/assets/nested/demo.mp4");
    try site.expectPreview("/post/test/", "<video autoplay loop muted playsinline");
    try site.write(asset, "video two");
    try site.waitFor("build complete");
    try site.expectText(copied, "video two");
    try tmp.dir.deleteFile(io, asset);
    try site.waitFor("build complete");
    try site.expectMissing(copied);

    // Replace an image while preserving its timestamp to require content-based invalidation.
    const image_stat = try tmp.dir.statFile(io, image_source, .{});
    try site.write(image_source, initial_thumbnail);
    try tmp.dir.setTimestamps(
        io,
        image_source,
        .{ .modify_timestamp = .{ .new = image_stat.mtime } },
    );
    try site.writePost(source, .{ .body = "![Screen](nested/screen.png)" });
    try site.waitFor("build complete");
    try site.expectMissing(image_thumbnail);
    try site.expectText(image_original, initial_thumbnail);
    try site.expectVersionedText(page, "src=\"{s}\"", "/post/test/assets/nested/screen.png");

    try site.write(image_source, @embedFile("test_data/thumbnail.png"));
    try site.waitFor("build complete");
    try site.expectText(image_thumbnail, initial_thumbnail);
    try site.expectVersionedText(page, "src=\"{s}\"", "/post/test/thumbnails/nested/screen.png");
    try site.expectVersionedText(feed, "src=&quot;{s}&quot;", "/post/test/thumbnails/nested/screen.png");

    try tmp.dir.deleteFile(io, image_thumbnail);
    try site.writePost(source, .{ .body = "Rebuild missing thumbnail. ![Screen](nested/screen.png)" });
    try site.waitFor("build complete");
    try site.expectText(image_thumbnail, initial_thumbnail);

    try tmp.dir.deleteTree(io, "posts/0001-test");
    try site.waitFor("build complete");
    try site.expectMissing(image_thumbnail);
    try site.expectMissing(image_original);

    // A post worker failure must prevent publication and leave no workers alive on retry.
    const batch_revision = try site.revision();
    const batch_image = "posts/1001-batch/nested/screen.png";
    try site.write(batch_image, "invalid image");
    try site.waitFor("build failed: ImageMagickException");
    try testing.expectEqual(batch_revision, try site.revision());
    try site.write(batch_image, @embedFile("test_data/thumbnail.png"));
    try site.waitFor("build complete");
    try testing.expectEqual(batch_revision +% 1, try site.revision());
    try site.expectText("docs/post/batch-1/thumbnails/nested/screen.png", initial_thumbnail);

    try site.writePost("posts/0999-duplicate.md", .{ .name = "batch-1" });
    try site.waitFor("build failed: DuplicatePostPath");
    try testing.expectEqual(batch_revision +% 1, try site.revision());
    try tmp.dir.deleteFile(io, "posts/0999-duplicate.md");
    for (0..batch_count) |number| {
        var path_buffer: [128]u8 = undefined;
        const post_path = try std.fmt.bufPrint(
            &path_buffer,
            "posts/{d}-batch.md",
            .{1000 + number},
        );
        try tmp.dir.deleteFile(io, post_path);
        const directory = try std.fmt.bufPrint(&path_buffer, "posts/{d}-batch", .{1000 + number});
        try tmp.dir.deleteTree(io, directory);
    }
    try site.waitFor("build complete");
    try site.expectMissing("docs/post/batch-1");
    try site.expectMissing("docs/draft/batch-0");

    try site.writePost(source, .{
        .body = "Fast build.[^timing] Another run.[^timing]\n\n" ++
            "[^timing]: Measured on a **warm cache**.\n\n" ++
            "    Second paragraph with [details](https://example.com).",
    });
    try site.waitFor("build complete");
    try site.expectText(page, "id=\"fnref-post-1-1-1\" href=\"#fn-post-1-1\"");
    try site.expectText(page, "id=\"fnref-post-1-1-2\" href=\"#fn-post-1-1\"");
    try site.expectText(page, "<li id=\"fn-post-1-1\" tabindex=\"-1\">");
    try site.expectText(page, "href=\"#fnref-post-1-1-1\" role=\"doc-backlink\"");
    try site.expectText(page, "href=\"#fnref-post-1-1-2\" role=\"doc-backlink\"");
    try site.expectText(page, "Measured on a <strong>warm cache</strong>.");
    try site.expectText(page, "<p>Second paragraph with <a href=\"https://example.com\">");
    try site.expectText(page, "details</a>.&#160;<span class=\"footnote-backlinks\">");
    try site.expectText(feed, "href=&quot;https://hspak.dev/post/test/#fn-post-1-1&quot;");
    try site.expectText(feed, "href=&quot;https://hspak.dev/post/test/#fnref-post-1-1-2&quot;");
    try site.expectPreview("/post/test/", "href=\"#fnref-post-1-1-2\"");

    const added = "posts/0002-added.md";
    const renamed = "posts/0003-renamed.md";
    try site.writePost(added, .{
        .name = "added",
        .body = "New post[^timing].\n\n[^timing]: Another post's note.",
    });
    try site.waitFor("build complete");
    try site.expectText("docs/post/added/index.html", "New post");
    try site.expectText("docs/post/added/index.html", "id=\"fn-post-2-1\"");
    try site.expectText(feed, "href=&quot;https://hspak.dev/post/added/#fn-post-2-1&quot;");
    try site.expectText(index, "/post/added/");
    try site.writePost(added, .{ .name = "renamed", .body = "Renamed post" });
    try tmp.dir.rename(added, tmp.dir, renamed, io);
    try site.waitFor("build complete");
    try site.expectMissing("docs/post/added");
    try site.expectText("docs/post/renamed/index.html", "Renamed post");
    try tmp.dir.deleteFile(io, renamed);
    try site.waitFor("build complete");
    try site.expectMissing("docs/post/renamed");
    try site.expectAbsent(index, "/post/renamed/");

    const draft = "posts/9000-draft.md";
    try site.writePost(draft, .{
        .name = "draft",
        .body = "Draft body[^note].\n\n[^note]: Draft note.",
        .draft = true,
    });
    try site.waitFor("build complete");
    try site.expectText("docs/draft/draft/index.html", "Draft body");
    try site.expectText("docs/draft/draft/index.html", "href=\"#fnref-post-9000-1-1\"");
    try site.expectAbsent(feed, "Draft body");
    try site.expectAbsent(feed, "Draft note");
    try tmp.dir.deleteFile(io, draft);
    try site.waitFor("build complete");
    try site.expectMissing("docs/draft/draft");

    const before_failure = try site.revision();
    try site.write(source, "Name: test\nDescription: Incomplete\n---\nSaving...\n");
    try site.waitFor("build failed: MissingTitle");
    try testing.expectEqual(before_failure, try site.revision());
    try site.writePost(source, .{ .body = "Recovered" });
    try site.waitFor("build complete");
    try site.expectText(page, "Recovered");
    try testing.expectEqual(before_failure +% 1, try site.revision());
    try site.expectPreview("/post/test/", "Recovered");
    try site.write("posts/.md", "Incomplete");
    try site.waitFor("InvalidPostFilename");
    try tmp.dir.deleteFile(io, "posts/.md");
    try site.waitFor("build complete");

    try tmp.dir.deleteFile(io, source);
    try site.waitFor("build complete");
    try site.expectMissing(page);
    try site.expectAbsent(index, "/post/test/");
    try site.expectAbsent(feed, "<entry>");
    try site.expectText(feed, "<feed xmlns=\"http://www.w3.org/2005/Atom\">");
    try site.expectText(feed, "</feed>");
    try site.writePost(source, .{ .body = "Back again" });
    try site.waitFor("build complete");
    try site.expectText(page, "Back again");

    try tmp.dir.rename("posts", tmp.dir, "old-posts", io);
    try site.waitFor("cannot scan posts/: FileNotFound");
    try tmp.dir.createDirPath(io, "posts");
    try site.writePost(source, .{ .body = "New directory" });
    try site.waitFor("build complete");
    try site.expectText(page, "New directory");

    // CSS starts absent, as in a new preview directory. Adding it must trigger a rebuild.
    const first_css = "body { color: red; }";
    const next_css = "body { color: tan; }";
    try site.write("docs/index.css", first_css);
    try site.waitFor("build complete");
    const first_css_url = try site.stylesheetUrl();
    defer testing.allocator.free(first_css_url);
    try site.expectPreview(first_css_url, first_css);
    const css_revision = try site.revision();
    var css_tab: Site.Events = undefined;
    try css_tab.init(site.port);
    defer css_tab.deinit();
    try testing.expectEqual(css_revision, try css_tab.next());

    // Editors commonly replace the file atomically; size and mtime may stay unchanged.
    const css_stat = try tmp.dir.statFile(io, "docs/index.css", .{});
    try site.write("docs/style.tmp", next_css);
    try tmp.dir.setTimestamps(
        io,
        "docs/style.tmp",
        .{ .modify_timestamp = .{ .new = css_stat.mtime } },
    );
    try tmp.dir.rename("docs/style.tmp", tmp.dir, "docs/index.css", io);
    try site.waitFor("build complete");
    try testing.expectEqual(css_revision +% 1, try css_tab.next());
    const next_css_url = try site.stylesheetUrl();
    defer testing.allocator.free(next_css_url);
    try testing.expect(!std.mem.eql(u8, first_css_url, next_css_url));
    try site.expectPreview(next_css_url, next_css);
    try site.expectPreview(first_css_url, next_css);
    try site.expectPreview("/post/test/", next_css_url);

    try tmp.dir.deleteFile(io, "docs/index.css");
    try site.waitFor("build complete");
    try testing.expectEqual(css_revision +% 2, try css_tab.next());
    try site.write("docs/index.css", first_css);
    try site.waitFor("build complete");
    try testing.expectEqual(css_revision +% 3, try css_tab.next());
    try site.expectPreview("/", first_css_url);
    // Generated pages and site.css must not trigger another rebuild.
    try Io.sleep(io, .fromMilliseconds(800), .awake);
    try testing.expectEqual(css_revision +% 3, try site.revision());

    try std.posix.kill(child.id.?, .INT);
    const Completion = union(enum) {
        term: std.process.Child.WaitError!std.process.Child.Term,
        timeout: Io.Cancelable!void,
    };
    var completions: [2]Completion = undefined;
    var completion: Io.Select(Completion) = .init(io, &completions);
    defer completion.cancelDiscard();
    try completion.concurrent(.term, std.process.Child.wait, .{ &child, io });
    completion.async(
        .timeout,
        Io.sleep,
        .{
            io,
            .fromSeconds(5),
            .awake,
        },
    );
    switch (try completion.await()) {
        .term => |term| try testing.expectEqual(std.process.Child.Term{ .signal = .INT }, try term),
        .timeout => |result| {
            try result;
            return error.WatchTimeout;
        },
    }
}
