const std = @import("std");
const models = @import("registry_models.zig");
const url_mod = @import("url.zig");
const github = @import("github.zig");
const network = @import("network.zig");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const chip8_db_cache = @import("chip8_db_cache.zig");
const spec_mod = @import("spec.zig");
const cpu_mod = @import("cpu.zig");

pub const RegistryError = error{
    NotFound,
    NotFoundStale,
    NetworkUnavailable,
    RateLimited,
    ChecksumMismatch,
    InvalidManifest,
    InvalidUrl,
    AlreadyInstalled,
    NoManifestFound,
    AmbiguousQuery,
    UnquotedGlob,
    UnsupportedSource,
    UnknownRegistry,
    RequestFailed,
    IoError,
} || std.mem.Allocator.Error;

pub const SearchResult = struct {
    metadata: models.RomMetadata,
    registry_name: []const u8,

    pub fn deinit(self: SearchResult, allocator: std.mem.Allocator) void {
        self.metadata.deinit(allocator);
        allocator.free(self.registry_name);
    }
};

// --- listInstalled / remove ------------------------------------------------

pub fn listInstalled(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8) ![]models.InstalledRom {
    const installed_dir_path = try std.fmt.allocPrint(allocator, "{s}/installed_roms", .{app_data_root});
    defer allocator.free(installed_dir_path);

    var results: std.ArrayList(models.InstalledRom) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try collectSidecars(io, allocator, installed_dir_path, &results);
    return results.toOwnedSlice(allocator);
}

fn collectSidecars(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    results: *std.ArrayList(models.InstalledRom),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            // Registry-namespaced subdirectory (e.g. installed_roms/kripod/).
            const sub = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(sub);
            try collectSidecars(io, allocator, sub, results);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const data = dir.readFileAlloc(io, entry.name, allocator, .limited(1 * 1024 * 1024)) catch continue;
        defer allocator.free(data);

        // Skip sidecars that don't match the current schema (e.g. left over
        // from an earlier version) instead of failing the whole listing.
        const parsed = std.json.parseFromSlice(models.InstalledRom, allocator, data, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();

        try results.append(allocator, try parsed.value.clone(allocator));
    }
}

// Remove by id. Accepts:
//   - "<id>"                 → matches any installed ROM with that id
//   - "<registry>:<id>"      → matches only if installed from that registry
// Returns error.NotFound if nothing matched, error.AmbiguousQuery if multiple
// registries have the same id and the caller didn't namespace the request.
pub fn remove(io: std.Io, allocator: std.mem.Allocator, id: []const u8, app_data_root: []const u8) !void {
    const installed = try listInstalled(io, allocator, app_data_root);
    defer {
        for (installed) |r| r.deinit(allocator);
        allocator.free(installed);
    }

    const requested = parseQualifiedId(id);
    var match: ?models.InstalledRom = null;
    var multiple = false;
    for (installed) |rom| {
        if (!std.mem.eql(u8, rom.metadata.id, requested.id)) continue;
        if (requested.registry) |want| {
            const ns = installedRegistryName(rom) orelse continue;
            if (!std.mem.eql(u8, ns, want)) continue;
        }
        if (match != null) {
            multiple = true;
            break;
        }
        match = rom;
    }

    if (multiple) return error.AmbiguousQuery;
    const target = match orelse return error.NotFound;

    // Derive sidecar path from rom path (…/<id>.ch8 → …/<id>.json).
    const rom_path = target.local.path;
    const sidecar_path = try std.fmt.allocPrint(allocator, "{s}.json", .{rom_path[0 .. rom_path.len - 4]});
    defer allocator.free(sidecar_path);

    std.Io.Dir.cwd().deleteFile(io, rom_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, sidecar_path) catch {};
}

pub const QualifiedId = struct { registry: ?[]const u8, id: []const u8 };

pub fn parseQualifiedId(input: []const u8) QualifiedId {
    if (std.mem.indexOfScalar(u8, input, ':')) |idx| {
        return .{ .registry = input[0..idx], .id = input[idx + 1 ..] };
    }
    return .{ .registry = null, .id = input };
}

pub fn installedRegistryName(rom: models.InstalledRom) ?[]const u8 {
    return switch (rom.local.source) {
        .known_registry => |v| v.name,
        else => null,
    };
}

// --- search (offline, over state) -----------------------------------------

