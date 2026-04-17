const std = @import("std");

pub const ParseError = error{
    InvalidUrl,
    UnquotedGlob,
    OutOfMemory,
};

pub const SourceUrl = union(enum) {
    direct_url: []const u8,
    repo_file: RepoFile,
    repo_glob: RepoGlob,
    repo_dir: RepoDir,
    repo_root: RepoRoot,
    repo_id: RepoId,
    registry_shorthand: RegistryShorthand,
    local_file: []const u8,
    local_dir: []const u8,

    pub const RepoFile = struct { user: []const u8, repo: []const u8, branch: []const u8, path: []const u8 };
    pub const RepoGlob = struct { user: []const u8, repo: []const u8, branch: []const u8, path: []const u8, pattern: []const u8 };
    pub const RepoDir = struct { user: []const u8, repo: []const u8, branch: []const u8, path: []const u8 };
    pub const RepoRoot = struct { user: []const u8, repo: []const u8, branch: []const u8 };
    pub const RepoId = struct { user: []const u8, repo: []const u8, id: []const u8 };
    pub const RegistryShorthand = struct { name: []const u8, query: []const u8 };

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
            .repo_dir => |v| {
                allocator.free(v.user);
                allocator.free(v.repo);
                allocator.free(v.branch);
                allocator.free(v.path);
            },
            .repo_root => |v| {
                allocator.free(v.user);
                allocator.free(v.repo);
                allocator.free(v.branch);
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

// Precedence (first-match wins):
//   1. Literal unquoted glob "*.ch8" / "*.rom" (shell expansion failed)
//   2. Local absolute/relative path prefixes: "/", "./", "../"
//   3. http(s):// URL — github.com host is unpacked into repo_* variants
//   4. "github.com/..." shorthand
//   5. "registry-name:query" (colon not preceded by http scheme)
//   6. "user/repo/..." GitHub shorthand (contains a slash)
//   7. Trailing ".ch8"/".rom" without path prefix → local_file
//   8. Otherwise → InvalidUrl
pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!SourceUrl {
    if (input.len == 0) return error.InvalidUrl;

    // 1. Literal unquoted glob — the shell didn't expand it.
    if (std.mem.eql(u8, input, "*.ch8") or std.mem.eql(u8, input, "*.rom")) {
        return error.UnquotedGlob;
    }

    // 2. Explicit local path prefix.
    if (std.mem.startsWith(u8, input, "/") or std.mem.startsWith(u8, input, "./") or std.mem.startsWith(u8, input, "../")) {
        if (hasRomExt(input)) {
            return .{ .local_file = try allocator.dupe(u8, input) };
        }
        return .{ .local_dir = try allocator.dupe(u8, input) };
    }

    // 3. http(s):// URLs.
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://")) {
        if (std.mem.indexOf(u8, input, "github.com/")) |idx| {
            return parseGithubPath(allocator, input[idx + "github.com/".len ..]);
        }
        if (std.mem.indexOf(u8, input, "raw.githubusercontent.com/")) |idx| {
            // Treat raw GitHub URLs as direct URLs — caller downloads as-is.
            _ = idx;
            return .{ .direct_url = try allocator.dupe(u8, input) };
        }
        if (!hasRomExt(input)) return error.InvalidUrl;
        return .{ .direct_url = try allocator.dupe(u8, input) };
    }

    // 4. "github.com/..." literal.
    if (std.mem.startsWith(u8, input, "github.com/")) {
        return parseGithubPath(allocator, input["github.com/".len..]);
    }

    // 5. "registry:query" (no scheme, has colon, no slash before colon).
    if (std.mem.indexOfScalar(u8, input, ':')) |colon_idx| {
        const before = input[0..colon_idx];
        const after = input[colon_idx + 1 ..];
        const has_slash_before = std.mem.indexOfScalar(u8, before, '/') != null;
        if (!has_slash_before and before.len > 0 and after.len > 0) {
            return .{ .registry_shorthand = .{
                .name = try allocator.dupe(u8, before),
                .query = try allocator.dupe(u8, after),
            } };
        }
    }

    // 6. "user/repo..." shorthand.
    if (std.mem.indexOfScalar(u8, input, '/')) |slash_idx| {
        if (slash_idx > 0 and slash_idx < input.len - 1) {
            return parseGithubPath(allocator, input);
        }
    }

    // 7. Bare filename with ROM extension.
    if (hasRomExt(input)) {
        return .{ .local_file = try allocator.dupe(u8, input) };
    }

    return error.InvalidUrl;
}

fn parseGithubPath(allocator: std.mem.Allocator, input: []const u8) ParseError!SourceUrl {
    var trimmed = input;
    // Normalize trailing slash — we detect repo_dir from it below.
    const has_trailing_slash = trimmed.len > 0 and trimmed[trimmed.len - 1] == '/';
    if (has_trailing_slash) trimmed = trimmed[0 .. trimmed.len - 1];

    var it = std.mem.tokenizeScalar(u8, trimmed, '/');
    const user = it.next() orelse return error.InvalidUrl;
    const repo = it.next() orelse return error.InvalidUrl;

    var branch: []const u8 = "main";
    var path_parts: std.ArrayList([]const u8) = .empty;
    defer path_parts.deinit(allocator);

    if (it.next()) |n| {
        if (std.mem.eql(u8, n, "blob") or std.mem.eql(u8, n, "tree")) {
            branch = it.next() orelse "main";
            while (it.next()) |p| try path_parts.append(allocator, p);
        } else {
            try path_parts.append(allocator, n);
            while (it.next()) |p| try path_parts.append(allocator, p);
        }
    }

    if (path_parts.items.len == 0) {
        return .{ .repo_root = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .branch = try allocator.dupe(u8, branch),
        } };
    }

    const full_path = try std.mem.join(allocator, "/", path_parts.items);
    errdefer allocator.free(full_path);

    // Contains glob character → repo_glob.
    if (std.mem.indexOfScalar(u8, full_path, '*')) |_| {
        const pattern = std.fs.path.basename(full_path);
        const dir = std.fs.path.dirname(full_path) orelse "";
        const result = SourceUrl{ .repo_glob = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .branch = try allocator.dupe(u8, branch),
            .path = try allocator.dupe(u8, dir),
            .pattern = try allocator.dupe(u8, pattern),
        } };
        allocator.free(full_path);
        return result;
    }

    // ROM extension → specific file.
    if (hasRomExt(full_path)) {
        return .{ .repo_file = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .branch = try allocator.dupe(u8, branch),
            .path = full_path,
        } };
    }

    // Trailing slash or no extension → repo_dir (treated as <dir>/*.ch8).
    if (has_trailing_slash) {
        return .{ .repo_dir = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .branch = try allocator.dupe(u8, branch),
            .path = full_path,
        } };
    }

    // Single non-extension segment after user/repo → manifest id lookup.
    if (path_parts.items.len == 1) {
        const id = try allocator.dupe(u8, path_parts.items[0]);
        allocator.free(full_path);
        return .{ .repo_id = .{
            .user = try allocator.dupe(u8, user),
            .repo = try allocator.dupe(u8, repo),
            .id = id,
        } };
    }

    // Multi-segment no-extension path without trailing slash → treat as dir.
    return .{ .repo_dir = .{
        .user = try allocator.dupe(u8, user),
        .repo = try allocator.dupe(u8, repo),
        .branch = try allocator.dupe(u8, branch),
        .path = full_path,
    } };
}

