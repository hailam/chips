const std = @import("std");

// Thin atomic JSON helpers. Callers pass absolute paths under app_data_root.
// No TTL. No hidden caching semantics. state.zig and chip8_db_cache.zig own
// their own file shapes; this module is just safe read/write.

pub fn writeJsonAtomic(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    value: anytype,
) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer.writer);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = writer.written() });
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(tmp_path, cwd, path, io);
}

pub fn readJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    comptime T: type,
) !?std.json.Parsed(T) {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);

    // Must use .alloc_always so parsed string slices don't alias `data` — we
    // free `data` on return and the caller keeps the Parsed value.
    return try std.json.parseFromSlice(T, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
