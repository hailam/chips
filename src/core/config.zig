const std = @import("std");
const models = @import("registry_models.zig");

pub const Config = struct {
    known_registries: []models.KnownRegistry,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        for (self.known_registries) |reg| reg.deinit(allocator);
        allocator.free(self.known_registries);
    }
};

const DEFAULT_REGISTRIES = [_]struct { name: []const u8, repo: ?[]const u8, local_path: ?[]const u8, globs: []const []const u8 }{
    .{
        .name = "local",
        .repo = null,
        .local_path = "roms",
        .globs = &.{ "*.ch8" },
    },
    .{
        .name = "kripod",
        .repo = "kripod/chip8-roms",
        .local_path = null,
        .globs = &.{ "games/*.ch8", "demos/*.ch8", "programs/*.ch8" },
    },
    .{
        .name = "dmatlack",
        .repo = "dmatlack/chip8",
        .local_path = null,
        .globs = &.{ "roms/games/*.ch8", "roms/demos/*.ch8" },
    },
    .{
        .name = "earnest",
        .repo = "JohnEarnest/chip8Archive",
        .local_path = null,
        .globs = &.{ "roms/*.ch8", "programs/*.ch8" },
    },
    .{
        .name = "viper",
        .repo = "Timendus/3d-viper-maze",
        .local_path = null,
        .globs = &.{ "*.ch8" },
    },
};

pub fn loadConfig(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) !Config {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{app_data_root});
    defer allocator.free(config_path);

    const data = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(1 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return try createDefaultConfig(io, allocator, app_data_root),
        else => return err,
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(Config, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var registries = try allocator.alloc(models.KnownRegistry, parsed.value.known_registries.len);
    for (parsed.value.known_registries, 0..) |reg, i| {
        var globs = try allocator.alloc([]const u8, reg.globs.len);
        for (reg.globs, 0..) |glob, j| {
            globs[j] = try allocator.dupe(u8, glob);
        }
        registries[i] = .{
            .name = try allocator.dupe(u8, reg.name),
            .repo = if (reg.repo) |v| try allocator.dupe(u8, v) else null,
            .local_path = if (reg.local_path) |v| try allocator.dupe(u8, v) else null,
            .globs = globs,
        };
    }

    return .{ .known_registries = registries };
}

fn createDefaultConfig(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) !Config {
    var registries = try allocator.alloc(models.KnownRegistry, DEFAULT_REGISTRIES.len);
    for (DEFAULT_REGISTRIES, 0..) |reg, i| {
        var globs = try allocator.alloc([]const u8, reg.globs.len);
        for (reg.globs, 0..) |glob, j| {
            globs[j] = try allocator.dupe(u8, glob);
        }
        registries[i] = .{
            .name = try allocator.dupe(u8, reg.name),
            .repo = if (reg.repo) |v| try allocator.dupe(u8, v) else null,
            .local_path = if (reg.local_path) |v| try allocator.dupe(u8, v) else null,
            .globs = globs,
        };
    }

    const config = Config{ .known_registries = registries };
    try saveConfig(io, allocator, app_data_root, config);
    return config;
}

pub fn saveConfig(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8, config: Config) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{app_data_root});
    defer allocator.free(config_path);

    if (std.fs.path.dirname(config_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(config, .{ .whitespace = .indent_2 }, &writer.writer);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = writer.written() });
    }

