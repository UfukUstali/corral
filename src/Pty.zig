//! One pseudoterminal plus the child running on it.
//!
//! A `Pty` is created per *run* of a task, not per task: restarting a task
//! throws the old pty away and opens a fresh one. That keeps the lifecycle
//! trivial (no half-closed state to reason about) while the task's terminal
//! emulator — and therefore its scrollback — survives across restarts.

const Pty = @This();

const std = @import("std");
const c = @import("c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.pty);

/// The controlling side. Non-blocking; owned by us.
master: c.fd_t,

/// The child's process id, which is also its process *group* id: the child
/// calls `setsid`, so signalling `-pid` reaches the whole tree rather than
/// just the wrapping `sh`.
pid: c.pid_t,

pub const Error = error{
    OpenPtyFailed,
    ForkFailed,
} || Allocator.Error;

pub const Options = struct {
    /// The command handed to `sh -c`.
    shell: []const u8,
    cwd: []const u8,
    /// Extra environment on top of the inherited one. Both halves must be
    /// NUL-terminated because they are handed straight to `execve`.
    env: []const [2][:0]const u8,
    rows: u16,
    cols: u16,
};

/// Open a pty and fork a shell onto it.
///
/// Everything the child needs is prepared *before* the fork: after `fork`
/// returns in the child, only async-signal-safe calls are legal, which rules
/// out the allocator. That is why `argv`/`envp` are built up here.
pub fn spawn(gpa: Allocator, opts: Options) Error!Pty {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shell_z = try arena.dupeZ(u8, opts.shell);
    const cwd_z = try arena.dupeZ(u8, opts.cwd);

    const argv_buf = try arena.allocSentinel(?[*:0]const u8, 3, null);
    argv_buf[0] = "sh";
    argv_buf[1] = "-c";
    argv_buf[2] = shell_z.ptr;
    const argv: [*:null]const ?[*:0]const u8 = argv_buf.ptr;

    const envp = try buildEnv(arena, opts.env);

    // Master side.
    const master = c.posix_openpt(c.O_RDWR | c.O_NOCTTY);
    if (master < 0) return error.OpenPtyFailed;
    errdefer _ = c.close(master);
    if (c.grantpt(master) != 0) return error.OpenPtyFailed;
    if (c.unlockpt(master) != 0) return error.OpenPtyFailed;

    var name_buf: [256]u8 = undefined;
    const name = c.ptsName(master, &name_buf) catch return error.OpenPtyFailed;

    // Size the pty before the child starts, so it never observes a bogus
    // 0x0 or 80x24 window and reflows on the first frame.
    setSize(master, opts.rows, opts.cols);

    // Slave side. The parent closes its copy right after the fork so that
    // reads on the master report EOF once the last user of the pty is gone.
    const slave = c.open(name.ptr, c.O_RDWR | c.O_NOCTTY);
    if (slave < 0) return error.OpenPtyFailed;
    errdefer _ = c.close(slave);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // --- child ---------------------------------------------------
        // No allocation, no logging, no error returns: just syscalls, and
        // `_exit` if any of them fail. Exit code 127 mirrors what a shell
        // reports for "could not run the command".
        if (c.setsid() < 0) c._exit(127);
        // Claim the pty as our controlling terminal. Without this, writing
        // 0x03 to the master is just a byte: no session means no line
        // discipline signal generation, so `stop: {"send-keys": ["<C-c>"]}`
        // would silently do nothing.
        if (c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0)) < 0) c._exit(127);

        if (c.chdir(cwd_z.ptr) != 0) c._exit(127);

        _ = c.dup2(slave, 0);
        _ = c.dup2(slave, 1);
        _ = c.dup2(slave, 2);
        if (slave > 2) _ = c.close(slave);
        _ = c.close(master);

        _ = c.execve("/bin/sh", argv, envp);
        c._exit(127);
    }

    // --- parent ---------------------------------------------------------
    _ = c.close(slave);
    setNonBlocking(master);

    return .{ .master = master, .pid = pid };
}

/// Inherited environment, with the task's overrides applied last.
fn buildEnv(
    arena: Allocator,
    extra: []const [2][:0]const u8,
) Allocator.Error![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;

    var i: usize = 0;
    while (c.environ[i]) |entry| : (i += 1) {
        const slice = std.mem.sliceTo(entry, 0);
        const name = slice[0 .. std.mem.indexOfScalar(u8, slice, '=') orelse slice.len];
        // Drop anything we are about to override, so the child does not see
        // the same variable twice (the first wins in most libcs, which would
        // silently ignore the task's value).
        if (std.mem.eql(u8, name, "TERM")) continue;
        for (extra) |pair| {
            if (std.mem.eql(u8, name, pair[0])) break;
        } else {
            try list.append(arena, entry);
        }
    }

    // Ghostty's emulator is a superset of xterm-256color, and that terminfo
    // entry exists everywhere. Claiming `xterm-ghostty` would be more
    // accurate but breaks on any machine without ghostty's terminfo.
    try list.append(arena, "TERM=xterm-256color");
    for (extra) |pair| {
        const joined = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ pair[0], pair[1] }, 0);
        try list.append(arena, joined.ptr);
    }
    try list.append(arena, null);

    return @ptrCast(list.items.ptr);
}

pub fn close(self: *Pty) void {
    _ = c.close(self.master);
    self.master = -1;
}

/// Read whatever is available. Returns null when the pty has no more data
/// *right now*; returns 0 when the far side is gone for good.
pub fn read(self: *Pty, buf: []u8) ?usize {
    const n = std.c.read(self.master, buf.ptr, buf.len);
    if (n > 0) return @intCast(n);
    if (n == 0) return 0;
    return switch (std.posix.errno(n)) {
        .AGAIN, .INTR => null,
        // EIO on a pty master means the last slave fd was closed. That is
        // the normal end-of-life for a pty, not an error worth reporting.
        else => 0,
    };
}

/// Best-effort write. Short writes are retried; a full pty buffer drops the
/// remainder rather than blocking the whole UI on one wedged task.
pub fn write(self: *Pty, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(self.master, data[off..].ptr, data.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return,
            else => return,
        }
    }
}

pub fn resize(self: *Pty, rows: u16, cols: u16) void {
    setSize(self.master, rows, cols);
}

/// Signal the child's entire process group.
///
/// `sh -c "npm run dev"` spawns children of its own; signalling only `sh`
/// would leave them orphaned and still holding the port.
pub fn signalGroup(self: *Pty, sig: c_int) void {
    if (c.kill(-self.pid, sig) == 0) return;
    // Never became a group leader, or the group is already gone.
    _ = c.kill(self.pid, sig);
}

fn setSize(fd: c.fd_t, rows: u16, cols: u16) void {
    var ws: c.winsize = .{
        .ws_row = @max(rows, 1),
        .ws_col = @max(cols, 1),
    };
    _ = c.ioctl(fd, c.TIOCSWINSZ, &ws);
}

fn setNonBlocking(fd: c.fd_t) void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return;
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

test {
    std.testing.refAllDecls(@This());
}
