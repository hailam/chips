const std = @import("std");
const models = @import("../registry_models.zig");
const emulation = @import("../emulation_config.zig");
const chip8_db_cache = @import("../chip8_db_cache.zig");
const ground_truth = @import("oracle/ground_truth.zig");
const report_mod = @import("report.zig");
const axis_memory = @import("axis/memory.zig");
const axis_sound = @import("axis/sound.zig");

// Batch runner. Composes every axis we currently support across a set of
// installed ROMs + the spec-invariant axes. Output is a single
// VerificationReport suitable for `chip8 verify all`.
//
// Per-ROM axis selection respects oracle hints:
//   - Memory axis honors `start_address` when the database entry specifies
//     one (ETI-660 case and similar).
//   - ROMs whose preferred platform isn't one we model get SKIP for the
//     axes that would require the platform's quirks (none today; placeholder
//     for the quirks axis when it lands).
//
// Axes that depend on per-ROM test fixtures (opcodes via 3-corax+, display
// via reference framebuffers) are *not* run here automatically — callers
// invoke `chip8 verify tests <id> <rom>` / `chip8 verify axis opcodes ...`
// with the specific fixture path. Corpus covers the fixture-free surface.

pub const CorpusRun = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    installed: []const models.InstalledRom,
    db_cache: *const chip8_db_cache.State,
};

pub fn runAll(run: CorpusRun) !report_mod.VerificationReport {
    var axes: std.ArrayList(report_mod.AxisReport) = .empty;
    errdefer {
        for (axes.items) |a| a.deinit(run.allocator);
        axes.deinit(run.allocator);
    }

    // Spec-invariant axes (fixture-free, always run).
    try axes.append(run.allocator, try axis_memory.runSyntheticInvariants(run.allocator));
    try axes.append(run.allocator, try axis_sound.runSyntheticInvariants(run.allocator));

    // Per-ROM memory axis runs for every installed ROM with bytes we can
    // read. Honors the database's start_address when present.
    for (run.installed) |rom| {
        const rom_bytes = std.Io.Dir.cwd().readFileAlloc(run.io, rom.local.path, run.allocator, .limited(64 * 1024)) catch |err| {
            try axes.append(run.allocator, try report_mod.AxisReport.simple(
                run.allocator,
                "memory",
                rom.metadata.id,
                .harness_error,
                @errorName(err),
            ));
            continue;
        };
        defer run.allocator.free(rom_bytes);

        const start_address = lookupStartAddress(run.db_cache, rom.metadata.sha1) orelse 0x200;
        const profile = pickProfile(run.db_cache, rom.metadata.sha1);

        const rep = try axis_memory.runForRom(run.allocator, rom_bytes, .{
            .rom_id = rom.metadata.id,
            .start_address = start_address,
            .profile = profile,
            .cycles = 50_000,
        });
        try axes.append(run.allocator, rep);
    }

    return .{ .axes = try axes.toOwnedSlice(run.allocator) };
}

fn lookupStartAddress(db: *const chip8_db_cache.State, sha1_opt: ?[]const u8) ?u16 {
    const sha1 = sha1_opt orelse return null;
    const entry = db.lookup(sha1) orelse return null;
    return entry.start_address;
}

fn pickProfile(db: *const chip8_db_cache.State, sha1_opt: ?[]const u8) emulation.QuirkProfile {
    const sha1 = sha1_opt orelse return .vip_legacy;
    const entry = db.lookup(sha1) orelse return .vip_legacy;
    if (entry.platforms.len == 0) return .vip_legacy;
    return emulation.platformIdToProfile(entry.platforms[0]) orelse .vip_legacy;
}

test "runAll over an empty installed list still runs synthetic axes" {
    const allocator = std.testing.allocator;
    var fake_cache = chip8_db_cache.State.init(allocator);
    defer fake_cache.deinit();

    const report = try runAll(.{
        .io = undefined, // unused when installed is empty
        .allocator = allocator,
        .installed = &.{},
        .db_cache = &fake_cache,
    });
    defer report.deinit(allocator);

    // memory + sound synthetic invariants always run.
    try std.testing.expectEqual(@as(usize, 2), report.axes.len);
    const s = report.summary();
    try std.testing.expect(s.pass == 2);
}
