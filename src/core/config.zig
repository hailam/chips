const std = @import("std");
const models = @import("registry_models.zig");
const cache = @import("cache.zig");

pub const Config = struct {
    known_registries: []models.KnownRegistry,
    github_token: ?[]const u8 = null,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        for (self.known_registries) |reg| reg.deinit(allocator);
        allocator.free(self.known_registries);
        if (self.github_token) |v| allocator.free(v);
    }
};

const DefaultRegistry = struct {
    name: []const u8,
    repo: []const u8,
    globs: []const []const u8,
};

pub const DEFAULT_REGISTRIES: []const DefaultRegistry = &.{
    .{
        .name = "kripod",
        .repo = "kripod/chip8-roms",
        .globs = &.{ "games/*.ch8", "demos/*.ch8", "programs/*.ch8" },
    },
    .{
        .name = "dmatlack",
        .repo = "dmatlack/chip8",
        .globs = &.{ "roms/games/*.ch8", "roms/demos/*.ch8" },
    },
    .{
        .name = "earnest",
        .repo = "JohnEarnest/chip8Archive",
        .globs = &.{"roms/*.ch8"},
    },
};

pub fn loadConfig(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) !Config {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{app_data_root});
    defer allocator.free(config_path);

    const ParsedShape = struct {
        known_registries: []models.KnownRegistry,
        github_token: ?[]const u8 = null,
    };

    // If the file is present but doesn't match the current schema
    // (e.g. carries fields from an earlier version), treat it as missing
    // and regenerate. User config is stateful but recoverable.
    const parsed_opt = cache.readJson(io, allocator, config_path, ParsedShape) catch null;
    if (parsed_opt) |parsed| {
        defer parsed.deinit();
        return try cloneConfig(allocator, parsed.value.known_registries, parsed.value.github_token);
    }

    const defaults = try buildDefaults(allocator);
    const cfg = Config{ .known_registries = defaults, .github_token = null };
    try saveConfig(io, allocator, app_data_root, cfg);
    return cfg;
}

pub fn saveConfig(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8, config: Config) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{app_data_root});
    defer allocator.free(config_path);
    try cache.writeJsonAtomic(io, allocator, config_path, config);
}

fn buildDefaults(allocator: std.mem.Allocator) ![]models.KnownRegistry {
    var registries = try allocator.alloc(models.KnownRegistry, DEFAULT_REGISTRIES.len);
    var populated: usize = 0;
    errdefer {
        for (registries[0..populated]) |r| r.deinit(allocator);
        allocator.free(registries);
    }
    for (DEFAULT_REGISTRIES, 0..) |reg, i| {
        var globs = try allocator.alloc([]const u8, reg.globs.len);
        var glob_pop: usize = 0;
        errdefer {
            for (globs[0..glob_pop]) |g| allocator.free(g);
            allocator.free(globs);
        }
        for (reg.globs, 0..) |glob, j| {
            globs[j] = try allocator.dupe(u8, glob);
            glob_pop = j + 1;
        }
        registries[i] = .{
            .name = try allocator.dupe(u8, reg.name),
            .repo = try allocator.dupe(u8, reg.repo),
            .globs = globs,
        };
        populated = i + 1;
    }
    return registries;
}

fn cloneConfig(allocator: std.mem.Allocator, src_regs: []models.KnownRegistry, src_token: ?[]const u8) !Config {
    var registries = try allocator.alloc(models.KnownRegistry, src_regs.len);
    var populated: usize = 0;
    errdefer {
        for (registries[0..populated]) |r| r.deinit(allocator);
        allocator.free(registries);
    }
    for (src_regs, 0..) |reg, i| {
        var globs = try allocator.alloc([]const u8, reg.globs.len);
        for (reg.globs, 0..) |glob, j| {
            globs[j] = try allocator.dupe(u8, glob);
        }
        registries[i] = .{
            .name = try allocator.dupe(u8, reg.name),
            .repo = try allocator.dupe(u8, reg.repo),
            .globs = globs,
        };
        populated = i + 1;
    }
    const token = if (src_token) |t| try allocator.dupe(u8, t) else null;
    return .{ .known_registries = registries, .github_token = token };
}
