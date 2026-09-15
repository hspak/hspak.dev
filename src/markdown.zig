//! Markdown-to-HTML converter for the subset of CommonMark this blog uses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ascii = std.ascii;

/// URL strings are borrowed for the duration of `toHtmlWithOptions`.
pub const Options = struct {
    /// Public URL of the post's media directory, including its trailing slash.
    /// Resolve relative URLs beneath it; an empty prefix disables URL rewriting.
    asset_url_prefix: []const u8 = "",
    /// Public thumbnail directory, including its trailing slash.
    thumbnail_url_prefix: []const u8 = "",
    /// Paths relative to the sibling directory for thumbnails that exist on disk.
    thumbnail_paths: []const []const u8 = &.{},
    /// HTML-safe identifier prefix, unique to the post (for example `post-42-`).
    footnote_id_prefix: []const u8 = "",
    /// Disable automatic original-image links when rendering inside an existing link.
    link_images: bool = true,
};

/// Convert markdown `source` to HTML. The returned slice is allocated with
/// `gpa`; caller must free it.
pub fn toHtml(gpa: Allocator, source: []const u8) Allocator.Error![]const u8 {
    return toHtmlWithOptions(gpa, source, .{});
}

/// Convert borrowed markdown and URL options to owned HTML. Caller must free the
/// result with `gpa`; on error, all intermediate allocations are released.
pub fn toHtmlWithOptions(
    gpa: Allocator,
    source: []const u8,
    options: Options,
) Allocator.Error![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var footnotes: Footnotes = .{};
    const blocks = try parse(arena.allocator(), source, &footnotes);
    try footnotes.prepare(arena.allocator(), blocks, options);

    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    renderBlocks(&aw.writer, blocks, options, &footnotes) catch return error.OutOfMemory;
    renderFootnotes(&aw.writer, &footnotes, options) catch return error.OutOfMemory;
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

const Block = union(enum) {
    paragraph: []const u8,
    figure: Media,
    heading: struct {
        level: u8,
        text: []const u8,
    },
    code: struct {
        info: []const u8,
        text: []const u8,
    },
    quote: []Block,
    list: struct {
        ordered: bool,
        start: u32,
        loose: bool,
        items: [][]Block,
    },
    thematic_break,
};

const Heading = @FieldType(Block, "heading");
const Code = @FieldType(Block, "code");
const List = @FieldType(Block, "list");

// Definitions and order storage belong to the conversion's arena.
const Footnotes = struct {
    definitions: std.ArrayList(Definition) = .empty,
    order: std.ArrayList(usize) = .empty,
    collecting: bool = false,

    const Definition = struct {
        label: []const u8,
        blocks: []const Block = &.{},
        number: usize = 0,
        references: usize = 0,
        emitted: usize = 0,
    };

    const Reference = struct {
        number: usize,
        occurrence: usize,
    };

    fn find(notes: *const Footnotes, label: []const u8) ?usize {
        for (notes.definitions.items, 0..) |definition, index| {
            if (std.mem.eql(u8, definition.label, label)) return index;
        }
        return null;
    }

    fn reference(notes: *Footnotes, label: []const u8) ?Reference {
        const index = notes.find(label) orelse return null;
        const definition = &notes.definitions.items[index];
        if (notes.collecting) {
            if (definition.number == 0) {
                notes.order.appendAssumeCapacity(index);
                definition.number = notes.order.items.len;
            }
            definition.references += 1;
        } else {
            std.debug.assert(definition.number != 0);
            definition.emitted += 1;
            std.debug.assert(definition.emitted <= definition.references);
        }
        return .{
            .number = definition.number,
            .occurrence = if (notes.collecting) definition.references else definition.emitted,
        };
    }

    fn prepare(
        notes: *Footnotes,
        arena: Allocator,
        blocks: []const Block,
        options: Options,
    ) Allocator.Error!void {
        if (notes.definitions.items.len == 0) return;
        try notes.order.ensureTotalCapacity(arena, notes.definitions.items.len);
        notes.collecting = true;
        var buffer: [256]u8 = undefined;
        var discard: Writer.Discarding = .init(&buffer);
        // Use the inline renderer so escapes, code, and link labels have identical semantics.
        // Count references inside notes too before emitting any of their return links.
        // The discarding writer cannot fail.
        renderBlocks(&discard.writer, blocks, options, notes) catch unreachable;
        var index: usize = 0;
        while (index < notes.order.items.len) : (index += 1) {
            const definition = notes.definitions.items[notes.order.items[index]];
            renderBlocks(&discard.writer, definition.blocks, options, notes) catch unreachable;
        }
        notes.collecting = false;
    }
};

fn parse(arena: Allocator, source: []const u8, footnotes: *Footnotes) Allocator.Error![]Block {
    const lines = try splitLines(arena, source);
    var i: usize = 0;
    return parseBlocks(arena, lines, &i, lines.len, footnotes);
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
    footnotes: *Footnotes,
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
        if (footnoteMarker(line)) |marker| {
            try parseFootnote(arena, lines, i, end, marker, footnotes);
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
            try blocks.append(arena, .{ .quote = try parseQuote(arena, lines, i, end, footnotes) });
            continue;
        }
        if (parseMarker(line) != null) {
            try blocks.append(arena, .{ .list = try parseList(arena, lines, i, end, footnotes) });
            continue;
        }
        const text = try parseParagraph(arena, lines, i, end);
        const block: Block = if (parseFigure(text)) |media|
            .{ .figure = media }
        else
            .{ .paragraph = text };
        try blocks.append(arena, block);
    }
    return blocks.toOwnedSlice(arena);
}

fn startsContainer(line: Line) bool {
    if (isBlank(line)) return true;
    if (parseFence(line) != null) return true;
    if (footnoteMarker(line) != null) return true;
    if (isThematicBreak(line)) return true;
    if (parseHeading(line) != null) return true;
    if (isQuote(line)) return true;
    if (parseMarker(line) != null) return true;
    return false;
}

const FootnoteMarker = struct {
    label: []const u8,
    content_offset: usize,
};

fn footnoteMarker(line: Line) ?FootnoteMarker {
    if (line.indent > 3) return null;
    const reference = parseFootnoteReference(line.rest, 0) orelse return null;
    if (reference.end == line.rest.len or line.rest[reference.end] != ':') return null;
    return .{
        .label = reference.content,
        .content_offset = line.indent + reference.end + 1,
    };
}

