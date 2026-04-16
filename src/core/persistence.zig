const builtin = @import("builtin");
const std = @import("std");
const chip8_mod = @import("chip8.zig");
const emulation = @import("emulation_config.zig");

pub const MAX_RECENT_ROMS: usize = 10;
const STATE_JSON_NAME = "state.json";
const SAVES_DIR_NAME = "saves";
const EXPORTS_DIR_NAME = "exports";
const SAVE_MAGIC = "CH8S";
const SAVE_VERSION: u32 = 2;

pub const DisplayPalette = enum {
    classic_green,
    amber,
    ice,
    gray,
};

pub const DisplayEffect = enum {
    none,
    scanlines,
};

pub const DisplaySettings = struct {
    palette: DisplayPalette = .classic_green,
    effect: DisplayEffect = .none,
    fullscreen: bool = false,
    volume: f32 = 1.0,
};

pub const RecentRom = struct {
    path: []u8,
    display_name: []u8,
    sha256_hex: []u8,
    last_opened_unix_ms: i64,

    fn clone(self: RecentRom, allocator: std.mem.Allocator) !RecentRom {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .display_name = try allocator.dupe(u8, self.display_name),
            .sha256_hex = try allocator.dupe(u8, self.sha256_hex),
            .last_opened_unix_ms = self.last_opened_unix_ms,
        };
    }

    fn deinit(self: *RecentRom, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.display_name);
        allocator.free(self.sha256_hex);
        self.* = undefined;
    }
};

pub const RomPreferences = struct {
    sha256_hex: []u8,
    last_path: []u8,
    quirk_profile: emulation.QuirkProfile,
    cpu_hz_target: i32,
    last_save_slot: u8,

    fn clone(self: RomPreferences, allocator: std.mem.Allocator) !RomPreferences {
        return .{
            .sha256_hex = try allocator.dupe(u8, self.sha256_hex),
            .last_path = try allocator.dupe(u8, self.last_path),
            .quirk_profile = self.quirk_profile,
            .cpu_hz_target = self.cpu_hz_target,
            .last_save_slot = self.last_save_slot,
        };
    }

    fn deinit(self: *RomPreferences, allocator: std.mem.Allocator) void {
        allocator.free(self.sha256_hex);
        allocator.free(self.last_path);
        self.* = undefined;
    }
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    recent_roms: std.ArrayList(RecentRom),
    rom_preferences: std.ArrayList(RomPreferences),
    global_settings: DisplaySettings,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .recent_roms = .empty,
            .rom_preferences = .empty,
            .global_settings = .{},
        };
    }

    pub fn deinit(self: *AppState) void {
        for (self.recent_roms.items) |*recent| recent.deinit(self.allocator);
        self.recent_roms.deinit(self.allocator);
        for (self.rom_preferences.items) |*pref| pref.deinit(self.allocator);
        self.rom_preferences.deinit(self.allocator);
    }

    pub fn findRomPreference(self: *const AppState, sha256_hex: []const u8) ?RomPreferences {
        for (self.rom_preferences.items) |pref| {
            if (std.mem.eql(u8, pref.sha256_hex, sha256_hex)) return pref;
        }
        return null;
    }

    pub fn upsertRecentRom(self: *AppState, path: []const u8, display_name: []const u8, sha256_hex: []const u8, opened_at_ms: i64) !void {
        var existing_index: ?usize = null;
        for (self.recent_roms.items, 0..) |recent, idx| {
            if (std.mem.eql(u8, recent.sha256_hex, sha256_hex) or std.mem.eql(u8, recent.path, path)) {
                existing_index = idx;
                break;
            }
        }

        const record = RecentRom{
            .path = try self.allocator.dupe(u8, path),
            .display_name = try self.allocator.dupe(u8, display_name),
            .sha256_hex = try self.allocator.dupe(u8, sha256_hex),
            .last_opened_unix_ms = opened_at_ms,
        };

        if (existing_index) |idx| {
            self.recent_roms.items[idx].deinit(self.allocator);
            _ = self.recent_roms.orderedRemove(idx);
        }

        try self.recent_roms.insert(self.allocator, 0, record);
        if (self.recent_roms.items.len > MAX_RECENT_ROMS) {
            var last = self.recent_roms.pop().?;
            last.deinit(self.allocator);
        }
    }

    pub fn upsertRomPreference(
        self: *AppState,
        sha256_hex: []const u8,
        last_path: []const u8,
        quirk_profile: emulation.QuirkProfile,
        cpu_hz_target: i32,
        last_save_slot: u8,
    ) !void {
        for (self.rom_preferences.items) |*pref| {
            if (std.mem.eql(u8, pref.sha256_hex, sha256_hex)) {
                self.allocator.free(pref.last_path);
                pref.last_path = try self.allocator.dupe(u8, last_path);
                pref.quirk_profile = quirk_profile;
                pref.cpu_hz_target = cpu_hz_target;
                pref.last_save_slot = last_save_slot;
                return;
            }
        }

        try self.rom_preferences.append(self.allocator, .{
            .sha256_hex = try self.allocator.dupe(u8, sha256_hex),
            .last_path = try self.allocator.dupe(u8, last_path),
            .quirk_profile = quirk_profile,
            .cpu_hz_target = cpu_hz_target,
            .last_save_slot = last_save_slot,
        });
    }
};

