const std = @import("std");
const report_mod = @import("../report.zig");
const test_suite = @import("../test_suite.zig");
const emulation = @import("../../emulation_config.zig");

// Opcode axis. Oracle: Timendus's 3-corax+.ch8 (and 4-flags.ch8 later).
//
// v1 verdict policy:
//   - Run the test ROM for its default cycle budget.
//   - Compute framebuffer hash + render an ASCII snapshot.
//   - If caller supplies a reference hash, compare → pass/fail.
//   - Otherwise use a coarse heuristic: the corax+ screen draws ~24 grid
//     cells with visible glyphs; a crashed/hung run leaves the display
//     nearly empty. We pass when the lit-pixel count crosses a reasonable
//     floor. This is a placeholder for the full per-cell parser — it
//     catches catastrophic emulator failures (traps, wrong opcode decode)
//     without claiming per-opcode coverage.
//
// `details` on the returned AxisReport always includes the observed hex
// hash so the user can capture it as a future reference.

pub const RunOptions = struct {
    // Optional reference framebuffer hash (SHA-256, lowercase hex) to
    // compare against. null → use the heuristic.
    reference_hash: ?[]const u8 = null,
    cycles: ?u32 = null,
    profile: emulation.QuirkProfile = .vip_legacy,
    rom_id: []const u8 = "3-corax+",
};

pub fn runCoraxPlus(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    opts: RunOptions,
) !report_mod.AxisReport {
    const result = test_suite.runHeadless(allocator, .corax_plus, rom_bytes, opts.cycles, opts.profile) catch |err| {
        return try report_mod.AxisReport.simple(
            allocator,
            "opcodes",
            opts.rom_id,
            .harness_error,
            @errorName(err),
        );
    };
    defer test_suite.freeRunResult(allocator, result);

    const hash_hex = try hexEncode(allocator, result.framebuffer_hash);
    errdefer allocator.free(hash_hex);

    // Hash-based verdict wins when a reference is supplied.
    if (opts.reference_hash) |ref| {
        const verdict: report_mod.Verdict = if (std.ascii.eqlIgnoreCase(ref, hash_hex)) .pass else .fail;
        const details = try std.fmt.allocPrint(allocator, "observed_hash={s} ran={d}", .{ hash_hex, result.cycles_run });
        const diagnostics = if (verdict == .fail) try buildMismatchDiagnostics(allocator, ref, hash_hex, result) else try allocator.alloc(report_mod.Diagnostic, 0);
        allocator.free(hash_hex);
        return .{
            .axis_name = try allocator.dupe(u8, "opcodes"),
            .rom_id = try allocator.dupe(u8, opts.rom_id),
            .verdict = verdict,
            .details = details,
            .diagnostics = diagnostics,
        };
    }

    // Heuristic fallback: count lit pixels.
    const lit = countLitPixels(result.pixels);
    const total: u32 = @as(u32, result.width) * @as(u32, result.height);
    const verdict: report_mod.Verdict = if (lit >= minimum_expected_lit_pixels) .pass else .fail;

    const details = try std.fmt.allocPrint(
        allocator,
        "observed_hash={s} ran={d} lit={d}/{d}  (heuristic — supply reference_hash for precise grading)",
        .{ hash_hex, result.cycles_run, lit, total },
    );
    allocator.free(hash_hex);

    const diagnostics = if (verdict == .fail) blk: {
        const snapshot = try test_suite.renderAsciiAlloc(allocator, result.pixels, result.width, result.height);
        defer allocator.free(snapshot);
        var diag = try allocator.alloc(report_mod.Diagnostic, 1);
        diag[0] = .{
            .kind = try allocator.dupe(u8, "blank_framebuffer"),
            .message = try std.fmt.allocPrint(allocator, "only {d} lit pixels; emulator likely crashed or hung. Snapshot:\n{s}", .{ lit, snapshot }),
        };
        break :blk diag;
    } else try allocator.alloc(report_mod.Diagnostic, 0);

    return .{
        .axis_name = try allocator.dupe(u8, "opcodes"),
        .rom_id = try allocator.dupe(u8, opts.rom_id),
        .verdict = verdict,
        .details = details,
        .diagnostics = diagnostics,
    };
}

// The corax+ screen draws 24 cells of text + a grid. A healthy run shows
// far more than 200 lit pixels; a crashed run usually shows <50 (logo
// fragment at best). 200 is a conservative floor.
const minimum_expected_lit_pixels: u32 = 200;

fn countLitPixels(pixels: []const u8) u32 {
    var count: u32 = 0;
    for (pixels) |p| if (p != 0) {
        count += 1;
    };
    return count;
}

fn hexEncode(allocator: std.mem.Allocator, bytes: [32]u8) ![]u8 {
    const buf = try allocator.alloc(u8, bytes.len * 2);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0x0F];
    }
    return buf;
}

fn buildMismatchDiagnostics(
    allocator: std.mem.Allocator,
    expected: []const u8,
    observed: []const u8,
    result: test_suite.RunResult,
) ![]report_mod.Diagnostic {
    const snapshot = try test_suite.renderAsciiAlloc(allocator, result.pixels, result.width, result.height);
    defer allocator.free(snapshot);

    var diag = try allocator.alloc(report_mod.Diagnostic, 1);
    diag[0] = .{
        .kind = try allocator.dupe(u8, "framebuffer_mismatch"),
        .message = try std.fmt.allocPrint(allocator, "expected={s} observed={s} snapshot:\n{s}", .{ expected, observed, snapshot }),
    };
    return diag;
}

test "runCoraxPlus reports harness_error for empty rom" {
    const allocator = std.testing.allocator;
    const rep = try runCoraxPlus(allocator, &.{}, .{});
    defer rep.deinit(allocator);
    // Empty ROM still runs (decodes zeros as 00E0 clear-screen, etc.) — the
    // heuristic will mark this FAIL (no lit pixels), not harness_error.
    try std.testing.expect(rep.verdict == .fail);
}
