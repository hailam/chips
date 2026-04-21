const std = @import("std");

pub const SPEC_VERSION: u32 = 1;

// Mirrors the chip-8-database quirk flag set
// (https://github.com/chip-8/chip-8-database — database/quirks.json).
// Every flag is optional at the per-ROM override level — null means
// "inherit from platform default".
//
// All 7 flags reach the CPU through runtime_check.emulationConfigFromResolution:
//   shift                   → QuirkFlags.shift_uses_vy (inverted)
//   memoryIncrementByX      → QuirkFlags.memory_increment (3-state enum)
//   memoryLeaveIUnchanged   → QuirkFlags.memory_increment (3-state enum)
//   wrap                    → QuirkFlags.draw_wrap
//   jump                    → QuirkFlags.jump_uses_vx
//   vblank                  → QuirkFlags.vblank_wait
//   logic                   → QuirkFlags.logic_ops_clear_vf
//
// If upstream adds an 8th quirk, the compile-time test below will need to
// be updated alongside emulationConfigFromResolution to route it — that's
// the safety net against silent drops at import time.
pub const QuirkSet = struct {
    shift: ?bool = null,
    memoryIncrementByX: ?bool = null,
    memoryLeaveIUnchanged: ?bool = null,
    wrap: ?bool = null,
    jump: ?bool = null,
    vblank: ?bool = null,
    logic: ?bool = null,
};

test "QuirkSet matches the upstream 7-quirk schema" {
    // Fails loud if someone adds or removes a field without also updating
    // runtime_check.emulationConfigFromResolution to route it. Prevents the
    // audit's "flag silently dropped at import" regression.
    const fields = std.meta.fields(QuirkSet);
    try std.testing.expectEqual(@as(usize, 7), fields.len);
    const expected = [_][]const u8{ "shift", "memoryIncrementByX", "memoryLeaveIUnchanged", "wrap", "jump", "vblank", "logic" };
    inline for (fields, expected) |f, name| {
        try std.testing.expectEqualStrings(name, f.name);
    }
}

pub const DbColors = struct {
    pixels: ?[]const []const u8 = null,
    buzzer: ?[]const u8 = null,
    silence: ?[]const u8 = null,

    pub fn clone(self: DbColors, allocator: std.mem.Allocator) !DbColors {
        var pixels: ?[]const []const u8 = null;
        if (self.pixels) |src| {
            const dup = try allocator.alloc([]const u8, src.len);
            errdefer allocator.free(dup);
            for (src, 0..) |p, i| dup[i] = try allocator.dupe(u8, p);
            pixels = dup;
        }
        return .{
            .pixels = pixels,
            .buzzer = if (self.buzzer) |v| try allocator.dupe(u8, v) else null,
            .silence = if (self.silence) |v| try allocator.dupe(u8, v) else null,
        };
    }

    pub fn deinit(self: DbColors, allocator: std.mem.Allocator) void {
        if (self.pixels) |p| {
            for (p) |c| allocator.free(c);
            allocator.free(p);
        }
        if (self.buzzer) |v| allocator.free(v);
        if (self.silence) |v| allocator.free(v);
    }
};

pub const DbKeys = struct {
    up: ?u8 = null,
    down: ?u8 = null,
    left: ?u8 = null,
    right: ?u8 = null,
    a: ?u8 = null,
    b: ?u8 = null,
    player2Up: ?u8 = null,
    player2Down: ?u8 = null,
    player2Left: ?u8 = null,
    player2Right: ?u8 = null,
    player2A: ?u8 = null,
    player2B: ?u8 = null,
};

// Mirrors one key-value pair in `quirkyPlatforms`. The database keys the
// outer object by platform id; we flatten to a list for portability.
pub const QuirkyPlatformOverride = struct {
    platform: []const u8,
    quirks: QuirkSet,

    pub fn clone(self: QuirkyPlatformOverride, allocator: std.mem.Allocator) !QuirkyPlatformOverride {
        return .{
            .platform = try allocator.dupe(u8, self.platform),
            .quirks = self.quirks,
        };
    }

    pub fn deinit(self: QuirkyPlatformOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.platform);
    }
};

