//! Shared HTML header and footer for generated pages.

const std = @import("std");
const Writer = std.Io.Writer;

const log = std.log.scoped(.partials);

/// Write the document head and site header.
pub fn writeHeader(w: *Writer, is_index: bool, title: []const u8) Writer.Error!void {
    @setEvalBranchQuota(3000);
    const header = if (is_index)
        \\<div class="indexHeader">
        \\        <div class="indexBlock"><h1>Blog</h1></div>
        \\        <div class="indexBlock"><a href="https://hspak.com/">By Hong</a></div>
        \\      </div>
    else
        \\<a href="/"><h1>Blog</h1></a>
    ;

    return w.print(
        \\<!doctype html>
        \\<html lang="en">
        \\  <head>
        \\    <title>{s}</title>
        \\    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        \\    <meta http-equiv="Content-Security-Policy" content="default-src 'self';">
        \\    <meta name="color-scheme" content="light dark">
        \\    <meta name="referrer" content="strict-origin">
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
        \\    <link rel="icon" href="/favicon.svg" type="image/svg+xml">
        \\    <link rel="icon" href="/favicon.ico" sizes="32x32">
        \\    <link rel="apple-touch-icon" href="/apple-touch-icon.png">
        \\    <link rel="preload" href="/fonts/et-book/et-book-roman.woff2" as="font" type="font/woff2">
        \\    <link rel="stylesheet" href="/index.css">
        \\    <script src="/theme.js"></script>
        \\  </head>
        \\  <body>
        \\    <input type="checkbox" id="theme">
        \\    <label for="theme" title="Toggle color scheme"><span aria-hidden="true">◐</span><span>Toggle color scheme</span></label>
        \\    <div class="outer">
        \\    <div class="container">
        \\      <div class="block">
        \\      {s}
        \\      </div>
        \\
    , .{ title, header });
}

/// Write the footer and close the document.
pub fn writeFooter(w: *Writer, is_index: bool) Writer.Error!void {
    const author = if (is_index)
        \\
    else
        \\ · <a href="https://hspak.com">By Hong</a>
    ;
    return w.print(
        \\      <div class="block">
        \\        <div class="footer">
        \\          <a href="#top">To Top</a>{s}
        \\        </div>
        \\      </div>
        \\    </div>
        \\    </div>
        \\  </body>
        \\</html>
        \\
    , .{author});
}
