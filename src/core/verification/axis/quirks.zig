const std = @import("std");
const report_mod = @import("../report.zig");
const chip8_mod = @import("../../chip8.zig");
const emulation = @import("../../emulation_config.zig");
const test_suite = @import("../test_suite.zig");
const ref_fb = @import("../oracle/reference_framebuffers.zig");

// Quirks axis. Oracle: Timendus's `5-quirks.ch8`.
//
// 5-quirks normally asks the user to pick a platform from the keypad. It
// also supports a programmatic override: writing a byte to memory[0x1FF]
// before execution skips the menu and runs under that platform:
//
//   1 = CHIP-8           (originalChip8)
//   2 = SUPER-CHIP modern (superchip)
//   3 = XO-CHIP          (xochip)
//   4 = SUPER-CHIP legacy (superchip1)
//
// We run the ROM once per platform code, each with the matching profile
// wired into the emulator, and produce one AxisReport per run. The verdict
// per run is:
//   - If a reference framebuffer is available and matches → PASS.
//   - If a reference is available and diverges → FAIL + diff diagnostic.
//   - Otherwise fall through to a lit-pixel heuristic: the quirks test
//     always renders a dense result grid; a crashed run leaves the display
//     mostly blank. ≥100 lit pixels = PASS-heuristic.

pub const PlatformRun = struct {
    code: u8, // memory[0x1FF] value
    platform_id: []const u8, // chip-8-database platform id
    profile: emulation.QuirkProfile,
};

pub const PLATFORM_RUNS: []const PlatformRun = &.{
    .{ .code = 1, .platform_id = "originalChip8", .profile = .vip_legacy },
    .{ .code = 2, .platform_id = "superchip", .profile = .schip_11 },
    .{ .code = 3, .platform_id = "xochip", .profile = .xo_chip },
    .{ .code = 4, .platform_id = "superchip1", .profile = .schip_11 },
};

pub const RunOptions = struct {
    cycles: u32 = 200_000,
    // Optional reference store; looked up by rom sha1 + cycle count.
    store: ?*const ref_fb.Store = null,
    rom_sha1: ?[]const u8 = null,
    rom_id: []const u8 = "5-quirks",
};

// Runs 5-quirks under every supported platform. Returns one AxisReport per
// platform; caller owns every slot in the slice.
pub fn runForRom(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    opts: RunOptions,
) ![]report_mod.AxisReport {
    var out = try allocator.alloc(report_mod.AxisReport, PLATFORM_RUNS.len);
    var populated: usize = 0;
    errdefer {
        for (out[0..populated]) |r| r.deinit(allocator);
        allocator.free(out);
    }
    for (PLATFORM_RUNS, 0..) |run, idx| {
        out[idx] = try runOnePlatform(allocator, rom_bytes, run, opts);
        populated = idx + 1;
    }
    return out;
}