pub fn search(
    allocator: std.mem.Allocator,
    query: []const u8,
    state: *const state_mod.State,
    db_cache: *const chip8_db_cache.State,
) ![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (results.items) |r| r.deinit(allocator);
        results.deinit(allocator);
    }

    var it = state.registries.iterator();
    while (it.next()) |kv| {
        const reg_name = kv.key_ptr.*;
        const reg_state = kv.value_ptr.*;

        for (reg_state.entries) |entry| {
            const name = std.fs.path.basename(entry.path);
            const db_entry: ?models.Chip8DbEntry = if (entry.chip8_db_hash) |h| db_cache.lookup(h) else null;

            if (!matches(query, name, db_entry)) continue;

            const id = try allocator.dupe(u8, std.fs.path.stem(name));
            errdefer allocator.free(id);
            const file = try allocator.dupe(u8, entry.path);
            errdefer allocator.free(file);
            const sha1 = try allocator.dupe(u8, entry.sha1);
            errdefer allocator.free(sha1);

            const db_clone: ?models.Chip8DbEntry = if (db_entry) |e| try e.clone(allocator) else null;

            try results.append(allocator, .{
                .metadata = .{
                    .id = id,
                    .file = file,
                    .sha1 = sha1,
                    .chip8_db_entry = db_clone,
                },
                .registry_name = try allocator.dupe(u8, reg_name),
            });
        }
    }

    return results.toOwnedSlice(allocator);
}

fn matches(query: []const u8, name: []const u8, db: ?models.Chip8DbEntry) bool {
    if (containsFold(name, query)) return true;
    if (db) |e| {
        if (containsFold(e.title, query)) return true;
        if (containsFold(e.description, query)) return true;
        for (e.authors) |a| if (containsFold(a, query)) return true;
    }
    return false;
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

// --- install dispatch -----------------------------------------------------

pub const InstallContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    app_data_root: []const u8,
    config: config_mod.Config,
    state: *state_mod.State,
    db_cache: *chip8_db_cache.State,
};

pub fn install(ctx: *InstallContext, source_url: url_mod.SourceUrl) RegistryError!models.InstalledRom {
    switch (source_url) {
        .direct_url => |u| return installDirect(ctx, u),
        .repo_file => |info| return installRepoFile(ctx, info.user, info.repo, info.branch, info.path, null),
        .repo_glob => |info| return installRepoGlob(ctx, info.user, info.repo, info.branch, info.path, info.pattern),
        .repo_dir => |info| return installRepoGlob(ctx, info.user, info.repo, info.branch, info.path, "*.ch8"),
        .repo_root => |info| return installRepoRoot(ctx, info.user, info.repo, info.branch),
        .repo_id => |info| return installRepoId(ctx, info.user, info.repo, info.id),
        .registry_shorthand => |info| return installRegistryShorthand(ctx, info.name, info.query),
        .local_file => |p| return installLocalFile(ctx, p),
        .local_dir => |p| return installLocalDir(ctx, p),
    }
}

fn installDirect(ctx: *InstallContext, u: []const u8) RegistryError!models.InstalledRom {
    const data = network.fetchBytes(ctx.io, ctx.allocator, u) catch return error.NetworkUnavailable;
    defer ctx.allocator.free(data);

    const id = std.fs.path.stem(std.fs.path.basename(u));
    const file_name = std.fs.path.basename(u);

    return try writeInstalled(ctx, .{
        .id = id,
        .file = file_name,
        .raw_url = u,
        .bytes = data,
        .source = .{ .direct_url = u },
        .expected_sha1 = null,
    });
}

fn installRepoFile(
    ctx: *InstallContext,
    user: []const u8,
    repo: []const u8,
    branch: []const u8,
    path: []const u8,
    expected_sha1: ?[]const u8,
) RegistryError!models.InstalledRom {
    const raw_url = try url_mod.resolveGithubRaw(ctx.allocator, user, repo, branch, path);
    defer ctx.allocator.free(raw_url);

    const data = network.fetchBytes(ctx.io, ctx.allocator, raw_url) catch |err| return mapNetworkError(err);
    defer ctx.allocator.free(data);

    const base = std.fs.path.basename(path);
    const id = std.fs.path.stem(base);
    const source_url = try std.fmt.allocPrint(ctx.allocator, "https://github.com/{s}/{s}/blob/{s}/{s}", .{ user, repo, branch, path });
    defer ctx.allocator.free(source_url);

    return try writeInstalled(ctx, .{
        .id = id,
        .file = base,
        .source_url = source_url,
        .raw_url = raw_url,
        .bytes = data,
        .source = .{ .repo_file = .{ .user = user, .repo = repo, .path = path } },
        .expected_sha1 = expected_sha1,
    });
}

