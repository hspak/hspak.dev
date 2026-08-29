//! Markdown-to-HTML converter for the subset of CommonMark this blog uses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ascii = std.ascii;

const log = std.log.scoped(.markdown);

/// Convert markdown `source` to HTML. The returned slice is allocated with
/// `gpa`; caller must free it.
pub fn toHtml(gpa: Allocator, source: []const u8) Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const blocks = try parse(arena.allocator(), source);

    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    renderBlocks(&aw.writer, blocks) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const Line = struct {
    raw: []const u8,
    indent: usize,
    rest: []const u8,
};

const Marker = struct {
    ordered: bool,
    start_number: u32,
    marker_indent: usize,
    content_indent: usize,
    content_offset: usize,
};

const Fence = struct {
    indent: usize,
    fence_len: usize,
    info: []const u8,
};

const Heading = struct {
    level: u8,
    text: []const u8,
};

const Code = struct {
    info: []const u8,
    text: []const u8,
};

const Block = union(enum) {
    paragraph: []const u8,
    heading: Heading,
    code: Code,
    quote: []Block,
    list: List,
    thematic_break,
};

const List = struct {
    ordered: bool,
    start: u32,
    loose: bool,
    items: [][]Block,
};

fn parse(arena: Allocator, source: []const u8) Allocator.Error![]Block {
    const lines = try splitLines(arena, source);
    var i: usize = 0;
    return parseBlocks(arena, lines, &i, lines.len);
}

fn splitLines(arena: Allocator, source: []const u8) Allocator.Error![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\n') {
            var end = i;
            if (end > start and source[end - 1] == '\r') end -= 1;
            try lines.append(arena, makeLine(source[start..end]));
            i += 1;
            start = i;
        } else {
            i += 1;
        }
    }
    if (start < source.len) {
        try lines.append(arena, makeLine(source[start..]));
    }
    return lines.toOwnedSlice(arena);
}

fn makeLine(raw: []const u8) Line {
    var indent: usize = 0;
    while (indent < raw.len and raw[indent] == ' ') indent += 1;
    return .{
        .raw = raw,
        .indent = indent,
        .rest = raw[indent..],
    };
}

fn isBlank(line: Line) bool {
    for (line.rest) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

fn parseBlocks(
    arena: Allocator,
    lines: []const Line,
    i: *usize,
    end: usize,
) Allocator.Error![]Block {
    var blocks: std.ArrayList(Block) = .empty;
    while (i.* < end) {
        const line = lines[i.*];
        if (isBlank(line)) {
            i.* += 1;
            continue;
        }
        if (parseFence(line)) |fence| {
            try blocks.append(arena, .{ .code = try parseCode(arena, lines, i, end, fence) });
            continue;
        }
        if (isThematicBreak(line)) {
            i.* += 1;
            try blocks.append(arena, .thematic_break);
            continue;
        }
        if (parseHeading(line)) |heading| {
            i.* += 1;
            try blocks.append(arena, .{ .heading = heading });
            continue;
        }
        if (isQuote(line)) {
            try blocks.append(arena, .{ .quote = try parseQuote(arena, lines, i, end) });
            continue;
        }
        if (parseMarker(line) != null) {
            try blocks.append(arena, .{ .list = try parseList(arena, lines, i, end) });
            continue;
        }
        try blocks.append(arena, .{ .paragraph = try parseParagraph(arena, lines, i, end) });
    }
    return blocks.toOwnedSlice(arena);
}

fn startsContainer(line: Line) bool {
    if (isBlank(line)) return true;
    if (parseFence(line) != null) return true;
    if (isThematicBreak(line)) return true;
    if (parseHeading(line) != null) return true;
    if (isQuote(line)) return true;
    if (parseMarker(line) != null) return true;
    return false;
}

fn parseParagraph(
    arena: Allocator,
    lines: []const Line,
    i: *usize,
    end: usize,
) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var first = true;
    while (i.* < end) {
        const line = lines[i.*];
        if (startsContainer(line)) break;
        if (!first) try text.append(arena, '\n');
        first = false;
        try text.appendSlice(arena, std.mem.trimEnd(u8, line.rest, " \t"));
        i.* += 1;
    }
    return text.toOwnedSlice(arena);
}

