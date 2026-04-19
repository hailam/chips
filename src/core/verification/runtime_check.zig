const std = @import("std");
const models = @import("../registry_models.zig");
const emulation = @import("../emulation_config.zig");
const assembly = @import("../assembly.zig");
const chip8_db_cache = @import("../chip8_db_cache.zig");
const spec = @import("oracle/spec.zig");
const ground_truth = @import("oracle/ground_truth.zig");

// Resolves the configuration a ROM should run under, consulting (in order):
//   1. chip-8-database match via SHA-1 → full RomConfig bundle.
//   2. Heuristic inference (assembly.inferProfileDetailed) → quirks + platform.
//      Non-quirk fields fall back to the inferred platform's defaults.
//   3. Fallback to the user's selected profile's platform defaults.
//
// A sidecar `config_override`, when present, layers on top of everything
// with any non-null fields winning.

pub const Layer = enum {
    database_match, // full bundle came from chip-8-database
    inference, // heuristic guess, platform defaults elsewhere
    fallback, // nothing matched; used user profile
};

pub const EmbeddedTitleMismatch = struct {
    expected: []const u8,
    // Caller can free this when done; contains raw bytes pulled from the ROM
    // at the embedded-title offset. Empty slice means the offset was out of
    // range or no readable ASCII was found.
    found: []const u8,
};

pub const ConfigResolution = struct {
    layer: Layer,
    config: ground_truth.RomConfig,

    // Layer-specific details for notification formatting.
    confidence: f32 = 1.0,
    reasoning: ?[]const u8 = null,
    override_applied: bool = false,
    embedded_title_mismatch: ?EmbeddedTitleMismatch = null,

    pub fn deinit(self: ConfigResolution, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
        if (self.embedded_title_mismatch) |m| {
            allocator.free(m.expected);
            allocator.free(m.found);
        }
    }
};

// Entry point for the ROM loader.
//
// `user_profile` is the profile the user asked for on the command line (or
// null if they didn't). `sidecar_override` is from InstalledRom.config_override.
// `auto_apply` gates whether a database match is turned into a resolution or
// left as metadata-only (caller uses fallback) — the spec's
// `auto_apply_db_config` flag.
pub fn resolveConfigForRom(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    user_profile: ?emulation.QuirkProfile,
    sidecar_override: ?models.RomConfigOverride,
    db_cache: *const chip8_db_cache.State,
    auto_apply: bool,
) !ConfigResolution {
    const sha1_bin = models.computeRomSha1(rom_bytes);
    const sha1_hex = try models.sha1HexAlloc(allocator, sha1_bin);
    defer allocator.free(sha1_hex);

    // (1) database_match
    if (auto_apply) {
        if (db_cache.lookup(sha1_hex)) |entry| {
            const platform_id = pickPlatformForEntry(entry, user_profile);
            if (ground_truth.expectedConfigFor(entry, platform_id)) |cfg| {
                const cloned = try cfg.clone(allocator);
                var resolution = ConfigResolution{
                    .layer = .database_match,
                    .config = cloned,
                    .confidence = 1.0,
                };
                if (entry.embedded_title) |expected| {
                    if (try embeddedTitleMismatch(allocator, rom_bytes, expected)) |m| {
                        resolution.embedded_title_mismatch = m;
                    }
                }
                try applyOverride(&resolution, sidecar_override, allocator);
                return resolution;
            }
        }
    }

    // (2) inference
    const detailed = assembly.inferProfileDetailed(rom_bytes);
    if (detailed.confidence >= 0.5) {
        const platform_id = detailed.platform_id orelse emulation.profileToPlatformId(detailed.profile);
        const inferred_platform = spec.findPlatform(platform_id) orelse return fallbackFromProfile(allocator, user_profile, sidecar_override);

        const cfg = ground_truth.RomConfig{
            .platform = try allocator.dupe(u8, inferred_platform.id),
            .quirks = inferred_platform.quirks,
            .tickrate = inferred_platform.default_tickrate,
        };
        var resolution = ConfigResolution{
            .layer = .inference,
            .config = cfg,
            .confidence = detailed.confidence,
            .reasoning = detailed.reasoning,
        };
        try applyOverride(&resolution, sidecar_override, allocator);
        return resolution;
    }

    // (3) fallback
    return try fallbackFromProfile(allocator, user_profile, sidecar_override);
}