pub const SaveStateEnvelope = struct {
    rom_sha256: [32]u8,
    quirk_profile: emulation.QuirkProfile,
    chip8_state: chip8_mod.Chip8.SaveState,
    cpu_hz_target: i32,
    paused_state: bool,
};

pub fn computeRomSha256(rom_data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rom_data, &digest, .{});
    return digest;
}

pub fn sha256HexAlloc(allocator: std.mem.Allocator, hash: [32]u8) ![]u8 {
    const buf = std.fmt.bytesToHex(&hash, .lower);
    return allocator.dupe(u8, &buf);
}

pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn defaultAppDataRootAlloc(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    return switch (builtin.os.tag) {
        .macos => blk: {
            const home = try environ.getAlloc(allocator, "HOME");
            defer allocator.free(home);
            break :blk std.fmt.allocPrint(allocator, "{s}/Library/Application Support/chips", .{home});
        },
        .windows => blk: {
            const local_app_data = try environ.getAlloc(allocator, "LOCALAPPDATA");
            defer allocator.free(local_app_data);
            break :blk std.fmt.allocPrint(allocator, "{s}\\chips", .{local_app_data});
        },
        else => blk: {
            const xdg_state_home = environ.getAlloc(allocator, "XDG_STATE_HOME") catch null;
            if (xdg_state_home) |state_home| {
                defer allocator.free(state_home);
                break :blk std.fmt.allocPrint(allocator, "{s}/chips", .{state_home});
            }

            const home = try environ.getAlloc(allocator, "HOME");
            defer allocator.free(home);
            break :blk std.fmt.allocPrint(allocator, "{s}/.local/state/chips", .{home});
        },
    };
}

pub fn loadAppState(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8) !AppState {
    var app_state = AppState.init(allocator);
    errdefer app_state.deinit();

    const state_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, STATE_JSON_NAME });
    defer allocator.free(state_path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, state_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return app_state,
        else => return err,
    };
    defer allocator.free(contents);

    try deserializeAppState(allocator, contents, &app_state);
    return app_state;
}

pub fn saveAppState(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8, app_state: *const AppState) !void {
    try std.Io.Dir.cwd().createDirPath(io, root_path);
    const state_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, STATE_JSON_NAME });
    defer allocator.free(state_path);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try serializeAppState(app_state, &writer.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = state_path, .data = writer.written() });
}

pub fn saveStatePathAlloc(allocator: std.mem.Allocator, root_path: []const u8, sha256_hex: []const u8, slot: u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}/slot-{d:0>2}.bin", .{ root_path, SAVES_DIR_NAME, sha256_hex, slot });
}

pub fn sourceExportPathAlloc(allocator: std.mem.Allocator, root_path: []const u8, sha256_hex: []const u8, rom_basename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}.asm", .{ root_path, EXPORTS_DIR_NAME, sha256_hex, rom_basename });
}

