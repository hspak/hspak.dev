//! Static site generator for hspak.dev.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;
const Atom = @import("Atom.zig");
const Posts = @import("Posts.zig");
const Server = @import("Server.zig");
const Watch = @import("Watch.zig");
const image = @import("image.zig");
const markdown = @import("markdown.zig");
const partials = @import("partials.zig");
const time = @import("time.zig");
const test_options = if (builtin.is_test) @import("test_options") else struct {};

const log = std.log.scoped(.main);

const LoopError = Io.Cancelable || Allocator.Error;
const MainError = LoopError || Watch.Error || Server.InitError || Server.RunError ||
    Io.Dir.CreateDirPathError || Io.Dir.OpenError || Io.File.Writer.Error || error{
    MissingPort,
    InvalidPort,
    InvalidArgument,
};

pub fn main(init: std.process.Init) MainError!void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    var port: u16 = 8000;
    while (args.next()) |arg| {
        if (std.mem.eql(
            u8,
            arg,
            "--port",
        )) {
            const value = args.next() orelse return error.MissingPort;
            port = std.fmt.parseInt(
                u16,
                value,
                10,
            ) catch return error.InvalidPort;
        } else if (std.mem.eql(
            u8,
            arg,
            "--help",
        )) {
            try Io.File.stdout().writeStreamingAll(
                init.io,
                "Usage: zmd [--port PORT]\n" ++
                    "Build posts/, serve docs/ on 127.0.0.1:8000, and watch for changes.\n",
            );
            return;
        } else {
            log.err("unknown argument: {s}; usage: zmd [--port PORT]", .{arg});
            return error.InvalidArgument;
        }
    }
    image.init();
    defer image.deinit();

    // Snapshot before rendering so edits made during a build are picked up too.
    var watch: Watch = .{ .path = "posts" };
    try watch.init(init.gpa, init.io);
    defer watch.deinit(init.gpa);
    try Io.Dir.cwd().createDirPath(init.io, "docs");
    const docs = try Io.Dir.cwd().openDir(
        init.io,
        "docs",
        .{ .follow_symlinks = false },
    );
    defer docs.close(init.io);
    var server: Server = undefined;
    server.init(
        docs,
        init.io,
        port,
    ) catch |err| {
        log.err(
            "cannot listen on 127.0.0.1:{d}: {t}; select another port with --port PORT",
            .{ port, err },
        );
        return err;
    };
    defer server.deinit(init.io);
    try rebuild(
        init.gpa,
        init.io,
        &server,
    );
    log.info("serving docs/ at http://127.0.0.1:{d}", .{server.listener.socket.address.getPort()});
    log.info("watching posts/ for changes; press Ctrl-C to stop", .{});

    const Completion = union(enum) {
        server: Server.RunError!void,
        watcher: LoopError!void,
    };
    var completions: [2]Completion = undefined;
    var completion: Io.Select(Completion) = .init(init.io, &completions);
    defer completion.cancelDiscard();
    try completion.concurrent(
        .server,
        Server.run,
        .{
            &server,
            init.gpa,
            init.io,
        },
    );
    try completion.concurrent(
        .watcher,
        watchPosts,
        .{
            init.gpa,
            init.io,
            &watch,
            &server,
        },
    );
    switch (try completion.await()) {
        inline else => |result| try result,
    }
}

fn watchPosts(
    gpa: std.mem.Allocator,
    io: Io,
    watch: *Watch,
    server: *Server,
) LoopError!void {
    var scan_error: ?Watch.Error = null;
    while (true) {
        try Io.sleep(
            io,
            .fromMilliseconds(250),
            .awake,
        );
        const changed = watch.poll(gpa, io) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |fatal| return fatal,
            else => {
                if (scan_error == null or scan_error.? != err) {
                    log.err("cannot scan posts/: {t}; retrying", .{err});
                }
                scan_error = err;
                continue;
            },
        };
        scan_error = null;
        if (changed) try rebuild(
            gpa,
            io,
            server,
        );
    }
}

fn rebuild(
    gpa: Allocator,
    io: Io,
    server: *Server,
) LoopError!void {
    try server.build_mutex.lock(io);
    defer server.build_mutex.unlock(io);
    const started_at = Io.Clock.awake.now(io);
    buildIndex(gpa, io) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => |fatal| return fatal,
        else => {
            log.err("build failed: {t}; waiting for changes", .{err});
            return;
        },
    };
    _ = server.revision.fetchAdd(1, .release);
    const elapsed_ns = started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: build complete", .{elapsed_ms});
}