fn footnoteContinuation(line: Line) ?Line {
    if (line.indent >= 4) return makeLine(line.raw[4..]);
    if (std.mem.startsWith(u8, line.raw, "\t")) return makeLine(line.raw[1..]);
    return null;
}

fn parseFootnote(
    arena: Allocator,
    lines: []const Line,
    i: *usize,
    end: usize,
    marker: FootnoteMarker,
    footnotes: *Footnotes,
) Allocator.Error!void {
    // Reserve the first definition before parsing its body, which may contain definitions too.
    const duplicate = footnotes.find(marker.label) != null;
    const index = footnotes.definitions.items.len;
    if (!duplicate) try footnotes.definitions.append(arena, .{ .label = marker.label });
    var inner: std.ArrayList(Line) = .empty;
    try inner.append(arena, makeLine(std.mem.trimStart(
        u8,
        lines[i.*].raw[marker.content_offset..],
        " \t",
    )));
    i.* += 1;
    var fence: ?Fence = null;
    while (i.* < end) {
        const previous = inner.items[inner.items.len - 1];
        const paragraph_open = paragraph: {
            if (fence) |opening| {
                if (isClosingFence(previous, opening)) fence = null;
                break :paragraph false;
            }
            if (parseFence(previous)) |opening| {
                fence = opening;
                break :paragraph false;
            }
            break :paragraph !startsContainer(previous);
        };
        const line = lines[i.*];
        if (isBlank(line)) {
            const next = nextNonBlank(lines, i.* + 1, end) orelse break;
            if (footnoteContinuation(lines[next]) == null) break;
            try inner.append(arena, makeLine(""));
        } else if (footnoteContinuation(line)) |continuation| {
            try inner.append(arena, continuation);
        } else {
            // Soft-wrapped prose stays in its paragraph even when indentation is lost.
            if (!paragraph_open or startsContainer(line)) break;
            try inner.append(arena, makeLine(line.rest));
        }
        i.* += 1;
    }
    var inner_i: usize = 0;
    const blocks = try parseBlocks(arena, inner.items, &inner_i, inner.items.len, footnotes);
    if (!duplicate) footnotes.definitions.items[index].blocks = blocks;
}

fn parseFigure(text: []const u8) ?Media {
    const media = parseMedia(text, 0) orelse return null;
    const caption = media.link.title orelse return null;
    if (media.end != text.len or caption.len == 0) return null;
    return media;
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
    footnotes: *Footnotes,
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
    return parseBlocks(arena, inner.items, &inner_i, inner.items.len, footnotes);
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
    footnotes: *Footnotes,
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
        const blocks = try parseBlocks(
            arena,
            item_lines.items,
            &item_i,
            item_lines.items.len,
            footnotes,
        );
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

fn renderBlocks(
    w: *Writer,
    blocks: []const Block,
    options: Options,
    footnotes: ?*Footnotes,
) Writer.Error!void {
    for (blocks) |block| try renderBlock(w, block, options, footnotes);
}

fn renderBlock(
    w: *Writer,
    block: Block,
    options: Options,
    footnotes: ?*Footnotes,
) Writer.Error!void {
    switch (block) {
        .paragraph => |text| {
            try w.writeAll("<p>");
            try renderInlines(w, text, options, footnotes);
            try w.writeAll("</p>\n");
        },
        .figure => |media| {
            try w.writeAll("<figure>\n");
            try renderMedia(w, media, options);
            try w.writeAll("\n<figcaption>");
            try writeLinkString(w, media.link.title.?);
            try w.writeAll("</figcaption>\n</figure>\n");
        },
        .heading => |heading| {
            try w.print("<h{d}>", .{heading.level});
            try renderInlines(w, heading.text, options, footnotes);
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
            try renderBlocks(w, inner, options, footnotes);
            try w.writeAll("</blockquote>\n");
        },
        .list => |list| try renderList(w, list, options, footnotes),
        .thematic_break => try w.writeAll("<hr />\n"),
    }
}

fn renderList(w: *Writer, list: List, options: Options, footnotes: ?*Footnotes) Writer.Error!void {
    const tag = if (list.ordered) "ol" else "ul";
    if (list.ordered and list.start != 1) {
        try w.print("<ol start=\"{d}\">\n", .{list.start});
    } else {
        try w.print("<{s}>\n", .{tag});
    }
    for (list.items) |item| {
        if (list.loose) {
            try w.writeAll("<li>\n");
            try renderBlocks(w, item, options, footnotes);
            try w.writeAll("</li>\n");
        } else {
            try w.writeAll("<li>");
            try renderTightItem(w, item, options, footnotes);
            try w.writeAll("</li>\n");
        }
    }
    try w.print("</{s}>\n", .{tag});
}

fn renderTightItem(
    w: *Writer,
    item: []const Block,
    options: Options,
    footnotes: ?*Footnotes,
) Writer.Error!void {
    var prev_ended_with_newline = false;
    for (item, 0..) |block, idx| {
        switch (block) {
            .paragraph => |text| {
                if (idx != 0 and !prev_ended_with_newline) try w.writeByte('\n');
                try renderInlines(w, text, options, footnotes);
                prev_ended_with_newline = false;
            },
            .figure,
            .heading,
            .code,
            .quote,
            .list,
            .thematic_break,
            => {
                if (idx != 0 and !prev_ended_with_newline) try w.writeByte('\n');
                try renderBlock(w, block, options, footnotes);
                prev_ended_with_newline = true;
            },
        }
    }
}

fn renderInlines(
    w: *Writer,
    text: []const u8,
    options: Options,
    footnotes: ?*Footnotes,
) Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) {
            if (parseFootnoteReference(text, i + 1)) |reference| {
                try writeEscaped(w, text[i + 1 .. reference.end]);
                i = reference.end;
                continue;
            }
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
            if (parseMedia(text, i)) |media| {
                try renderMedia(w, media, options);
                i = media.end;
                continue;
            }
        }
        if (c == '[') {
            if (parseInlineLink(text, i)) |link| {
                try w.writeAll("<a href=\"");
                try writeUrl(w, link.url, options);
                try w.writeByte('"');
                try writeTitle(w, link.title);
                try w.writeByte('>');
                var nested_options = options;
                nested_options.link_images = false;
                try renderInlines(w, link.text, nested_options, null);
                try w.writeAll("</a>");
                i = link.end;
                continue;
            }
            if (parseFootnoteReference(text, i)) |reference| {
                const resolved = if (footnotes) |notes| notes.reference(reference.content) else null;
                if (resolved) |found| {
                    try renderFootnoteReference(w, found, options);
                } else {
                    try writeEscaped(w, text[i..reference.end]);
                }
                i = reference.end;
                continue;
            }
        }
        if (c == '*' or c == '_') {
            if (parseEmphasis(text, i)) |em| {
                const tag: []const u8 = if (em.strong) "strong" else "em";
                try w.print("<{s}>", .{tag});
                try renderInlines(w, em.content, options, footnotes);
                try w.print("</{s}>", .{tag});
                i = em.end;
                continue;
            }
        }
        if (c == '~') {
            if (parseStrike(text, i)) |strike| {
                try w.writeAll("<del>");
                try renderInlines(w, strike.content, options, footnotes);
                try w.writeAll("</del>");
                i = strike.end;
                continue;
            }
        }
        try writeEscapedChar(w, c);
        i += 1;
    }
}

