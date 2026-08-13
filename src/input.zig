//! Just enough terminal input decoding for a two-key-deep list, plus the
//! mouse reports corral asks for while a task is focused.
//!
//! Corral only needs to recognise keys while the list has focus; once a task
//! is focused every byte goes to it verbatim apart from the mouse, so there
//! is nothing here about kitty protocols or modifier encodings.

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

// --- mouse ---------------------------------------------------------------

/// One SGR mouse report, as the host terminal sends it while a task is
/// focused. Corral only ever enables the SGR encoding, so this is the only
/// shape a report arrives in.
pub const Mouse = struct {
    /// The button code with its modifier and motion bits still in it, which
    /// is also the form a task's own program wants it forwarded in.
    button: u16,
    /// Host screen cell, 1-based, exactly as the terminal reported it.
    col: u16,
    row: u16,
    /// SGR ends a release with `m` and everything else with `M`.
    release: bool,

    pub const Wheel = enum { up, down };

    /// Bits 2..4 are shift, alt and ctrl.
    pub fn base(self: Mouse) u16 {
        return self.button & ~@as(u16, 0b11100);
    }

    /// Bit 5 means the pointer moved rather than a button changing state.
    pub fn motion(self: Mouse) bool {
        return self.button & 32 != 0;
    }

    pub fn wheel(self: Mouse) ?Wheel {
        return switch (self.base()) {
            64 => .up,
            65 => .down,
            else => null,
        };
    }
};

/// Where the next mouse report is in a buffer of bytes bound for a task.
pub const Scan = union(enum) {
    /// No report begins anywhere in here; every byte belongs to the task.
    none,
    /// A report begins at this offset but has not finished arriving.
    partial: usize,
    found: struct { at: usize, len: usize, mouse: Mouse },
};

/// Find the first mouse report in `buf`.
///
/// The bytes around a report are the user's own typing and must reach the
/// task untouched, so this reports an offset rather than decoding the lot.
pub fn scanMouse(buf: []const u8) Scan {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, buf, from, 0x1b)) |at| {
        switch (parseMouse(buf[at..])) {
            .no => from = at + 1,
            .partial => return .{ .partial = at },
            .ok => |ok| return .{ .found = .{ .at = at, .len = ok.len, .mouse = ok.mouse } },
        }
    }
    return .none;
}

const Parsed = union(enum) {
    no,
    partial,
    ok: struct { len: usize, mouse: Mouse },
};

fn parseMouse(buf: []const u8) Parsed {
    // Only `ESC [ <` is worth holding bytes back for. A trailing lone ESC is
    // overwhelmingly the Escape key, and waiting to find out would stall
    // every press of it inside the task; a report split across two reads
    // right after its ESC is the far rarer accident.
    if (buf.len < 3) return .no;
    if (buf[1] != '[' or buf[2] != '<') return .no;

    var nums: [3]u16 = @splat(0);
    var count: usize = 0;
    var digits = false;

    var i: usize = 3;
    while (i < buf.len) : (i += 1) {
        const ch = buf[i];
        switch (ch) {
            '0'...'9' => {
                const wider = @as(u32, nums[count]) * 10 + (ch - '0');
                if (wider > std.math.maxInt(u16)) return .no;
                nums[count] = @intCast(wider);
                digits = true;
            },
            ';' => {
                if (!digits or count == 2) return .no;
                count += 1;
                digits = false;
            },
            'M', 'm' => {
                if (!digits or count != 2) return .no;
                return .{ .ok = .{
                    .len = i + 1,
                    .mouse = .{
                        .button = nums[0],
                        .col = nums[1],
                        .row = nums[2],
                        .release = ch == 'm',
                    },
                } };
            },
            else => return .no,
        }
    }
    return .partial;
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

test "a mouse report is found among ordinary typing" {
    const scan = scanMouse("ls\x1b[<64;10;5Mrest");
    const found = scan.found;
    try testing.expectEqual(@as(usize, 2), found.at);
    try testing.expectEqual("\x1b[<64;10;5M".len, found.len);
    try testing.expectEqual(@as(u16, 10), found.mouse.col);
    try testing.expectEqual(@as(u16, 5), found.mouse.row);
    try testing.expectEqual(Mouse.Wheel.up, found.mouse.wheel().?);
    try testing.expect(!found.mouse.release);
}

test "wheel survives modifiers, buttons are not wheels" {
    // Ctrl-wheel-down: 65 + 16.
    try testing.expectEqual(Mouse.Wheel.down, scanMouse("\x1b[<81;1;1M").found.mouse.wheel().?);
    try testing.expectEqual(@as(?Mouse.Wheel, null), scanMouse("\x1b[<0;1;1M").found.mouse.wheel());
    try testing.expect(scanMouse("\x1b[<0;1;1m").found.mouse.release);
    try testing.expect(scanMouse("\x1b[<35;1;1M").found.mouse.motion());
}

test "an unfinished report asks for more bytes" {
    try testing.expectEqual(@as(usize, 0), scanMouse("\x1b[<").partial);
    try testing.expectEqual(@as(usize, 1), scanMouse("k\x1b[<64;10").partial);
    // A lone ESC is the Escape key until proven otherwise; holding it back
    // would stall every press of it inside a focused task.
    try testing.expectEqual(Scan.none, scanMouse("\x1b"));
    try testing.expectEqual(Scan.none, scanMouse("\x1b["));
}

test "keys that merely look like reports are left alone" {
    try testing.expectEqual(Scan.none, scanMouse("\x1b[A"));
    try testing.expectEqual(Scan.none, scanMouse("\x1b[200~pasted\x1b[201~"));
    // Malformed: too few parameters, and a stray letter mid-number.
    try testing.expectEqual(Scan.none, scanMouse("\x1b[<64;10M"));
    try testing.expectEqual(Scan.none, scanMouse("\x1b[<64;1q;5M"));
    // The scan resumes after a false start rather than giving up on the buffer.
    try testing.expectEqual(@as(usize, 3), scanMouse("\x1b[A\x1b[<64;10;5M").found.at);
}

test "a decoded sequence never leaves stray letters behind" {
    // The bug this guards against: consuming only the ESC of an unknown
    // sequence, so the rest of it arrives as commands.
    const seq = "\x1b[200~";
    const d = decode(seq);
    try testing.expectEqual(seq.len, d.len);
}
