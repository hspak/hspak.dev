//! Content-based query parameters for generated HTML and stylesheet asset URLs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Assets = @This();

files: std.ArrayList(File) = .empty,
/// Borrowed from the caller until `deinit`.
roots: []const []const u8,
version: [Sha256.digest_length * 2]u8,

pub const Error = Allocator.Error || Io.Dir.StatFileError || Io.Dir.OpenError ||
    Io.Dir.Iterator.Error || Io.File.OpenError || Io.File.Reader.Error;
pub const RewriteError = Allocator.Error || Io.Dir.ReadFileAllocError ||
    Io.Dir.CreateFileAtomicError || Io.File.Writer.Error || Io.File.Atomic.ReplaceError;
pub const StylesheetError = RewriteError || Io.Dir.DeleteFileError;

const File = struct {
    path: []const u8,
};

/// Hash regular files beneath `roots`, relative to `docs`, without copying or modifying them.
/// Skip missing roots and symlinks. The version covers paths and bytes, independent of mtimes.
/// Borrow `roots` and its strings until `deinit`; roots must be relative and nonoverlapping.
/// Initialize fresh storage; pair success with `deinit(gpa)`. No allocations survive errors.
pub fn init(
    assets: *Assets,
    gpa: Allocator,
    io: Io,
    docs: Io.Dir,
    roots: []const []const u8,
) Error!void {
    assets.* = .{ .roots = roots, .version = undefined };
    errdefer assets.deinit(gpa);
    for (roots) |root| try assets.collect(gpa, io, docs, root);
    std.mem.sort(File, assets.files.items, {}, lessThan);
    var hash = Sha256.init(.{});
    for (assets.files.items) |file| {
        const digest = try hashFile(io, docs, file.path);
        const length = std.mem.toBytes(std.mem.nativeToLittle(u64, file.path.len));
        hash.update(&length);
        hash.update(file.path);
        hash.update(&digest);
    }
    assets.version = std.fmt.bytesToHex(hash.finalResult(), .lower);
}

/// Free owned paths and poison the asset index. Files on disk are unchanged.
pub fn deinit(assets: *Assets, gpa: Allocator) void {
    for (assets.files.items) |file| gpa.free(file.path);
    assets.files.deinit(gpa);
    assets.* = undefined;
}

