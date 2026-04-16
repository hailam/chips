const std = @import("std");
const emulation = @import("emulation_config.zig");
const trace_mod = @import("trace.zig");

pub const CHIP8_REGISTER_COUNT = 16;
pub const CHIP8_STACK_SIZE = 16;
pub const CHIP8_MEMORY_SIZE = 65536;

pub const DISPLAY_WIDTH = 64;
pub const DISPLAY_HEIGHT = 32;
pub const DISPLAY_SIZE = DISPLAY_WIDTH * DISPLAY_HEIGHT;
pub const DISPLAY_HIRES_WIDTH = 128;
pub const DISPLAY_HIRES_HEIGHT = 64;
pub const DISPLAY_BACKING_SIZE = DISPLAY_HIRES_WIDTH * DISPLAY_HIRES_HEIGHT;
pub const DISPLAY_PLANE_COUNT = 2;

pub const RPL_COUNT = 16;
pub const XO_AUDIO_PATTERN_SIZE = 16;

pub const DisplayMode = enum(u8) {
    lores,
    hires,
};

pub const TrapOpcode = struct {
    pc: u16,
    opcode_hi: u16,
    opcode_lo: u16 = 0,
    byte_len: u8 = 2,
};

pub const TrapReason = union(enum(u8)) {
    unsupported_opcode: TrapOpcode,
    invalid_instruction: TrapOpcode,
    exit: TrapOpcode,
    stack_overflow: u16,
    stack_underflow: u16,

    pub fn format(self: TrapReason, buf: []u8) []const u8 {
        return switch (self) {
            .unsupported_opcode => |trap| formatTrapOpcode(buf, "unsupported", trap),
            .invalid_instruction => |trap| formatTrapOpcode(buf, "invalid", trap),
            .exit => |trap| formatTrapOpcode(buf, "exit", trap),
            .stack_overflow => |pc| std.fmt.bufPrint(buf, "stack overflow @ {X:0>4}", .{pc}) catch "",
            .stack_underflow => |pc| std.fmt.bufPrint(buf, "stack underflow @ {X:0>4}", .{pc}) catch "",
        };
    }
};