fn parseHeading(line: Line) ?Heading {
    if (line.indent > 3) return null;
    const rest = line.rest;
    var level: u8 = 0;
    while (level < rest.len and level < 6 and rest[level] == '#') level += 1;
    if (level == 0) return null;
    if (level < rest.len and rest[level] != ' ' and rest[level] != '\t') return null;
    var text = std.mem.trim(u8, rest[level..], " \t");
    var trail = text.len;
    while (trail > 0 and text[trail - 1] == '#') trail -= 1;
    if (trail < text.len and trail > 0 and (text[trail - 1] == ' ' or text[trail - 1] == '\t')) {
        text = std.mem.trimEnd(u8, text[0..trail], " \t");
    }
    return .{ .level = level, .text = text };
}

fn isThematicBreak(line: Line) bool {
    if (line.indent > 3) return false;
    var count: usize = 0;
    var char: ?u8 = null;
    for (line.rest) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c != '-' and c != '*' and c != '_') return false;
        if (char) |ch| {
            if (c != ch) return false;
        } else char = c;
        count += 1;
    }
    return count >= 3;
}

fn parseFence(line: Line) ?Fence {
    if (line.indent > 3) return null;
    const rest = line.rest;
    if (rest.len < 3 or rest[0] != '`') return null;
    var fence_len: usize = 0;
    while (fence_len < rest.len and rest[fence_len] == '`') fence_len += 1;
    if (fence_len < 3) return null;
    const info_raw = std.mem.trim(u8, rest[fence_len..], " \t");
    if (std.mem.indexOfScalar(u8, info_raw, '`') != null) return null;
    return .{
        .indent = line.indent,
        .fence_len = fence_len,
        .info = firstWord(info_raw),
    };
}

fn firstWord(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (std.mem.indexOfAny(u8, trimmed, " \t")) |idx| return trimmed[0..idx];
    return trimmed;
}

fn parseCode(
    arena: Allocator,
    lines: []const Line,
    i: *usize,
    end: usize,
    opening: Fence,
) Allocator.Error!Code {
    i.* += 1;
    var text: std.ArrayList(u8) = .empty;
    while (i.* < end) {
        const line = lines[i.*];
        if (isClosingFence(line, opening)) {
            i.* += 1;
            break;
        }
        const stripped = stripIndent(line.raw, opening.indent);
        try text.appendSlice(arena, stripped);
        try text.append(arena, '\n');
        i.* += 1;
    }
    return .{ .info = opening.info, .text = text.items };
}

fn isClosingFence(line: Line, opening: Fence) bool {
    if (line.indent > 3) return false;
    const rest = line.rest;
    var n: usize = 0;
    while (n < rest.len and rest[n] == '`') n += 1;
    if (n < opening.fence_len) return false;
    return std.mem.trim(u8, rest[n..], " \t").len == 0;
}

fn stripIndent(raw: []const u8, indent: usize) []const u8 {
    var idx: usize = 0;
    var remaining = indent;
    while (idx < raw.len and remaining > 0) : (idx += 1) {
        if (raw[idx] == ' ') {
            remaining -= 1;
        } else break;
    }
    return raw[idx..];
}

fn isQuote(line: Line) bool {
    if (line.indent > 3) return false;
    return line.rest.len > 0 and line.rest[0] == '>';
}

fn quoteInner(line: Line) Line {
    var idx: usize = 0;
    var extra: usize = 0;
    while (idx < line.raw.len and extra < 3 and line.raw[idx] == ' ') {
        idx += 1;
        extra += 1;
    }
    if (idx < line.raw.len and line.raw[idx] == '>') {
        idx += 1;
        if (idx < line.raw.len and line.raw[idx] == ' ') idx += 1;
    }
    return makeLine(line.raw[idx..]);
}

fn parseQuote(
    arena: Allocator,
    lines: []const Line,
    i: *usize,
    end: usize,
) Allocator.Error![]Block {
    var inner: std.ArrayList(Line) = .empty;
    while (i.* < end) {
        const line = lines[i.*];
        if (isQuote(line)) {
            try inner.append(arena, quoteInner(line));
            i.* += 1;
            continue;
        }
        if (isBlank(line)) break;
        if (startsContainer(line)) break;
        try inner.append(arena, makeLine(line.rest));
        i.* += 1;
    }
    var inner_i: usize = 0;
    return parseBlocks(arena, inner.items, &inner_i, inner.items.len);
}

