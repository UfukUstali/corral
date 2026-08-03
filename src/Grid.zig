//! A double-buffered cell grid that knows how to turn "what changed" into
//! the smallest reasonable pile of escape sequences.
//!
//! This is the whole of corral's TUI. There is no widget tree, no layout
//! pass and no reusable abstraction: callers compute coordinates themselves
//! and write cells. For one side panel and one output pane that is less
//! code than configuring a framework, and it means the pane can be a direct
//! blit of a terminal grid rather than a translation into someone else's
//! cell model.

const Grid = @This();

const std = @import("std");
const ghostty = @import("ghostty-vt");

const Allocator = std.mem.Allocator;

/// Bytes of text per cell. Enough for any single codepoint plus the common
/// combining and emoji-ZWJ clusters; longer clusters are truncated at a
/// codepoint boundary, which is what every terminal does at some width
/// anyway.
pub const text_max = 16;

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Color = union(enum) {
    /// The host terminal's own default. Emitted as SGR 39/49 so the user's
    /// theme keeps deciding what it looks like.
    default,
    palette: u8,
    rgb: Rgb,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .palette => |p| b == .palette and b.palette == p,
            .rgb => |v| b == .rgb and
                b.rgb.r == v.r and b.rgb.g == v.g and b.rgb.b == v.b,
        };
    }
};

pub const Underline = enum(u3) { none, single, double, curly, dotted, dashed };

pub const Attrs = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: Underline = .none,
    _pad: u5 = 0,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    underline_color: Color = .default,
    attrs: Attrs = .{},

    pub fn eql(a: Style, b: Style) bool {
        return @as(u16, @bitCast(a.attrs)) == @as(u16, @bitCast(b.attrs)) and
            a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            a.underline_color.eql(b.underline_color);
    }
};

pub const Cell = struct {
    text: [text_max]u8 = [_]u8{' '} ++ [_]u8{0} ** (text_max - 1),
    len: u8 = 1,
    /// Columns this cell occupies. Zero marks the second half of a wide
    /// glyph: it is never emitted, only skipped over.
    width: u8 = 1,
    style: Style = .{},

    pub const blank: Cell = .{};

    pub fn eql(a: *const Cell, b: *const Cell) bool {
        return a.len == b.len and
            a.width == b.width and
            std.mem.eql(u8, a.text[0..a.len], b.text[0..b.len]) and
            a.style.eql(b.style);
    }

    pub fn fromSlice(bytes: []const u8, width: u8, style: Style) Cell {
        var cell: Cell = .{ .width = width, .style = style };
        const n = @min(bytes.len, text_max);
        @memcpy(cell.text[0..n], bytes[0..n]);
        cell.len = @intCast(n);
        return cell;
    }
};

cols: u16 = 0,
rows: u16 = 0,
/// What the terminal is currently showing.
front: []Cell = &.{},
/// What we want it to show.
back: []Cell = &.{},
/// Where the cursor should end up, if it should be visible at all.
cursor: ?struct { x: u16, y: u16 } = null,
/// Set when the front buffer can no longer be trusted (resize, resume from
/// a suspend). Forces a clear and a full repaint.
damaged: bool = true,
/// The frame under construction. Reused between frames so a steady stream
/// of output does not churn the allocator.
out: std.ArrayList(u8) = .empty,

pub fn deinit(self: *Grid, gpa: Allocator) void {
    gpa.free(self.front);
    gpa.free(self.back);
    self.out.deinit(gpa);
    self.* = .{};
}

pub fn resize(self: *Grid, gpa: Allocator, cols: u16, rows: u16) Allocator.Error!void {
    if (self.cols == cols and self.rows == rows) return;
    const count = @as(usize, cols) * @as(usize, rows);

    const front = try gpa.alloc(Cell, count);
    errdefer gpa.free(front);
    const back = try gpa.alloc(Cell, count);

    gpa.free(self.front);
    gpa.free(self.back);
    self.front = front;
    self.back = back;
    self.cols = cols;
    self.rows = rows;
    self.damaged = true;
}

/// Reset the frame under construction to blanks. Called once per frame,
/// before anything draws.
pub fn clear(self: *Grid) void {
    @memset(self.back, .blank);
    self.cursor = null;
}

pub fn set(self: *Grid, x: u16, y: u16, cell: Cell) void {
    if (x >= self.cols or y >= self.rows) return;
    self.back[@as(usize, y) * self.cols + x] = cell;
}

/// Paint a run of cells with just a background, e.g. the selected row.
pub fn fill(self: *Grid, x: u16, y: u16, width: u16, style: Style) void {
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        self.set(x + i, y, .{ .style = style });
    }
}

/// Draw text, clipped to `max_width` columns. Returns the number of columns
/// actually used.
pub fn text(self: *Grid, x: u16, y: u16, str: []const u8, max_width: u16, style: Style) u16 {
    var col: u16 = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = str, .i = 0 };
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch continue;
        // Control characters have no business in a panel label, and letting
        // one through would desynchronise the cursor from the grid.
        if (cp < 0x20 or cp == 0x7f) continue;
        const w = ghostty.unicode.codepointWidth(@intCast(cp));
        if (w == 0) continue;
        if (col + w > max_width) break;

        self.set(x + col, y, .fromSlice(slice, @intCast(w), style));
        if (w == 2) self.set(x + col + 1, y, .{ .width = 0, .style = style });
        col += w;
    }
    return col;
}

