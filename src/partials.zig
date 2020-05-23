const std = @import("std");
const fs = std.fs;

pub fn writeHeader(output_file: fs.File, is_index: bool) !void {
    @setEvalBranchQuota(3000);
    const stream = output_file.outStream();
    const header = if (is_index) "<h1>Blog</h1>" else "<a href=\"https://hspak.dev\"><h1>Blog</h1></a>";
    return stream.print(
        \\<!doctype html>
        \\<html>
        \\  <head>
        \\    <title>Blog: Hong Shick Pak</title>
        \\    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        \\    <meta name="author" content="Hong Shick Pak">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <meta name="keywords" content="Michael Pak, Hong Shick Pak, Hong, Shick, Pak, Michael, Blog, hspak">
        \\    <meta name="description" content="Blog of Hong Shick Pak">
        \\    <meta property="og:url" content="https://hspak.dev">
        \\    <meta property="og:type" content="website">
        \\    <meta property="og:site_name" content="Hspak">
        \\    <meta property="og:title" content="Hspak">
        \\    <meta property="og:description" content="Blog of Hong Shick Pak">
        \\    <meta property="twitter:creator" content="@hspasta">
        \\    <link rel="canonical" href="https://hspak.dev/">
        \\    <link rel="stylesheet" href="/index.css">
        \\  </head>
        \\  <body>
        \\    <div class="container">
        \\      <div class="block">{}</div>
        \\
    , .{header});
}

pub fn writeFooter(output_file: fs.File) !void {
    const stream = output_file.outStream();
    return stream.print(
        \\       <div class="block">
        \\        <div class="footer">
        \\          <a href="#top">To Top</a> ·
        \\          <a href="https://hspak.com">By Hong</a>
        \\        </div>
        \\      </div>
        \\    </div>
        \\  </body>
        \\</html>
        \\
    , .{});
}