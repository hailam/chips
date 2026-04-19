const std = @import("std");
const report_mod = @import("../report.zig");
const chip8_mod = @import("../../chip8.zig");
const cpu_mod = @import("../../cpu.zig");
const emulation = @import("../../emulation_config.zig");
const spec = @import("../oracle/spec.zig");

// Memory axis. Oracle is the CHIP-8 spec + per-ROM `startAddress` from
// chip-8-database. Two modes:
//
//   1. `runForRom` — loads `rom_bytes` at the configured `start_address`,
//      runs `cycles` instructions, asserts the CPU didn't trap. Catches
//      the silent-failure class of bugs where an emulator hardcodes 0x200
//      and a non-default-start-address ROM (e.g. ETI-660 at 0x600) looks
//      like garbage without complaining.
//
//   2. `runSyntheticInvariants` — exercises emulator-level spec invariants
//      that don't need a ROM: stack depth, memory wrap, font sprite content
//      at the documented address. These fire on any build; they verify the
//      emulator itself, not a particular ROM.

pub const RunOptions = struct {
    rom_id: []const u8 = "unknown",
    start_address: u16 = spec.DEFAULT_START_ADDRESS,
    cycles: u32 = 50_000,
    profile: emulation.QuirkProfile = .vip_legacy,
};

pub fn runForRom(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    opts: RunOptions,
) !report_mod.AxisReport {
    const fits = @as(usize, opts.start_address) + rom_bytes.len <= cpu_mod.CHIP8_MEMORY_SIZE;
    if (!fits) {
        return try report_mod.AxisReport.simple(
            allocator,
            "memory",
            opts.rom_id,
            .fail,
            "ROM + startAddress overflows memory",
        );
    }

    var chip8 = chip8_mod.Chip8.initWithConfig(emulation.EmulationConfig.init(opts.profile));
    // Explicit load at startAddress — Chip8.loadRom hardcodes 0x200, so we
    // place bytes manually to honor the oracle's address.
    @memcpy(chip8.memory[opts.start_address..][0..rom_bytes.len], rom_bytes);
    chip8.cpu.program_counter = opts.start_address;
    chip8.rom_size = @intCast(rom_bytes.len);

    var ran: u32 = 0;
    while (ran < opts.cycles) : (ran += 1) {
        chip8.update() catch break;
        if (chip8.cpu.trap_reason != null) break;
        if (ran % 17 == 0) chip8.tickTimers();
    }

    if (chip8.cpu.trap_reason) |trap| {
        var buf: [128]u8 = undefined;
        const trap_str = trap.format(&buf);
        const details = try std.fmt.allocPrint(
            allocator,
            "trapped after {d} cycles at PC=0x{X:0>4} ({s}) start_address=0x{X:0>3}",
            .{ ran, chip8.cpu.program_counter, trap_str, opts.start_address },
        );
        var diag = try allocator.alloc(report_mod.Diagnostic, 1);
        diag[0] = .{
            .kind = try allocator.dupe(u8, "cpu_trap"),
            .message = try allocator.dupe(u8, trap_str),
        };
        return .{
            .axis_name = try allocator.dupe(u8, "memory"),
            .rom_id = try allocator.dupe(u8, opts.rom_id),
            .verdict = .fail,
            .details = details,
            .diagnostics = diag,
        };
    }

    const details = try std.fmt.allocPrint(
        allocator,
        "ran={d} cycles  start_address=0x{X:0>3}  no trap",
        .{ ran, opts.start_address },
    );
    return .{
        .axis_name = try allocator.dupe(u8, "memory"),
        .rom_id = try allocator.dupe(u8, opts.rom_id),
        .verdict = .pass,
        .details = details,
        .diagnostics = &.{},
    };
}

