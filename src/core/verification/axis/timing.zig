const std = @import("std");
const report_mod = @import("../report.zig");
const chip8_mod = @import("../../chip8.zig");
const cpu_mod = @import("../../cpu.zig");
const emulation = @import("../../emulation_config.zig");
const spec = @import("../oracle/spec.zig");

// Timing axis. Oracle: `oracle/spec.zig` constants — 60Hz timer tick rate,
// the two independent decrementing counters.
//
// v1 scope is deliberately narrow: synthetic invariants over the timer
// subsystem, no per-instruction cycle count verification (our CPU doesn't
// model cycles per instruction — that would need its own instrumentation
// pass and a reference cycle table from the COSMAC VIP spec). The spec
// notes this axis is the hardest; starting with timer behavior gives us
// regression coverage for the part we can actually check.
//
// Checks:
//   - Delay timer decrements exactly once per `tickTimers` call (one tick = 1/60s).
//   - Sound timer decrements exactly once per `tickTimers` call.
//   - Neither timer underflows below zero.
//   - Both decrement independently — setting one doesn't leak to the other.
//   - Setting a timer from a register via FX15 / FX18 respects the written value.

pub fn runSyntheticInvariants(allocator: std.mem.Allocator) !report_mod.AxisReport {
    var diagnostics: std.ArrayList(report_mod.Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |d| {
            allocator.free(d.kind);
            allocator.free(d.message);
        }
        diagnostics.deinit(allocator);
    }

    try checkDelayDecrement(allocator, &diagnostics);
    try checkDelayStopsAtZero(allocator, &diagnostics);
    try checkTimersIndependent(allocator, &diagnostics);
    try checkFxTimerOpcodes(allocator, &diagnostics);
    try checkOpcodeCycleReporting(allocator, &diagnostics);
    try checkOpcodeCycleOrdering(allocator, &diagnostics);
    try checkDrwCycleScaling(allocator, &diagnostics);
    try checkFxRegisterRangeCycleScaling(allocator, &diagnostics);
    try checkKeyWaitCycles(allocator, &diagnostics);
    try checkDxy0WidthScaling(allocator, &diagnostics);

    const verdict: report_mod.Verdict = if (diagnostics.items.len == 0) .pass else .fail;
    const details = try std.fmt.allocPrint(
        allocator,
        "invariants=10 failing={d}  (timer_freq={d}Hz)",
        .{ diagnostics.items.len, spec.TIMER_FREQUENCY_HZ },
    );
    return .{
        .axis_name = try allocator.dupe(u8, "timing"),
        .rom_id = try allocator.dupe(u8, "spec-invariants"),
        .verdict = verdict,
        .details = details,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn checkDelayDecrement(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    var c = chip8_mod.Chip8.init();
    c.cpu.delay_timer = 30;
    var i: usize = 0;
    while (i < 10) : (i += 1) c.tickTimers();
    if (c.cpu.delay_timer != 20) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "delay_timer_decrement"),
            .message = try std.fmt.allocPrint(
                allocator,
                "expected 20 after 10 ticks from 30, got {d}",
                .{c.cpu.delay_timer},
            ),
        });
    }
}

fn checkDelayStopsAtZero(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    var c = chip8_mod.Chip8.init();
    c.cpu.delay_timer = 3;
    var i: usize = 0;
    while (i < 20) : (i += 1) c.tickTimers();
    if (c.cpu.delay_timer != 0) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "delay_timer_underflow"),
            .message = try std.fmt.allocPrint(
                allocator,
                "delay_timer underflowed or held non-zero past exhaustion (got {d})",
                .{c.cpu.delay_timer},
            ),
        });
    }
}

fn checkTimersIndependent(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    var c = chip8_mod.Chip8.init();
    // Set the two timers to different values; tick; both must decrement
    // by the same amount. Catches the class of bug where one timer's
    // decrement logic leaks into the other (e.g. same variable aliased).
    c.cpu.delay_timer = 10;
    c.cpu.sound_timer = 5;
    var i: usize = 0;
    while (i < 3) : (i += 1) c.tickTimers();
    if (c.cpu.delay_timer != 7) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "delay_not_independent"),
            .message = try std.fmt.allocPrint(allocator, "delay_timer=10 − 3 ticks ≠ 7 (got {d})", .{c.cpu.delay_timer}),
        });
    }
    if (c.cpu.sound_timer != 2) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "sound_not_independent"),
            .message = try std.fmt.allocPrint(allocator, "sound_timer=5 − 3 ticks ≠ 2 (got {d})", .{c.cpu.sound_timer}),
        });
    }
}

