const std = @import("std");
const models = @import("../registry_models.zig");
const emulation = @import("../emulation_config.zig");
const chip8_db_cache = @import("../chip8_db_cache.zig");
const ground_truth = @import("oracle/ground_truth.zig");
const report_mod = @import("report.zig");
const axis_memory = @import("axis/memory.zig");
const axis_sound = @import("axis/sound.zig");
const axis_opcodes = @import("axis/opcodes.zig");
const axis_quirks = @import("axis/quirks.zig");
const axis_timing = @import("axis/timing.zig");
const test_suite = @import("test_suite.zig");
const ref_fb = @import("oracle/reference_framebuffers.zig");

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
    // Optional — when a reference-framebuffer store is provided, fixture
    // axes (opcodes, quirks) use it for precise grading instead of the
    // lit-pixel heuristic.
    ref_store: ?*const ref_fb.Store = null,
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
    try axes.append(run.allocator, try axis_timing.runSyntheticInvariants(run.allocator));

    // Per-ROM memory axis runs for every installed ROM with bytes we can
    // read. Honors the database's start_address when present. When the
    // ROM is one of Timendus's test fixtures (installed via
    // `chip8 get timendus:<id>`), also dispatch the fixture-aware axis.
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

        try runFixtureAxesForRom(run, rom, rom_bytes, &axes);
    }

    return .{ .axes = try axes.toOwnedSlice(run.allocator) };
}

// Dispatch to the per-test-ROM axes when the installed ROM matches one of
// Timendus's fixtures. Keeps `verify all` opportunistic: if the ROM isn't
// installed, nothing extra runs; if it is, we exercise the matching axis
// automatically.
fn runFixtureAxesForRom(
    run: CorpusRun,
    rom: models.InstalledRom,
    rom_bytes: []const u8,
    axes: *std.ArrayList(report_mod.AxisReport),
) !void {
    const test_id = test_suite.TestId.fromString(rom.metadata.id) orelse return;

    switch (test_id) {
        .corax_plus, .flags => {
            // Both ROMs draw a pass/fail grid; the "opcodes" axis checks
            // that the grid rendered + matches any captured reference.
            const rep = try axis_opcodes.runFramebufferAxis(run.allocator, rom_bytes, .{
                .test_id = test_id,
                .rom_id = rom.metadata.id,
                .axis_name = "opcodes",
                .store = run.ref_store,
                .rom_sha1 = rom.metadata.sha1,
            });
            try axes.append(run.allocator, rep);
        },
        .chip8_logo, .ibm_logo => {
            // Static-image tests. Route through the "display" axis name so
            // downstream consumers can slice by axis.
            const rep = try axis_opcodes.runFramebufferAxis(run.allocator, rom_bytes, .{
                .test_id = test_id,
                .rom_id = rom.metadata.id,
                .axis_name = "display",
                .store = run.ref_store,
                .rom_sha1 = rom.metadata.sha1,
                // Logo tests have smaller lit footprint than corax+; lower
                // the floor so a correct render still clears it without
                // also accepting a crash.
                .min_lit_pixels = 60,
            });
            try axes.append(run.allocator, rep);
        },
        .quirks => {
            const quirk_reports = try axis_quirks.runForRom(run.allocator, rom_bytes, .{
                .rom_id = rom.metadata.id,
                .store = run.ref_store,
                .rom_sha1 = rom.metadata.sha1,
            });
            defer run.allocator.free(quirk_reports);
            for (quirk_reports) |r| try axes.append(run.allocator, r);
        },
        .beep => {
            // 7-beep's contract is that FX18 sets the sound timer. Its
            // UI path blocks on FX0A (key press) which never fires in our
            // headless run, so we deliberately skip the framebuffer check
            // and grade only on sound-timer activity.
            const sound_rep = try axis_sound.runForRom(run.allocator, rom_bytes, .{
                .rom_id = rom.metadata.id,
            });
            try axes.append(run.allocator, sound_rep);
        },
        .scrolling => {
            // Exercises the SCHIP scroll opcodes; the surface we can grade
            // headlessly is the rendered framebuffer.
            const rep = try axis_opcodes.runFramebufferAxis(run.allocator, rom_bytes, .{
                .test_id = .scrolling,
                .rom_id = rom.metadata.id,
                .axis_name = "display",
                .profile = .schip_modern,
                .store = run.ref_store,
                .rom_sha1 = rom.metadata.sha1,
                .min_lit_pixels = 100,
            });
            try axes.append(run.allocator, rep);
        },
    }
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

    // memory + sound + timing synthetic invariants always run.
    try std.testing.expectEqual(@as(usize, 3), report.axes.len);
    const s = report.summary();
    try std.testing.expect(s.pass == 3);
}
