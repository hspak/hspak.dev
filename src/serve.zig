//! Serve the generated site with zhtps and startup-prepared zstd representations.

const std = @import("std");
const linux = std.os.linux;
const zhtps = @import("zhtps");
const security = @import("security.zig");
const server_options = @import("server_options");

const security_headers = [_]zhtps.http.Header{
    .{ .name = "Strict-Transport-Security", .value = "max-age=31536000; includeSubDomains" },
    .{ .name = "Content-Security-Policy", .value = security.content_security_policy },
    .{ .name = "X-Frame-Options", .value = "SAMEORIGIN" },
    .{ .name = "Referrer-Policy", .value = security.referrer_policy },
    .{
        .name = "Permissions-Policy",
        .value = "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    },
};

const api = struct {
    const files = zhtps.staticFiles(@This(), "/", .{ .root = server_options.document_root, .zstd = true });

    pub const lanes = .{ .files = .{
        .threads = server_options.file_threads,
        .queue = server_options.file_queue,
        .timeout_ms = 30_000,
    } };
    const content_routes = .{secured: {
        var route = files;
        route.handler = serve;
        break :secured route;
    }};

    // HTTP-01 validation can follow the HTTP redirect to this HTTPS route.
    pub const routes = if (server_options.acme_root) |root| .{
        zhtps.staticFiles(@This(), "/.well-known/acme-challenge", .{
            .root = root,
            .index_file = null,
        }),
    } ++ content_routes else content_routes;

    fn serve(call: *zhtps.Call(@This())) zhtps.EndpointError!zhtps.http.Response {
        var response = try files.handler(call);
        // The transport borrows headers until completion; keep them in request scratch.
        response.headers = try std.mem.concat(call.scratch.allocator(), zhtps.http.Header, &.{
            response.headers,
            &security_headers,
        });
        return response;
    }
};

var stopping: std.atomic.Value(bool) = .init(false);

fn stop(_: linux.SIG) callconv(.c) void {
    stopping.store(true, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    for (args[1..]) |arg| {
        if (!std.mem.eql(u8, arg, "--help")) continue;
        try std.Io.File.stdout().writeStreamingAll(init.io,
            \\Usage: zserve [zhtps options]
            \\Serve the configured document directory with startup-prepared zstd compression.
            \\Defaults: http://127.0.0.1:8080, admin listener disabled.
            \\  --address IP             Bind address
            \\  --port PORT              Port; 0 selects a free port
            \\  --tls-certificate PATH   PEM certificate chain
            \\  --tls-key PATH           PEM private key; enables HTTPS with certificate
            \\  --workers N             Transport workers (default: automatic)
            \\  --admin-connections N   Enable the admin listener with N connection slots
            \\  --no-access-log         Disable per-request logs
            \\All other zhtps configuration flags are accepted.
            \\Restart after deploying changed files to refresh compression.
            \\SIGINT and SIGTERM gracefully stop the server and remove its cache.
            \\
        );
        return;
    }
    // Put site defaults first so explicit zhtps flags can override them.
    const defaults = [_][]const u8{ "--admin-connections", "0" };
    const options = try std.mem.concat(gpa, []const u8, &.{ &defaults, args[1..] });
    const config = try zhtps.Config.parse(options);
    const action: linux.Sigaction = .{
        .handler = .{ .handler = stop },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    for ([_]linux.SIG{ .TERM, .INT }) |signal|
        _ = try zhtps.platform.check(linux.sigaction(signal, &action, null));
    try zhtps.Server(zhtps.Application(api)).run(init.gpa, init.io, config, &stopping);
}
