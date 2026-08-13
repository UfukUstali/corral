//! One task: a terminal emulator, the pty its process runs on, and the
//! small state machine that connects them.
//!
//! Tasks are heap allocated and never moved. Ghostty's stream handler holds
//! a pointer back to its terminal, and the pty write-back effect finds this
//! struct with `@fieldParentPtr`, so a `Task` that moved would corrupt both.

const Task = @This();

const std = @import("std");
const ghostty = @import("ghostty-vt");

const Config = @import("Config.zig");
const Pty = @import("Pty.zig");
const input = @import("input.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.task);

/// How long a task gets to honour its stop request before it is killed.
pub const stop_grace_ms: i64 = 5000;

/// Scrollback per task. Ghostty stores this compactly and compresses cold
/// history, so this is far cheaper than the equivalent line count suggests.
const max_scrollback_bytes: usize = 8 * 1024 * 1024;

pub const State = enum { stopped, running, stopping };

pub const Exit = union(enum) {
    /// Never started, or started and stopped cleanly with no status yet.
    none,
    code: u8,
    signal: c_int,
    /// The fork or exec never got off the ground.
    spawn_failed,
};

gpa: Allocator,
io: std.Io,
cfg: *const Config.Task,

terminal: ghostty.Terminal,
/// Kept for the life of the task rather than recreated per write: escape
/// sequences routinely straddle read boundaries, and a fresh parser would
/// drop the tail of every one that does.
stream: ghostty.TerminalStream,
render: ghostty.RenderState,

pty: ?Pty = null,
state: State = .stopped,
exit: Exit = .none,

/// Set once the pty reports end-of-file, so the event loop stops polling a
/// descriptor that will only ever be readable-with-nothing.
eof: bool = false,
/// Monotonic ms after which a stopping task gets SIGKILL.
kill_at: ?i64 = null,
/// A `restart` that is waiting for the current process to die.
restart_pending: bool = false,
/// True when corral is the reason this process is going away. A task that
/// dies from the signal we sent it stopped; one that dies from a signal
/// nobody here sent was killed, and those should not look the same.
stop_requested: bool = false,

/// Output arrived since the last time this task was painted.
dirty: bool = true,
/// The task rang the bell since it was last looked at.
bell: bool = false,

cols: u16,
rows: u16,

pub fn create(
    gpa: Allocator,
    io: std.Io,
    cfg: *const Config.Task,
    cols: u16,
    rows: u16,
) !*Task {
    const self = try gpa.create(Task);
    errdefer gpa.destroy(self);

    self.* = .{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .terminal = try .init(io, gpa, .{
            .cols = @max(cols, 1),
            .rows = @max(rows, 1),
            .max_scrollback_bytes = max_scrollback_bytes,
        }),
        .stream = undefined,
        .render = .empty,
        .cols = @max(cols, 1),
        .rows = @max(rows, 1),
    };
    errdefer self.terminal.deinit(gpa);

    self.stream = self.terminal.vtStream();
    // Without these the stream is read-only: a program that asks the
    // terminal a question (device attributes, cursor position, background
    // colour) waits forever for an answer that never comes.
    self.stream.handler.effects.write_pty = &effectWritePty;
    self.stream.handler.effects.bell = &effectBell;

    return self;
}

pub fn destroy(self: *Task) void {
    if (self.pty) |*pty| {
        pty.signalGroup(Config.SIGKILL);
        pty.close();
    }
    self.render.deinit(self.gpa);
    self.stream.deinit();
    self.terminal.deinit(self.gpa);
    const gpa = self.gpa;
    gpa.destroy(self);
}

pub fn name(self: *const Task) []const u8 {
    return self.cfg.name;
}

// --- effects -------------------------------------------------------------

/// Recover the owning task from a handler pointer. The handler lives inside
/// the stream, which lives inside the task.
fn fromHandler(h: *ghostty.TerminalStream.Handler) *Task {
    const stream: *ghostty.TerminalStream = @fieldParentPtr("handler", h);
    return @fieldParentPtr("stream", stream);
}

fn effectWritePty(h: *ghostty.TerminalStream.Handler, data: [:0]const u8) void {
    const self = fromHandler(h);
    if (self.pty) |*pty| pty.write(data);
}

fn effectBell(h: *ghostty.TerminalStream.Handler) void {
    fromHandler(h).bell = true;
}

// --- lifecycle -----------------------------------------------------------

pub fn start(self: *Task) void {
    if (self.state != .stopped) return;

    self.exit = .none;
    self.eof = false;
    self.bell = false;
    self.kill_at = null;
    self.stop_requested = false;

    const pty = Pty.spawn(self.gpa, .{
        .shell = self.cfg.shell,
        .cwd = self.cfg.cwd,
        .env = self.cfg.env,
        .rows = self.rows,
        .cols = self.cols,
    }) catch |err| {
        // A missing cwd or an exhausted pty pool should show up in the
        // task's own pane, not take the whole app down.
        self.feedOwnMessage("corral: could not start", @errorName(err));
        self.state = .stopped;
        self.exit = .spawn_failed;
        return;
    };

    self.pty = pty;
    self.state = .running;
    self.dirty = true;
}

/// Ask the task to stop the way its config says to.
pub fn stop(self: *Task, now_ms: i64) void {
    if (self.state != .running) return;
    self.state = .stopping;
    self.stop_requested = true;
    switch (self.cfg.stop) {
        .keys => |data| if (self.pty) |*pty| pty.write(data),
        .signal => |sig| if (self.pty) |*pty| pty.signalGroup(sig),
    }
    self.kill_at = now_ms + stop_grace_ms;
    self.dirty = true;
}

/// SIGKILL now, no grace period.
pub fn kill(self: *Task) void {
    if (self.state == .stopped) return;
    self.kill_at = null;
    self.stop_requested = true;
    if (self.pty) |*pty| pty.signalGroup(Config.SIGKILL);
}

pub fn restart(self: *Task, now_ms: i64) void {
    if (self.state == .stopped) {
        self.start();
        return;
    }
    // Deferred rather than immediate: the new process cannot have the pty
    // until the old one has actually let go of it.
    self.restart_pending = true;
    if (self.state == .running) self.stop(now_ms);
}

/// Called by the event loop once `waitpid` has a status for our child.
pub fn reap(self: *Task, status: c_int) void {
    // Whatever the process managed to say before dying is still worth
    // showing, and it is sitting in the pty buffer right now.
    _ = self.drain();

    if (self.pty) |*pty| pty.close();
    self.pty = null;
    self.state = .stopped;
    self.kill_at = null;
    self.eof = true;
    self.dirty = true;

    const c = @import("c.zig");
    if (c.termSignal(status)) |sig| {
        self.exit = .{ .signal = sig };
    } else {
        self.exit = .{ .code = c.exitStatus(status) };
    }

    if (self.restart_pending) {
        self.restart_pending = false;
        self.start();
    }
}

// --- io ------------------------------------------------------------------

/// Read whatever the process has produced and feed it to the emulator.
/// Returns true if anything was consumed.
pub fn drain(self: *Task) bool {
    const pty = if (self.pty) |*p| p else return false;

    var progressed = false;
    var buf: [64 * 1024]u8 = undefined;
    // Bounded so one very chatty task cannot starve the rest of the loop.
    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        const n = pty.read(&buf) orelse break;
        if (n == 0) {
            self.eof = true;
            break;
        }
        self.stream.nextSlice(buf[0..n]);
        progressed = true;
    }

    if (progressed) self.dirty = true;
    return progressed;
}