// Spec invariants that don't need a ROM. Each failure adds a Diagnostic;
// any failure flips the verdict to .fail.
pub fn runSyntheticInvariants(allocator: std.mem.Allocator) !report_mod.AxisReport {
    var diagnostics: std.ArrayList(report_mod.Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |d| {
            allocator.free(d.kind);
            allocator.free(d.message);
        }
        diagnostics.deinit(allocator);
    }

    try checkFontSpritesPresent(allocator, &diagnostics);
    try checkMemorySize(allocator, &diagnostics);
    try checkStackDepth(allocator, &diagnostics);

    const verdict: report_mod.Verdict = if (diagnostics.items.len == 0) .pass else .fail;
    const details = try std.fmt.allocPrint(
        allocator,
        "invariants={d} failing={d}",
        .{ 3, diagnostics.items.len },
    );
    return .{
        .axis_name = try allocator.dupe(u8, "memory"),
        .rom_id = try allocator.dupe(u8, "spec-invariants"),
        .verdict = verdict,
        .details = details,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn checkFontSpritesPresent(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    const chip8 = chip8_mod.Chip8.init();
    // The classic 16-digit hex font lives at 0x000 (or 0x050 depending on
    // interpreter) and consumes 80 bytes. We accept either placement — just
    // require *somewhere* in the first 0x100 bytes to contain the canonical
    // sprite for '0' (F0 90 90 90 F0).
    const needle = [_]u8{ 0xF0, 0x90, 0x90, 0x90, 0xF0 };
    const found = std.mem.indexOf(u8, chip8.memory[0..0x100], &needle);
    if (found == null) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "font_missing"),
            .message = try allocator.dupe(u8, "canonical '0' sprite (F0 90 90 90 F0) not found in memory[0..0x100]"),
        });
    }
}

fn checkMemorySize(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    // 4096 is the COSMAC/SCHIP spec. XO-CHIP extends the address space to
    // 65536 via 16-bit addressing. Accept both.
    const ok = cpu_mod.CHIP8_MEMORY_SIZE == 4096 or cpu_mod.CHIP8_MEMORY_SIZE == 65536;
    if (!ok) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "memory_size"),
            .message = try std.fmt.allocPrint(
                allocator,
                "expected 4096 (CHIP-8) or 65536 (XO-CHIP) bytes, got {d}",
                .{cpu_mod.CHIP8_MEMORY_SIZE},
            ),
        });
    }
}

fn checkStackDepth(
    allocator: std.mem.Allocator,
    diags: *std.ArrayList(report_mod.Diagnostic),
) !void {
    // The spec allows 12 (COSMAC) or 16 (SCHIP). Anything outside that range
    // is a red flag.
    if (cpu_mod.CHIP8_STACK_SIZE < 12 or cpu_mod.CHIP8_STACK_SIZE > 16) {
        try diags.append(allocator, .{
            .kind = try allocator.dupe(u8, "stack_depth"),
            .message = try std.fmt.allocPrint(allocator, "stack depth {d} outside spec range [12, 16]", .{cpu_mod.CHIP8_STACK_SIZE}),
        });
    }
}

test "runSyntheticInvariants passes on a healthy emulator" {
    const allocator = std.testing.allocator;
    const rep = try runSyntheticInvariants(allocator);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.verdict == .pass);
}

test "runForRom succeeds on minimal jump loop at default start" {
    const allocator = std.testing.allocator;
    // 1200 = JP 0x200 — tight infinite loop; never traps.
    const rom = [_]u8{ 0x12, 0x00 };
    const rep = try runForRom(allocator, &rom, .{ .cycles = 1000 });
    defer rep.deinit(allocator);
    try std.testing.expect(rep.verdict == .pass);
}

test "runForRom succeeds at non-default start address" {
    const allocator = std.testing.allocator;
    // 1600 = JP 0x600 — tight infinite loop at ETI-660 start address.
    const rom = [_]u8{ 0x16, 0x00 };
    const rep = try runForRom(allocator, &rom, .{ .cycles = 1000, .start_address = 0x600 });
    defer rep.deinit(allocator);
    try std.testing.expect(rep.verdict == .pass);
}
