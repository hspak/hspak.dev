//! Static site generator for hspak.dev.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Assets = @import("Assets.zig");
const Atom = @import("Atom.zig");
const Posts = @import("Posts.zig");
const Server = @import("Server.zig");
const Watch = @import("Watch.zig");
const image = @import("image.zig");
const partials = @import("partials.zig");

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
        if (std.mem.eql(u8, arg, "--port")) {
            const value = args.next() orelse return error.MissingPort;
            port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--help")) {
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
    var watch: Watch = .{
        .path = "posts",
        .extra_files = &.{"docs/index.css"},
    };
    try watch.init(init.gpa, init.io);
    defer watch.deinit(init.gpa);
    try Io.Dir.cwd().createDirPath(init.io, "docs");
    const docs = try Io.Dir.cwd().openDir(init.io, "docs", .{ .follow_symlinks = false });
    defer docs.close(init.io);
    var server: Server = undefined;
    server.init(docs, init.io, port) catch |err| {
        log.err(
            "cannot listen on 127.0.0.1:{d}: {t}; select another port with --port PORT",
            .{ port, err },
        );
        return err;
    };
    defer server.deinit(init.io);
    try rebuild(init.gpa, init.io, &server);
    log.info("serving docs/ at http://127.0.0.1:{d}", .{server.listener.socket.address.getPort()});
    log.info("watching posts/ and docs/index.css for changes; press Ctrl-C to stop", .{});

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

fn watchPosts(gpa: Allocator, io: Io, watch: *Watch, server: *Server) LoopError!void {
    var scan_error: ?Watch.Error = null;
    while (true) {
        try Io.sleep(io, .fromMilliseconds(250), .awake);
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
        if (changed) try rebuild(gpa, io, server);
    }
}

fn rebuild(gpa: Allocator, io: Io, server: *Server) LoopError!void {
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

fn buildIndex(gpa: Allocator, io: Io) !void {
    const cwd = Io.Dir.cwd();
    const index_path = try Io.Dir.path.join(gpa, &.{ "docs", "index.html" });
    defer gpa.free(index_path);

    var posts: Posts = .{};
    try posts.init(gpa, io, "posts");
    defer posts.deinit(gpa);
    try cwd.createDirPath(io, "docs");
    try posts.write(gpa, io);

    const docs = try cwd.openDir(io, "docs", .{});
    defer docs.close(io);
    var asset_roots: std.ArrayList([]const u8) = .empty;
    defer {
        for (asset_roots.items) |path| gpa.free(path);
        asset_roots.deinit(gpa);
    }
    for ([_][]const u8{
        "index.css",
        "theme.js",
        "favicon.svg",
        "favicon.ico",
        "apple-touch-icon.png",
        "fonts",
    }) |path| {
        try asset_roots.ensureUnusedCapacity(gpa, 1);
        asset_roots.appendAssumeCapacity(try gpa.dupe(u8, path));
    }
    for (posts.list.items) |post| {
        for ([_][]const u8{ "assets", "thumbnails" }) |directory| {
            try asset_roots.ensureUnusedCapacity(gpa, 1);
            asset_roots.appendAssumeCapacity(try std.fmt.allocPrint(
                gpa,
                "{s}/{s}/{s}",
                .{
                    if (post.meta.draft) "draft" else "post",
                    post.meta.name,
                    directory,
                },
            ));
        }
    }
    var assets: Assets = undefined;
    try assets.init(gpa, io, docs, asset_roots.items);
    defer assets.deinit(gpa);
    try assets.writeStylesheet(gpa, io, docs);
    for (posts.list.items) |*post| {
        const html = try assets.rewriteHtml(gpa, post.parsed_html);
        gpa.free(post.parsed_html);
        post.parsed_html = html;
        const path = try std.fmt.allocPrint(
            gpa,
            "{s}/{s}/index.html",
            .{
                if (post.meta.draft) "draft" else "post",
                post.meta.name,
            },
        );
        defer gpa.free(path);
        try assets.rewriteFile(gpa, io, docs, path);
    }

    const feed_started_at = Io.Clock.awake.now(io);
    const feed_path = try Io.Dir.path.join(gpa, &.{ "docs", "feed.xml" });
    defer gpa.free(feed_path);
    var atom_feed: Atom = undefined;
    try atom_feed.init(gpa, io, feed_path);
    defer atom_feed.deinit(io);
    try atom_feed.generate(io, &posts);
    const feed_elapsed_ns = feed_started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const feed_elapsed_ms = @as(f64, @floatFromInt(feed_elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: create {s}", .{ feed_elapsed_ms, feed_path });

    const started_at = Io.Clock.awake.now(io);
    {
        const index_file = try cwd.createFile(io, index_path, .{});
        defer index_file.close(io);
        var buf: [4096]u8 = undefined;
        var writer = index_file.writer(io, &buf);
        try partials.writeHeader(&writer.interface, true, "Blog: Hong Shick Pak");
        try posts.writeIndex(&writer.interface);
        try partials.writeFooter(&writer.interface, true);
        try writer.interface.flush();
    }
    try assets.rewriteFile(gpa, io, docs, "index.html");
    // Query versions supersede the archived files emitted by earlier generator versions.
    try docs.deleteTree(io, "versioned");
    const elapsed_ns = started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
    log.info("{d:.2}ms: create {s}", .{ elapsed_ms, index_path });
}

test {
    _ = Assets;
    _ = Server;
    _ = Watch;
    _ = image;
    _ = @import("markdown.zig");
    _ = Posts;
    _ = Atom;
    _ = partials;
    _ = @import("time.zig");
    _ = @import("site_test.zig");
}
