//! Calendar formatting for Unix timestamps.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Timestamp = std.Io.Timestamp;

const log = std.log.scoped(.time);

/// Format `timestamp` as `Month D, YYYY`. Caller owns the returned slice.
pub fn formatTimestamp(gpa: Allocator, timestamp: Timestamp) Allocator.Error![]const u8 {
    const secs: u64 = @intCast(@max(timestamp.toSeconds(), 0));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(gpa, "{s} {d}, {d}", .{
        formatMonth(month_day.month),
        month_day.day_index + 1,
        year_day.year,
    });
}

fn formatMonth(month: std.time.epoch.Month) []const u8 {
    return switch (month) {
        .jan => "January",
        .feb => "February",
        .mar => "March",
        .apr => "April",
        .may => "May",
        .jun => "June",
        .jul => "July",
        .aug => "August",
        .sep => "September",
        .oct => "October",
        .nov => "November",
        .dec => "December",
    };
}
