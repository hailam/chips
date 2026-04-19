const std = @import("std");
const chip8_mod = @import("../chip8.zig");
const cpu_mod = @import("../cpu.zig");
const emulation = @import("../emulation_config.zig");

// Runs Timendus's chip8-test-suite ROMs headlessly. Exposes a single
// `runHeadless` that spins the emulator for a configured number of CPU
// cycles and returns a framebuffer hash + the raw pixel buffer, which the
// axis modules use to derive pass/fail verdicts.
//
// Per-test framebuffer *parsing* (e.g. the 3-corax+ 4x6 grid of checks)
// belongs here too — but pixel-exact grid coordinates aren't documented
// upstream in a machine-readable form, so v1 relies on whole-framebuffer
// hash matches against captured-once reference hashes. Grid-level
// per-opcode parsers are a follow-up.

pub const TestId = enum {
    chip8_logo, // 1-chip8-logo
    ibm_logo, // 2-ibm-logo
    corax_plus, // 3-corax+
    flags, // 4-flags
    quirks, // 5-quirks
    beep, // 7-beep
    scrolling, // 8-scrolling (the file is named scrolling.ch8 upstream)

    pub fn fromString(s: []const u8) ?TestId {
        if (std.mem.eql(u8, s, "1-chip8-logo")) return .chip8_logo;
        if (std.mem.eql(u8, s, "2-ibm-logo")) return .ibm_logo;
        if (std.mem.eql(u8, s, "3-corax+") or std.mem.eql(u8, s, "3-corax")) return .corax_plus;
        if (std.mem.eql(u8, s, "4-flags")) return .flags;
        if (std.mem.eql(u8, s, "5-quirks")) return .quirks;
        if (std.mem.eql(u8, s, "7-beep")) return .beep;
        if (std.mem.eql(u8, s, "8-scrolling") or std.mem.eql(u8, s, "8-scrolltest")) return .scrolling;
        return null;
    }

    pub fn displayName(self: TestId) []const u8 {
        return switch (self) {
            .chip8_logo => "1-chip8-logo",
            .ibm_logo => "2-ibm-logo",
            .corax_plus => "3-corax+",
            .flags => "4-flags",
            .quirks => "5-quirks",
            .beep => "7-beep",
            .scrolling => "8-scrolling",
        };
    }

    // Cycles we spin the emulator before snapshotting the framebuffer.
    // Empirically chosen: each test's output stabilizes well before this.
    pub fn defaultCycles(self: TestId) u32 {
        return switch (self) {
            .chip8_logo, .ibm_logo => 500,
            .corax_plus, .flags => 100_000,
            .quirks => 200_000,
            .beep, .scrolling => 100_000,
        };
    }
};

pub const RunResult = struct {
    test_id: TestId,
    cycles_run: u32,
    // SHA-256 of the raw packed framebuffer (rows x cols of u1 collapsed to u8).
    // Stable across runs; used for reference-framebuffer comparison.
    framebuffer_hash: [32]u8,
    // Packed 64*32 bytes for lores runs; 128*64 for hires. Caller owns.
    pixels: []u8,
    width: u16,
    height: u16,
};

pub fn freeRunResult(allocator: std.mem.Allocator, result: RunResult) void {
    allocator.free(result.pixels);
}

pub fn runHeadless(
    allocator: std.mem.Allocator,
    test_id: TestId,
    rom_bytes: []const u8,
    cycles: ?u32,
    profile: emulation.QuirkProfile,
) !RunResult {
    var chip8 = chip8_mod.Chip8.initWithConfig(emulation.EmulationConfig.init(profile));
    try chip8.loadRom(rom_bytes);

    const total = cycles orelse test_id.defaultCycles();
    var ran: u32 = 0;
    while (ran < total) : (ran += 1) {
        chip8.update() catch |err| switch (err) {
            // Traps (bad opcode, stack overflow, etc.) stop execution but
            // the framebuffer up to that point is still a valid snapshot.
            else => break,
        };
        // Tick timers once per simulated frame (every ~17 CPU cycles at 60Hz /
        // 1000Hz ratio — close enough for tests that don't care about exact
        // timing).
        if (ran % 17 == 0) chip8.tickTimers();
    }

    return buildSnapshot(allocator, test_id, &chip8, ran);
}

fn buildSnapshot(
    allocator: std.mem.Allocator,
    test_id: TestId,
    chip8: *const chip8_mod.Chip8,
    cycles_run: u32,
) !RunResult {
    const w = chip8.cpu.displayWidth();
    const h = chip8.cpu.displayHeight();
    const pixels = try allocator.alloc(u8, w * h);
    errdefer allocator.free(pixels);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            pixels[y * w + x] = @as(u8, chip8.cpu.compositePixel(x, y));
        }
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(pixels);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    return .{
        .test_id = test_id,
        .cycles_run = cycles_run,
        .framebuffer_hash = hash,
        .pixels = pixels,
        .width = @intCast(w),
        .height = @intCast(h),
    };
}

// Render the framebuffer as ASCII for diagnostic dumps. Caller-owned.
pub fn renderAsciiAlloc(allocator: std.mem.Allocator, pixels: []const u8, width: u16, height: u16) ![]u8 {
    const stride = @as(usize, width) + 1; // +1 for the '\n'
    const buf = try allocator.alloc(u8, stride * height);
    var i: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            buf[i] = if (pixels[y * width + x] != 0) '#' else '.';
            i += 1;
        }
        buf[i] = '\n';
        i += 1;
    }
    return buf;
}

test "TestId.fromString roundtrips" {
    try std.testing.expectEqual(TestId.corax_plus, TestId.fromString("3-corax+").?);
    try std.testing.expectEqual(TestId.corax_plus, TestId.fromString("3-corax").?);
    try std.testing.expect(TestId.fromString("garbage") == null);
}
