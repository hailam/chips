const std = @import("std");

pub const MAX_MICRO_OPS: usize = 12;
pub const NO_KEY_INDEX: u8 = 0xFF;

pub const Lane = enum {
    pc,
    memory,
    decode,
    registers,
    stack,
    display,
    keypad,
    timers,
};

pub const TraceTag = enum {
    alu,
    load,
    store,
    key,
    draw,
    call,
    ret,
    jump,
    skip,
    timer,
    fetch,
    misc,
};

pub const TraceEndpoint = union(enum) {
    none,
    pc: u16,
    memory: struct { addr: u16, len: u8 },
    decode,
    index: u16,
    registers: struct { start: u4, len: u8 },
    stack: struct { index: u8, len: u8 },
    display: struct {
        x: u8,
        y: u8,
        w: u8,
        h: u8,
        plane_mask: u8 = 1,
        wraps: bool = false,
        full_screen: bool = false,
    },
    keypad: struct {
        key: u8 = NO_KEY_INDEX,
        target_register: u8 = 0,
        waiting: bool = false,
    },
    timers: struct {
        delay: bool = false,
        sound: bool = false,
    },
};

pub const MicroOpKind = enum {
    fetch_opcode,
    decode_opcode,
    read_mem_range,
    write_mem_range,
    read_reg,
    write_reg,
    read_keypad,
    write_timer,
    read_timer,
    push_stack,
    pop_stack,
    branch_pc,
    draw_sprite,
    wait_key,
};

pub const MicroOp = struct {
    kind: MicroOpKind,
    source: TraceEndpoint = .none,
    destination: TraceEndpoint = .none,
};

pub const TraceEntry = struct {
    pc: u16 = 0,
    opcode_hi: u16 = 0,
    opcode_lo: u16 = 0,
    byte_len: u8 = 2,
    tag: TraceTag = .fetch,
    source: TraceEndpoint = .none,
    destination: TraceEndpoint = .none,
    waits_for_key: bool = false,
    micro_ops: [MAX_MICRO_OPS]MicroOp = [_]MicroOp{EMPTY_MICRO_OP} ** MAX_MICRO_OPS,
    micro_op_len: u8 = 0,

    pub fn init(pc: u16, opcode_hi: u16, tag: TraceTag) TraceEntry {
        return .{
            .pc = pc,
            .opcode_hi = opcode_hi,
            .tag = tag,
        };
    }

    pub fn addMicroOp(self: *TraceEntry, micro_op: MicroOp) void {
        if (self.micro_op_len >= MAX_MICRO_OPS) return;
        self.micro_ops[self.micro_op_len] = micro_op;
        self.micro_op_len += 1;
    }
};

pub const Connector = struct {
    from: Lane,
    to: Lane,
};

const EMPTY_MICRO_OP = MicroOp{
    .kind = .fetch_opcode,
    .source = .none,
    .destination = .none,
};

pub fn endpointLane(endpoint: TraceEndpoint) ?Lane {
    return switch (endpoint) {
        .none => null,
        .pc => .pc,
        .memory => .memory,
        .decode => .decode,
        .index => .registers,
        .registers => .registers,
        .stack => .stack,
        .display => .display,
        .keypad => .keypad,
        .timers => .timers,
    };
}

pub fn microOpConnector(micro_op: MicroOp) ?Connector {
    const from = endpointLane(micro_op.source) orelse return null;
    const to = endpointLane(micro_op.destination) orelse return null;
    if (from == to) return null;
    return .{ .from = from, .to = to };
}

pub fn pcEndpoint(pc: u16) TraceEndpoint {
    return .{ .pc = pc };
}

pub fn memoryEndpoint(addr: u16, len: usize) TraceEndpoint {
    return .{ .memory = .{
        .addr = addr,
        .len = @intCast(@min(len, std.math.maxInt(u8))),
    } };
}

pub fn registersEndpoint(start: u4, len: usize) TraceEndpoint {
    return .{ .registers = .{
        .start = start,
        .len = @intCast(@min(len, std.math.maxInt(u8))),
    } };
}

pub fn indexEndpoint(value: u16) TraceEndpoint {
    return .{ .index = value };
}

pub fn stackEndpoint(index: usize, len: usize) TraceEndpoint {
    return .{ .stack = .{
        .index = @intCast(@min(index, std.math.maxInt(u8))),
        .len = @intCast(@min(len, std.math.maxInt(u8))),
    } };
}

pub fn displayEndpoint(x: usize, y: usize, w: usize, h: usize, plane_mask: u8, wraps: bool, full_screen: bool) TraceEndpoint {
    return .{ .display = .{
        .x = @intCast(@min(x, std.math.maxInt(u8))),
        .y = @intCast(@min(y, std.math.maxInt(u8))),
        .w = @intCast(@min(w, std.math.maxInt(u8))),
        .h = @intCast(@min(h, std.math.maxInt(u8))),
        .plane_mask = plane_mask,
        .wraps = wraps,
        .full_screen = full_screen,
    } };
}

pub fn keypadEndpoint(key: ?u4, target_register: ?u4, waiting: bool) TraceEndpoint {
    return .{ .keypad = .{
        .key = if (key) |value| value else NO_KEY_INDEX,
        .target_register = if (target_register) |value| value else 0,
        .waiting = waiting,
    } };
}

pub fn timersEndpoint(delay: bool, sound: bool) TraceEndpoint {
    return .{ .timers = .{ .delay = delay, .sound = sound } };
}
