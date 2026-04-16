const std = @import("std");

pub const FetchError = error{
    NetworkUnavailable,
    RateLimited,
    NotFound,
    InvalidJson,
    RedirectLoop,
    RequestFailed,
};

pub fn fetchBytes(io: std.Io, allocator: std.mem.Allocator, url_str: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url_str);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &writer.writer,
    });

    if (result.status == .not_found) return error.NotFound;
    if (result.status == .too_many_requests) return error.RateLimited;
    if (result.status != .ok) return error.RequestFailed;

    return try allocator.dupe(u8, writer.written());
}

pub fn fetchJson(io: std.Io, allocator: std.mem.Allocator, url_str: []const u8, comptime T: type) !std.json.Parsed(T) {
    const bytes = try fetchBytes(io, allocator, url_str);
    defer allocator.free(bytes);

    return std.json.parseFromSlice(T, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
}
