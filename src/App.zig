//! Layout, input and the event loop.
//!
//! The side panel is one flat list at a time. At the top it lists every
//! `corral.json` found under the working directory; `l` steps into one and
//! the same list becomes that config's tasks, `h` steps back out. There is
//! no tree widget and no nesting beyond those two levels, which is the
//! whole reason this fits in one screen of drawing code.

const App = @This();

const std = @import("std");
const ghostty = @import("ghostty-vt");

const Config = @import("Config.zig");
const Grid = @import("Grid.zig");
const Task = @import("Task.zig");
const Term = @import("Term.zig");
const c = @import("c.zig");
const discover = @import("discover.zig");
const input = @import("input.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.app);

/// Frame budget. Output arriving faster than this coalesces into one repaint
/// instead of one per read, which is what keeps a noisy task from turning
/// into a busy loop.
const frame_ms: i64 = 16;

/// How long everything gets to shut down cleanly when quitting.
const quit_grace_ms: i64 = 6000;

const panel_min: u16 = 18;
const panel_max: u16 = 44;

const Level = enum { configs, tasks };

/// One discovered config, plus whatever we know about it.
pub const Entry = struct {
    /// Directory relative to the scan root; "." for the root itself.
    display: []const u8,
    path: []const u8,
    config: ?Config = null,
    tasks: []*Task = &.{},
    /// Selection and scroll position *within* this config, remembered so
    /// stepping out and back in lands where you left.
    sel: usize = 0,
    top: usize = 0,
    /// Why this config could not be loaded, if it could not be.
    err: []const u8 = "",

    fn running(self: *const Entry) usize {
        var n: usize = 0;
        for (self.tasks) |t| {
            if (t.state != .stopped) n += 1;
        }
        return n;
    }

    /// A task in here rang the bell and has not been looked at since.
    fn anyBell(self: *const Entry) bool {
        for (self.tasks) |t| {
            if (t.bell) return true;
        }
        return false;
    }

    fn anyFailed(self: *const Entry) bool {
        for (self.tasks) |t| {
            if (t.failed()) return true;
        }
        return false;
    }
};

gpa: Allocator,
io: std.Io,
term: Term,
grid: Grid = .{},

root: []const u8,
found: []discover.Found,
entries: []Entry,

level: Level = .configs,
sel: usize = 0,
top: usize = 0,

/// True while keystrokes belong to the focused task rather than to corral.
focused: bool = false,
zoomed: bool = false,
quitting: bool = false,

/// Set when something on screen changed. Cleared by `paint`.
needs_paint: bool = true,
last_paint_ms: i64 = 0,

/// Bytes of an escape sequence that arrived split across reads.
pending: [64]u8 = undefined,
pending_len: usize = 0,
/// A config to open directly, applied once the configs have been parsed.
pending_enter: ?[]const u8 = null,

// Layout, recomputed on resize.
panel_w: u16 = panel_min,
out_x: u16 = 0,
out_w: u16 = 1,
out_h: u16 = 1,

// --- setup ---------------------------------------------------------------

pub fn init(
    gpa: Allocator,
    io: std.Io,
    root: []const u8,
    found: []discover.Found,
) !App {
    const entries = try gpa.alloc(Entry, found.len);
    errdefer gpa.free(entries);

    for (entries, found) |*entry, f| {
        entry.* = .{
            .display = displayDir(f.display),
            .path = f.path,
        };
    }

    return .{
        .gpa = gpa,
        .io = io,
        .term = try .init(),
        .root = root,
        .found = found,
        .entries = entries,
    };
}

/// `services/api/corral.json` reads better as `services/api`, and the config
/// in the directory corral was launched from reads better as `.`.
fn displayDir(config_path: []const u8) []const u8 {
    return std.fs.path.dirname(config_path) orelse ".";
}

pub fn deinit(self: *App) void {
    for (self.entries) |*entry| {
        for (entry.tasks) |t| t.destroy();
        self.gpa.free(entry.tasks);
        if (entry.config) |*cfg| cfg.deinit();
        if (entry.err.len > 0) self.gpa.free(entry.err);
    }
    self.gpa.free(self.entries);
    self.grid.deinit(self.gpa);
    self.term.deinit();
}

/// Parse every config up front. Nothing is *started* — that is always an
/// explicit `s` — but knowing each config's tasks means the list can show
/// real counts, and a broken config announces itself immediately rather
/// than when you finally step into it.
fn loadAll(self: *App) !void {
    for (self.entries) |*entry| {
        var diag: Config.Diag = .{};
        var cfg = Config.load(self.gpa, self.io, entry.path, &diag) catch {
            entry.err = try self.gpa.dupe(u8, diag.msg);
            continue;
        };
        errdefer cfg.deinit();

        const tasks = try self.gpa.alloc(*Task, cfg.tasks.len);
        errdefer self.gpa.free(tasks);

        var made: usize = 0;
        errdefer for (tasks[0..made]) |t| t.destroy();
        for (cfg.tasks, 0..) |*task_cfg, i| {
            tasks[i] = try .create(self.gpa, self.io, task_cfg, self.out_w, self.out_h);
            made += 1;
        }

        entry.config = cfg;
        entry.tasks = tasks;
    }
}

/// Ask to open straight inside one config, as `-c` and a directory with a
/// single config both want.
///
/// This only records the request: which configs have tasks is not known
/// until `run` has parsed them, and stepping into an empty list would land
/// on a pane promising task keys that do nothing.
pub fn enterOnStart(self: *App, path: []const u8) void {
    self.pending_enter = path;
}

fn applyPendingEnter(self: *App) void {
    const path = self.pending_enter orelse return;
    self.pending_enter = null;

    for (self.entries, 0..) |entry, i| {
        if (!std.mem.eql(u8, entry.path, path)) continue;
        self.sel = i;
        // A config that failed to load has nothing to step into. Staying on
        // the list keeps its error on screen.
        if (entry.tasks.len > 0) self.level = .tasks;
        self.scrollListIntoView();
        return;
    }
}

// --- accessors -----------------------------------------------------------

fn current(self: *App) ?*Entry {
    if (self.sel >= self.entries.len) return null;
    return &self.entries[self.sel];
}

fn currentTask(self: *App) ?*Task {
    const e = self.current() orelse return null;
    if (e.sel >= e.tasks.len) return null;
    return e.tasks[e.sel];
}

/// How many rows the list occupies, and how many of them are tasks.
fn listRows(self: *App) u16 {
    return self.term.rows -| 1;
}

fn listLen(self: *App) usize {
    return switch (self.level) {
        .configs => self.entries.len,
        // Row zero is the breadcrumb back to the config list.
        .tasks => if (self.current()) |e| e.tasks.len else 0,
    };
}

fn cursor(self: *App) *usize {
    return switch (self.level) {
        .configs => &self.sel,
        .tasks => if (self.current()) |e| &e.sel else &self.sel,
    };
}

fn scrollTop(self: *App) *usize {
    return switch (self.level) {
        .configs => &self.top,
        .tasks => if (self.current()) |e| &e.top else &self.top,
    };
}

// --- layout --------------------------------------------------------------

fn layout(self: *App) void {
    self.term.refreshSize();

    var panel: u16 = 0;
    if (!self.zoomed) {
        var widest: u16 = 0;
        for (self.entries) |e| {
            widest = @max(widest, Grid.displayWidth(e.display));
            for (e.tasks) |t| widest = @max(widest, Grid.displayWidth(t.name()));
        }
        // marker + gap + name + gap + status
        panel = std.math.clamp(widest + 12, panel_min, panel_max);
        panel = @min(panel, self.term.cols / 2);
    }

    self.panel_w = panel;
    self.out_x = if (panel == 0) 0 else panel + 1;
    self.out_w = @max(self.term.cols -| self.out_x, 1);
    self.out_h = @max(self.term.rows -| 1, 1);
}

fn onResize(self: *App) !void {
    self.layout();
    try self.grid.resize(self.gpa, self.term.cols, self.term.rows);
    for (self.entries) |e| {
        for (e.tasks) |t| t.resize(self.out_w, self.out_h);
    }
    self.grid.damaged = true;
    self.needs_paint = true;
}

// --- event loop ----------------------------------------------------------

pub fn run(self: *App) !void {
    try self.term.enter();
    defer self.term.leave();

    try self.onResize();
    try self.loadAll();
    self.applyPendingEnter();
    // Loading may have widened the panel: task names were unknown before.
    try self.onResize();

    while (!self.quitting) try self.tick();
    try self.shutdown();
}

fn tick(self: *App) !void {
    var fds: std.ArrayList(std.posix.pollfd) = .empty;
    defer fds.deinit(self.gpa);
    var sources: std.ArrayList(*Task) = .empty;
    defer sources.deinit(self.gpa);

    try fds.append(self.gpa, .{ .fd = Term.in_fd, .events = std.posix.POLL.IN, .revents = 0 });
    try fds.append(self.gpa, .{ .fd = self.term.sig_r, .events = std.posix.POLL.IN, .revents = 0 });

    for (self.entries) |e| {
        for (e.tasks) |t| {
            const pty = if (t.pty) |*p| p else continue;
            if (t.eof) continue;
            try fds.append(self.gpa, .{ .fd = pty.master, .events = std.posix.POLL.IN, .revents = 0 });
            try sources.append(self.gpa, t);
        }
    }

    const now = self.nowMs();
    _ = std.posix.poll(fds.items, self.timeout(now)) catch |err| switch (err) {
        error.SystemResources => return,
        else => return err,
    };

    if (fds.items[0].revents != 0) try self.readInput();
    if (fds.items[1].revents != 0) try self.readSignals();

    for (fds.items[2..], sources.items) |fd, t| {
        if (fd.revents == 0) continue;
        if (t.drain()) {
            // Only a repaint of what is on screen is worth scheduling; other
            // tasks just accumulate into their own emulator for free. The
            // exception is a bell, which is a background task's one way of
            // asking to be looked at.
            if (self.currentTask() == t or t.bell) self.needs_paint = true;
        }
    }

    self.enforceDeadlines();
    try self.maybePaint();
}

/// How long `poll` may sleep: until the next frame if something is waiting
/// to be drawn, else until the next task has to be killed, else forever.
fn timeout(self: *App, now: i64) i32 {
    var deadline: ?i64 = null;

    if (self.needs_paint) {
        deadline = self.last_paint_ms + frame_ms;
    }
    for (self.entries) |e| {
        for (e.tasks) |t| {
            const at = t.kill_at orelse continue;
            deadline = if (deadline) |d| @min(d, at) else at;
        }
    }

    const at = deadline orelse return -1;
    return @intCast(std.math.clamp(at - now, 0, 60_000));
}

fn enforceDeadlines(self: *App) void {
    const now = self.nowMs();
    for (self.entries) |e| {
        for (e.tasks) |t| {
            const at = t.kill_at orelse continue;
            if (now < at) continue;
            // It had its chance to stop politely.
            t.kill();
            t.kill_at = null;
        }
    }
}

fn readSignals(self: *App) !void {
    const pending = self.term.drainSignals();
    if (pending.winch) try self.onResize();
    if (pending.child) self.reapChildren();
    if (pending.quit) self.quitting = true;
}

/// Reap every child that has exited and hand the status to its task.
///
/// Reaping happens here rather than in the signal handler on purpose: a task
/// records its pid synchronously inside `start`, and the main loop cannot be
/// between those two points, so there is no window where a status arrives
/// for a pid nobody owns yet.
fn reapChildren(self: *App) void {
    while (true) {
        var status: c_int = 0;
        const pid = c.waitpid(-1, &status, c.WNOHANG);
        if (pid <= 0) break;

        const owner = self.taskForPid(pid) orelse continue;
        owner.reap(status);
        self.needs_paint = true;
    }
}

fn taskForPid(self: *App, pid: c.pid_t) ?*Task {
    for (self.entries) |e| {
        for (e.tasks) |t| {
            const pty = t.pty orelse continue;
            if (pty.pid == pid) return t;
        }
    }
    return null;
}

fn nowMs(self: *App) i64 {
    const ts = std.Io.Clock.awake.now(self.io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

// --- input ---------------------------------------------------------------

fn readInput(self: *App) !void {
    var buf: [1024]u8 = undefined;
    const n = std.c.read(Term.in_fd, &buf, buf.len);
    if (n <= 0) return;
    const data = buf[0..@intCast(n)];

    if (self.focused) {
        try self.forwardToTask(data);
        return;
    }

    // Escape sequences can straddle reads, so anything left over from last
    // time goes first.
    var joined: [1024 + 64]u8 = undefined;
    @memcpy(joined[0..self.pending_len], self.pending[0..self.pending_len]);
    const total = self.pending_len + data.len;
    @memcpy(joined[self.pending_len..total], data);
    self.pending_len = 0;

    var i: usize = 0;
    while (i < total) {
        const decoded = input.decode(joined[i..total]);
        if (decoded.len == 0) {
            // Incomplete. Hold it for the next read; if it is really a bare
            // Escape, the worst case is that it acts on the next keystroke.
            const rest = total - i;
            if (rest <= self.pending.len) {
                @memcpy(self.pending[0..rest], joined[i..total]);
                self.pending_len = rest;
            }
            return;
        }
        try self.onKey(decoded.key);
        if (self.quitting or self.focused) {
            // The rest of this read belongs to the task now.
            const rest = joined[i + decoded.len .. total];
            if (self.focused and rest.len > 0) try self.forwardToTask(rest);
            return;
        }
        i += decoded.len;
    }
}

fn forwardToTask(self: *App, data: []const u8) !void {
    // Ctrl-A is the one key corral keeps for itself while a task is focused.
    if (std.mem.indexOfScalar(u8, data, 0x01)) |at| {
        const before = data[0..at];
        if (before.len > 0) self.writeToTask(before);
        self.focused = false;
        self.needs_paint = true;
        const after = data[at + 1 ..];
        if (after.len > 0) {
            // Whatever followed is for corral, not the task.
            var i: usize = 0;
            while (i < after.len) {
                const decoded = input.decode(after[i..]);
                if (decoded.len == 0) break;
                try self.onKey(decoded.key);
                i += decoded.len;
            }
        }
        return;
    }
    self.writeToTask(data);
}

fn writeToTask(self: *App, data: []const u8) void {
    const t = self.currentTask() orelse return;
    // Typing means you want to see what you are typing.
    t.scrollToBottom();
    t.write(data);
    self.needs_paint = true;
}

fn onKey(self: *App, key: input.Key) !void {
    const now = self.nowMs();
    const page: isize = @max(@divTrunc(@as(isize, @intCast(self.out_h)), 2), 1);

    switch (key) {
        .up => self.move(-1),
        .down => self.move(1),
        .left => self.stepOut(),
        .right, .enter => self.stepIn(),
        .home => self.moveTo(0),
        .end => self.moveTo(std.math.maxInt(usize)),
        .page_up => self.scroll(page),
        .page_down => self.scroll(-page),
        .escape, .unknown => {},

        .ctrl => |ch| switch (ch) {
            'a' => self.setFocus(true),
            'u' => self.scroll(page),
            'd' => self.scroll(-page),
            'y' => self.scroll(3),
            'e' => self.scroll(-3),
            'n' => self.move(1),
            'p' => self.move(-1),
            else => {},
        },

        .char => |ch| switch (ch) {
            'j' => self.move(1),
            'k' => self.move(-1),
            'h' => self.stepOut(),
            'l' => self.stepIn(),
            'g' => self.moveViewport(.top),
            'G' => self.moveViewport(.bottom),

            's' => self.startSelected(),
            'S' => self.startAll(),
            'x' => self.stopSelected(now),
            'X' => self.killSelected(),
            'r' => self.restartSelected(now),

            'w' => try self.dumpToHost(),
            'z' => {
                self.zoomed = !self.zoomed;
                try self.onResize();
            },
            'q' => self.quitting = true,

            '1'...'9' => self.moveTo(ch - '1'),
            else => {},
        },
    }
}

fn setFocus(self: *App, on: bool) void {
    if (self.level != .tasks) return;
    if (on and self.currentTask() == null) return;
    self.focused = on;
    if (on) {
        if (self.currentTask()) |t| {
            t.scrollToBottom();
            t.bell = false;
        }
    }
    self.needs_paint = true;
}

fn stepIn(self: *App) void {
    switch (self.level) {
        .configs => {
            const e = self.current() orelse return;
            if (e.tasks.len == 0) return;
            self.level = .tasks;
            self.scrollListIntoView();
            self.noticeSelection();
            self.needs_paint = true;
        },
        // Already as deep as the list goes; the next step in is the task
        // itself, which is what focusing means.
        .tasks => self.setFocus(true),
    }
}

fn stepOut(self: *App) void {
    switch (self.level) {
        .configs => {},
        .tasks => {
            self.level = .configs;
            self.scrollListIntoView();
            self.needs_paint = true;
        },
    }
}

/// Moving onto a task is what counts as noticing it rang.
fn noticeSelection(self: *App) void {
    if (self.level != .tasks) return;
    if (self.currentTask()) |t| t.bell = false;
}

fn move(self: *App, delta: isize) void {
    const len = self.listLen();
    if (len == 0) return;
    const cur = self.cursor();
    const next = @as(isize, @intCast(cur.*)) + delta;
    cur.* = @intCast(std.math.clamp(next, 0, @as(isize, @intCast(len - 1))));
    self.scrollListIntoView();
    self.noticeSelection();
    self.needs_paint = true;
}

fn moveTo(self: *App, index: usize) void {
    const len = self.listLen();
    if (len == 0) return;
    self.cursor().* = @min(index, len - 1);
    self.scrollListIntoView();
    self.noticeSelection();
    self.needs_paint = true;
}

fn scrollListIntoView(self: *App) void {
    const rows = self.visibleListRows();
    if (rows == 0) return;
    const cur = self.cursor().*;
    const top = self.scrollTop();
    if (cur < top.*) top.* = cur;
    if (cur >= top.* + rows) top.* = cur - rows + 1;
}

/// Rows the list itself gets, after the breadcrumb takes one.
fn visibleListRows(self: *App) usize {
    const rows = self.listRows();
    return switch (self.level) {
        .configs => rows,
        .tasks => rows -| 1,
    };
}

fn scroll(self: *App, lines: isize) void {
    const t = self.currentTask() orelse return;
    t.scroll(-lines);
    self.needs_paint = true;
}

fn moveViewport(self: *App, where: enum { top, bottom }) void {
    const t = self.currentTask() orelse return;
    switch (where) {
        .top => t.scrollToTop(),
        .bottom => t.scrollToBottom(),
    }
    self.needs_paint = true;
}

// --- task commands -------------------------------------------------------

fn startSelected(self: *App) void {
    switch (self.level) {
        .tasks => if (self.currentTask()) |t| t.start(),
        // From the config list, `s` starts the config's currently selected
        // task without making you step in first.
        .configs => if (self.currentTask()) |t| t.start(),
    }
    self.needs_paint = true;
}

/// Bring up everything in the selected config. This is the "one command
/// starts my dev environment" key; `autostart: false` opts a task out.
fn startAll(self: *App) void {
    const e = self.current() orelse return;
    for (e.tasks) |t| {
        if (t.cfg.in_start_all) t.start();
    }
    self.needs_paint = true;
}

fn stopSelected(self: *App, now: i64) void {
    if (self.currentTask()) |t| t.stop(now);
    self.needs_paint = true;
}

fn killSelected(self: *App) void {
    if (self.currentTask()) |t| t.kill();
    self.needs_paint = true;
}

fn restartSelected(self: *App, now: i64) void {
    if (self.currentTask()) |t| t.restart(now);
    self.needs_paint = true;
}

// --- painting ------------------------------------------------------------

fn maybePaint(self: *App) !void {
    if (!self.needs_paint) return;
    const now = self.nowMs();
    if (now - self.last_paint_ms < frame_ms) return;
    try self.paint();
    self.last_paint_ms = now;
    self.needs_paint = false;
}

fn paint(self: *App) !void {
    self.grid.clear();

    if (self.panel_w > 0) {
        self.drawPanel();
        var y: u16 = 0;
        while (y < self.term.rows -| 1) : (y += 1) {
            self.grid.set(self.panel_w, y, .fromSlice("│", 1, dim));
        }
    }

    try self.drawOutput();
    self.drawFooter();

    const frame = try self.grid.flush(self.gpa);
    self.term.writeAll(frame);
}

const dim: Grid.Style = .{ .fg = .{ .palette = 8 } };
const green: Grid.Style = .{ .fg = .{ .palette = 2 } };
const yellow: Grid.Style = .{ .fg = .{ .palette = 3 } };
const red: Grid.Style = .{ .fg = .{ .palette = 1 } };

fn dotStyle(state: Task.State, failed: bool) Grid.Style {
    return switch (state) {
        .running => green,
        .stopping => yellow,
        .stopped => if (failed) red else dim,
    };
}

fn drawPanel(self: *App) void {
    switch (self.level) {
        .configs => self.drawConfigList(),
        .tasks => self.drawTaskList(),
    }
}

fn drawConfigList(self: *App) void {
    const rows = self.listRows();
    var y: u16 = 0;
    while (y < rows) : (y += 1) {
        const i = self.top + y;
        if (i >= self.entries.len) break;
        const e = &self.entries[i];
        const selected = i == self.sel;

        var style: Grid.Style = .{};
        if (selected) style.attrs.inverse = true;
        self.grid.fill(0, y, self.panel_w, style);

        if (e.err.len > 0) {
            var s = red;
            s.attrs.inverse = selected;
            _ = self.grid.text(1, y, "!", 1, s);
        } else {
            const running = e.running();
            var s = dotStyle(
                if (running > 0) .running else .stopped,
                e.anyFailed(),
            );
            s.attrs.inverse = selected;
            _ = self.grid.text(1, y, if (running > 0) "●" else "○", 1, s);

            if (e.anyBell()) {
                var b = yellow;
                b.attrs.inverse = selected;
                _ = self.grid.text(2, y, "!", 1, b);
            }
        }

        // Right-aligned count, laid out first so the name knows its room.
        var count_buf: [16]u8 = undefined;
        const count = if (e.err.len > 0)
            "broken"
        else if (e.tasks.len == 0)
            ""
        else
            std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ e.running(), e.tasks.len }) catch "";

        const count_w = Grid.displayWidth(count);
        const name_room = self.panel_w -| (3 + count_w + 2);
        _ = self.grid.textEllipsis(3, y, e.display, name_room, style);

        if (count_w > 0) {
            var s = if (e.err.len > 0) red else dim;
            s.attrs.inverse = selected;
            _ = self.grid.text(self.panel_w -| (count_w + 1), y, count, count_w, s);
        }
    }
}

fn drawTaskList(self: *App) void {
    const e = self.current() orelse return;
    const rows = self.listRows();
    if (rows == 0) return;

    // Breadcrumb. `h` is the way back, and saying so costs one row.
    _ = self.grid.text(1, 0, "‹", 1, dim);
    _ = self.grid.textEllipsis(3, 0, e.display, self.panel_w -| 4, dim);

    var y: u16 = 1;
    while (y < rows) : (y += 1) {
        const i = e.top + (y - 1);
        if (i >= e.tasks.len) break;
        const t = e.tasks[i];
        const selected = i == e.sel;

        var style: Grid.Style = .{};
        if (selected) style.attrs.inverse = true;
        self.grid.fill(0, y, self.panel_w, style);

        var dot = dotStyle(t.state, t.failed());
        dot.attrs.inverse = selected;
        _ = self.grid.text(1, y, if (t.state == .stopped) "○" else "●", 1, dot);

        if (t.bell) {
            var s = yellow;
            s.attrs.inverse = selected;
            _ = self.grid.text(2, y, "!", 1, s);
        }

        var status_buf: [16]u8 = undefined;
        var detail_buf: [16]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "{s}{s}", .{
            t.statusText(),
            t.statusDetail(&detail_buf),
        }) catch t.statusText();

        const status_w = Grid.displayWidth(status);
        const name_room = self.panel_w -| (3 + status_w + 2);
        _ = self.grid.textEllipsis(3, y, t.name(), name_room, style);

        var s = if (t.failed()) red else if (selected) style else dim;
        s.attrs.inverse = selected;
        _ = self.grid.text(self.panel_w -| (status_w + 1), y, status, status_w, s);
    }
}

