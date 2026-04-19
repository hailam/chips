const std = @import("std");
const models = @import("registry_models.zig");
const cache = @import("cache.zig");
const network = @import("network.zig");
const shipped = @import("shipped_assets.zig");

// Local cache of chip-8-database entries keyed by SHA-1. Avoids live fetches
// on every operation; works offline for hashes present in the cache.
//
// On-disk shape (chip8_db_cache.json):
//   {
//     "last_full_sync": <unix_ms>,
//     "entries": [ { "sha1": "<hex>", "entry": Chip8DbEntry }, ... ],
//     "misses": [ "<hex>", ... ]
//   }

const HASHES_URL = "https://raw.githubusercontent.com/chip-8/chip-8-database/master/database/sha1-hashes.json";
const PROGRAMS_URL = "https://raw.githubusercontent.com/chip-8/chip-8-database/master/database/programs.json";

pub const State = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(models.Chip8DbEntry) = .{},
    misses: std.StringHashMapUnmanaged(void) = .{},
    last_full_sync: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);

        var mit = self.misses.iterator();
        while (mit.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.misses.deinit(self.allocator);
    }

    pub fn lookup(self: *const State, sha1: []const u8) ?models.Chip8DbEntry {
        return self.entries.get(sha1);
    }

    pub fn isKnownMiss(self: *const State, sha1: []const u8) bool {
        return self.misses.contains(sha1);
    }

    pub fn putEntry(self: *State, sha1: []const u8, entry: models.Chip8DbEntry) !void {
        const key = try self.allocator.dupe(u8, sha1);
        errdefer self.allocator.free(key);
        const gop = try self.entries.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            gop.value_ptr.deinit(self.allocator);
        }
        gop.value_ptr.* = entry;
    }

    pub fn putMiss(self: *State, sha1: []const u8) !void {
        const key = try self.allocator.dupe(u8, sha1);
        errdefer self.allocator.free(key);
        const gop = try self.misses.getOrPut(self.allocator, key);
        if (gop.found_existing) self.allocator.free(key);
    }
};

const SerializedEntry = struct { sha1: []const u8, entry: models.Chip8DbEntry };
const SerializedState = struct {
    last_full_sync: i64 = 0,
    entries: []SerializedEntry = &.{},
    misses: []const []const u8 = &.{},
};

pub fn cachePath(allocator: std.mem.Allocator, app_data_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/chip8_db_cache.json", .{app_data_root});
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) !State {
    const path = try cachePath(allocator, app_data_root);
    defer allocator.free(path);

    var state = State.init(allocator);
    errdefer state.deinit();

    const maybe_parsed = try cache.readJson(io, allocator, path, SerializedState);
    var parsed: std.json.Parsed(SerializedState) = undefined;
    if (maybe_parsed) |p| {
        parsed = p;
    } else {
        parsed = try std.json.parseFromSlice(SerializedState, allocator, shipped.chip8_db_cache_json, .{ .ignore_unknown_fields = true });
    }
    defer parsed.deinit();

    state.last_full_sync = parsed.value.last_full_sync;
    for (parsed.value.entries) |se| {
        const cloned = try se.entry.clone(allocator);
        errdefer cloned.deinit(allocator);
        try state.putEntry(se.sha1, cloned);
    }
    for (parsed.value.misses) |m| try state.putMiss(m);
    return state;
}

pub fn save(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8, state: *const State) !void {
    const path = try cachePath(allocator, app_data_root);
    defer allocator.free(path);

    var entries = try allocator.alloc(SerializedEntry, state.entries.count());
    defer allocator.free(entries);
    var i: usize = 0;
    var it = state.entries.iterator();
    while (it.next()) |kv| : (i += 1) {
        entries[i] = .{ .sha1 = kv.key_ptr.*, .entry = kv.value_ptr.* };
    }

    var misses = try allocator.alloc([]const u8, state.misses.count());
    defer allocator.free(misses);
    var j: usize = 0;
    var mit = state.misses.iterator();
    while (mit.next()) |kv| : (j += 1) misses[j] = kv.key_ptr.*;

    const view = SerializedState{
        .last_full_sync = state.last_full_sync,
        .entries = entries,
        .misses = misses,
    };
    try cache.writeJsonAtomic(io, allocator, path, view);
}

// Shape of chip-8-database program entries (partial — only fields we care about).
const DbProgram = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    release: []const u8 = "",
    authors: []const []const u8 = &.{},
    roms: std.json.ArrayHashMap(DbRom) = .{},
};

const DbRom = struct {
    file: ?[]const u8 = null,
    platforms: []const []const u8 = &.{},
    embeddedTitle: ?[]const u8 = null,
    tickrate: ?u32 = null,
    startAddress: ?u16 = null,
    screenRotation: ?u16 = null,
    fontStyle: ?[]const u8 = null,
    touchInputMode: ?[]const u8 = null,
    keys: ?models.DbKeys = null,
    colors: ?models.DbColors = null,
    quirkyPlatforms: std.json.ArrayHashMap(models.QuirkSet) = .{},
};

