const std = @import("std");

pub const CHIP8_REGISTER_COUNT = 16;
pub const CHIP8_STACK_SIZE = 16;
pub const CHIP8_MEMORY_SIZE = 4096;
pub const DISPLAY_WIDTH = 64;
pub const DISPLAY_HEIGHT = 32;
pub const DISPLAY_SIZE = DISPLAY_WIDTH * DISPLAY_HEIGHT;

// Tagged union for decoded instructions
pub const Instruction = union(enum) {
    cls,
    ret,
    sys: u16, // 0NNN (ignored on modern interpreters)
    jmp: u16, // 1NNN
    call: u16, // 2NNN
    se_byte: struct { vx: u4, byte: u8 }, // 3XKK
    sne_byte: struct { vx: u4, byte: u8 }, // 4XKK
    se_reg: struct { vx: u4, vy: u4 }, // 5XY0
    ld_byte: struct { vx: u4, byte: u8 }, // 6XKK
    add_byte: struct { vx: u4, byte: u8 }, // 7XKK
    ld_reg: struct { vx: u4, vy: u4 }, // 8XY0
    or_reg: struct { vx: u4, vy: u4 }, // 8XY1
    and_reg: struct { vx: u4, vy: u4 }, // 8XY2
    xor_reg: struct { vx: u4, vy: u4 }, // 8XY3
    add_reg: struct { vx: u4, vy: u4 }, // 8XY4
    sub_reg: struct { vx: u4, vy: u4 }, // 8XY5
    shr: struct { vx: u4 }, // 8XY6
    subn_reg: struct { vx: u4, vy: u4 }, // 8XY7
    shl: struct { vx: u4 }, // 8XYE
    sne_reg: struct { vx: u4, vy: u4 }, // 9XY0
    ld_i: u16, // ANNN
    jmp_v0: u16, // BNNN
    rnd: struct { vx: u4, byte: u8 }, // CXKK
    drw: struct { vx: u4, vy: u4, n: u4 }, // DXYN
    skp: u4, // EX9E
    sknp: u4, // EXA1
    ld_vx_dt: u4, // FX07
    ld_vx_k: u4, // FX0A
    ld_dt_vx: u4, // FX15
    ld_st_vx: u4, // FX18
    add_i_vx: u4, // FX1E
    ld_f_vx: u4, // FX29
    ld_b_vx: u4, // FX33
    ld_i_vx: u4, // FX55
    ld_vx_i: u4, // FX65
    unknown: u16,

    pub fn decode(opcode: u16) Instruction {
        const nnn: u16 = opcode & 0x0FFF;
        const kk: u8 = @truncate(opcode);
        const n: u4 = @truncate(opcode);
        const x: u4 = @truncate(opcode >> 8);
        const y: u4 = @truncate(opcode >> 4);
        const op: u4 = @truncate(opcode >> 12);

        return switch (op) {
            0x0 => if (nnn == 0x0E0) .cls else if (nnn == 0x0EE) .ret else .{ .sys = nnn },
            0x1 => .{ .jmp = nnn },
            0x2 => .{ .call = nnn },
            0x3 => .{ .se_byte = .{ .vx = x, .byte = kk } },
            0x4 => .{ .sne_byte = .{ .vx = x, .byte = kk } },
            0x5 => .{ .se_reg = .{ .vx = x, .vy = y } },
            0x6 => .{ .ld_byte = .{ .vx = x, .byte = kk } },
            0x7 => .{ .add_byte = .{ .vx = x, .byte = kk } },
            0x8 => switch (n) {
                0x0 => .{ .ld_reg = .{ .vx = x, .vy = y } },
                0x1 => .{ .or_reg = .{ .vx = x, .vy = y } },
                0x2 => .{ .and_reg = .{ .vx = x, .vy = y } },
                0x3 => .{ .xor_reg = .{ .vx = x, .vy = y } },
                0x4 => .{ .add_reg = .{ .vx = x, .vy = y } },
                0x5 => .{ .sub_reg = .{ .vx = x, .vy = y } },
                0x6 => .{ .shr = .{ .vx = x } },
                0x7 => .{ .subn_reg = .{ .vx = x, .vy = y } },
                0xE => .{ .shl = .{ .vx = x } },
                else => .{ .unknown = opcode },
            },
            0x9 => .{ .sne_reg = .{ .vx = x, .vy = y } },
            0xA => .{ .ld_i = nnn },
            0xB => .{ .jmp_v0 = nnn },
            0xC => .{ .rnd = .{ .vx = x, .byte = kk } },
            0xD => .{ .drw = .{ .vx = x, .vy = y, .n = n } },
            0xE => if (kk == 0x9E) .{ .skp = x } else if (kk == 0xA1) .{ .sknp = x } else .{ .unknown = opcode },
            0xF => switch (kk) {
                0x07 => .{ .ld_vx_dt = x },
                0x0A => .{ .ld_vx_k = x },
                0x15 => .{ .ld_dt_vx = x },
                0x18 => .{ .ld_st_vx = x },
                0x1E => .{ .add_i_vx = x },
                0x29 => .{ .ld_f_vx = x },
                0x33 => .{ .ld_b_vx = x },
                0x55 => .{ .ld_i_vx = x },
                0x65 => .{ .ld_vx_i = x },
                else => .{ .unknown = opcode },
            },
        };
    }

    pub fn format(self: Instruction, buf: []u8) []const u8 {
        return switch (self) {
            .cls => copyTo(buf, "CLS"),
            .ret => copyTo(buf, "RET"),
            .sys => |addr| fmtTo(buf, "SYS  {X:0>3}", .{addr}),
            .jmp => |addr| fmtTo(buf, "JP   {X:0>3}", .{addr}),
            .call => |addr| fmtTo(buf, "CALL {X:0>3}", .{addr}),
            .se_byte => |s| fmtTo(buf, "SE   V{X}, {X:0>2}", .{ s.vx, s.byte }),
            .sne_byte => |s| fmtTo(buf, "SNE  V{X}, {X:0>2}", .{ s.vx, s.byte }),
            .se_reg => |s| fmtTo(buf, "SE   V{X}, V{X}", .{ s.vx, s.vy }),
            .ld_byte => |s| fmtTo(buf, "LD   V{X}, {X:0>2}", .{ s.vx, s.byte }),
            .add_byte => |s| fmtTo(buf, "ADD  V{X}, {X:0>2}", .{ s.vx, s.byte }),
            .ld_reg => |s| fmtTo(buf, "LD   V{X}, V{X}", .{ s.vx, s.vy }),
            .or_reg => |s| fmtTo(buf, "OR   V{X}, V{X}", .{ s.vx, s.vy }),
            .and_reg => |s| fmtTo(buf, "AND  V{X}, V{X}", .{ s.vx, s.vy }),
            .xor_reg => |s| fmtTo(buf, "XOR  V{X}, V{X}", .{ s.vx, s.vy }),
            .add_reg => |s| fmtTo(buf, "ADD  V{X}, V{X}", .{ s.vx, s.vy }),
            .sub_reg => |s| fmtTo(buf, "SUB  V{X}, V{X}", .{ s.vx, s.vy }),
            .shr => |s| fmtTo(buf, "SHR  V{X}", .{s.vx}),
            .subn_reg => |s| fmtTo(buf, "SUBN V{X}, V{X}", .{ s.vx, s.vy }),
            .shl => |s| fmtTo(buf, "SHL  V{X}", .{s.vx}),
            .sne_reg => |s| fmtTo(buf, "SNE  V{X}, V{X}", .{ s.vx, s.vy }),
            .ld_i => |addr| fmtTo(buf, "LD   I, {X:0>3}", .{addr}),
            .jmp_v0 => |addr| fmtTo(buf, "JP   V0, {X:0>3}", .{addr}),
            .rnd => |s| fmtTo(buf, "RND  V{X}, {X:0>2}", .{ s.vx, s.byte }),
            .drw => |s| fmtTo(buf, "DRW  V{X}, V{X}, {d}", .{ s.vx, s.vy, s.n }),
            .skp => |vx| fmtTo(buf, "SKP  V{X}", .{vx}),
            .sknp => |vx| fmtTo(buf, "SKNP V{X}", .{vx}),
            .ld_vx_dt => |vx| fmtTo(buf, "LD   V{X}, DT", .{vx}),
            .ld_vx_k => |vx| fmtTo(buf, "LD   V{X}, K", .{vx}),
            .ld_dt_vx => |vx| fmtTo(buf, "LD   DT, V{X}", .{vx}),
            .ld_st_vx => |vx| fmtTo(buf, "LD   ST, V{X}", .{vx}),
            .add_i_vx => |vx| fmtTo(buf, "ADD  I, V{X}", .{vx}),
            .ld_f_vx => |vx| fmtTo(buf, "LD   F, V{X}", .{vx}),
            .ld_b_vx => |vx| fmtTo(buf, "LD   B, V{X}", .{vx}),
            .ld_i_vx => |vx| fmtTo(buf, "LD   [I], V{X}", .{vx}),
            .ld_vx_i => |vx| fmtTo(buf, "LD   V{X}, [I]", .{vx}),
            .unknown => |op| fmtTo(buf, "???  {X:0>4}", .{op}),
        };
    }

    fn fmtTo(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
    }

    fn copyTo(buf: []u8, src: []const u8) []const u8 {
        const len = @min(src.len, buf.len);
        @memcpy(buf[0..len], src[0..len]);
        return buf[0..len];
    }
};

