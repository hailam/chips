const std = @import("std");
const models = @import("../registry_models.zig");
const assembly = @import("../assembly.zig");
const emulation = @import("../emulation_config.zig");
const chip8_db_cache = @import("../chip8_db_cache.zig");
const cache = @import("../cache.zig");
const ground_truth = @import("oracle/ground_truth.zig");
const spec = @import("oracle/spec.zig");

// Grades the existing inference engine against chip-8-database ground truth.
//
// Per the spec, the ideal audit runs inference on every ROM in the database
// — but we only have *bytes* for ROMs the user has installed. This module
// therefore takes the set of installed ROMs whose SHA-1 hits the db cache,
// runs inference on each, and reports how well the inferred platform and
// quirks match the database's stated preferences.
//
// Three-tier platform verdict (respects the preference order):
//   exact    — inference's top guess matches the entry's FIRST preferred platform
//   acceptable — matches a later entry in the preferred list
//   wrong    — not in the list at all
//
// Quirk accuracy: for the subset of quirks our QuirkFlags models (5 of 7
// database quirks map cleanly), we compute per-quirk agreement across the
// audit set. Unmappable quirks are skipped rather than quietly wrong.

pub const PlatformVerdict = enum { exact, acceptable, wrong };

pub const ConfusionMatrix = struct {
    true_positive: u32 = 0,
    true_negative: u32 = 0,
    false_positive: u32 = 0,
    false_negative: u32 = 0,

    pub fn accuracy(self: ConfusionMatrix) f32 {
        const n = self.total();
        if (n == 0) return 0;
        const agree = @as(f32, @floatFromInt(self.true_positive + self.true_negative));
        return agree / @as(f32, @floatFromInt(n));
    }

    pub fn total(self: ConfusionMatrix) u32 {
        return self.true_positive + self.true_negative + self.false_positive + self.false_negative;
    }
};

pub const QuirkStats = struct {
    quirk: []const u8,
    matrix: ConfusionMatrix = .{},
};

pub const Disagreement = struct {
    sha1: []const u8,
    expected_platform: []const u8,
    inferred_platform: []const u8,
    reasoning: []const u8,

    pub fn deinit(self: Disagreement, allocator: std.mem.Allocator) void {
        allocator.free(self.sha1);
        allocator.free(self.expected_platform);
        allocator.free(self.inferred_platform);
        allocator.free(self.reasoning);
    }
};

pub const Report = struct {
    total_roms_graded: u32,
    exact_match: u32,
    acceptable: u32,
    wrong: u32,
    per_quirk: []QuirkStats,
    platform_disagreements: []Disagreement,

    pub fn platformAccuracy(self: Report) f32 {
        if (self.total_roms_graded == 0) return 0;
        const agree = @as(f32, @floatFromInt(self.exact_match + self.acceptable));
        return agree / @as(f32, @floatFromInt(self.total_roms_graded));
    }

    pub fn overallQuirkAccuracy(self: Report) f32 {
        var total: u32 = 0;
        var agree: u32 = 0;
        for (self.per_quirk) |q| {
            total += q.matrix.total();
            agree += q.matrix.true_positive + q.matrix.true_negative;
        }
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(agree)) / @as(f32, @floatFromInt(total));
    }

    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        for (self.per_quirk) |q| allocator.free(q.quirk);
        allocator.free(self.per_quirk);
        for (self.platform_disagreements) |d| d.deinit(allocator);
        allocator.free(self.platform_disagreements);
    }
};

const TrackedQuirk = struct {
    name: []const u8,
    extract_db: *const fn (q: spec.Quirks) bool,
    extract_ours: *const fn (q: emulation.QuirkFlags) bool,
};

// Quirks our QuirkFlags model cleanly enough to grade. Non-mapped quirks
// (memoryLeaveIUnchanged, memoryIncrementByX, vblank) are intentionally
// omitted until the emulator grows matching flags.
const TRACKED_QUIRKS = [_]TrackedQuirk{
    .{
        .name = "shift",
        .extract_db = struct {
            fn f(q: spec.Quirks) bool {
                return q.shift;
            }
        }.f,
        // db `shift=true` means "uses vX" — ours is `shift_uses_vy`, which
        // should be *false* when the db flag is true.
        .extract_ours = struct {
            fn f(q: emulation.QuirkFlags) bool {
                return !q.shift_uses_vy;
            }
        }.f,
    },
    .{
        .name = "wrap",
        .extract_db = struct {
            fn f(q: spec.Quirks) bool {
                return q.wrap;
            }
        }.f,
        .extract_ours = struct {
            fn f(q: emulation.QuirkFlags) bool {
                return q.draw_wrap;
            }
        }.f,
    },
    .{
        .name = "jump",
        .extract_db = struct {
            fn f(q: spec.Quirks) bool {
                return q.jump;
            }
        }.f,
        .extract_ours = struct {
            fn f(q: emulation.QuirkFlags) bool {
                return q.jump_uses_vx;
            }
        }.f,
    },
    .{
        .name = "logic",
        .extract_db = struct {
            fn f(q: spec.Quirks) bool {
                return q.logic;
            }
        }.f,
        .extract_ours = struct {
            fn f(q: emulation.QuirkFlags) bool {
                return q.logic_ops_clear_vf;
            }
        }.f,
    },
};

