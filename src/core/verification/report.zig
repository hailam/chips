const std = @import("std");

// Shared scaffolding for every axis + aggregate reports. Each axis module
// builds one AxisReport; the aggregate (corpus / `chip8 verify all`) builds
// a VerificationReport that folds them together.

pub const Verdict = enum {
    pass,
    fail,
    skip,
    harness_error,

    pub fn asString(self: Verdict) []const u8 {
        return switch (self) {
            .pass => "PASS",
            .fail => "FAIL",
            .skip => "SKIP",
            .harness_error => "ERROR",
        };
    }
};

// A single diagnostic a failing axis emits for a caller to act on. Cheap
// strings; callers own them via the report's arena.
pub const Diagnostic = struct {
    kind: []const u8, // e.g. "framebuffer_mismatch", "cycle_count"
    message: []const u8,
};

pub const AxisReport = struct {
    axis_name: []const u8,
    rom_id: []const u8,
    verdict: Verdict,
    details: []const u8 = "",
    diagnostics: []const Diagnostic = &.{},

    pub fn deinit(self: AxisReport, allocator: std.mem.Allocator) void {
        allocator.free(self.axis_name);
        allocator.free(self.rom_id);
        allocator.free(self.details);
        for (self.diagnostics) |d| {
            allocator.free(d.kind);
            allocator.free(d.message);
        }
        allocator.free(self.diagnostics);
    }

    pub fn simple(
        allocator: std.mem.Allocator,
        axis_name: []const u8,
        rom_id: []const u8,
        verdict: Verdict,
        details: []const u8,
    ) !AxisReport {
        return .{
            .axis_name = try allocator.dupe(u8, axis_name),
            .rom_id = try allocator.dupe(u8, rom_id),
            .verdict = verdict,
            .details = try allocator.dupe(u8, details),
            .diagnostics = &.{},
        };
    }
};

// Aggregate across many AxisReports (different axes on different ROMs).
pub const VerificationReport = struct {
    axes: []const AxisReport,

    pub fn deinit(self: VerificationReport, allocator: std.mem.Allocator) void {
        for (self.axes) |a| a.deinit(allocator);
        allocator.free(self.axes);
    }

    pub const Summary = struct { pass: u32 = 0, fail: u32 = 0, skip: u32 = 0, err: u32 = 0 };

    pub fn summary(self: VerificationReport) Summary {
        var s: Summary = .{};
        for (self.axes) |a| switch (a.verdict) {
            .pass => s.pass += 1,
            .fail => s.fail += 1,
            .skip => s.skip += 1,
            .harness_error => s.err += 1,
        };
        return s;
    }
};

// Plain-text formatter for humans. CLI prints this.
pub fn formatHuman(report: VerificationReport, writer: anytype) !void {
    const s = report.summary();
    try writer.print("Verification summary: {d} pass, {d} fail, {d} skip, {d} error\n", .{ s.pass, s.fail, s.skip, s.err });
    for (report.axes) |a| {
        try writer.print("  [{s}] {s} :: {s}  {s}\n", .{ a.verdict.asString(), a.axis_name, a.rom_id, a.details });
        for (a.diagnostics) |d| try writer.print("      - {s}: {s}\n", .{ d.kind, d.message });
    }
}

// Machine-readable formatter for CI pipelines. Stable schema: axis reports
// are emitted even when diagnostics are empty, so downstream filters don't
// need to special-case shape differences.
pub fn formatJson(allocator: std.mem.Allocator, report: VerificationReport, writer: anytype) !void {
    const AxisJsonView = struct {
        verdict: []const u8,
        axis: []const u8,
        rom_id: []const u8,
        details: []const u8,
        diagnostics: []const Diagnostic,
    };
    const View = struct {
        summary: VerificationReport.Summary,
        axes: []const AxisJsonView,
    };

    var axes_view = try allocator.alloc(AxisJsonView, report.axes.len);
    defer allocator.free(axes_view);
    for (report.axes, 0..) |a, i| {
        axes_view[i] = .{
            .verdict = a.verdict.asString(),
            .axis = a.axis_name,
            .rom_id = a.rom_id,
            .details = a.details,
            .diagnostics = a.diagnostics,
        };
    }
    const view = View{ .summary = report.summary(), .axes = axes_view };
    try std.json.Stringify.value(view, .{ .whitespace = .indent_2 }, writer);
    try writer.print("\n", .{});
}

// Convenience for single-axis commands (`verify tests`, `verify axis`).
pub fn formatAxisJson(allocator: std.mem.Allocator, rep: AxisReport, writer: anytype) !void {
    var axes: [1]AxisReport = .{rep};
    const fake = VerificationReport{ .axes = axes[0..] };
    try formatJson(allocator, fake, writer);
}

// --- persistence / diff --------------------------------------------------
//
// `verify all` snapshots are persisted in a compact form so CI can use
// `--diff` to show only what changed since the last baseline. We keep the
// minimum needed for a verdict-level comparison (axis + rom_id + verdict);
// we don't persist `details` because they contain run-specific noise like
// cycle counts that would create spurious diffs.

const Allocator = std.mem.Allocator;

pub const HistoryEntry = struct {
    axis: []const u8,
    rom_id: []const u8,
    verdict: []const u8,
};

pub const HistorySnapshot = struct {
    timestamp_ms: i64 = 0,
    entries: []HistoryEntry = &.{},
};

// Rolling window of recent `verify all` runs. New runs are appended and
// the list truncated to `HISTORY_MAX_RUNS` so the file size stays bounded.
// Kept backward-compatible: `loadHistoryFile` accepts both the current
// multi-run shape and the older single-snapshot shape by probing for the
// `runs` key.
pub const HISTORY_MAX_RUNS: usize = 20;

