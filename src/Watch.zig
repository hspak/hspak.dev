//! Poll a directory tree and selected files, coalescing changes until two scans agree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Watch = @This();
const log = std.log.scoped(.watch);

dir: Io.Dir = .cwd(),
path: []const u8 = ".",
/// Additional regular files relative to `dir`; absent files are watched for creation.
extra_files: []const []const u8 = &.{},
snapshot: Snapshot = .{},
pending: bool = false,

pub const Error = Allocator.Error || Io.Dir.OpenError ||
    Io.Dir.Iterator.Error || Io.Dir.StatFileError;

const Stamp = struct {
    inode: Io.File.INode,
    size: u64,
    mtime: Io.Timestamp,
    ctime: Io.Timestamp,
};

const Snapshot = struct {
    files: std.StringHashMapUnmanaged(Stamp) = .empty,

    fn read(
        gpa: Allocator,
        io: Io,
        parent: Io.Dir,
        path: []const u8,
        extra_files: []const []const u8,
    ) Error!Snapshot {
        const dir = try parent.openDir(
            io,
            path,
            .{
                .iterate = true,
                .follow_symlinks = false,
            },
        );
        defer dir.close(io);
        var snapshot: Snapshot = .{};
        errdefer snapshot.deinit(gpa);

        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            // Match the renderer: regular files only, including nested assets.
            if (entry.kind != .file) continue;
            const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
            const name = try Io.Dir.path.join(gpa, &.{ path, entry.path });
            defer gpa.free(name);
            try snapshot.recordFile(gpa, name, stat);
        }
        for (extra_files) |file_path| {
            const stat = parent.statFile(
                io,
                file_path,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            try snapshot.recordFile(gpa, file_path, stat);
        }
        return snapshot;
    }

    fn recordFile(
        snapshot: *Snapshot,
        gpa: Allocator,
        path: []const u8,
        stat: Io.File.Stat,
    ) Allocator.Error!void {
        if (stat.kind != .file) return;
        const stamp: Stamp = .{
            .inode = stat.inode,
            .size = stat.size,
            .mtime = stat.mtime,
            .ctime = stat.ctime,
        };
        if (snapshot.files.getPtr(path)) |existing| {
            existing.* = stamp;
            return;
        }
        const name = try gpa.dupe(u8, path);
        errdefer gpa.free(name);
        try snapshot.files.put(gpa, name, stamp);
    }

    fn deinit(snapshot: *Snapshot, gpa: Allocator) void {
        var names = snapshot.files.keyIterator();
        while (names.next()) |name| gpa.free(name.*);
        snapshot.files.deinit(gpa);
        snapshot.* = undefined;
    }

    fn eql(a: *const Snapshot, b: *const Snapshot) bool {
        if (a.files.count() != b.files.count()) return false;
        var iter = a.files.iterator();
        while (iter.next()) |entry| {
            const other = b.files.get(entry.key_ptr.*) orelse return false;
            if (!std.meta.eql(entry.value_ptr.*, other)) return false;
        }
        return true;
    }
};

/// Capture the initial snapshot in a fresh `Watch` with `dir` and `path` set.
/// Borrows those fields and `extra_files` until `deinit`; the caller must keep them valid.
/// On success, call `deinit` with `gpa`. On error, no resources are retained.
pub fn init(watch: *Watch, gpa: Allocator, io: Io) Error!void {
    watch.snapshot = try Snapshot.read(gpa, io, watch.dir, watch.path, watch.extra_files);
}

/// Free the snapshot using the same allocator passed to `init` and `poll`.
pub fn deinit(watch: *Watch, gpa: Allocator) void {
    watch.snapshot.deinit(gpa);
    watch.* = undefined;
}

/// Return true once per settled batch of edits. Call at a fixed interval.
/// Requires successful `init` and its allocator; owns any captured paths.
/// Failed scans leave the last snapshot intact so the caller can retry.
pub fn poll(watch: *Watch, gpa: Allocator, io: Io) Error!bool {
    var next = try Snapshot.read(gpa, io, watch.dir, watch.path, watch.extra_files);
    if (!watch.snapshot.eql(&next)) {
        watch.snapshot.deinit(gpa);
        watch.snapshot = next;
        watch.pending = true;
        return false;
    }
    next.deinit(gpa);
    const changed = watch.pending;
    watch.pending = false;
    if (changed) log.debug("changes settled in {s}", .{watch.path});
    return changed;
}

test "watch coalesces edits and detects nested files, renames, and deletions" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "posts");
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/0001-test.md", .data = "first" });
    var watch: Watch = .{ .dir = tmp.dir, .path = "posts" };
    try watch.init(gpa, io);
    defer watch.deinit(gpa);
    try testing.expect(!try watch.poll(gpa, io));

    try tmp.dir.writeFile(io, .{ .sub_path = "posts/0001-test.md", .data = "second" });
    try testing.expect(!try watch.poll(gpa, io));
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/0001-test.md", .data = "third edit" });
    try testing.expect(!try watch.poll(gpa, io));
    try testing.expect(try watch.poll(gpa, io));
    try testing.expect(!try watch.poll(gpa, io));

    try tmp.dir.createDirPath(io, "posts/0001-test/nested");
    try tmp.dir.writeFile(io, .{
        .sub_path = "posts/0001-test/nested/video.mp4",
        .data = "video",
    });
    try testing.expect(!try watch.poll(gpa, io));
    try testing.expect(try watch.poll(gpa, io));
    try tmp.dir.rename("posts/0001-test.md", tmp.dir, "posts/0002-renamed.md", io);
    try testing.expect(!try watch.poll(gpa, io));
    try testing.expect(try watch.poll(gpa, io));
    try tmp.dir.deleteTree(io, "posts/0001-test");
    try testing.expect(!try watch.poll(gpa, io));
    try testing.expect(try watch.poll(gpa, io));

    // Reopen the root each scan so replacing the directory does not lose it.
    try tmp.dir.rename("posts", tmp.dir, "moved", io);
    try testing.expectError(error.FileNotFound, watch.poll(gpa, io));
    try tmp.dir.createDirPath(io, "posts");
    try testing.expect(!try watch.poll(gpa, io));
    try testing.expect(try watch.poll(gpa, io));
    try testing.expect(!try watch.poll(gpa, io));
}