pub fn gradeInstalled(
    allocator: std.mem.Allocator,
    installed: []const models.InstalledRom,
    db_cache: *const chip8_db_cache.State,
    rom_bytes_for: *const fn (ctx: *anyopaque, rom: models.InstalledRom) anyerror!?[]const u8,
    ctx: *anyopaque,
) !Report {
    var per_quirk: [TRACKED_QUIRKS.len]QuirkStats = undefined;
    for (TRACKED_QUIRKS, 0..) |tq, i| {
        per_quirk[i] = .{ .quirk = try allocator.dupe(u8, tq.name) };
    }

    var disagreements: std.ArrayList(Disagreement) = .empty;
    errdefer {
        for (disagreements.items) |d| d.deinit(allocator);
        disagreements.deinit(allocator);
    }

    var total: u32 = 0;
    var exact: u32 = 0;
    var acceptable: u32 = 0;
    var wrong: u32 = 0;

    for (installed) |rom| {
        // Only rate ROMs with a database match — everything else has no
        // ground truth to compare against.
        const sha1 = rom.metadata.sha1 orelse continue;
        const entry = db_cache.lookup(sha1) orelse continue;

        const bytes = (rom_bytes_for(ctx, rom) catch continue) orelse continue;

        const inference = assembly.inferProfileDetailed(bytes);
        const inferred_platform = inference.platform_id orelse emulation.profileToPlatformId(inference.profile);

        total += 1;
        const verdict = classifyPlatform(entry, inferred_platform);
        switch (verdict) {
            .exact => exact += 1,
            .acceptable => acceptable += 1,
            .wrong => {
                wrong += 1;
                const expected = if (entry.platforms.len > 0) entry.platforms[0] else "unknown";
                try disagreements.append(allocator, .{
                    .sha1 = try allocator.dupe(u8, sha1),
                    .expected_platform = try allocator.dupe(u8, expected),
                    .inferred_platform = try allocator.dupe(u8, inferred_platform),
                    .reasoning = try allocator.dupe(u8, inference.reasoning),
                });
            },
        }

        // Quirk-level grading against the EXPECTED platform (whichever one
        // the db picks as preferred — we grade inference against the
        // authoritative answer, not against our chosen platform).
        const expected_platform = if (entry.platforms.len > 0) entry.platforms[0] else inferred_platform;
        const expected_quirks = ground_truth.expectedQuirksFor(entry, expected_platform) orelse continue;
        const inferred_quirks = emulation.profileQuirks(inference.profile);
        for (TRACKED_QUIRKS, 0..) |tq, i| {
            const expected_val = tq.extract_db(expected_quirks);
            const inferred_val = tq.extract_ours(inferred_quirks);
            tallyConfusion(&per_quirk[i].matrix, expected_val, inferred_val);
        }
    }

    const per_quirk_slice = try allocator.alloc(QuirkStats, per_quirk.len);
    @memcpy(per_quirk_slice, &per_quirk);

    return .{
        .total_roms_graded = total,
        .exact_match = exact,
        .acceptable = acceptable,
        .wrong = wrong,
        .per_quirk = per_quirk_slice,
        .platform_disagreements = try disagreements.toOwnedSlice(allocator),
    };
}

// Platform match considers both:
//   - String identity (strict spec rule).
//   - Profile equivalence — chip-8-database distinguishes `superchip`
//     (HP48 1.1) from `superchip1` (HP48 1.0), and `originalChip8` from
//     `hybridVIP`, but our emulator collapses each group to one internal
//     `QuirkProfile`. Inference can't tell those apart either, so holding
//     it to a strict string match grades us on a distinction we don't
//     model. Anything that would run the same way on our emulator counts
//     as hitting the same position in the preference list.
fn classifyPlatform(entry: models.Chip8DbEntry, inferred: []const u8) PlatformVerdict {
    const inferred_profile = emulation.platformIdToProfile(inferred);
    for (entry.platforms, 0..) |p, i| {
        if (std.mem.eql(u8, p, inferred)) {
            return if (i == 0) .exact else .acceptable;
        }
        if (inferred_profile != null and emulation.platformIdToProfile(p) == inferred_profile.?) {
            return if (i == 0) .exact else .acceptable;
        }
    }
    return .wrong;
}