pub fn saveEnvelopeToFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    sha256_hex: []const u8,
    slot: u8,
    envelope: *const SaveStateEnvelope,
) !void {
    const save_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ root_path, SAVES_DIR_NAME, sha256_hex });
    defer allocator.free(save_dir);
    try std.Io.Dir.cwd().createDirPath(io, save_dir);

    const save_path = try saveStatePathAlloc(allocator, root_path, sha256_hex, slot);
    defer allocator.free(save_path);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try serializeSaveStateEnvelope(envelope, &writer.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = save_path, .data = writer.written() });
}

pub fn loadEnvelopeFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    sha256_hex: []const u8,
    slot: u8,
) !SaveStateEnvelope {
    const save_path = try saveStatePathAlloc(allocator, root_path, sha256_hex, slot);
    defer allocator.free(save_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, save_path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bytes);
    return try deserializeSaveStateEnvelope(bytes);
}

pub fn serializeAppState(app_state: *const AppState, writer: *std.Io.Writer) !void {
    const view = struct {
        recent_roms: []const RecentRom,
        rom_preferences: []const RomPreferences,
        global_settings: DisplaySettings,
    }{
        .recent_roms = app_state.recent_roms.items,
        .rom_preferences = app_state.rom_preferences.items,
        .global_settings = app_state.global_settings,
    };
    try std.json.Stringify.value(view, .{ .whitespace = .indent_2 }, writer);
}

pub fn deserializeAppState(allocator: std.mem.Allocator, bytes: []const u8, app_state: *AppState) !void {
    const ParsedState = struct {
        recent_roms: []const RecentRom = &.{},
        rom_preferences: []const RomPreferences = &.{},
        global_settings: DisplaySettings = .{},
    };

    var parsed = try std.json.parseFromSlice(ParsedState, allocator, bytes, .{});
    defer parsed.deinit();

    app_state.global_settings = parsed.value.global_settings;
    for (parsed.value.recent_roms) |recent| {
        try app_state.recent_roms.append(allocator, try recent.clone(allocator));
    }
    for (parsed.value.rom_preferences) |pref| {
        try app_state.rom_preferences.append(allocator, try pref.clone(allocator));
    }
}

pub fn serializeSaveStateEnvelope(envelope: *const SaveStateEnvelope, writer: *std.Io.Writer) !void {
    try writer.writeAll(SAVE_MAGIC);
    try writer.writeInt(u32, SAVE_VERSION, .little);
    try writer.writeAll(&envelope.rom_sha256);
    try writer.writeByte(@intFromEnum(envelope.quirk_profile));
    try writer.writeInt(i32, envelope.cpu_hz_target, .little);
    try writer.writeByte(if (envelope.paused_state) 1 else 0);
    try chip8_mod.Chip8.writeSaveState(writer, &envelope.chip8_state);
}

pub fn deserializeSaveStateEnvelope(bytes: []const u8) !SaveStateEnvelope {
    var reader = std.Io.Reader.fixed(bytes);

    var magic: [4]u8 = undefined;
    try reader.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, SAVE_MAGIC)) return error.InvalidSaveStateMagic;

    const version = try reader.takeInt(u32, .little);
    if (version != SAVE_VERSION) return error.UnsupportedSaveStateVersion;

    var rom_sha256: [32]u8 = undefined;
    try reader.readSliceAll(&rom_sha256);
    const quirk_profile = emulation.profileFromByte(try reader.takeByte()) orelse return error.InvalidSaveStateProfile;
    const cpu_hz_target = try reader.takeInt(i32, .little);
    const paused_state = (try reader.takeByte()) != 0;
    const chip8_state = try chip8_mod.Chip8.readSaveState(&reader);

    return .{
        .rom_sha256 = rom_sha256,
        .quirk_profile = quirk_profile,
        .chip8_state = chip8_state,
        .cpu_hz_target = cpu_hz_target,
        .paused_state = paused_state,
    };
}
