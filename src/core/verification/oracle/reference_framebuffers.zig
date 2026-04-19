const std = @import("std");
const cache = @import("../../cache.zig");

// Bundled oracle of framebuffer snapshots captured from a reference
// emulator (Cadmium, Octo, etc.), used by the display and opcodes axes to
// grade our output with pixel-exact precision.
//
// Stored as `assets/reference_framebuffers.json`, shipped with the binary
// via @embedFile, loaded on first access. Entries keyed by rom SHA-1 so
// any installed ROM that matches is automatically graded.
//
// Schema:
//   {
//     "version": 1,
//     "entries": {
//       "<rom_sha1>": {
//         "rom_name": "3-corax+",
//         "platform": "originalChip8",
//         "reference_emulator": "cadmium-1.0.12",
//         "font_style": "cosmac",
//         "snapshots": [
//           { "cycle": 100,  "framebuffer_sha256": "...", "display_wh": [64, 32] },
//           { "cycle": 1000, "framebuffer_sha256": "..." }
//         ]
//       }
//     }
//   }
//
// Generation is manual and offline — `scripts/CAPTURING_REFERENCE.md`
// documents the exact invocation. Do NOT regenerate from our own emulator
// output; the whole point is that the oracle sits outside the thing we're
// verifying.

pub const Snapshot = struct {
    cycle: u32,
    framebuffer_sha256: []const u8,
    display_wh: ?[2]u16 = null,
};

pub const Entry = struct {
    rom_name: []const u8,
    platform: []const u8,
    reference_emulator: []const u8,
    font_style: ?[]const u8 = null,
    snapshots: []const Snapshot,
};

// On-disk / in-memory shape. Dict-of-SHA1 → Entry via json's ArrayHashMap
// so lookups are O(log n) without a dedicated hash map type.
const SerializedShape = struct {
    version: u32 = 1,
    entries: std.json.ArrayHashMap(Entry) = .{},
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    parsed: ?std.json.Parsed(SerializedShape) = null,

    pub fn deinit(self: *Store) void {
        if (self.parsed) |p| p.deinit();
        self.parsed = null;
    }

    pub fn lookup(self: *const Store, sha1: []const u8) ?Entry {
        const p = self.parsed orelse return null;
        return p.value.entries.map.get(sha1);
    }

    // Return the snapshot hash matching `cycle` exactly, or null if the
    // entry exists but doesn't have that cycle captured. Callers decide
    // whether a cycle-mismatch is a skip or a fail.
    pub fn snapshotAt(self: *const Store, sha1: []const u8, cycle: u32) ?[]const u8 {
        const entry = self.lookup(sha1) orelse return null;
        for (entry.snapshots) |s| {
            if (s.cycle == cycle) return s.framebuffer_sha256;
        }
        return null;
    }
};

const embedded_json: []const u8 = @embedFile("../../assets/reference_framebuffers.json");

// Load the shipped reference data. First tries a user-writable override at
// `<app_data_root>/verification/reference_framebuffers.json` so devs can
// iterate without rebuilding; falls back to the embedded asset.
pub fn load(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) !Store {
    const override_path = try std.fmt.allocPrint(
        allocator,
        "{s}/verification/reference_framebuffers.json",
        .{app_data_root},
    );
    defer allocator.free(override_path);

    const override = cache.readJson(io, allocator, override_path, SerializedShape) catch null;
    if (override) |p| return .{ .allocator = allocator, .parsed = p };

    const parsed = try std.json.parseFromSlice(SerializedShape, allocator, embedded_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{ .allocator = allocator, .parsed = parsed };
}

test "empty store lookups return null" {
    const allocator = std.testing.allocator;
    var s = Store{ .allocator = allocator };
    defer s.deinit();
    try std.testing.expect(s.lookup("abc") == null);
    try std.testing.expect(s.snapshotAt("abc", 100) == null);
}

test "embedded asset parses as a valid SerializedShape" {
    // We can't call load() here because it takes a std.Io value and tests
    // run without the runtime's io vtable wired up. Parse the embedded
    // bytes directly — same code path, no I/O probe.
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(SerializedShape, allocator, embedded_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
}