fn parseMarker(line: Line) ?Marker {
    if (isBlank(line) or line.indent > 3) return null;
    const rest = line.rest;
    if (rest.len == 0) return null;

    var ordered = false;
    var start_number: u32 = 1;
    var marker_len: usize = 0;

    if (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') {
        marker_len = 1;
    } else if (ascii.isDigit(rest[0])) {
        var n: u32 = 0;
        var digits: usize = 0;
        while (digits < rest.len and digits < 9 and ascii.isDigit(rest[digits])) {
            n = n * 10 + (rest[digits] - '0');
            digits += 1;
        }
        if (digits == 0 or digits >= rest.len) return null;
        if (rest[digits] != '.' and rest[digits] != ')') return null;
        marker_len = digits + 1;
        ordered = true;
        start_number = n;
    } else {
        return null;
    }

    var spaces: usize = 0;
    if (marker_len < rest.len) {
        if (rest[marker_len] != ' ' and rest[marker_len] != '\t') return null;
        var s = marker_len;
        while (s < rest.len and rest[s] == ' ') {
            spaces += 1;
            s += 1;
        }
    }

    const pad: usize = if (spaces > 4) 1 else if (spaces == 0) 1 else spaces;
    const content_offset: usize = offset: {
        if (spaces > 4) break :offset line.indent + marker_len + 1;
        if (spaces == 0) break :offset line.raw.len;
        break :offset line.indent + marker_len + spaces;
    };

    return .{
        .ordered = ordered,
        .start_number = start_number,
        .marker_indent = line.indent,
        .content_indent = line.indent + marker_len + pad,
        .content_offset = @min(content_offset, line.raw.len),
    };
}

fn parseList(
    arena: Allocator,
    lines: []const Line,
    i: *usize,
    end: usize,
) Allocator.Error!List {
    // parseList is only called when the current line has a list marker.
    const first = parseMarker(lines[i.*]) orelse unreachable;
    var items: std.ArrayList([]Block) = .empty;
    var loose = false;

    while (i.* < end) {
        const marker = parseMarker(lines[i.*]) orelse break;
        if (marker.ordered != first.ordered) break;
        if (marker.marker_indent != first.marker_indent) break;

        var item_lines: std.ArrayList(Line) = .empty;
        try item_lines.append(arena, makeLine(lines[i.*].raw[marker.content_offset..]));
        i.* += 1;

        while (i.* < end) {
            const line = lines[i.*];
            if (isBlank(line)) {
                const next = nextNonBlank(lines, i.* + 1, end);
                if (next) |n| {
                    if (lineBelongsToItem(lines[n], marker)) {
                        loose = true;
                        try item_lines.append(arena, makeLine(""));
                        i.* += 1;
                        continue;
                    }
                    if (parseMarker(lines[n])) |sib| {
                        if (sib.marker_indent == marker.marker_indent and
                            sib.ordered == marker.ordered)
                        {
                            loose = true;
                            i.* = n;
                            break;
                        }
                    }
                }
                break;
            }
            if (lineBelongsToItem(line, marker)) {
                const stripped = stripIndent(line.raw, marker.content_indent);
                try item_lines.append(arena, makeLine(stripped));
                i.* += 1;
                continue;
            }
            if (parseMarker(line)) |sib| {
                if (sib.marker_indent <= marker.marker_indent) break;
            }
            if (startsContainer(line)) break;
            try item_lines.append(arena, makeLine(line.rest));
            i.* += 1;
        }

        var item_i: usize = 0;
        const blocks = try parseBlocks(arena, item_lines.items, &item_i, item_lines.items.len);
        try items.append(arena, blocks);
    }

    return .{
        .ordered = first.ordered,
        .start = first.start_number,
        .loose = loose,
        .items = try items.toOwnedSlice(arena),
    };
}

fn nextNonBlank(lines: []const Line, start: usize, end: usize) ?usize {
    var i = start;
    while (i < end) : (i += 1) {
        if (!isBlank(lines[i])) return i;
    }
    return null;
}

