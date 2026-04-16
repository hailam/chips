const std = @import("std");
const emulation = @import("emulation_config.zig");

pub const RomMetadata = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    raw_url: ?[]const u8 = null,
    quirk_profile: ?emulation.QuirkProfile = null,
    tags: ?[]const []const u8 = null,

    pub fn deinit(self: RomMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.name) |v| allocator.free(v);
        if (self.description) |v| allocator.free(v);
        if (self.author) |v| allocator.free(v);
        if (self.source_url) |v| allocator.free(v);
        if (self.raw_url) |v| allocator.free(v);
        if (self.tags) |tags| {
            for (tags) |tag| allocator.free(tag);
            allocator.free(tags);
        }
    }
};

pub const Manifest = struct {
    roms: []RomMetadata,

    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        for (self.roms) |rom| rom.deinit(allocator);
        allocator.free(self.roms);
    }
};

pub const InstalledRom = struct {
    metadata: RomMetadata,
    local: struct {
        path: []const u8,
        installed_at: i64,
        sha256: [32]u8,
        source: Source,
    },

    pub const Source = union(enum) {
        direct_url: []const u8,
        repo_file: struct { user: []const u8, repo: []const u8, path: []const u8 },
        repo_glob: struct { user: []const u8, repo: []const u8, pattern: []const u8 },
        manifest_entry: struct { user: []const u8, repo: []const u8, id: []const u8 },
        known_registry: []const u8,
        local_import: []const u8,

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

    pub fn deinit(self: InstalledRom, allocator: std.mem.Allocator) void {
        self.metadata.deinit(allocator);
        allocator.free(self.local.path);
        self.local.source.deinit(allocator);
    }
};

pub const KnownRegistry = struct {
    name: []const u8,
    repo: ?[]const u8 = null,
    local_path: ?[]const u8 = null,
    globs: []const []const u8,

    pub fn repo_user(self: KnownRegistry) []const u8 {
        const repo = self.repo orelse return "";
        var it = std.mem.splitScalar(u8, repo, '/');
        return it.next() orelse "";
    }

    pub fn repo_name(self: KnownRegistry) []const u8 {
        const repo = self.repo orelse return "";
        var it = std.mem.splitScalar(u8, repo, '/');
        _ = it.next();
        return it.next() orelse "";
    }

    pub fn deinit(self: KnownRegistry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.repo) |v| allocator.free(v);
        if (self.local_path) |v| allocator.free(v);
        for (self.globs) |glob| allocator.free(glob);
        allocator.free(self.globs);
    }
};