/// Send raw bytes to the process, as typed.
pub fn write(self: *Task, data: []const u8) void {
    if (self.pty) |*pty| pty.write(data);
}

pub fn resize(self: *Task, cols: u16, rows: u16) void {
    const c = @max(cols, 1);
    const r = @max(rows, 1);
    if (c == self.cols and r == self.rows) return;
    self.cols = c;
    self.rows = r;

    // Go through the handler rather than `Terminal.resize` so that programs
    // using in-band size reports (mode 2048) are told about it.
    self.stream.handler.resize(.{ .cols = c, .rows = r }) catch |err| {
        log.warn("resize failed for {s}: {t}", .{ self.name(), err });
    };
    if (self.pty) |*pty| pty.resize(r, c);
    self.dirty = true;
}

// --- viewport ------------------------------------------------------------

pub fn scroll(self: *Task, delta: isize) void {
    self.terminal.scrollViewport(.{ .delta = delta });
    self.dirty = true;
}

pub fn scrollToTop(self: *Task) void {
    self.terminal.scrollViewport(.top);
    self.dirty = true;
}

pub fn scrollToBottom(self: *Task) void {
    self.terminal.scrollViewport(.bottom);
    self.dirty = true;
}

/// True when the viewport is following new output rather than parked in
/// the scrollback.
pub fn atBottom(self: *Task) bool {
    return self.terminal.screens.active.pages.viewport == .active;
}

/// How far back the viewport is, in rows, for the scroll indicator.
pub fn scrollbackOffset(self: *Task) usize {
    const bar = self.terminal.screens.active.pages.scrollbar();
    const bottom = bar.total -| bar.len;
    return bottom -| bar.offset;
}

// --- mouse ---------------------------------------------------------------

/// True when the program running here asked to be sent mouse events itself.
pub fn wantsMouse(self: *const Task) bool {
    const m = &self.terminal.modes;
    return m.get(.mouse_event_x10) or m.get(.mouse_event_normal) or
        m.get(.mouse_event_button) or m.get(.mouse_event_any);
}