fn writeFootnoteId(
    w: *Writer,
    prefix: []const u8,
    number: usize,
    occurrence: ?usize,
) Writer.Error!void {
    try w.writeAll(if (occurrence == null) "fn-" else "fnref-");
    try writeEscaped(w, prefix);
    try w.print("{d}", .{number});
    if (occurrence) |index| try w.print("-{d}", .{index});
}

fn renderFootnoteReference(
    w: *Writer,
    reference: Footnotes.Reference,
    options: Options,
) Writer.Error!void {
    try w.writeAll("<sup class=\"footnote-ref\"><a id=\"");
    try writeFootnoteId(w, options.footnote_id_prefix, reference.number, reference.occurrence);
    try w.writeAll("\" href=\"#");
    try writeFootnoteId(w, options.footnote_id_prefix, reference.number, null);
    try w.print("\" role=\"doc-noteref\" aria-label=\"Footnote {d}\">{d}</a></sup>", .{
        reference.number,
        reference.number,
    });
}

fn renderFootnotes(w: *Writer, notes: *Footnotes, options: Options) Writer.Error!void {
    if (notes.order.items.len == 0) return;
    try w.writeAll(
        "<section class=\"footnotes\" role=\"doc-endnotes\" aria-label=\"Footnotes\">\n<ol>\n",
    );
    for (notes.order.items) |index| {
        const definition = notes.definitions.items[index];
        try w.writeAll("<li id=\"");
        try writeFootnoteId(w, options.footnote_id_prefix, definition.number, null);
        try w.writeAll("\" tabindex=\"-1\">\n");
        const last_paragraph = if (definition.blocks.len == 0)
            null
        else switch (definition.blocks[definition.blocks.len - 1]) {
            .paragraph => |text| text,
            .figure,
            .heading,
            .code,
            .quote,
            .list,
            .thematic_break,
            => null,
        };
        const preceding_blocks = if (last_paragraph != null)
            definition.blocks[0 .. definition.blocks.len - 1]
        else
            definition.blocks;
        try renderBlocks(w, preceding_blocks, options, notes);
        try w.writeAll("<p>");
        if (last_paragraph) |text| {
            try renderInlines(w, text, options, notes);
            try w.writeAll("&#160;");
        }
        try w.writeAll("<span class=\"footnote-backlinks\">");
        for (1..definition.references + 1) |occurrence| {
            if (occurrence > 1) try w.writeByte(' ');
            try w.writeAll("<a href=\"#");
            try writeFootnoteId(w, options.footnote_id_prefix, definition.number, occurrence);
            try w.print(
                "\" role=\"doc-backlink\" aria-label=\"Back to reference {d} of footnote {d}\">↩",
                .{ occurrence, definition.number },
            );
            if (definition.references > 1) try w.print("{d}", .{occurrence});
            try w.writeAll("</a>");
        }
        try w.writeAll("</span></p>\n</li>\n");
    }
    try w.writeAll("</ol>\n</section>\n");
}

fn renderMedia(w: *Writer, media: Media, options: Options) Writer.Error!void {
    const link = media.link;
    if (isVideoUrl(link.url)) {
        try w.writeAll(if (media.gif)
            "<video autoplay loop muted playsinline src=\""
        else
            "<video controls preload=\"metadata\" src=\"");
        try writeUrl(w, link.url, options);
        try w.writeAll("\" aria-label=\"");
        try writeEscaped(w, link.text);
        try w.writeByte('"');
        try writeTitle(w, link.title);
        try w.writeAll("><a href=\"");
        try writeUrl(w, link.url, options);
        try w.writeAll("\">");
        try writeEscaped(w, if (link.text.len == 0) "Download video" else link.text);
        try w.writeAll("</a></video>");
        return;
    }
    const has_thumbnail = hasThumbnail(link.url, options);
    const link_original = has_thumbnail and options.link_images;
    if (link_original) {
        try w.writeAll("<a href=\"");
        try writeUrl(w, link.url, options);
        try w.writeAll("\">");
    }
    var image_options = options;
    if (has_thumbnail) image_options.asset_url_prefix = options.thumbnail_url_prefix;
    try w.writeAll("<img src=\"");
    try writeUrl(w, link.url, image_options);
    try w.writeAll("\" alt=\"");
    try writeEscaped(w, link.text);
    try w.writeByte('"');
    try writeTitle(w, link.title);
    try w.writeAll(" />");
    if (link_original) try w.writeAll("</a>");
}

fn hasThumbnail(url: []const u8, options: Options) bool {
    if (options.asset_url_prefix.len == 0 or options.thumbnail_url_prefix.len == 0) return false;
    const relative = assetPath(url) orelse return false;
    const path_end = std.mem.indexOfAny(u8, relative, "?#") orelse relative.len;
    for (options.thumbnail_paths) |path| {
        if (urlPathEql(relative[0..path_end], path)) return true;
    }
    return false;
}

// Match filesystem paths against Markdown escapes and percent-encoded URL bytes.
fn urlPathEql(url: []const u8, path: []const u8) bool {
    var i: usize = 0;
    for (path) |byte| {
        if (i >= url.len) return false;
        if (url[i] == '\\' and i + 1 < url.len and isEscapable(url[i + 1])) i += 1;
        var decoded = url[i];
        if (decoded == '%' and i + 2 < url.len) {
            const high = std.fmt.charToDigit(url[i + 1], 16) catch return false;
            const low = std.fmt.charToDigit(url[i + 2], 16) catch return false;
            decoded = high * 16 + low;
            i += 2;
        }
        if (decoded != byte) return false;
        i += 1;
    }
    return i == url.len;
}

