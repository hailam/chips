pub const QuirkProfile = enum {
    modern,
    vip_legacy,
};

pub const QuirkFlags = struct {
    shift_uses_vy: bool,
    load_store_increment_i: bool,
    logic_ops_clear_vf: bool,
    draw_wrap: bool,
    jump_uses_vx: bool,
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
        },
        .vip_legacy => .{
            .shift_uses_vy = true,
            .load_store_increment_i = true,
            .logic_ops_clear_vf = false,
            .draw_wrap = false,
            .jump_uses_vx = false,
        },
    };
}

pub fn profileLabel(profile: QuirkProfile) []const u8 {
    return switch (profile) {
        .modern => "MODERN",
        .vip_legacy => "VIP",
    };
}
