const std = @import("std");

pub const QuirkProfile = enum {
    modern,
    vip_legacy,
    // CHIP-48 on the HP-48: 64×32 only, shift-VX, Bnnn-uses-VX, FX55/FX65
    // increments I by X (not X+1). Split out from the old generic `schip_11`
    // because the oracle models this platform as a 64×32 device — running
    // it under an SCHIP 1.1 feature set was exposing hires ops it never had.
    chip48,
    // Classic HP-48 SUPER-CHIP 1.0 / 1.1 ("superchip1"). Same post-I
    // behavior as CHIP-48 (increment by X) but adds hires, SCD/SCR/SCL,
    // and FX30 big-font. Matches `chip-8-database` platform `superchip1`.
    schip_legacy,
    // Modern SUPER-CHIP ("superchip"). Differs from schip_legacy on post-I
    // semantics: FX55/FX65 leave I unchanged. Same opcode surface. Matches
    // `chip-8-database` platform `superchip`.
    schip_modern,
    xo_chip,
    octo_xo,
};

// Three-state post-`I` policy for FX55 / FX65. The chip-8-database encodes
// this as a pair of booleans (`memoryIncrementByX`, `memoryLeaveIUnchanged`);
// our runtime collapses that to a single enum so the CPU dispatch stays a
// clean switch and the sidecar-override path has somewhere to land.
//
//   increment_full     — I += X + 1  (VIP / modernChip8 / XO-CHIP / Octo)
//   increment_by_x     — I += X      (CHIP-48, SUPER-CHIP 1.0 / 1.1)
//   leave_i_unchanged  — I stays     (modern SUPER-CHIP, MegaChip8)
pub const MemoryIncrement = enum(u8) {
    increment_full = 0,
    increment_by_x = 1,
    leave_i_unchanged = 2,
};