fn writeTitle(w: *Writer, title: ?[]const u8) Writer.Error!void {
    const text = title orelse return;
    try w.writeAll(" title=\"");
    try writeLinkString(w, text);
    try w.writeByte('"');
}

fn writeLinkString(w: *Writer, text: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) i += 1;
        try writeEscapedChar(w, text[i]);
    }
}

fn isVideoUrl(url: []const u8) bool {
    const path_end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..path_end];
    const extension = std.Io.Dir.path.extension(path);
    for ([_][]const u8{
        ".mp4",
        ".webm",
        ".ogv",
        ".mov",
        ".m4v",
    }) |video_extension| {
        if (ascii.eqlIgnoreCase(extension, video_extension)) return true;
    }
    return false;
}

fn writeUrl(w: *Writer, url: []const u8, options: Options) Writer.Error!void {
    if (options.asset_url_prefix.len == 0) return writeLinkString(w, url);
    const path = assetPath(url) orelse return writeLinkString(w, url);
    try writeEscaped(w, options.asset_url_prefix);
    try writeLinkString(w, path);
}

fn assetPath(url: []const u8) ?[]const u8 {
    var relative = url;
    while (std.mem.startsWith(u8, relative, "./")) relative = relative[2..];
    if (relative.len == 0) return null;
    switch (relative[0]) {
        '/', '?', '#' => return null,
        else => {},
    }
    const first_end = std.mem.indexOfAny(u8, relative, "/?#") orelse relative.len;
    const first = relative[0..first_end];
    if (std.mem.eql(u8, first, ".") or std.mem.eql(u8, first, "..") or
        std.mem.indexOfScalar(u8, first, ':') != null)
    {
        return null;
    }
    return relative;
}

const Span = struct { content: []const u8, end: usize };

fn parseFootnoteReference(text: []const u8, start: usize) ?Span {
    if (!std.mem.startsWith(u8, text[start..], "[^")) return null;
    var i = start + 2;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == ']') {
            if (i == start + 2) return null;
            return .{ .content = text[start + 2 .. i], .end = i + 1 };
        }
        if (ascii.isWhitespace(c) or c == '[' or c == '\\') return null;
    }
    return null;
}

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

const Media = struct {
    link: Link,
    end: usize,
    gif: bool = false,
};

fn parseMedia(text: []const u8, start: usize) ?Media {
    if (start >= text.len or text[start] != '!') return null;
    const link = parseInlineLink(text, start + 1) orelse return null;
    const gif_flag = "{gif}";
    const gif = isVideoUrl(link.url) and std.mem.startsWith(u8, text[link.end..], gif_flag);
    return .{
        .link = link,
        .end = if (gif) link.end + gif_flag.len else link.end,
        .gif = gif,
    };
}

const Link = struct {
    text: []const u8,
    url: []const u8,
    end: usize,
    title: ?[]const u8 = null,
};

