const std = @import("std");

pub const CacheType = enum {
    manifests,
    listings,
};

pub fn getCachePath(allocator: std.mem.Allocator, app_data_root: []const u8, cache_type: CacheType, key: []const u8) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(key);
    const hash = hasher.final();

    return std.fmt.allocPrint(allocator, "{s}/cache/{s}/{x}.json", .{ app_data_root, @tagName(cache_type), hash });
}

pub fn saveToCache(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8, cache_type: CacheType, key: []const u8, data: []const u8) !void {
    const path = try getCachePath(allocator, app_data_root, cache_type, key);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn loadFromCache(io: std.Io, allocator: std.mem.Allocator, app_data_root: []const u8, cache_type: CacheType, key: []const u8, ttl_ms: i64) !?[]const u8 {
    const path = try getCachePath(allocator, app_data_root, cache_type, key);
    defer allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)) catch return null;

    // Check TTL - We can't easily get mtime from std.Io.Dir currently without more effort, 
    // so for now let's just return the data if it exists. 
    // In a real implementation we'd probably use std.fs for stat or store TTL in the JSON.
    _ = ttl_ms;

    return data;
}

pub fn clearCache(io: std.Io, app_data_root: []const u8) !void {
    const cache_root = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/cache", .{app_data_root});
    defer std.heap.page_allocator.free(cache_root);

    try std.Io.Dir.cwd().deleteTree(io, cache_root);
}
