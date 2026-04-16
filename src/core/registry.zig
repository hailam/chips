const std = @import("std");
const models = @import("registry_models.zig");
const url_mod = @import("url.zig");
const github = @import("github.zig");
const network = @import("network.zig");
const cache = @import("cache.zig");
const config_mod = @import("config.zig");
const persistence = @import("persistence.zig");
const cpu_mod = @import("cpu.zig");

pub const RegistryError = error{
    NotFound,
    NetworkUnavailable,
    RateLimited,
    ChecksumMismatch,
    InvalidManifest,
    InvalidUrl,
    AlreadyInstalled,
    NoManifestFound,
    AmbiguousQuery,
    RequestFailed,
    IoError,
} || std.mem.Allocator.Error;

pub const SearchResult = struct {
    metadata: models.RomMetadata,
    registry_name: ?[]const u8,

    pub fn deinit(self: SearchResult, allocator: std.mem.Allocator) void {
        self.metadata.deinit(allocator);
        if (self.registry_name) |v| allocator.free(v);
    }
};

pub fn listInstalled(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) ![]models.InstalledRom {
    const installed_dir_path = try std.fmt.allocPrint(allocator, "{s}/installed_roms", .{app_data_root});
    defer allocator.free(installed_dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, installed_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var results: std.ArrayList(models.InstalledRom) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(allocator);
        results.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            const data = try dir.readFileAlloc(io, entry.name, allocator, .limited(1 * 1024 * 1024));
            defer allocator.free(data);

            const parsed = try std.json.parseFromSlice(models.InstalledRom, allocator, data, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            // We need to clone everything because parsed.deinit() will free it
            try results.append(allocator, try cloneInstalledRom(allocator, parsed.value));
        }
    }

    return results.toOwnedSlice(allocator);
}

fn cloneInstalledRom(allocator: std.mem.Allocator, other: models.InstalledRom) !models.InstalledRom {
    return .{
        .metadata = try cloneRomMetadata(allocator, other.metadata),
        .local = .{
            .path = try allocator.dupe(u8, other.local.path),
            .installed_at = other.local.installed_at,
            .sha256 = other.local.sha256,
            .source = try cloneSource(allocator, other.local.source),
        },
    };
}

fn cloneRomMetadata(allocator: std.mem.Allocator, other: models.RomMetadata) !models.RomMetadata {
    var tags: ?[]const []const u8 = null;
    if (other.tags) |t| {
        var new_tags = try allocator.alloc([]const u8, t.len);
        for (t, 0..) |tag, i| new_tags[i] = try allocator.dupe(u8, tag);
        tags = new_tags;
    }

    return .{
        .id = try allocator.dupe(u8, other.id),
        .name = if (other.name) |v| try allocator.dupe(u8, v) else null,
        .description = if (other.description) |v| try allocator.dupe(u8, v) else null,
        .author = if (other.author) |v| try allocator.dupe(u8, v) else null,
        .source_url = if (other.source_url) |v| try allocator.dupe(u8, v) else null,
        .raw_url = if (other.raw_url) |v| try allocator.dupe(u8, v) else null,
        .quirk_profile = other.quirk_profile,
        .tags = tags,
    };
}

fn cloneSource(allocator: std.mem.Allocator, other: models.InstalledRom.Source) !models.InstalledRom.Source {
    return switch (other) {
        .direct_url => |v| .{ .direct_url = try allocator.dupe(u8, v) },
        .repo_file => |v| .{ .repo_file = .{
            .user = try allocator.dupe(u8, v.user),
            .repo = try allocator.dupe(u8, v.repo),
            .path = try allocator.dupe(u8, v.path),
        } },
        .repo_glob => |v| .{ .repo_glob = .{
            .user = try allocator.dupe(u8, v.user),
            .repo = try allocator.dupe(u8, v.repo),
            .pattern = try allocator.dupe(u8, v.pattern),
        } },
        .manifest_entry => |v| .{ .manifest_entry = .{
            .user = try allocator.dupe(u8, v.user),
            .repo = try allocator.dupe(u8, v.repo),
            .id = try allocator.dupe(u8, v.id),
        } },
        .known_registry => |v| .{ .known_registry = try allocator.dupe(u8, v) },
        .local_import => |v| .{ .local_import = try allocator.dupe(u8, v) },
    };
}

