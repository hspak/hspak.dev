//! Local static preview server with build notifications over server-sent events.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const Server = @This();
const log = std.log.scoped(.server);

root: Io.Dir,
listener: Io.net.Server,
// Protect generated files while the watcher replaces them.
build_mutex: Io.Mutex = .init,
revision: std.atomic.Value(u64) = .init(0),

pub const InitError = Io.net.IpAddress.ListenError;
pub const RunError = Io.ConcurrentError || Io.Cancelable || Io.UnexpectedError || error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    NetworkDown,
    WouldBlock,
    BlockedByFirewall,
    ProtocolFailure,
};

const Resource = struct {
    file: Io.File,
    size: u64,
    directory: bool,
    content: ?[]u8,
    revision: u64,
};

const Range = struct { start: u64, end: u64 };

const reload_script = @embedFile("reload.js");
const no_cache: http.Header = .{ .name = "cache-control", .value = "no-store" };

/// Initialize fresh storage, borrowing `root` until `deinit`. Port zero selects a free port.
/// Pair success with `deinit(io)`. On error, no resources are retained.
pub fn init(server: *Server, root: Io.Dir, io: Io, port: u16) InitError!void {
    const address: Io.net.IpAddress = .{
        .ip4 = .{
            .bytes = .{
                127,
                0,
                0,
                1,
            },
            .port = port,
        },
    };
    server.* = .{
        .root = root,
        .listener = try address.listen(io, .{ .reuse_address = true }),
    };
    // A new process must also refresh pages left open from a previous preview.
    Io.random(io, std.mem.asBytes(&server.revision.raw));
}

/// Close the listener after `run` and all its connection tasks have finished.
pub fn deinit(server: *Server, io: Io) void {
    server.listener.deinit(io);
    server.* = undefined;
}

/// Serve until canceled. `gpa` must support concurrent calls.
pub fn run(server: *Server, gpa: Allocator, io: Io) RunError!void {
    var connections: Io.Group = .init;
    defer connections.cancel(io);
    while (true) {
        const stream = server.listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => |accept_err| return accept_err,
        };
        connections.concurrent(
            io,
            serveConnection,
            .{
                server,
                gpa,
                io,
                stream,
            },
        ) catch |err| {
            stream.close(io);
            return err;
        };
    }
}

fn serveConnection(server: *Server, gpa: Allocator, io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var connection: http.Server = .init(&reader.interface, &writer.interface);
    var request = connection.receiveHead() catch return;
    server.respond(gpa, io, &request) catch |err| switch (err) {
        error.Canceled,
        error.WriteFailed,
        error.ReadFailed,
        error.EndOfStream,
        => {},
        error.OutOfMemory => log.err("out of memory serving request", .{}),
        else => log.err("request failed: {t}", .{err}),
    };
}

