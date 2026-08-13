//! The *host* terminal: the one corral itself is running inside.
//!
//! Owns raw mode, the alternate screen, the window size, and the self-pipe
//! that turns signals into something `poll` can wait on.

const Term = @This();

const std = @import("std");
const c = @import("c.zig");

const posix = std.posix;
const log = std.log.scoped(.term);

pub const in_fd: c.fd_t = 0;
pub const out_fd: c.fd_t = 1;

/// Termios as we found it. Restored verbatim on the way out.
saved: ?posix.termios = null,
rows: u16 = 24,
cols: u16 = 80,
raw: bool = false,
/// Whether we are currently asking the host to report the mouse. Kept as a
/// wish rather than a fact, so leaving and re-entering the alternate screen
/// restores it.
mouse: bool = false,

/// Read end of the self-pipe; the thing the event loop polls.
sig_r: c.fd_t = -1,
sig_w: c.fd_t = -1,

/// Signals are delivered to a handler that must be async-signal-safe, which
/// rules out touching a `Term` through a normal pointer. A file-scope write
/// end plus `write(2)` is the classic way out.
var signal_pipe_w: std.atomic.Value(c.fd_t) = .init(-1);

pub const Signal = enum(u8) {
    /// The window changed size.
    winch = 'w',
    /// At least one child exited; the loop should reap.
    child = 'c',
    /// The user or the system asked us to go away.
    quit = 'q',
};

pub fn init() !Term {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    setNonBlocking(fds[0]);
    setNonBlocking(fds[1]);
    signal_pipe_w.store(fds[1], .release);

    var self: Term = .{ .sig_r = fds[0], .sig_w = fds[1] };
    self.refreshSize();
    try installHandlers();
    return self;
}

pub fn deinit(self: *Term) void {
    self.leave();
    signal_pipe_w.store(-1, .release);
    if (self.sig_r >= 0) _ = c.close(self.sig_r);
    if (self.sig_w >= 0) _ = c.close(self.sig_w);
    self.sig_r = -1;
    self.sig_w = -1;
}

// --- screen state --------------------------------------------------------

/// Raw mode plus the alternate screen. Idempotent.
pub fn enter(self: *Term) !void {
    if (self.raw) return;

    const original = posix.tcgetattr(in_fd) catch return error.NotATerminal;
    self.saved = original;

    var t = original;
    t.iflag.IGNBRK = false;
    t.iflag.BRKINT = false;
    t.iflag.PARMRK = false;
    t.iflag.ISTRIP = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.ICRNL = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.lflag.ECHO = false;
    t.lflag.ECHONL = false;
    t.lflag.ICANON = false;
    // No ISIG: Ctrl-C belongs to whichever task is focused, and when nothing
    // is focused corral decides what it means. The host terminal must not
    // turn it into a signal behind our back.
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.cflag.PARENB = false;
    t.cflag.CSIZE = .CS8;
    // Blocking reads that return as soon as one byte lands. The event loop
    // only reads after `poll` says there is something, so this never waits.
    t.cc[@intFromEnum(posix.V.MIN)] = 1;
    t.cc[@intFromEnum(posix.V.TIME)] = 0;

    posix.tcsetattr(in_fd, .FLUSH, t) catch return error.NotATerminal;
    self.raw = true;

    self.writeAll(
        // Alternate screen, cursor hidden, autowrap off. Autowrap matters:
        // every cell is positioned explicitly, and writing the bottom-right
        // cell with it on would scroll the screen out from under us.
        "\x1b[?1049h" ++
            "\x1b[?25l" ++
            "\x1b[?7l" ++
            // Push the window title so we can hand it back untouched.
            "\x1b[22;2t" ++
            "\x1b]2;corral\x07" ++
            "\x1b[2J",
    );
    if (self.mouse) self.writeAll(mouse_on);
}

