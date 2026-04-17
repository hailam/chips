const std = @import("std");
const models = @import("registry_models.zig");
const chip8_db_cache = @import("chip8_db_cache.zig");

pub const ValidationError = struct {
    field_path: []const u8,
    message: []const u8,

    pub fn deinit(self: ValidationError, allocator: std.mem.Allocator) void {
        allocator.free(self.field_path);
        allocator.free(self.message);
    }
};

pub const ValidationResult = union(enum) {
    ok: models.Manifest,
    errors: []ValidationError,

    pub fn deinit(self: ValidationResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |m| m.deinit(allocator),
            .errors => |errs| {
                for (errs) |e| e.deinit(allocator);
                allocator.free(errs);
            },
        }
    }
};

pub fn validateManifest(allocator: std.mem.Allocator, json_bytes: []const u8) !ValidationResult {
    var errors: std.ArrayList(ValidationError) = .empty;
    errdefer {
        for (errors.items) |e| e.deinit(allocator);
        errors.deinit(allocator);
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch |err| {
        try errors.append(allocator, try mkError(allocator, "$", "JSON parse failed: {s}", .{@errorName(err)}));
        return .{ .errors = try errors.toOwnedSlice(allocator) };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try errors.append(allocator, try mkError(allocator, "$", "root must be an object", .{}));
        return .{ .errors = try errors.toOwnedSlice(allocator) };
    }

    const root = parsed.value.object;

    // spec_version
    const sv = root.get("spec_version") orelse {
        try errors.append(allocator, try mkError(allocator, "$.spec_version", "missing required field", .{}));
        return .{ .errors = try errors.toOwnedSlice(allocator) };
    };
    if (sv != .integer or sv.integer != models.SPEC_VERSION) {
        try errors.append(allocator, try mkError(allocator, "$.spec_version", "must be integer {d}", .{models.SPEC_VERSION}));
    }

    // roms
    const roms_val = root.get("roms") orelse {
        try errors.append(allocator, try mkError(allocator, "$.roms", "missing required field", .{}));
        return .{ .errors = try errors.toOwnedSlice(allocator) };
    };
    if (roms_val != .array) {
        try errors.append(allocator, try mkError(allocator, "$.roms", "must be array", .{}));
        return .{ .errors = try errors.toOwnedSlice(allocator) };
    }

    // Validate every rom entry's required fields.
    for (roms_val.array.items, 0..) |rom_val, i| {
        if (rom_val != .object) {
            try errors.append(allocator, try mkError(allocator, "$.roms[_]", "roms[{d}] must be object", .{i}));
            continue;
        }
        const obj = rom_val.object;
        const id = obj.get("id");
        if (id == null or id.? != .string or id.?.string.len == 0) {
            try errors.append(allocator, try mkError(allocator, "$.roms[_].id", "roms[{d}].id missing or not a non-empty string", .{i}));
        }
        const file = obj.get("file");
        if (file == null or file.? != .string or file.?.string.len == 0) {
            try errors.append(allocator, try mkError(allocator, "$.roms[_].file", "roms[{d}].file missing or not a non-empty string", .{i}));
        }
    }

    if (errors.items.len > 0) {
        return .{ .errors = try errors.toOwnedSlice(allocator) };
    }

    // Re-parse into typed Manifest now that we know shape is valid.
    const typed = try std.json.parseFromSlice(models.Manifest, allocator, json_bytes, .{ .ignore_unknown_fields = true });
    defer typed.deinit();

    var roms = try allocator.alloc(models.RomMetadata, typed.value.roms.len);
    var r_pop: usize = 0;
    errdefer {
        for (roms[0..r_pop]) |r| r.deinit(allocator);
        allocator.free(roms);
    }
    for (typed.value.roms, 0..) |r, i| {
        roms[i] = try r.clone(allocator);
        r_pop = i + 1;
    }

    return .{ .ok = .{ .spec_version = typed.value.spec_version, .roms = roms } };
}

pub fn scaffoldManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    db_cache: *const chip8_db_cache.State,
) !models.Manifest {
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);

    var roms: std.ArrayList(models.RomMetadata) = .empty;
    errdefer {
        for (roms.items) |r| r.deinit(allocator);
        roms.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ch8") and !std.mem.endsWith(u8, entry.name, ".rom")) continue;

        const data = try dir.readFileAlloc(io, entry.name, allocator, .limited(1 * 1024 * 1024));
        defer allocator.free(data);

        const sha1_bin = models.computeRomSha1(data);
        const sha1_hex = try models.sha1HexAlloc(allocator, sha1_bin);
        errdefer allocator.free(sha1_hex);

        const id_slice = std.fs.path.stem(entry.name);
        const id = try allocator.dupe(u8, id_slice);
        errdefer allocator.free(id);
        const file = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(file);

        var chip8_db_entry: ?models.Chip8DbEntry = null;
        if (db_cache.lookup(sha1_hex)) |e| {
            chip8_db_entry = try e.clone(allocator);
        }

        try roms.append(allocator, .{
            .id = id,
            .file = file,
            .sha1 = sha1_hex,
            .chip8_db_entry = chip8_db_entry,
        });
    }

    return .{
        .spec_version = models.SPEC_VERSION,
        .roms = try roms.toOwnedSlice(allocator),
    };
}

fn mkError(allocator: std.mem.Allocator, field_path: []const u8, comptime fmt: []const u8, args: anytype) !ValidationError {
    return .{
        .field_path = try allocator.dupe(u8, field_path),
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    };
}

test "validate rejects missing spec_version" {
    const allocator = std.testing.allocator;
    const json = "{\"roms\":[]}";
    const result = try validateManifest(allocator, json);
    defer result.deinit(allocator);
    try std.testing.expect(result == .errors);
}

test "validate rejects missing required rom fields" {
    const allocator = std.testing.allocator;
    const json = "{\"spec_version\":1,\"roms\":[{}]}";
    const result = try validateManifest(allocator, json);
    defer result.deinit(allocator);
    try std.testing.expect(result == .errors);
}

test "validate accepts minimal manifest" {
    const allocator = std.testing.allocator;
    const json = "{\"spec_version\":1,\"roms\":[{\"id\":\"pong\",\"file\":\"pong.ch8\"}]}";
    const result = try validateManifest(allocator, json);
    defer result.deinit(allocator);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(usize, 1), result.ok.roms.len);
}