fn respond(server: *Server, gpa: Allocator, io: Io, request: *http.Server.Request) !void {
    if (request.head.method != .GET and request.head.method != .HEAD) {
        return request.respond("Method not allowed\n", .{
            .status = .method_not_allowed,
            .keep_alive = false,
            .extra_headers = &.{ no_cache, .{ .name = "allow", .value = "GET, HEAD" } },
        });
    }

    const target = request.head.target;
    const path = decodePath(gpa, target) catch |err| switch (err) {
        error.InvalidPath => return respondError(request, .bad_request),
        else => return err,
    };
    defer gpa.free(path);

    if (std.mem.eql(u8, path, "__zmd/reload.js")) {
        return request.respond(reload_script, .{
            .keep_alive = false,
            .extra_headers = &.{
                no_cache,
                .{ .name = "content-type", .value = "text/javascript; charset=utf-8" },
            },
        });
    }
    if (std.mem.eql(u8, path, "__zmd/events")) return server.sendEvents(io, request);

    var resource = server.openResource(gpa, io, path) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        error.FileNotFound,
        error.NotDir,
        error.IsDir,
        error.SymLinkLoop,
        error.AccessDenied,
        error.PermissionDenied,
        error.NotRegularFile,
        => return respondError(request, .not_found),
        else => {
            log.err("cannot serve {s}: {t}", .{ path, err });
            return respondError(request, .internal_server_error);
        },
    };
    defer resource.file.close(io);
    defer if (resource.content) |content| gpa.free(content);

    if (resource.directory and path.len != 0 and !std.mem.endsWith(u8, path, "/")) {
        const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const location = try std.fmt.allocPrint(
            gpa,
            "{s}/{s}",
            .{ target[0..query], target[query..] },
        );
        defer gpa.free(location);
        return request.respond("", .{
            .status = .moved_permanently,
            .keep_alive = false,
            .extra_headers = &.{ no_cache, .{ .name = "location", .value = location } },
        });
    }

    const content_type = if (resource.directory) "text/html; charset=utf-8" else mimeType(path);
    if (resource.content) |content| {
        const injected = if (std.mem.startsWith(u8, content_type, "text/html"))
            try injectReload(gpa, content, resource.revision)
        else
            null;
        defer if (injected) |body| gpa.free(body);
        return request.respond(injected orelse content, .{
            .keep_alive = false,
            .extra_headers = &.{ no_cache, .{ .name = "content-type", .value = content_type } },
        });
    }

    var range: ?Range = null;
    // HTTP Range applies only to GET; HEAD describes the complete representation.
    if (request.head.method == .GET) {
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "range")) {
                range = parseRange(header.value, resource.size) catch {
                    var buffer: [64]u8 = undefined;
                    const value = try std.fmt.bufPrint(&buffer, "bytes */{d}", .{resource.size});
                    return request.respond("Range not satisfiable\n", .{
                        .status = .range_not_satisfiable,
                        .keep_alive = false,
                        .extra_headers = &.{
                            no_cache,
                            .{ .name = "content-range", .value = value },
                        },
                    });
                };
            }
        }
    }
    var range_buffer: [96]u8 = undefined;
    var headers: [4]http.Header = .{
        no_cache,
        .{ .name = "content-type", .value = content_type },
        .{ .name = "accept-ranges", .value = "bytes" },
        undefined,
    };
    if (range) |r| headers[3] = .{
        .name = "content-range",
        .value = try std.fmt.bufPrint(
            &range_buffer,
            "bytes {d}-{d}/{d}",
            .{
                r.start,
                r.end,
                resource.size,
            },
        ),
    };
    const length = if (range) |r| r.end - r.start + 1 else resource.size;
    var body_buffer: [8192]u8 = undefined;
    var body = try request.respondStreaming(&body_buffer, .{
        .content_length = length,
        .respond_options = .{
            .status = if (range != null) .partial_content else .ok,
            .keep_alive = false,
            .extra_headers = headers[0..@as(usize, if (range != null) 4 else 3)],
        },
    });
    if (request.head.method == .HEAD) return body.flush();
    var file_buffer: [8192]u8 = undefined;
    var reader = resource.file.reader(io, &file_buffer);
    if (range) |r| try reader.seekTo(r.start);
    try reader.interface.streamExact64(&body.writer, length);
    try body.end();
}

fn openResource(server: *Server, gpa: Allocator, io: Io, path: []const u8) !Resource {
    try server.build_mutex.lock(io);
    defer server.build_mutex.unlock(io);

    // Walk one component at a time so intermediate symlinks cannot escape docs/.
    var parent = server.root;
    defer if (parent.handle != server.root.handle) parent.close(io);
    var components = std.mem.tokenizeScalar(u8, path, '/');
    var basename: []const u8 = "index.html";
    var directory = path.len == 0;
    while (components.next()) |component| {
        if (components.peek() == null) {
            const stat = try parent.statFile(io, component, .{ .follow_symlinks = false });
            if (stat.kind == .file) {
                if (std.mem.endsWith(u8, path, "/")) return error.NotDir;
                basename = component;
                break;
            }
            if (stat.kind != .directory) return error.NotRegularFile;
            directory = true;
        }
        const next = try parent.openDir(io, component, .{ .follow_symlinks = false });
        if (parent.handle != server.root.handle) parent.close(io);
        parent = next;
    }
    const entry = try parent.statFile(io, basename, .{ .follow_symlinks = false });
    if (entry.kind != .file) return error.NotRegularFile;
    const file = try parent.openFile(io, basename, .{ .follow_symlinks = false });
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;

    // Snapshot HTML and the feed under the build lock, then release it before
    // writing to a potentially slow browser. Media streams from its open inode.
    const content_type = mimeType(basename);
    const snapshot = std.mem.startsWith(u8, content_type, "text/html") or
        std.mem.eql(u8, content_type, "application/xml; charset=utf-8");
    var reader = file.reader(io, &.{});
    return .{
        .file = file,
        .size = stat.size,
        .directory = directory,
        .content = if (snapshot)
            try reader.interface.allocRemaining(gpa, .limited(64 * 1024 * 1024))
        else
            null,
        .revision = server.revision.load(.acquire),
    };
}