fn parseInlineLink(text: []const u8, start: usize) ?Link {
    if (start >= text.len or text[start] != '[') return null;
    const close = findMatchingBracket(text, start + 1) orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    var i = close + 2;
    while (i < text.len and isSpace(text[i])) : (i += 1) {}
    if (i == text.len) return null;

    const angled = text[i] == '<';
    if (angled) i += 1;
    const url_start = i;
    var depth: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) {
            i += 1;
            continue;
        }
        if (angled) {
            if (c == '>') break;
            if (c == '\n' or c == '\r' or c == '<') return null;
            continue;
        }
        if (isSpace(c)) break;
        if (c == '(') depth += 1;
        if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    if (i == text.len or depth != 0) return null;
    const url_end = i;
    if (angled) i += 1;

    const separator_start = i;
    while (i < text.len and isSpace(text[i])) : (i += 1) {}
    var title: ?[]const u8 = null;
    if (i < text.len and (text[i] == '"' or text[i] == '\'')) {
        if (i == separator_start) return null;
        const quote = text[i];
        i += 1;
        const title_start = i;
        while (i < text.len and text[i] != quote) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len and isEscapable(text[i + 1])) i += 1;
        }
        if (i == text.len) return null;
        title = text[title_start..i];
        i += 1;
        while (i < text.len and isSpace(text[i])) : (i += 1) {}
    }
    if (i == text.len or text[i] != ')') return null;
    return .{
        .text = text[start + 1 .. close],
        .url = text[url_start..url_end],
        .end = i + 1,
        .title = title,
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

const Emphasis = struct {
    strong: bool,
    content: []const u8,
    end: usize,
};

fn parseEmphasis(text: []const u8, start: usize) ?Emphasis {
    const delim = text[start];
    var count: usize = 0;
    while (start + count < text.len and text[start + count] == delim) count += 1;
    if (count == 0) return null;

    if (delim == '_' and start > 0 and ascii.isAlphanumeric(text[start - 1])) return null;

    if (count >= 2) {
        if (takeDelimited(text, start, delim, 2)) |span| {
            return .{
                .strong = true,
                .content = span.content,
                .end = span.end,
            };
        }
    }
    if (takeDelimited(text, start, delim, 1)) |span| {
        return .{
            .strong = false,
            .content = span.content,
            .end = span.end,
        };
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
        "<h2>Title</h2>\n<p>This is <em>a</em> sentence <em>with</em> some <strong>" ++
            "formatting</strong> and a <strong>mix</strong>.</p>\n",
    );
}

test "links including multiline text" {
    try expectHtml(
        \\See [Zig](https://ziglang.org/) and [Dan Harmon's Story
        \\Circle](https://example.com).
    ,
        "<p>See <a href=\"https://ziglang.org/\">Zig</a>" ++
            " and <a href=\"https://example.com\">Dan Harmon's Story\nCircle</a>.</p>\n",
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
        "<p>Use <code>package.json</code> please.</p>\n<pre><code>const x = 1;\n</code>" ++
            "</pre>\n<pre><code class=\"language-json\">{&quot;a&quot;: 1}\n</code></pre>\n",
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
        "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n<ol>\n<li>\n<p>alpha</p>\n</li>\n<li>" ++
            "\n<p>beta</p>\n</li>\n</ol>\n",
    );
}

test "nested list and wrapping items" {
    try expectHtml(
        \\- outer
        \\  - inner
        \\- The hinge feels stiff. Compared
        \\  to the macbook hinge.
    ,
        "<ul>\n<li>outer\n<ul>\n<li>inner</li>\n</ul>\n</li>\n<li>" ++
            "The hinge feels stiff. Compared\nto the macbook hinge.</li>\n</ul>\n",
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
        "<blockquote>\n<p>quoted\nlines</p>\n</blockquote>\n<p>to <del>spite</del>" ++
            " scratch</p>\n<hr />\n<p>* literal star and Advanced -&gt; Virtual</p>\n",
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
        "<ul>\n<li>intro:\n<pre><code class=\"language-json\">  {&quot;a&quot;: 1}\n" ++
            "</code></pre>\ntrailing</li>\n</ul>\n",
    );
    try expectHtml(
        \\- intro:
        \\  ```json
        \\    {"a": 1}
        \\  ```
        \\
        \\  trailing
    ,
        "<ul>\n<li>\n<p>intro:</p>\n<pre><code class=\"language-json\">" ++
            "  {&quot;a&quot;: 1}\n</code></pre>\n<p>trailing</p>\n</li>\n</ul>\n",
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
        "<ol>\n<li><strong><a href=\"https://en.wikipedia.org/wiki/UEFI\">UEFI</a>" ++
            "</strong>: new cool thing.</li>\n</ol>\n<p>projects* and * <em>" ++
            "Google is an exception</em></p>\n",
    );
}

test "images escape alt text and URLs" {
    try expectHtml(
        "![A \"quote\" & <caption>](photo.png?size=1&crop=2)",
        "<p>" ++
            "<img src=\"photo.png?size=1&amp;crop=2\" alt=\"A &quot;quote&quot; &amp; " ++
            "&lt;caption&gt;\" /></p>\n",
    );
}

test "video embeds have controls and a fallback link" {
    for ([_][]const u8{
        "mp4",
        "webm",
        "ogv",
        "MOV",
        "m4v",
    }) |extension| {
        const gpa = std.testing.allocator;
        const source = try std.fmt.allocPrint(gpa, "![A & B](clip.{s}?x=1&y=2#t=3)", .{extension});
        defer gpa.free(source);
        const expected = try std.fmt.allocPrint(
            gpa,
            "<p>" ++
                "<video controls preload=\"metadata\" src=\"clip.{s}?x=1&amp;y=2#t=3\" " ++
                "aria-label=\"A &amp; B\"><a href=\"clip.{s}?x=1&amp;y=2#t=3\">A &amp; B</a>" ++
                "</video></p>\n",
            .{ extension, extension },
        );
        defer gpa.free(expected);
        try expectHtml(source, expected);
    }
    try expectHtml(
        "![](clip.mp4)",
        "<p><video controls preload=\"metadata\" src=\"clip.mp4\" aria-label=\"\">" ++
            "<a href=\"clip.mp4\">Download video</a></video></p>\n",
    );
    try expectHtml(
        "[Download](clip.mp4) ![Photo](photo.png?name=clip.mp4)",
        "<p><a href=\"clip.mp4\">Download</a>" ++
            " <img src=\"photo.png?name=clip.mp4\" alt=\"Photo\" /></p>\n",
    );
}

test "gif video embeds autoplay muted inline and loop without controls" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        "mp4",
        "webm",
        "ogv",
        "MOV",
        "m4v",
    }) |extension| {
        const source = try std.fmt.allocPrint(
            gpa,
            "See ![A & B](clip.{s}?x=1&y=2#t=3){{gif}} again.",
            .{extension},
        );
        defer gpa.free(source);
        const expected = try std.fmt.allocPrint(
            gpa,
            "<p>See <video autoplay loop muted playsinline " ++
                "src=\"clip.{s}?x=1&amp;y=2#t=3\" aria-label=\"A &amp; B\">" ++
                "<a href=\"clip.{s}?x=1&amp;y=2#t=3\">A &amp; B</a></video> again.</p>\n",
            .{ extension, extension },
        );
        defer gpa.free(expected);
        try expectHtml(source, expected);
    }
    try expectHtml(
        "![](clip.mp4){gif}",
        "<p><video autoplay loop muted playsinline src=\"clip.mp4\" aria-label=\"\">" ++
            "<a href=\"clip.mp4\">Download video</a></video></p>\n",
    );
}

test "gif video captions preserve rewritten asset URLs and escape HTML" {
    const gpa = std.testing.allocator;
    const actual = try toHtmlWithOptions(
        gpa,
        "![Demo](./demo.mp4#t=2 'Before & after (<script>)'){gif}",
        .{
            .asset_url_prefix = "/draft/example/assets/",
        },
    );
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(
        "<figure>\n<video autoplay loop muted playsinline " ++
            "src=\"/draft/example/assets/demo.mp4#t=2\" aria-label=\"Demo\" title=\"Before " ++
            "&amp; after (&lt;script&gt;)\"><a href=\"/draft/example/assets/demo.mp4#t=2\">" ++
            "Demo</a></video>\n<figcaption>Before &amp; after (&lt;script&gt;)</figcaption>" ++
            "\n</figure>\n",
        actual,
    );
}

test "gif flags only apply immediately after video embeds" {
    try expectHtml(
        "![Photo](photo.png){gif} [Download](clip.mp4){gif} `![](clip.mp4){gif}`",
        "<p><img src=\"photo.png\" alt=\"Photo\" />{gif} " ++
            "<a href=\"clip.mp4\">Download</a>{gif} <code>![](clip.mp4){gif}</code></p>\n",
    );
    const gpa = std.testing.allocator;
    for ([_]struct { suffix: []const u8, literal: []const u8 }{
        .{ .suffix = "{gift}", .literal = "{gift}" },
        .{ .suffix = "{gif", .literal = "{gif" },
        .{ .suffix = " {gif}", .literal = " {gif}" },
        .{ .suffix = "\\{gif}", .literal = "{gif}" },
    }) |case| {
        const source = try std.fmt.allocPrint(gpa, "![](clip.mp4){s}", .{case.suffix});
        defer gpa.free(source);
        const expected = try std.fmt.allocPrint(
            gpa,
            "<p><video controls preload=\"metadata\" src=\"clip.mp4\" aria-label=\"\">" ++
                "<a href=\"clip.mp4\">Download video</a></video>{s}</p>\n",
            .{case.literal},
        );
        defer gpa.free(expected);
        try expectHtml(source, expected);
    }
}