fn formatTrapOpcode(buf: []u8, prefix: []const u8, trap: TrapOpcode) []const u8 {
    if (trap.byte_len == 4) {
        return std.fmt.bufPrint(buf, "{s} @ {X:0>4}: {X:0>4} {X:0>4}", .{ prefix, trap.pc, trap.opcode_hi, trap.opcode_lo }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s} @ {X:0>4}: {X:0>4}", .{ prefix, trap.pc, trap.opcode_hi }) catch "";
}

pub const Instruction = union(enum) {
    cls,
    ret,
    sys: u16,
    scd: u4,
    scu: u4,
    scr,
    scl,
    exit,
    low,
    high,
    jmp: u16,
    call: u16,
    se_byte: struct { vx: u4, byte: u8 },
    sne_byte: struct { vx: u4, byte: u8 },
    se_reg: struct { vx: u4, vy: u4 },
    save_range: struct { vx: u4, vy: u4 },
    load_range: struct { vx: u4, vy: u4 },
    ld_byte: struct { vx: u4, byte: u8 },
    add_byte: struct { vx: u4, byte: u8 },
    ld_reg: struct { vx: u4, vy: u4 },
    or_reg: struct { vx: u4, vy: u4 },
    and_reg: struct { vx: u4, vy: u4 },
    xor_reg: struct { vx: u4, vy: u4 },
    add_reg: struct { vx: u4, vy: u4 },
    sub_reg: struct { vx: u4, vy: u4 },
    shr: struct { vx: u4, vy: u4 },
    subn_reg: struct { vx: u4, vy: u4 },
    shl: struct { vx: u4, vy: u4 },
    sne_reg: struct { vx: u4, vy: u4 },
    ld_i: u16,
    ld_i_long: u16,
    jmp_v0: u16,
    rnd: struct { vx: u4, byte: u8 },
    drw: struct { vx: u4, vy: u4, n: u4 },
    skp: u4,
    sknp: u4,
    ld_vx_dt: u4,
    ld_vx_k: u4,
    ld_dt_vx: u4,
    ld_st_vx: u4,
    add_i_vx: u4,
    ld_f_vx: u4,
    ld_hf_vx: u4,
    ld_b_vx: u4,
    ld_i_vx: u4,
    ld_vx_i: u4,
    ld_r_vx: u4,
    ld_vx_r: u4,
    plane: u4,
    audio,
    ld_pitch_vx: u4,
    unknown: u16,

    pub fn decode(opcode: u16) Instruction {
        const nnn: u16 = opcode & 0x0FFF;
        const kk: u8 = @truncate(opcode);
        const n: u4 = @truncate(opcode);
        const x: u4 = @truncate(opcode >> 8);
        const y: u4 = @truncate(opcode >> 4);
        const op: u4 = @truncate(opcode >> 12);

        return switch (op) {
            0x0 => decodeSystem(opcode, nnn, n),
            0x1 => .{ .jmp = nnn },
            0x2 => .{ .call = nnn },
            0x3 => .{ .se_byte = .{ .vx = x, .byte = kk } },
            0x4 => .{ .sne_byte = .{ .vx = x, .byte = kk } },
            0x5 => switch (n) {
                0x0 => .{ .se_reg = .{ .vx = x, .vy = y } },
                0x2 => .{ .save_range = .{ .vx = x, .vy = y } },
                0x3 => .{ .load_range = .{ .vx = x, .vy = y } },
                else => .{ .unknown = opcode },
            },
            0x6 => .{ .ld_byte = .{ .vx = x, .byte = kk } },
            0x7 => .{ .add_byte = .{ .vx = x, .byte = kk } },
            0x8 => switch (n) {
                0x0 => .{ .ld_reg = .{ .vx = x, .vy = y } },
                0x1 => .{ .or_reg = .{ .vx = x, .vy = y } },
                0x2 => .{ .and_reg = .{ .vx = x, .vy = y } },
                0x3 => .{ .xor_reg = .{ .vx = x, .vy = y } },
                0x4 => .{ .add_reg = .{ .vx = x, .vy = y } },
                0x5 => .{ .sub_reg = .{ .vx = x, .vy = y } },
                0x6 => .{ .shr = .{ .vx = x, .vy = y } },
                0x7 => .{ .subn_reg = .{ .vx = x, .vy = y } },
                0xE => .{ .shl = .{ .vx = x, .vy = y } },
                else => .{ .unknown = opcode },
            },
            0x9 => if (n == 0) .{ .sne_reg = .{ .vx = x, .vy = y } } else .{ .unknown = opcode },
            0xA => .{ .ld_i = nnn },
            0xB => .{ .jmp_v0 = nnn },
            0xC => .{ .rnd = .{ .vx = x, .byte = kk } },
            0xD => .{ .drw = .{ .vx = x, .vy = y, .n = n } },
            0xE => if (kk == 0x9E) .{ .skp = x } else if (kk == 0xA1) .{ .sknp = x } else .{ .unknown = opcode },
            0xF => switch (kk) {
                0x01 => .{ .plane = x },
                0x02 => if (x == 0) .audio else .{ .unknown = opcode },
                0x07 => .{ .ld_vx_dt = x },
                0x0A => .{ .ld_vx_k = x },
                0x15 => .{ .ld_dt_vx = x },
                0x18 => .{ .ld_st_vx = x },
                0x1E => .{ .add_i_vx = x },
                0x29 => .{ .ld_f_vx = x },
                0x30 => .{ .ld_hf_vx = x },
                0x33 => .{ .ld_b_vx = x },
                0x3A => .{ .ld_pitch_vx = x },
                0x55 => .{ .ld_i_vx = x },
                0x65 => .{ .ld_vx_i = x },
                0x75 => .{ .ld_r_vx = x },
                0x85 => .{ .ld_vx_r = x },
                else => .{ .unknown = opcode },
            },
        };
    }

    pub fn format(self: Instruction, buf: []u8) []const u8 {
        return switch (self) {
            .cls => copyTo(buf, "CLS"),
            .ret => copyTo(buf, "RET"),
            .sys => |addr| fmtTo(buf, "SYS  0x{X:0>3}", .{addr}),
            .scd => |n| fmtTo(buf, "SCD  {d}", .{n}),
            .scu => |n| fmtTo(buf, "SCU  {d}", .{n}),
            .scr => copyTo(buf, "SCR"),
            .scl => copyTo(buf, "SCL"),
            .exit => copyTo(buf, "EXIT"),
            .low => copyTo(buf, "LOW"),
            .high => copyTo(buf, "HIGH"),
            .jmp => |addr| fmtTo(buf, "JP   0x{X:0>3}", .{addr}),
            .call => |addr| fmtTo(buf, "CALL 0x{X:0>3}", .{addr}),
            .se_byte => |s| fmtTo(buf, "SE   V{X}, 0x{X:0>2}", .{ s.vx, s.byte }),
            .sne_byte => |s| fmtTo(buf, "SNE  V{X}, 0x{X:0>2}", .{ s.vx, s.byte }),
            .se_reg => |s| fmtTo(buf, "SE   V{X}, V{X}", .{ s.vx, s.vy }),
            .save_range => |s| fmtTo(buf, "SAVE V{X}-V{X}", .{ s.vx, s.vy }),
            .load_range => |s| fmtTo(buf, "LOAD V{X}-V{X}", .{ s.vx, s.vy }),
            .ld_byte => |s| fmtTo(buf, "LD   V{X}, 0x{X:0>2}", .{ s.vx, s.byte }),
            .add_byte => |s| fmtTo(buf, "ADD  V{X}, 0x{X:0>2}", .{ s.vx, s.byte }),
            .ld_reg => |s| fmtTo(buf, "LD   V{X}, V{X}", .{ s.vx, s.vy }),
            .or_reg => |s| fmtTo(buf, "OR   V{X}, V{X}", .{ s.vx, s.vy }),
            .and_reg => |s| fmtTo(buf, "AND  V{X}, V{X}", .{ s.vx, s.vy }),
            .xor_reg => |s| fmtTo(buf, "XOR  V{X}, V{X}", .{ s.vx, s.vy }),
            .add_reg => |s| fmtTo(buf, "ADD  V{X}, V{X}", .{ s.vx, s.vy }),
            .sub_reg => |s| fmtTo(buf, "SUB  V{X}, V{X}", .{ s.vx, s.vy }),
            .shr => |s| fmtTo(buf, "SHR  V{X}, V{X}", .{ s.vx, s.vy }),
            .subn_reg => |s| fmtTo(buf, "SUBN V{X}, V{X}", .{ s.vx, s.vy }),
            .shl => |s| fmtTo(buf, "SHL  V{X}, V{X}", .{ s.vx, s.vy }),
            .sne_reg => |s| fmtTo(buf, "SNE  V{X}, V{X}", .{ s.vx, s.vy }),
            .ld_i => |addr| fmtTo(buf, "LD   I, 0x{X:0>3}", .{addr}),
            .ld_i_long => |addr| fmtTo(buf, "LD   I, 0x{X:0>4}", .{addr}),
            .jmp_v0 => |addr| fmtTo(buf, "JP   V0, 0x{X:0>3}", .{addr}),
            .rnd => |s| fmtTo(buf, "RND  V{X}, 0x{X:0>2}", .{ s.vx, s.byte }),
            .drw => |s| fmtTo(buf, "DRW  V{X}, V{X}, {d}", .{ s.vx, s.vy, s.n }),
            .skp => |vx| fmtTo(buf, "SKP  V{X}", .{vx}),
            .sknp => |vx| fmtTo(buf, "SKNP V{X}", .{vx}),
            .ld_vx_dt => |vx| fmtTo(buf, "LD   V{X}, DT", .{vx}),
            .ld_vx_k => |vx| fmtTo(buf, "LD   V{X}, K", .{vx}),
            .ld_dt_vx => |vx| fmtTo(buf, "LD   DT, V{X}", .{vx}),
            .ld_st_vx => |vx| fmtTo(buf, "LD   ST, V{X}", .{vx}),
            .add_i_vx => |vx| fmtTo(buf, "ADD  I, V{X}", .{vx}),
            .ld_f_vx => |vx| fmtTo(buf, "LD   F, V{X}", .{vx}),
            .ld_hf_vx => |vx| fmtTo(buf, "LD   HF, V{X}", .{vx}),
            .ld_b_vx => |vx| fmtTo(buf, "LD   B, V{X}", .{vx}),
            .ld_i_vx => |vx| fmtTo(buf, "LD   [I], V{X}", .{vx}),
            .ld_vx_i => |vx| fmtTo(buf, "LD   V{X}, [I]", .{vx}),
            .ld_r_vx => |vx| fmtTo(buf, "LD   R, V{X}", .{vx}),
            .ld_vx_r => |vx| fmtTo(buf, "LD   V{X}, R", .{vx}),
            .plane => |mask| fmtTo(buf, "PLANE {d}", .{mask}),
            .audio => copyTo(buf, "AUDIO"),
            .ld_pitch_vx => |vx| fmtTo(buf, "LD   PITCH, V{X}", .{vx}),
            .unknown => |op| fmtTo(buf, "???  0x{X:0>4}", .{op}),
        };
    }

    fn decodeSystem(opcode: u16, nnn: u16, n: u4) Instruction {
        return if (opcode == 0x00E0)
            .cls
        else if (opcode == 0x00EE)
            .ret
        else if ((opcode & 0xFFF0) == 0x00C0)
            .{ .scd = n }
        else if ((opcode & 0xFFF0) == 0x00D0)
            .{ .scu = n }
        else if (opcode == 0x00FB)
            .scr
        else if (opcode == 0x00FC)
            .scl
        else if (opcode == 0x00FD)
            .exit
        else if (opcode == 0x00FE)
            .low
        else if (opcode == 0x00FF)
            .high
        else
            .{ .sys = nnn };
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

pub const DecodedInstruction = struct {
    instruction: Instruction,
    opcode_hi: u16,
    opcode_lo: u16 = 0,
    byte_len: u8 = 2,
    malformed: bool = false,

    pub fn decode(memory: *const [CHIP8_MEMORY_SIZE]u8, pc: u16) DecodedInstruction {
        return decodeForQuirks(memory, pc, emulation.profileQuirks(.modern));
    }

    pub fn decodeForProfile(memory: *const [CHIP8_MEMORY_SIZE]u8, pc: u16, profile: emulation.QuirkProfile) DecodedInstruction {
        return decodeForQuirks(memory, pc, emulation.profileQuirks(profile));
    }

    pub fn decodeForQuirks(memory: *const [CHIP8_MEMORY_SIZE]u8, pc: u16, quirks: emulation.QuirkFlags) DecodedInstruction {
        const hi = fetchWord(memory, pc) orelse {
            return .{
                .instruction = .{ .unknown = 0 },
                .opcode_hi = 0,
                .byte_len = 2,
                .malformed = true,
            };
        };

        if (hi == 0xF000 and quirks.supports_xo) {
            const lo = fetchWord(memory, pc + 2) orelse {
                return .{
                    .instruction = .{ .unknown = hi },
                    .opcode_hi = hi,
                    .byte_len = 4,
                    .malformed = true,
                };
            };
            return .{
                .instruction = .{ .ld_i_long = lo },
                .opcode_hi = hi,
                .opcode_lo = lo,
                .byte_len = 4,
            };
        }

        return .{
            .instruction = Instruction.decode(hi),
            .opcode_hi = hi,
            .byte_len = 2,
        };
    }
};

fn fetchWord(memory: *const [CHIP8_MEMORY_SIZE]u8, pc: u16) ?u16 {
    if (pc >= CHIP8_MEMORY_SIZE - 1) return null;
    return @as(u16, memory[pc]) << 8 | @as(u16, memory[pc + 1]);
}

pub const CPU = struct {
    registers: [CHIP8_REGISTER_COUNT]u8,
    index_register: u16,
    program_counter: u16,
    stack: [CHIP8_STACK_SIZE]u16,
    stack_pointer: u16,
    delay_timer: u8,
    sound_timer: u8,
    display_planes: [DISPLAY_PLANE_COUNT][DISPLAY_BACKING_SIZE]u1,
    display_mode: DisplayMode,
    active_plane_mask: u8,
    rpl_flags: [RPL_COUNT]u8,
    audio_pattern: [XO_AUDIO_PATTERN_SIZE]u8,
    audio_pitch: u8,
    keys: [16]bool,
    draw_flag: bool,
    waiting_for_key: bool,
    key_register: u4,
    trap_reason: ?TrapReason,
    rng: std.Random.Xoshiro256,

    mem_write_age: [CHIP8_MEMORY_SIZE]u32,
    last_i_target: u16,
    frame_count: u32,
    prev_registers: [CHIP8_REGISTER_COUNT]u8,
    reg_change_age: [CHIP8_REGISTER_COUNT]u32,
    last_flow: DataFlow,
    last_trace: trace_mod.TraceEntry,

    pub const FlowKind = enum {
        none,
        fetch,
        sprite_read,
        i_read,
        i_write,
        key_wait,
        reg_load,
        reg_op,
        call,
        ret,
        skip,
        jump,
        timer,
        audio,
    };

    pub const DataFlow = struct {
        kind: FlowKind = .none,
        src_addr: u16 = 0,
        src_len: u8 = 0,
        vx: u4 = 0,
        vy: u4 = 0,
        opcode: u16 = 0,
    };

    pub const SaveState = struct {
        registers: [CHIP8_REGISTER_COUNT]u8,
        index_register: u16,
        program_counter: u16,
        stack: [CHIP8_STACK_SIZE]u16,
        stack_pointer: u16,
        delay_timer: u8,
        sound_timer: u8,
        display_planes: [DISPLAY_PLANE_COUNT][DISPLAY_BACKING_SIZE]u8,
        display_mode: u8,
        active_plane_mask: u8,
        rpl_flags: [RPL_COUNT]u8,
        audio_pattern: [XO_AUDIO_PATTERN_SIZE]u8,
        audio_pitch: u8,
        keys: [16]u8,
        draw_flag: u8,
        waiting_for_key: u8,
        key_register: u8,
        trap_kind: u8,
        trap_pc: u16,
        trap_opcode_hi: u16,
        trap_opcode_lo: u16,
        trap_byte_len: u8,
        rng_state: [4]u64,
    };

    pub fn init() CPU {
        return .{
            .registers = [_]u8{0} ** CHIP8_REGISTER_COUNT,
            .index_register = 0,
            .program_counter = 0x200,
            .stack = [_]u16{0} ** CHIP8_STACK_SIZE,
            .stack_pointer = 0,
            .delay_timer = 0,
            .sound_timer = 0,
            .display_planes = [_][DISPLAY_BACKING_SIZE]u1{[_]u1{0} ** DISPLAY_BACKING_SIZE} ** DISPLAY_PLANE_COUNT,
            .display_mode = .lores,
            .active_plane_mask = 0x1,
            .rpl_flags = [_]u8{0} ** RPL_COUNT,
            .audio_pattern = [_]u8{0} ** XO_AUDIO_PATTERN_SIZE,
            .audio_pitch = 64,
            .keys = [_]bool{false} ** 16,
            .draw_flag = false,
            .waiting_for_key = false,
            .key_register = 0,
            .trap_reason = null,
            .rng = std.Random.Xoshiro256.init(0),
            .mem_write_age = [_]u32{0} ** CHIP8_MEMORY_SIZE,
            .last_i_target = 0,
            .frame_count = 0,
            .prev_registers = [_]u8{0} ** CHIP8_REGISTER_COUNT,
            .reg_change_age = [_]u32{0} ** CHIP8_REGISTER_COUNT,
            .last_flow = .{},
            .last_trace = trace_mod.TraceEntry.init(0, 0, .fetch),
        };
    }

    pub fn displayWidth(self: *const CPU) usize {
        return if (self.display_mode == .hires) DISPLAY_HIRES_WIDTH else DISPLAY_WIDTH;
    }

    pub fn displayHeight(self: *const CPU) usize {
        return if (self.display_mode == .hires) DISPLAY_HIRES_HEIGHT else DISPLAY_HEIGHT;
    }

    pub fn planePixel(self: *const CPU, plane_index: usize, x: usize, y: usize) u1 {
        if (plane_index >= DISPLAY_PLANE_COUNT or x >= DISPLAY_HIRES_WIDTH or y >= DISPLAY_HIRES_HEIGHT) return 0;
        return self.display_planes[plane_index][y * DISPLAY_HIRES_WIDTH + x];
    }

    pub fn compositePixel(self: *const CPU, x: usize, y: usize) u2 {
        if (x >= self.displayWidth() or y >= self.displayHeight()) return 0;
        const backing_scale = if (self.display_mode == .hires) @as(usize, 1) else @as(usize, 2);
        const bx = x * backing_scale;
        const by = y * backing_scale;
        var plane_mask: u2 = 0;
        for (0..DISPLAY_PLANE_COUNT) |plane| {
            if (blockPlanePixel(self.display_planes[plane], bx, by, backing_scale)) {
                plane_mask |= @as(u2, 1) << @intCast(plane);
            }
        }
        return plane_mask;
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

    pub fn clearTrap(self: *CPU) void {
        self.trap_reason = null;
    }

    fn stampWrite(self: *CPU, addr: usize) void {
        if (addr < CHIP8_MEMORY_SIZE) self.mem_write_age[addr] = self.frame_count;
    }

    pub fn snapshot(self: *const CPU) SaveState {
        var display_state = [_][DISPLAY_BACKING_SIZE]u8{[_]u8{0} ** DISPLAY_BACKING_SIZE} ** DISPLAY_PLANE_COUNT;
        for (self.display_planes, 0..) |plane, plane_index| {
            for (plane, 0..) |pixel, idx| display_state[plane_index][idx] = pixel;
        }

        var key_state = [_]u8{0} ** 16;
        for (self.keys, 0..) |pressed, idx| key_state[idx] = if (pressed) 1 else 0;

        const trap = self.trap_reason;
        var trap_kind: u8 = 0;
        var trap_pc: u16 = 0;
        var trap_opcode_hi: u16 = 0;
        var trap_opcode_lo: u16 = 0;
        var trap_byte_len: u8 = 0;
        if (trap) |value| {
            trap_kind = @intFromEnum(std.meta.activeTag(value)) + 1;
            switch (value) {
                .unsupported_opcode, .invalid_instruction, .exit => |op| {
                    trap_pc = op.pc;
                    trap_opcode_hi = op.opcode_hi;
                    trap_opcode_lo = op.opcode_lo;
                    trap_byte_len = op.byte_len;
                },
                .stack_overflow => |pc| trap_pc = pc,
                .stack_underflow => |pc| trap_pc = pc,
            }
        }
        return .{
            .registers = self.registers,
            .index_register = self.index_register,
            .program_counter = self.program_counter,
            .stack = self.stack,
            .stack_pointer = self.stack_pointer,
            .delay_timer = self.delay_timer,
            .sound_timer = self.sound_timer,
            .display_planes = display_state,
            .display_mode = @intFromEnum(self.display_mode),
            .active_plane_mask = self.active_plane_mask,
            .rpl_flags = self.rpl_flags,
            .audio_pattern = self.audio_pattern,
            .audio_pitch = self.audio_pitch,
            .keys = key_state,
            .draw_flag = if (self.draw_flag) 1 else 0,
            .waiting_for_key = if (self.waiting_for_key) 1 else 0,
            .key_register = self.key_register,
            .trap_kind = trap_kind,
            .trap_pc = trap_pc,
            .trap_opcode_hi = trap_opcode_hi,
            .trap_opcode_lo = trap_opcode_lo,
            .trap_byte_len = trap_byte_len,
            .rng_state = self.rng.s,
        };
    }

    pub fn restore(self: *CPU, state: SaveState) void {
        self.registers = state.registers;
        self.index_register = state.index_register;
        self.program_counter = state.program_counter;
        self.stack = state.stack;
        self.stack_pointer = state.stack_pointer;
        self.delay_timer = state.delay_timer;
        self.sound_timer = state.sound_timer;
        for (state.display_planes, 0..) |plane, plane_index| {
            for (plane, 0..) |pixel, idx| self.display_planes[plane_index][idx] = @intCast(pixel);
        }
        self.display_mode = if (state.display_mode == 1) .hires else .lores;
        self.active_plane_mask = state.active_plane_mask;
        self.rpl_flags = state.rpl_flags;
        self.audio_pattern = state.audio_pattern;
        self.audio_pitch = state.audio_pitch;
        for (state.keys, 0..) |pressed, idx| self.keys[idx] = pressed != 0;
        self.draw_flag = state.draw_flag != 0;
        self.waiting_for_key = state.waiting_for_key != 0;
        self.key_register = @intCast(state.key_register);
        self.trap_reason = decodeTrap(state);
        self.rng = std.Random.Xoshiro256{ .s = state.rng_state };
        self.mem_write_age = [_]u32{0} ** CHIP8_MEMORY_SIZE;
        self.last_i_target = self.index_register;
        self.frame_count = 0;
        self.prev_registers = self.registers;
        self.reg_change_age = [_]u32{0} ** CHIP8_REGISTER_COUNT;
        self.last_flow = .{};
        self.last_trace = trace_mod.TraceEntry.init(self.program_counter, 0, .fetch);
    }

    pub fn writeSaveState(writer: *std.Io.Writer, state: *const SaveState) !void {
        try writer.writeAll(&state.registers);
        try writer.writeInt(u16, state.index_register, .little);
        try writer.writeInt(u16, state.program_counter, .little);
        for (state.stack) |entry| try writer.writeInt(u16, entry, .little);
        try writer.writeInt(u16, state.stack_pointer, .little);
        try writer.writeByte(state.delay_timer);
        try writer.writeByte(state.sound_timer);
        for (state.display_planes) |plane| try writer.writeAll(&plane);
        try writer.writeByte(state.display_mode);
        try writer.writeByte(state.active_plane_mask);
        try writer.writeAll(&state.rpl_flags);
        try writer.writeAll(&state.audio_pattern);
        try writer.writeByte(state.audio_pitch);
        try writer.writeAll(&state.keys);
        try writer.writeByte(state.draw_flag);
        try writer.writeByte(state.waiting_for_key);
        try writer.writeByte(state.key_register);
        try writer.writeByte(state.trap_kind);
        try writer.writeInt(u16, state.trap_pc, .little);
        try writer.writeInt(u16, state.trap_opcode_hi, .little);
        try writer.writeInt(u16, state.trap_opcode_lo, .little);
        try writer.writeByte(state.trap_byte_len);
        for (state.rng_state) |entry| try writer.writeInt(u64, entry, .little);
    }

    pub fn readSaveState(reader: *std.Io.Reader) !SaveState {
        var state: SaveState = undefined;
        try reader.readSliceAll(&state.registers);
        state.index_register = try reader.takeInt(u16, .little);
        state.program_counter = try reader.takeInt(u16, .little);
        for (&state.stack) |*entry| entry.* = try reader.takeInt(u16, .little);
        state.stack_pointer = try reader.takeInt(u16, .little);
        state.delay_timer = try reader.takeByte();
        state.sound_timer = try reader.takeByte();
        for (&state.display_planes) |*plane| try reader.readSliceAll(plane);
        state.display_mode = try reader.takeByte();
        state.active_plane_mask = try reader.takeByte();
        try reader.readSliceAll(&state.rpl_flags);
        try reader.readSliceAll(&state.audio_pattern);
        state.audio_pitch = try reader.takeByte();
        try reader.readSliceAll(&state.keys);
        state.draw_flag = try reader.takeByte();
        state.waiting_for_key = try reader.takeByte();
        state.key_register = try reader.takeByte();
        state.trap_kind = try reader.takeByte();
        state.trap_pc = try reader.takeInt(u16, .little);
        state.trap_opcode_hi = try reader.takeInt(u16, .little);
        state.trap_opcode_lo = try reader.takeInt(u16, .little);
        state.trap_byte_len = try reader.takeByte();
        for (&state.rng_state) |*entry| entry.* = try reader.takeInt(u64, .little);
        return state;
    }

    pub fn executeInstruction(self: *CPU, memory: *[CHIP8_MEMORY_SIZE]u8, quirks: emulation.QuirkFlags) !void {
        if (self.trap_reason != null) return error.CpuTrapped;

        const fetch_pc = self.program_counter;
        const decoded = DecodedInstruction.decodeForQuirks(memory, fetch_pc, quirks);

        var trace_entry = trace_mod.TraceEntry.init(fetch_pc, decoded.opcode_hi, .fetch);
        trace_entry.opcode_lo = decoded.opcode_lo;
        trace_entry.byte_len = decoded.byte_len;

        const fetch_memory = trace_mod.memoryEndpoint(fetch_pc, decoded.byte_len);
        trace_entry.source = trace_mod.pcEndpoint(fetch_pc);
        trace_entry.destination = fetch_memory;
        trace_entry.addMicroOp(.{
            .kind = .fetch_opcode,
            .source = trace_mod.pcEndpoint(fetch_pc),
            .destination = fetch_memory,
        });
        trace_entry.addMicroOp(.{
            .kind = .decode_opcode,
            .source = fetch_memory,
            .destination = .decode,
        });

        self.last_flow = .{ .kind = .fetch, .src_addr = fetch_pc, .src_len = decoded.byte_len, .opcode = decoded.opcode_hi };

        if (decoded.malformed) return self.trapDecode(.invalid_instruction, decoded, &trace_entry);

        self.program_counter +%= decoded.byte_len;

        switch (decoded.instruction) {
            .cls => {
                self.clearSelectedPlanes(if (quirks.supports_xo) self.activePlaneMask() else 0x1);
                self.draw_flag = true;
                trace_entry.tag = .draw;
                trace_entry.source = .decode;
                trace_entry.destination = trace_mod.displayEndpoint(0, 0, self.displayWidth(), self.displayHeight(), self.activePlaneMask(), false, true);
                trace_entry.addMicroOp(.{ .kind = .draw_sprite, .source = .decode, .destination = trace_entry.destination });
            },
            .ret => {
                if (self.stack_pointer == 0) return self.trapAt(.stack_underflow, fetch_pc, decoded, &trace_entry);
                self.stack_pointer -= 1;
                self.program_counter = self.stack[self.stack_pointer];
                self.last_flow = .{ .kind = .ret, .opcode = decoded.opcode_hi };
                trace_entry.tag = .ret;
                trace_entry.source = trace_mod.stackEndpoint(self.stack_pointer, 1);
                trace_entry.destination = trace_mod.pcEndpoint(self.program_counter);
                trace_entry.addMicroOp(.{ .kind = .pop_stack, .source = trace_entry.source, .destination = trace_entry.destination });
            },
            .sys => |addr| {
                if (decoded.opcode_hi == 0x0000 and quirks.octo_behavior) {
                    return self.trapDecode(.exit, decoded, &trace_entry);
                }
                _ = addr;
                trace_entry.tag = .misc;
            },
            .scd => |amount| {
                if (!quirks.supports_hires) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.scrollVertical(if (quirks.supports_xo) self.activePlaneMask() else 0x1, @intCast(amount));
                self.draw_flag = true;
                trace_entry.tag = .draw;
                trace_entry.destination = trace_mod.displayEndpoint(0, 0, self.displayWidth(), self.displayHeight(), self.activePlaneMask(), false, true);
            },
            .scu => |amount| {
                if (!quirks.supports_xo) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.scrollVertical(if (quirks.supports_xo) self.activePlaneMask() else 0x1, -@as(i32, amount));
                self.draw_flag = true;
                trace_entry.tag = .draw;
                trace_entry.destination = trace_mod.displayEndpoint(0, 0, self.displayWidth(), self.displayHeight(), self.activePlaneMask(), false, true);
            },
            .scr => {
                if (!quirks.supports_hires) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.scrollHorizontal(if (quirks.supports_xo) self.activePlaneMask() else 0x1, 4);
                self.draw_flag = true;
                trace_entry.tag = .draw;
                trace_entry.destination = trace_mod.displayEndpoint(0, 0, self.displayWidth(), self.displayHeight(), self.activePlaneMask(), false, true);
            },
            .scl => {
                if (!quirks.supports_hires) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.scrollHorizontal(if (quirks.supports_xo) self.activePlaneMask() else 0x1, -4);
                self.draw_flag = true;
                trace_entry.tag = .draw;
                trace_entry.destination = trace_mod.displayEndpoint(0, 0, self.displayWidth(), self.displayHeight(), self.activePlaneMask(), false, true);
            },
            .exit => {
                if (!quirks.supports_hires) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                return self.trapDecode(.exit, decoded, &trace_entry);
            },
            .low => {
                if (!quirks.supports_hires) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.display_mode = .lores;
                if (quirks.resolution_switch_clears) self.clearSelectedPlanes(if (quirks.supports_xo) self.activePlaneMask() else 0x1);
                self.draw_flag = true;
                trace_entry.tag = .draw;
                trace_entry.destination = trace_mod.displayEndpoint(0, 0, self.displayWidth(), self.displayHeight(), self.activePlaneMask(), false, true);
            },
            .high => {
                if (!quirks.supports_hires) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.display_mode = .hires;
                if (quirks.resolution_switch_clears) self.clearSelectedPlanes(if (quirks.supports_xo) self.activePlaneMask() else 0x1);
                self.draw_flag = true;
                trace_entry.tag = .draw;
                trace_entry.destination = trace_mod.displayEndpoint(0, 0, self.displayWidth(), self.displayHeight(), self.activePlaneMask(), false, true);
            },
            .jmp => |addr| {
                self.program_counter = addr;
                self.last_flow = .{ .kind = .jump, .src_addr = addr, .opcode = decoded.opcode_hi };
                trace_entry.tag = .jump;
                trace_entry.source = .decode;
                trace_entry.destination = trace_mod.pcEndpoint(addr);
                trace_entry.addMicroOp(.{ .kind = .branch_pc, .source = .decode, .destination = trace_entry.destination });
            },
            .call => |addr| {
                if (self.stack_pointer >= CHIP8_STACK_SIZE) return self.trapAt(.stack_overflow, fetch_pc, decoded, &trace_entry);
                const return_pc = self.program_counter;
                const stack_slot = self.stack_pointer;
                self.stack[self.stack_pointer] = return_pc;
                self.stack_pointer += 1;
                self.program_counter = addr;
                self.last_flow = .{ .kind = .call, .src_addr = addr, .opcode = decoded.opcode_hi };
                trace_entry.tag = .call;
                trace_entry.source = trace_mod.pcEndpoint(return_pc);
                trace_entry.destination = trace_mod.stackEndpoint(stack_slot, 1);
                trace_entry.addMicroOp(.{ .kind = .push_stack, .source = trace_entry.source, .destination = trace_entry.destination });
                trace_entry.addMicroOp(.{ .kind = .branch_pc, .source = .decode, .destination = trace_mod.pcEndpoint(addr) });
            },
            .se_byte => |s| self.handleSkip(self.registers[s.vx] == s.byte, memory, quirks, s.vx, null, decoded, &trace_entry),
            .sne_byte => |s| self.handleSkip(self.registers[s.vx] != s.byte, memory, quirks, s.vx, null, decoded, &trace_entry),
            .se_reg => |s| self.handleSkip(self.registers[s.vx] == self.registers[s.vy], memory, quirks, s.vx, s.vy, decoded, &trace_entry),
            .save_range => |s| {
                if (!quirks.supports_xo) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                const span = rangeSpan(s.vx, s.vy);
                if (!self.ensureMemoryRange(self.index_register, span.len)) return self.trapDecode(.invalid_instruction, decoded, &trace_entry);
                var addr = self.index_register;
                var reg = s.vx;
                while (true) {
                    memory[addr] = self.registers[reg];
                    self.stampWrite(addr);
                    if (reg == s.vy) break;
                    addr +%= 1;
                    reg = if (s.vx <= s.vy) reg + 1 else reg - 1;
                }
                self.last_flow = .{ .kind = .i_write, .src_addr = self.index_register, .src_len = @intCast(span.len), .vx = s.vx, .vy = s.vy, .opcode = decoded.opcode_hi };
                trace_entry.tag = .store;
                trace_entry.source = trace_mod.registersEndpoint(s.vx, span.len);
                trace_entry.destination = trace_mod.memoryEndpoint(self.index_register, span.len);
                trace_entry.addMicroOp(.{ .kind = .write_mem_range, .source = trace_entry.source, .destination = trace_entry.destination });
            },
            .load_range => |s| {
                if (!quirks.supports_xo) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                const span = rangeSpan(s.vx, s.vy);
                if (!self.ensureMemoryRange(self.index_register, span.len)) return self.trapDecode(.invalid_instruction, decoded, &trace_entry);
                var addr = self.index_register;
                var reg = s.vx;
                while (true) {
                    self.registers[reg] = memory[addr];
                    if (reg == s.vy) break;
                    addr +%= 1;
                    reg = if (s.vx <= s.vy) reg + 1 else reg - 1;
                }
                self.last_flow = .{ .kind = .i_read, .src_addr = self.index_register, .src_len = @intCast(span.len), .vx = s.vx, .vy = s.vy, .opcode = decoded.opcode_hi };
                trace_entry.tag = .load;
                trace_entry.source = trace_mod.memoryEndpoint(self.index_register, span.len);
                trace_entry.destination = trace_mod.registersEndpoint(s.vx, span.len);
                trace_entry.addMicroOp(.{ .kind = .read_mem_range, .source = trace_entry.source, .destination = trace_entry.destination });
            },
            .ld_byte => |s| {
                self.registers[s.vx] = s.byte;
                self.last_flow = .{ .kind = .reg_load, .vx = s.vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .load;
                trace_entry.source = fetch_memory;
                trace_entry.destination = trace_mod.registersEndpoint(s.vx, 1);
                trace_entry.addMicroOp(.{ .kind = .write_reg, .source = fetch_memory, .destination = trace_entry.destination });
            },
            .add_byte => |s| {
                self.registers[s.vx] +%= s.byte;
                self.last_flow = .{ .kind = .reg_load, .vx = s.vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .alu;
                trace_entry.source = trace_mod.registersEndpoint(s.vx, 1);
                trace_entry.destination = trace_mod.registersEndpoint(s.vx, 1);
            },
            .ld_reg => |s| {
                self.registers[s.vx] = self.registers[s.vy];
                self.last_flow = .{ .kind = .reg_op, .vx = s.vx, .vy = s.vy, .opcode = decoded.opcode_hi };
                trace_entry.tag = .load;
                trace_entry.source = trace_mod.registersEndpoint(s.vy, 1);
                trace_entry.destination = trace_mod.registersEndpoint(s.vx, 1);
            },
            .or_reg => |s| self.logicOp(s.vx, s.vy, quirks, decoded.opcode_hi, &trace_entry, .or_reg),
            .and_reg => |s| self.logicOp(s.vx, s.vy, quirks, decoded.opcode_hi, &trace_entry, .and_reg),
            .xor_reg => |s| self.logicOp(s.vx, s.vy, quirks, decoded.opcode_hi, &trace_entry, .xor_reg),
            .add_reg => |s| {
                const sum: u16 = @as(u16, self.registers[s.vx]) + @as(u16, self.registers[s.vy]);
                self.registers[s.vx] = @truncate(sum);
                self.registers[0xF] = if (sum > 0xFF) 1 else 0;
                trace_entry.tag = .alu;
                trace_entry.source = trace_mod.registersEndpoint(s.vy, 1);
                trace_entry.destination = trace_mod.registersEndpoint(s.vx, 1);
            },
            .sub_reg => |s| {
                self.registers[0xF] = if (self.registers[s.vx] >= self.registers[s.vy]) 1 else 0;
                self.registers[s.vx] -%= self.registers[s.vy];
                trace_entry.tag = .alu;
                trace_entry.source = trace_mod.registersEndpoint(s.vy, 1);
                trace_entry.destination = trace_mod.registersEndpoint(s.vx, 1);
            },
            .shr => |s| self.shiftOp(s.vx, s.vy, quirks.shift_uses_vy, false, &trace_entry),
            .subn_reg => |s| {
                self.registers[0xF] = if (self.registers[s.vy] >= self.registers[s.vx]) 1 else 0;
                self.registers[s.vx] = self.registers[s.vy] -% self.registers[s.vx];
                trace_entry.tag = .alu;
                trace_entry.source = trace_mod.registersEndpoint(s.vy, 1);
                trace_entry.destination = trace_mod.registersEndpoint(s.vx, 1);
            },
            .shl => |s| self.shiftOp(s.vx, s.vy, quirks.shift_uses_vy, true, &trace_entry),
            .sne_reg => |s| self.handleSkip(self.registers[s.vx] != self.registers[s.vy], memory, quirks, s.vx, s.vy, decoded, &trace_entry),
            .ld_i => |addr| {
                self.index_register = addr;
                self.last_i_target = addr;
                trace_entry.tag = .load;
                trace_entry.destination = trace_mod.indexEndpoint(addr);
            },
            .ld_i_long => |addr| {
                if (!quirks.supports_xo) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.index_register = addr;
                self.last_i_target = addr;
                trace_entry.tag = .load;
                trace_entry.destination = trace_mod.indexEndpoint(addr);
            },
            .jmp_v0 => |addr| {
                const source_reg: u4 = if (quirks.jump_uses_vx) @truncate((addr >> 8) & 0xF) else 0;
                self.program_counter = @as(u16, self.registers[source_reg]) + addr;
                self.last_flow = .{ .kind = .jump, .src_addr = self.program_counter, .opcode = decoded.opcode_hi };
                trace_entry.tag = .jump;
                trace_entry.source = trace_mod.registersEndpoint(source_reg, 1);
                trace_entry.destination = trace_mod.pcEndpoint(self.program_counter);
            },
            .rnd => |s| {
                const random_byte: u8 = self.rng.random().int(u8);
                self.registers[s.vx] = random_byte & s.byte;
                self.last_flow = .{ .kind = .reg_load, .vx = s.vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .load;
                trace_entry.destination = trace_mod.registersEndpoint(s.vx, 1);
            },
            .drw => |s| {
                const plane_mask = if (quirks.supports_xo) self.activePlaneMask() else 0x1;
                const draw_kind = drawKind(s.n, quirks, self.display_mode);
                if (draw_kind == .unsupported) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);

                const sprite_height: usize = switch (draw_kind) {
                    .eight_by_n => s.n,
                    .sixteen_by_sixteen => 16,
                    .unsupported => unreachable,
                };
                const bytes_per_row: usize = switch (draw_kind) {
                    .eight_by_n => 1,
                    .sixteen_by_sixteen => 2,
                    .unsupported => unreachable,
                };
                if (!self.ensureMemoryRange(self.index_register, sprite_height * bytes_per_row)) return self.trapDecode(.invalid_instruction, decoded, &trace_entry);

                const vx = self.registers[s.vx];
                const vy = self.registers[s.vy];
                const draw_result = self.drawSprite(memory, vx, vy, self.index_register, draw_kind, plane_mask, quirks.draw_wrap, quirks.draw_vf_rowcount_in_hires);
                self.registers[0xF] = draw_result.vf;
                self.draw_flag = true;
                self.last_i_target = self.index_register;
                self.last_flow = .{ .kind = .sprite_read, .src_addr = self.index_register, .src_len = @intCast(sprite_height * bytes_per_row), .vx = s.vx, .vy = s.vy, .opcode = decoded.opcode_hi };
                trace_entry.tag = .draw;
                trace_entry.source = trace_mod.memoryEndpoint(self.index_register, sprite_height * bytes_per_row);
                trace_entry.destination = trace_mod.displayEndpoint(vx, vy, draw_result.logical_w, draw_result.logical_h, plane_mask, draw_result.wraps, false);
                trace_entry.addMicroOp(.{ .kind = .read_mem_range, .source = trace_entry.source, .destination = .decode });
                trace_entry.addMicroOp(.{ .kind = .draw_sprite, .source = trace_entry.source, .destination = trace_entry.destination });
            },
            .skp => |vx| {
                const key = @as(u4, @truncate(self.registers[vx] & 0xF));
                const should_skip = self.keys[key];
                self.handleKeySkip(should_skip, key, decoded, &trace_entry, memory, quirks);
            },
            .sknp => |vx| {
                const key = @as(u4, @truncate(self.registers[vx] & 0xF));
                const should_skip = !self.keys[key];
                self.handleKeySkip(should_skip, key, decoded, &trace_entry, memory, quirks);
            },
            .ld_vx_dt => |vx| {
                self.registers[vx] = self.delay_timer;
                self.last_flow = .{ .kind = .timer, .vx = vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .timer;
                trace_entry.source = trace_mod.timersEndpoint(true, false);
                trace_entry.destination = trace_mod.registersEndpoint(vx, 1);
            },
            .ld_vx_k => |vx| {
                self.waiting_for_key = true;
                self.key_register = vx;
                self.program_counter -%= decoded.byte_len;
                self.last_flow = .{ .kind = .key_wait, .vx = vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .key;
                trace_entry.source = trace_mod.keypadEndpoint(null, vx, true);
                trace_entry.destination = trace_mod.registersEndpoint(vx, 1);
                trace_entry.waits_for_key = true;
                trace_entry.addMicroOp(.{ .kind = .wait_key, .source = trace_entry.source, .destination = trace_entry.destination });
            },
            .ld_dt_vx => |vx| {
                self.delay_timer = self.registers[vx];
                self.last_flow = .{ .kind = .timer, .vx = vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .timer;
                trace_entry.source = trace_mod.registersEndpoint(vx, 1);
                trace_entry.destination = trace_mod.timersEndpoint(true, false);
            },
            .ld_st_vx => |vx| {
                self.sound_timer = self.registers[vx];
                self.last_flow = .{ .kind = .timer, .vx = vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .timer;
                trace_entry.source = trace_mod.registersEndpoint(vx, 1);
                trace_entry.destination = trace_mod.timersEndpoint(false, true);
            },
            .add_i_vx => |vx| {
                self.index_register +%= self.registers[vx];
                self.last_i_target = self.index_register;
                trace_entry.tag = .alu;
                trace_entry.source = trace_mod.registersEndpoint(vx, 1);
                trace_entry.destination = trace_mod.indexEndpoint(self.index_register);
            },
            .ld_f_vx => |vx| {
                self.index_register = @as(u16, self.registers[vx] & 0xF) * 5;
                self.last_i_target = self.index_register;
                trace_entry.tag = .load;
                trace_entry.source = trace_mod.registersEndpoint(vx, 1);
                trace_entry.destination = trace_mod.indexEndpoint(self.index_register);
            },
            .ld_hf_vx => |vx| {
                if (!quirks.supports_hires) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                const digit = if (quirks.fx30_large_font_hex) self.registers[vx] & 0xF else self.registers[vx] % 10;
                self.index_register = 0x50 + @as(u16, digit) * 10;
                self.last_i_target = self.index_register;
                trace_entry.tag = .load;
                trace_entry.source = trace_mod.registersEndpoint(vx, 1);
                trace_entry.destination = trace_mod.indexEndpoint(self.index_register);
            },
            .ld_b_vx => |vx| {
                if (!self.ensureMemoryRange(self.index_register, 3)) return self.trapDecode(.invalid_instruction, decoded, &trace_entry);
                const value = self.registers[vx];
                memory[self.index_register] = value / 100;
                memory[self.index_register + 1] = (value / 10) % 10;
                memory[self.index_register + 2] = value % 10;
                self.stampWrite(self.index_register);
                self.stampWrite(self.index_register + 1);
                self.stampWrite(self.index_register + 2);
                self.last_i_target = self.index_register;
                self.last_flow = .{ .kind = .i_write, .src_addr = self.index_register, .src_len = 3, .vx = vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .store;
                trace_entry.source = trace_mod.registersEndpoint(vx, 1);
                trace_entry.destination = trace_mod.memoryEndpoint(self.index_register, 3);
                trace_entry.addMicroOp(.{ .kind = .write_mem_range, .source = trace_entry.source, .destination = trace_entry.destination });
            },
            .ld_i_vx => |vx| {
                const count = @as(usize, vx) + 1;
                if (!self.ensureMemoryRange(self.index_register, count)) return self.trapDecode(.invalid_instruction, decoded, &trace_entry);
                for (0..count) |i| {
                    memory[self.index_register + i] = self.registers[i];
                    self.stampWrite(self.index_register + i);
                }
                if (quirks.load_store_increment_i) self.index_register +%= @intCast(count);
                self.last_i_target = self.index_register;
                self.last_flow = .{ .kind = .i_write, .src_addr = self.index_register, .src_len = @intCast(count), .vx = vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .store;
                trace_entry.source = trace_mod.registersEndpoint(0, count);
                trace_entry.destination = trace_mod.memoryEndpoint(self.index_register, count);
                trace_entry.addMicroOp(.{ .kind = .write_mem_range, .source = trace_entry.source, .destination = trace_entry.destination });
            },
            .ld_vx_i => |vx| {
                const count = @as(usize, vx) + 1;
                if (!self.ensureMemoryRange(self.index_register, count)) return self.trapDecode(.invalid_instruction, decoded, &trace_entry);
                for (0..count) |i| self.registers[i] = memory[self.index_register + i];
                if (quirks.load_store_increment_i) self.index_register +%= @intCast(count);
                self.last_i_target = self.index_register;
                self.last_flow = .{ .kind = .i_read, .src_addr = self.index_register, .src_len = @intCast(count), .vx = vx, .opcode = decoded.opcode_hi };
                trace_entry.tag = .load;
                trace_entry.source = trace_mod.memoryEndpoint(self.index_register, count);
                trace_entry.destination = trace_mod.registersEndpoint(0, count);
                trace_entry.addMicroOp(.{ .kind = .read_mem_range, .source = trace_entry.source, .destination = trace_entry.destination });
            },
            .ld_r_vx => |vx| {
                if (!quirks.supports_hires or vx + 1 > quirks.max_rpl) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                const count = @as(usize, vx) + 1;
                @memcpy(self.rpl_flags[0..count], self.registers[0..count]);
                trace_entry.tag = .store;
                trace_entry.source = trace_mod.registersEndpoint(0, count);
            },
            .ld_vx_r => |vx| {
                if (!quirks.supports_hires or vx + 1 > quirks.max_rpl) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                const count = @as(usize, vx) + 1;
                @memcpy(self.registers[0..count], self.rpl_flags[0..count]);
                trace_entry.tag = .load;
                trace_entry.destination = trace_mod.registersEndpoint(0, count);
            },
            .plane => |mask| {
                if (!quirks.supports_xo) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.active_plane_mask = mask & 0x3;
                trace_entry.tag = .misc;
            },
            .audio => {
                if (!quirks.supports_xo) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                if (!self.ensureMemoryRange(self.index_register, XO_AUDIO_PATTERN_SIZE)) return self.trapDecode(.invalid_instruction, decoded, &trace_entry);
                @memcpy(&self.audio_pattern, memory[self.index_register .. self.index_register + XO_AUDIO_PATTERN_SIZE]);
                self.last_flow = .{ .kind = .audio, .src_addr = self.index_register, .src_len = XO_AUDIO_PATTERN_SIZE, .opcode = decoded.opcode_hi };
                trace_entry.tag = .load;
                trace_entry.source = trace_mod.memoryEndpoint(self.index_register, XO_AUDIO_PATTERN_SIZE);
            },
            .ld_pitch_vx => |vx| {
                if (!quirks.supports_xo) return self.trapDecode(.unsupported_opcode, decoded, &trace_entry);
                self.audio_pitch = self.registers[vx];
                trace_entry.tag = .load;
                trace_entry.source = trace_mod.registersEndpoint(vx, 1);
            },
            .unknown => return self.trapDecode(.invalid_instruction, decoded, &trace_entry),
        }

        self.last_trace = trace_entry;
    }

    fn logicOp(self: *CPU, vx: u4, vy: u4, quirks: emulation.QuirkFlags, opcode: u16, trace_entry: *trace_mod.TraceEntry, comptime which: enum { or_reg, and_reg, xor_reg }) void {
        switch (which) {
            .or_reg => self.registers[vx] |= self.registers[vy],
            .and_reg => self.registers[vx] &= self.registers[vy],
            .xor_reg => self.registers[vx] ^= self.registers[vy],
        }
        if (quirks.logic_ops_clear_vf) self.registers[0xF] = 0;
        self.last_flow = .{ .kind = .reg_op, .vx = vx, .vy = vy, .opcode = opcode };
        trace_entry.tag = .alu;
        trace_entry.source = trace_mod.registersEndpoint(vy, 1);
        trace_entry.destination = trace_mod.registersEndpoint(vx, 1);
    }

    fn shiftOp(self: *CPU, vx: u4, vy: u4, shift_uses_vy: bool, left: bool, trace_entry: *trace_mod.TraceEntry) void {
        const source_reg: u4 = if (shift_uses_vy) vy else vx;
        const source = self.registers[source_reg];
        if (left) {
            self.registers[0xF] = (source >> 7) & 1;
            self.registers[vx] = source << 1;
        } else {
            self.registers[0xF] = source & 1;
            self.registers[vx] = source >> 1;
        }
        trace_entry.tag = .alu;
        trace_entry.source = trace_mod.registersEndpoint(source_reg, 1);
        trace_entry.destination = trace_mod.registersEndpoint(vx, 1);
    }

    fn handleSkip(self: *CPU, should_skip: bool, memory: *[CHIP8_MEMORY_SIZE]u8, quirks: emulation.QuirkFlags, vx: u4, maybe_vy: ?u4, decoded: DecodedInstruction, trace_entry: *trace_mod.TraceEntry) void {
        if (should_skip) self.program_counter +%= nextInstructionByteLen(memory, self.program_counter, quirks);
        self.last_flow = .{ .kind = .skip, .vx = vx, .vy = maybe_vy orelse 0, .opcode = decoded.opcode_hi };
        trace_entry.tag = .skip;
        trace_entry.source = trace_mod.registersEndpoint(vx, 1);
        trace_entry.destination = trace_mod.pcEndpoint(self.program_counter);
    }

    fn handleKeySkip(self: *CPU, should_skip: bool, key: u4, decoded: DecodedInstruction, trace_entry: *trace_mod.TraceEntry, memory: *[CHIP8_MEMORY_SIZE]u8, quirks: emulation.QuirkFlags) void {
        if (should_skip) self.program_counter +%= nextInstructionByteLen(memory, self.program_counter, quirks);
        self.last_flow = .{ .kind = .skip, .vx = key, .opcode = decoded.opcode_hi };
        trace_entry.tag = .skip;
        trace_entry.source = trace_mod.keypadEndpoint(key, null, false);
        trace_entry.destination = trace_mod.pcEndpoint(self.program_counter);
    }

    fn ensureMemoryRange(self: *const CPU, start: u16, len: usize) bool {
        _ = self;
        if (len == 0) return true;
        return @as(usize, start) + len <= CHIP8_MEMORY_SIZE;
    }

    fn activePlaneMask(self: *const CPU) u8 {
        return self.active_plane_mask & 0x3;
    }

    fn clearSelectedPlanes(self: *CPU, plane_mask: u8) void {
        for (0..DISPLAY_PLANE_COUNT) |plane| {
            if ((plane_mask & (@as(u8, 1) << @intCast(plane))) == 0) continue;
            @memset(&self.display_planes[plane], 0);
        }
    }

    fn scrollVertical(self: *CPU, plane_mask: u8, delta: i32) void {
        for (0..DISPLAY_PLANE_COUNT) |plane| {
            if ((plane_mask & (@as(u8, 1) << @intCast(plane))) == 0) continue;
            var next_plane = [_]u1{0} ** DISPLAY_BACKING_SIZE;
            for (0..DISPLAY_HIRES_HEIGHT) |y| {
                for (0..DISPLAY_HIRES_WIDTH) |x| {
                    const src_y = @as(i32, @intCast(y)) - delta;
                    if (src_y < 0 or src_y >= DISPLAY_HIRES_HEIGHT) continue;
                    next_plane[y * DISPLAY_HIRES_WIDTH + x] = self.display_planes[plane][@as(usize, @intCast(src_y)) * DISPLAY_HIRES_WIDTH + x];
                }
            }
            self.display_planes[plane] = next_plane;
        }
    }

    fn scrollHorizontal(self: *CPU, plane_mask: u8, delta: i32) void {
        for (0..DISPLAY_PLANE_COUNT) |plane| {
            if ((plane_mask & (@as(u8, 1) << @intCast(plane))) == 0) continue;
            var next_plane = [_]u1{0} ** DISPLAY_BACKING_SIZE;
            for (0..DISPLAY_HIRES_HEIGHT) |y| {
                for (0..DISPLAY_HIRES_WIDTH) |x| {
                    const src_x = @as(i32, @intCast(x)) - delta;
                    if (src_x < 0 or src_x >= DISPLAY_HIRES_WIDTH) continue;
                    next_plane[y * DISPLAY_HIRES_WIDTH + x] = self.display_planes[plane][y * DISPLAY_HIRES_WIDTH + @as(usize, @intCast(src_x))];
                }
            }
            self.display_planes[plane] = next_plane;
        }
    }

    fn drawSprite(
        self: *CPU,
        memory: *[CHIP8_MEMORY_SIZE]u8,
        vx: u8,
        vy: u8,
        start_addr: u16,
        kind: DrawKind,
        plane_mask: u8,
        wrap: bool,
        hires_rowcount_vf: bool,
    ) DrawResult {
        const logical_w = self.displayWidth();
        const logical_h = self.displayHeight();
        const backing_scale: usize = if (self.display_mode == .hires) 1 else 2;
        const sprite_w: usize = if (kind == .sixteen_by_sixteen) 16 else 8;
        const sprite_h: usize = if (kind == .sixteen_by_sixteen) 16 else @as(usize, @intCast(kind.eightHeight()));
        var collision_any = false;
        var collision_rows: u8 = 0;

        for (0..sprite_h) |row| {
            const sprite_word: u16 = if (sprite_w == 16)
                (@as(u16, memory[start_addr + row * 2]) << 8) | @as(u16, memory[start_addr + row * 2 + 1])
            else
                @as(u16, memory[start_addr + row]);

            var row_collision = false;
            for (0..sprite_w) |col| {
                const mask_shift: u4 = @intCast(sprite_w - 1 - col);
                if (((sprite_word >> mask_shift) & 1) == 0) continue;

                const raw_x = @as(usize, vx) + col;
                const raw_y = @as(usize, vy) + row;
                if (!wrap and (raw_x >= logical_w or raw_y >= logical_h)) continue;

                const px = if (wrap) raw_x % logical_w else raw_x;
                const py = if (wrap) raw_y % logical_h else raw_y;
                const bx = px * backing_scale;
                const by = py * backing_scale;

                for (0..DISPLAY_PLANE_COUNT) |plane| {
                    if ((plane_mask & (@as(u8, 1) << @intCast(plane))) == 0) continue;
                    for (0..backing_scale) |dy| {
                        for (0..backing_scale) |dx| {
                            const idx = (by + dy) * DISPLAY_HIRES_WIDTH + (bx + dx);
                            if (self.display_planes[plane][idx] == 1) {
                                collision_any = true;
                                row_collision = true;
                            }
                            self.display_planes[plane][idx] ^= 1;
                        }
                    }
                }
            }
            if (row_collision) collision_rows += 1;
        }

        return .{
            .vf = if (hires_rowcount_vf and self.display_mode == .hires) collision_rows else if (collision_any) 1 else 0,
            .logical_w = sprite_w,
            .logical_h = sprite_h,
            .wraps = wrap,
        };
    }

    fn trapDecode(
        self: *CPU,
        comptime kind: std.meta.Tag(TrapReason),
        decoded: DecodedInstruction,
        trace_entry: *trace_mod.TraceEntry,
    ) error{CpuTrapped} {
        const pc = if (decoded.opcode_hi == 0 and decoded.opcode_lo == 0)
            self.program_counter
        else
            self.program_counter - decoded.byte_len;
        return self.trapAt(kind, pc, decoded, trace_entry);
    }

    fn trapAt(
        self: *CPU,
        comptime kind: std.meta.Tag(TrapReason),
        pc: u16,
        decoded: DecodedInstruction,
        trace_entry: *trace_mod.TraceEntry,
    ) error{CpuTrapped} {
        self.trap_reason = switch (kind) {
            .unsupported_opcode => .{ .unsupported_opcode = .{ .pc = pc, .opcode_hi = decoded.opcode_hi, .opcode_lo = decoded.opcode_lo, .byte_len = decoded.byte_len } },
            .invalid_instruction => .{ .invalid_instruction = .{ .pc = pc, .opcode_hi = decoded.opcode_hi, .opcode_lo = decoded.opcode_lo, .byte_len = decoded.byte_len } },
            .exit => .{ .exit = .{ .pc = pc, .opcode_hi = decoded.opcode_hi, .opcode_lo = decoded.opcode_lo, .byte_len = decoded.byte_len } },
            .stack_overflow => .{ .stack_overflow = pc },
            .stack_underflow => .{ .stack_underflow = pc },
        };
        trace_entry.tag = .misc;
        self.last_trace = trace_entry.*;
        return error.CpuTrapped;
    }
};

const DrawKind = union(enum) {
    eight_by_n: u4,
    sixteen_by_sixteen,
    unsupported,

    fn eightHeight(self: DrawKind) u4 {
        return switch (self) {
            .eight_by_n => |n| n,
            else => 0,
        };
    }
};

const DrawResult = struct {
    vf: u8,
    logical_w: usize,
    logical_h: usize,
    wraps: bool,
};

fn drawKind(n: u4, quirks: emulation.QuirkFlags, mode: DisplayMode) DrawKind {
    if (n != 0) return .{ .eight_by_n = n };
    if (!quirks.supports_hires) return .unsupported;
    if (mode == .hires or quirks.dxy0_lores_16x16) return .sixteen_by_sixteen;
    return .unsupported;
}

fn rangeSpan(vx: u4, vy: u4) struct { len: usize } {
    return .{
        .len = if (vx <= vy) @as(usize, vy - vx) + 1 else @as(usize, vx - vy) + 1,
    };
}

fn nextInstructionByteLen(memory: *const [CHIP8_MEMORY_SIZE]u8, pc: u16, quirks: emulation.QuirkFlags) u8 {
    return DecodedInstruction.decodeForQuirks(memory, pc, quirks).byte_len;
}

fn blockPlanePixel(plane: [DISPLAY_BACKING_SIZE]u1, bx: usize, by: usize, scale: usize) bool {
    for (0..scale) |dy| {
        for (0..scale) |dx| {
            const x = bx + dx;
            const y = by + dy;
            if (x >= DISPLAY_HIRES_WIDTH or y >= DISPLAY_HIRES_HEIGHT) continue;
            if (plane[y * DISPLAY_HIRES_WIDTH + x] == 1) return true;
        }
    }
    return false;
}

fn decodeTrap(state: CPU.SaveState) ?TrapReason {
    if (state.trap_kind == 0) return null;
    const opcode = TrapOpcode{
        .pc = state.trap_pc,
        .opcode_hi = state.trap_opcode_hi,
        .opcode_lo = state.trap_opcode_lo,
        .byte_len = state.trap_byte_len,
    };
    return switch (state.trap_kind - 1) {
        @intFromEnum(std.meta.Tag(TrapReason).unsupported_opcode) => .{ .unsupported_opcode = opcode },
        @intFromEnum(std.meta.Tag(TrapReason).invalid_instruction) => .{ .invalid_instruction = opcode },
        @intFromEnum(std.meta.Tag(TrapReason).exit) => .{ .exit = opcode },
        @intFromEnum(std.meta.Tag(TrapReason).stack_overflow) => .{ .stack_overflow = state.trap_pc },
        @intFromEnum(std.meta.Tag(TrapReason).stack_underflow) => .{ .stack_underflow = state.trap_pc },
        else => null,
    };
}
