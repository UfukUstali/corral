//! Finding every `corral.json` under a root directory.
//!
//! This is what makes the side panel two levels deep: one flat list of the
//! configs in the tree, and one flat list of the tasks inside whichever
//! config you stepped into.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Config = @import("Config.zig");

/// How far below the root to look. Deep enough for a monorepo's
/// `packages/<name>/services/<name>`, shallow enough that a stray symlink
/// into `/` cannot keep us busy.
pub const max_depth = 8;

/// Enough configs that hitting the cap means something is wrong with the
/// root, not with the cap.
pub const max_results = 512;

pub const Found = struct {
    /// Absolute path to the config file.
    path: []const u8,
    /// Path relative to the scan root, for display: `corral.json`,
    /// `services/api/corral.json`.
    display: []const u8,
};

/// Directories that never contain a config worth running and frequently
/// contain tens of thousands of files. Skipping them is the difference
/// between an instant scan and a visible pause.
const skip_dirs: []const []const u8 = &.{
    "node_modules",
    "target",
    "vendor",
    "dist",
    "build",
    "out",
    "result",
    "zig-out",
    "zig-cache",
    "__pycache__",
    "venv",
    "Pods",
    "DerivedData",
};

fn shouldSkip(name: []const u8) bool {
    // Hidden directories cover `.git`, `.direnv`, `.zig-cache`, `.venv` and
    // everything else in that family without listing them one by one.
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

/// Walk `root` (an absolute path) and return every config found, ordered
/// shallowest first and alphabetically within a depth. Caller owns the
/// result; free it with `free`.
pub fn scan(gpa: Allocator, io: Io, root: []const u8) ![]Found {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var found: std.ArrayList(Found) = .empty;
    errdefer {
        for (found.items) |f| {
            gpa.free(f.path);
            gpa.free(f.display);
        }
        found.deinit(gpa);
    }

    while (true) {
        // A directory we cannot read is not a reason to abandon the scan.
        // The walker has already popped the offending directory, so retrying
        // makes progress rather than spinning.
        const next = walker.next(io) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const entry = next orelse break;

        switch (entry.kind) {
            .directory => {
                if (shouldSkip(entry.basename)) continue;
                if (depthOf(entry.path) >= max_depth) continue;
                // Symlinked directories report `.sym_link`, not `.directory`,
                // so declining to enter them here is also what keeps a cyclic
                // symlink from mattering.
                walker.enter(io, entry) catch continue;
            },
            .file, .sym_link => {
                if (!std.mem.eql(u8, entry.basename, Config.file_name)) continue;
                if (found.items.len >= max_results) break;
                const display = try gpa.dupe(u8, entry.path);
                errdefer gpa.free(display);
                const abs = try std.fs.path.join(gpa, &.{ root, entry.path });
                try found.append(gpa, .{ .path = abs, .display = display });
            },
            else => {},
        }
    }

    std.mem.sort(Found, found.items, {}, lessThan);
    return found.toOwnedSlice(gpa);
}

fn depthOf(path: []const u8) usize {
    return std.mem.count(u8, path, std.fs.path.sep_str);
}

/// Shallow before deep, then alphabetical. The config in the directory you
/// launched from is therefore always the first row.
fn lessThan(_: void, a: Found, b: Found) bool {
    const da = depthOf(a.display);
    const db = depthOf(b.display);
    if (da != db) return da < db;
    return std.mem.lessThan(u8, a.display, b.display);
}

pub fn free(gpa: Allocator, list: []Found) void {
    for (list) |f| {
        gpa.free(f.path);
        gpa.free(f.display);
    }
    gpa.free(list);
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "ordering is shallow-first then alphabetical" {
    var list = [_]Found{
        .{ .path = "", .display = "b/corral.json" },
        .{ .path = "", .display = "corral.json" },
        .{ .path = "", .display = "a/deep/corral.json" },
        .{ .path = "", .display = "a/corral.json" },
    };
    std.mem.sort(Found, &list, {}, lessThan);

    try testing.expectEqualStrings("corral.json", list[0].display);
    try testing.expectEqualStrings("a/corral.json", list[1].display);
    try testing.expectEqualStrings("b/corral.json", list[2].display);
    try testing.expectEqualStrings("a/deep/corral.json", list[3].display);
}

test "skips hidden and heavy directories" {
    try testing.expect(shouldSkip(".git"));
    try testing.expect(shouldSkip(".direnv"));
    try testing.expect(shouldSkip("node_modules"));
    try testing.expect(shouldSkip("zig-out"));
    try testing.expect(!shouldSkip("services"));
    try testing.expect(!shouldSkip("api"));
}