fn checkFxTimerOpcodes(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    // FX15 writes V[X] → DT; FX18 writes V[X] → ST. A tiny program drives
    // each once and we observe the result through tickTimers.
    var c = chip8_mod.Chip8.init();
    c.cpu.registers[0] = 0x3C; // 60
    c.cpu.program_counter = 0x200;
    c.memory[0x200] = 0xF0;
    c.memory[0x201] = 0x15; // FX15: DT = V0
    c.memory[0x202] = 0xF0;
    c.memory[0x203] = 0x18; // FX18: ST = V0

    c.cpu.executeInstruction(&c.memory, emulation.profileQuirks(.vip_legacy)) catch {};
    if (c.cpu.delay_timer != 0x3C) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "fx15_delay_write"),
            .message = try std.fmt.allocPrint(allocator, "FX15 didn't set DT=0x3C (got {d})", .{c.cpu.delay_timer}),
        });
    }
    c.cpu.executeInstruction(&c.memory, emulation.profileQuirks(.vip_legacy)) catch {};
    if (c.cpu.sound_timer != 0x3C) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "fx18_sound_write"),
            .message = try std.fmt.allocPrint(allocator, "FX18 didn't set ST=0x3C (got {d})", .{c.cpu.sound_timer}),
        });
    }
}

// Checks the CPU's reported cycle count for a curated fixture set against
// VIP reference values HARD-CODED in this axis. These numbers come from
// Matthew Mikolay's CHIP-8 Technical Reference independently of
// `cpu.cyclesFor`; if either side drifts from the spec, the check
// fires. That's what makes the verification non-tautological: the CPU's
// table and the axis's table have to agree for the test to clear.
fn checkOpcodeCycleReporting(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    // `expected` values below are per-opcode VIP machine cycles, sourced
    // from Mikolay's reference. Do not rewrite them from cpu.zig.
    const Fixture = struct { name: []const u8, bytes: [2]u8, expected: u32 };
    const fixtures = [_]Fixture{
        .{ .name = "CLS (00E0)", .bytes = .{ 0x00, 0xE0 }, .expected = 3078 },
        .{ .name = "JP 0x204 (1nnn)", .bytes = .{ 0x12, 0x04 }, .expected = 12 },
        .{ .name = "CALL 0x300 (2nnn)", .bytes = .{ 0x23, 0x00 }, .expected = 26 },
        .{ .name = "SE V0, 0x00 (3xkk)", .bytes = .{ 0x30, 0x00 }, .expected = 10 },
        .{ .name = "LD V0, 0x42 (6xkk)", .bytes = .{ 0x60, 0x42 }, .expected = 6 },
        .{ .name = "ADD V0, 0x01 (7xkk)", .bytes = .{ 0x70, 0x01 }, .expected = 10 },
        .{ .name = "LD V0, V1 (8xy0)", .bytes = .{ 0x80, 0x10 }, .expected = 12 },
        .{ .name = "OR V0, V1 (8xy1)", .bytes = .{ 0x80, 0x11 }, .expected = 44 },
        .{ .name = "LD I, 0x300 (Annn)", .bytes = .{ 0xA3, 0x00 }, .expected = 12 },
        .{ .name = "RND V0, 0xFF (Cxkk)", .bytes = .{ 0xC0, 0xFF }, .expected = 36 },
        .{ .name = "LD V0, DT (Fx07)", .bytes = .{ 0xF0, 0x07 }, .expected = 10 },
        .{ .name = "LD DT, V0 (Fx15)", .bytes = .{ 0xF0, 0x15 }, .expected = 6 },
        .{ .name = "ADD I, V0 (Fx1E)", .bytes = .{ 0xF0, 0x1E }, .expected = 12 },
        .{ .name = "LD F, V0 (Fx29)", .bytes = .{ 0xF0, 0x29 }, .expected = 20 },
        .{ .name = "LD B, V0 (Fx33)", .bytes = .{ 0xF0, 0x33 }, .expected = 100 },
    };

    for (fixtures) |fx| {
        var c = chip8_mod.Chip8.init();
        c.cpu.program_counter = 0x200;
        c.memory[0x200] = fx.bytes[0];
        c.memory[0x201] = fx.bytes[1];
        // BCD needs I pointing somewhere writable; Fx33 is at the end of
        // the fixtures and unlikely to trap due to unmapped memory, but
        // be defensive.
        c.cpu.index_register = 0x300;
        c.cpu.executeInstruction(&c.memory, emulation.profileQuirks(.vip_legacy)) catch {};

        if (c.cpu.last_instruction_cycles != fx.expected) {
            try diags.append(allocator, .{
                .kind = try allocator.dupe(u8, "opcode_cycles_report"),
                .message = try std.fmt.allocPrint(
                    allocator,
                    "{s}: expected {d} VIP cycles, got {d}",
                    .{ fx.name, fx.expected, c.cpu.last_instruction_cycles },
                ),
            });
        }
    }
}

