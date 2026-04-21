const std = @import("std");
const cpu_mod = @import("cpu.zig");
const emulation = @import("emulation_config.zig");
const fonts = @import("fonts.zig");
const CPU = cpu_mod.CPU;

const CHIP8_MEMORY_SIZE = cpu_mod.CHIP8_MEMORY_SIZE;

// Font memory layout: small digits (80 bytes) at 0x000, big digits
// (160 bytes) at 0x050, matching Octo and most CHIP-8 emulators.
const FONT_SMALL_ADDR: u16 = 0x000;
const FONT_BIG_ADDR: u16 = 0x050;

pub const Chip8 = struct {
    cpu: CPU,
    memory: [CHIP8_MEMORY_SIZE]u8,
    config: emulation.EmulationConfig,
    rom_size: u16,

    pub const SaveState = struct {
        cpu: CPU.SaveState,
        memory: [CHIP8_MEMORY_SIZE]u8,
        config: emulation.EmulationConfig,
        rom_size: u16,
    };

    pub fn init() Chip8 {
        return initWithConfig(emulation.EmulationConfig.init(.modern));
    }

    pub fn initWithConfig(config: emulation.EmulationConfig) Chip8 {
        return initWithConfigAndFont(config, fonts.default_style);
    }

    pub fn initWithConfigAndFont(config: emulation.EmulationConfig, style: fonts.FontStyle) Chip8 {
        var c = Chip8{
            .cpu = CPU.init(),
            .memory = [_]u8{0} ** CHIP8_MEMORY_SIZE,
            .config = config,
            .rom_size = 0,
        };
        c.loadFont(style);
        return c;
    }

    // Overwrite the font region with a different variant. Called at init
    // and again from the ROM loader when the oracle picks a non-default
    // style, so callers don't need to re-init the whole CPU to switch.
    pub fn loadFont(self: *Chip8, style: fonts.FontStyle) void {
        const set = fonts.fontSet(style);
        @memcpy(self.memory[FONT_SMALL_ADDR .. FONT_SMALL_ADDR + set.small.len], set.small);
        @memcpy(self.memory[FONT_BIG_ADDR .. FONT_BIG_ADDR + set.big.len], set.big);
    }

    pub fn loadRom(self: *Chip8, rom_data: []const u8) !void {
        return self.loadRomAt(rom_data, 0x200);
    }

    // Load a ROM at an arbitrary entry address. Used when the
    // chip-8-database specifies a non-default `startAddress` (e.g. 0x600
    // for ETI-660 ROMs). Caller must also set `cpu.program_counter` to
    // this address before execution starts.
    pub fn loadRomAt(self: *Chip8, rom_data: []const u8, start_address: u16) !void {
        if (@as(usize, start_address) + rom_data.len > CHIP8_MEMORY_SIZE) {
            return error.RomTooLarge;
        }
        @memset(self.memory[start_address..], 0);
        @memcpy(self.memory[start_address..][0..rom_data.len], rom_data);
        self.rom_size = @intCast(rom_data.len);
        self.cpu.program_counter = start_address;
    }

    pub fn update(self: *Chip8) !void {
        try self.cpu.executeInstruction(&self.memory, self.config.quirks);
    }

    pub fn tickTimers(self: *Chip8) void {
        if (self.cpu.delay_timer > 0) self.cpu.delay_timer -= 1;
        if (self.cpu.sound_timer > 0) self.cpu.sound_timer -= 1;
        self.cpu.frame_count +%= 1;
        // tickTimers runs at 60 Hz — treat every call as a vblank boundary.
        // This lets any DRW deferred by the vblank_wait quirk retry in the
        // next frame. Clear both flags together so a deferred draw that
        // retries this cycle isn't mis-flagged as stalled.
        self.cpu.drew_this_frame = false;
        self.cpu.draw_stalled = false;
    }

    pub fn reset(self: *Chip8) void {
        const old_mem = self.memory;
        const old_config = self.config;
        const old_rom_size = self.rom_size;
        self.cpu = CPU.init();
        self.memory = [_]u8{0} ** CHIP8_MEMORY_SIZE;
        self.config = old_config;
        self.rom_size = old_rom_size;
        // old_mem already carries whichever font variant was loaded at
        // init (or replaced by loadFont), so restoring memory wholesale
        // is enough — no separate font reseed needed.
        @memcpy(&self.memory, &old_mem);
    }

    pub fn snapshot(self: *const Chip8) SaveState {
        return .{
            .cpu = self.cpu.snapshot(),
            .memory = self.memory,
            .config = self.config,
            .rom_size = self.rom_size,
        };
    }

    pub fn restore(self: *Chip8, state: SaveState) void {
        self.memory = state.memory;
        self.config = state.config;
        self.rom_size = state.rom_size;
        self.cpu.restore(state.cpu);
    }

    pub fn writeSaveState(writer: *std.Io.Writer, state: *const SaveState) !void {
        try CPU.writeSaveState(writer, &state.cpu);
        try writer.writeAll(&state.memory);
        try writer.writeByte(emulation.profileToByte(state.config.quirk_profile));
        try writer.writeByte(if (state.config.quirks.shift_uses_vy) 1 else 0);
        try writer.writeByte(@intFromEnum(state.config.quirks.memory_increment));
        try writer.writeByte(if (state.config.quirks.logic_ops_clear_vf) 1 else 0);
        try writer.writeByte(if (state.config.quirks.draw_wrap) 1 else 0);
        try writer.writeByte(if (state.config.quirks.jump_uses_vx) 1 else 0);
        try writer.writeByte(if (state.config.quirks.supports_hires) 1 else 0);
        try writer.writeByte(if (state.config.quirks.supports_xo) 1 else 0);
        try writer.writeByte(if (state.config.quirks.octo_behavior) 1 else 0);
        try writer.writeByte(if (state.config.quirks.resolution_switch_clears) 1 else 0);
        try writer.writeByte(if (state.config.quirks.dxy0_lores_16x16) 1 else 0);
        try writer.writeByte(if (state.config.quirks.fx30_large_font_hex) 1 else 0);
        try writer.writeByte(if (state.config.quirks.draw_vf_rowcount_in_hires) 1 else 0);
        try writer.writeByte(state.config.quirks.max_rpl);
        try writer.writeByte(if (state.config.quirks.vblank_wait) 1 else 0);
        try writer.writeInt(u16, state.rom_size, .little);
    }

    pub fn readSaveState(reader: *std.Io.Reader) !SaveState {
        var state: SaveState = undefined;
        state.cpu = try CPU.readSaveState(reader);
        try reader.readSliceAll(&state.memory);
        const profile_byte = try reader.takeByte();
        state.config = .{
            .quirk_profile = emulation.profileFromByte(profile_byte) orelse return error.InvalidSaveStateProfile,
            .quirks = .{
                .shift_uses_vy = (try reader.takeByte()) != 0,
                .memory_increment = switch (try reader.takeByte()) {
                    0 => .increment_full,
                    1 => .increment_by_x,
                    2 => .leave_i_unchanged,
                    else => return error.InvalidSaveStateProfile,
                },
                .logic_ops_clear_vf = (try reader.takeByte()) != 0,
                .draw_wrap = (try reader.takeByte()) != 0,
                .jump_uses_vx = (try reader.takeByte()) != 0,
                .supports_hires = (try reader.takeByte()) != 0,
                .supports_xo = (try reader.takeByte()) != 0,
                .octo_behavior = (try reader.takeByte()) != 0,
                .resolution_switch_clears = (try reader.takeByte()) != 0,
                .dxy0_lores_16x16 = (try reader.takeByte()) != 0,
                .fx30_large_font_hex = (try reader.takeByte()) != 0,
                .draw_vf_rowcount_in_hires = (try reader.takeByte()) != 0,
                .max_rpl = try reader.takeByte(),
                .vblank_wait = (try reader.takeByte()) != 0,
            },
        };
        state.rom_size = try reader.takeInt(u16, .little);
        return state;
    }
};
