//! Loading and validating a `corral.json`.
//!
//! A `Config` owns everything it hands out through an arena, so dropping one
//! is a single `deinit` no matter how far a task definition sprawled.

const Config = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "corral.json";

arena: std.heap.ArenaAllocator,

/// Absolute path to the config file.
path: []const u8,
/// Absolute path to the directory holding it; what relative paths resolve
/// against.
dir: []const u8,
tasks: []const Task,

pub const Task = struct {
    name: []const u8,
    /// The command line, handed to `sh -c`.
    shell: []const u8,
    cwd: []const u8,
    /// NUL-terminated because these go straight into `execve`.
    env: []const [2][:0]const u8,
    /// Whether "start everything here" includes this task. Corral never
    /// starts anything on its own, so `autostart: false` means "only when
    /// asked for by name" rather than "not at launch".
    in_start_all: bool,
    stop: Stop,
};

pub const Stop = union(enum) {
    /// Bytes to write to the pty, e.g. 0x03 for `<C-c>`.
    keys: []const u8,
    signal: c_int,
};

pub const SIGINT = 2;
pub const SIGKILL = 9;
pub const SIGTERM = 15;

/// A human-readable explanation for why loading failed. Kept inline so that
/// reporting an error never needs an allocator that might itself be the
/// thing that failed.
pub const Diag = struct {
    buf: [512]u8 = undefined,
    msg: []const u8 = "",

    fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        self.msg = std.fmt.bufPrint(&self.buf, fmt, args) catch
            "error message too long to format";
    }
};

pub const LoadError = error{
    ReadFailed,
    Invalid,
} || Allocator.Error;

/// Read and parse `path`, which must be absolute.
pub fn load(gpa: Allocator, io: Io, path: []const u8, diag: *Diag) LoadError!Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch |err| {
        diag.set("cannot read {s}: {t}", .{ path, err });
        return error.ReadFailed;
    };
    defer gpa.free(text);

    return parse(gpa, path, text, diag);
}

/// Split out from `load` so the parser is testable without touching disk.
pub fn parse(
    gpa: Allocator,
    path: []const u8,
    text: []const u8,
    diag: *Diag,
) LoadError!Config {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const owned_path = try arena.dupe(u8, path);
    const dir = std.fs.path.dirname(owned_path) orelse "/";

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| {
        diag.set("{s}: not valid JSON ({t})", .{ std.fs.path.basename(path), err });
        return error.Invalid;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            diag.set("{s}: top level must be an object", .{std.fs.path.basename(path)});
            return error.Invalid;
        },
    };

    const defs = switch (root.get("tasks") orelse {
        diag.set("{s}: no \"tasks\" object", .{std.fs.path.basename(path)});
        return error.Invalid;
    }) {
        .object => |o| o,
        else => {
            diag.set("{s}: \"tasks\" must be an object", .{std.fs.path.basename(path)});
            return error.Invalid;
        },
    };

    if (defs.count() == 0) {
        diag.set("{s}: defines no tasks", .{std.fs.path.basename(path)});
        return error.Invalid;
    }

    var tasks: std.ArrayList(Task) = .empty;
    // `std.json`'s object map preserves insertion order, so the sidebar ends
    // up in the same order as the file. That is worth relying on: the order
    // tasks are written in is the order they are thought about in.
    var it = defs.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const task = try parseTask(arena, dir, name, entry.value_ptr.*, diag);
        try tasks.append(arena, task);
    }

    return .{
        .arena = arena_state,
        .path = owned_path,
        .dir = dir,
        .tasks = tasks.items,
    };
}

