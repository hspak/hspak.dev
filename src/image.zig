//! Image thumbnails through the native ImageMagick 7 MagickWand library.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("magickwand");

const log = std.log.scoped(.image);

pub const Error = Allocator.Error || error{
    InvalidDimensions,
    ImageMagickException,
};

/// Initialize ImageMagick once before processing images. Pair with `deinit`
/// after all image operations have finished; this controls process-wide resources.
pub fn init() void {
    c.MagickWandGenesis();
}

/// Release process-wide ImageMagick resources after all image operations finish.
pub fn deinit() void {
    c.MagickWandTerminus();
}

/// Raster formats for which this site generates thumbnails. Other assets are copied as-is.
pub fn supportsPath(path: []const u8) bool {
    const extension = std.Io.Dir.path.extension(path);
    for ([_][]const u8{
        ".png",
        ".jpg",
        ".jpeg",
        ".webp",
    }) |supported| {
        if (std.ascii.eqlIgnoreCase(extension, supported)) return true;
    }
    return false;
}

/// Decode borrowed bytes and return a thumbnail in the source format, preserving
/// aspect ratio and applying camera orientation. `null` means the image fits already
/// or contains multiple frames. Caller frees returned bytes with `gpa`.
/// Requires `init`; all per-image native resources are released on success and error.
pub fn thumbnail(gpa: Allocator, encoded: []const u8, max_width: usize) Error!?[]u8 {
    if (max_width == 0) return error.InvalidDimensions;
    if (isAnimatedPng(encoded)) return null;
    const wand = c.NewMagickWand() orelse return error.OutOfMemory;
    defer _ = c.DestroyMagickWand(wand);

    try check(wand, c.MagickReadImageBlob(wand, encoded.ptr, encoded.len));
    if (c.MagickGetNumberImages(wand) != 1) return null;
    try check(wand, c.MagickAutoOrientImage(wand));
    const width = c.MagickGetImageWidth(wand);
    const height = c.MagickGetImageHeight(wand);
    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (width <= max_width) return null;

    // Wide arithmetic avoids overflow; round to the nearest pixel with a minimum of one.
    const scaled_height: usize = @intCast(@max(
        1,
        (@as(u128, height) * max_width + width / 2) / width,
    ));
    try check(wand, c.MagickThumbnailImage(wand, max_width, scaled_height));
    // Encoding time must not change the bytes of an otherwise identical thumbnail.
    try check(wand, c.MagickSetOption(wand, "png:exclude-chunk", "date,time"));
    var length: usize = 0;
    const blob = c.MagickGetImageBlob(wand, &length);
    if (blob == null) {
        try check(wand, c.MagickFalse);
        unreachable;
    }
    defer _ = c.MagickRelinquishMemory(blob);
    return try gpa.dupe(u8, blob[0..length]);
}

fn isAnimatedPng(encoded: []const u8) bool {
    if (!std.mem.startsWith(u8, encoded, "\x89PNG\r\n\x1a\n")) return false;
    // MagickWand's PNG decoder exposes only APNG's default frame. The animation
    // control chunk precedes image data, so detect it before a resize can discard frames.
    var offset: usize = 8;
    while (encoded.len - offset >= 12) {
        const length = std.mem.readInt(u32, encoded[offset..][0..4], .big);
        if (length > encoded.len - offset - 12) return false;
        const kind = encoded[offset + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "acTL")) return true;
        if (std.mem.eql(u8, kind, "IDAT")) return false;
        offset += @as(usize, length) + 12;
    }
    return false;
}

fn check(wand: *c.MagickWand, result: c.MagickBooleanType) Error!void {
    if (result != c.MagickFalse) return;
    var severity: c.ExceptionType = undefined;
    const description = c.MagickGetException(wand, &severity);
    if (description != null) {
        defer _ = c.MagickRelinquishMemory(description);
        log.debug("{s}", .{std.mem.span(description)});
    }
    if (severity == c.ResourceLimitError or severity == c.ResourceLimitFatalError) {
        return error.OutOfMemory;
    }
    return error.ImageMagickException;
}