fn drawOutput(self: *App) !void {
    const e = self.current() orelse {
        _ = self.grid.text(self.out_x + 2, 1, "no corral.json found", self.out_w -| 2, dim);
        return;
    };

    if (e.err.len > 0) {
        _ = self.grid.text(self.out_x + 2, 1, e.err, self.out_w -| 4, red);
        _ = self.grid.text(self.out_x + 2, 3, e.path, self.out_w -| 4, dim);
        return;
    }

    const t = self.currentTask() orelse {
        _ = self.grid.text(self.out_x + 2, 1, "this config defines no tasks", self.out_w -| 4, dim);
        return;
    };

    try t.render.update(self.gpa, &t.terminal);
    self.blit(t);
    t.dirty = false;
}

/// Copy a task's viewport into the grid, cell for cell.
fn blit(self: *App, t: *Task) void {
    const state = &t.render;
    const cells_list = state.row_data.items(.cells);

    var row: u16 = 0;
    while (row < self.out_h) : (row += 1) {
        if (row >= state.rows or row >= cells_list.len) break;

        const cells = cells_list[row];
        const raws = cells.items(.raw);
        const styles = cells.items(.style);
        const graphemes = cells.items(.grapheme);

        var col: u16 = 0;
        while (col < self.out_w and col < raws.len) : (col += 1) {
            const raw = raws[col];
            // The second half of a wide glyph is covered by the first.
            if (raw.wide == .spacer_tail) continue;

            const style: ghostty.Style = if (raw.style_id == 0) .{} else styles[col];
            var out: Grid.Style = .{
                .fg = convertColor(style.fg_color),
                .bg = convertColor(style.bg_color),
                .underline_color = convertColor(style.underline_color),
                .attrs = .{
                    .bold = style.flags.bold,
                    .dim = style.flags.faint,
                    .italic = style.flags.italic,
                    .blink = style.flags.blink,
                    .inverse = style.flags.inverse,
                    .invisible = style.flags.invisible,
                    .strikethrough = style.flags.strikethrough,
                    .overline = style.flags.overline,
                    .underline = switch (style.flags.underline) {
                        .none => .none,
                        .single => .single,
                        .double => .double,
                        .curly => .curly,
                        .dotted => .dotted,
                        .dashed => .dashed,
                    },
                },
            };

            var text_buf: [Grid.text_max]u8 = undefined;
            var text_len: usize = 0;
            var width: u8 = if (raw.wide == .wide) 2 else 1;

            switch (raw.content_tag) {
                .codepoint, .codepoint_grapheme => {
                    const cp = raw.content.codepoint.data;
                    text_len = encode(&text_buf, text_len, if (cp == 0) ' ' else cp);
                    if (raw.content_tag == .codepoint_grapheme) {
                        for (graphemes[col]) |extra| {
                            text_len = encode(&text_buf, text_len, extra);
                        }
                    }
                },
                // A cell with no text but a background, which is how a run
                // of coloured blanks is stored.
                .bg_color_palette => {
                    out.bg = .{ .palette = raw.content.color_palette.data };
                    text_buf[0] = ' ';
                    text_len = 1;
                    width = 1;
                },
                .bg_color_rgb => {
                    const rgb = raw.content.color_rgb;
                    out.bg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } };
                    text_buf[0] = ' ';
                    text_len = 1;
                    width = 1;
                },
            }

            self.grid.set(self.out_x + col, row, .fromSlice(text_buf[0..text_len], width, out));
            if (width == 2) {
                self.grid.set(self.out_x + col + 1, row, .{ .width = 0, .style = out });
            }
        }
    }

    // The cursor is only meaningful while the task has the keyboard.
    self.grid.cursor = null;
    if (self.focused and state.cursor.visible) {
        if (state.cursor.viewport) |pos| {
            if (pos.x < self.out_w and pos.y < self.out_h) {
                self.grid.cursor = .{ .x = self.out_x + pos.x, .y = pos.y };
            }
        }
    }
}

