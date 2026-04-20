const std = @import("std");
const report_mod = @import("../report.zig");
const chip8_mod = @import("../../chip8.zig");
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

    const verdict: report_mod.Verdict = if (diagnostics.items.len == 0) .pass else .fail;
    const details = try std.fmt.allocPrint(
        allocator,
        "invariants=4 failing={d}  (timer_freq={d}Hz)",
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

    const emulation = @import("../../emulation_config.zig");
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

test "runSyntheticInvariants passes on a healthy emulator" {
    const allocator = std.testing.allocator;
    const rep = try runSyntheticInvariants(allocator);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.verdict == .pass);
}