/// Like `text`, but ellipsises rather than cutting a name off mid-word.
pub fn textEllipsis(
    self: *Grid,
    x: u16,
    y: u16,
    str: []const u8,
    max_width: u16,
    style: Style,
) u16 {
    if (max_width == 0) return 0;
    if (displayWidth(str) <= max_width) return self.text(x, y, str, max_width, style);
    const used = self.text(x, y, str, max_width - 1, style);
    _ = self.text(x + used, y, "…", 1, style);
    return used + 1;
}

pub fn displayWidth(str: []const u8) u16 {
    var total: u16 = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = str, .i = 0 };
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch continue;
        if (cp < 0x20 or cp == 0x7f) continue;
        total += ghostty.unicode.codepointWidth(@intCast(cp));
    }
    return total;
}

// --- flushing ------------------------------------------------------------

/// The pen state the host terminal is in, as far as we know.
const Pen = struct {
    style: ?Style = null,
    /// Cursor position, or null when we are not sure where it is.
    x: ?u16 = null,
    y: ?u16 = null,
};

/// Diff the frame against what is on screen and return the bytes that turn
/// one into the other. The returned slice is owned by the grid and stays
/// valid until the next `flush`.
pub fn flush(self: *Grid, gpa: Allocator) Allocator.Error![]const u8 {
    self.out.clearRetainingCapacity();
    const w = &self.out;

    // Synchronized output: the host terminal presents the whole frame at
    // once instead of showing it being painted. Terminals that don't know
    // the sequence ignore it.
    try w.appendSlice(gpa, "\x1b[?2026h");
    // Hide the cursor for the duration, so it does not visibly skate across
    // the screen as cells are updated.
    try w.appendSlice(gpa, "\x1b[?25l");

    var pen: Pen = .{};

    if (self.damaged) {
        try w.appendSlice(gpa, "\x1b[0m\x1b[2J");
        pen.style = .{};
        // A cleared screen contains blanks with the default style, which is
        // exactly what a fresh front buffer says.
        @memset(self.front, .blank);
        self.damaged = false;
    }

    var y: u16 = 0;
    while (y < self.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < self.cols) {
            const i = @as(usize, y) * self.cols + x;
            const cell = &self.back[i];
            const width = @max(cell.width, 1);

            if (cell.width == 0 or cell.eql(&self.front[i])) {
                x += width;
                continue;
            }

            if (pen.x == null or pen.x.? != x or pen.y.? != y) {
                try w.print(gpa, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
                pen.x = x;
                pen.y = y;
            }

            if (pen.style == null or !pen.style.?.eql(cell.style)) {
                try writeStyle(gpa, w, cell.style);
                pen.style = cell.style;
            }

            try w.appendSlice(gpa, cell.text[0..cell.len]);
            self.front[i] = cell.*;
            // Wide glyphs consume their spacer cell too, which is already
            // identical in both buffers by construction.
            if (cell.width == 2 and i + 1 < self.front.len) self.front[i + 1] = self.back[i + 1];

            pen.x = pen.x.? + width;
            // Autowrap is off, so the terminal parks the cursor on the last
            // column instead of moving on. Forget where it is rather than
            // guess.
            if (pen.x.? >= self.cols) {
                pen.x = null;
                pen.y = null;
            }
            x += width;
        }
    }

    if (self.cursor) |pos| {
        try w.print(gpa, "\x1b[{d};{d}H\x1b[?25h", .{ pos.y + 1, pos.x + 1 });
    }

    try w.appendSlice(gpa, "\x1b[?2026l");
    return w.items;
}

fn writeStyle(gpa: Allocator, w: *std.ArrayList(u8), style: Style) Allocator.Error!void {
    // Reset first and reapply. Computing a minimal attribute delta saves a
    // handful of bytes per style run and costs a great deal of subtlety
    // around attributes that have no individual "off" code.
    try w.appendSlice(gpa, "\x1b[0");

    const a = style.attrs;
    if (a.bold) try w.appendSlice(gpa, ";1");
    if (a.dim) try w.appendSlice(gpa, ";2");
    if (a.italic) try w.appendSlice(gpa, ";3");
    switch (a.underline) {
        .none => {},
        .single => try w.appendSlice(gpa, ";4"),
        .double => try w.appendSlice(gpa, ";4:2"),
        .curly => try w.appendSlice(gpa, ";4:3"),
        .dotted => try w.appendSlice(gpa, ";4:4"),
        .dashed => try w.appendSlice(gpa, ";4:5"),
    }
    if (a.blink) try w.appendSlice(gpa, ";5");
    if (a.inverse) try w.appendSlice(gpa, ";7");
    if (a.invisible) try w.appendSlice(gpa, ";8");
    if (a.strikethrough) try w.appendSlice(gpa, ";9");
    if (a.overline) try w.appendSlice(gpa, ";53");

    try writeColor(gpa, w, style.fg, .fg);
    try writeColor(gpa, w, style.bg, .bg);
    if (a.underline != .none) try writeColor(gpa, w, style.underline_color, .underline);

    try w.append(gpa, 'm');
}

