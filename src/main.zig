const std = @import("std");

const App = @import("App.zig");
const Config = @import("Config.zig");
const Term = @import("Term.zig");
const discover = @import("discover.zig");

const usage =
    \\corral — run your dev processes side by side, in one view
    \\
    \\Usage: corral [-c <config>]
    \\
    \\Finds every corral.json under the working directory and lists them.
    \\`l` steps into one, `h` steps back out, `s` starts a task, `S` starts
    \\the whole config. Nothing runs until you ask it to.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var explicit: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout(io, usage);
            return;
        }
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) fail(io, "-c/--config needs a path", .{});
            explicit = args[i];
            continue;
        }
        fail(io, "unknown argument: {s}", .{arg});
    }

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    var found = try discover.scan(gpa, io, root);
    defer discover.free(gpa, found);

    // An explicitly named config need not be anywhere under the working
    // directory, so make room for it in the list if the scan missed it.
    var explicit_abs: ?[]const u8 = null;
    defer if (explicit_abs) |p| gpa.free(p);
    if (explicit) |path| {
        const abs = try std.fs.path.resolve(gpa, &.{ root, path });
        explicit_abs = abs;
        found = try includePath(gpa, found, root, abs);
    }

    if (found.len == 0) {
        fail(io, "no {s} found under {s}", .{ Config.file_name, root });
    }

    var app: App = try .init(gpa, io, root, found);
    defer app.deinit();

    // Step straight into the config there is no choice about. The list is
    // still one `h` away.
    if (explicit_abs) |path| {
        app.enterOnStart(path);
    } else if (found.len == 1) {
        app.enterOnStart(found[0].path);
    }

    app.run() catch |err| switch (err) {
        // The common way to hit this is a pipe or a CI log, where the real
        // answer is "corral needs a terminal", not a Zig error name.
        error.NotATerminal => fail(io, "needs a terminal to run in", .{}),
        // `run` restores the terminal on its way out, so anything else
        // prints onto a sane screen rather than into the alternate one.
        else => fail(io, "{t}", .{err}),
    };
}

/// Add `abs` to the scan results if it is not already there.
fn includePath(
    gpa: std.mem.Allocator,
    found: []discover.Found,
    root: []const u8,
    abs: []const u8,
) ![]discover.Found {
    for (found) |f| {
        if (std.mem.eql(u8, f.path, abs)) return found;
    }

    var list: std.ArrayList(discover.Found) = .fromOwnedSlice(found);
    errdefer list.deinit(gpa);

    const display = if (std.mem.startsWith(u8, abs, root) and abs.len > root.len + 1)
        try gpa.dupe(u8, abs[root.len + 1 ..])
    else
        try gpa.dupe(u8, abs);
    errdefer gpa.free(display);

    try list.insert(gpa, 0, .{
        .path = try gpa.dupe(u8, abs),
        .display = display,
    });
    return list.toOwnedSlice(gpa);
}

fn stdout(io: std.Io, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// Report a problem the way a command line tool should: one line on stderr,
/// a non-zero status, and no Zig error trace on top of it.
fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    writer.interface.print("corral: " ++ fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
    std.process.exit(1);
}

test {
    _ = @import("App.zig");
    _ = @import("Config.zig");
    _ = @import("Grid.zig");
    _ = @import("Task.zig");
    _ = @import("Term.zig");
    _ = @import("discover.zig");
    _ = @import("input.zig");
}
