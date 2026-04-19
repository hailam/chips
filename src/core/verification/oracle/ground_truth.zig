const std = @import("std");
const models = @import("../../registry_models.zig");
const spec = @import("spec.zig");

// Verification-facing wrapper over a Chip8DbEntry. Exposes the fully-resolved
// configuration bundle for a given (sha1, platform) — platform defaults
// layered with per-ROM overrides from quirkyPlatforms and top-level per-ROM
// fields.
//
// All values here are the authoritative ORACLE for verification. Runtime
// code consumes these via `runtime_check.zig`.

pub const RomConfig = struct {
    platform: []const u8,
    quirks: spec.Quirks,
    tickrate: u32,
    start_address: u16 = spec.DEFAULT_START_ADDRESS,
    screen_rotation: u16 = 0,
    font_style: ?[]const u8 = null,
    touch_input_mode: ?[]const u8 = null,
    keys: ?models.DbKeys = null,
    colors: ?models.DbColors = null,
    embedded_title: ?[]const u8 = null,

    // Used by callers that need a stable copy (e.g. freeing the source entry).
    pub fn clone(self: RomConfig, allocator: std.mem.Allocator) !RomConfig {
        return .{
            .platform = try allocator.dupe(u8, self.platform),
            .quirks = self.quirks,
            .tickrate = self.tickrate,
            .start_address = self.start_address,
            .screen_rotation = self.screen_rotation,
            .font_style = if (self.font_style) |v| try allocator.dupe(u8, v) else null,
            .touch_input_mode = if (self.touch_input_mode) |v| try allocator.dupe(u8, v) else null,
            .keys = self.keys,
            .colors = if (self.colors) |c| try c.clone(allocator) else null,
            .embedded_title = if (self.embedded_title) |v| try allocator.dupe(u8, v) else null,
        };
    }

    pub fn deinit(self: RomConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.platform);
        if (self.font_style) |v| allocator.free(v);
        if (self.touch_input_mode) |v| allocator.free(v);
        if (self.colors) |c| c.deinit(allocator);
        if (self.embedded_title) |v| allocator.free(v);
    }
};

// Build a RomConfig by layering, in order:
//   1. spec.PLATFORMS[platform_id] — base quirks, default tickrate
//   2. entry.quirky_platforms[platform_id] — ROM-specific quirk overrides
//   3. entry.{tickrate, start_address, screen_rotation, font_style, ...}
//
// Returns null if platform_id isn't a known platform.
pub fn expectedConfigFor(entry: models.Chip8DbEntry, platform_id: []const u8) ?RomConfig {
    const platform = spec.findPlatform(platform_id) orelse return null;

    // Layer 2: check for a quirkyPlatforms override keyed by platform_id.
    var quirks = platform.quirks;
    for (entry.quirky_platforms) |qp| {
        if (std.mem.eql(u8, qp.platform, platform_id)) {
            quirks = spec.applyQuirkOverride(platform.quirks, qp.quirks);
            break;
        }
    }

    return .{
        .platform = platform.id,
        .quirks = quirks,
        .tickrate = entry.tickrate orelse platform.default_tickrate,
        .start_address = entry.start_address orelse spec.DEFAULT_START_ADDRESS,
        .screen_rotation = entry.screen_rotation orelse 0,
        .font_style = entry.font_style,
        .touch_input_mode = entry.touch_input_mode,
        .keys = entry.keys,
        .colors = entry.colors,
        .embedded_title = entry.embedded_title,
    };
}

pub fn expectedQuirksFor(entry: models.Chip8DbEntry, platform_id: []const u8) ?spec.Quirks {
    const cfg = expectedConfigFor(entry, platform_id) orelse return null;
    return cfg.quirks;
}

// Ordered list of targeted platforms from the ROM entry, most-desired first.
pub fn platformsFor(entry: models.Chip8DbEntry) []const []const u8 {
    return entry.platforms;
}

// Walk the ROM's ordered platform preferences; return the first platform id
// that appears in the caller-supplied supported list. Implements the
// "XO-CHIP preferred but SCHIP also works" resolution rule.
pub fn preferredPlatformFor(
    entry: models.Chip8DbEntry,
    supported: []const []const u8,
) ?[]const u8 {
    for (entry.platforms) |ep| {
        for (supported) |sp| {
            if (std.mem.eql(u8, ep, sp)) return ep;
        }
    }
    return null;
}

// --- tests ---

fn dummyEntry(platforms: []const []const u8) models.Chip8DbEntry {
    return .{
        .title = "t",
        .description = "d",
        .release = "r",
        .authors = &.{},
        .platforms = platforms,
    };
}

test "expectedConfigFor returns null for unknown platform" {
    const e = dummyEntry(&.{"originalChip8"});
    try std.testing.expect(expectedConfigFor(e, "nosuchplatform") == null);
}

test "expectedConfigFor uses platform defaults with no overrides" {
    const e = dummyEntry(&.{"originalChip8"});
    const cfg = expectedConfigFor(e, "originalChip8").?;
    try std.testing.expectEqual(@as(u32, 15), cfg.tickrate);
    try std.testing.expect(cfg.quirks.vblank);
    try std.testing.expect(!cfg.quirks.shift);
    try std.testing.expectEqual(@as(u16, 0x200), cfg.start_address);
}

test "expectedConfigFor applies per-ROM tickrate override" {
    var e = dummyEntry(&.{"originalChip8"});
    e.tickrate = 30;
    const cfg = expectedConfigFor(e, "originalChip8").?;
    try std.testing.expectEqual(@as(u32, 30), cfg.tickrate);
}

test "expectedConfigFor applies quirkyPlatforms override" {
    const qp = &[_]models.QuirkyPlatformOverride{.{
        .platform = "originalChip8",
        .quirks = .{ .shift = true, .vblank = false },
    }};
    var e = dummyEntry(&.{"originalChip8"});
    e.quirky_platforms = qp;
    const cfg = expectedConfigFor(e, "originalChip8").?;
    try std.testing.expect(cfg.quirks.shift); // overridden
    try std.testing.expect(!cfg.quirks.vblank); // overridden
    try std.testing.expect(cfg.quirks.logic); // inherited from platform default
}

test "expectedConfigFor applies startAddress for ETI-660 case" {
    var e = dummyEntry(&.{"originalChip8"});
    e.start_address = 0x600;
    const cfg = expectedConfigFor(e, "originalChip8").?;
    try std.testing.expectEqual(@as(u16, 0x600), cfg.start_address);
}

test "preferredPlatformFor walks in order, returns first supported" {
    const e = dummyEntry(&[_][]const u8{ "xochip", "superchip", "modernChip8" });
    const supported_no_xo = &[_][]const u8{ "originalChip8", "superchip", "modernChip8" };
    const pick = preferredPlatformFor(e, supported_no_xo).?;
    try std.testing.expectEqualStrings("superchip", pick);

    const supported_xo = &[_][]const u8{ "xochip", "superchip" };
    try std.testing.expectEqualStrings("xochip", preferredPlatformFor(e, supported_xo).?);

    const supported_none = &[_][]const u8{"chip8x"};
    try std.testing.expect(preferredPlatformFor(e, supported_none) == null);
}