fn lineBelongsToItem(line: Line, marker: Marker) bool {
    if (isBlank(line)) return false;
    return line.indent >= marker.content_indent;
}

fn renderBlocks(w: *Writer, blocks: []const Block) Writer.Error!void {
    for (blocks) |block| try renderBlock(w, block);
}

fn renderBlock(w: *Writer, block: Block) Writer.Error!void {
    switch (block) {
        .paragraph => |text| {
            try w.writeAll("<p>");
            try renderInlines(w, text);
            try w.writeAll("</p>\n");
        },
        .heading => |heading| {
            try w.print("<h{d}>", .{heading.level});
            try renderInlines(w, heading.text);
            try w.print("</h{d}>\n", .{heading.level});
        },
        .code => |code| {
            if (code.info.len == 0) {
                try w.writeAll("<pre><code>");
            } else {
                try w.writeAll("<pre><code class=\"language-");
                try writeEscaped(w, code.info);
                try w.writeAll("\">");
            }
            try writeEscaped(w, code.text);
            try w.writeAll("</code></pre>\n");
        },
        .quote => |inner| {
            try w.writeAll("<blockquote>\n");
            try renderBlocks(w, inner);
            try w.writeAll("</blockquote>\n");
        },
        .list => |list| try renderList(w, list),
        .thematic_break => try w.writeAll("<hr />\n"),
    }
}

fn renderList(w: *Writer, list: List) Writer.Error!void {
    const tag = if (list.ordered) "ol" else "ul";
    if (list.ordered and list.start != 1) {
        try w.print("<ol start=\"{d}\">\n", .{list.start});
    } else {
        try w.print("<{s}>\n", .{tag});
    }
    for (list.items) |item| {
        if (list.loose) {
            try w.writeAll("<li>\n");
            try renderBlocks(w, item);
            try w.writeAll("</li>\n");
        } else {
            try w.writeAll("<li>");
            try renderTightItem(w, item);
            try w.writeAll("</li>\n");
        }
    }
    try w.print("</{s}>\n", .{tag});
}

fn renderTightItem(w: *Writer, item: []const Block) Writer.Error!void {
    var prev_ended_with_newline = false;
    for (item, 0..) |block, idx| {
        switch (block) {
            .paragraph => |text| {
                if (idx != 0 and !prev_ended_with_newline) try w.writeByte('\n');
                try renderInlines(w, text);
                prev_ended_with_newline = false;
            },
            else => {
                if (idx != 0 and !prev_ended_with_newline) try w.writeByte('\n');
                try renderBlock(w, block);
                prev_ended_with_newline = true;
            },
        }
    }
}

fn renderInlines(w: *Writer, text: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) {
            try writeEscapedChar(w, text[i + 1]);
            i += 2;
            continue;
        }
        if (c == '`') {
            if (parseCodeSpan(text, i)) |span| {
                try w.writeAll("<code>");
                try writeEscaped(w, span.content);
                try w.writeAll("</code>");
                i = span.end;
                continue;
            }
        }
        if (c == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (parseInlineLink(text, i + 1)) |link| {
                try w.writeAll("<img src=\"");
                try writeEscaped(w, link.url);
                try w.writeAll("\" alt=\"");
                try writeEscaped(w, link.text);
                try w.writeAll("\" />");
                i = link.end;
                continue;
            }
        }
        if (c == '[') {
            if (parseInlineLink(text, i)) |link| {
                try w.writeAll("<a href=\"");
                try writeEscaped(w, link.url);
                try w.writeAll("\">");
                try renderInlines(w, link.text);
                try w.writeAll("</a>");
                i = link.end;
                continue;
            }
        }
        if (c == '*' or c == '_') {
            if (parseEmphasis(text, i)) |em| {
                const tag: []const u8 = if (em.strong) "strong" else "em";
                try w.print("<{s}>", .{tag});
                try renderInlines(w, em.content);
                try w.print("</{s}>", .{tag});
                i = em.end;
                continue;
            }
        }
        if (c == '~') {
            if (parseStrike(text, i)) |strike| {
                try w.writeAll("<del>");
                try renderInlines(w, strike.content);
                try w.writeAll("</del>");
                i = strike.end;
                continue;
            }
        }
        try writeEscapedChar(w, c);
        i += 1;
    }
}