fn sendEvents(server: *Server, io: Io, request: *http.Server.Request) !void {
    var buffer: [256]u8 = undefined;
    var body = try request.respondStreaming(&buffer, .{
        .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                no_cache,
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "x-accel-buffering", .value = "no" },
            },
        },
    });
    if (request.head.method == .HEAD) return body.end();
    var previous: ?u64 = null;
    var ticks: u8 = 0;
    while (true) {
        const revision = server.revision.load(.acquire);
        if (previous == null or previous.? != revision) {
            try body.writer.print("data: {d}\n\n", .{revision});
            try body.writer.flush();
            try body.flush();
            previous = revision;
            ticks = 0;
        } else if (ticks == 60) {
            try body.writer.writeAll(": keep-alive\n\n");
            try body.writer.flush();
            try body.flush();
            ticks = 0;
        }
        try Io.sleep(io, .fromMilliseconds(250), .awake);
        ticks += 1;
    }
}

fn respondError(request: *http.Server.Request, status: http.Status) !void {
    return request.respond(status.phrase().?, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            no_cache,
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        },
    });
}

fn decodePath(gpa: Allocator, target: []const u8) (Allocator.Error || error{InvalidPath})![]u8 {
    if (target.len == 0 or target[0] != '/') return error.InvalidPath;
    for (target) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '#') return error.InvalidPath;
    }
    const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    var decoded: std.Io.Writer.Allocating = .init(gpa);
    defer decoded.deinit();
    var i: usize = 1;
    while (i < query) : (i += 1) {
        const byte = if (target[i] == '%') byte: {
            if (i + 2 >= query) return error.InvalidPath;
            const value = std.fmt.parseInt(
                u8,
                target[i + 1 ..][0..2],
                16,
            ) catch return error.InvalidPath;
            i += 2;
            break :byte value;
        } else target[i];
        if (byte < 0x20 or byte == 0x7f or byte == '\\' or byte == ':') return error.InvalidPath;
        decoded.writer.writeByte(byte) catch return error.OutOfMemory;
    }
    const path = decoded.written();
    if (std.mem.startsWith(u8, path, "/") or std.mem.indexOf(u8, path, "//") != null) {
        return error.InvalidPath;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidPath;
        }
    }
    return decoded.toOwnedSlice();
}

fn injectReload(gpa: Allocator, html: []const u8, revision: u64) Allocator.Error![]u8 {
    const position = std.ascii.indexOfIgnoreCase(html, "</body>") orelse html.len;
    return std.fmt.allocPrint(
        gpa,
        "{s}<script src=\"/__zmd/reload.js\" data-revision=\"{d}\"></script>\n{s}",
        .{
            html[0..position],
            revision,
            html[position..],
        },
    );
}

