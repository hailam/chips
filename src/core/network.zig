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

// Cheap probe: does this URL respond with a 2xx? We still issue a GET
// (std.http.Client in 0.16 has no HEAD helper) but discard the body. Used
// by the branch-probing fallback so a 404 on `main` transparently retries
// on `master` without downloading multi-MB JSON twice.
pub fn headOk(io: std.Io, allocator: std.mem.Allocator, url_str: []const u8) bool {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url_str) catch return false;
    var sink: std.Io.Writer.Discarding = .init(&.{});

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &sink.writer,
    }) catch return false;

    return result.status == .ok;
}

pub fn fetchJson(io: std.Io, allocator: std.mem.Allocator, url_str: []const u8, comptime T: type) !std.json.Parsed(T) {
    const bytes = try fetchBytes(io, allocator, url_str);
    defer allocator.free(bytes);

    return std.json.parseFromSlice(T, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
}