/// True when the program is on the alternate screen, which means it draws a
/// whole screen of its own and there is no scrollback of ours behind it.
pub fn onAltScreen(self: *const Task) bool {
    return self.terminal.screens.active_key == .alternate;
}

/// What an arrow key sends to this program, which depends on whether it put
/// its cursor keys in application mode.
pub fn arrowKey(self: *const Task, dir: enum { up, down }) []const u8 {
    const app = self.terminal.modes.get(.cursor_keys);
    return switch (dir) {
        .up => if (app) "\x1bOA" else "\x1b[A",
        .down => if (app) "\x1bOB" else "\x1b[B",
    };
}

/// Hand a mouse event to the program, at `col`/`row` in its own screen and
/// encoded the way it asked for.
///
/// The host reports to corral in SGR whatever the program here understands,
/// so this is a re-encoding rather than a pass-through.
pub fn writeMouse(self: *Task, ev: input.Mouse, col: u16, row: u16) void {
    const m = &self.terminal.modes;

    // Motion is only interesting to the two modes that asked for it, and
    // mode 9 predates the idea of reporting a release at all.
    if (ev.motion() and !(m.get(.mouse_event_button) or m.get(.mouse_event_any))) return;
    if (ev.release and !(m.get(.mouse_event_normal) or
        m.get(.mouse_event_button) or m.get(.mouse_event_any))) return;

    var buf: [32]u8 = undefined;
    if (m.get(.mouse_format_sgr) or m.get(.mouse_format_sgr_pixels)) {
        // Pixel coordinates (1016) would need a cell size corral has no way
        // of knowing, so a program asking for those gets cells anyway.
        const out = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
            ev.button,
            col,
            row,
            @as(u8, if (ev.release) 'm' else 'M'),
        }) catch return;
        self.write(out);
        return;
    }

    // The original encoding: three bytes offset by 32, so nothing past
    // column 223 fits and a release is just "some button came up".
    if (col > 223 or row > 223) return;
    const button = if (ev.release) (ev.button & ~@as(u16, 0b11)) | 0b11 else ev.button;
    if (button > 223 - 32) return;
    const out = std.fmt.bufPrint(&buf, "\x1b[M{c}{c}{c}", .{
        @as(u8, @intCast(32 + button)),
        @as(u8, @intCast(32 + col)),
        @as(u8, @intCast(32 + row)),
    }) catch return;
    self.write(out);
}

// --- presentation --------------------------------------------------------

pub fn statusText(self: *const Task) []const u8 {
    return switch (self.state) {
        .running => "running",
        .stopping => "stopping",
        .stopped => switch (self.exit) {
            .none => "idle",
            .spawn_failed => "failed",
            .signal => if (self.stop_requested) "stopped" else "killed",
            .code => |code| if (code == 0) "done" else "exit",
        },
    };
}

/// The trailing detail for statuses that carry a number, or an empty slice.
pub fn statusDetail(self: *const Task, buf: []u8) []const u8 {
    return switch (self.state) {
        .stopped => switch (self.exit) {
            .code => |code| if (code == 0)
                ""
            else
                std.fmt.bufPrint(buf, " {d}", .{code}) catch "",
            .signal => |sig| if (self.stop_requested)
                ""
            else
                std.fmt.bufPrint(buf, " {d}", .{sig}) catch "",
            else => "",
        },
        else => "",
    };
}

pub fn failed(self: *const Task) bool {
    if (self.state != .stopped) return false;
    return switch (self.exit) {
        .code => |code| code != 0,
        // A task we asked to stop did what it was told; that is not a
        // failure to flag in red.
        .signal => !self.stop_requested,
        .spawn_failed => true,
        .none => false,
    };
}

/// Write a corral-generated line into the task's own pane, so problems with
/// starting a task appear where the user is already looking.
fn feedOwnMessage(self: *Task, prefix: []const u8, detail: []const u8) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "\r\n\x1b[31m{s}\x1b[0m: {s}\r\n",
        .{ prefix, detail },
    ) catch return;
    self.stream.nextSlice(msg);
    self.dirty = true;
}

/// Render the whole scrollback as VT text, for handing back to the host
/// terminal. Palette *indexes* are emitted rather than resolved colours so
/// the host's own theme still applies.
pub fn formatScrollback(self: *Task) ghostty.formatter.TerminalFormatter {
    var f: ghostty.formatter.TerminalFormatter = .init(&self.terminal, .{
        .emit = .vt,
        .trim = true,
        .unwrap = true,
    });
    // Nothing that would reprogram the host terminal: no OSC 4 palette
    // rewrite, no cursor positioning, no mode changes.
    f.extra = .none;
    return f;
}

test {
    std.testing.refAllDecls(@This());
}
