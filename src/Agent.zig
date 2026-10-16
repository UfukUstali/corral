//! One-shot JSON commands. All task access stays on the TUI's event loop.
const std = @import("std");
const Task = @import("Task.zig");
const Allocator = std.mem.Allocator;

pub const usage =
    \\Usage: corral agent <command> [options]
    \\
    \\  list [--name <substring>] [--status <status>] [--state <state>]
    \\       [--config <directory-or-config-path>]
    \\  show|start|stop|restart|logs <id-or-exact-name> [--config <path>]
    \\  logs also accepts --lines <1..10000> (default 100)
    \\
    \\Connects to the human's TUI started in this exact working directory.
    \\Prints one JSON response. Never starts a Corral instance.
    \\States: stopped, running, stopping.
    \\Statuses: idle, running, stopping, stopped, done, exit, killed, failed.
    \\Filters are combined. Names are case-sensitive. Ambiguous names fail.
    \\Stop/restart acknowledge the request; query again for completion.
    \\
;

pub const Command = enum { list, show, start, stop, restart, logs };
pub const Request = struct {
    command: Command,
    target: ?[]const u8 = null,
    name: ?[]const u8 = null,
    status: ?[]const u8 = null,
    state: ?Task.State = null,
    config: ?[]const u8 = null,
    lines: usize = 100,
};

pub fn parse(args: []const []const u8) !Request {
    if (args.len == 0) return error.CommandRequired;
    var req: Request = .{ .command = std.meta.stringToEnum(Command, args[0]) orelse return error.UnknownCommand };
    var i: usize = 1;
    var lines_set = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--")) {
            i += 1;
            if (i == args.len) return error.OptionNeedsValue;
            const value = args[i];
            if (std.mem.eql(u8, arg, "--name")) {
                if (req.name != null) return error.DuplicateOption;
                req.name = value;
            } else if (std.mem.eql(u8, arg, "--status")) {
                if (req.status != null) return error.DuplicateOption;
                req.status = value;
            } else if (std.mem.eql(u8, arg, "--state")) {
                if (req.state != null) return error.DuplicateOption;
                req.state = std.meta.stringToEnum(Task.State, value) orelse return error.InvalidState;
            } else if (std.mem.eql(u8, arg, "--config")) {
                if (req.config != null) return error.DuplicateOption;
                req.config = value;
            } else if (std.mem.eql(u8, arg, "--lines")) {
                if (lines_set) return error.DuplicateOption;
                lines_set = true;
                req.lines = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLines;
            } else return error.UnknownOption;
        } else {
            if (req.target != null) return error.UnexpectedArgument;
            req.target = arg;
        }
    }
    if (lines_set and req.command != .logs) return error.UnexpectedOption;
    try validate(req);
    return req;
}

fn validate(req: Request) !void {
    if (req.lines == 0 or req.lines > 10000) return error.InvalidLines;
    if (req.status) |s| {
        const statuses = [_][]const u8{ "idle", "running", "stopping", "stopped", "done", "exit", "killed", "failed" };
        var valid = false;
        for (statuses) |status| {
            if (std.mem.eql(u8, s, status)) valid = true;
        }
        if (!valid) return error.InvalidStatus;
    }
    if (req.command == .list) {
        if (req.target != null) return error.UnexpectedArgument;
    } else {
        if (req.target == null) return error.TaskRequired;
        if (req.name != null or req.status != null or req.state != null) return error.UnexpectedOption;
    }
}

pub fn failure(gpa: Allocator, code: []const u8, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .@"error" = .{ .code = code, .message = message } }, .{});
}

pub const TaskInfo = struct {
    id: []const u8,
    name: []const u8,
    config: []const u8,
    cwd: []const u8,
    shell: []const u8,
    state: Task.State,
    status: []const u8,
    pid: ?c_int,
    exit_code: ?u8,
    signal: ?c_int,
    restart_pending: bool,
};

// Two JSON pointer tokens make names and config paths unambiguous, even
// when either contains slashes or separators used by other task runners.
fn taskId(gpa: Allocator, path: []const u8, name: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    for ([_][]const u8{ path, name }) |part| {
        try w.writer.writeByte('/');
        for (part) |ch| switch (ch) {
            '~' => try w.writer.writeAll("~0"),
            '/' => try w.writer.writeAll("~1"),
            else => try w.writer.writeByte(ch),
        };
    }
    return w.toOwnedSlice();
}

fn info(gpa: Allocator, entry: anytype, task: *Task) !TaskInfo {
    return .{
        .id = try taskId(gpa, entry.path, task.name()),
        .name = task.name(),
        .config = entry.path,
        .cwd = task.cfg.cwd,
        .shell = task.cfg.shell,
        .state = task.state,
        .status = task.statusText(),
        .pid = if (task.pty) |p| p.pid else null,
        .exit_code = if (task.exit == .code) task.exit.code else null,
        .signal = if (task.exit == .signal) task.exit.signal else null,
        .restart_pending = task.restart_pending,
    };
}