fn encode(buf: []u8, at: usize, cp: u21) usize {
    const len = std.unicode.utf8CodepointSequenceLength(cp) catch return at;
    if (at + len > buf.len) return at;
    _ = std.unicode.utf8Encode(cp, buf[at..]) catch return at;
    return at + len;
}

fn convertColor(color: ghostty.Style.Color) Grid.Color {
    return switch (color) {
        .none => .default,
        .palette => |idx| .{ .palette = idx },
        .rgb => |v| .{ .rgb = .{ .r = v.r, .g = v.g, .b = v.b } },
    };
}

fn drawFooter(self: *App) void {
    const y = self.term.rows -| 1;
    self.grid.fill(0, y, self.term.cols, .{});

    const hint = if (self.focused)
        " ^a back to the list — every other key goes to the task"
    else switch (self.level) {
        .configs => " j/k move  l enter  s start  S start all  q quit",
        .tasks => " j/k move  h back  l focus  s/x/r start stop restart  S all  w dump  z zoom  q quit",
    };
    _ = self.grid.text(0, y, hint, self.term.cols, dim);

    // Scroll position, when it is not simply "following the output".
    const t = self.currentTask() orelse return;
    if (t.atBottom()) return;
    var buf: [24]u8 = undefined;
    const badge = std.fmt.bufPrint(&buf, "↑{d} ", .{t.scrollbackOffset()}) catch return;
    const w = Grid.displayWidth(badge);
    _ = self.grid.text(self.term.cols -| w, y, badge, w, .{});
}