pub fn install(io: std.Io, allocator: std.mem.Allocator, source_url: url_mod.SourceUrl, app_data_root: []const u8, config: config_mod.Config) !models.InstalledRom {
    _ = config; // To be used for registry shorthand and manifest lookup

    switch (source_url) {
        .direct_url => |url| {
            const data = try network.fetchBytes(io, allocator, url);
            defer allocator.free(data);

            const id = std.fs.path.stem(std.fs.path.basename(url));
            const sha256 = persistence.computeRomSha256(data);
            
            const metadata = models.RomMetadata{
                .id = try allocator.dupe(u8, id),
                .name = try allocator.dupe(u8, id),
                .raw_url = try allocator.dupe(u8, url),
            };
            defer metadata.deinit(allocator);

            return try saveInstalledRom(io, allocator, app_data_root, metadata, data, sha256, .{ .direct_url = try allocator.dupe(u8, url) });
        },
        .repo_file => |info| {
            const raw_url = try url_mod.resolveGithubRaw(allocator, info.user, info.repo, info.branch, info.path);
            defer allocator.free(raw_url);

            const data = try network.fetchBytes(io, allocator, raw_url);
            defer allocator.free(data);

            const id = std.fs.path.stem(std.fs.path.basename(info.path));
            const sha256 = persistence.computeRomSha256(data);

            const metadata = models.RomMetadata{
                .id = try allocator.dupe(u8, id),
                .name = try allocator.dupe(u8, id),
                .source_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/blob/{s}/{s}", .{ info.user, info.repo, info.branch, info.path }),
                .raw_url = try allocator.dupe(u8, raw_url),
            };
            defer metadata.deinit(allocator);

            return try saveInstalledRom(io, allocator, app_data_root, metadata, data, sha256, .{ .repo_file = .{
                .user = try allocator.dupe(u8, info.user),
                .repo = try allocator.dupe(u8, info.repo),
                .path = try allocator.dupe(u8, info.path),
            } });
        },
        .local_file => |path| {
            const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(cpu_mod.CHIP8_MEMORY_SIZE - @as(usize, 0x200)));
            defer allocator.free(data);

            const id = std.fs.path.stem(std.fs.path.basename(path));
            const sha256 = persistence.computeRomSha256(data);

            const metadata = models.RomMetadata{
                .id = try allocator.dupe(u8, id),
                .name = try allocator.dupe(u8, id),
                .source_url = try allocator.dupe(u8, path),
            };
            defer metadata.deinit(allocator);

            return try saveInstalledRom(io, allocator, app_data_root, metadata, data, sha256, .{ .local_import = try allocator.dupe(u8, path) });
        },
        // TODO: Implement other source types
        else => return error.InvalidUrl,
    }
}

pub fn syncLocalRegistries(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8, config: config_mod.Config) !void {
    for (config.known_registries) |reg| {
        if (reg.local_path) |local_path| {
            var dir = std.Io.Dir.cwd().openDir(io, local_path, .{ .iterate = true }) catch |err| {
                std.debug.print("Warning: could not open local registry path '{s}': {s}\n", .{ local_path, @errorName(err) });
                continue;
            };
            defer dir.close(io);

            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind == .file and (std.mem.endsWith(u8, entry.name, ".ch8") or std.mem.endsWith(u8, entry.name, ".rom"))) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ local_path, entry.name });
                    defer allocator.free(full_path);
                    
                    const source_url = try url_mod.parse(allocator, full_path);
                    defer source_url.deinit(allocator);

                    var installed = install(io, allocator, source_url, app_data_root, config) catch continue;
                    defer installed.deinit(allocator);
                    std.debug.print("  - Synced {s}\n", .{entry.name});
                }
            }
        }
    }
}

