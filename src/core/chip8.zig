const std = @import("std");
const cpu_mod = @import("cpu.zig");
const emulation = @import("emulation_config.zig");
const CPU = cpu_mod.CPU;

const CHIP8_MEMORY_SIZE = cpu_mod.CHIP8_MEMORY_SIZE;

const font_data = [_]u8{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

const large_font_data = [_]u8{
    0x7C, 0xC6, 0xCE, 0xD6, 0xE6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, // 0
    0x18, 0x38, 0x78, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00, // 1
    0x7C, 0xC6, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC6, 0xFE, 0x00, // 2
    0x7C, 0xC6, 0x06, 0x06, 0x3C, 0x06, 0x06, 0xC6, 0x7C, 0x00, // 3
    0x0C, 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x0C, 0x1E, 0x00, // 4
    0xFE, 0xC0, 0xC0, 0xFC, 0x06, 0x06, 0x06, 0xC6, 0x7C, 0x00, // 5
    0x3C, 0x60, 0xC0, 0xFC, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, // 6
    0xFE, 0xC6, 0x06, 0x0C, 0x18, 0x18, 0x30, 0x30, 0x30, 0x00, // 7
    0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, // 8
    0x7C, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0x06, 0x0C, 0x78, 0x00, // 9
    0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, // A
    0xFC, 0x66, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x66, 0xFC, 0x00, // B
    0x3C, 0x66, 0xC2, 0xC0, 0xC0, 0xC0, 0xC2, 0x66, 0x3C, 0x00, // C
    0xF8, 0x6C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00, // D
    0xFE, 0x62, 0x68, 0x78, 0x68, 0x78, 0x68, 0x62, 0xFE, 0x00, // E
    0xFE, 0x62, 0x68, 0x78, 0x68, 0x78, 0x68, 0x60, 0xF0, 0x00, // F
};

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
        var c = Chip8{
            .cpu = CPU.init(),
            .memory = [_]u8{0} ** CHIP8_MEMORY_SIZE,
            .config = config,
            .rom_size = 0,
        };
        // Load font data at 0x000
        @memcpy(c.memory[0..font_data.len], &font_data);
        @memcpy(c.memory[0x50 .. 0x50 + large_font_data.len], &large_font_data);
        return c;
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
    }

    pub fn reset(self: *Chip8) void {
        const old_mem = self.memory;
        const old_config = self.config;
        const old_rom_size = self.rom_size;
        self.cpu = CPU.init();
        self.memory = [_]u8{0} ** CHIP8_MEMORY_SIZE;
        self.config = old_config;
        self.rom_size = old_rom_size;
        @memcpy(self.memory[0..font_data.len], &font_data);
        @memcpy(self.memory[0x50 .. 0x50 + large_font_data.len], &large_font_data);
        // Preserve loaded ROM
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
        try writer.writeByte(@intFromEnum(state.config.quirk_profile));
        try writer.writeByte(if (state.config.quirks.shift_uses_vy) 1 else 0);
        try writer.writeByte(if (state.config.quirks.load_store_increment_i) 1 else 0);
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
                .load_store_increment_i = (try reader.takeByte()) != 0,
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
            },
        };
        state.rom_size = try reader.takeInt(u16, .little);
        return state;
    }
};
