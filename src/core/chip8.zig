const std = @import("std");
const cpu_mod = @import("cpu.zig");
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

    pub fn init() Chip8 {
        var c = Chip8{
            .cpu = CPU.init(),
            .memory = [_]u8{0} ** CHIP8_MEMORY_SIZE,
        };
        // Load font data at 0x000
        @memcpy(c.memory[0..font_data.len], &font_data);
        return c;
    }

    pub fn loadRom(self: *Chip8, rom_data: []const u8) !void {
        if (rom_data.len > CHIP8_MEMORY_SIZE - 0x200) {
            return error.RomTooLarge;
        }
        @memcpy(self.memory[0x200..][0..rom_data.len], rom_data);
    }

    pub fn update(self: *Chip8) !void {
        try self.cpu.executeInstruction(&self.memory);
    }

    pub fn tickTimers(self: *Chip8) void {
        if (self.cpu.delay_timer > 0) self.cpu.delay_timer -= 1;
        if (self.cpu.sound_timer > 0) self.cpu.sound_timer -= 1;
        self.cpu.frame_count +%= 1;
    }

    pub fn reset(self: *Chip8) void {
        const old_mem = self.memory;
        self.cpu = CPU.init();
        self.memory = [_]u8{0} ** CHIP8_MEMORY_SIZE;
        @memcpy(self.memory[0..font_data.len], &font_data);
        // Preserve loaded ROM
        @memcpy(&self.memory, &old_mem);
    }
};