test "post asset URLs are rewritten in nested formatting and links" {
    const gpa = std.testing.allocator;
    const actual = try toHtmlWithOptions(
        gpa,
        \\# ![Heading](heading.svg)
        \\
        \\> **![Screenshot](./nested/screen.png)**
        \\
        \\- [![Thumbnail](thumb.jpg)](full.jpg)
        \\- ![Demo](demo.webm#t=2)
        \\- [Download](./nested/demo.mp4?next=https://example.com&raw=1#t=2)
        \\- ![Other](0042-post-other/image.png)
    ,
        .{ .asset_url_prefix = "/post/custom-slug/assets/" },
    );
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(
        "<h1><img src=\"/post/custom-slug/assets/heading.svg\" alt=\"Heading\" /></h1>" ++
            "\n<blockquote>\n<p><strong>" ++
            "<img src=\"/post/custom-slug/assets/nested/screen.png\" alt=\"Screenshot\" />" ++
            "</strong></p>\n</blockquote>\n<ul>\n<li>" ++
            "<a href=\"/post/custom-slug/assets/full.jpg\">" ++
            "<img src=\"/post/custom-slug/assets/thumb.jpg\" alt=\"Thumbnail\" /></a></li>" ++
            "\n<li>" ++
            "<video controls preload=\"metadata\" " ++
            "src=\"/post/custom-slug/assets/demo.webm#t=2\" aria-label=\"Demo\">" ++
            "<a href=\"/post/custom-slug/assets/demo.webm#t=2\">Demo</a></video></li>\n" ++
            "<li><a href=\"/post/custom-slug/assets/nested/demo.mp4?next=https://example.com" ++
            "&amp;raw=1#t=2\">Download</a></li>\n" ++
            "<li><img src=\"/post/custom-slug/assets/0042-post-other/image.png\" " ++
            "alt=\"Other\" /></li>\n" ++
            "</ul>\n",
        actual,
    );
}

test "asset rewriting preserves unrelated URLs and code" {
    const source =
        \\![Remote](https://example.com/0042-post/image.png)
        \\![Root](/0042-post/image.png)
        \\![Protocol relative](//example.com/image.png)
        \\![Data](data:image/png;base64,AAAA)
        \\[Email](mailto:hello@example.com)
        \\[Custom scheme](custom+media:screen.png)
        \\[Anchor](#0042-post)
        \\[Query](?download=1)
        \\[Empty]()
        \\[Parent](../other/)
        \\[Parent directory](..)
        \\[Current directory](./)
        \\
        \\`![Literal](image.png)`
        \\
        \\```
        \\![Literal](image.png)
        \\```
    ;
    const gpa = std.testing.allocator;
    const expected = try toHtml(gpa, source);
    defer gpa.free(expected);
    const actual = try toHtmlWithOptions(
        gpa,
        source,
        .{
            .asset_url_prefix = "/draft/example/assets/",
        },
    );
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "standalone media titles become captions without replacing alt text" {
    try expectHtml(
        "![Accessible description](screen.png \"The build timeline\")",
        "<figure>\n" ++
            "<img src=\"screen.png\" alt=\"Accessible description\" title=\"The build " ++
            "timeline\" />\n<figcaption>The build timeline</figcaption>\n</figure>\n",
    );
    try expectHtml(
        "![Alt](screen.png \"\")",
        "<p><img src=\"screen.png\" alt=\"Alt\" title=\"\" /></p>\n",
    );
}

test "video captions preserve rewritten asset URLs and escape HTML" {
    const gpa = std.testing.allocator;
    const actual = try toHtmlWithOptions(
        gpa,
        "![Demo](./demo.mp4#t=2 'Before & after (<script>)')",
        .{
            .asset_url_prefix = "/draft/example/assets/",
        },
    );
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(
        "<figure>\n" ++
            "<video controls preload=\"metadata\" " ++
            "src=\"/draft/example/assets/demo.mp4#t=2\" aria-label=\"Demo\" title=\"Before " ++
            "&amp; after (&lt;script&gt;)\"><a href=\"/draft/example/assets/demo.mp4#t=2\">" ++
            "Demo</a></video>\n<figcaption>Before &amp; after (&lt;script&gt;)</figcaption>" ++
            "\n</figure>\n",
        actual,
    );
}

test "captions support escaped quotes and parentheses in destinations" {
    try expectHtml(
        \\![Alt](screen(1).png "The \"before\" view (left)")
    ,
        "<figure>\n" ++
            "<img src=\"screen(1).png\" alt=\"Alt\" title=\"The &quot;before&quot; view " ++
            "(left)\" />\n<figcaption>The &quot;before&quot; view (left)</figcaption>\n" ++
            "</figure>\n",
    );
    try expectHtml(
        \\![Alt](<screen shot.png> 'It\'s ready')
    ,
        "<figure>\n<img src=\"screen shot.png\" alt=\"Alt\" title=\"It's ready\" />\n" ++
            "<figcaption>It's ready</figcaption>\n</figure>\n",
    );
    try expectHtml(
        \\![Alt](screen\(1\).png "Caption")
    ,
        "<figure>\n<img src=\"screen(1).png\" alt=\"Alt\" title=\"Caption\" />\n" ++
            "<figcaption>Caption</figcaption>\n</figure>\n",
    );
}

test "captioned figures remain valid blocks inside quotes and lists" {
    try expectHtml(
        \\> ![Alt](screen.png "Caption")
        \\
        \\- ![Alt](screen.png "Caption")
    ,
        "<blockquote>\n<figure>\n" ++
            "<img src=\"screen.png\" alt=\"Alt\" title=\"Caption\" />\n<figcaption>" ++
            "Caption</figcaption>\n</figure>\n</blockquote>\n<ul>\n<li><figure>\n" ++
            "<img src=\"screen.png\" alt=\"Alt\" title=\"Caption\" />\n<figcaption>" ++
            "Caption</figcaption>\n</figure>\n</li>\n</ul>\n",
    );
}

test "inline media and ordinary links keep titles as tooltips" {
    try expectHtml(
        "See ![Alt](screen.png \"Image title\") and [link](page.html \"Link title\").",
        "<p>See <img src=\"screen.png\" alt=\"Alt\" title=\"Image title\" />" ++
            " and <a href=\"page.html\" title=\"Link title\">link</a>.</p>\n",
    );
    try expectHtml(
        "![Alt](screen.png \"Image title\") trailing prose.",
        "<p><img src=\"screen.png\" alt=\"Alt\" title=\"Image title\" /> trailing prose.</p>\n",
    );
}

test "malformed captions and caption syntax in code stay literal" {
    try expectHtml("![Alt](screen.png \"Unclosed)", "<p>![Alt](screen.png &quot;Unclosed)</p>\n");
    try expectHtml(
        "![Alt](screen.png \"Caption\" unexpected)",
        "<p>![Alt](screen.png &quot;Caption&quot; unexpected)</p>\n",
    );
    try expectHtml(
        "`![Alt](screen.png \"Caption\")`\n\n```\n![Alt](screen.png \"Caption\")\n```",
        "<p><code>![Alt](screen.png &quot;Caption&quot;)</code></p>\n<pre><code>" ++
            "![Alt](screen.png &quot;Caption&quot;)\n</code></pre>\n",
    );
}

test "thumbnails link originals and retain captions and URL escaping" {
    const gpa = std.testing.allocator;
    const html = try toHtmlWithOptions(
        gpa,
        "![Alt](./nested/screen%20shot\\(1\\).png?v=1&x=2#detail \"A & B\")",
        .{
            .asset_url_prefix = "/post/example/assets/",
            .thumbnail_url_prefix = "/post/example/thumbnails/",
            .thumbnail_paths = &.{"nested/screen shot(1).png"},
        },
    );
    defer gpa.free(html);
    try std.testing.expectEqualStrings(
        "<figure>\n" ++
            "<a " ++
            "href=\"/post/example/assets/nested/screen%20shot(1).png?v=1&amp;x=2#detail\">" ++
            "<img " ++
            "src=\"/post/example/thumbnails/nested/screen%20shot(1).png?v=1&amp;x=2#detail" ++
            "\" alt=\"Alt\" title=\"A &amp; B\" /></a>\n<figcaption>A &amp; B</figcaption>" ++
            "\n</figure>\n",
        html,
    );
}

test "thumbnails preserve explicit image links and leave other images unchanged" {
    const gpa = std.testing.allocator;
    const html = try toHtmlWithOptions(
        gpa,
        "[![Linked](large.png)](https://example.com)\n\n" ++
            "![Small](small.png)\n\n![External](https://example.com/large.png)\n" ++
            "\n![Root](/0042-post/large.png)",
        .{
            .asset_url_prefix = "/draft/example/assets/",
            .thumbnail_url_prefix = "/draft/example/thumbnails/",
            .thumbnail_paths = &.{"large.png"},
        },
    );
    defer gpa.free(html);
    try std.testing.expectEqualStrings(
        "<p><a href=\"https://example.com\">" ++
            "<img src=\"/draft/example/thumbnails/large.png\" alt=\"Linked\" /></a></p>\n" ++
            "<p><img src=\"/draft/example/assets/small.png\" alt=\"Small\" /></p>\n<p>" ++
            "<img src=\"https://example.com/large.png\" alt=\"External\" /></p>\n<p>" ++
            "<img src=\"/0042-post/large.png\" alt=\"Root\" /></p>\n",
        html,
    );
}

test "footnotes link references and return to their original positions" {
    try expectHtml(
        "Fast build.[^timing]\n\n[^timing]: Measured on a warm cache.",
        "<p>Fast build.<sup class=\"footnote-ref\"><a id=\"fnref-1-1\" " ++
            "href=\"#fn-1\" role=\"doc-noteref\" aria-label=\"Footnote 1\">1</a></sup></p>\n" ++
            "<section class=\"footnotes\" role=\"doc-endnotes\" aria-label=\"Footnotes\">\n" ++
            "<ol>\n<li id=\"fn-1\" tabindex=\"-1\">\n<p>Measured on a warm cache.&#160;" ++
            "<span class=\"footnote-backlinks\"><a href=\"#fnref-1-1\" role=\"doc-backlink\" " ++
            "aria-label=\"Back to reference 1 of footnote 1\">↩</a></span></p>\n" ++
            "</li>\n</ol>\n</section>\n",
    );
}

test "footnotes number first references and give each occurrence a return link" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const html = try toHtml(gpa,
        \\[^later]: Second note.
        \\[^first]: First note.
        \\
        \\# Heading[^first]
        \\
        \\- **Another[^first]** and then[^later].
        \\
        \\> Last[^first].
        \\
        \\[^first]: Duplicate definition.
        \\[^unused]: Unused definition.
    );
    defer gpa.free(html);
    for ([_][]const u8{
        "id=\"fnref-1-1\" href=\"#fn-1\"",
        "id=\"fnref-1-2\" href=\"#fn-1\"",
        "id=\"fnref-1-3\" href=\"#fn-1\"",
        "id=\"fnref-2-1\" href=\"#fn-2\"",
        "<li id=\"fn-1\" tabindex=\"-1\">\n<p>First note.&#160;<span",
        "<li id=\"fn-2\" tabindex=\"-1\">\n<p>Second note.&#160;<span",
        "href=\"#fnref-1-1\" role=\"doc-backlink\"",
        "href=\"#fnref-1-2\" role=\"doc-backlink\"",
        "href=\"#fnref-1-3\" role=\"doc-backlink\"",
        "href=\"#fnref-2-1\" role=\"doc-backlink\"",
        ">↩1</a>",
        ">↩2</a>",
        ">↩3</a>",
    }) |expected| try testing.expect(std.mem.indexOf(u8, html, expected) != null);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, html, "role=\"doc-noteref\""));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, html, "role=\"doc-backlink\""));
    try testing.expect(std.mem.indexOf(u8, html, "Duplicate definition") == null);
    try testing.expect(std.mem.indexOf(u8, html, "Unused definition") == null);
    try testing.expect(std.mem.indexOf(u8, html, "First note").? <
        std.mem.indexOf(u8, html, "Second note").?);
}

test "footnotes preserve paragraphs lists code and media in their bodies" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const html = try toHtmlWithOptions(gpa,
        \\See[^details].
        \\[^details]: **First** paragraph & <script>.
        \\    Continued line.
        \\
        \\    Second paragraph with [a link](https://example.com).
        \\
        \\    - Item with `code`
        \\    - Another item
        \\
        \\    ![Screen](screen.png "Caption")
        \\
        \\    ```text
        \\    [^fake]: Code stays literal.
        \\    ```
        \\
        \\After the definition. [^fake]
    , .{
        .asset_url_prefix = "/post/example/assets/",
        .thumbnail_url_prefix = "/post/example/thumbnails/",
        .thumbnail_paths = &.{"screen.png"},
        .footnote_id_prefix = "post-42-",
    });
    defer gpa.free(html);
    for ([_][]const u8{
        "<p>After the definition. [^fake]</p>",
        "<li id=\"fn-post-42-1\" tabindex=\"-1\">",
        "<p><strong>First</strong> paragraph &amp; &lt;script&gt;.\nContinued line.</p>",
        "<p>Second paragraph with <a href=\"https://example.com\">a link</a>.</p>",
        "<ul>\n<li>Item with <code>code</code></li>\n<li>Another item</li>\n</ul>",
        "href=\"/post/example/assets/screen.png\"",
        "src=\"/post/example/thumbnails/screen.png\"",
        "<figcaption>Caption</figcaption>",
        "<pre><code class=\"language-text\">[^fake]: Code stays literal.\n</code></pre>",
    }) |expected| try testing.expect(std.mem.indexOf(u8, html, expected) != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "role=\"doc-noteref\""));
}