fn parseTask(
    arena: Allocator,
    dir: []const u8,
    name: []const u8,
    value: std.json.Value,
    diag: *Diag,
) LoadError!Task {
    // Shorthand: `"web": "npm run dev"`.
    const obj = switch (value) {
        .string => |s| {
            return .{
                .name = try arena.dupe(u8, name),
                .shell = try arena.dupe(u8, s),
                .cwd = try arena.dupe(u8, dir),
                .env = &.{},
                .in_start_all = true,
                .stop = .{ .signal = SIGTERM },
            };
        },
        .object => |o| o,
        else => {
            diag.set("task \"{s}\": must be a string or an object", .{name});
            return error.Invalid;
        },
    };

    const shell = switch (obj.get("shell") orelse {
        // `cmd: [...]` is deliberately unsupported. Everything corral runs
        // goes through a shell, and supporting both spellings means every
        // config reader downstream has to handle both.
        diag.set("task \"{s}\": needs a string \"shell\"", .{name});
        return error.Invalid;
    }) {
        .string => |s| s,
        else => {
            diag.set("task \"{s}\": \"shell\" must be a string", .{name});
            return error.Invalid;
        },
    };

    const cwd = cwd: {
        const raw = switch (obj.get("cwd") orelse std.json.Value{ .string = dir }) {
            .string => |s| s,
            else => {
                diag.set("task \"{s}\": \"cwd\" must be a string", .{name});
                return error.Invalid;
            },
        };
        if (std.fs.path.isAbsolute(raw)) break :cwd try arena.dupe(u8, raw);
        break :cwd try std.fs.path.resolve(arena, &.{ dir, raw });
    };

    var env: std.ArrayList([2][:0]const u8) = .empty;
    if (obj.get("env")) |raw_env| {
        const map = switch (raw_env) {
            .object => |o| o,
            else => {
                diag.set("task \"{s}\": \"env\" must be an object", .{name});
                return error.Invalid;
            },
        };
        var it = map.iterator();
        while (it.next()) |entry| {
            const val = switch (entry.value_ptr.*) {
                .string => |s| try arena.dupeZ(u8, s),
                .integer => |i| try std.fmt.allocPrintSentinel(arena, "{d}", .{i}, 0),
                .bool => |b| try arena.dupeZ(u8, if (b) "true" else "false"),
                .null => continue,
                else => {
                    diag.set(
                        "task \"{s}\": env \"{s}\" must be a string, number or bool",
                        .{ name, entry.key_ptr.* },
                    );
                    return error.Invalid;
                },
            };
            try env.append(arena, .{ try arena.dupeZ(u8, entry.key_ptr.*), val });
        }
    }

    const in_start_all = switch (obj.get("autostart") orelse std.json.Value{ .bool = true }) {
        .bool => |b| b,
        else => {
            diag.set("task \"{s}\": \"autostart\" must be a boolean", .{name});
            return error.Invalid;
        },
    };

    return .{
        .name = try arena.dupe(u8, name),
        .shell = try arena.dupe(u8, shell),
        .cwd = cwd,
        .env = env.items,
        .in_start_all = in_start_all,
        .stop = try parseStop(arena, name, obj.get("stop"), diag),
    };
}

fn parseStop(
    arena: Allocator,
    name: []const u8,
    value: ?std.json.Value,
    diag: *Diag,
) LoadError!Stop {
    const raw = value orelse return .{ .signal = SIGTERM };
    switch (raw) {
        .null => return .{ .signal = SIGTERM },
        .string => |s| {
            if (std.ascii.eqlIgnoreCase(s, "SIGINT")) return .{ .signal = SIGINT };
            if (std.ascii.eqlIgnoreCase(s, "SIGTERM")) return .{ .signal = SIGTERM };
            if (std.ascii.eqlIgnoreCase(s, "SIGKILL")) return .{ .signal = SIGKILL };
            diag.set("task \"{s}\": unsupported stop signal \"{s}\"", .{ name, s });
            return error.Invalid;
        },
        .object => |o| {
            const keys = switch (o.get("send-keys") orelse {
                diag.set("task \"{s}\": \"stop\" object needs \"send-keys\"", .{name});
                return error.Invalid;
            }) {
                .array => |a| a,
                else => {
                    diag.set("task \"{s}\": \"send-keys\" must be an array", .{name});
                    return error.Invalid;
                },
            };
            var out: std.ArrayList(u8) = .empty;
            for (keys.items) |item| {
                const s = switch (item) {
                    .string => |s| s,
                    else => {
                        diag.set("task \"{s}\": \"send-keys\" entries must be strings", .{name});
                        return error.Invalid;
                    },
                };
                decodeKeys(arena, &out, s) catch {
                    diag.set("task \"{s}\": unrecognized key notation \"{s}\"", .{ name, s });
                    return error.Invalid;
                };
            }
            return .{ .keys = out.items };
        },
        else => {
            diag.set("task \"{s}\": \"stop\" must be a string or an object", .{name});
            return error.Invalid;
        },
    }
}

/// `<C-c>` -> 0x03, `<Enter>` -> CR, anything else passes through verbatim.
fn decodeKeys(
    arena: Allocator,
    out: *std.ArrayList(u8),
    notation: []const u8,
) !void {
    if (notation.len < 3 or notation[0] != '<' or notation[notation.len - 1] != '>') {
        try out.appendSlice(arena, notation);
        return;
    }
    const body = notation[1 .. notation.len - 1];

    // `<C-c>`, and the `<C-Space>`-style spelling of the same idea.
    if (body.len == 3 and (body[0] == 'C' or body[0] == 'c') and body[1] == '-') {
        const code = std.ascii.toUpper(body[2]);
        // Ctrl maps A..Z (and a handful of neighbours) onto 0x01..0x1f.
        if (code >= '@' and code <= '_') {
            try out.append(arena, code - '@');
            return;
        }
        if (code == '?') {
            try out.append(arena, 0x7f);
            return;
        }
    }

    const named: []const struct { []const u8, []const u8 } = &.{
        .{ "enter", "\r" },
        .{ "cr", "\r" },
        .{ "esc", "\x1b" },
        .{ "escape", "\x1b" },
        .{ "space", " " },
        .{ "tab", "\t" },
        .{ "backspace", "\x7f" },
        .{ "up", "\x1b[A" },
        .{ "down", "\x1b[B" },
        .{ "right", "\x1b[C" },
        .{ "left", "\x1b[D" },
    };
    for (named) |pair| {
        if (std.ascii.eqlIgnoreCase(body, pair[0])) {
            try out.appendSlice(arena, pair[1]);
            return;
        }
    }
    return error.Unrecognized;
}