/// Set `v` on managed root-relative href/src attributes emitted by the HTML renderer.
/// Map the editable /index.css to its generated /site.css, including versioned font references.
/// Preserve other parameters, fragments, escaping, page links, external URLs, and code samples.
/// Caller owns the result and must free it with `gpa`.
pub fn rewriteHtml(assets: *const Assets, gpa: Allocator, html: []const u8) Allocator.Error![]u8 {
    var output: Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    var offset: usize = 0;
    var copied: usize = 0;
    while (offset < html.len) : (offset += 1) {
        const rest = html[offset..];
        const start = if (std.mem.startsWith(u8, rest, " href=\"/"))
            offset + " href=\"".len
        else if (std.mem.startsWith(u8, rest, " src=\"/"))
            offset + " src=\"".len
        else
            continue;
        const end = std.mem.indexOfScalarPos(u8, html, start, '"') orelse break;
        const url = html[start..end];
        if (assets.isManaged(url)) {
            output.writer.writeAll(html[copied..start]) catch return error.OutOfMemory;
            assets.writeUrl(&output.writer, url, "&amp;") catch return error.OutOfMemory;
            copied = end;
        }
        offset = end;
    }
    output.writer.writeAll(html[copied..]) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

/// Add query versions to managed CSS url() references without changing comments or strings.
/// Relative references are resolved from the site root, where index.css and site.css live.
/// Caller owns the result and must free it with `gpa`.
pub fn rewriteCss(assets: *const Assets, gpa: Allocator, css: []const u8) Allocator.Error![]u8 {
    var output: Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    var offset: usize = 0;
    var copied: usize = 0;
    while (offset < css.len) {
        if (std.mem.startsWith(u8, css[offset..], "/*")) {
            const close = std.mem.indexOfPos(u8, css, offset + 2, "*/") orelse break;
            offset = close + 2;
            continue;
        }
        if (css[offset] == '"' or css[offset] == '\'') {
            offset = (quotedEnd(css, offset) orelse break) + 1;
            continue;
        }
        if (offset + 3 > css.len or !std.ascii.eqlIgnoreCase(css[offset..][0..3], "url") or
            (offset > 0 and isCssName(css[offset - 1])))
        {
            offset += 1;
            continue;
        }
        var start = offset + 3;
        while (start < css.len and std.ascii.isWhitespace(css[start])) : (start += 1) {}
        if (start == css.len or css[start] != '(') {
            offset += 3;
            continue;
        }
        start += 1;
        while (start < css.len and std.ascii.isWhitespace(css[start])) : (start += 1) {}
        if (start == css.len) break;
        var end: usize = undefined;
        var close: usize = undefined;
        if (css[start] == '"' or css[start] == '\'') {
            end = quotedEnd(css, start) orelse break;
            start += 1;
            close = end + 1;
            while (close < css.len and std.ascii.isWhitespace(css[close])) : (close += 1) {}
            if (close == css.len or css[close] != ')') {
                offset = close;
                continue;
            }
        } else {
            close = start;
            while (close < css.len and css[close] != ')') : (close += 1) {
                if (css[close] == '\\' and close + 1 < css.len) close += 1;
            }
            if (close == css.len) break;
            end = close;
            while (end > start and std.ascii.isWhitespace(css[end - 1])) : (end -= 1) {}
        }
        const url = css[start..end];
        if (assets.isManaged(url)) {
            output.writer.writeAll(css[copied..start]) catch return error.OutOfMemory;
            assets.writeUrl(&output.writer, url, "&") catch return error.OutOfMemory;
            copied = end;
        }
        offset = close + 1;
    }
    output.writer.writeAll(css[copied..]) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

/// Write the current site.css from editable index.css with versioned dependency URLs.
/// Source CSS is never rewritten, so generated changes cannot retrigger the source watcher.
/// Remove site.css if the source is absent.
pub fn writeStylesheet(
    assets: *const Assets,
    gpa: Allocator,
    io: Io,
    docs: Io.Dir,
) StylesheetError!void {
    const source = docs.readFileAlloc(io, "index.css", gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            docs.deleteFile(io, "site.css") catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
            return;
        },
        else => return err,
    };
    defer gpa.free(source);
    const css = try assets.rewriteCss(gpa, source);
    defer gpa.free(css);
    try writeGenerated(io, docs, "site.css", css);
}

/// Atomically replace generated HTML with query versions for this build.
pub fn rewriteFile(
    assets: *const Assets,
    gpa: Allocator,
    io: Io,
    docs: Io.Dir,
    path: []const u8,
) RewriteError!void {
    const html = try docs.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(html);
    const rewritten = try assets.rewriteHtml(gpa, html);
    defer gpa.free(rewritten);
    try writeGenerated(io, docs, path, rewritten);
}

fn writeGenerated(io: Io, docs: Io.Dir, path: []const u8, bytes: []const u8) RewriteError!void {
    var file = try docs.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.replace(io);
}

fn isManaged(assets: *const Assets, url: []const u8) bool {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    var path = url[0..end];
    while (std.mem.startsWith(u8, path, "./")) path = path[2..];
    if (std.mem.startsWith(u8, path, "/")) path = path[1..];
    if (std.mem.eql(u8, path, "site.css")) return true;
    for (assets.roots) |root| {
        const length = pathPrefixLength(path, root) orelse continue;
        if (length == path.len or path[length] == '/') return true;
    }
    return false;
}

fn writeUrl(
    assets: *const Assets,
    writer: *Io.Writer,
    url: []const u8,
    separator: []const u8,
) Io.Writer.Error!void {
    const fragment = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    const query = std.mem.indexOfScalar(u8, url[0..fragment], '?') orelse fragment;
    const path = url[0..query];
    try writer.writeAll(if (std.mem.eql(u8, path, "/index.css")) "/site.css" else path);
    var next_separator: []const u8 = "?";
    if (query < fragment) {
        var parameters = std.mem.splitSequence(u8, url[query + 1 .. fragment], separator);
        while (parameters.next()) |parameter| {
            const name_end = std.mem.indexOfScalar(u8, parameter, '=') orelse parameter.len;
            if (parameter.len == 0 or std.mem.eql(u8, parameter[0..name_end], "v")) continue;
            try writer.writeAll(next_separator);
            try writer.writeAll(parameter);
            next_separator = separator;
        }
    }
    try writer.writeAll(next_separator);
    try writer.writeAll("v=");
    try writer.writeAll(&assets.version);
    try writer.writeAll(url[fragment..]);
}

fn quotedEnd(source: []const u8, start: usize) ?usize {
    var offset = start + 1;
    while (offset < source.len) : (offset += 1) {
        if (source[offset] == '\\') {
            offset += 1;
        } else if (source[offset] == source[start]) {
            return offset;
        }
    }
    return null;
}

fn isCssName(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

fn collect(assets: *Assets, gpa: Allocator, io: Io, docs: Io.Dir, path: []const u8) Error!void {
    const stat = docs.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .file) {
        try assets.files.ensureUnusedCapacity(gpa, 1);
        assets.files.appendAssumeCapacity(.{ .path = try gpa.dupe(u8, path) });
        return;
    }
    if (stat.kind != .directory) return;
    const dir = try docs.openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const child = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, entry.name });
        defer gpa.free(child);
        try assets.collect(gpa, io, docs, child);
    }
}