test "native thumbnails preserve aspect ratio without upscaling" {
    const testing = std.testing;
    const gpa = testing.allocator;
    init();
    defer deinit();

    const input = "P6\n4 2\n255\n" ++ "\xff\x00\x00" ** 8;
    const output = (try thumbnail(gpa, input, 2)).?;
    defer gpa.free(output);
    const wand = c.NewMagickWand() orelse return error.OutOfMemory;
    defer _ = c.DestroyMagickWand(wand);
    try check(wand, c.MagickReadImageBlob(wand, output.ptr, output.len));
    try testing.expectEqual(@as(usize, 2), c.MagickGetImageWidth(wand));
    try testing.expectEqual(@as(usize, 1), c.MagickGetImageHeight(wand));
    try testing.expectEqual(null, try thumbnail(gpa, input, 4));
    try testing.expectEqual(null, try thumbnail(gpa, input, 8));
}

test "native thumbnails reject invalid dimensions and image bytes" {
    const testing = std.testing;
    init();
    defer deinit();

    try testing.expectError(error.InvalidDimensions, thumbnail(testing.allocator, "", 0));
    try testing.expectError(error.ImageMagickException, thumbnail(
        testing.allocator,
        "invalid image",
        720,
    ));
}

test "native thumbnails retain PNG transparency and skip animated WebP and PNG" {
    const testing = std.testing;
    const gpa = testing.allocator;
    init();
    defer deinit();

    const output = (try thumbnail(gpa, @embedFile("test_data/thumbnail.png"), 720)).?;
    defer gpa.free(output);
    try testing.expect(std.mem.startsWith(u8, output, "\x89PNG\r\n\x1a\n"));
    const wand = c.NewMagickWand() orelse return error.OutOfMemory;
    defer _ = c.DestroyMagickWand(wand);
    try check(wand, c.MagickReadImageBlob(wand, output.ptr, output.len));
    try testing.expectEqual(@as(usize, 720), c.MagickGetImageWidth(wand));
    try testing.expectEqual(@as(usize, 450), c.MagickGetImageHeight(wand));
    try testing.expect(c.MagickGetImageAlphaChannel(wand) != c.MagickFalse);
    try testing.expectEqual(null, try thumbnail(gpa, @embedFile("test_data/animated.webp"), 720));
    try testing.expectEqual(null, try thumbnail(gpa, @embedFile("test_data/animated.png"), 720));
}

test "native thumbnails apply JPEG camera orientation before sizing" {
    const testing = std.testing;
    const gpa = testing.allocator;
    init();
    defer deinit();

    const output = (try thumbnail(gpa, @embedFile("test_data/oriented.jpg"), 2)).?;
    defer gpa.free(output);
    const wand = c.NewMagickWand() orelse return error.OutOfMemory;
    defer _ = c.DestroyMagickWand(wand);
    try check(wand, c.MagickReadImageBlob(wand, output.ptr, output.len));
    try testing.expectEqual(@as(usize, 2), c.MagickGetImageWidth(wand));
    try testing.expectEqual(@as(usize, 1), c.MagickGetImageHeight(wand));
}

test "native thumbnails propagate Zig allocator exhaustion" {
    const testing = std.testing;
    init();
    defer deinit();

    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, thumbnail(
        failing.allocator(),
        @embedFile("test_data/thumbnail.png"),
        720,
    ));
}

test "native PNG thumbnail hashes are stable across regeneration" {
    const testing = std.testing;
    const gpa = testing.allocator;
    init();
    defer deinit();

    const first = (try thumbnail(gpa, @embedFile("test_data/thumbnail.png"), 720)).?;
    defer gpa.free(first);
    // PNG timestamps have one-second resolution; cross it to expose metadata churn.
    try std.Io.sleep(testing.io, .fromMilliseconds(1100), .awake);
    const second = (try thumbnail(gpa, @embedFile("test_data/thumbnail.png"), 720)).?;
    defer gpa.free(second);
    var first_hash: [32]u8 = undefined;
    var second_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(first, &first_hash, .{});
    std.crypto.hash.sha2.Sha256.hash(second, &second_hash, .{});
    try testing.expectEqualSlices(u8, &first_hash, &second_hash);
}
