const std = @import("std");
const report_mod = @import("../report.zig");
const chip8_mod = @import("../../chip8.zig");
const emulation = @import("../../emulation_config.zig");

// Sound axis. Oracle: CHIP-8 spec (60Hz timer decrement, beep-active iff
// sound_timer > 0).
//
// v1 scope: synthetic behavior only — verify the timer itself decrements
// correctly when we tick at 60Hz. ROM-driven analysis via Timendus's
// 7-beep.ch8 comes later (needs the test ROM bundled).

pub fn runSyntheticInvariants(allocator: std.mem.Allocator) !report_mod.AxisReport {
    var diagnostics: std.ArrayList(report_mod.Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |d| {
            allocator.free(d.kind);
            allocator.free(d.message);
        }
        diagnostics.deinit(allocator);
    }

    try checkDecrementsOnTick(allocator, &diagnostics);
    try checkStopsAtZero(allocator, &diagnostics);

    const verdict: report_mod.Verdict = if (diagnostics.items.len == 0) .pass else .fail;
    const details = try std.fmt.allocPrint(
        allocator,
        "invariants=2 failing={d}",
        .{diagnostics.items.len},
    );
    return .{
        .axis_name = try allocator.dupe(u8, "sound"),
        .rom_id = try allocator.dupe(u8, "spec-invariants"),
        .verdict = verdict,
        .details = details,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn checkDecrementsOnTick(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    var c = chip8_mod.Chip8.init();
    c.cpu.sound_timer = 30;
    var i: usize = 0;
    while (i < 10) : (i += 1) c.tickTimers();
    if (c.cpu.sound_timer != 20) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "sound_timer_decrement"),
            .message = try std.fmt.allocPrint(
                allocator,
                "expected sound_timer=20 after 10 ticks from 30, got {d}",
                .{c.cpu.sound_timer},
            ),
        });
    }
}

fn checkStopsAtZero(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    var c = chip8_mod.Chip8.init();
    c.cpu.sound_timer = 3;
    var i: usize = 0;
    while (i < 20) : (i += 1) c.tickTimers();
    if (c.cpu.sound_timer != 0) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "sound_timer_underflow"),
            .message = try std.fmt.allocPrint(
                allocator,
                "sound_timer underflowed or held non-zero past exhaustion (got {d})",
                .{c.cpu.sound_timer},
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
