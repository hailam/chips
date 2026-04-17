const std = @import("std");
const models = @import("registry_models.zig");
const cache = @import("cache.zig");
const network = @import("network.zig");
const github = @import("github.zig");
const config_mod = @import("config.zig");
const chip8_db_cache = @import("chip8_db_cache.zig");
const url_mod = @import("url.zig");
const shipped = @import("shipped_assets.zig");

// Persistent working memory of known-registry contents. NOT a TTL cache —
// only refreshed by explicit user action (chip8 refresh) or by on-miss
// auto-resync inside registry.install.

pub const Entry = struct {
    path: []const u8,
    git_sha: []const u8,
    sha1: []const u8,
    size: usize,
    chip8_db_hash: ?[]const u8 = null,
    download_url: ?[]const u8 = null,

    pub fn clone(self: Entry, allocator: std.mem.Allocator) !Entry {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .git_sha = try allocator.dupe(u8, self.git_sha),
            .sha1 = try allocator.dupe(u8, self.sha1),
            .size = self.size,
            .chip8_db_hash = if (self.chip8_db_hash) |v| try allocator.dupe(u8, v) else null,
            .download_url = if (self.download_url) |v| try allocator.dupe(u8, v) else null,
        };
    }

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.git_sha);
        allocator.free(self.sha1);
        if (self.chip8_db_hash) |v| allocator.free(v);
        if (self.download_url) |v| allocator.free(v);
    }
};

pub const RegistryState = struct {
    repo: []const u8,
    last_synced: i64 = 0,
    entries: []Entry = &.{},
    manifest: ?models.Manifest = null,

    pub fn deinit(self: RegistryState, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
        for (self.entries) |e| e.deinit(allocator);
        allocator.free(self.entries);
        if (self.manifest) |m| m.deinit(allocator);
    }
};

// Serialized form (JSON object of registry name → RegistryState).
const SerializedState = struct {
    registries: std.json.ArrayHashMap(RegistryState) = .{},
};

pub const State = struct {
    allocator: std.mem.Allocator,
    registries: std.StringHashMapUnmanaged(RegistryState) = .{},

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        var it = self.registries.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(self.allocator);
        }
        self.registries.deinit(self.allocator);
    }

    pub fn get(self: *const State, name: []const u8) ?*const RegistryState {
        return self.registries.getPtr(name);
    }
};

pub fn statePath(allocator: std.mem.Allocator, app_data_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/registry_state.json", .{app_data_root});
}

pub fn loadState(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) !State {
    const path = try statePath(allocator, app_data_root);
    defer allocator.free(path);

    var state = State.init(allocator);
    errdefer state.deinit();

    const maybe_parsed = try cache.readJson(io, allocator, path, SerializedState);
    var parsed: std.json.Parsed(SerializedState) = undefined;
    if (maybe_parsed) |p| {
        parsed = p;
    } else {
        // No on-disk state — seed from embedded shipped asset.
        parsed = try std.json.parseFromSlice(SerializedState, allocator, shipped.registry_state_json, .{ .ignore_unknown_fields = true });
    }
    defer parsed.deinit();

    var it = parsed.value.registries.map.iterator();
    while (it.next()) |kv| {
        const name_dup = try allocator.dupe(u8, kv.key_ptr.*);
        errdefer allocator.free(name_dup);

        const src = kv.value_ptr.*;
        var entries = try allocator.alloc(Entry, src.entries.len);
        var e_pop: usize = 0;
        errdefer {
            for (entries[0..e_pop]) |e| e.deinit(allocator);
            allocator.free(entries);
        }
        for (src.entries, 0..) |e, i| {
            entries[i] = try e.clone(allocator);
            e_pop = i + 1;
        }

        const manifest: ?models.Manifest = if (src.manifest) |m| blk: {
            var roms = try allocator.alloc(models.RomMetadata, m.roms.len);
            var r_pop: usize = 0;
            errdefer {
                for (roms[0..r_pop]) |r| r.deinit(allocator);
                allocator.free(roms);
            }
            for (m.roms, 0..) |r, i| {
                roms[i] = try r.clone(allocator);
                r_pop = i + 1;
            }
            break :blk models.Manifest{ .spec_version = m.spec_version, .roms = roms };
        } else null;

        const rs = RegistryState{
            .repo = try allocator.dupe(u8, src.repo),
            .last_synced = src.last_synced,
            .entries = entries,
            .manifest = manifest,
        };
        try state.registries.put(allocator, name_dup, rs);
    }

    return state;
}

pub fn saveState(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8, state: *const State) !void {
    const path = try statePath(allocator, app_data_root);
    defer allocator.free(path);

    // Build serialized view. We use an ArrayHashMap whose entries alias into State's storage.
    var view = SerializedState{};
    defer view.registries.map.deinit(allocator);

    var it = state.registries.iterator();
    while (it.next()) |kv| {
        try view.registries.map.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
    }

    try cache.writeJsonAtomic(io, allocator, path, view);
}

// Sync one registry by name. Network failure propagates; caller can decide.
pub fn syncRegistry(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *State,
    registry_name: []const u8,
    config: config_mod.Config,
    db_cache: *chip8_db_cache.State,
) !void {
    const reg = findRegistry(config, registry_name) orelse return error.UnknownRegistry;
    try syncOne(io, allocator, state, reg, config, db_cache);
}

