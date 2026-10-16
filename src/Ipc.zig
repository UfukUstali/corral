//! Directory-scoped Unix socket, owned by the human's TUI. Partial requests
//! and slow readers never block the task/terminal event loop.
const std = @import("std");
const c = @import("c.zig");
const Agent = @import("Agent.zig");
const Allocator = std.mem.Allocator;
const max_request = 64 * 1024;
const max_response = 64 * 1024 * 1024;
const timeout_ms = 5000;
const max_clients = 16;

pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

fn socketPath(gpa: Allocator, root: []const u8) ![:0]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &hash, .{});
    return std.fmt.allocPrintSentinel(gpa, "/tmp/corral-{d}/{s}.sock", .{ std.c.getuid(), std.fmt.bytesToHex(hash, .lower) }, 0);
}

fn checkDirectory(gpa: Allocator, path: []const u8, create: bool) !void {
    const dir = try gpa.dupeZ(u8, std.fs.path.dirname(path).?);
    defer gpa.free(dir);
    if (create and std.c.mkdir(dir, 0o700) != 0 and std.posix.errno(-1) != .EXIST)
        return error.InstanceDirectoryFailed;
    const flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
    const fd = c.open(dir, @as(c_int, @bitCast(flags)));
    if (fd < 0) {
        if (std.posix.errno(fd) == .NOENT) return error.InstanceNotRunning;
        return error.InstanceDirectoryFailed;
    }
    defer _ = c.close(fd);
    if (@import("builtin").os.tag == .linux) {
        var stat: std.os.linux.Statx = undefined;
        if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &stat) != 0 or
            !stat.mask.UID or !stat.mask.MODE or stat.uid != std.c.getuid() or stat.mode & 0o077 != 0)
            return error.InstanceDirectoryNotPrivate;
    } else {
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0 or stat.uid != std.c.getuid() or stat.mode & 0o077 != 0)
            return error.InstanceDirectoryNotPrivate;
    }
}

fn address(path: []const u8) !std.c.sockaddr.un {
    var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn nonBlocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0 or c.fcntl(fd, std.c.F.SETFL, flags | c.O_NONBLOCK) < 0) return error.SocketSetup;
}

fn newSocket() !c.fd_t {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    try configure(fd);
    return fd;
}

fn configure(fd: c.fd_t) !void {
    if (c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.SocketSetup;
    try nonBlocking(fd);
}

const Client = struct {
    fd: c.fd_t = -1,
    request: std.ArrayList(u8) = .empty,
    response: ?[]u8 = null,
    sent: usize = 0,
    deadline: i64 = 0,

    fn close(self: *Client, gpa: Allocator) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.request.deinit(gpa);
        if (self.response) |bytes| gpa.free(bytes);
        self.* = .{};
    }
};

pub const Server = struct {
    gpa: Allocator,
    fd: c.fd_t,
    lock: c.fd_t,
    path: [:0]u8,
    clients: [max_clients]Client = @splat(.{}),

    pub fn init(gpa: Allocator, root: []const u8) !Server {
        const path = try socketPath(gpa, root);
        errdefer gpa.free(path);
        try checkDirectory(gpa, path, true);
        const lock_path = try std.fmt.allocPrintSentinel(gpa, "{s}.lock", .{path}, 0);
        defer gpa.free(lock_path);
        const flags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true };
        const lock = c.open(lock_path, @as(c_int, @bitCast(flags)), @as(std.c.mode_t, 0o600));
        if (lock < 0) return error.InstanceLockFailed;
        errdefer _ = c.close(lock);
        if (std.c.flock(lock, std.c.LOCK.EX | std.c.LOCK.NB) != 0) return error.InstanceAlreadyRunning;

        const fd = try newSocket();
        errdefer _ = c.close(fd);
        // Holding the lock makes stale socket removal safe even when two
        // humans launch simultaneously. The lock file itself is never removed.
        _ = std.c.unlink(path);
        var addr = try address(path);
        const mask = std.c.umask(0o177);
        const result = std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        _ = std.c.umask(mask);
        if (result != 0) return error.SocketBindFailed;
        errdefer _ = std.c.unlink(path);
        if (std.c.listen(fd, max_clients) != 0) return error.SocketListenFailed;
        return .{ .gpa = gpa, .fd = fd, .lock = lock, .path = path };
    }

    pub fn deinit(self: *Server) void {
        for (&self.clients) |*client| client.close(self.gpa);
        _ = c.close(self.fd);
        _ = std.c.unlink(self.path);
        _ = c.close(self.lock);
        self.gpa.free(self.path);
    }

    pub fn appendPoll(self: *Server, fds: *std.ArrayList(std.posix.pollfd)) !void {
        try fds.append(self.gpa, .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 });
        for (self.clients) |client| {
            try fds.append(self.gpa, .{
                .fd = client.fd,
                .events = if (client.response != null) std.posix.POLL.OUT else std.posix.POLL.IN,
                .revents = 0,
            });
        }
    }

    pub fn active(self: *const Server) bool {
        for (self.clients) |client| if (client.fd >= 0) return true;
        return false;
    }

    pub fn service(self: *Server, fds: []const std.posix.pollfd, context: anytype, now: i64) !void {
        for (&self.clients, fds[1..]) |*client, fd| {
            if (client.fd < 0) continue;
            if (now >= client.deadline) {
                client.close(self.gpa);
                continue;
            }
            if (fd.revents == 0) continue;
            if (client.response) |response| {
                const bytes = response[client.sent..@min(response.len, client.sent + 64 * 1024)];
                const n = std.c.send(client.fd, bytes.ptr, bytes.len, std.c.MSG.NOSIGNAL);
                if (n > 0) {
                    client.sent += @intCast(n);
                    if (client.sent == response.len) client.close(self.gpa);
                } else if (n == 0 or (std.posix.errno(n) != .AGAIN and std.posix.errno(n) != .INTR)) client.close(self.gpa);
            } else {
                var buf: [4096]u8 = undefined;
                const n = std.c.read(client.fd, &buf, buf.len);
                if (n > 0) {
                    if (client.request.items.len + @as(usize, @intCast(n)) > max_request) {
                        client.close(self.gpa);
                        continue;
                    }
                    try client.request.appendSlice(self.gpa, buf[0..@intCast(n)]);
                    if (std.mem.indexOfScalar(u8, client.request.items, '\n')) |end| {
                        client.response = context.agentResponse(client.request.items[0..end]) catch
                            try Agent.failure(self.gpa, "internal_error", "Could not process the request.");
                    }
                } else if (n == 0 or (std.posix.errno(n) != .AGAIN and std.posix.errno(n) != .INTR)) client.close(self.gpa);
            }
        }
        if (fds[0].revents == 0) return;
        for (0..max_clients) |_| {
            const fd = std.c.accept(self.fd, null, null);
            if (fd < 0) break;
            configure(fd) catch {
                _ = c.close(fd);
                continue;
            };
            var saved = false;
            for (&self.clients) |*client| {
                if (client.fd >= 0) continue;
                client.* = .{ .fd = fd, .deadline = now + timeout_ms };
                saved = true;
                break;
            }
            if (!saved) _ = c.close(fd);
        }
    }
};