pub const MultiHistory = struct {
    runs: []HistorySnapshot = &.{},

    // Most recent snapshot, or null when no runs recorded.
    pub fn last(self: MultiHistory) ?HistorySnapshot {
        if (self.runs.len == 0) return null;
        return self.runs[self.runs.len - 1];
    }

    // Snapshot `age` runs before the most recent. age=0 means last().
    // Returns null if age is out of bounds.
    pub fn nthFromEnd(self: MultiHistory, age: usize) ?HistorySnapshot {
        if (age >= self.runs.len) return null;
        return self.runs[self.runs.len - 1 - age];
    }
};

pub fn entriesForHistory(allocator: Allocator, report: VerificationReport) ![]HistoryEntry {
    var out = try allocator.alloc(HistoryEntry, report.axes.len);
    var populated: usize = 0;
    errdefer {
        for (out[0..populated]) |e| {
            allocator.free(e.axis);
            allocator.free(e.rom_id);
            allocator.free(e.verdict);
        }
        allocator.free(out);
    }
    for (report.axes, 0..) |a, i| {
        out[i] = .{
            .axis = try allocator.dupe(u8, a.axis_name),
            .rom_id = try allocator.dupe(u8, a.rom_id),
            .verdict = try allocator.dupe(u8, a.verdict.asString()),
        };
        populated = i + 1;
    }
    return out;
}

pub fn freeHistoryEntries(allocator: Allocator, entries: []HistoryEntry) void {
    for (entries) |e| {
        allocator.free(e.axis);
        allocator.free(e.rom_id);
        allocator.free(e.verdict);
    }
    allocator.free(entries);
}

pub const DiffRow = struct {
    axis: []const u8,
    rom_id: []const u8,
    before: []const u8, // "absent" if new
    after: []const u8, // "absent" if removed
};

pub const Diff = struct {
    changed: []DiffRow, // verdict changed or newly appeared/disappeared
    unchanged_count: u32,

    pub fn deinit(self: Diff, allocator: Allocator) void {
        for (self.changed) |r| {
            allocator.free(r.axis);
            allocator.free(r.rom_id);
            allocator.free(r.before);
            allocator.free(r.after);
        }
        allocator.free(self.changed);
    }

    // Anything that went PASS→FAIL or is a new FAIL counts as a
    // regression. Exit-code gating keys off this.
    pub fn hasRegressions(self: Diff) bool {
        for (self.changed) |r| {
            if (std.mem.eql(u8, r.after, "FAIL") or std.mem.eql(u8, r.after, "ERROR")) return true;
        }
        return false;
    }
};

pub fn diffReports(
    allocator: Allocator,
    baseline: []const HistoryEntry,
    current: []const HistoryEntry,
) !Diff {
    var rows: std.ArrayList(DiffRow) = .empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.axis);
            allocator.free(r.rom_id);
            allocator.free(r.before);
            allocator.free(r.after);
        }
        rows.deinit(allocator);
    }

    var unchanged: u32 = 0;

    // Transitions + new rows.
    for (current) |cur| {
        if (findMatching(baseline, cur.axis, cur.rom_id)) |prev| {
            if (!std.mem.eql(u8, prev.verdict, cur.verdict)) {
                try rows.append(allocator, .{
                    .axis = try allocator.dupe(u8, cur.axis),
                    .rom_id = try allocator.dupe(u8, cur.rom_id),
                    .before = try allocator.dupe(u8, prev.verdict),
                    .after = try allocator.dupe(u8, cur.verdict),
                });
            } else {
                unchanged += 1;
            }
        } else {
            try rows.append(allocator, .{
                .axis = try allocator.dupe(u8, cur.axis),
                .rom_id = try allocator.dupe(u8, cur.rom_id),
                .before = try allocator.dupe(u8, "absent"),
                .after = try allocator.dupe(u8, cur.verdict),
            });
        }
    }

    // Rows that existed in baseline but are gone now (ROM uninstalled, etc.).
    for (baseline) |prev| {
        if (findMatching(current, prev.axis, prev.rom_id) == null) {
            try rows.append(allocator, .{
                .axis = try allocator.dupe(u8, prev.axis),
                .rom_id = try allocator.dupe(u8, prev.rom_id),
                .before = try allocator.dupe(u8, prev.verdict),
                .after = try allocator.dupe(u8, "absent"),
            });
        }
    }

    return .{ .changed = try rows.toOwnedSlice(allocator), .unchanged_count = unchanged };
}

fn findMatching(list: []const HistoryEntry, axis: []const u8, rom_id: []const u8) ?HistoryEntry {
    for (list) |e| {
        if (std.mem.eql(u8, e.axis, axis) and std.mem.eql(u8, e.rom_id, rom_id)) return e;
    }
    return null;
}

test "diffReports flags changed verdicts and new/missing rows" {
    const allocator = std.testing.allocator;
    const baseline = [_]HistoryEntry{
        .{ .axis = "memory", .rom_id = "a", .verdict = "PASS" },
        .{ .axis = "memory", .rom_id = "b", .verdict = "FAIL" },
        .{ .axis = "opcodes", .rom_id = "c", .verdict = "PASS" },
    };
    const current = [_]HistoryEntry{
        .{ .axis = "memory", .rom_id = "a", .verdict = "FAIL" }, // regressed
        .{ .axis = "memory", .rom_id = "b", .verdict = "PASS" }, // fixed
        .{ .axis = "sound", .rom_id = "d", .verdict = "PASS" }, // new
        // opcodes/c absent
    };
    const diff = try diffReports(allocator, &baseline, &current);
    defer diff.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), diff.unchanged_count);
    try std.testing.expectEqual(@as(usize, 4), diff.changed.len);
    try std.testing.expect(diff.hasRegressions());
}