pub fn fetchAndCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *State,
    sha1: []const u8,
) !?models.Chip8DbEntry {
    // Short-circuit if already known.
    if (state.lookup(sha1)) |e| return e;
    if (state.isKnownMiss(sha1)) return null;

    // Download sha1-hashes.json, find index.
    const hashes_bytes = network.fetchBytes(io, allocator, HASHES_URL) catch return null;
    defer allocator.free(hashes_bytes);

    const HashMap = std.json.ArrayHashMap(u32);
    const hashes_parsed = std.json.parseFromSlice(HashMap, allocator, hashes_bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer hashes_parsed.deinit();

    const index = hashes_parsed.value.map.get(sha1) orelse {
        try state.putMiss(sha1);
        return null;
    };

    const programs_bytes = network.fetchBytes(io, allocator, PROGRAMS_URL) catch return null;
    defer allocator.free(programs_bytes);

    const programs_parsed = std.json.parseFromSlice([]DbProgram, allocator, programs_bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer programs_parsed.deinit();

    if (index >= programs_parsed.value.len) {
        try state.putMiss(sha1);
        return null;
    }

    const prog = programs_parsed.value[index];
    const rom = prog.roms.map.get(sha1) orelse {
        try state.putMiss(sha1);
        return null;
    };

    const entry = try buildEntry(allocator, prog, rom);
    try state.putEntry(sha1, entry);
    return state.lookup(sha1).?;
}

pub fn refreshAll(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *State,
) !void {
    const hashes_bytes = try network.fetchBytes(io, allocator, HASHES_URL);
    defer allocator.free(hashes_bytes);

    const HashMap = std.json.ArrayHashMap(u32);
    const hashes_parsed = try std.json.parseFromSlice(HashMap, allocator, hashes_bytes, .{ .ignore_unknown_fields = true });
    defer hashes_parsed.deinit();

    const programs_bytes = try network.fetchBytes(io, allocator, PROGRAMS_URL);
    defer allocator.free(programs_bytes);

    const programs_parsed = try std.json.parseFromSlice([]DbProgram, allocator, programs_bytes, .{ .ignore_unknown_fields = true });
    defer programs_parsed.deinit();

    // Clear existing entries and misses — full rebuild.
    {
        var it = state.entries.iterator();
        while (it.next()) |kv| {
            state.allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(state.allocator);
        }
        state.entries.clearRetainingCapacity();
    }
    {
        var mit = state.misses.iterator();
        while (mit.next()) |kv| state.allocator.free(kv.key_ptr.*);
        state.misses.clearRetainingCapacity();
    }

    var hit = hashes_parsed.value.map.iterator();
    while (hit.next()) |kv| {
        const sha1 = kv.key_ptr.*;
        const index = kv.value_ptr.*;
        if (index >= programs_parsed.value.len) continue;
        const prog = programs_parsed.value[index];
        const rom = prog.roms.map.get(sha1) orelse continue;
        const entry = try buildEntry(allocator, prog, rom);
        try state.putEntry(sha1, entry);
    }

    state.last_full_sync = std.Io.Clock.now(.real, io).toMilliseconds();
}

fn buildEntry(allocator: std.mem.Allocator, prog: DbProgram, rom: DbRom) !models.Chip8DbEntry {
    var authors = try allocator.alloc([]const u8, prog.authors.len);
    var a_pop: usize = 0;
    errdefer {
        for (authors[0..a_pop]) |a| allocator.free(a);
        allocator.free(authors);
    }
    for (prog.authors, 0..) |a, i| {
        authors[i] = try allocator.dupe(u8, a);
        a_pop = i + 1;
    }

    var platforms = try allocator.alloc([]const u8, rom.platforms.len);
    var p_pop: usize = 0;
    errdefer {
        for (platforms[0..p_pop]) |p| allocator.free(p);
        allocator.free(platforms);
    }
    for (rom.platforms, 0..) |p, i| {
        platforms[i] = try allocator.dupe(u8, p);
        p_pop = i + 1;
    }

    // Flatten quirkyPlatforms (JSON object) into a list so it round-trips
    // through our own json-serialized cache without hash-map dependencies.
    var qp = try allocator.alloc(models.QuirkyPlatformOverride, rom.quirkyPlatforms.map.count());
    var qp_pop: usize = 0;
    errdefer {
        for (qp[0..qp_pop]) |q| q.deinit(allocator);
        allocator.free(qp);
    }
    var qp_it = rom.quirkyPlatforms.map.iterator();
    while (qp_it.next()) |kv| {
        qp[qp_pop] = .{
            .platform = try allocator.dupe(u8, kv.key_ptr.*),
            .quirks = kv.value_ptr.*,
        };
        qp_pop += 1;
    }

    const colors_clone: ?models.DbColors = if (rom.colors) |c| try c.clone(allocator) else null;

    return .{
        .title = try allocator.dupe(u8, prog.title),
        .description = try allocator.dupe(u8, prog.description),
        .release = try allocator.dupe(u8, prog.release),
        .authors = authors,
        .platforms = platforms,
        .file = if (rom.file) |v| try allocator.dupe(u8, v) else null,
        .embedded_title = if (rom.embeddedTitle) |v| try allocator.dupe(u8, v) else null,
        .tickrate = rom.tickrate,
        .start_address = rom.startAddress,
        .screen_rotation = rom.screenRotation,
        .font_style = if (rom.fontStyle) |v| try allocator.dupe(u8, v) else null,
        .touch_input_mode = if (rom.touchInputMode) |v| try allocator.dupe(u8, v) else null,
        .keys = rom.keys,
        .colors = colors_clone,
        .quirky_platforms = qp,
    };
}