const Span = struct { content: []const u8, end: usize };

fn parseCodeSpan(text: []const u8, start: usize) ?Span {
    var ticks: usize = 0;
    while (start + ticks < text.len and text[start + ticks] == '`') ticks += 1;
    if (ticks == 0) return null;

    var i = start + ticks;
    while (i < text.len) {
        if (text[i] != '`') {
            i += 1;
            continue;
        }
        var n: usize = 0;
        while (i + n < text.len and text[i + n] == '`') n += 1;
        if (n == ticks) {
            var content = text[start + ticks .. i];
            if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ') {
                content = content[1 .. content.len - 1];
            }
            return .{ .content = content, .end = i + n };
        }
        i += n;
    }
    return null;
}

const Link = struct { text: []const u8, url: []const u8, end: usize };

fn parseInlineLink(text: []const u8, start: usize) ?Link {
    if (start >= text.len or text[start] != '[') return null;
    const close = findMatchingBracket(text, start + 1) orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const url_end = std.mem.indexOfScalarPos(u8, text, close + 2, ')') orelse return null;
    const url = std.mem.trim(u8, text[close + 2 .. url_end], " \t\n\r");
    return .{
        .text = text[start + 1 .. close],
        .url = url,
        .end = url_end + 1,
    };
}

fn findMatchingBracket(text: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (text[i] == '`') {
            if (parseCodeSpan(text, i)) |span| {
                i = span.end - 1;
                continue;
            }
        }
        switch (text[i]) {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

const Emphasis = struct { strong: bool, content: []const u8, end: usize };

fn parseEmphasis(text: []const u8, start: usize) ?Emphasis {
    const delim = text[start];
    var count: usize = 0;
    while (start + count < text.len and text[start + count] == delim) count += 1;
    if (count == 0) return null;

    if (delim == '_' and start > 0 and ascii.isAlphanumeric(text[start - 1])) return null;

    if (count >= 2) {
        if (takeDelimited(text, start, delim, 2)) |span| {
            return .{ .strong = true, .content = span.content, .end = span.end };
        }
    }
    if (takeDelimited(text, start, delim, 1)) |span| {
        return .{ .strong = false, .content = span.content, .end = span.end };
    }
    return null;
}

fn parseStrike(text: []const u8, start: usize) ?Span {
    var used: usize = 1;
    if (start + 1 < text.len and text[start + 1] == '~') used = 2;
    return takeDelimited(text, start, '~', used);
}

fn takeDelimited(text: []const u8, start: usize, delim: u8, count: usize) ?Span {
    const after = start + count;
    if (after >= text.len) return null;
    if (isSpace(text[after])) return null;
    const closer = findCloser(text, after, delim, count) orelse return null;
    if (closer == after) return null;
    return .{ .content = text[after..closer], .end = closer + count };
}

fn findCloser(text: []const u8, start: usize, delim: u8, count: usize) ?usize {
    var i = start;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 2;
            continue;
        }
        if (text[i] == '`') {
            if (parseCodeSpan(text, i)) |span| {
                i = span.end;
                continue;
            }
        }
        if (text[i] == delim) {
            var n: usize = 0;
            while (i + n < text.len and text[i + n] == delim) n += 1;
            if (n >= count and i > 0 and !isSpace(text[i - 1])) {
                const after = i + count;
                if (delim == '_' and after < text.len and ascii.isAlphanumeric(text[after])) {
                    i += n;
                    continue;
                }
                return i;
            }
            i += @max(n, 1);
            continue;
        }
        i += 1;
    }
    return null;
}

fn isEscapable(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) != null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn writeEscaped(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| try writeEscapedChar(w, c);
}

fn writeEscapedChar(w: *Writer, c: u8) Writer.Error!void {
    switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    }
}