pub const CPU = struct {
    // Standard registers & state
    registers: [CHIP8_REGISTER_COUNT]u8,
    index_register: u16,
    program_counter: u16,
    stack: [CHIP8_STACK_SIZE]u16,
    stack_pointer: u16,
    delay_timer: u8,
    sound_timer: u8,
    display: [DISPLAY_SIZE]u1,
    keys: [16]bool,
    draw_flag: bool,
    waiting_for_key: bool,
    key_register: u4,
    rng: std.Random.Xoshiro256,

    // Observability extensions
    mem_write_age: [CHIP8_MEMORY_SIZE]u32,
    last_i_target: u16,
    frame_count: u32,
    prev_registers: [CHIP8_REGISTER_COUNT]u8,
    reg_change_age: [CHIP8_REGISTER_COUNT]u32,
    last_flow: DataFlow,

    pub const FlowKind = enum {
        none,
        fetch, // RAM[PC] → decode
        sprite_read, // RAM[I..] → display
        i_read, // RAM[I..] → registers
        i_write, // registers → RAM[I..]
        key_wait, // keypad → register
        reg_load, // byte → VX (6XKK, 7XKK)
        reg_op, // VX ↔ VY (8XY_)
        call, // PC → stack
        ret, // stack → PC
        skip, // VX test → PC+2
        jump, // addr → PC
        timer, // VX ↔ DT/ST
    };

    pub const DataFlow = struct {
        kind: FlowKind = .none,
        src_addr: u16 = 0,
        src_len: u8 = 0,
        vx: u4 = 0,
        vy: u4 = 0,
        opcode: u16 = 0,
    };

    pub fn init() CPU {
        return CPU{
            .registers = [_]u8{0} ** CHIP8_REGISTER_COUNT,
            .index_register = 0,
            .program_counter = 0x200,
            .stack = [_]u16{0} ** CHIP8_STACK_SIZE,
            .stack_pointer = 0,
            .delay_timer = 0,
            .sound_timer = 0,
            .display = [_]u1{0} ** DISPLAY_SIZE,
            .keys = [_]bool{false} ** 16,
            .draw_flag = false,
            .waiting_for_key = false,
            .key_register = 0,
            .rng = std.Random.Xoshiro256.init(0),
            .mem_write_age = [_]u32{0} ** CHIP8_MEMORY_SIZE,
            .last_i_target = 0,
            .frame_count = 0,
            .prev_registers = [_]u8{0} ** CHIP8_REGISTER_COUNT,
            .reg_change_age = [_]u32{0} ** CHIP8_REGISTER_COUNT,
            .last_flow = .{},
        };
    }

    pub fn snapshotRegisters(self: *CPU) void {
        for (0..CHIP8_REGISTER_COUNT) |i| {
            if (self.registers[i] != self.prev_registers[i]) {
                self.reg_change_age[i] = self.frame_count;
            }
        }
        self.prev_registers = self.registers;
    }

    pub fn seedRng(self: *CPU, seed: u64) void {
        self.rng = std.Random.Xoshiro256.init(seed);
    }

    fn stampWrite(self: *CPU, addr: usize) void {
        if (addr < CHIP8_MEMORY_SIZE) {
            self.mem_write_age[addr] = self.frame_count;
        }
    }

    pub fn executeInstruction(self: *CPU, memory: *[CHIP8_MEMORY_SIZE]u8) !void {
        const fetch_pc = self.program_counter;
        const opcode: u16 = @as(u16, memory[self.program_counter]) << 8 | @as(u16, memory[self.program_counter + 1]);
        self.program_counter += 2;

        const inst = Instruction.decode(opcode);

        // Default flow: fetch
        self.last_flow = .{ .kind = .fetch, .src_addr = fetch_pc, .src_len = 2, .opcode = opcode };

        switch (inst) {
            .cls => {
                @memset(&self.display, 0);
                self.draw_flag = true;
            },
            .ret => {
                if (self.stack_pointer > 0) {
                    self.stack_pointer -= 1;
                    self.program_counter = self.stack[self.stack_pointer];
                }
                self.last_flow = .{ .kind = .ret, .opcode = opcode };
            },
            .sys => {},
            .jmp => |addr| {
                self.program_counter = addr;
                self.last_flow = .{ .kind = .jump, .src_addr = addr, .opcode = opcode };
            },
            .call => |addr| {
                if (self.stack_pointer < CHIP8_STACK_SIZE) {
                    self.stack[self.stack_pointer] = self.program_counter;
                    self.stack_pointer += 1;
                    self.program_counter = addr;
                } else {
                    return error.StackOverflow;
                }
                self.last_flow = .{ .kind = .call, .src_addr = addr, .opcode = opcode };
            },
            .se_byte => |s| {
                if (self.registers[s.vx] == s.byte) self.program_counter += 2;
                self.last_flow = .{ .kind = .skip, .vx = s.vx, .opcode = opcode };
            },
            .sne_byte => |s| {
                if (self.registers[s.vx] != s.byte) self.program_counter += 2;
                self.last_flow = .{ .kind = .skip, .vx = s.vx, .opcode = opcode };
            },
            .se_reg => |s| {
                if (self.registers[s.vx] == self.registers[s.vy]) self.program_counter += 2;
                self.last_flow = .{ .kind = .skip, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .ld_byte => |s| {
                self.registers[s.vx] = s.byte;
                self.last_flow = .{ .kind = .reg_load, .vx = s.vx, .opcode = opcode };
            },
            .add_byte => |s| {
                self.registers[s.vx] = self.registers[s.vx] +% s.byte;
                self.last_flow = .{ .kind = .reg_load, .vx = s.vx, .opcode = opcode };
            },
            .ld_reg => |s| {
                self.registers[s.vx] = self.registers[s.vy];
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .or_reg => |s| {
                self.registers[s.vx] |= self.registers[s.vy];
                self.registers[0xF] = 0;
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .and_reg => |s| {
                self.registers[s.vx] &= self.registers[s.vy];
                self.registers[0xF] = 0;
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .xor_reg => |s| {
                self.registers[s.vx] ^= self.registers[s.vy];
                self.registers[0xF] = 0;
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .add_reg => |s| {
                const sum: u16 = @as(u16, self.registers[s.vx]) + @as(u16, self.registers[s.vy]);
                self.registers[s.vx] = @truncate(sum);
                self.registers[0xF] = if (sum > 255) @as(u8, 1) else @as(u8, 0);
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .sub_reg => |s| {
                const vf: u8 = if (self.registers[s.vx] >= self.registers[s.vy]) 1 else 0;
                self.registers[s.vx] = self.registers[s.vx] -% self.registers[s.vy];
                self.registers[0xF] = vf;
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .shr => |s| {
                const vf: u8 = self.registers[s.vx] & 1;
                self.registers[s.vx] >>= 1;
                self.registers[0xF] = vf;
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .opcode = opcode };
            },
            .subn_reg => |s| {
                const vf: u8 = if (self.registers[s.vy] >= self.registers[s.vx]) 1 else 0;
                self.registers[s.vx] = self.registers[s.vy] -% self.registers[s.vx];
                self.registers[0xF] = vf;
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .shl => |s| {
                const vf: u8 = (self.registers[s.vx] >> 7) & 1;
                self.registers[s.vx] <<= 1;
                self.registers[0xF] = vf;
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .opcode = opcode };
            },
            .sne_reg => |s| {
                if (self.registers[s.vx] != self.registers[s.vy]) self.program_counter += 2;
                self.last_flow = .{ .kind = .skip, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .ld_i => |addr| {
                self.index_register = addr;
                self.last_flow = .{ .kind = .reg_load, .src_addr = addr, .opcode = opcode };
            },
            .jmp_v0 => |addr| {
                self.program_counter = @as(u16, self.registers[0]) + addr;
                self.last_flow = .{ .kind = .jump, .src_addr = self.program_counter, .opcode = opcode };
            },
            .rnd => |s| {
                const random_byte: u8 = self.rng.random().int(u8);
                self.registers[s.vx] = random_byte & s.byte;
                self.last_flow = .{ .kind = .reg_load, .vx = s.vx, .opcode = opcode };
            },
            .drw => |s| {
                const vx: u8 = self.registers[s.vx];
                const vy: u8 = self.registers[s.vy];
                self.registers[0xF] = 0;
                self.last_i_target = self.index_register;

                for (0..@as(usize, s.n)) |row| {
                    const sprite_byte = memory[self.index_register + row];
                    for (0..8) |col| {
                        const pixel: u1 = @truncate(sprite_byte >> @as(u3, @intCast(7 - col)));
                        if (pixel == 1) {
                            const px: usize = (@as(usize, vx) + col) % DISPLAY_WIDTH;
                            const py: usize = (@as(usize, vy) + row) % DISPLAY_HEIGHT;
                            const idx = py * DISPLAY_WIDTH + px;
                            if (self.display[idx] == 1) {
                                self.registers[0xF] = 1;
                            }
                            self.display[idx] ^= 1;
                        }
                    }
                }
                self.draw_flag = true;
                self.last_flow = .{ .kind = .sprite_read, .src_addr = self.index_register, .src_len = s.n, .vx = s.vx, .vy = s.vy, .opcode = opcode };
            },
            .skp => |vx| {
                if (self.keys[self.registers[vx] & 0xF]) self.program_counter += 2;
                self.last_flow = .{ .kind = .skip, .vx = vx, .opcode = opcode };
            },
            .sknp => |vx| {
                if (!self.keys[self.registers[vx] & 0xF]) self.program_counter += 2;
                self.last_flow = .{ .kind = .skip, .vx = vx, .opcode = opcode };
            },
            .ld_vx_dt => |vx| {
                self.registers[vx] = self.delay_timer;
                self.last_flow = .{ .kind = .timer, .vx = vx, .opcode = opcode };
            },
            .ld_vx_k => |vx| {
                self.waiting_for_key = true;
                self.key_register = vx;
                self.program_counter -= 2;
                self.last_flow = .{ .kind = .key_wait, .vx = vx, .opcode = opcode };
            },
            .ld_dt_vx => |vx| {
                self.delay_timer = self.registers[vx];
                self.last_flow = .{ .kind = .timer, .vx = vx, .opcode = opcode };
            },
            .ld_st_vx => |vx| {
                self.sound_timer = self.registers[vx];
                self.last_flow = .{ .kind = .timer, .vx = vx, .opcode = opcode };
            },
            .add_i_vx => |vx| {
                self.index_register +%= self.registers[vx];
            },
            .ld_f_vx => |vx| {
                self.index_register = @as(u16, self.registers[vx] & 0xF) * 5;
                self.last_i_target = self.index_register;
            },
            .ld_b_vx => |vx| {
                const val = self.registers[vx];
                const addr = self.index_register;
                memory[addr] = val / 100;
                memory[addr + 1] = (val / 10) % 10;
                memory[addr + 2] = val % 10;
                self.last_i_target = addr;
                self.stampWrite(addr);
                self.stampWrite(addr + 1);
                self.stampWrite(addr + 2);
                self.last_flow = .{ .kind = .i_write, .src_addr = addr, .src_len = 3, .vx = vx, .opcode = opcode };
            },
            .ld_i_vx => |vx| {
                self.last_i_target = self.index_register;
                for (0..@as(usize, vx) + 1) |i| {
                    memory[self.index_register + i] = self.registers[i];
                    self.stampWrite(self.index_register + i);
                }
                self.last_flow = .{ .kind = .i_write, .src_addr = self.index_register, .src_len = @as(u8, vx) + 1, .vx = vx, .opcode = opcode };
            },
            .ld_vx_i => |vx| {
                self.last_i_target = self.index_register;
                for (0..@as(usize, vx) + 1) |i| {
                    self.registers[i] = memory[self.index_register + i];
                }
                self.last_flow = .{ .kind = .i_read, .src_addr = self.index_register, .src_len = @as(u8, vx) + 1, .vx = vx, .opcode = opcode };
            },
            .unknown => {},
        }
    }
};