fn installRepoGlob(
    ctx: *InstallContext,
    user: []const u8,
    repo: []const u8,
    branch: []const u8,
    dir: []const u8,
    pattern: []const u8,
) RegistryError!models.InstalledRom {
    const token = ctx.config.github_token;
    const contents = github.listContents(ctx.io, ctx.allocator, user, repo, dir, token) catch |err| switch (err) {
        github.Error.NotFound => return error.NotFound,
        github.Error.RateLimited => return error.RateLimited,
        github.Error.NetworkUnavailable => return error.NetworkUnavailable,
        else => return error.RequestFailed,
    };
    defer github.freeEntries(ctx.allocator, contents);

    var last: ?models.InstalledRom = null;
    errdefer if (last) |v| v.deinit(ctx.allocator);

    var count: usize = 0;
    for (contents) |c| {
        if (!std.mem.eql(u8, c.type, "file")) continue;
        if (!globMatch(pattern, c.name)) continue;
        if (last) |v| {
            v.deinit(ctx.allocator);
            last = null;
        }
        last = try installRepoFile(ctx, user, repo, branch, c.path, null);
        count += 1;
    }

    if (count == 0) return error.NotFound;
    return last.?;
}

fn installRepoRoot(
    ctx: *InstallContext,
    user: []const u8,
    repo: []const u8,
    branch: []const u8,
) RegistryError!models.InstalledRom {
    const manifest = fetchRepoManifest(ctx, user, repo, branch, "") catch |err| switch (err) {
        error.NoManifestFound => return error.NoManifestFound,
        else => return err,
    };
    defer manifest.deinit(ctx.allocator);

    if (manifest.roms.len == 0) return error.NotFound;
    if (manifest.roms.len > 1) return error.AmbiguousQuery;

    const rom = manifest.roms[0];
    return installRepoFile(ctx, user, repo, branch, rom.file, rom.sha1);
}

fn installRepoId(
    ctx: *InstallContext,
    user: []const u8,
    repo: []const u8,
    id: []const u8,
) RegistryError!models.InstalledRom {
    const manifest = fetchRepoManifest(ctx, user, repo, "main", "") catch |err| return err;
    defer manifest.deinit(ctx.allocator);

    for (manifest.roms) |rom| {
        if (std.mem.eql(u8, rom.id, id)) {
            return installRepoFile(ctx, user, repo, "main", rom.file, rom.sha1);
        }
    }
    return error.NotFound;
}

fn installRegistryShorthand(ctx: *InstallContext, name: []const u8, query: []const u8) RegistryError!models.InstalledRom {
    const reg = findRegistry(ctx.config, name) orelse return error.UnknownRegistry;

    if (try tryInstallMatch(ctx, reg, query)) |inst| return inst;

    // On miss, resync this one registry and retry.
    state_mod.syncRegistry(ctx.io, ctx.allocator, ctx.state, reg.name, ctx.config, ctx.db_cache) catch return error.NotFoundStale;

    if (try tryInstallMatch(ctx, reg, query)) |inst| return inst;
    return error.NotFound;
}

fn tryInstallMatch(ctx: *InstallContext, reg: models.KnownRegistry, query: []const u8) RegistryError!?models.InstalledRom {
    // Capture a snapshot of path + download_url before install mutates state.
    const snapshot = findMatchSnapshot(ctx.state, reg.name, query) orelse return null;
    const path_dup = try ctx.allocator.dupe(u8, snapshot.path);
    defer ctx.allocator.free(path_dup);
    const dl_dup = if (snapshot.download_url) |d| try ctx.allocator.dupe(u8, d) else null;
    defer if (dl_dup) |d| ctx.allocator.free(d);
    return try installRepoFileAt(ctx, reg.repo_user(), reg.repo_name(), path_dup, dl_dup, null, reg.name);
}

const MatchSnapshot = struct {
    path: []const u8,
    download_url: ?[]const u8,
};

fn findMatchSnapshot(state: *const state_mod.State, reg_name: []const u8, query: []const u8) ?MatchSnapshot {
    const reg_state = state.get(reg_name) orelse return null;
    var best: ?MatchSnapshot = null;
    for (reg_state.entries) |entry| {
        const stem = std.fs.path.stem(std.fs.path.basename(entry.path));
        if (std.mem.eql(u8, stem, query)) {
            return .{ .path = entry.path, .download_url = entry.download_url };
        }
        if (containsFold(stem, query) and best == null) {
            best = .{ .path = entry.path, .download_url = entry.download_url };
        }
    }
    return best;
}