fn saveInstalledRom(
    io: std.Io,
    allocator: std.mem.Allocator,
    app_data_root: []const u8,
    metadata: models.RomMetadata,
    data: []const u8,
    sha256: [32]u8,
    source: models.InstalledRom.Source,
) !models.InstalledRom {
    const installed_dir = try std.fmt.allocPrint(allocator, "{s}/installed_roms", .{app_data_root});
    defer allocator.free(installed_dir);
    try std.Io.Dir.cwd().createDirPath(io, installed_dir);

    const rom_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ch8", .{ installed_dir, metadata.id });
    defer allocator.free(rom_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_path, .data = data });

    const installed_rom = models.InstalledRom{
        .metadata = metadata,
        .local = .{
            .path = try allocator.dupe(u8, rom_path),
            .installed_at = std.Io.Clock.now(.real, io).toMilliseconds(),
            .sha256 = sha256,
            .source = source,
        },
    };
    defer {
        // We don't call installed_rom.deinit(allocator) because it would free 'metadata' 
        // which was passed in and owned by the caller... wait.
        // Actually, let's just be careful.
    }

    const sidecar_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ installed_dir, metadata.id });
    defer allocator.free(sidecar_path);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(installed_rom, .{ .whitespace = .indent_2 }, &writer.writer);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sidecar_path, .data = writer.written() });

    // Transfer ownership of the allocated path and source to the returned struct
    // and clone the metadata (since we don't own it)
    return .{
        .metadata = try cloneRomMetadata(allocator, metadata),
        .local = .{
            .path = installed_rom.local.path,
            .installed_at = installed_rom.local.installed_at,
            .sha256 = installed_rom.local.sha256,
            .source = installed_rom.local.source,
        },
    };
}

pub fn search(io: std.Io, allocator: std.mem.Allocator, query: []const u8, config: config_mod.Config) ![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(allocator);
        results.deinit(allocator);
    }

    for (config.known_registries) |reg| {
        if (reg.repo) |repo| {
            _ = repo;
            // For each registry, we might want to fetch listings for its globs
            for (reg.globs) |glob_pattern| {
                const dir_path = std.fs.path.dirname(glob_pattern) orelse "";
                const entries = github.listContents(io, allocator, reg.repo_user(), reg.repo_name(), dir_path) catch continue;
                defer github.freeEntries(allocator, entries);

                for (entries) |entry| {
                    if (std.mem.indexOf(u8, entry.name, query) != null) {
                        if (std.mem.endsWith(u8, entry.name, ".ch8") or std.mem.endsWith(u8, entry.name, ".rom")) {
                            const id = std.fs.path.stem(entry.name);
                            try results.append(allocator, .{
                                .metadata = .{
                                    .id = try allocator.dupe(u8, id),
                                    .name = try allocator.dupe(u8, id),
                                    .source_url = try allocator.dupe(u8, entry.html_url),
                                    .raw_url = if (entry.download_url) |du| try allocator.dupe(u8, du) else null,
                                },
                                .registry_name = try allocator.dupe(u8, reg.name),
                            });
                        }
                    }
                }
            }
        } else if (reg.local_path) |local_path| {
            var dir = std.Io.Dir.cwd().openDir(io, local_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind == .file and (std.mem.endsWith(u8, entry.name, ".ch8") or std.mem.endsWith(u8, entry.name, ".rom"))) {
                    if (std.mem.indexOf(u8, entry.name, query) != null) {
                        const id = std.fs.path.stem(entry.name);
                        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ local_path, entry.name });
                        defer allocator.free(full_path);

                        try results.append(allocator, .{
                            .metadata = .{
                                .id = try allocator.dupe(u8, id),
                                .name = try allocator.dupe(u8, id),
                                .source_url = try allocator.dupe(u8, full_path),
                            },
                            .registry_name = try allocator.dupe(u8, reg.name),
                        });
                    }
                }
            }
        }
    }

    return results.toOwnedSlice(allocator);
}

pub fn remove(io: std.Io, allocator: std.mem.Allocator, id: []const u8, app_data_root: []const u8) !void {
    const installed_dir = try std.fmt.allocPrint(allocator, "{s}/installed_roms", .{app_data_root});
    defer allocator.free(installed_dir);

    const rom_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ch8", .{ installed_dir, id });
    defer allocator.free(rom_path);

    const sidecar_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ installed_dir, id });
    defer allocator.free(sidecar_path);

    std.Io.Dir.cwd().deleteFile(io, rom_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, sidecar_path) catch {};
}