fn lessThan(_: void, left: File, right: File) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

fn hashFile(io: Io, dir: Io.Dir, path: []const u8) Error![Sha256.digest_length]u8 {
    const input = try dir.openFile(io, path, .{ .follow_symlinks = false });
    defer input.close(io);
    var hash = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |read_err| return read_err,
        };
        if (count == 0) break;
        const bytes = buffer[0..count];
        hash.update(bytes);
    }
    return hash.finalResult();
}

fn pathPrefixLength(url: []const u8, path: []const u8) ?usize {
    var offset: usize = 0;
    for (path) |byte| {
        if (offset == url.len) return null;
        var decoded = url[offset];
        if (decoded == '%' and offset + 2 < url.len) {
            const high = std.fmt.charToDigit(url[offset + 1], 16) catch return null;
            const low = std.fmt.charToDigit(url[offset + 2], 16) catch return null;
            decoded = high * 16 + low;
            offset += 2;
        } else if (decoded == '&') {
            const entities = .{
                .{ "&amp;", '&' },
                .{ "&quot;", '"' },
                .{ "&#39;", '\'' },
                .{ "&lt;", '<' },
                .{ "&gt;", '>' },
            };
            inline for (entities) |entity| {
                if (std.mem.startsWith(u8, url[offset..], entity[0])) {
                    decoded = entity[1];
                    offset += entity[0].len - 1;
                    break;
                }
            }
        }
        if (decoded != byte) return null;
        offset += 1;
    }
    return offset;
}

test "asset URLs preserve encoding suffixes and unrelated markup" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var assets: Assets = undefined;
    try assets.init(gpa, testing.io, tmp.dir, &.{ "post/test/assets", "index.css" });
    defer assets.deinit(gpa);
    const unchanged = "<a href=\"/post/test/\">Post</a><a href=\"/index.css-other\">Other</a>" ++
        "<img src=\"https://example.com/index.css\" /><a href=\"#note\">Note</a>" ++
        "<img src=\"//example.com/index.css\" /><code>href=&quot;/index.css&quot;</code>";
    const source = "<link href=\"/index.css?v=old\" />" ++
        "<a href=\"/post/test/assets/screen%20shot.png?q=1&amp;v=old" ++
        "&amp;x=2&amp;v=older#detail\">" ++
        "<img src=\"/post/test/assets/a&amp;b.png#image\" /></a>" ++ unchanged;
    const expected = try std.fmt.allocPrint(
        gpa,
        "<link href=\"/site.css?v={s}\" />" ++
            "<a href=\"/post/test/assets/screen%20shot.png?q=1&amp;x=2&amp;v={s}#detail\">" ++
            "<img src=\"/post/test/assets/a&amp;b.png?v={s}#image\" /></a>{s}",
        .{
            assets.version,
            assets.version,
            assets.version,
            unchanged,
        },
    );
    defer gpa.free(expected);
    const actual = try assets.rewriteHtml(gpa, source);
    defer gpa.free(actual);
    try testing.expectEqualStrings(expected, actual);
    const repeated = try assets.rewriteHtml(gpa, actual);
    defer gpa.free(repeated);
    try testing.expectEqualStrings(actual, repeated);
}

test "asset CSS versions local dependencies without changing strings or comments" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var assets: Assets = undefined;
    try assets.init(gpa, testing.io, tmp.dir, &.{"fonts"});
    defer assets.deinit(gpa);
    const unchanged = "/* url(\"fonts/ignored.woff2\") */\n" ++
        "x::before { content: 'url(\"fonts/literal.woff2\")'; }\n" ++
        "x { a: url(data:font/woff2;base64,AAAA); b: url(https://example.com/font.woff2); " ++
        "c: url(//example.com/font.woff2); d: url(#icon); }\n";
    const source = unchanged ++
        "a { src: url(\"fonts/regular.woff2?download=1&v=old#font\"); }\n" ++
        "b { src: URL( /fonts/bold.woff2 ); }\n" ++
        "c { src: url('./fonts/italic.woff2'); }\n";
    const expected = try std.fmt.allocPrint(
        gpa,
        "{s}a {{ src: url(\"fonts/regular.woff2?download=1&v={s}#font\"); }}\n" ++
            "b {{ src: URL( /fonts/bold.woff2?v={s} ); }}\n" ++
            "c {{ src: url('./fonts/italic.woff2?v={s}'); }}\n",
        .{
            unchanged,
            assets.version,
            assets.version,
            assets.version,
        },
    );
    defer gpa.free(expected);
    const actual = try assets.rewriteCss(gpa, source);
    defer gpa.free(actual);
    try testing.expectEqualStrings(expected, actual);
    const repeated = try assets.rewriteCss(gpa, actual);
    defer gpa.free(repeated);
    try testing.expectEqualStrings(actual, repeated);
}