const ColorRole = enum { fg, bg, underline };

fn writeColor(
    gpa: Allocator,
    w: *std.ArrayList(u8),
    color: Color,
    role: ColorRole,
) Allocator.Error!void {
    switch (color) {
        // SGR 0 already put us back to the default, so there is nothing to
        // say. Passing the default through as 39/49 rather than a concrete
        // colour is the point: the user's own theme decides.
        .default => {},
        .palette => |idx| switch (role) {
            // The 16 ANSI colours have short forms that terminals map onto
            // the user's palette, so prefer them over 38;5;n.
            .fg => if (idx < 8)
                try w.print(gpa, ";{d}", .{30 + @as(u16, idx)})
            else if (idx < 16)
                try w.print(gpa, ";{d}", .{90 + @as(u16, idx) - 8})
            else
                try w.print(gpa, ";38;5;{d}", .{idx}),
            .bg => if (idx < 8)
                try w.print(gpa, ";{d}", .{40 + @as(u16, idx)})
            else if (idx < 16)
                try w.print(gpa, ";{d}", .{100 + @as(u16, idx) - 8})
            else
                try w.print(gpa, ";48;5;{d}", .{idx}),
            .underline => try w.print(gpa, ";58;5;{d}", .{idx}),
        },
        .rgb => |v| switch (role) {
            .fg => try w.print(gpa, ";38;2;{d};{d};{d}", .{ v.r, v.g, v.b }),
            .bg => try w.print(gpa, ";48;2;{d};{d};{d}", .{ v.r, v.g, v.b }),
            .underline => try w.print(gpa, ";58;2;{d};{d};{d}", .{ v.r, v.g, v.b }),
        },
    }
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

fn testGrid(cols: u16, rows: u16) !Grid {
    var g: Grid = .{};
    try g.resize(testing.allocator, cols, rows);
    // Consume the initial full repaint so tests can look at deltas.
    g.clear();
    _ = try g.flush(testing.allocator);
    return g;
}

test "an unchanged frame emits no drawing" {
    var g = try testGrid(10, 3);
    defer g.deinit(testing.allocator);

    g.clear();
    const frame = try g.flush(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, frame, "H") == null);
}

test "only changed cells are redrawn" {
    var g = try testGrid(10, 3);
    defer g.deinit(testing.allocator);

    g.clear();
    _ = g.text(2, 1, "hi", 10, .{});
    const frame = try g.flush(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, frame, "\x1b[2;3H") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "hi") != null);

    // Drawing the same thing again is a no-op.
    g.clear();
    _ = g.text(2, 1, "hi", 10, .{});
    const second = try g.flush(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, second, "hi") == null);
}

test "styles are emitted once per run" {
    var g = try testGrid(20, 1);
    defer g.deinit(testing.allocator);

    g.clear();
    _ = g.text(0, 0, "abc", 20, .{ .fg = .{ .palette = 2 }, .attrs = .{ .bold = true } });
    const frame = try g.flush(testing.allocator);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame, "\x1b[0;1;32m"));
}

test "wide glyphs occupy two columns" {
    var g = try testGrid(10, 1);
    defer g.deinit(testing.allocator);

    g.clear();
    const used = g.text(0, 0, "漢字", 10, .{});
    try testing.expectEqual(@as(u16, 4), used);
    try testing.expectEqual(@as(u8, 2), g.back[0].width);
    try testing.expectEqual(@as(u8, 0), g.back[1].width);
    try testing.expectEqual(@as(u8, 2), g.back[2].width);
}

test "text is clipped, not wrapped" {
    var g = try testGrid(10, 2);
    defer g.deinit(testing.allocator);

    g.clear();
    const used = g.text(0, 0, "abcdef", 3, .{});
    try testing.expectEqual(@as(u16, 3), used);
    // Nothing leaked onto the next row.
    try testing.expect(g.back[g.cols].eql(&Cell.blank));
}

test "ellipsis only when it does not fit" {
    var g = try testGrid(20, 2);
    defer g.deinit(testing.allocator);

    g.clear();
    try testing.expectEqual(@as(u16, 5), g.textEllipsis(0, 0, "short", 10, .{}));
    try testing.expectEqual(@as(u16, 4), g.textEllipsis(0, 1, "abcdefgh", 4, .{}));
    try testing.expectEqualStrings("…", g.back[g.cols + 3].text[0..g.back[g.cols + 3].len]);
}

test "default colors are left to the host theme" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try writeStyle(testing.allocator, &buf, .{});
    try testing.expectEqualStrings("\x1b[0m", buf.items);

    buf.clearRetainingCapacity();
    try writeStyle(testing.allocator, &buf, .{ .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } });
    try testing.expectEqualStrings("\x1b[0;38;2;1;2;3m", buf.items);
}