// Like installRepoFile but prefers a caller-supplied raw download URL (from
// GitHub's contents API) so we avoid guessing at branch names. When
// `registry_name` is provided, the install is attributed to that registry
// (shown in listings; sidecar namespaced to avoid collisions between
// registries that happen to ship the same filename).
fn installRepoFileAt(
    ctx: *InstallContext,
    user: []const u8,
    repo: []const u8,
    path: []const u8,
    download_url: ?[]const u8,
    expected_sha1: ?[]const u8,
    registry_name: ?[]const u8,
) RegistryError!models.InstalledRom {
    const raw_url = if (download_url) |d|
        try ctx.allocator.dupe(u8, d)
    else
        try url_mod.resolveGithubRaw(ctx.allocator, user, repo, "main", path);
    defer ctx.allocator.free(raw_url);

    const data = network.fetchBytes(ctx.io, ctx.allocator, raw_url) catch |err| return mapNetworkError(err);
    defer ctx.allocator.free(data);

    const base = std.fs.path.basename(path);
    const id = std.fs.path.stem(base);
    const source_url = try std.fmt.allocPrint(ctx.allocator, "https://github.com/{s}/{s}/blob/HEAD/{s}", .{ user, repo, path });
    defer ctx.allocator.free(source_url);

    const source: models.InstalledRom.Source = if (registry_name) |reg_name|
        .{ .known_registry = .{ .name = reg_name, .user = user, .repo = repo, .path = path } }
    else
        .{ .repo_file = .{ .user = user, .repo = repo, .path = path } };

    return try writeInstalled(ctx, .{
        .id = id,
        .file = base,
        .source_url = source_url,
        .raw_url = raw_url,
        .bytes = data,
        .source = source,
        .expected_sha1 = expected_sha1,
        .namespace = registry_name,
    });
}

fn installLocalFile(ctx: *InstallContext, path: []const u8) RegistryError!models.InstalledRom {
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(cpu_mod.CHIP8_MEMORY_SIZE)) catch return error.IoError;
    defer ctx.allocator.free(data);

    const base = std.fs.path.basename(path);
    const id = std.fs.path.stem(base);

    return try writeInstalled(ctx, .{
        .id = id,
        .file = base,
        .source_url = path,
        .bytes = data,
        .source = .{ .local_import = path },
        .expected_sha1 = null,
    });
}

fn installLocalDir(ctx: *InstallContext, path: []const u8) RegistryError!models.InstalledRom {
    // Look for chip8.json first.
    const manifest_path = try std.fmt.allocPrint(ctx.allocator, "{s}/chip8.json", .{path});
    defer ctx.allocator.free(manifest_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, manifest_path, ctx.allocator, .limited(1 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return installLocalDirNoManifest(ctx, path),
        else => return error.IoError,
    };
    defer ctx.allocator.free(bytes);

    const result = spec_mod.validateManifest(ctx.allocator, bytes) catch return error.InvalidManifest;
    defer result.deinit(ctx.allocator);

    if (result == .errors) return error.InvalidManifest;
    const manifest = result.ok;

    if (manifest.roms.len == 0) return error.NotFound;
    var last: ?models.InstalledRom = null;
    errdefer if (last) |v| v.deinit(ctx.allocator);
    for (manifest.roms) |rom| {
        if (last) |v| {
            v.deinit(ctx.allocator);
            last = null;
        }
        const rom_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, rom.file });
        defer ctx.allocator.free(rom_path);
        last = try installLocalFile(ctx, rom_path);
    }
    return last.?;
}

fn installLocalDirNoManifest(ctx: *InstallContext, path: []const u8) RegistryError!models.InstalledRom {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch return error.IoError;
    defer dir.close(ctx.io);

    var last: ?models.InstalledRom = null;
    errdefer if (last) |v| v.deinit(ctx.allocator);
    var it = dir.iterate();
    while (it.next(ctx.io) catch return error.IoError) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ch8") and !std.mem.endsWith(u8, entry.name, ".rom")) continue;
        if (last) |v| {
            v.deinit(ctx.allocator);
            last = null;
        }
        const full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, entry.name });
        defer ctx.allocator.free(full);
        last = try installLocalFile(ctx, full);
    }
    return last orelse error.NotFound;
}

