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
