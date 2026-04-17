const std = @import("std");

pub const SPEC_VERSION: u32 = 1;

pub const Chip8DbEntry = struct {
    title: []const u8,
    description: []const u8,
    release: []const u8,
    authors: []const []const u8,
    platforms: []const []const u8 = &.{},
    file: ?[]const u8 = null,
    embedded_title: ?[]const u8 = null,
    tickrate: ?u32 = null,

    pub fn clone(self: Chip8DbEntry, allocator: std.mem.Allocator) !Chip8DbEntry {
        var authors = try allocator.alloc([]const u8, self.authors.len);
        errdefer allocator.free(authors);
        for (self.authors, 0..) |a, i| authors[i] = try allocator.dupe(u8, a);

        var platforms = try allocator.alloc([]const u8, self.platforms.len);
        errdefer allocator.free(platforms);
        for (self.platforms, 0..) |p, i| platforms[i] = try allocator.dupe(u8, p);

        return .{
            .title = try allocator.dupe(u8, self.title),
            .description = try allocator.dupe(u8, self.description),
            .release = try allocator.dupe(u8, self.release),
            .authors = authors,
            .platforms = platforms,
            .file = if (self.file) |v| try allocator.dupe(u8, v) else null,
            .embedded_title = if (self.embedded_title) |v| try allocator.dupe(u8, v) else null,
            .tickrate = self.tickrate,
        };
    }

    pub fn deinit(self: Chip8DbEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.release);
        for (self.authors) |a| allocator.free(a);
        allocator.free(self.authors);
        for (self.platforms) |p| allocator.free(p);
        allocator.free(self.platforms);
        if (self.file) |v| allocator.free(v);
        if (self.embedded_title) |v| allocator.free(v);
    }
};

pub const RomMetadata = struct {
    id: []const u8,
    file: []const u8,
    source_url: ?[]const u8 = null,
    raw_url: ?[]const u8 = null,
    sha1: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    chip8_db_entry: ?Chip8DbEntry = null,

    pub fn clone(self: RomMetadata, allocator: std.mem.Allocator) !RomMetadata {
        var tags: ?[]const []const u8 = null;
        if (self.tags) |t| {
            var new_tags = try allocator.alloc([]const u8, t.len);
            errdefer allocator.free(new_tags);
            for (t, 0..) |tag, i| new_tags[i] = try allocator.dupe(u8, tag);
            tags = new_tags;
        }
        return .{
            .id = try allocator.dupe(u8, self.id),
            .file = try allocator.dupe(u8, self.file),
            .source_url = if (self.source_url) |v| try allocator.dupe(u8, v) else null,
            .raw_url = if (self.raw_url) |v| try allocator.dupe(u8, v) else null,
            .sha1 = if (self.sha1) |v| try allocator.dupe(u8, v) else null,
            .tags = tags,
            .chip8_db_entry = if (self.chip8_db_entry) |e| try e.clone(allocator) else null,
        };
    }

    pub fn deinit(self: RomMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.file);
        if (self.source_url) |v| allocator.free(v);
        if (self.raw_url) |v| allocator.free(v);
        if (self.sha1) |v| allocator.free(v);
        if (self.tags) |tags| {
            for (tags) |tag| allocator.free(tag);
            allocator.free(tags);
        }
        if (self.chip8_db_entry) |e| e.deinit(allocator);
    }
};

pub const Manifest = struct {
    spec_version: u32 = SPEC_VERSION,
    roms: []RomMetadata,

    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        for (self.roms) |rom| rom.deinit(allocator);
        allocator.free(self.roms);
    }
};

pub const InstalledRom = struct {
    metadata: RomMetadata,
    local: Local,

    pub const Local = struct {
        path: []const u8,
        installed_at: i64,
        sha1: []const u8,
        source: Source,
    };

    pub const Source = union(enum) {
        direct_url: []const u8,
        repo_file: RepoFile,
        repo_glob: RepoGlob,
        manifest_entry: ManifestEntry,
        known_registry: []const u8,
        local_import: []const u8,

        pub const RepoFile = struct { user: []const u8, repo: []const u8, path: []const u8 };
        pub const RepoGlob = struct { user: []const u8, repo: []const u8, pattern: []const u8 };
        pub const ManifestEntry = struct { user: []const u8, repo: []const u8, id: []const u8 };

        pub fn clone(self: Source, allocator: std.mem.Allocator) !Source {
            return switch (self) {
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

        pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
            switch (self) {
                .direct_url => |v| allocator.free(v),
                .repo_file => |v| {
                    allocator.free(v.user);
                    allocator.free(v.repo);
                    allocator.free(v.path);
                },
                .repo_glob => |v| {
                    allocator.free(v.user);
                    allocator.free(v.repo);
                    allocator.free(v.pattern);
                },
                .manifest_entry => |v| {
                    allocator.free(v.user);
                    allocator.free(v.repo);
                    allocator.free(v.id);
                },
                .known_registry => |v| allocator.free(v),
                .local_import => |v| allocator.free(v),
            }
        }
    };

    pub fn clone(self: InstalledRom, allocator: std.mem.Allocator) !InstalledRom {
        return .{
            .metadata = try self.metadata.clone(allocator),
            .local = .{
                .path = try allocator.dupe(u8, self.local.path),
                .installed_at = self.local.installed_at,
                .sha1 = try allocator.dupe(u8, self.local.sha1),
                .source = try self.local.source.clone(allocator),
            },
        };
    }

    pub fn deinit(self: InstalledRom, allocator: std.mem.Allocator) void {
        self.metadata.deinit(allocator);
        allocator.free(self.local.path);
        allocator.free(self.local.sha1);
        self.local.source.deinit(allocator);
    }
};

pub const KnownRegistry = struct {
    name: []const u8,
    repo: []const u8,
    globs: []const []const u8,

    pub fn repo_user(self: KnownRegistry) []const u8 {
        var it = std.mem.splitScalar(u8, self.repo, '/');
        return it.next() orelse "";
    }

    pub fn repo_name(self: KnownRegistry) []const u8 {
        var it = std.mem.splitScalar(u8, self.repo, '/');
        _ = it.next();
        return it.next() orelse "";
    }

    pub fn deinit(self: KnownRegistry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.repo);
        for (self.globs) |glob| allocator.free(glob);
        allocator.free(self.globs);
    }
};

pub fn computeRomSha1(rom_data: []const u8) [20]u8 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(rom_data, &digest, .{});
    return digest;
}

pub fn sha1HexAlloc(allocator: std.mem.Allocator, hash: [20]u8) ![]u8 {
    const buf = std.fmt.bytesToHex(&hash, .lower);
    return allocator.dupe(u8, &buf);
}