pub fn deinit(self: *Config) void {
    self.arena.deinit();
    self.* = undefined;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

fn parseTest(text: []const u8) !Config {
    var diag: Diag = .{};
    return parse(testing.allocator, "/work/corral.json", text, &diag) catch |err| {
        std.debug.print("parse failed: {s}\n", .{diag.msg});
        return err;
    };
}

test "shorthand task" {
    var cfg = try parseTest(
        \\{"tasks": {"web": "npm run dev"}}
    );
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.tasks.len);
    try testing.expectEqualStrings("web", cfg.tasks[0].name);
    try testing.expectEqualStrings("npm run dev", cfg.tasks[0].shell);
    try testing.expectEqualStrings("/work", cfg.tasks[0].cwd);
    try testing.expectEqual(Stop{ .signal = SIGTERM }, cfg.tasks[0].stop);
}

test "cwd resolves against the config" {
    var cfg = try parseTest(
        \\{"tasks": {
        \\  "a": {"shell": "run", "cwd": "api"},
        \\  "b": {"shell": "run", "cwd": "../sibling"},
        \\  "c": {"shell": "run", "cwd": "/elsewhere"}
        \\}}
    );
    defer cfg.deinit();

    try testing.expectEqualStrings("/work/api", cfg.tasks[0].cwd);
    try testing.expectEqualStrings("/sibling", cfg.tasks[1].cwd);
    try testing.expectEqualStrings("/elsewhere", cfg.tasks[2].cwd);
}

test "task order follows the file" {
    var cfg = try parseTest(
        \\{"tasks": {"zeta": "z", "alpha": "a", "mid": "m"}}
    );
    defer cfg.deinit();

    try testing.expectEqualStrings("zeta", cfg.tasks[0].name);
    try testing.expectEqualStrings("alpha", cfg.tasks[1].name);
    try testing.expectEqualStrings("mid", cfg.tasks[2].name);
}

test "stop modes" {
    var cfg = try parseTest(
        \\{"tasks": {
        \\  "a": {"shell": "x", "stop": "SIGINT"},
        \\  "b": {"shell": "x", "stop": {"send-keys": ["<C-c>", "q", "<Enter>"]}}
        \\}}
    );
    defer cfg.deinit();

    try testing.expectEqual(Stop{ .signal = SIGINT }, cfg.tasks[0].stop);
    try testing.expectEqualStrings("\x03q\r", cfg.tasks[1].stop.keys);
}

test "env is nul terminated" {
    var cfg = try parseTest(
        \\{"tasks": {"a": {"shell": "x", "env": {"ROOT": "data", "PORT": 8080}}}}
    );
    defer cfg.deinit();

    const env = cfg.tasks[0].env;
    try testing.expectEqual(@as(usize, 2), env.len);
    try testing.expectEqualStrings("ROOT", env[0][0]);
    try testing.expectEqualStrings("data", env[0][1]);
    try testing.expectEqualStrings("8080", env[1][1]);
}

test "autostart only scopes start-all" {
    var cfg = try parseTest(
        \\{"tasks": {"a": {"shell": "x"}, "b": {"shell": "x", "autostart": false}}}
    );
    defer cfg.deinit();

    try testing.expect(cfg.tasks[0].in_start_all);
    try testing.expect(!cfg.tasks[1].in_start_all);
}

test "errors are explained, not thrown away" {
    const cases: []const struct { []const u8, []const u8 } = &.{
        .{ "{", "not valid JSON" },
        .{ "[]", "top level must be an object" },
        .{ "{}", "no \"tasks\" object" },
        .{ "{\"tasks\": {}}", "defines no tasks" },
        .{ "{\"tasks\": {\"a\": {}}}", "needs a string \"shell\"" },
        .{ "{\"tasks\": {\"a\": {\"shell\": \"x\", \"stop\": \"SIGFOO\"}}}", "unsupported stop signal" },
        .{ "{\"tasks\": {\"a\": {\"shell\": \"x\", \"stop\": {\"send-keys\": [\"<Nope>\"]}}}}", "unrecognized key notation" },
    };
    for (cases) |case| {
        var diag: Diag = .{};
        try testing.expectError(
            error.Invalid,
            parse(testing.allocator, "/work/corral.json", case[0], &diag),
        );
        try testing.expect(std.mem.indexOf(u8, diag.msg, case[1]) != null);
    }
}