// DRW's cycle cost is data-dependent: VIP base 3812 + 68 per sprite row.
// The CPU's sprite draw sets `last_instruction_cycles` from actual rows
// rasterized. This check runs three 8×N sprites and verifies the cost
// grows in 68-cycle steps.
fn checkDrwCycleScaling(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    const cases = [_]struct { rows: u8, expected: u32 }{
        .{ .rows = 1, .expected = 3812 + 68 * 1 },
        .{ .rows = 4, .expected = 3812 + 68 * 4 },
        .{ .rows = 15, .expected = 3812 + 68 * 15 },
    };
    for (cases) |ck| {
        var c = chip8_mod.Chip8.init();
        c.cpu.program_counter = 0x200;
        // DRW V0, V1, N with V0=V1=0 draws an 8×N sprite at top-left.
        c.memory[0x200] = 0xD0;
        c.memory[0x201] = 0x10 | ck.rows;
        c.cpu.registers[0] = 0;
        c.cpu.registers[1] = 0;
        c.cpu.index_register = 0x300;
        // Fill sprite source with 0xFF so every row lights pixels.
        var i: usize = 0;
        while (i < ck.rows) : (i += 1) c.memory[0x300 + i] = 0xFF;
        c.cpu.executeInstruction(&c.memory, emulation.profileQuirks(.vip_legacy)) catch {};

        if (c.cpu.last_instruction_cycles != ck.expected) {
            try diags.append(allocator, .{
                .kind = try allocator.dupe(u8, "drw_cycle_scaling"),
                .message = try std.fmt.allocPrint(
                    allocator,
                    "DRW 8x{d}: expected {d}, got {d}",
                    .{ ck.rows, ck.expected, c.cpu.last_instruction_cycles },
                ),
            });
        }
        if (c.cpu.last_draw_rows != ck.rows) {
            try diags.append(allocator, .{
                .kind = try allocator.dupe(u8, "drw_row_reporting"),
                .message = try std.fmt.allocPrint(
                    allocator,
                    "DRW 8x{d}: last_draw_rows expected {d}, got {d}",
                    .{ ck.rows, ck.rows, c.cpu.last_draw_rows },
                ),
            });
        }
    }
}

// Relative-cost invariants from the VIP reference. If someone tweaks the
// table and accidentally inverts the ordering (e.g. makes CLS cheaper than
// JP), this catches it before it ships. Cheap tripwire for "cycle values
// still look like VIP" without listing every opcode.
fn checkOpcodeCycleOrdering(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    const Check = struct { a: cpu_mod.Instruction, b: cpu_mod.Instruction, rel: enum { gt, lt, eq }, label: []const u8 };
    const checks = [_]Check{
        // CLS (full framebuffer clear) >> JP (just address write)
        .{ .a = .cls, .b = .{ .jmp = 0 }, .rel = .gt, .label = "cls > jp" },
        // DRW (sprite raster) >> CLS (bulk clear)
        .{ .a = .{ .drw = .{ .vx = 0, .vy = 0, .n = 0 } }, .b = .cls, .rel = .gt, .label = "drw > cls" },
        // ALU ops > LD Vx, byte
        .{ .a = .{ .or_reg = .{ .vx = 0, .vy = 0 } }, .b = .{ .ld_byte = .{ .vx = 0, .byte = 0 } }, .rel = .gt, .label = "alu > ld_byte" },
        // SE (skip) > LD (no skip)
        .{ .a = .{ .se_byte = .{ .vx = 0, .byte = 0 } }, .b = .{ .ld_byte = .{ .vx = 0, .byte = 0 } }, .rel = .gt, .label = "se_byte > ld_byte" },
    };

    for (checks) |ck| {
        const a = cpu_mod.cyclesFor(ck.a);
        const b = cpu_mod.cyclesFor(ck.b);
        const ok = switch (ck.rel) {
            .gt => a > b,
            .lt => a < b,
            .eq => a == b,
        };
        if (!ok) {
            try diags.append(allocator, .{
                .kind = try allocator.dupe(u8, "opcode_cycles_ordering"),
                .message = try std.fmt.allocPrint(allocator, "{s}: {d} vs {d}", .{ ck.label, a, b }),
            });
        }
    }
}

