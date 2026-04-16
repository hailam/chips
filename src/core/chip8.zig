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
        return c;
    }

    pub fn loadRom(self: *Chip8, rom_data: []const u8) !void {
        if (rom_data.len > CHIP8_MEMORY_SIZE - 0x200) {
            return error.RomTooLarge;
        }
        @memset(self.memory[0x200..], 0);
        @memcpy(self.memory[0x200..][0..rom_data.len], rom_data);
        self.rom_size = @intCast(rom_data.len);
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
        try writer.writeInt(u16, state.rom_size, .little);
    }

    pub fn readSaveState(reader: *std.Io.Reader) !SaveState {
        var state: SaveState = undefined;
        state.cpu = try CPU.readSaveState(reader);
        try reader.readSliceAll(&state.memory);
        state.config = .{
            .quirk_profile = switch (try reader.takeByte()) {
                0 => .modern,
                1 => .vip_legacy,
                else => return error.InvalidSaveStateProfile,
            },
            .quirks = .{
                .shift_uses_vy = (try reader.takeByte()) != 0,
                .load_store_increment_i = (try reader.takeByte()) != 0,
                .logic_ops_clear_vf = (try reader.takeByte()) != 0,
                .draw_wrap = (try reader.takeByte()) != 0,
                .jump_uses_vx = (try reader.takeByte()) != 0,
            },
        };
        state.rom_size = try reader.takeInt(u16, .little);
        return state;
    }
};