fn fallbackFromProfile(
    allocator: std.mem.Allocator,
    user_profile: ?emulation.QuirkProfile,
    sidecar_override: ?models.RomConfigOverride,
) !ConfigResolution {
    const profile = user_profile orelse .modern;
    const platform_id = emulation.profileToPlatformId(profile);
    const p = spec.findPlatform(platform_id).?;
    const cfg = ground_truth.RomConfig{
        .platform = try allocator.dupe(u8, p.id),
        .quirks = p.quirks,
        .tickrate = p.default_tickrate,
    };
    var resolution = ConfigResolution{
        .layer = .fallback,
        .config = cfg,
        .confidence = 0.0,
        .reasoning = "no database match and inference inconclusive",
    };
    try applyOverride(&resolution, sidecar_override, allocator);
    return resolution;
}

// Choose a platform from a database entry's preferred list. If the user
// explicitly requested a profile, prefer the entry's platform that matches
// it; otherwise take the first preference.
fn pickPlatformForEntry(entry: models.Chip8DbEntry, user_profile: ?emulation.QuirkProfile) []const u8 {
    if (user_profile) |p| {
        const want = emulation.profileToPlatformId(p);
        for (entry.platforms) |ep| {
            if (std.mem.eql(u8, ep, want)) return ep;
        }
    }
    if (entry.platforms.len > 0) return entry.platforms[0];
    return "originalChip8";
}

fn applyOverride(
    resolution: *ConfigResolution,
    override: ?models.RomConfigOverride,
    allocator: std.mem.Allocator,
) !void {
    const o = override orelse return;
    resolution.override_applied = true;
    if (o.platform) |new_plat| {
        allocator.free(resolution.config.platform);
        resolution.config.platform = try allocator.dupe(u8, new_plat);
        if (spec.findPlatform(new_plat)) |p| {
            resolution.config.quirks = p.quirks;
            resolution.config.tickrate = p.default_tickrate;
        }
    }
    if (o.quirks) |q| resolution.config.quirks = spec.applyQuirkOverride(resolution.config.quirks, q);
    if (o.tickrate) |t| resolution.config.tickrate = t;
    if (o.start_address) |a| resolution.config.start_address = a;
    if (o.screen_rotation) |r| resolution.config.screen_rotation = r;
    if (o.font_style) |f| {
        if (resolution.config.font_style) |old| allocator.free(old);
        resolution.config.font_style = try allocator.dupe(u8, f);
    }
}

// Compare the bytes at a well-known offset to the database's embedded_title.
// The database doesn't specify an offset formally — we scan the first 512
// bytes for a null-terminated ASCII run that matches. A miss returns null
// (no mismatch diagnostic); a visible-but-different run returns what we saw.
fn embeddedTitleMismatch(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    expected: []const u8,
) !?EmbeddedTitleMismatch {
    if (expected.len == 0 or rom_bytes.len == 0) return null;
    const scan_len = @min(rom_bytes.len, 512);
    var best_start: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < scan_len) : (i += 1) {
        if (!std.ascii.isPrint(rom_bytes[i])) continue;
        var j = i;
        while (j < scan_len and std.ascii.isPrint(rom_bytes[j])) : (j += 1) {}
        const run_len = j - i;
        if (run_len > best_len and run_len >= 4) {
            best_start = i;
            best_len = run_len;
        }
        i = j;
    }

    const found = rom_bytes[best_start .. best_start + best_len];
    if (std.mem.eql(u8, found, expected)) return null;
    return .{
        .expected = try allocator.dupe(u8, expected),
        .found = try allocator.dupe(u8, found),
    };
}

test "resolveConfigForRom uses inference for marker-free ROM" {
    const allocator = std.testing.allocator;
    var cache = chip8_db_cache.State.init(allocator);
    defer cache.deinit();

    // No markers → heuristic v2 returns vip_legacy/originalChip8 with
    // confidence >= 0.5, so the inference layer wins.
    const rom = [_]u8{0} ** 32;
    const res = try resolveConfigForRom(allocator, &rom, null, null, &cache, true);
    defer res.deinit(allocator);
    try std.testing.expect(res.layer == .inference);
    try std.testing.expectEqualStrings("originalChip8", res.config.platform);
}

test "resolveConfigForRom picks inference when confidence high" {
    const allocator = std.testing.allocator;
    var cache = chip8_db_cache.State.init(allocator);
    defer cache.deinit();

    // F000 marker → XO-CHIP with high confidence.
    const rom = [_]u8{ 0xF0, 0x00, 0x12, 0x34 };
    const res = try resolveConfigForRom(allocator, &rom, null, null, &cache, true);
    defer res.deinit(allocator);
    try std.testing.expect(res.layer == .inference);
    try std.testing.expectEqualStrings("xochip", res.config.platform);
}
