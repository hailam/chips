const std = @import("std");
const report_mod = @import("../report.zig");
const chip8_mod = @import("../../chip8.zig");
const emulation = @import("../../emulation_config.zig");
const test_suite = @import("../test_suite.zig");

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

// Run a ROM (typically Timendus's 7-beep.ch8) and check that the sound
// timer actually got set non-zero at some point. If the emulator never
// activates the beep, the test ROM is being misinterpreted — FX18 is a
// single-opcode behavior that every CHIP-8 profile shares.
pub const RomRunOptions = struct {
    cycles: u32 = 200_000,
    profile: emulation.QuirkProfile = .vip_legacy,
    rom_id: []const u8 = "7-beep",
};

pub fn runForRom(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    opts: RomRunOptions,
) !report_mod.AxisReport {
    var chip8 = chip8_mod.Chip8.initWithConfig(emulation.EmulationConfig.init(opts.profile));
    chip8.loadRom(rom_bytes) catch |err| {
        return try report_mod.AxisReport.simple(
            allocator,
            "sound",
            opts.rom_id,
            .harness_error,
            @errorName(err),
        );
    };

    var max_sound_timer: u8 = 0;
    var beep_active_ticks: u32 = 0;
    var ran: u32 = 0;
    while (ran < opts.cycles) : (ran += 1) {
        chip8.update() catch break;
        if (chip8.cpu.trap_reason != null) break;
        if (chip8.cpu.sound_timer > max_sound_timer) max_sound_timer = chip8.cpu.sound_timer;
        if (chip8.cpu.sound_timer > 0) beep_active_ticks += 1;
        if (ran % 17 == 0) chip8.tickTimers();
    }

    const verdict: report_mod.Verdict = if (max_sound_timer > 0) .pass else .fail;
    const details = try std.fmt.allocPrint(
        allocator,
        "max_sound_timer={d} beep_active_ticks={d} ran={d}",
        .{ max_sound_timer, beep_active_ticks, ran },
    );
    const diagnostics: []report_mod.Diagnostic = if (verdict == .fail) blk: {
        var diag = try allocator.alloc(report_mod.Diagnostic, 1);
        diag[0] = .{
            .kind = try allocator.dupe(u8, "no_beep"),
            .message = try allocator.dupe(u8, "sound_timer stayed at 0 for the entire run — FX18 not reached, or quirk misconfigured"),
        };
        break :blk diag;
    } else try allocator.alloc(report_mod.Diagnostic, 0);
    _ = test_suite; // referenced so the import stays meaningful

    return .{
        .axis_name = try allocator.dupe(u8, "sound"),
        .rom_id = try allocator.dupe(u8, opts.rom_id),
        .verdict = verdict,
        .details = details,
        .diagnostics = diagnostics,
    };
}

test "runForRom marks a blank ROM as fail (no beep ever fires)" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{ 0x12, 0x00 }; // JP 0x200 — no sound
    const rep = try runForRom(allocator, &rom, .{ .cycles = 2000 });
    defer rep.deinit(allocator);
    try std.testing.expect(rep.verdict == .fail);
}

test "runSyntheticInvariants passes on a healthy emulator" {
    const allocator = std.testing.allocator;
    const rep = try runSyntheticInvariants(allocator);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.verdict == .pass);
}