pub const Chip8DbEntry = struct {
    title: []const u8,
    description: []const u8,
    release: []const u8,
    authors: []const []const u8,
    platforms: []const []const u8 = &.{},
    file: ?[]const u8 = null,
    embedded_title: ?[]const u8 = null,
    tickrate: ?u32 = null,
    start_address: ?u16 = null,
    screen_rotation: ?u16 = null,
    font_style: ?[]const u8 = null,
    touch_input_mode: ?[]const u8 = null,
    keys: ?DbKeys = null,
    colors: ?DbColors = null,
    quirky_platforms: []const QuirkyPlatformOverride = &.{},

    pub fn clone(self: Chip8DbEntry, allocator: std.mem.Allocator) !Chip8DbEntry {
        var authors = try allocator.alloc([]const u8, self.authors.len);
        errdefer allocator.free(authors);
        for (self.authors, 0..) |a, i| authors[i] = try allocator.dupe(u8, a);

        var platforms = try allocator.alloc([]const u8, self.platforms.len);
        errdefer allocator.free(platforms);
        for (self.platforms, 0..) |p, i| platforms[i] = try allocator.dupe(u8, p);

        var quirky = try allocator.alloc(QuirkyPlatformOverride, self.quirky_platforms.len);
        errdefer allocator.free(quirky);
        for (self.quirky_platforms, 0..) |q, i| quirky[i] = try q.clone(allocator);

        return .{
            .title = try allocator.dupe(u8, self.title),
            .description = try allocator.dupe(u8, self.description),
            .release = try allocator.dupe(u8, self.release),
            .authors = authors,
            .platforms = platforms,
            .file = if (self.file) |v| try allocator.dupe(u8, v) else null,
            .embedded_title = if (self.embedded_title) |v| try allocator.dupe(u8, v) else null,
            .tickrate = self.tickrate,
            .start_address = self.start_address,
            .screen_rotation = self.screen_rotation,
            .font_style = if (self.font_style) |v| try allocator.dupe(u8, v) else null,
            .touch_input_mode = if (self.touch_input_mode) |v| try allocator.dupe(u8, v) else null,
            .keys = self.keys,
            .colors = if (self.colors) |c| try c.clone(allocator) else null,
            .quirky_platforms = quirky,
        };
    }

    pub fn deinit(self: Chip8DbEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.release);
        for (self.authors) |a| allocator.free(a);
        allocator.free(self.authors);
        for (self.platforms) |p| allocator.free(p);
        allocator.free(self.platforms);
        if (self.file) |v| allocator.free(v);
        if (self.embedded_title) |v| allocator.free(v);
        if (self.font_style) |v| allocator.free(v);
        if (self.touch_input_mode) |v| allocator.free(v);
        if (self.colors) |c| c.deinit(allocator);
        for (self.quirky_platforms) |q| q.deinit(allocator);
        allocator.free(self.quirky_platforms);
    }
};

pub const RomMetadata = struct {
    id: []const u8,
    file: []const u8,
    source_url: ?[]const u8 = null,
    raw_url: ?[]const u8 = null,
    sha1: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    chip8_db_entry: ?Chip8DbEntry = null,

    pub fn clone(self: RomMetadata, allocator: std.mem.Allocator) !RomMetadata {
        var tags: ?[]const []const u8 = null;
        if (self.tags) |t| {
            var new_tags = try allocator.alloc([]const u8, t.len);
            errdefer allocator.free(new_tags);
            for (t, 0..) |tag, i| new_tags[i] = try allocator.dupe(u8, tag);
            tags = new_tags;
        }
        return .{
            .id = try allocator.dupe(u8, self.id),
            .file = try allocator.dupe(u8, self.file),
            .source_url = if (self.source_url) |v| try allocator.dupe(u8, v) else null,
            .raw_url = if (self.raw_url) |v| try allocator.dupe(u8, v) else null,
            .sha1 = if (self.sha1) |v| try allocator.dupe(u8, v) else null,
            .tags = tags,
            .chip8_db_entry = if (self.chip8_db_entry) |e| try e.clone(allocator) else null,
        };
    }

    pub fn deinit(self: RomMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.file);
        if (self.source_url) |v| allocator.free(v);
        if (self.raw_url) |v| allocator.free(v);
        if (self.sha1) |v| allocator.free(v);
        if (self.tags) |tags| {
            for (tags) |tag| allocator.free(tag);
            allocator.free(tags);
        }
        if (self.chip8_db_entry) |e| e.deinit(allocator);
    }
};

pub const Manifest = struct {
    spec_version: u32 = SPEC_VERSION,
    roms: []RomMetadata,

    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        for (self.roms) |rom| rom.deinit(allocator);
        allocator.free(self.roms);
    }
};

// Per-ROM user override of the resolved RomConfig. All fields optional;
// anything set here wins over both database matches and inference. Stored
// in the installed ROM's sidecar JSON.
pub const RomConfigOverride = struct {
    platform: ?[]const u8 = null,
    quirks: ?QuirkSet = null,
    tickrate: ?u32 = null,
    start_address: ?u16 = null,
    screen_rotation: ?u16 = null,
    font_style: ?[]const u8 = null,

    pub fn clone(self: RomConfigOverride, allocator: std.mem.Allocator) !RomConfigOverride {
        return .{
            .platform = if (self.platform) |v| try allocator.dupe(u8, v) else null,
            .quirks = self.quirks,
            .tickrate = self.tickrate,
            .start_address = self.start_address,
            .screen_rotation = self.screen_rotation,
            .font_style = if (self.font_style) |v| try allocator.dupe(u8, v) else null,
        };
    }

    pub fn deinit(self: RomConfigOverride, allocator: std.mem.Allocator) void {
        if (self.platform) |v| allocator.free(v);
        if (self.font_style) |v| allocator.free(v);
    }
};