fn expectHtml(source: []const u8, expected: []const u8) !void {
    const testing = std.testing;
    const gpa = testing.allocator;
    const actual = try toHtml(gpa, source);
    defer gpa.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "paragraphs preserve soft line breaks" {
    try expectHtml(
        \\Hello world
        \\next line
        \\
        \\Second paragraph.
    ,
        "<p>Hello world\nnext line</p>\n<p>Second paragraph.</p>\n",
    );
}

test "paragraphs trim indent and trailing spaces" {
    try expectHtml(
        \\foo
        \\bar   
        \\
        \\  leading indent
    ,
        "<p>foo\nbar</p>\n<p>leading indent</p>\n",
    );
}

test "headings and emphasis" {
    try expectHtml(
        \\## Title
        \\
        \\This is _a_ sentence *with* some __formatting__ and a **mix**.
    ,
        "<h2>Title</h2>\n<p>This is <em>a</em> sentence <em>with</em> some <strong>formatting</strong> and a <strong>mix</strong>.</p>\n",
    );
}

test "links including multiline text" {
    try expectHtml(
        \\See [Zig](https://ziglang.org/) and [Dan Harmon's Story
        \\Circle](https://example.com).
    ,
        "<p>See <a href=\"https://ziglang.org/\">Zig</a> and <a href=\"https://example.com\">Dan Harmon's Story\nCircle</a>.</p>\n",
    );
}

test "inline code and fenced code" {
    try expectHtml(
        \\Use `package.json` please.
        \\
        \\```
        \\const x = 1;
        \\```
        \\
        \\```json
        \\{"a": 1}
        \\```
    ,
        "<p>Use <code>package.json</code> please.</p>\n<pre><code>const x = 1;\n</code></pre>\n<pre><code class=\"language-json\">{&quot;a&quot;: 1}\n</code></pre>\n",
    );
}

test "triple backtick inline code on one line" {
    try expectHtml(
        "``` console.log(\"Hello World\"); // an example ```",
        "<p><code>console.log(&quot;Hello World&quot;); // an example</code></p>\n",
    );
}

test "tight and loose lists" {
    try expectHtml(
        \\- one
        \\- two
        \\
        \\1. alpha
        \\
        \\2. beta
    ,
        "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n<ol>\n<li>\n<p>alpha</p>\n</li>\n<li>\n<p>beta</p>\n</li>\n</ol>\n",
    );
}

test "nested list and wrapping items" {
    try expectHtml(
        \\- outer
        \\  - inner
        \\- The hinge feels stiff. Compared
        \\  to the macbook hinge.
    ,
        "<ul>\n<li>outer\n<ul>\n<li>inner</li>\n</ul>\n</li>\n<li>The hinge feels stiff. Compared\nto the macbook hinge.</li>\n</ul>\n",
    );
}

test "blockquote strikethrough hr and escapes" {
    try expectHtml(
        \\> quoted
        \\> lines
        \\
        \\to ~spite~ scratch
        \\
        \\----
        \\
        \\\* literal star and Advanced -> Virtual
    ,
        "<blockquote>\n<p>quoted\nlines</p>\n</blockquote>\n<p>to <del>spite</del> scratch</p>\n<hr />\n<p>* literal star and Advanced -&gt; Virtual</p>\n",
    );
}

test "code block inside a list item" {
    try expectHtml(
        \\- intro:
        \\  ```json
        \\    {"a": 1}
        \\  ```
        \\  trailing
    ,
        "<ul>\n<li>intro:\n<pre><code class=\"language-json\">  {&quot;a&quot;: 1}\n</code></pre>\ntrailing</li>\n</ul>\n",
    );
    try expectHtml(
        \\- intro:
        \\  ```json
        \\    {"a": 1}
        \\  ```
        \\
        \\  trailing
    ,
        "<ul>\n<li>\n<p>intro:</p>\n<pre><code class=\"language-json\">  {&quot;a&quot;: 1}\n</code></pre>\n<p>trailing</p>\n</li>\n</ul>\n",
    );
}

test "html in inline code" {
    try expectHtml(
        \\`<missing-image>`
    ,
        "<p><code>&lt;missing-image&gt;</code></p>\n",
    );
}

test "bold link and footnote asterisk" {
    try expectHtml(
        \\1. **[UEFI](https://en.wikipedia.org/wiki/UEFI)**: new cool thing.
        \\
        \\projects* and \* _Google is an exception_
    ,
        "<ol>\n<li><strong><a href=\"https://en.wikipedia.org/wiki/UEFI\">UEFI</a></strong>: new cool thing.</li>\n</ol>\n<p>projects* and * <em>Google is an exception</em></p>\n",
    );
}
