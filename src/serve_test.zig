//! Exercise the production executable against an isolated generated-site directory.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const test_options = @import("test_options");
const server_options = @import("server_options");
const partials = @import("partials.zig");

fn waitForPort(dir: Io.Dir) !u16 {
    const deadline = Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(15));
    while (Io.Clock.awake.now(testing.io).nanoseconds < deadline.nanoseconds) {
        const bytes = try dir.readFileAlloc(
            testing.io,
            "serve.log",
            testing.allocator,
            .limited(1024 * 1024),
        );
        defer testing.allocator.free(bytes);
        if (std.mem.startsWith(u8, bytes, "error: IoUringUnavailable\n")) return error.SkipZigTest;
        if (std.mem.startsWith(u8, bytes, "error: ResourceDetectionUnavailable\n")) {
            // Nix build sandboxes omit cgroup mounts. The same suite runs fully
            // in nix develop; visible cgroups with failed detection remain errors.
            Io.Dir.cwd().access(testing.io, "/sys/fs/cgroup", .{}) catch |err| switch (err) {
                error.FileNotFound => return error.SkipZigTest,
                else => return err,
            };
        }
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const parsed = std.json.parseFromSlice(struct {
                event: []const u8,
                port: ?u16 = null,
            }, testing.allocator, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            defer parsed.deinit();
            if (std.mem.eql(u8, parsed.value.event, "listening")) return parsed.value.port.?;
        }
        try Io.sleep(testing.io, .fromMilliseconds(25), .awake);
    }
    const bytes = try dir.readFileAlloc(testing.io, "serve.log", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    std.debug.print("Production server did not start:\n{s}\n", .{bytes});
    return error.ServerTimeout;
}

fn request(port: u16, method: []const u8, path: []const u8, headers: []const u8) ![]u8 {
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    var writer = stream.writer(testing.io, &.{});
    try writer.interface.print(
        "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n{s}\r\n",
        .{
            method,
            path,
            headers,
        },
    );
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(testing.io, &buffer);
    return reader.interface.allocRemaining(testing.allocator, .limited(1024 * 1024));
}

fn header(response: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn body(response: []const u8) ![]const u8 {
    const boundary = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.MissingHeaders;
    return response[boundary + 4 ..];
}

fn expectSecurityHeaders(response: []const u8) !void {
    const fields = .{
        .{ "strict-transport-security", "max-age=31536000; includeSubDomains" },
        .{ "x-frame-options", "SAMEORIGIN" },
        .{ "referrer-policy", "strict-origin" },
        .{ "permissions-policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()" },
    };
    inline for (fields) |field| {
        const actual = header(response, field[0]) orelse return error.MissingSecurityHeader;
        try testing.expectEqualStrings(field[1], actual);
    }
    const policy = header(response, "content-security-policy") orelse
        return error.MissingContentSecurityPolicy;
    for ([_][]const u8{
        "default-src 'self';",
        "object-src 'none';",
        "base-uri 'none';",
        "form-action 'none';",
        "frame-ancestors 'self';",
    }) |directive| try testing.expect(std.mem.indexOf(u8, policy, directive) != null);
    try testing.expect(std.mem.indexOf(u8, policy, "'unsafe-inline'") == null);
    try testing.expect(std.mem.indexOf(u8, policy, "'unsafe-eval'") == null);
}

fn expectThemeAllowed(response: []const u8) !void {
    const html = try body(response);
    const start = (std.mem.indexOf(u8, html, "<script>") orelse
        return error.MissingThemeScript) + "<script>".len;
    const end = std.mem.indexOfPos(u8, html, start, "</script>") orelse
        return error.MissingScriptEnd;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(html[start..end], &digest, .{});
    var hash_buffer: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&hash_buffer, &digest);
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "script-src 'self' 'sha256-{s}';",
        .{encoded},
    );
    defer testing.allocator.free(expected);
    const policy = header(response, "content-security-policy") orelse
        return error.MissingContentSecurityPolicy;
    try testing.expect(std.mem.indexOf(u8, policy, expected) != null);
}

