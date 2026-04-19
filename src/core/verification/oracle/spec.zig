const std = @import("std");
const models = @import("../../registry_models.zig");

// CHIP-8 spec constants and platform definitions mirrored from
// chip-8-database (database/platforms.json, database/quirks.json). Treat the
// upstream files as authoritative — if they change, regenerate this file.
//
// Source: https://github.com/chip-8/chip-8-database @ master

pub const DISPLAY_DEFAULT_W: u16 = 64;
pub const DISPLAY_DEFAULT_H: u16 = 32;
pub const TIMER_FREQUENCY_HZ: u16 = 60;
pub const DEFAULT_START_ADDRESS: u16 = 0x200;
pub const ETI660_START_ADDRESS: u16 = 0x600;
pub const FONT_SPRITE_START: u16 = 0x050;

// Full quirk-flag set. All fields are concrete booleans (no optionals):
// this represents the RESOLVED quirk set for a specific platform, not a
// partial override.
pub const Quirks = struct {
    shift: bool,
    memoryIncrementByX: bool,
    memoryLeaveIUnchanged: bool,
    wrap: bool,
    jump: bool,
    vblank: bool,
    logic: bool,
};

pub const Platform = struct {
    id: []const u8,
    display_resolutions: []const []const u8,
    default_tickrate: u32,
    quirks: Quirks,
};

// Mirror of database/platforms.json. Order preserved.
pub const PLATFORMS: []const Platform = &.{
    .{
        .id = "originalChip8",
        .display_resolutions = &.{"64x32"},
        .default_tickrate = 15,
        .quirks = .{ .shift = false, .memoryIncrementByX = false, .memoryLeaveIUnchanged = false, .wrap = false, .jump = false, .vblank = true, .logic = true },
    },
    .{
        .id = "hybridVIP",
        .display_resolutions = &.{"64x32"},
        .default_tickrate = 15,
        .quirks = .{ .shift = false, .memoryIncrementByX = false, .memoryLeaveIUnchanged = false, .wrap = false, .jump = false, .vblank = true, .logic = true },
    },
    .{
        .id = "modernChip8",
        .display_resolutions = &.{"64x32"},
        .default_tickrate = 12,
        .quirks = .{ .shift = false, .memoryIncrementByX = false, .memoryLeaveIUnchanged = false, .wrap = false, .jump = false, .vblank = false, .logic = false },
    },
    .{
        .id = "chip8x",
        .display_resolutions = &.{"64x32"},
        .default_tickrate = 15,
        .quirks = .{ .shift = false, .memoryIncrementByX = false, .memoryLeaveIUnchanged = false, .wrap = false, .jump = false, .vblank = true, .logic = true },
    },
    .{
        .id = "chip48",
        .display_resolutions = &.{"64x32"},
        .default_tickrate = 30,
        .quirks = .{ .shift = true, .memoryIncrementByX = true, .memoryLeaveIUnchanged = false, .wrap = false, .jump = true, .vblank = false, .logic = false },
    },
    .{
        .id = "superchip1",
        .display_resolutions = &.{ "64x32", "128x64" },
        .default_tickrate = 30,
        .quirks = .{ .shift = true, .memoryIncrementByX = true, .memoryLeaveIUnchanged = false, .wrap = false, .jump = true, .vblank = false, .logic = false },
    },
    .{
        .id = "superchip",
        .display_resolutions = &.{ "64x32", "128x64" },
        .default_tickrate = 30,
        // Upstream omits memoryIncrementByX for superchip/megachip8; the schema
        // defaults non-specified quirks to false. Captured explicitly here.
        .quirks = .{ .shift = true, .memoryIncrementByX = false, .memoryLeaveIUnchanged = true, .wrap = false, .jump = true, .vblank = false, .logic = false },
    },
    .{
        .id = "megachip8",
        .display_resolutions = &.{ "64x32", "128x64", "256x192" },
        .default_tickrate = 1000,
        .quirks = .{ .shift = true, .memoryIncrementByX = false, .memoryLeaveIUnchanged = true, .wrap = false, .jump = true, .vblank = false, .logic = false },
    },
    .{
        .id = "xochip",
        .display_resolutions = &.{ "64x32", "128x64" },
        .default_tickrate = 100,
        .quirks = .{ .shift = false, .memoryIncrementByX = false, .memoryLeaveIUnchanged = false, .wrap = true, .jump = false, .vblank = false, .logic = false },
    },
};

pub fn findPlatform(id: []const u8) ?*const Platform {
    for (PLATFORMS) |*p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

// Apply a partial override (from a ROM's quirkyPlatforms entry) on top of
// the platform's base quirks. Fields that are null in the override are
// inherited from the base.
pub fn applyQuirkOverride(base: Quirks, override: models.QuirkSet) Quirks {
    return .{
        .shift = override.shift orelse base.shift,
        .memoryIncrementByX = override.memoryIncrementByX orelse base.memoryIncrementByX,
        .memoryLeaveIUnchanged = override.memoryLeaveIUnchanged orelse base.memoryLeaveIUnchanged,
        .wrap = override.wrap orelse base.wrap,
        .jump = override.jump orelse base.jump,
        .vblank = override.vblank orelse base.vblank,
        .logic = override.logic orelse base.logic,
    };
}

test "findPlatform resolves known ids" {
    try std.testing.expect(findPlatform("originalChip8") != null);
    try std.testing.expect(findPlatform("xochip") != null);
    try std.testing.expect(findPlatform("nonexistent") == null);
}

test "platform defaults match upstream" {
    const vip = findPlatform("originalChip8").?;
    try std.testing.expectEqual(@as(u32, 15), vip.default_tickrate);
    try std.testing.expect(vip.quirks.vblank);
    try std.testing.expect(vip.quirks.logic);
    try std.testing.expect(!vip.quirks.shift);

    const xo = findPlatform("xochip").?;
    try std.testing.expectEqual(@as(u32, 100), xo.default_tickrate);
    try std.testing.expect(xo.quirks.wrap);
    try std.testing.expect(!xo.quirks.logic);
}

test "applyQuirkOverride only changes specified fields" {
    const base = Quirks{ .shift = false, .memoryIncrementByX = false, .memoryLeaveIUnchanged = false, .wrap = false, .jump = false, .vblank = true, .logic = true };
    const override = models.QuirkSet{ .shift = true, .vblank = false };
    const merged = applyQuirkOverride(base, override);
    try std.testing.expect(merged.shift);
    try std.testing.expect(!merged.vblank);
    try std.testing.expect(merged.logic);
    try std.testing.expect(!merged.jump);
}
