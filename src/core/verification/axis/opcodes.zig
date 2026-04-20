const std = @import("std");
const report_mod = @import("../report.zig");
const test_suite = @import("../test_suite.zig");
const emulation = @import("../../emulation_config.zig");
const ref_fb = @import("../oracle/reference_framebuffers.zig");

// Framebuffer-output axis. Oracle: any Timendus test whose pass/fail is
// encoded in what it DRAWS on screen — 3-corax+ (opcode grid), 4-flags
// (arithmetic/flag grid), 1-chip8-logo + 2-ibm-logo (static images).
//
// Verdict policy:
//   1. If a reference framebuffer hash is supplied (directly or via the
//      reference-framebuffer store), compare → pass/fail.
//   2. Otherwise apply a coarse lit-pixel heuristic. Every supported test
//      draws a dense output; a crashed/hung emulator leaves the screen
//      nearly empty. Pass when lit ≥ `opts.min_lit_pixels`.
//
// `axis_name` on the returned report comes from `opts.axis_name`, so the
// same function powers both `opcodes` (corax+, flags) and `display`
// (ibm-logo, chip8-logo) surfaces without duplicating the plumbing.

pub const RunOptions = struct {
    test_id: test_suite.TestId = .corax_plus,
    // Optional reference framebuffer hash (SHA-256, lowercase hex).
    reference_hash: ?[]const u8 = null,
    // Optional reference-framebuffer store; looked up by (sha1, cycles_run).
    store: ?*const ref_fb.Store = null,
    rom_sha1: ?[]const u8 = null,
    cycles: ?u32 = null,
    profile: emulation.QuirkProfile = .vip_legacy,
    // Report fields.
    axis_name: []const u8 = "opcodes",
    rom_id: ?[]const u8 = null, // defaults to test_id.displayName()
    min_lit_pixels: u32 = 200,
};

// Generic entry. Previous callers that used `runCoraxPlus` should migrate
// here; the old name is kept as a thin shim for backward-compat.
pub fn runFramebufferAxis(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    opts: RunOptions,
) !report_mod.AxisReport {
    const rom_id = opts.rom_id orelse opts.test_id.displayName();

    const result = test_suite.runHeadless(allocator, opts.test_id, rom_bytes, opts.cycles, opts.profile) catch |err| {
        return try report_mod.AxisReport.simple(
            allocator,
            opts.axis_name,
            rom_id,
            .harness_error,
            @errorName(err),
        );
    };
    defer test_suite.freeRunResult(allocator, result);

    const hash_hex = try hexEncode(allocator, result.framebuffer_hash);
    errdefer allocator.free(hash_hex);

    // If no explicit reference was passed but we have a store and sha1,
    // try the store for a snapshot at this cycle count. Silently falls
    // through to heuristic if no match.
    const ref_from_store: ?[]const u8 = blk: {
        if (opts.reference_hash != null) break :blk null;
        const store = opts.store orelse break :blk null;
        const sha1 = opts.rom_sha1 orelse break :blk null;
        break :blk store.snapshotAt(sha1, result.cycles_run);
    };
    const effective_ref = opts.reference_hash orelse ref_from_store;

    // Hash-based verdict wins when a reference is supplied.
    if (effective_ref) |ref| {
        const verdict: report_mod.Verdict = if (std.ascii.eqlIgnoreCase(ref, hash_hex)) .pass else .fail;
        const details = try std.fmt.allocPrint(allocator, "observed_hash={s} ran={d}", .{ hash_hex, result.cycles_run });
        const diagnostics = if (verdict == .fail) try buildMismatchDiagnostics(allocator, ref, hash_hex, result) else try allocator.alloc(report_mod.Diagnostic, 0);
        allocator.free(hash_hex);
        return .{
            .axis_name = try allocator.dupe(u8, opts.axis_name),
            .rom_id = try allocator.dupe(u8, rom_id),
            .verdict = verdict,
            .details = details,
            .diagnostics = diagnostics,
        };
    }

    // Heuristic fallback: count lit pixels.
    const lit = countLitPixels(result.pixels);
    const total: u32 = @as(u32, result.width) * @as(u32, result.height);
    const verdict: report_mod.Verdict = if (lit >= opts.min_lit_pixels) .pass else .fail;

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
        .axis_name = try allocator.dupe(u8, opts.axis_name),
        .rom_id = try allocator.dupe(u8, rom_id),
        .verdict = verdict,
        .details = details,
        .diagnostics = diagnostics,
    };
}

// Legacy shim — old callsites that assumed corax+.
pub fn runCoraxPlus(
    allocator: std.mem.Allocator,
    rom_bytes: []const u8,
    opts: RunOptions,
) !report_mod.AxisReport {
    var fixed = opts;
    fixed.test_id = .corax_plus;
    if (fixed.rom_id == null) fixed.rom_id = "3-corax+";
    return runFramebufferAxis(allocator, rom_bytes, fixed);
}

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

test "runFramebufferAxis with explicit test_id uses the right defaults" {
    const allocator = std.testing.allocator;
    const rom = [_]u8{ 0x12, 0x00 }; // JP 0x200 — infinite loop, blank frame
    const rep = try runFramebufferAxis(allocator, &rom, .{
        .test_id = .ibm_logo,
        .axis_name = "display",
    });
    defer rep.deinit(allocator);
    try std.testing.expectEqualStrings("display", rep.axis_name);
    try std.testing.expectEqualStrings("2-ibm-logo", rep.rom_id);
}