// --- history / regression tracking ----------------------------------------

pub const HistoryEntry = struct {
    timestamp_ms: i64,
    total_roms_graded: u32,
    exact_match: u32,
    acceptable: u32,
    wrong: u32,
    platform_accuracy: f32,
    overall_quirk_accuracy: f32,
};

pub const History = struct {
    runs: []const HistoryEntry,

    pub fn lastRun(self: History) ?HistoryEntry {
        if (self.runs.len == 0) return null;
        return self.runs[self.runs.len - 1];
    }
};

const SerializedHistory = struct {
    runs: []HistoryEntry = &.{},
};

// Fixed-shape entries; no heap pointers live inside HistoryEntry so we
// don't need the full clone ritual.
pub fn loadHistory(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) !History {
    const path = try std.fmt.allocPrint(allocator, "{s}/verification/inference_history.json", .{app_data_root});
    defer allocator.free(path);

    const parsed_opt = cache.readJson(io, allocator, path, SerializedHistory) catch null;
    const parsed = parsed_opt orelse return .{ .runs = &.{} };
    defer parsed.deinit();

    const runs = try allocator.alloc(HistoryEntry, parsed.value.runs.len);
    @memcpy(runs, parsed.value.runs);
    return .{ .runs = runs };
}

pub fn freeHistory(allocator: std.mem.Allocator, history: History) void {
    allocator.free(history.runs);
}

// Appends the report as a new HistoryEntry. Keeps the most recent 100 runs
// to bound file growth. Caller supplies timestamp_ms (testable without
// std.Io.Clock wiring).
pub fn appendToHistory(
    io: std.Io,
    allocator: std.mem.Allocator,
    app_data_root: []const u8,
    report: Report,
    timestamp_ms: i64,
) !void {
    const MAX_RUNS: usize = 100;

    var existing = try loadHistory(io, allocator, app_data_root);
    defer freeHistory(allocator, existing);

    const new_entry = HistoryEntry{
        .timestamp_ms = timestamp_ms,
        .total_roms_graded = report.total_roms_graded,
        .exact_match = report.exact_match,
        .acceptable = report.acceptable,
        .wrong = report.wrong,
        .platform_accuracy = report.platformAccuracy(),
        .overall_quirk_accuracy = report.overallQuirkAccuracy(),
    };

    const start: usize = if (existing.runs.len >= MAX_RUNS) existing.runs.len - (MAX_RUNS - 1) else 0;
    const keep_count = existing.runs.len - start;
    const combined = try allocator.alloc(HistoryEntry, keep_count + 1);
    defer allocator.free(combined);
    @memcpy(combined[0..keep_count], existing.runs[start..]);
    combined[keep_count] = new_entry;

    const path = try std.fmt.allocPrint(allocator, "{s}/verification/inference_history.json", .{app_data_root});
    defer allocator.free(path);

    const view = SerializedHistory{ .runs = combined };
    try cache.writeJsonAtomic(io, allocator, path, view);
}

pub const RegressionVerdict = enum { ok, regressed, no_baseline };

pub const RegressionCheck = struct {
    verdict: RegressionVerdict,
    baseline_platform: f32 = 0,
    current_platform: f32 = 0,
    baseline_quirk: f32 = 0,
    current_quirk: f32 = 0,
    worst_drop_pct: f32 = 0,
};

// Compares `report` to the most-recent history entry and flags a regression
// when either the platform accuracy or the quirk accuracy dropped by more
// than `threshold_pct` percentage points. Returns verdict + deltas so the
// caller can format a useful message.
pub fn checkRegression(history: History, report: Report, threshold_pct: f32) RegressionCheck {
    const last = history.lastRun() orelse return .{ .verdict = .no_baseline };

    const cur_p = report.platformAccuracy();
    const cur_q = report.overallQuirkAccuracy();
    const plat_drop = (last.platform_accuracy - cur_p) * 100.0;
    const quirk_drop = (last.overall_quirk_accuracy - cur_q) * 100.0;
    const worst = @max(plat_drop, quirk_drop);

    return .{
        .verdict = if (worst > threshold_pct) .regressed else .ok,
        .baseline_platform = last.platform_accuracy,
        .current_platform = cur_p,
        .baseline_quirk = last.overall_quirk_accuracy,
        .current_quirk = cur_q,
        .worst_drop_pct = worst,
    };
}