fn expectDecoded(compressed: []const u8, expected: []const u8) !void {
    var input: Io.Reader = .fixed(compressed);
    const zstd = std.compress.zstd;
    const buffer = try testing.allocator.alloc(u8, zstd.default_window_len + zstd.block_size_max);
    defer testing.allocator.free(buffer);
    var decoder: zstd.Decompress = .init(&input, buffer, .{});
    const decoded = try decoder.reader.allocRemaining(testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(expected, decoded);
}

test "production server negotiates zstd for generated pages and assets" {
    if (comptime builtin.os.tag != .linux or !std.process.can_spawn) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const document_root = server_options.document_root;
    const post_directory = try Io.Dir.path.join(testing.allocator, &.{ document_root, "post/example" });
    defer testing.allocator.free(post_directory);
    try tmp.dir.createDirPath(io, post_directory);
    if (!std.mem.eql(u8, document_root, "docs")) {
        try tmp.dir.createDirPath(io, "docs");
        try tmp.dir.writeFile(io, .{ .sub_path = "docs/index.html", .data = "wrong document root" });
    }
    if (server_options.acme_root) |root| {
        try tmp.dir.createDirPath(io, root);
        const challenge = try tmp.dir.openDir(io, root, .{});
        defer challenge.close(io);
        try challenge.writeFile(io, .{ .sub_path = "test-token", .data = "challenge-token" });
        try challenge.writeFile(io, .{ .sub_path = "index.html", .data = "must not serve directory index" });
    }
    var document: Io.Writer.Allocating = .init(testing.allocator);
    defer document.deinit();
    try partials.writeHeader(&document.writer, false, "Security headers");
    try document.writer.writeAll("<p>A generated blog post.</p>\n" ** 256);
    try partials.writeFooter(&document.writer, false);
    const html = document.written();
    const files = [_]struct { path: []const u8, mime: []const u8, content: []const u8 }{
        .{
            .path = "index.html",
            .mime = "text/html; charset=utf-8",
            .content = html,
        },
        .{
            .path = "post/example/index.html",
            .mime = "text/html; charset=utf-8",
            .content = html,
        },
        .{
            .path = "site.css",
            .mime = "text/css; charset=utf-8",
            .content = "body { color: black; }\n" ** 256,
        },
        .{
            .path = "theme.js",
            .mime = "text/javascript; charset=utf-8",
            .content = "/* theme switch */\n" ** 256,
        },
        .{
            .path = "feed.xml",
            .mime = "application/xml",
            .content = "<feed>" ++ "<entry/>" ** 256 ++ "</feed>",
        },
    };
    const docs = try tmp.dir.openDir(io, document_root, .{});
    defer docs.close(io);
    for (files) |file| try docs.writeFile(io, .{ .sub_path = file.path, .data = file.content });
    try docs.writeFile(io, .{ .sub_path = "image.png", .data = html });
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "outside docs" });

    const log = try tmp.dir.createFile(io, "serve.log", .{});
    defer log.close(io);
    const executable = try Io.Dir.cwd().realPathFileAlloc(io, test_options.zserve_path, testing.allocator);
    defer testing.allocator.free(executable);
    var child = try std.process.spawn(io, .{
        .argv = &.{
            executable,
            "--port",
            "0",
            "--workers",
            "1",
            "--max-connections",
            "4",
        },
        .cwd = .{ .dir = tmp.dir },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    defer child.kill(io);
    const port = try waitForPort(tmp.dir);
    const challenge = try request(port, "GET", "/.well-known/acme-challenge/test-token", "");
    defer testing.allocator.free(challenge);
    if (server_options.acme_root != null) {
        try testing.expect(std.mem.startsWith(u8, challenge, "HTTP/1.1 200 "));
        try testing.expectEqualStrings("challenge-token", try body(challenge));
    } else {
        try testing.expect(std.mem.startsWith(u8, challenge, "HTTP/1.1 404 "));
    }
    for ([_][]const u8{ "/.well-known/acme-challenge/", "/.well-known/acme-challenge/missing" }) |path| {
        const response = try request(port, "GET", path, "");
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 404 "));
    }

    for (files) |file| {
        const path = try std.fmt.allocPrint(testing.allocator, "/{s}?v=version", .{file.path});
        defer testing.allocator.free(path);
        const plain = try request(port, "GET", path, "Accept-Encoding: gzip, br\r\n");
        defer testing.allocator.free(plain);
        try testing.expect(std.mem.startsWith(u8, plain, "HTTP/1.1 200 "));
        try testing.expect(header(plain, "content-encoding") == null);
        try testing.expectEqualStrings(file.content, try body(plain));
        try expectSecurityHeaders(plain);
        if (std.mem.endsWith(u8, file.path, ".html")) try expectThemeAllowed(plain);

        const compressed = try request(port, "GET", path, "Accept-Encoding: zstd\r\n");
        defer testing.allocator.free(compressed);
        try testing.expect(std.mem.startsWith(u8, compressed, "HTTP/1.1 200 "));
        try testing.expectEqualStrings("zstd", header(compressed, "content-encoding").?);
        try testing.expectEqualStrings("Accept-Encoding", header(compressed, "vary").?);
        try testing.expectEqualStrings(file.mime, header(compressed, "content-type").?);
        try testing.expectEqualStrings("no-cache", header(compressed, "cache-control").?);
        try expectSecurityHeaders(compressed);
        const encoded = try body(compressed);
        try testing.expect(encoded.len < file.content.len);
        const length = try std.fmt.parseInt(usize, header(compressed, "content-length").?, 10);
        try testing.expectEqual(encoded.len, length);
        try expectDecoded(encoded, file.content);
        try testing.expect(!std.mem.eql(u8, header(plain, "etag").?, header(compressed, "etag").?));

        const head = try request(port, "HEAD", path, "Accept-Encoding: zstd\r\n");
        defer testing.allocator.free(head);
        try expectSecurityHeaders(head);
        try testing.expectEqualStrings("", try body(head));
        try testing.expectEqualStrings("zstd", header(head, "content-encoding").?);
        try testing.expectEqualStrings(
            header(compressed, "content-length").?,
            header(head, "content-length").?,
        );

        const conditions = try std.fmt.allocPrint(
            testing.allocator,
            "Accept-Encoding: zstd\r\nIf-None-Match: {s}\r\n",
            .{header(compressed, "etag").?},
        );
        defer testing.allocator.free(conditions);
        const cached = try request(port, "GET", path, conditions);
        defer testing.allocator.free(cached);
        try testing.expect(std.mem.startsWith(u8, cached, "HTTP/1.1 304 "));
        try expectSecurityHeaders(cached);
        try testing.expectEqualStrings("", try body(cached));
    }
    for ([_][]const u8{ "/", "/post/example/" }) |path| {
        const response = try request(port, "GET", path, "Accept-Encoding: zstd\r\n");
        defer testing.allocator.free(response);
        try expectSecurityHeaders(response);
        try testing.expectEqualStrings("zstd", header(response, "content-encoding").?);
        try expectDecoded(try body(response), html);
    }
    const image = try request(port, "GET", "/image.png", "Accept-Encoding: zstd\r\n");
    defer testing.allocator.free(image);
    try testing.expect(header(image, "content-encoding") == null);
    try testing.expectEqualStrings(html, try body(image));
    try expectSecurityHeaders(image);
    const outside = try request(port, "GET", "/secret.txt", "");
    defer testing.allocator.free(outside);
    try testing.expect(std.mem.startsWith(u8, outside, "HTTP/1.1 404 "));
    try expectSecurityHeaders(outside);

    const redirect = try request(port, "GET", "/post/example?version=1", "");
    defer testing.allocator.free(redirect);
    try testing.expect(std.mem.startsWith(u8, redirect, "HTTP/1.1 308 "));
    try testing.expectEqualStrings("/post/example/?version=1", header(redirect, "location").?);
    try expectSecurityHeaders(redirect);

    const unacceptable = try request(port, "GET", "/", "Accept-Encoding: *;q=0\r\n");
    defer testing.allocator.free(unacceptable);
    try testing.expect(std.mem.startsWith(u8, unacceptable, "HTTP/1.1 406 "));
    try expectSecurityHeaders(unacceptable);

    const updated = "<html><body>Updated deployment</body></html>";
    try docs.writeFile(io, .{ .sub_path = "index.html", .data = updated });
    const changed = try request(port, "GET", "/", "Accept-Encoding: zstd\r\n");
    defer testing.allocator.free(changed);
    try testing.expect(header(changed, "content-encoding") == null);
    try testing.expectEqualStrings(updated, try body(changed));
    try expectSecurityHeaders(changed);
    // The server handles TERM so its private compression files can be removed.
    try testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.kill(child.id.?, .TERM)));
    const Completion = union(enum) {
        term: std.process.Child.WaitError!std.process.Child.Term,
        timeout: Io.Cancelable!void,
    };
    var completions: [2]Completion = undefined;
    var completion: Io.Select(Completion) = .init(io, &completions);
    defer completion.cancelDiscard();
    try completion.concurrent(.term, std.process.Child.wait, .{ &child, io });
    completion.async(.timeout, Io.sleep, .{
        io,
        .fromSeconds(8),
        .awake,
    });
    switch (try completion.await()) {
        .term => |term| try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try term),
        .timeout => return error.ShutdownTimeout,
    }
}