fn fetchRepoManifest(
    ctx: *InstallContext,
    user: []const u8,
    repo: []const u8,
    branch: []const u8,
    subdir: []const u8,
) RegistryError!models.Manifest {
    const path = if (subdir.len == 0)
        try ctx.allocator.dupe(u8, "chip8.json")
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}/chip8.json", .{subdir});
    defer ctx.allocator.free(path);

    const raw_url = try url_mod.resolveGithubRaw(ctx.allocator, user, repo, branch, path);
    defer ctx.allocator.free(raw_url);

    const bytes = network.fetchBytes(ctx.io, ctx.allocator, raw_url) catch |err| {
        const name = @errorName(err);
        if (std.mem.eql(u8, name, "NotFound")) return error.NoManifestFound;
        if (std.mem.eql(u8, name, "NetworkUnavailable")) return error.NetworkUnavailable;
        if (std.mem.eql(u8, name, "RateLimited")) return error.RateLimited;
        return error.RequestFailed;
    };
    defer ctx.allocator.free(bytes);

    const result = spec_mod.validateManifest(ctx.allocator, bytes) catch return error.InvalidManifest;
    switch (result) {
        .errors => |errs| {
            allocator_free_errs(ctx.allocator, errs);
            return error.InvalidManifest;
        },
        .ok => |m| return m,
    }
}

fn allocator_free_errs(allocator: std.mem.Allocator, errs: []spec_mod.ValidationError) void {
    for (errs) |e| e.deinit(allocator);
    allocator.free(errs);
}

// --- sidecar write --------------------------------------------------------

const WriteParams = struct {
    id: []const u8,
    file: []const u8,
    source_url: ?[]const u8 = null,
    raw_url: ?[]const u8 = null,
    bytes: []const u8,
    source: models.InstalledRom.Source,
    expected_sha1: ?[]const u8,
    // When set, files are written under installed_roms/<namespace>/ so two
    // registries shipping the same filename don't collide on disk.
    namespace: ?[]const u8 = null,
};

fn writeInstalled(ctx: *InstallContext, params: WriteParams) RegistryError!models.InstalledRom {
    const sha1_bin = models.computeRomSha1(params.bytes);
    const sha1_hex = try models.sha1HexAlloc(ctx.allocator, sha1_bin);
    errdefer ctx.allocator.free(sha1_hex);

    if (params.expected_sha1) |expected| {
        if (!std.mem.eql(u8, expected, sha1_hex)) return error.ChecksumMismatch;
    }

    const installed_dir = if (params.namespace) |ns|
        try std.fmt.allocPrint(ctx.allocator, "{s}/installed_roms/{s}", .{ ctx.app_data_root, ns })
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}/installed_roms", .{ctx.app_data_root});
    defer ctx.allocator.free(installed_dir);
    std.Io.Dir.cwd().createDirPath(ctx.io, installed_dir) catch return error.IoError;

    const rom_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.ch8", .{ installed_dir, params.id });
    errdefer ctx.allocator.free(rom_path);

    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = rom_path, .data = params.bytes }) catch return error.IoError;

    // Look up chip-8-database entry.
    var db_entry: ?models.Chip8DbEntry = null;
    errdefer if (db_entry) |e| e.deinit(ctx.allocator);
    if (ctx.db_cache.lookup(sha1_hex)) |e| {
        db_entry = try e.clone(ctx.allocator);
    } else if (!ctx.db_cache.isKnownMiss(sha1_hex)) {
        const fetched = chip8_db_cache.fetchAndCache(ctx.io, ctx.allocator, ctx.db_cache, sha1_hex) catch null;
        if (fetched) |e| db_entry = try e.clone(ctx.allocator);
    }

    const metadata = models.RomMetadata{
        .id = try ctx.allocator.dupe(u8, params.id),
        .file = try ctx.allocator.dupe(u8, params.file),
        .source_url = if (params.source_url) |v| try ctx.allocator.dupe(u8, v) else null,
        .raw_url = if (params.raw_url) |v| try ctx.allocator.dupe(u8, v) else null,
        .sha1 = try ctx.allocator.dupe(u8, sha1_hex),
        .tags = null,
        .chip8_db_entry = db_entry,
    };
    errdefer metadata.deinit(ctx.allocator);
    db_entry = null; // ownership transferred

    const source_clone = try params.source.clone(ctx.allocator);
    errdefer source_clone.deinit(ctx.allocator);

    const installed = models.InstalledRom{
        .metadata = metadata,
        .local = .{
            .path = rom_path,
            .installed_at = std.Io.Clock.now(.real, ctx.io).toMilliseconds(),
            .sha1 = sha1_hex,
            .source = source_clone,
        },
    };

    const sidecar_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}.json", .{ installed_dir, params.id });
    defer ctx.allocator.free(sidecar_path);

    var writer: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer writer.deinit();
    std.json.Stringify.value(installed, .{ .whitespace = .indent_2 }, &writer.writer) catch return error.IoError;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = sidecar_path, .data = writer.written() }) catch return error.IoError;

    return installed;
}