fn buildIndex(gpa: std.mem.Allocator, io: Io) !void {
    const cwd = Io.Dir.cwd();
    const index_path = try Io.Dir.path.join(gpa, &.{ "docs", "index.html" });
    defer gpa.free(index_path);

    var posts: Posts = .{};
    try posts.init(
        gpa,
        io,
        "posts",
    );
    defer posts.deinit(gpa);
    try cwd.createDirPath(io, "docs");
    try posts.writePost(gpa, io);

    const feed_started_at = Io.Clock.awake.now(io);
    const feed_path = try Io.Dir.path.join(gpa, &.{ "docs", "feed.xml" });
    defer gpa.free(feed_path);
    var atom_feed: Atom = undefined;
    try atom_feed.init(
        gpa,
        io,
        feed_path,
    );
    defer atom_feed.deinit(io);
    try atom_feed.generate(io, &posts);
    const feed_elapsed_ns = feed_started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const feed_elapsed_ms = @as(f64, @floatFromInt(feed_elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: create {s}", .{ feed_elapsed_ms, feed_path });

    const started_at = Io.Clock.awake.now(io);
    var index_file = try cwd.createFile(
        io,
        index_path,
        .{},
    );
    defer index_file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = index_file.writer(io, &buf);
    try partials.writeHeader(
        &writer.interface,
        true,
        "Blog: Hong Shick Pak",
    );
    try posts.writeIndex(&writer.interface);
    try partials.writeFooter(&writer.interface, true);
    try writer.interface.flush();
    const elapsed_ns = started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: create {s}", .{ elapsed_ms, index_path });
}

test {
    _ = Server;
    _ = Watch;
    _ = image;
    _ = markdown;
    _ = Posts;
    _ = Atom;
    _ = partials;
    _ = time;
}

test "watch rebuilds the site and recovers from invalid posts" {
    if (comptime builtin.os.tag == .windows or !std.process.can_spawn) {
        return error.SkipZigTest;
    }

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
            client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io },
            request: std.http.Client.Request = undefined,
            reader: *Io.Reader = undefined,
            url_buffer: [128]u8 = undefined,
            transfer_buffer: [1024]u8 = undefined,

            const ReadError = Io.Reader.DelimiterError || std.fmt.ParseIntError;

            fn init(events: *Events, port: u16) !void {
                events.* = .{};
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
                    if (!std.mem.startsWith(
                        u8,
                        line,
                        "data: ",
                    )) continue;
                    return std.fmt.parseInt(
                        u64,
                        line[6..],
                        10,
                    );
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
                try completion.concurrent(
                    .revision,
                    readRevision,
                    .{events},
                );
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

        fn read(site: @This(), path: []const u8) ![]u8 {
            return site.dir.readFileAlloc(
                testing.io,
                path,
                testing.allocator,
                .limited(1024 * 1024),
            );
        }

        fn write(
            site: @This(),
            path: []const u8,
            data: []const u8,
        ) !void {
            try site.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
        }

        fn writePost(
            site: @This(),
            path: []const u8,
            options: PostOptions,
        ) !void {
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

        fn expectText(
            site: @This(),
            path: []const u8,
            expected: []const u8,
        ) !void {
            const content = try site.read(path);
            defer testing.allocator.free(content);
            try testing.expect(std.mem.indexOf(
                u8,
                content,
                expected,
            ) != null);
        }

        fn expectAbsent(
            site: @This(),
            path: []const u8,
            unexpected: []const u8,
        ) !void {
            const content = try site.read(path);
            defer testing.allocator.free(content);
            try testing.expect(std.mem.indexOf(
                u8,
                content,
                unexpected,
            ) == null);
        }

        fn expectMissing(site: @This(), path: []const u8) !void {
            try testing.expectError(error.FileNotFound, site.dir.statFile(
                testing.io,
                path,
                .{},
            ));
        }

        fn preview(
            site: @This(),
            path: []const u8,
            event: bool,
        ) ![]u8 {
            var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
            defer client.deinit();
            var url_buffer: [256]u8 = undefined;
            const url = try std.fmt.bufPrint(
                &url_buffer,
                "http://127.0.0.1:{d}{s}",
                .{ site.port, path },
            );
            var request = try client.request(
                .GET,
                try std.Uri.parse(url),
                .{ .keep_alive = false },
            );
            defer request.deinit();
            try request.sendBodiless();
            var response = try request.receiveHead(&.{});
            try testing.expectEqual(.ok, response.head.status);
            var buffer: [4096]u8 = undefined;
            const reader = response.reader(&buffer);
            if (event) return testing.allocator.dupe(u8, try reader.takeDelimiterExclusive('\n'));
            return reader.allocRemaining(testing.allocator, .limited(1024 * 1024));
        }

        fn revision(site: @This()) !u64 {
            const event = try site.preview("/__zmd/events", true);
            defer testing.allocator.free(event);
            try testing.expect(std.mem.startsWith(
                u8,
                event,
                "data: ",
            ));
            return std.fmt.parseInt(
                u64,
                event[6..],
                10,
            );
        }

        fn expectPreview(
            site: @This(),
            path: []const u8,
            expected: []const u8,
        ) !void {
            const content = try site.preview(path, false);
            defer testing.allocator.free(content);
            try testing.expect(std.mem.indexOf(
                u8,
                content,
                expected,
            ) != null);
        }

        fn waitFor(site: *@This(), expected: []const u8) !void {
            const deadline = Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(8));
            while (Io.Clock.awake.now(testing.io).nanoseconds < deadline.nanoseconds) {
                const content = try site.read("watch.log");
                defer testing.allocator.free(content);
                if (std.mem.indexOfPos(
                    u8,
                    content,
                    site.log_offset,
                    expected,
                )) |offset| {
                    site.log_offset = offset + expected.len;
                    return;
                }
                try Io.sleep(
                    testing.io,
                    .fromMilliseconds(50),
                    .awake,
                );
            }
            const content = try site.read("watch.log");
            defer testing.allocator.free(content);
            std.debug.print("Timed out waiting for {s}:\n{s}\n", .{ expected, content });
            return error.WatchTimeout;
        }
    };

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var site: Site = .{ .dir = tmp.dir };
    try tmp.dir.createDirPath(io, "posts");
    const source = "posts/0001-test.md";
    const page = "docs/post/test/index.html";
    const feed = "docs/feed.xml";
    const index = "docs/index.html";
    try site.writePost(source, .{});
    const log_file = try tmp.dir.createFile(
        io,
        "watch.log",
        .{},
    );
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
        const end = std.mem.indexOfScalarPos(
            u8,
            content,
            start,
            '\n',
        ) orelse content.len;
        site.port = try std.fmt.parseInt(
            u16,
            content[start..end],
            10,
        );
    }
    const initial_revision = try site.revision();
    var first_tab: Site.Events = .{};
    try first_tab.init(site.port);
    defer first_tab.deinit();
    try testing.expectEqual(initial_revision, try first_tab.next());
    var second_tab: Site.Events = .{};
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
    try Io.sleep(
        io,
        .fromMilliseconds(800),
        .awake,
    );
    {
        const content = try site.read("watch.log");
        defer testing.allocator.free(content);
        try testing.expectEqual(@as(usize, 1), std.mem.count(
            u8,
            content,
            "build complete",
        ));
    }

    try site.writePost(source, .{ .body = "Bravo", .title = "Edited post" });
    try site.waitFor("build complete");
    try site.expectText(page, "Bravo");
    try site.expectText(feed, "Bravo");
    try site.expectText(index, "Edited post");
    try site.expectPreview("/post/test/", "Bravo");
    try testing.expectEqual(initial_revision +% 1, try site.revision());
    try testing.expectEqual(initial_revision +% 1, try first_tab.next());
    try testing.expectEqual(initial_revision +% 1, try second_tab.next());

    // Editors can replace a file while preserving its length and timestamp.
    const stat = try tmp.dir.statFile(
        io,
        source,
        .{},
    );
    try site.writePost("posts/save.tmp", .{ .body = "Gamma", .title = "Edited post" });
    try tmp.dir.setTimestamps(
        io,
        "posts/save.tmp",
        .{ .modify_timestamp = .{ .new = stat.mtime } },
    );
    try tmp.dir.rename(
        "posts/save.tmp",
        tmp.dir,
        source,
        io,
    );
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
    try site.expectText(page, "<figure>\n<video autoplay loop muted playsinline " ++
        "src=\"/post/test/assets/nested/demo.mp4\" aria-label=\"Demo\"");
    try site.expectText(page, "<figcaption>Build &amp; run</figcaption>");
    try site.expectText(page, "<a href=\"/post/test/assets/nested/demo.mp4\">Demo</a>");
    try site.expectAbsent(page, "<video controls");
    try site.expectAbsent(page, "{gif}");
    try site.expectText(feed, "&lt;video autoplay loop muted playsinline");
    try site.expectText(feed, "src=&quot;/post/test/assets/nested/demo.mp4&quot;");
    try site.expectPreview("/post/test/", "<video autoplay loop muted playsinline");
    try site.write(asset, "video two");
    try site.waitFor("build complete");
    try site.expectText(copied, "video two");
    try tmp.dir.deleteFile(io, asset);
    try site.waitFor("build complete");
    try site.expectMissing(copied);

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
    try tmp.dir.rename(
        added,
        tmp.dir,
        renamed,
        io,
    );
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

    try tmp.dir.rename(
        "posts",
        tmp.dir,
        "old-posts",
        io,
    );
    try site.waitFor("cannot scan posts/: FileNotFound");
    try tmp.dir.createDirPath(io, "posts");
    try site.writePost(source, .{ .body = "New directory" });
    try site.waitFor("build complete");
    try site.expectText(page, "New directory");

    try std.posix.kill(child.id.?, .INT);
    const Completion = union(enum) {
        term: std.process.Child.WaitError!std.process.Child.Term,
        timeout: Io.Cancelable!void,
    };
    var completions: [2]Completion = undefined;
    var completion: Io.Select(Completion) = .init(io, &completions);
    defer completion.cancelDiscard();
    try completion.concurrent(
        .term,
        std.process.Child.wait,
        .{ &child, io },
    );
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
        .term => |term| try testing.expectEqual(
            std.process.Child.Term{ .signal = .INT },
            try term,
        ),
        .timeout => |result| {
            try result;
            return error.WatchTimeout;
        },
    }
}
