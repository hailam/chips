const std = @import("std");

pub const Error = error{
    RateLimited,
    NotFound,
    NetworkUnavailable,
    RequestFailed,
    InvalidJson,
} || std.mem.Allocator.Error;

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

pub fn listContents(
    io: std.Io,
    allocator: std.mem.Allocator,
    user: []const u8,
    repo: []const u8,
    path: []const u8,
    github_token: ?[]const u8,
) Error![]ContentEntry {
    var url_writer: std.Io.Writer.Allocating = .init(allocator);
    defer url_writer.deinit();
    url_writer.writer.print("https://api.github.com/repos/{s}/{s}/contents/{s}", .{ user, repo, path }) catch return error.RequestFailed;

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url_writer.written()) catch return error.RequestFailed;

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    var auth_buf: [256]u8 = undefined;
    var extra_headers_buf: [1]std.http.Header = undefined;
    var extra_headers: []const std.http.Header = &.{};
    if (github_token) |tok| {
        const hdr_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{tok}) catch return error.RequestFailed;
        extra_headers_buf[0] = .{ .name = "Authorization", .value = hdr_value };
        extra_headers = extra_headers_buf[0..1];
    }

    const fetch_res = client.fetch(.{
        .location = .{ .uri = uri },
        .headers = .{ .user_agent = .{ .override = "chips-emulator" } },
        .extra_headers = extra_headers,
        .response_writer = &body_writer.writer,
    }) catch return error.NetworkUnavailable;

    if (fetch_res.status == .not_found) return error.NotFound;
    if (fetch_res.status == .too_many_requests or fetch_res.status == .forbidden) return error.RateLimited;
    if (fetch_res.status != .ok) return error.RequestFailed;

    const body = body_writer.written();

    const parsed = std.json.parseFromSlice([]ContentEntry, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    defer parsed.deinit();

    var result = try allocator.alloc(ContentEntry, parsed.value.len);
    var populated: usize = 0;
    errdefer {
        for (result[0..populated]) |e| freeEntry(allocator, e);
        allocator.free(result);
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
        populated = i + 1;
    }

    return result;
}

pub fn resolveToken(allocator: std.mem.Allocator, environ: std.process.Environ, config_token: ?[]const u8) !?[]const u8 {
    if (config_token) |tok| {
        if (tok.len > 0) return try allocator.dupe(u8, tok);
    }
    const env_tok = environ.getAlloc(allocator, "GITHUB_TOKEN") catch return null;
    if (env_tok.len == 0) {
        allocator.free(env_tok);
        return null;
    }
    return env_tok;
}

fn freeEntry(allocator: std.mem.Allocator, entry: ContentEntry) void {
    allocator.free(entry.name);
    allocator.free(entry.path);
    allocator.free(entry.sha);
    allocator.free(entry.url);
    allocator.free(entry.html_url);
    allocator.free(entry.git_url);
    if (entry.download_url) |du| allocator.free(du);
    allocator.free(entry.type);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []ContentEntry) void {
    for (entries) |entry| freeEntry(allocator, entry);
    allocator.free(entries);
}