fn parseRange(header: []const u8, size: u64) error{InvalidRange}!?Range {
    // Unknown units and multipart ranges can be ignored by serving the whole file.
    if (!std.mem.startsWith(u8, header, "bytes=") or
        std.mem.indexOfScalar(u8, header, ',') != null) return null;
    if (size == 0) return error.InvalidRange;
    const range = header[6..];
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse return error.InvalidRange;
    const first = range[0..dash];
    const last = range[dash + 1 ..];
    if (first.len == 0) {
        const suffix = std.fmt.parseInt(u64, last, 10) catch return error.InvalidRange;
        if (suffix == 0) return error.InvalidRange;
        return .{ .start = size - @min(size, suffix), .end = size - 1 };
    }
    const start = std.fmt.parseInt(u64, first, 10) catch return error.InvalidRange;
    const end = if (last.len == 0) size - 1 else std.fmt.parseInt(
        u64,
        last,
        10,
    ) catch return error.InvalidRange;
    if (start >= size or end < start) return error.InvalidRange;
    return .{ .start = start, .end = @min(end, size - 1) };
}

fn mimeType(path: []const u8) []const u8 {
    const extension = Io.Dir.path.extension(path);
    const types = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".xml", "application/xml; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        .{ ".mp4", "video/mp4" },
        .{ ".m4v", "video/mp4" },
        .{ ".webm", "video/webm" },
        .{ ".ogv", "video/ogg" },
        .{ ".mov", "video/quicktime" },
        .{ ".pdf", "application/pdf" },
    };
    inline for (types) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

fn testRequest(server: *Server, raw: []const u8) ![]u8 {
    var reader: Io.Reader = .fixed(raw);
    var writer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var connection: http.Server = .init(&reader, &writer.writer);
    var request = try connection.receiveHead();
    try server.respond(std.testing.allocator, std.testing.io, &request);
    return writer.toOwnedSlice();
}