fn hasRomExt(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ch8") or std.mem.endsWith(u8, path, ".rom");
}

pub fn resolveGithubRaw(allocator: std.mem.Allocator, user: []const u8, repo: []const u8, branch: []const u8, path: []const u8) ![]const u8 {
    const encoded = try percentEncodePath(allocator, path);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}", .{ user, repo, branch, encoded });
}

// Percent-encode characters that aren't safe in a URL path. Slashes are
// preserved because `path` is expected to contain directory separators.
fn percentEncodePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (path) |c| {
        if (isUnreservedPathChar(c)) {
            try out.append(allocator, c);
        } else {
            try out.print(allocator, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isUnreservedPathChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~' or c == '/';
}

// --- tests ---

test "parse direct url" {
    const allocator = std.testing.allocator;
    const url = "https://example.com/game.ch8";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .direct_url);
    try std.testing.expectEqualStrings(res.direct_url, url);
}

test "parse github file via blob" {
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

test "parse github file via shorthand" {
    const allocator = std.testing.allocator;
    const url = "user/repo/games/pong.ch8";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .repo_file);
    try std.testing.expectEqualStrings(res.repo_file.path, "games/pong.ch8");
}

test "parse github glob" {
    const allocator = std.testing.allocator;
    const url = "github.com/user/repo/games/*.ch8";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .repo_glob);
    try std.testing.expectEqualStrings(res.repo_glob.path, "games");
    try std.testing.expectEqualStrings(res.repo_glob.pattern, "*.ch8");
}

test "parse github dir with trailing slash" {
    const allocator = std.testing.allocator;
    const url = "github.com/user/repo/games/";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .repo_dir);
    try std.testing.expectEqualStrings(res.repo_dir.path, "games");
}

test "parse repo root" {
    const allocator = std.testing.allocator;
    const url = "user/repo";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .repo_root);
    try std.testing.expectEqualStrings(res.repo_root.user, "user");
    try std.testing.expectEqualStrings(res.repo_root.repo, "repo");
}

test "parse repo id lookup" {
    const allocator = std.testing.allocator;
    const url = "user/repo/pong";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .repo_id);
    try std.testing.expectEqualStrings(res.repo_id.id, "pong");
}

test "parse registry shorthand" {
    const allocator = std.testing.allocator;
    const url = "kripod:pong";
    const res = try parse(allocator, url);
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .registry_shorthand);
    try std.testing.expectEqualStrings(res.registry_shorthand.name, "kripod");
    try std.testing.expectEqualStrings(res.registry_shorthand.query, "pong");
}

test "parse unquoted glob error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnquotedGlob, parse(allocator, "*.ch8"));
    try std.testing.expectError(error.UnquotedGlob, parse(allocator, "*.rom"));
}

test "parse local absolute path" {
    const allocator = std.testing.allocator;
    const res = try parse(allocator, "/tmp/pong.ch8");
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .local_file);
}

test "parse local relative dir" {
    const allocator = std.testing.allocator;
    const res = try parse(allocator, "./examples/roms");
    defer res.deinit(allocator);
    try std.testing.expectEqual(std.meta.activeTag(res), .local_dir);
}

test "parse invalid empty" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUrl, parse(allocator, ""));
}