fn waitReady(fd: c.fd_t, events: i16, io: std.Io, deadline: i64) !void {
    while (true) {
        const remaining = deadline - nowMs(io);
        if (remaining <= 0) return error.InstanceTimeout;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const n = try std.posix.poll(&fds, @intCast(remaining));
        if (n > 0) return;
    }
}

pub fn call(gpa: Allocator, io: std.Io, root: []const u8, req: Agent.Request) ![]u8 {
    const path = try socketPath(gpa, root);
    defer gpa.free(path);
    try checkDirectory(gpa, path, false);
    var addr = try address(path);
    const fd = try newSocket();
    defer _ = c.close(fd);
    const deadline = nowMs(io) + timeout_ms;
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
        switch (std.posix.errno(-1)) {
            .NOENT, .CONNREFUSED => return error.InstanceNotRunning,
            .INPROGRESS, .AGAIN => {
                try waitReady(fd, std.posix.POLL.OUT, io, deadline);
                var code: c_int = 0;
                var len: std.c.socklen_t = @sizeOf(c_int);
                if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, @ptrCast(&code), &len) != 0 or code != 0)
                    return error.InstanceNotRunning;
            },
            else => return error.InstanceConnectFailed,
        }
    }
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try std.json.Stringify.value(req, .{}, &w.writer);
    try w.writer.writeByte('\n');
    const request = w.written();
    if (request.len > max_request) return error.RequestTooLarge;
    var sent: usize = 0;
    while (sent < request.len) {
        try waitReady(fd, std.posix.POLL.OUT, io, deadline);
        const n = std.c.send(fd, request[sent..].ptr, request.len - sent, std.c.MSG.NOSIGNAL);
        if (n > 0) sent += @intCast(n) else switch (std.posix.errno(n)) {
            .AGAIN, .INTR => continue,
            else => return error.InstanceDisconnected,
        }
    }
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        try waitReady(fd, std.posix.POLL.IN, io, deadline);
        const n = std.c.read(fd, &buf, buf.len);
        if (n == 0) break;
        if (n < 0) switch (std.posix.errno(n)) {
            .AGAIN, .INTR => continue,
            else => return error.InstanceDisconnected,
        };
        if (result.items.len + @as(usize, @intCast(n)) > max_response) return error.ResponseTooLarge;
        try result.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    if (result.items.len == 0) return error.InstanceDisconnected;
    return result.toOwnedSlice(gpa);
}

test "socket identity is deterministic and directory specific" {
    const a = std.testing.allocator;
    const one = try socketPath(a, "/work/one");
    defer a.free(one);
    const again = try socketPath(a, "/work/one");
    defer a.free(again);
    const two = try socketPath(a, "/work/two");
    defer a.free(two);
    try std.testing.expectEqualStrings(one, again);
    try std.testing.expect(!std.mem.eql(u8, one, two));
    _ = try address(one);
}