// Sync all registries; continue-on-error so a single flaky repo doesn't block.
pub fn syncAll(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *State,
    config: config_mod.Config,
    db_cache: *chip8_db_cache.State,
) !void {
    for (config.known_registries) |reg| {
        syncOne(io, allocator, state, reg, config, db_cache) catch {
            // Best-effort: keep going. CLI surfaces status.
        };
    }
}

fn syncOne(
    io: std.Io,
    allocator: std.mem.Allocator,
    state: *State,
    reg: models.KnownRegistry,
    config: config_mod.Config,
    db_cache: *chip8_db_cache.State,
) !void {
    // Collect previous entries indexed by path for git_sha-based reuse.
    const prev: ?*const RegistryState = state.get(reg.name);

    var new_entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (new_entries.items) |e| e.deinit(allocator);
        new_entries.deinit(allocator);
    }

    for (reg.globs) |glob_pattern| {
        const dir_part = std.fs.path.dirname(glob_pattern) orelse "";
        const pattern = std.fs.path.basename(glob_pattern);

        const contents = github.listContents(io, allocator, reg.repo_user(), reg.repo_name(), dir_part, config.github_token) catch |err| return err;
        defer github.freeEntries(allocator, contents);

        for (contents) |c| {
            if (!std.mem.eql(u8, c.type, "file")) continue;
            if (!globMatch(pattern, c.name)) continue;

            if (findPrev(prev, c.path)) |prev_entry| {
                if (std.mem.eql(u8, prev_entry.git_sha, c.sha)) {
                    var reused = try prev_entry.clone(allocator);
                    // Keep download_url in sync with the listing even when
                    // the git_sha is unchanged — older state may have stored
                    // a null here before we tracked the field.
                    if (c.download_url) |du| {
                        if (reused.download_url) |old| allocator.free(old);
                        reused.download_url = try allocator.dupe(u8, du);
                    }
                    try new_entries.append(allocator, reused);
                    continue;
                }
            }

            const dl_url = c.download_url orelse continue;
            const rom_bytes = network.fetchBytes(io, allocator, dl_url) catch continue;
            defer allocator.free(rom_bytes);

            const sha1_bin = models.computeRomSha1(rom_bytes);
            const sha1_hex = try models.sha1HexAlloc(allocator, sha1_bin);
            errdefer allocator.free(sha1_hex);

            var db_hash: ?[]const u8 = null;
            if (db_cache.lookup(sha1_hex) != null) {
                db_hash = try allocator.dupe(u8, sha1_hex);
            } else if (!db_cache.isKnownMiss(sha1_hex)) {
                _ = chip8_db_cache.fetchAndCache(io, allocator, db_cache, sha1_hex) catch null;
                if (db_cache.lookup(sha1_hex) != null) {
                    db_hash = try allocator.dupe(u8, sha1_hex);
                }
            }

            try new_entries.append(allocator, .{
                .path = try allocator.dupe(u8, c.path),
                .git_sha = try allocator.dupe(u8, c.sha),
                .sha1 = sha1_hex,
                .size = c.size,
                .chip8_db_hash = db_hash,
                .download_url = if (c.download_url) |du| try allocator.dupe(u8, du) else null,
            });
        }
    }

    // Replace registry state atomically.
    const name_dup = try allocator.dupe(u8, reg.name);
    errdefer allocator.free(name_dup);
    const repo_dup = try allocator.dupe(u8, reg.repo);
    errdefer allocator.free(repo_dup);

    const owned_entries = try new_entries.toOwnedSlice(allocator);
    const new_state = RegistryState{
        .repo = repo_dup,
        .last_synced = std.Io.Clock.now(.real, io).toMilliseconds(),
        .entries = owned_entries,
        .manifest = null,
    };

    if (state.registries.fetchRemove(reg.name)) |kv| {
        allocator.free(kv.key);
        kv.value.deinit(allocator);
    }
    try state.registries.put(allocator, name_dup, new_state);
}

fn findRegistry(config: config_mod.Config, name: []const u8) ?models.KnownRegistry {
    for (config.known_registries) |reg| {
        if (std.mem.eql(u8, reg.name, name)) return reg;
    }
    return null;
}

fn findPrev(prev: ?*const RegistryState, path: []const u8) ?Entry {
    const r = prev orelse return null;
    for (r.entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return e;
    }
    return null;
}

// Single-level glob ('*' matches any non-slash run). No '**'.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Fast path for literal names.
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return std.mem.eql(u8, pattern, name);
    }
    return matchHere(pattern, name);
}

fn matchHere(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    while (p < pattern.len) {
        if (pattern[p] == '*') {
            // Skip consecutive stars.
            while (p < pattern.len and pattern[p] == '*') p += 1;
            if (p == pattern.len) return true;
            // Try every suffix of name.
            while (n <= name.len) : (n += 1) {
                if (matchHere(pattern[p..], name[n..])) return true;
            }
            return false;
        }
        if (n >= name.len) return false;
        if (pattern[p] != name[n]) return false;
        p += 1;
        n += 1;
    }
    return n == name.len;
}

test "glob match basics" {
    try std.testing.expect(globMatch("*.ch8", "pong.ch8"));
    try std.testing.expect(!globMatch("*.ch8", "pong.rom"));
    try std.testing.expect(globMatch("pong.ch8", "pong.ch8"));
    try std.testing.expect(globMatch("p*.ch8", "pong.ch8"));
    try std.testing.expect(!globMatch("p*.ch8", "xong.ch8"));
}

pub const SyncError = error{ UnknownRegistry } || std.mem.Allocator.Error;