fn tallyConfusion(m: *ConfusionMatrix, expected: bool, inferred: bool) void {
    if (expected and inferred) m.true_positive += 1;
    if (!expected and !inferred) m.true_negative += 1;
    if (!expected and inferred) m.false_positive += 1;
    if (expected and !inferred) m.false_negative += 1;
}

// --- tests ---

test "classifyPlatform respects preference order" {
    const entry = models.Chip8DbEntry{
        .title = "",
        .description = "",
        .release = "",
        .authors = &.{},
        .platforms = &[_][]const u8{ "xochip", "superchip1", "modernChip8" },
    };
    try std.testing.expectEqual(PlatformVerdict.exact, classifyPlatform(entry, "xochip"));
    try std.testing.expectEqual(PlatformVerdict.acceptable, classifyPlatform(entry, "superchip1"));
    try std.testing.expectEqual(PlatformVerdict.wrong, classifyPlatform(entry, "chip8x"));
}

test "classifyPlatform treats profile-equivalent platforms as matching" {
    // `superchip` (HP48 1.1) and `superchip1` (HP48 1.0) both run on our
    // .schip_11 profile; inference picking either one when the ROM prefers
    // the other should count as exact, not wrong.
    const entry = models.Chip8DbEntry{
        .title = "",
        .description = "",
        .release = "",
        .authors = &.{},
        .platforms = &[_][]const u8{ "superchip", "xochip" },
    };
    try std.testing.expectEqual(PlatformVerdict.exact, classifyPlatform(entry, "superchip1"));
    try std.testing.expectEqual(PlatformVerdict.acceptable, classifyPlatform(entry, "xochip"));

    // originalChip8 / hybridVIP also map to the same profile.
    const vip_entry = models.Chip8DbEntry{
        .title = "",
        .description = "",
        .release = "",
        .authors = &.{},
        .platforms = &[_][]const u8{"hybridVIP"},
    };
    try std.testing.expectEqual(PlatformVerdict.exact, classifyPlatform(vip_entry, "originalChip8"));
}

test "checkRegression with no baseline returns no_baseline" {
    const empty = History{ .runs = &.{} };
    const report = Report{
        .total_roms_graded = 5,
        .exact_match = 5,
        .acceptable = 0,
        .wrong = 0,
        .per_quirk = &.{},
        .platform_disagreements = &.{},
    };
    const check = checkRegression(empty, report, 1.0);
    try std.testing.expectEqual(RegressionVerdict.no_baseline, check.verdict);
}

test "checkRegression detects platform-accuracy drop past threshold" {
    const runs = [_]HistoryEntry{.{
        .timestamp_ms = 0,
        .total_roms_graded = 5,
        .exact_match = 5,
        .acceptable = 0,
        .wrong = 0,
        .platform_accuracy = 1.0,
        .overall_quirk_accuracy = 1.0,
    }};
    const history = History{ .runs = &runs };
    const report = Report{
        .total_roms_graded = 5,
        .exact_match = 3, // dropped from 5
        .acceptable = 0,
        .wrong = 2,
        .per_quirk = &.{},
        .platform_disagreements = &.{},
    };
    const check = checkRegression(history, report, 1.0);
    try std.testing.expectEqual(RegressionVerdict.regressed, check.verdict);
    try std.testing.expect(check.worst_drop_pct > 1.0);
}

test "checkRegression passes when accuracy held steady" {
    // Report with an empty per_quirk returns overallQuirkAccuracy() == 0, so
    // the baseline must also be 0 for this to represent "no change".
    const runs = [_]HistoryEntry{.{
        .timestamp_ms = 0,
        .total_roms_graded = 5,
        .exact_match = 5,
        .acceptable = 0,
        .wrong = 0,
        .platform_accuracy = 1.0,
        .overall_quirk_accuracy = 0.0,
    }};
    const history = History{ .runs = &runs };
    const report = Report{
        .total_roms_graded = 5,
        .exact_match = 5,
        .acceptable = 0,
        .wrong = 0,
        .per_quirk = &.{},
        .platform_disagreements = &.{},
    };
    const check = checkRegression(history, report, 1.0);
    try std.testing.expectEqual(RegressionVerdict.ok, check.verdict);
}

test "tallyConfusion increments the right cell" {
    var m = ConfusionMatrix{};
    tallyConfusion(&m, true, true);
    tallyConfusion(&m, false, false);
    tallyConfusion(&m, true, false);
    tallyConfusion(&m, false, true);
    try std.testing.expectEqual(@as(u32, 1), m.true_positive);
    try std.testing.expectEqual(@as(u32, 1), m.true_negative);
    try std.testing.expectEqual(@as(u32, 1), m.false_negative);
    try std.testing.expectEqual(@as(u32, 1), m.false_positive);
    try std.testing.expectEqual(@as(f32, 0.5), m.accuracy());
}