// --- dump ----------------------------------------------------------------

/// Hand the task's scrollback back to the host terminal, so its own
/// selection, search and scrollback apply to it.
///
/// This emits the *screen contents* rather than replaying the raw bytes the
/// task produced. Replaying raw output would drag along every cursor move
/// and screen clear in it, which scribbles over whatever else is in the
/// host's scrollback.
fn dumpToHost(self: *App) !void {
    const t = self.currentTask() orelse return;

    self.term.leave();
    defer {
        self.term.enter() catch {};
        self.grid.damaged = true;
        self.needs_paint = true;
        self.last_paint_ms = 0;
    }

    var buf: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(self.io, &buf);
    const w = &writer.interface;

    w.print("\n\x1b[1m── {s} ──\x1b[0m\n", .{t.name()}) catch {};
    w.print("{f}", .{t.formatScrollback()}) catch {};
    w.writeAll("\n\x1b[2m── press enter to return to corral ──\x1b[0m\n") catch {};
    w.flush() catch {};

    // Read until Enter. The terminal is out of raw mode, so this is the
    // host's own line editing doing the waiting.
    var line: [64]u8 = undefined;
    while (true) {
        const n = std.c.read(Term.in_fd, &line, line.len);
        if (n <= 0) break;
        if (std.mem.indexOfAny(u8, line[0..@intCast(n)], "\r\n") != null) break;
    }
}

// --- shutdown ------------------------------------------------------------

/// Stop everything corral started. Tasks live in their own sessions, so
/// leaving without this would leave them running with no way back to them.
fn shutdown(self: *App) !void {
    const now = self.nowMs();
    for (self.entries) |e| {
        for (e.tasks) |t| {
            t.restart_pending = false;
            t.stop(now);
        }
    }

    const deadline = now + quit_grace_ms;
    while (self.nowMs() < deadline and self.anyAlive()) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.term.sig_r, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, 50) catch break;
        _ = self.term.drainSignals();
        self.reapChildren();
        self.enforceDeadlines();
    }

    for (self.entries) |e| {
        for (e.tasks) |t| t.kill();
    }
    // One last sweep so we do not leave zombies behind for init to adopt.
    self.reapChildren();
}

fn anyAlive(self: *App) bool {
    for (self.entries) |e| {
        for (e.tasks) |t| {
            if (t.state != .stopped) return true;
        }
    }
    return false;
}

test {
    std.testing.refAllDecls(@This());
}