pub const QuirkFlags = struct {
    shift_uses_vy: bool,
    memory_increment: MemoryIncrement,
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
    // COSMAC VIP synchronizes DRW with the display's vertical refresh: at most
    // one sprite draw per 60Hz frame, the rest are held until vblank. Games
    // from that era (Blinky, Kolumne, ...) use DRW as an implicit frame-rate
    // throttle. Modern / SCHIP / XO-CHIP runtimes don't gate draws.
    vblank_wait: bool,
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

// Values here track chip-8-database/database/platforms.json as the oracle.
// When a flag's boolean doesn't match the upstream platform's `quirks`
// entry, that is a bug — update this table, not the database.
//
// Mapping (our flag ↔ db `quirks.*`):
//   shift_uses_vy        true ↔ db.shift=false   (standard vY source)
//   logic_ops_clear_vf   same ↔ db.logic
//   draw_wrap            same ↔ db.wrap
//   jump_uses_vx         same ↔ db.jump
//   load_store_increment_i approximates db.memoryIncrementByX / memoryLeaveIUnchanged
pub fn profileQuirks(profile: QuirkProfile) QuirkFlags {
    return switch (profile) {
        // modernChip8: shift=false, wrap=false, jump=false, vblank=false, logic=false
        .modern => .{
            .shift_uses_vy = true,
            .memory_increment = .increment_full,
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
            .vblank_wait = false,
        },
        // originalChip8 (Cosmac VIP): shift=false, wrap=false, jump=false, vblank=true, logic=true
        .vip_legacy => .{
            .shift_uses_vy = true,
            .memory_increment = .increment_full,
            .logic_ops_clear_vf = true,
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
            .vblank_wait = true,
        },
        // CHIP-48 on the HP-48 (64x32 only). shift=true, memIncX=true,
        // wrap=false, jump=true, vblank=false, logic=false. No hires, no
        // SCHIP opcodes — hires gating must stay off.
        .chip48 => .{
            .shift_uses_vy = false,
            .memory_increment = .increment_by_x,
            .logic_ops_clear_vf = false,
            .draw_wrap = false,
            .jump_uses_vx = true,
            .supports_hires = false,
            .supports_xo = false,
            .octo_behavior = false,
            .resolution_switch_clears = false,
            .dxy0_lores_16x16 = false,
            .fx30_large_font_hex = false,
            .draw_vf_rowcount_in_hires = false,
            .max_rpl = 0,
            .vblank_wait = false,
        },
        // SUPER-CHIP 1.0/1.1 (HP48, superchip1): shift=true, memIncX=true,
        // wrap=false, jump=true, vblank=false, logic=false. Adds hires +
        // scrolls + FX30.
        .schip_legacy => .{
            .shift_uses_vy = false,
            .memory_increment = .increment_by_x,
            .logic_ops_clear_vf = false,
            .draw_wrap = false,
            .jump_uses_vx = true,
            .supports_hires = true,
            .supports_xo = false,
            .octo_behavior = false,
            .resolution_switch_clears = false,
            .dxy0_lores_16x16 = false,
            .fx30_large_font_hex = true,
            .draw_vf_rowcount_in_hires = true,
            .max_rpl = 8,
            .vblank_wait = false,
        },
        // Modern SUPER-CHIP (superchip): like schip_legacy but FX55/FX65
        // leave I unchanged (memoryLeaveIUnchanged=true, memoryIncrementByX=false).
        .schip_modern => .{
            .shift_uses_vy = false,
            .memory_increment = .leave_i_unchanged,
            .logic_ops_clear_vf = false,
            .draw_wrap = false,
            .jump_uses_vx = true,
            .supports_hires = true,
            .supports_xo = false,
            .octo_behavior = false,
            .resolution_switch_clears = false,
            .dxy0_lores_16x16 = false,
            .fx30_large_font_hex = true,
            .draw_vf_rowcount_in_hires = true,
            .max_rpl = 8,
            .vblank_wait = false,
        },
        // xochip: shift=false, wrap=true, jump=false, vblank=false, logic=false
        .xo_chip => .{
            .shift_uses_vy = true,
            .memory_increment = .increment_full,
            .logic_ops_clear_vf = false,
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
            .vblank_wait = false,
        },
        // Octo's XO-CHIP flavor — base xochip + Octo's quirks.
        .octo_xo => .{
            .shift_uses_vy = true,
            .memory_increment = .increment_full,
            .logic_ops_clear_vf = false,
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
            .vblank_wait = false,
        },
    };
}

pub fn profileLabel(profile: QuirkProfile) []const u8 {
    return switch (profile) {
        .modern => "MODERN",
        .vip_legacy => "VIP",
        .chip48 => "CHIP48",
        .schip_legacy => "SCHIP1",
        .schip_modern => "SCHIP",
        .xo_chip => "XO",
        .octo_xo => "OCTO",
    };
}

pub fn profileCliName(profile: QuirkProfile) []const u8 {
    return switch (profile) {
        .modern => "modern",
        .vip_legacy => "vip_legacy",
        .chip48 => "chip48",
        .schip_legacy => "schip_legacy",
        .schip_modern => "schip_modern",
        .xo_chip => "xo_chip",
        .octo_xo => "octo_xo",
    };
}

pub fn parseProfile(name: []const u8) ?QuirkProfile {
    if (std.ascii.eqlIgnoreCase(name, "modern")) return .modern;
    if (std.ascii.eqlIgnoreCase(name, "vip") or std.ascii.eqlIgnoreCase(name, "vip_legacy")) return .vip_legacy;
    if (std.ascii.eqlIgnoreCase(name, "chip48")) return .chip48;
    if (std.ascii.eqlIgnoreCase(name, "schip_legacy") or std.ascii.eqlIgnoreCase(name, "schip1") or std.ascii.eqlIgnoreCase(name, "superchip1")) return .schip_legacy;
    // `schip` / `schip_11` used to mean the generic hybrid; route to
    // schip_modern now (closest user-intent match) so older CLIs and
    // save-state profile bytes keep landing somewhere sensible.
    if (std.ascii.eqlIgnoreCase(name, "schip") or std.ascii.eqlIgnoreCase(name, "schip_11") or std.ascii.eqlIgnoreCase(name, "schip_modern") or std.ascii.eqlIgnoreCase(name, "superchip")) return .schip_modern;
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
        .chip48 => "chip48",
        .schip_legacy => "superchip1",
        .schip_modern => "superchip",
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
    if (std.mem.eql(u8, platform_id, "chip48")) return .chip48;
    if (std.mem.eql(u8, platform_id, "superchip1")) return .schip_legacy;
    if (std.mem.eql(u8, platform_id, "superchip")) return .schip_modern;
    if (std.mem.eql(u8, platform_id, "xochip")) return .xo_chip;
    // chip8x / megachip8 — not supported, no direct mapping.
    return null;
}

// Save-state byte codes. Bytes 0/1/3/4 are stable across the split; byte 2
// used to mean the old generic `schip_11` — we now route it to schip_modern
// so pre-split save files resume somewhere usable. New dedicated codes 5/6
// for chip48 / schip_legacy keep the mapping unambiguous going forward.
pub fn profileFromByte(value: u8) ?QuirkProfile {
    return switch (value) {
        0 => .modern,
        1 => .vip_legacy,
        2 => .schip_modern,
        3 => .xo_chip,
        4 => .octo_xo,
        5 => .chip48,
        6 => .schip_legacy,
        else => null,
    };
}

pub fn profileToByte(profile: QuirkProfile) u8 {
    return switch (profile) {
        .modern => 0,
        .vip_legacy => 1,
        .schip_modern => 2,
        .xo_chip => 3,
        .octo_xo => 4,
        .chip48 => 5,
        .schip_legacy => 6,
    };
}
