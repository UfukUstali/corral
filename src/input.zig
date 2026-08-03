//! Just enough terminal input decoding for a two-key-deep list.
//!
//! Corral only needs to recognise keys while the list has focus; once a task
//! is focused every byte goes to it verbatim, so there is nothing here about
//! kitty protocols, modifier encodings or mouse reports.

const std = @import("std");

pub const Key = union(enum) {
    /// A plain printable character.
    char: u8,
    /// A control character, stored as the letter it is made from: 0x03 is
    /// `.{ .ctrl = 'c' }`.
    ctrl: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    enter,
    escape,
    /// Something we do not care about. Consumed, ignored.
    unknown,
};

pub const Decoded = struct {
    key: Key,
    /// Bytes consumed. Zero means "incomplete sequence, wait for more".
    len: usize,
};

/// Decode the next key from `buf`.
///
/// Returns `len == 0` when `buf` holds the start of an escape sequence but
/// not all of it, which happens routinely because a single arrow key can
/// arrive split across two reads.
pub fn decode(buf: []const u8) Decoded {
    if (buf.len == 0) return .{ .key = .unknown, .len = 0 };

    const b = buf[0];
    switch (b) {
        0x1b => return decodeEscape(buf),
        '\r', '\n' => return .{ .key = .enter, .len = 1 },
        0x7f => return .{ .key = .{ .ctrl = 'h' }, .len = 1 },
        0x00 => return .{ .key = .{ .ctrl = ' ' }, .len = 1 },
        // Ctrl-A..Ctrl-Z minus the two that already mean Enter.
        0x01...0x09, 0x0b, 0x0c, 0x0e...0x1a => {
            return .{ .key = .{ .ctrl = b + 'a' - 1 }, .len = 1 };
        },
        else => {},
    }

    // Everything printable, including UTF-8 continuation bytes, which the
    // list has no use for but must still consume one at a time.
    return .{ .key = .{ .char = b }, .len = 1 };
}

fn decodeEscape(buf: []const u8) Decoded {
    // A lone ESC. We cannot tell it apart from the start of a sequence
    // without waiting, and the caller resolves that with a timeout.
    if (buf.len == 1) return .{ .key = .unknown, .len = 0 };

    switch (buf[1]) {
        '[' => {},
        // SS3, as sent by some terminals for arrows in application mode.
        'O' => {
            if (buf.len < 3) return .{ .key = .unknown, .len = 0 };
            return .{ .key = switch (buf[2]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                else => .unknown,
            }, .len = 3 };
        },
        // ESC followed by anything else is Alt+key, which corral does not
        // bind. Consume both so the letter does not act on its own.
        else => return .{ .key = .unknown, .len = 2 },
    }

    // CSI: parameters, then a final byte in 0x40..0x7e.
    var i: usize = 2;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c >= 0x40 and c <= 0x7e) {
            const params = buf[2..i];
            return .{ .key = csiKey(params, c), .len = i + 1 };
        }
    }
    return .{ .key = .unknown, .len = 0 };
}

fn csiKey(params: []const u8, final: u8) Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '~' => blk: {
            const n = std.fmt.parseInt(u16, params, 10) catch break :blk .unknown;
            break :blk switch (n) {
                1, 7 => .home,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                else => .unknown,
            };
        },
        else => .unknown,
    };
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "plain characters" {
    try testing.expectEqual(Decoded{ .key = .{ .char = 'j' }, .len = 1 }, decode("j"));
    try testing.expectEqual(Decoded{ .key = .enter, .len = 1 }, decode("\r"));
}

test "control characters name their letter" {
    try testing.expectEqual(Decoded{ .key = .{ .ctrl = 'a' }, .len = 1 }, decode("\x01"));
    try testing.expectEqual(Decoded{ .key = .{ .ctrl = 'c' }, .len = 1 }, decode("\x03"));
    try testing.expectEqual(Decoded{ .key = .{ .ctrl = 'u' }, .len = 1 }, decode("\x15"));
}

test "arrows in both encodings" {
    try testing.expectEqual(Decoded{ .key = .up, .len = 3 }, decode("\x1b[A"));
    try testing.expectEqual(Decoded{ .key = .left, .len = 3 }, decode("\x1bOD"));
}

test "keypad sequences" {
    try testing.expectEqual(Decoded{ .key = .page_up, .len = 4 }, decode("\x1b[5~"));
    try testing.expectEqual(Decoded{ .key = .page_down, .len = 4 }, decode("\x1b[6~"));
    // Modified keys still resolve to the base key rather than acting as text.
    try testing.expectEqual(Decoded{ .key = .up, .len = 6 }, decode("\x1b[1;5A"));
}

test "partial sequences ask for more bytes" {
    try testing.expectEqual(@as(usize, 0), decode("\x1b").len);
    try testing.expectEqual(@as(usize, 0), decode("\x1b[").len);
    try testing.expectEqual(@as(usize, 0), decode("\x1b[5").len);
    try testing.expectEqual(@as(usize, 4), decode("\x1b[5~").len);
}

test "a decoded sequence never leaves stray letters behind" {
    // The bug this guards against: consuming only the ESC of an unknown
    // sequence, so the rest of it arrives as commands.
    const seq = "\x1b[200~";
    const d = decode(seq);
    try testing.expectEqual(seq.len, d.len);
}