test "footnotes leave undefined escaped code and link label references literal" {
    try expectHtml(
        \\[^missing] [^*unknown*] [^] [^two words] [^unclosed
        \\
        \\`[^note]` and \[^note] and \[^*note*] and [label[^note]](https://example.com).
        \\
        \\![Alt[^note]](screen.png "Caption[^note]")
        \\
        \\```
        \\[^note]: A literal definition.
        \\```
        \\
        \\[^note]: Not referenced outside code or a link label.
    ,
        "<p>[^missing] [^*unknown*] [^] [^two words] [^unclosed</p>\n" ++
            "<p><code>[^note]</code> and [^note] and [^*note*] and " ++
            "<a href=\"https://example.com\">label[^note]</a>.</p>\n" ++
            "<figure>\n<img src=\"screen.png\" alt=\"Alt[^note]\" " ++
            "title=\"Caption[^note]\" />\n<figcaption>Caption[^note]</figcaption>\n</figure>\n" ++
            "<pre><code>[^note]: A literal definition.\n</code></pre>\n",
    );
    try expectHtml("[^unused]: Hidden.", "");
    try expectHtml(
        "[^note]\n\n```\n[^note]: Only in code.\n```",
        "<p>[^note]</p>\n<pre><code>[^note]: Only in code.\n</code></pre>\n",
    );
}

test "footnotes count references inside notes before emitting return links" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const html = try toHtml(gpa,
        \\Start[^one].
        \\
        \\[^one]: Next[^two] and self[^one].
        \\[^two]: Back[^one].
    );
    defer gpa.free(html);
    for ([_][]const u8{
        "id=\"fnref-1-3\" href=\"#fn-1\"",
        "id=\"fnref-2-1\" href=\"#fn-2\"",
        "href=\"#fnref-1-3\" role=\"doc-backlink\"",
        "href=\"#fnref-2-1\" role=\"doc-backlink\"",
    }) |expected| try testing.expect(std.mem.indexOf(u8, html, expected) != null);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, html, "role=\"doc-noteref\""));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, html, "role=\"doc-backlink\""));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, html, "<li id=\"fn-"));
}