/// Mouse reporting: button presses, releases and drags in the SGR encoding.
///
/// Off by default, and on only while a task is focused. With it off the host
/// terminal owns the mouse, which is what keeps its own selection and
/// ctrl-click working over task output; with it on the same gestures still
/// work with shift held, which every terminal that reports the mouse honours.
///
/// The reason to turn it on at all: in the alternate screen with reporting
/// off, terminals translate the wheel into arrow keys, and a task's program
/// that is not reading its input then echoes them as `^[[A`.
pub fn setMouse(self: *Term, on: bool) void {
    if (self.mouse == on) return;
    self.mouse = on;
    if (self.raw) self.writeAll(if (on) mouse_on else mouse_off);
}

const mouse_on = "\x1b[?1002h\x1b[?1006h";
const mouse_off = "\x1b[?1006l\x1b[?1002l";

/// Put the terminal back exactly as we found it. Safe to call twice, and
/// safe to call from a panic handler.
pub fn leave(self: *Term) void {
    if (!self.raw) return;
    self.raw = false;

    // Before the alternate screen goes away, so the host is not left
    // reporting the mouse over whatever was underneath it.
    if (self.mouse) self.writeAll(mouse_off);
    self.writeAll(
        "\x1b[?7h" ++
            "\x1b[?25h" ++
            "\x1b[0m" ++
            "\x1b[?1049l" ++
            "\x1b[23;2t",
    );

    if (self.saved) |original| {
        posix.tcsetattr(in_fd, .FLUSH, original) catch {};
    }
}

/// Ask the kernel how big the window is now.
pub fn refreshSize(self: *Term) void {
    var ws: c.winsize = .{ .ws_row = 0, .ws_col = 0 };
    if (c.ioctl(out_fd, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        self.cols = ws.ws_col;
        self.rows = ws.ws_row;
        return;
    }
    // No window size (a pipe, or a terminal that will not say). 80x24 is the
    // convention and beats rendering into a 0x0 grid.
    self.cols = 80;
    self.rows = 24;
}

pub fn writeAll(self: *Term, bytes: []const u8) void {
    _ = self;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(out_fd, bytes[off..].ptr, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        switch (posix.errno(n)) {
            .INTR, .AGAIN => continue,
            else => return,
        }
    }
}

// --- signals -------------------------------------------------------------

fn onSignal(sig: posix.SIG) callconv(.c) void {
    const bytes = [_]u8{switch (sig) {
        .WINCH => @intFromEnum(Signal.winch),
        .CHLD => @intFromEnum(Signal.child),
        else => @intFromEnum(Signal.quit),
    }};
    const fd = signal_pipe_w.load(.acquire);
    if (fd < 0) return;
    // A full pipe means the loop already has wakeups queued, so dropping
    // this one loses nothing: the byte is a nudge, not the payload.
    _ = std.c.write(fd, &bytes, 1);
}

fn installHandlers() !void {
    var act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        // Restart interrupted syscalls where possible; the pipe byte, not
        // the EINTR, is what tells the loop something happened.
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.WINCH, &act, null);
    posix.sigaction(.CHLD, &act, null);
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.HUP, &act, null);
    // SIGINT can still arrive from outside (`kill -INT`) even though the
    // line discipline no longer generates it.
    posix.sigaction(.INT, &act, null);
}

pub const Pending = struct {
    winch: bool = false,
    child: bool = false,
    quit: bool = false,
};

/// Drain every byte the handler queued and collapse it into a summary.
pub fn drainSignals(self: *Term) Pending {
    var pending: Pending = .{};
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.c.read(self.sig_r, &buf, buf.len);
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |byte| switch (byte) {
            @intFromEnum(Signal.winch) => pending.winch = true,
            @intFromEnum(Signal.child) => pending.child = true,
            else => pending.quit = true,
        };
        if (@as(usize, @intCast(n)) < buf.len) break;
    }
    return pending;
}

fn setNonBlocking(fd: c.fd_t) void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return;
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

test {
    std.testing.refAllDecls(@This());
}
