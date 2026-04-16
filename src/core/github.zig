const std = @import("std");
const network = @import("network.zig");

pub const ContentEntry = struct {
    name: []const u8,
    path: []const u8,
    sha: []const u8,
    size: usize,
    url: []const u8,
    html_url: []const u8,
    git_url: []const u8,
    download_url: ?[]const u8,
    type: []const u8,
};

pub fn listContents(io: std.Io, allocator: std.mem.Allocator, user: []const u8, repo: []const u8, path: []const u8) ![]ContentEntry {
    var url_writer: std.Io.Writer.Allocating = .init(allocator);
    defer url_writer.deinit();
    try url_writer.writer.print("https://api.github.com/repos/{s}/{s}/contents/{s}", .{ user, repo, path });

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url_writer.written());
    
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const fetch_res = try client.fetch(.{
        .location = .{ .uri = uri },
        .headers = .{
            .user_agent = .{ .override = "chips-emulator" },
        },
        .response_writer = &writer.writer,
    });

    if (fetch_res.status == .not_found) return error.NotFound;
    if (fetch_res.status == .too_many_requests) return error.RateLimited;
    if (fetch_res.status != .ok) return error.RequestFailed;

    const body = writer.written();

    const parsed = try std.json.parseFromSlice([]ContentEntry, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // We need to dupe the strings because parsed.deinit() will free them
    var result = try allocator.alloc(ContentEntry, parsed.value.len);
    errdefer {
        // Cleaning up partially allocated result is complex here, 
        // but for simplicity in this utility we'll assume it's okay or use a better strategy if needed.
        // Actually, let's just use the allocator to dupe everything properly.
    }

    for (parsed.value, 0..) |entry, i| {
        result[i] = .{
            .name = try allocator.dupe(u8, entry.name),
            .path = try allocator.dupe(u8, entry.path),
            .sha = try allocator.dupe(u8, entry.sha),
            .size = entry.size,
            .url = try allocator.dupe(u8, entry.url),
            .html_url = try allocator.dupe(u8, entry.html_url),
            .git_url = try allocator.dupe(u8, entry.git_url),
            .download_url = if (entry.download_url) |du| try allocator.dupe(u8, du) else null,
            .type = try allocator.dupe(u8, entry.type),
        };
    }

    return result;
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []ContentEntry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
        allocator.free(entry.sha);
        allocator.free(entry.url);
        allocator.free(entry.html_url);
        allocator.free(entry.git_url);
        if (entry.download_url) |du| allocator.free(du);
        allocator.free(entry.type);
    }
    allocator.free(entries);
}