test "footnotes release all allocations on failure" {
    const check = struct {
        fn render(gpa: Allocator) !void {
            const html = try toHtml(gpa, "First[^a], second[^b], and again[^a].\n\n" ++
                "[^b]: Second note.\n\n[^a]: First note.\n\n    More **details**.");
            defer gpa.free(html);
            try std.testing.expect(std.mem.indexOf(u8, html, "<strong>details</strong>") != null);
            try std.testing.expect(std.mem.indexOf(u8, html, "href=\"#fnref-1-2\"") != null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check.render, .{});
}

test "footnotes keep unindented wrapped lines in the same paragraph" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const html = try toHtml(gpa,
        \\A weird bug[^bug].
        \\
        \\[^bug]: In KDE, the dock will display a volume icon if that window is playing
        \\    sound. I had helium playing a video and noticed
        \\that flamez was also getting the volume icon.
        \\The fix sets the `app_id` and needs a
        \\[patch](https://example.com/patch).
    );
    defer gpa.free(html);
    const expected_note =
        "<li id=\"fn-1\" tabindex=\"-1\">\n" ++
        "<p>In KDE, the dock will display a volume icon if that window is playing\n" ++
        "sound. I had helium playing a video and noticed\n" ++
        "that flamez was also getting the volume icon.\n" ++
        "The fix sets the <code>app_id</code> and needs a\n" ++
        "<a href=\"https://example.com/patch\">patch</a>.&#160;<span class=\"footnote-backlinks\">";
    try testing.expect(std.mem.indexOf(u8, html, expected_note) != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "that flamez"));
}

test "footnotes stop lazy continuation at paragraph and block boundaries" {
    const testing = std.testing;
    const gpa = testing.allocator;
    for ([_][]const u8{
        "\nOutside.",
        "# Outside\n\nBody.",
        "- Outside\n\nBody.",
        "> Outside\n\nBody.",
        "```\nOutside\n```",
        "[^next]: Another note.\n\nOutside.",
    }) |following| {
        const source = try std.fmt.allocPrint(
            gpa,
            "See[^note].\n\n[^note]: Inside.\n{s}",
            .{following},
        );
        defer gpa.free(source);
        const html = try toHtml(gpa, source);
        defer gpa.free(html);
        const section = std.mem.indexOf(u8, html, "<section class=\"footnotes\"").?;
        try testing.expect(std.mem.indexOf(u8, html[0..section], "Outside") != null);
        try testing.expect(std.mem.indexOf(u8, html[section..], "Outside") == null);
    }

    const html = try toHtml(gpa,
        \\See[^code].
        \\
        \\[^code]: A code example.
        \\
        \\    ```text
        \\    Code remains in the note.
        \\    ```
        \\Outside after the code block.
    );
    defer gpa.free(html);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "<p>Outside after the code block.</p>\n<section class=\"footnotes\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "<pre><code class=\"language-text\">Code remains in the note.\n</code></pre>",
    ) != null);
}
