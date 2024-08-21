const std = @import("std");

pub fn formatUnixTime(allocator: std.mem.Allocator, unixtime: i128) ![]const u8 {
    const secs: u64 = @intCast(@divFloor(unixtime, 1_000_000_000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return try std.fmt.allocPrint(allocator, "{s} {d}, {d}", .{
        formatMonth(month_day.month),
        month_day.day_index + 1,
        year_day.year,
    });
}

fn formatMonth(month: std.time.epoch.Month) []const u8 {
    return switch (month) {
        std.time.epoch.Month.jan => "January",
        std.time.epoch.Month.feb => "February",
        std.time.epoch.Month.mar => "March",
        std.time.epoch.Month.apr => "April",
        std.time.epoch.Month.may => "May",
        std.time.epoch.Month.jun => "June",
        std.time.epoch.Month.jul => "July",
        std.time.epoch.Month.aug => "August",
        std.time.epoch.Month.sep => "September",
        std.time.epoch.Month.oct => "October",
        std.time.epoch.Month.nov => "November",
        std.time.epoch.Month.dec => "December",
    };
}