// FX55 / FX65 on VIP loop one register at a time — cost scales with
// (X+1). Verify with X=0, X=5, X=15 and the formula `14 + 14*(X+1)`.
fn checkFxRegisterRangeCycleScaling(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    const xs = [_]u4{ 0, 5, 15 };
    for (xs) |x| {
        // FX55 store
        {
            var c = chip8_mod.Chip8.init();
            c.cpu.program_counter = 0x200;
            c.memory[0x200] = 0xF0 | @as(u8, x);
            c.memory[0x201] = 0x55;
            c.cpu.index_register = 0x400;
            c.cpu.executeInstruction(&c.memory, emulation.profileQuirks(.vip_legacy)) catch {};
            const expected: u32 = 14 + 14 * @as(u32, @as(u32, x) + 1);
            if (c.cpu.last_instruction_cycles != expected) {
                try diags.append(allocator, .{
                    .kind = try allocator.dupe(u8, "fx55_cycle_scaling"),
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "FX55 X={d}: expected {d}, got {d}",
                        .{ x, expected, c.cpu.last_instruction_cycles },
                    ),
                });
            }
        }
        // FX65 load
        {
            var c = chip8_mod.Chip8.init();
            c.cpu.program_counter = 0x200;
            c.memory[0x200] = 0xF0 | @as(u8, x);
            c.memory[0x201] = 0x65;
            c.cpu.index_register = 0x400;
            c.cpu.executeInstruction(&c.memory, emulation.profileQuirks(.vip_legacy)) catch {};
            const expected: u32 = 14 + 14 * @as(u32, @as(u32, x) + 1);
            if (c.cpu.last_instruction_cycles != expected) {
                try diags.append(allocator, .{
                    .kind = try allocator.dupe(u8, "fx65_cycle_scaling"),
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "FX65 X={d}: expected {d}, got {d}",
                        .{ x, expected, c.cpu.last_instruction_cycles },
                    ),
                });
            }
        }
    }
}

// FX0A blocks polling; one call to executeInstruction is one poll, and
// the VIP reference pegs that at ~40 machine cycles.
fn checkKeyWaitCycles(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    var c = chip8_mod.Chip8.init();
    c.cpu.program_counter = 0x200;
    c.memory[0x200] = 0xF0;
    c.memory[0x201] = 0x0A;
    c.cpu.executeInstruction(&c.memory, emulation.profileQuirks(.vip_legacy)) catch {};
    const expected: u32 = 40;
    if (c.cpu.last_instruction_cycles != expected) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "fx0a_cycle_report"),
            .message = try std.fmt.allocPrint(
                allocator,
                "FX0A per-poll: expected {d}, got {d}",
                .{ expected, c.cpu.last_instruction_cycles },
            ),
        });
    }
}

// SCHIP's DXY0 draws 16-pixel-wide sprite rows vs DXYN's 8 — per-row cost
// should roughly double. The CPU scales 68 cycles/row by (width/8), so a
// 16x16 sprite in hires mode reports `3812 + 136 * 16`.
fn checkDxy0WidthScaling(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    var c = chip8_mod.Chip8.init();
    // Force SCHIP-style hires so DXY0 actually produces a 16x16 sprite.
    const schip = emulation.profileQuirks(.schip_11);
    c.cpu.display_mode = .hires;
    c.cpu.program_counter = 0x200;
    c.memory[0x200] = 0xD0;
    c.memory[0x201] = 0x10; // DXY0 — V0, V1, n=0 → 16x16 in hires
    c.cpu.registers[0] = 0;
    c.cpu.registers[1] = 0;
    c.cpu.index_register = 0x300;
    // Fill 32 bytes (16 rows × 2 bytes per row) with 0xFF.
    var i: usize = 0;
    while (i < 32) : (i += 1) c.memory[0x300 + i] = 0xFF;
    c.cpu.executeInstruction(&c.memory, schip) catch {};

    // Base 3812 + (68 * 16/8) cycles per row × 16 rows = 3812 + 136 * 16.
    const expected: u32 = 3812 + 136 * 16;
    if (c.cpu.last_instruction_cycles != expected) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "dxy0_width_scaling"),
            .message = try std.fmt.allocPrint(
                allocator,
                "DXY0 16x16: expected {d}, got {d}",
                .{ expected, c.cpu.last_instruction_cycles },
            ),
        });
    }
}

test "runSyntheticInvariants passes on a healthy emulator" {
    const allocator = std.testing.allocator;
    const rep = try runSyntheticInvariants(allocator);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.verdict == .pass);
}
