const std = @import("std");

pub const SourceUrl = union(enum) {
    direct_url: []const u8,
    repo_file: struct { user: []const u8, repo: []const u8, branch: []const u8, path: []const u8 },
    repo_glob: struct { user: []const u8, repo: []const u8, branch: []const u8, path: []const u8, pattern: []const u8 },
    repo_root: struct { user: []const u8, repo: []const u8, branch: []const u8, path: []const u8 },
    repo_id: struct { user: []const u8, repo: []const u8, id: []const u8 },
    registry_shorthand: struct { name: []const u8, query: []const u8 },
    local_file: []const u8,
    local_dir: []const u8,

    pub fn deinit(self: SourceUrl, allocator: std.mem.Allocator) void {
        switch (self) {
            .direct_url => |v| allocator.free(v),
            .repo_file => |v| {
                allocator.free(v.user);
                allocator.free(v.repo);
                allocator.free(v.branch);
                allocator.free(v.path);
            },
            .repo_glob => |v| {
                allocator.free(v.user);
                allocator.free(v.repo);
                allocator.free(v.branch);
                allocator.free(v.path);
                allocator.free(v.pattern);
            },
            .repo_root => |v| {
                allocator.free(v.user);
                allocator.free(v.repo);
                allocator.free(v.branch);
                allocator.free(v.path);
            },
            .repo_id => |v| {
                allocator.free(v.user);
                allocator.free(v.repo);
                allocator.free(v.id);
            },
            .registry_shorthand => |v| {
                allocator.free(v.name);
                allocator.free(v.query);
            },
            .local_file => |v| allocator.free(v),
            .local_dir => |v| allocator.free(v),
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !SourceUrl {
    if (input.len == 0) return error.InvalidUrl;

    // Local file/dir paths or just files with extensions
    if (std.mem.startsWith(u8, input, "/") or std.mem.startsWith(u8, input, "./") or std.mem.startsWith(u8, input, "../") or std.mem.endsWith(u8, input, ".ch8") or std.mem.endsWith(u8, input, ".rom")) {
        if (std.mem.endsWith(u8, input, ".ch8") or std.mem.endsWith(u8, input, ".rom")) {
            return .{ .local_file = try allocator.dupe(u8, input) };
        } else {
            return .{ .local_dir = try allocator.dupe(u8, input) };
        }
    }

    // Direct HTTP(S) URL
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://")) {
        if (std.mem.indexOf(u8, input, "github.com")) |idx| {
            return try parseGithubUrl(allocator, input[idx..]);
        }
        return .{ .direct_url = try allocator.dupe(u8, input) };
    }

    // Registry shorthand registry-name:query
    if (std.mem.indexOfScalar(u8, input, ':')) |colon_idx| {
        if (colon_idx > 0 and colon_idx < input.len - 1) {
            return .{ .registry_shorthand = .{
                .name = try allocator.dupe(u8, input[0..colon_idx]),
                .query = try allocator.dupe(u8, input[colon_idx + 1 ..]),
            } };
        }
    }

    // GitHub shorthands user/repo...
    if (std.mem.startsWith(u8, input, "github.com/")) {
        return try parseGithubUrl(allocator, input["github.com/".len..]);
    }

    if (std.mem.indexOfScalar(u8, input, '/')) |slash_idx| {
        if (slash_idx > 0 and slash_idx < input.len - 1) {
            // Check if it's user/repo
            return try parseGithubUrl(allocator, input);
        }
    }

    // Fallback to local file if it exists or if it just looks like a filename
    if (std.mem.endsWith(u8, input, ".ch8") or std.mem.endsWith(u8, input, ".rom")) {
        return .{ .local_file = try allocator.dupe(u8, input) };
    }

    return error.InvalidUrl;
}

fn parseGithubUrl(allocator: std.mem.Allocator, input: []const u8) !SourceUrl {
    var it = std.mem.tokenizeScalar(u8, input, '/');
    var first = it.next() orelse return error.InvalidUrl;
    
    if (std.mem.eql(u8, first, "github.com")) {
        first = it.next() orelse return error.InvalidUrl;
    }
    
    const user = first;
    const repo = it.next() orelse return error.InvalidUrl;

    var branch: []const u8 = "main";
    var path_parts: std.ArrayList([]const u8) = .empty;
    defer path_parts.deinit(allocator);

    const next = it.next();
    if (next) |n| {
        if (std.mem.eql(u8, n, "blob") or std.mem.eql(u8, n, "tree")) {
            branch = it.next() orelse "main";
            while (it.next()) |p| {
                try path_parts.append(allocator, p);
            }
        } else {
            // Could be user/repo/id or user/repo/path...
            try path_parts.append(allocator, n);
            while (it.next()) |p| {
                try path_parts.append(allocator, p);
            }
        }
    }

    const full_path = try std.mem.join(allocator, "/", path_parts.items);
    errdefer allocator.free(full_path);

    if (full_path.len == 0) {
        return .{ .repo_root = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .branch = try allocator.dupe(u8, branch),
            .path = full_path,
        } };
    }

    if (std.mem.indexOfScalar(u8, full_path, '*')) |_| {
        return .{ .repo_glob = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .branch = try allocator.dupe(u8, branch),
            .path = try allocator.dupe(u8, std.fs.path.dirname(full_path) orelse ""),
            .pattern = try allocator.dupe(u8, std.fs.path.basename(full_path)),
        } };
    }

    if (std.mem.endsWith(u8, full_path, ".ch8") or std.mem.endsWith(u8, full_path, ".rom")) {
        return .{ .repo_file = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .branch = try allocator.dupe(u8, branch),
            .path = full_path,
        } };
    }

    // If it's just one part and not a known extension, it might be an ID
    if (path_parts.items.len == 1) {
        return .{ .repo_id = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .id = try allocator.dupe(u8, path_parts.items[0]),
        } };
    }

    return .{ .repo_root = .{
        .user = try allocator.dupe(u8, user),
        .repo = try allocator.dupe(u8, repo),
        .branch = try allocator.dupe(u8, branch),
        .path = full_path,
    } };
}

pub fn resolveGithubRaw(allocator: std.mem.Allocator, user: []const u8, repo: []const u8, branch: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}", .{ user, repo, branch, path });
}

test "parse direct url" {
    const allocator = std.testing.allocator;
    const url = "https://example.com/game.ch8";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .direct_url);
    try std.testing.expectEqualStrings(res.direct_url, url);
}

test "parse github file" {
    const allocator = std.testing.allocator;
    const url = "github.com/user/repo/blob/main/games/pong.ch8";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .repo_file);
    try std.testing.expectEqualStrings(res.repo_file.user, "user");
    try std.testing.expectEqualStrings(res.repo_file.repo, "repo");
    try std.testing.expectEqualStrings(res.repo_file.branch, "main");
    try std.testing.expectEqualStrings(res.repo_file.path, "games/pong.ch8");
}

test "parse github glob" {
    const allocator = std.testing.allocator;
    const url = "github.com/user/repo/games/*.ch8";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .repo_glob);
    try std.testing.expectEqualStrings(res.repo_glob.user, "user");
    try std.testing.expectEqualStrings(res.repo_glob.repo, "repo");
    try std.testing.expectEqualStrings(res.repo_glob.path, "games");
    try std.testing.expectEqualStrings(res.repo_glob.pattern, "*.ch8");
}

test "parse registry shorthand" {
    const allocator = std.testing.allocator;
    const url = "main:pong";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .registry_shorthand);
    try std.testing.expectEqualStrings(res.registry_shorthand.name, "main");
    try std.testing.expectEqualStrings(res.registry_shorthand.query, "pong");
}
