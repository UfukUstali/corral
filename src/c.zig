//! The libc surface corral needs that `std.posix` no longer exposes.
//!
//! Zig 0.16 moved most process and terminal plumbing behind `std.Io`, which
//! has no notion of a pty. Declaring the handful of functions we need
//! ourselves is both smaller than working around that and stable against
//! further std churn.

const std = @import("std");

pub const fd_t = std.c.fd_t;
pub const pid_t = std.c.pid_t;

// --- process -------------------------------------------------------------

pub extern "c" fn fork() pid_t;
pub extern "c" fn setsid() pid_t;
pub extern "c" fn dup2(old: fd_t, new: fd_t) c_int;
pub extern "c" fn close(fd: fd_t) c_int;
pub extern "c" fn pipe(fds: *[2]fd_t) c_int;
pub extern "c" fn _exit(status: c_int) noreturn;
pub extern "c" fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
pub extern "c" var environ: [*:null]?[*:0]const u8;
pub extern "c" fn waitpid(pid: pid_t, status: ?*c_int, options: c_int) pid_t;
pub extern "c" fn kill(pid: pid_t, sig: c_int) c_int;
pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern "c" fn chdir(path: [*:0]const u8) c_int;
pub extern "c" fn fcntl(fd: fd_t, cmd: c_int, ...) c_int;

pub const WNOHANG = 1;

pub const F_GETFL = 3;
pub const F_SETFL = 4;
pub const O_NONBLOCK = switch (@import("builtin").target.os.tag) {
    .linux => 0o4000,
    else => 0x0004, // Darwin and the BSDs
};

/// `waitpid` status decoding. These are macros in C, so they have to be
/// reimplemented rather than linked.
pub fn exitedNormally(status: c_int) bool {
    return status & 0x7f == 0;
}

pub fn exitStatus(status: c_int) u8 {
    return @truncate(@as(c_uint, @bitCast(status)) >> 8);
}

pub fn termSignal(status: c_int) ?c_int {
    const sig = status & 0x7f;
    // 0 means exited, 0x7f means stopped rather than terminated.
    return if (sig == 0 or sig == 0x7f) null else sig;
}

// --- pty -----------------------------------------------------------------

pub extern "c" fn posix_openpt(flags: c_int) fd_t;
pub extern "c" fn grantpt(fd: fd_t) c_int;
pub extern "c" fn unlockpt(fd: fd_t) c_int;
pub extern "c" fn ptsname_r(fd: fd_t, buf: [*]u8, buflen: usize) c_int;
pub extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) fd_t;
pub extern "c" fn ioctl(fd: fd_t, request: c_ulong, ...) c_int;

pub const O_RDWR = 0o2;
pub const O_NOCTTY = switch (@import("builtin").target.os.tag) {
    .linux => 0o400,
    else => 0x20000,
};

pub const TIOCSCTTY: c_ulong = switch (@import("builtin").target.os.tag) {
    .linux => 0x540E,
    else => 0x20007461,
};

pub const TIOCGWINSZ: c_ulong = switch (@import("builtin").target.os.tag) {
    .linux => 0x5413,
    else => 0x40087468,
};

pub const TIOCSWINSZ: c_ulong = switch (@import("builtin").target.os.tag) {
    .linux => 0x5414,
    else => 0x80087467,
};

pub const winsize = extern struct {
    ws_row: c_ushort,
    ws_col: c_ushort,
    ws_xpixel: c_ushort = 0,
    ws_ypixel: c_ushort = 0,
};

// `ptsname_r` is a glibc extension. macOS has no reentrant variant, so fall
// back to the non-reentrant one there; corral only calls it from the single
// thread that spawns tasks, so the shared buffer is not a hazard.
pub extern "c" fn ptsname(fd: fd_t) ?[*:0]u8;

pub fn ptsName(fd: fd_t, buf: []u8) ![:0]const u8 {
    switch (@import("builtin").target.os.tag) {
        .linux => {
            if (ptsname_r(fd, buf.ptr, buf.len) != 0) return error.PtsName;
            const name = std.mem.sliceTo(buf, 0);
            return buf[0..name.len :0];
        },
        else => {
            const name = ptsname(fd) orelse return error.PtsName;
            const slice = std.mem.sliceTo(name, 0);
            if (slice.len + 1 > buf.len) return error.PtsName;
            @memcpy(buf[0..slice.len], slice);
            buf[slice.len] = 0;
            return buf[0..slice.len :0];
        },
    }
}