test "server serves HTML, assets, redirects, HEAD, and video ranges" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "post/example");
    const html = "<html><body>Preview</body></html>";
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = html });
    try tmp.dir.writeFile(io, .{ .sub_path = "post/example/index.html", .data = html });
    try tmp.dir.writeFile(io, .{ .sub_path = "index.css", .data = "body {}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "feed.xml", .data = "<feed/>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "clip.mp4", .data = "0123456789" });
    try tmp.dir.writeFile(io, .{ .sub_path = "space name.PNG", .data = "\x00\xffPNG" });
    var server: Server = .{
        .root = tmp.dir,
        .listener = undefined,
        .revision = .init(42),
    };

    const cases = [_]struct {
        request: []const u8,
        status: []const u8 = "200 OK",
        header: []const u8,
        body: []const u8,
    }{
        .{
            .request = "GET /?v=1",
            .header = "content-type: text/html; charset=utf-8",
            .body = "<html><body>Preview<script src=\"/__zmd/reload.js\" data-revision=\"42\">" ++
                "</script>\n</body></html>",
        },
        .{
            .request = "GET /post/example/",
            .header = "content-type: text/html; charset=utf-8",
            .body = "<html><body>Preview<script src=\"/__zmd/reload.js\" data-revision=\"42\">" ++
                "</script>\n</body></html>",
        },
        .{
            .request = "GET /post/example?x=1",
            .status = "301 Moved Permanently",
            .header = "location: /post/example/?x=1",
            .body = "",
        },
        .{
            .request = "GET /index.css",
            .header = "content-type: text/css; charset=utf-8",
            .body = "body {}",
        },
        .{
            .request = "HEAD /index.css",
            .header = "content-length: 7",
            .body = "",
        },
        .{
            .request = "HEAD /",
            .header = "content-type: text/html; charset=utf-8",
            .body = "",
        },
        .{
            .request = "GET /feed.xml",
            .header = "content-type: application/xml; charset=utf-8",
            .body = "<feed/>",
        },
        .{
            .request = "GET /space%20name.PNG",
            .header = "content-type: image/png",
            .body = "\x00\xffPNG",
        },
        .{
            .request = "GET /clip.mp4",
            .header = "content-type: video/mp4",
            .body = "0123456789",
        },
        .{
            .request = "GET /missing",
            .status = "404 Not Found",
            .header = "content-type: text/plain; charset=utf-8",
            .body = "Not Found",
        },
        .{
            .request = "POST /",
            .status = "405 Method Not Allowed",
            .header = "allow: GET, HEAD",
            .body = "Method not allowed\n",
        },
        .{
            .request = "GET /__zmd/reload.js",
            .header = "content-type: text/javascript; charset=utf-8",
            .body = reload_script,
        },
        .{
            .request = "HEAD /__zmd/events",
            .header = "content-type: text/event-stream",
            .body = "",
        },
    };
    for (cases) |case| {
        const raw = try std.fmt.allocPrint(
            testing.allocator,
            "{s} HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .{case.request},
        );
        defer testing.allocator.free(raw);
        const response = try testRequest(&server, raw);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, case.status) != null);
        try testing.expect(std.mem.indexOf(u8, response, case.header) != null);
        try testing.expect(std.mem.indexOf(u8, response, "cache-control: no-store\r\n") != null);
        const body = (std.mem.indexOf(
            u8,
            response,
            "\r\n\r\n",
        ) orelse return error.MissingHeaders) + 4;
        try testing.expectEqualStrings(case.body, response[body..]);
    }
    const ranges = [_]struct {
        value: []const u8,
        status: []const u8 = "206 Partial Content",
        content_range: []const u8,
        body: []const u8,
    }{
        .{
            .value = "bytes=2-5",
            .content_range = "bytes 2-5/10",
            .body = "2345",
        },
        .{
            .value = "bytes=7-",
            .content_range = "bytes 7-9/10",
            .body = "789",
        },
        .{
            .value = "bytes=-3",
            .content_range = "bytes 7-9/10",
            .body = "789",
        },
        .{
            .value = "bytes=8-100",
            .content_range = "bytes 8-9/10",
            .body = "89",
        },
        .{
            .value = "bytes=10-",
            .status = "416 Range Not Satisfiable",
            .content_range = "bytes */10",
            .body = "Range not satisfiable\n",
        },
    };
    for (ranges) |range| {
        const raw = try std.fmt.allocPrint(
            testing.allocator,
            "GET /clip.mp4 HTTP/1.1\r\nRange: {s}\r\n\r\n",
            .{range.value},
        );
        defer testing.allocator.free(raw);
        const response = try testRequest(&server, raw);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, range.status) != null);
        try testing.expect(std.mem.indexOf(u8, response, range.content_range) != null);
        const body = (std.mem.indexOf(
            u8,
            response,
            "\r\n\r\n",
        ) orelse return error.MissingHeaders) + 4;
        try testing.expectEqualStrings(range.body, response[body..]);
    }
    const saved = try tmp.dir.readFileAlloc(io, "index.html", testing.allocator, .limited(4096));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings(html, saved);
}

test "server rejects traversal and symlinks outside the document root" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "docs", .default_dir);
    const docs = try tmp.dir.openDir(io, "docs", .{});
    defer docs.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "outside docs" });
    var server: Server = .{ .root = docs, .listener = undefined };
    const targets = [_][]const u8{
        "/../secret.txt",
        "/%2e%2e/secret.txt",
        "/%2e%2e%2fsecret.txt",
        "/..%5csecret.txt",
        "/%00",
        "/%",
        "/%zz",
        "//example.com/",
        "/a//b",
    };
    for (targets) |target| {
        const raw = try std.fmt.allocPrint(
            testing.allocator,
            "GET {s} HTTP/1.1\r\n\r\n",
            .{target},
        );
        defer testing.allocator.free(raw);
        const response = try testRequest(&server, raw);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 "));
    }
    if (comptime builtin.os.tag == .windows) return;
    try docs.symLink(io, "../secret.txt", "linked.txt", .{});
    try docs.symLink(io, "..", "outside", .{ .is_directory = true });
    for ([_][]const u8{ "/linked.txt", "/outside/secret.txt" }) |target| {
        const raw = try std.fmt.allocPrint(
            testing.allocator,
            "GET {s} HTTP/1.1\r\n\r\n",
            .{target},
        );
        defer testing.allocator.free(raw);
        const response = try testRequest(&server, raw);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 404 "));
        try testing.expect(std.mem.indexOf(u8, response, "outside docs") == null);
    }
}