fn runOnePlatform(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    run: PlatformRun,
    opts: RunOptions,
) !report_mod.AxisReport {
    var chip8 = chip8_mod.Chip8.initWithConfig(emulation.EmulationConfig.init(run.profile));
    chip8.loadRom(rom_bytes) catch |err| {
        return try report_mod.AxisReport.simple(
            allocator,
            "quirks",
            opts.rom_id,
            .harness_error,
            @errorName(err),
        );
    };
    // Programmatic platform select — exactly what Timendus's headless test
    // harness does.
    chip8.memory[0x1FF] = run.code;

    var ran: u32 = 0;
    while (ran < opts.cycles) : (ran += 1) {
        chip8.update() catch break;
        if (chip8.cpu.trap_reason != null) break;
        if (ran % 17 == 0) chip8.tickTimers();
    }

    // Snapshot framebuffer.
    const w = chip8.cpu.displayWidth();
    const h = chip8.cpu.displayHeight();
    const pixels = try allocator.alloc(u8, w * h);
    defer allocator.free(pixels);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) pixels[y * w + x] = @as(u8, chip8.cpu.compositePixel(x, y));
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(pixels);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    var hash_hex_buf: [64]u8 = undefined;
    const hash_hex = std.fmt.bytesToHex(&hash, .lower);
    @memcpy(hash_hex_buf[0..], &hash_hex);

    const run_id = try std.fmt.allocPrint(allocator, "{s} @ {s}", .{ opts.rom_id, run.platform_id });
    errdefer allocator.free(run_id);

    if (chip8.cpu.trap_reason) |trap| {
        var trap_buf: [128]u8 = undefined;
        const trap_str = trap.format(&trap_buf);
        const details = try std.fmt.allocPrint(allocator, "trapped at PC=0x{X:0>4} ({s}) after {d} cycles", .{ chip8.cpu.program_counter, trap_str, ran });
        return .{
            .axis_name = try allocator.dupe(u8, "quirks"),
            .rom_id = run_id,
            .verdict = .fail,
            .details = details,
            .diagnostics = &.{},
        };
    }

    // Reference-hash verdict wins when available.
    if (opts.store) |store| {
        if (opts.rom_sha1) |sha1| {
            if (store.snapshotAt(sha1, ran)) |expected| {
                if (std.ascii.eqlIgnoreCase(expected, hash_hex_buf[0..])) {
                    const details = try std.fmt.allocPrint(allocator, "observed_hash={s} ran={d}", .{ hash_hex_buf[0..], ran });
                    return .{
                        .axis_name = try allocator.dupe(u8, "quirks"),
                        .rom_id = run_id,
                        .verdict = .pass,
                        .details = details,
                        .diagnostics = &.{},
                    };
                }
                const details = try std.fmt.allocPrint(allocator, "observed_hash={s} ran={d}", .{ hash_hex_buf[0..], ran });
                const snapshot = try test_suite.renderAsciiAlloc(allocator, pixels, @intCast(w), @intCast(h));
                defer allocator.free(snapshot);
                var diag = try allocator.alloc(report_mod.Diagnostic, 1);
                diag[0] = .{
                    .kind = try allocator.dupe(u8, "framebuffer_mismatch"),
                    .message = try std.fmt.allocPrint(allocator, "expected={s} observed={s} snapshot:\n{s}", .{ expected, hash_hex_buf[0..], snapshot }),
                };
                return .{
                    .axis_name = try allocator.dupe(u8, "quirks"),
                    .rom_id = run_id,
                    .verdict = .fail,
                    .details = details,
                    .diagnostics = diag,
                };
            }
        }
    }

    // Heuristic fallback.
    var lit: u32 = 0;
    for (pixels) |p| if (p != 0) {
        lit += 1;
    };
    const verdict: report_mod.Verdict = if (lit >= 100) .pass else .fail;
    const details = try std.fmt.allocPrint(
        allocator,
        "observed_hash={s} ran={d} lit={d}/{d}  (heuristic — supply reference framebuffer for precise grading)",
        .{ hash_hex_buf[0..], ran, lit, @as(u32, @intCast(w * h)) },
    );
    const diagnostics: []report_mod.Diagnostic = if (verdict == .fail) blk: {
        const snapshot = try test_suite.renderAsciiAlloc(allocator, pixels, @intCast(w), @intCast(h));
        defer allocator.free(snapshot);
        var diag = try allocator.alloc(report_mod.Diagnostic, 1);
        diag[0] = .{
            .kind = try allocator.dupe(u8, "blank_framebuffer"),
            .message = try std.fmt.allocPrint(allocator, "only {d} lit pixels; emulator likely crashed or hung. Snapshot:\n{s}", .{ lit, snapshot }),
        };
        break :blk diag;
    } else try allocator.alloc(report_mod.Diagnostic, 0);

    return .{
        .axis_name = try allocator.dupe(u8, "quirks"),
        .rom_id = run_id,
        .verdict = verdict,
        .details = details,
        .diagnostics = diagnostics,
    };
}

test "runForRom emits one report per platform" {
    const allocator = std.testing.allocator;
    // Use an infinite-loop ROM so the run doesn't trap; the heuristic will
    // fail (blank framebuffer) but we still expect 4 reports back.
    const rom = [_]u8{ 0x12, 0x00 }; // JP 0x200
    const reports = try runForRom(allocator, &rom, .{});
    defer {
        for (reports) |r| r.deinit(allocator);
        allocator.free(reports);
    }
    try std.testing.expectEqual(@as(usize, 4), reports.len);
    try std.testing.expectEqualStrings("quirks", reports[0].axis_name);
}