fn configMatches(gpa: Allocator, root: []const u8, entry: anytype, filter: ?[]const u8) !bool {
    const path = filter orelse return true;
    const abs = try std.fs.path.resolve(gpa, &.{ root, path });
    return std.mem.eql(u8, abs, entry.path) or
        std.mem.eql(u8, abs, std.fs.path.dirname(entry.path) orelse "/");
}

/// `entries` are borrowed for this call; allocations other than the response
/// belong to a short-lived arena, including parsed request strings.
pub fn respond(gpa: Allocator, root: []const u8, entries: anytype, bytes: []const u8, now: i64) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSlice(Request, a, bytes, .{ .allocate = .alloc_always }) catch
        return failure(gpa, "invalid_request", "Invalid agent request. Use corral agent --help.");
    const req = parsed.value;
    validate(req) catch |err| return failure(gpa, "invalid_request", @errorName(err));

    if (req.command == .list) {
        var tasks: std.ArrayList(TaskInfo) = .empty;
        const ConfigError = struct { config: []const u8, message: []const u8 };
        var errors: std.ArrayList(ConfigError) = .empty;
        for (entries) |entry| {
            if (!try configMatches(a, root, entry, req.config)) continue;
            if (entry.err.len > 0) try errors.append(a, .{ .config = entry.path, .message = entry.err });
            for (entry.tasks) |t| {
                if (req.name) |name| if (std.mem.indexOf(u8, t.name(), name) == null) continue;
                if (req.status) |status| if (!std.mem.eql(u8, t.statusText(), status)) continue;
                if (req.state) |state| if (t.state != state) continue;
                try tasks.append(a, try info(a, entry, t));
            }
        }
        return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .root = root, .tasks = tasks.items, .config_errors = errors.items }, .{});
    }

    // Prefer an exact ID over a name. Resolve fully before mutating anything.
    var selected: ?*Task = null;
    var selected_entry: ?@TypeOf(entries[0]) = null;
    var matches: usize = 0;
    for ([_]bool{ true, false }) |by_id| {
        for (entries) |entry| {
            if (!try configMatches(a, root, entry, req.config)) continue;
            for (entry.tasks) |t| {
                const key = if (by_id) try taskId(a, entry.path, t.name()) else t.name();
                if (!std.mem.eql(u8, key, req.target.?)) continue;
                selected = t;
                selected_entry = entry;
                matches += 1;
            }
        }
        if (matches > 0) break;
    }
    if (matches == 0) return failure(gpa, "task_not_found", "No matching task. Use corral agent list to find task IDs.");
    if (matches != 1) return failure(gpa, "ambiguous_task", "Several tasks have that name. Use an ID from corral agent list or add --config.");
    const t = selected.?;
    switch (req.command) {
        .start => t.start(),
        .stop => {
            t.restart_pending = false;
            t.stop(now);
        },
        .restart => t.restart(now),
        .logs => {
            _ = t.drain();
            var w: std.Io.Writer.Allocating = .init(a);
            var formatter = t.formatScrollback();
            formatter.opts.emit = .plain;
            try w.writer.print("{f}", .{formatter});
            const text = tailLines(w.written(), req.lines);
            return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .root = root, .task = try info(a, selected_entry.?, t), .text = text }, .{});
        },
        .show => {},
        .list => unreachable,
    }
    if ((req.command == .start or req.command == .restart) and t.exit == .spawn_failed)
        return failure(gpa, "spawn_failed", "Task could not start. Read its logs for details.");
    return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .root = root, .task = try info(a, selected_entry.?, t) }, .{});
}

fn tailLines(text: []const u8, lines: usize) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    var left = lines;
    var i = trimmed.len;
    while (i > 0) {
        i -= 1;
        if (trimmed[i] == '\n') {
            left -= 1;
            if (left == 0) return trimmed[i + 1 ..];
        }
    }
    return trimmed;
}

test "agent arguments reject unsafe or ambiguous command shapes" {
    const t = std.testing;
    const req = try parse(&.{ "list", "--name", "web", "--status", "running", "--config", "services" });
    try t.expectEqualStrings("web", req.name.?);
    try t.expectError(error.TaskRequired, parse(&.{"stop"}));
    try t.expectError(error.UnexpectedOption, parse(&.{ "stop", "web", "--status", "running" }));
    try t.expectError(error.UnexpectedOption, parse(&.{ "show", "web", "--lines", "10" }));
    try t.expectError(error.InvalidStatus, parse(&.{ "list", "--status", "unknown" }));
    try t.expectError(error.InvalidLines, parse(&.{ "logs", "web", "--lines", "0" }));
    try t.expectError(error.DuplicateOption, parse(&.{ "list", "--name", "a", "--name", "b" }));
}

test "log tail counts logical lines including an unfinished last line" {
    try std.testing.expectEqualStrings("b\nc", tailLines("a\nb\nc\n", 2));
    try std.testing.expectEqualStrings("c", tailLines("a\nb\nc", 1));
    try std.testing.expectEqualStrings("", tailLines("", 3));
}

test "task IDs escape separators" {
    const id = try taskId(std.testing.allocator, "/work/corral.json", "web/~dev");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("/~1work~1corral.json/web~1~0dev", id);
}