// --- update ---------------------------------------------------------------

pub fn update(ctx: *InstallContext, id: []const u8) RegistryError!models.InstalledRom {
    // Find the sidecar via listInstalled (handles namespaced subdirs and
    // `<registry>:<id>` qualification).
    const installed = listInstalled(ctx.io, ctx.allocator, ctx.app_data_root) catch return error.IoError;
    defer {
        for (installed) |r| r.deinit(ctx.allocator);
        ctx.allocator.free(installed);
    }
    const requested = parseQualifiedId(id);
    var match: ?models.InstalledRom = null;
    var multiple = false;
    for (installed) |rom| {
        if (!std.mem.eql(u8, rom.metadata.id, requested.id)) continue;
        if (requested.registry) |want| {
            const ns = installedRegistryName(rom) orelse continue;
            if (!std.mem.eql(u8, ns, want)) continue;
        }
        if (match != null) {
            multiple = true;
            break;
        }
        match = rom;
    }
    if (multiple) return error.AmbiguousQuery;
    const target = match orelse return error.NotFound;

    const source = target.local.source;
    const source_url: url_mod.SourceUrl = switch (source) {
        .direct_url => |u| .{ .direct_url = try ctx.allocator.dupe(u8, u) },
        .repo_file => |v| .{ .repo_file = .{
            .user = try ctx.allocator.dupe(u8, v.user),
            .repo = try ctx.allocator.dupe(u8, v.repo),
            .branch = try ctx.allocator.dupe(u8, "main"),
            .path = try ctx.allocator.dupe(u8, v.path),
        } },
        .repo_glob => |v| .{ .repo_glob = .{
            .user = try ctx.allocator.dupe(u8, v.user),
            .repo = try ctx.allocator.dupe(u8, v.repo),
            .branch = try ctx.allocator.dupe(u8, "main"),
            .path = try ctx.allocator.dupe(u8, ""),
            .pattern = try ctx.allocator.dupe(u8, v.pattern),
        } },
        .manifest_entry => |v| .{ .repo_id = .{
            .user = try ctx.allocator.dupe(u8, v.user),
            .repo = try ctx.allocator.dupe(u8, v.repo),
            .id = try ctx.allocator.dupe(u8, v.id),
        } },
        .known_registry => |v| .{ .registry_shorthand = .{
            .name = try ctx.allocator.dupe(u8, v.name),
            .query = try ctx.allocator.dupe(u8, parseQualifiedId(id).id),
        } },
        .local_import => |p| .{ .local_file = try ctx.allocator.dupe(u8, p) },
    };
    defer source_url.deinit(ctx.allocator);

    return install(ctx, source_url);
}

// --- helpers --------------------------------------------------------------

fn mapNetworkError(err: anyerror) RegistryError {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "NotFound")) return error.NotFound;
    if (std.mem.eql(u8, name, "RateLimited")) return error.RateLimited;
    if (std.mem.eql(u8, name, "NetworkUnavailable")) return error.NetworkUnavailable;
    return error.RequestFailed;
}

fn findRegistry(config: config_mod.Config, name: []const u8) ?models.KnownRegistry {
    for (config.known_registries) |reg| {
        if (std.mem.eql(u8, reg.name, name)) return reg;
    }
    return null;
}

fn globMatch(pattern: []const u8, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return std.mem.eql(u8, pattern, name);
    }
    return matchHere(pattern, name);
}

fn matchHere(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    while (p < pattern.len) {
        if (pattern[p] == '*') {
            while (p < pattern.len and pattern[p] == '*') p += 1;
            if (p == pattern.len) return true;
            while (n <= name.len) : (n += 1) {
                if (matchHere(pattern[p..], name[n..])) return true;
            }
            return false;
        }
        if (n >= name.len) return false;
        if (pattern[p] != name[n]) return false;
        p += 1;
        n += 1;
    }
    return n == name.len;
}
