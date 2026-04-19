const std = @import("std");

pub const QuirkProfile = enum {
    modern,
    vip_legacy,
    schip_11,
    xo_chip,
    octo_xo,
};

pub const QuirkFlags = struct {
    shift_uses_vy: bool,
    load_store_increment_i: bool,
    logic_ops_clear_vf: bool,
    draw_wrap: bool,
    jump_uses_vx: bool,
    supports_hires: bool,
    supports_xo: bool,
    octo_behavior: bool,
    resolution_switch_clears: bool,
    dxy0_lores_16x16: bool,
    fx30_large_font_hex: bool,
    draw_vf_rowcount_in_hires: bool,
    max_rpl: u8,
};

pub const EmulationConfig = struct {
    quirk_profile: QuirkProfile,
    quirks: QuirkFlags,

    pub fn init(profile: QuirkProfile) EmulationConfig {
        return .{
            .quirk_profile = profile,
            .quirks = profileQuirks(profile),
        };
    }

    pub fn setProfile(self: *EmulationConfig, profile: QuirkProfile) void {
        self.* = init(profile);
    }
};

pub fn profileQuirks(profile: QuirkProfile) QuirkFlags {
    return switch (profile) {
        .modern => .{
            .shift_uses_vy = false,
            .load_store_increment_i = false,
            .logic_ops_clear_vf = true,
            .draw_wrap = true,
            .jump_uses_vx = false,
            .supports_hires = false,
            .supports_xo = false,
            .octo_behavior = false,
            .resolution_switch_clears = false,
            .dxy0_lores_16x16 = false,
            .fx30_large_font_hex = false,
            .draw_vf_rowcount_in_hires = false,
            .max_rpl = 0,
        },
        .vip_legacy => .{
            .shift_uses_vy = true,
            .load_store_increment_i = true,
            .logic_ops_clear_vf = false,
            .draw_wrap = false,
            .jump_uses_vx = false,
            .supports_hires = false,
            .supports_xo = false,
            .octo_behavior = false,
            .resolution_switch_clears = false,
            .dxy0_lores_16x16 = false,
            .fx30_large_font_hex = false,
            .draw_vf_rowcount_in_hires = false,
            .max_rpl = 0,
        },
        .schip_11 => .{
            .shift_uses_vy = false,
            .load_store_increment_i = false,
            .logic_ops_clear_vf = true,
            .draw_wrap = true,
            .jump_uses_vx = true,
            .supports_hires = true,
            .supports_xo = false,
            .octo_behavior = false,
            .resolution_switch_clears = false,
            .dxy0_lores_16x16 = false,
            .fx30_large_font_hex = false,
            .draw_vf_rowcount_in_hires = true,
            .max_rpl = 8,
        },
        .xo_chip => .{
            .shift_uses_vy = false,
            .load_store_increment_i = false,
            .logic_ops_clear_vf = true,
            .draw_wrap = true,
            .jump_uses_vx = false,
            .supports_hires = true,
            .supports_xo = true,
            .octo_behavior = false,
            .resolution_switch_clears = true,
            .dxy0_lores_16x16 = false,
            .fx30_large_font_hex = false,
            .draw_vf_rowcount_in_hires = true,
            .max_rpl = 16,
        },
        .octo_xo => .{
            .shift_uses_vy = false,
            .load_store_increment_i = false,
            .logic_ops_clear_vf = true,
            .draw_wrap = true,
            .jump_uses_vx = false,
            .supports_hires = true,
            .supports_xo = true,
            .octo_behavior = true,
            .resolution_switch_clears = true,
            .dxy0_lores_16x16 = true,
            .fx30_large_font_hex = true,
            .draw_vf_rowcount_in_hires = true,
            .max_rpl = 16,
        },
    };
}

pub fn profileLabel(profile: QuirkProfile) []const u8 {
    return switch (profile) {
        .modern => "MODERN",
        .vip_legacy => "VIP",
        .schip_11 => "SCHIP",
        .xo_chip => "XO",
        .octo_xo => "OCTO",
    };
}

pub fn profileCliName(profile: QuirkProfile) []const u8 {
    return switch (profile) {
        .modern => "modern",
        .vip_legacy => "vip_legacy",
        .schip_11 => "schip_11",
        .xo_chip => "xo_chip",
        .octo_xo => "octo_xo",
    };
}

pub fn parseProfile(name: []const u8) ?QuirkProfile {
    if (std.ascii.eqlIgnoreCase(name, "modern")) return .modern;
    if (std.ascii.eqlIgnoreCase(name, "vip") or std.ascii.eqlIgnoreCase(name, "vip_legacy")) return .vip_legacy;
    if (std.ascii.eqlIgnoreCase(name, "schip") or std.ascii.eqlIgnoreCase(name, "schip_11")) return .schip_11;
    if (std.ascii.eqlIgnoreCase(name, "xo") or std.ascii.eqlIgnoreCase(name, "xo_chip")) return .xo_chip;
    if (std.ascii.eqlIgnoreCase(name, "octo") or std.ascii.eqlIgnoreCase(name, "octo_xo")) return .octo_xo;
    return null;
}

// Maps our internal QuirkProfile to the closest chip-8-database platform id.
// Used by runtime_check to turn a user-selected profile into a platform the
// oracle layer understands.
pub fn profileToPlatformId(profile: QuirkProfile) []const u8 {
    return switch (profile) {
        .modern => "modernChip8",
        .vip_legacy => "originalChip8",
        .schip_11 => "superchip1",
        .xo_chip => "xochip",
        .octo_xo => "xochip",
    };
}

// Inverse — best-effort mapping from a chip-8-database platform id back to
// our internal profile. Returns null for platforms we don't simulate.
pub fn platformIdToProfile(platform_id: []const u8) ?QuirkProfile {
    if (std.mem.eql(u8, platform_id, "originalChip8")) return .vip_legacy;
    if (std.mem.eql(u8, platform_id, "hybridVIP")) return .vip_legacy;
    if (std.mem.eql(u8, platform_id, "modernChip8")) return .modern;
    if (std.mem.eql(u8, platform_id, "chip48")) return .schip_11;
    if (std.mem.eql(u8, platform_id, "superchip1")) return .schip_11;
    if (std.mem.eql(u8, platform_id, "superchip")) return .schip_11;
    if (std.mem.eql(u8, platform_id, "xochip")) return .xo_chip;
    // chip8x / megachip8 — not supported, no direct mapping.
    return null;
}

pub fn profileFromByte(value: u8) ?QuirkProfile {
    return switch (value) {
        0 => .modern,
        1 => .vip_legacy,
        2 => .schip_11,
        3 => .xo_chip,
        4 => .octo_xo,
        else => null,
    };
}