pub const InstalledRom = struct {
    metadata: RomMetadata,
    local: Local,
    config_override: ?RomConfigOverride = null,

    pub const Local = struct {
        path: []const u8,
        installed_at: i64,
        sha1: []const u8,
        source: Source,
    };

    pub const Source = union(enum) {
        direct_url: []const u8,
        repo_file: RepoFile,
        repo_glob: RepoGlob,
        manifest_entry: ManifestEntry,
        known_registry: KnownRegistryEntry,
        local_import: []const u8,

        pub const RepoFile = struct { user: []const u8, repo: []const u8, path: []const u8 };
        pub const RepoGlob = struct { user: []const u8, repo: []const u8, pattern: []const u8 };
        pub const ManifestEntry = struct { user: []const u8, repo: []const u8, id: []const u8 };
        pub const KnownRegistryEntry = struct { name: []const u8, user: []const u8, repo: []const u8, path: []const u8 };

        pub fn clone(self: Source, allocator: std.mem.Allocator) !Source {
            return switch (self) {
                .direct_url => |v| .{ .direct_url = try allocator.dupe(u8, v) },
                .repo_file => |v| .{ .repo_file = .{
                    .user = try allocator.dupe(u8, v.user),
                    .repo = try allocator.dupe(u8, v.repo),
                    .path = try allocator.dupe(u8, v.path),
                } },
                .repo_glob => |v| .{ .repo_glob = .{
                    .user = try allocator.dupe(u8, v.user),
                    .repo = try allocator.dupe(u8, v.repo),
                    .pattern = try allocator.dupe(u8, v.pattern),
                } },
                .manifest_entry => |v| .{ .manifest_entry = .{
                    .user = try allocator.dupe(u8, v.user),
                    .repo = try allocator.dupe(u8, v.repo),
                    .id = try allocator.dupe(u8, v.id),
                } },
                .known_registry => |v| .{ .known_registry = .{
                    .name = try allocator.dupe(u8, v.name),
                    .user = try allocator.dupe(u8, v.user),
                    .repo = try allocator.dupe(u8, v.repo),
                    .path = try allocator.dupe(u8, v.path),
                } },
                .local_import => |v| .{ .local_import = try allocator.dupe(u8, v) },
            };
        }

        pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
            switch (self) {
                .direct_url => |v| allocator.free(v),
                .repo_file => |v| {
                    allocator.free(v.user);
                    allocator.free(v.repo);
                    allocator.free(v.path);
                },
                .repo_glob => |v| {
                    allocator.free(v.user);
                    allocator.free(v.repo);
                    allocator.free(v.pattern);
                },
                .manifest_entry => |v| {
                    allocator.free(v.user);
                    allocator.free(v.repo);
                    allocator.free(v.id);
                },
                .known_registry => |v| {
                    allocator.free(v.name);
                    allocator.free(v.user);
                    allocator.free(v.repo);
                    allocator.free(v.path);
                },
                .local_import => |v| allocator.free(v),
            }
        }
    };

    pub fn clone(self: InstalledRom, allocator: std.mem.Allocator) !InstalledRom {
        return .{
            .metadata = try self.metadata.clone(allocator),
            .local = .{
                .path = try allocator.dupe(u8, self.local.path),
                .installed_at = self.local.installed_at,
                .sha1 = try allocator.dupe(u8, self.local.sha1),
                .source = try self.local.source.clone(allocator),
            },
            .config_override = if (self.config_override) |o| try o.clone(allocator) else null,
        };
    }

    pub fn deinit(self: InstalledRom, allocator: std.mem.Allocator) void {
        self.metadata.deinit(allocator);
        allocator.free(self.local.path);
        allocator.free(self.local.sha1);
        self.local.source.deinit(allocator);
        if (self.config_override) |o| o.deinit(allocator);
    }
};

pub const KnownRegistry = struct {
    name: []const u8,
    repo: []const u8,
    globs: []const []const u8,

    pub fn repo_user(self: KnownRegistry) []const u8 {
        var it = std.mem.splitScalar(u8, self.repo, '/');
        return it.next() orelse "";
    }

    pub fn repo_name(self: KnownRegistry) []const u8 {
        var it = std.mem.splitScalar(u8, self.repo, '/');
        _ = it.next();
        return it.next() orelse "";
    }

    pub fn deinit(self: KnownRegistry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.repo);
        for (self.globs) |glob| allocator.free(glob);
        allocator.free(self.globs);
    }
};

pub fn computeRomSha1(rom_data: []const u8) [20]u8 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(rom_data, &digest, .{});
    return digest;
}

pub fn sha1HexAlloc(allocator: std.mem.Allocator, hash: [20]u8) ![]u8 {
    const buf = std.fmt.bytesToHex(&hash, .lower);
    return allocator.dupe(u8, &buf);
}
