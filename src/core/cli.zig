const std = @import("std");
const emulation = @import("emulation_config.zig");

pub const Command = union(enum) {
    run: RunCommand,
    disasm: DisasmCommand,
    assemble: struct {
        source_path: []const u8,
        output_path: ?[]const u8,
    },
    check: struct {
        source_path: []const u8,
    },
    get: struct {
        source: []const u8,
    },
    search: struct {
        query: []const u8,
    },
    list: struct {},
    remove: struct {
        id: []const u8,
    },
    update: struct {
        id: ?[]const u8,
    },
    refresh: struct {},
    registries: struct {},
    sync: struct {},
    help: struct {},
};

pub const RunCommand = struct {
    rom_path: ?[]const u8,
    profile: ?emulation.QuirkProfile,
};

pub const DisasmCommand = struct {
    rom_path: []const u8,
    output_path: ?[]const u8,
    profile: ?emulation.QuirkProfile,
};

pub const ParseError = error{
    MissingOperand,
    UnexpectedArgument,
    InvalidCommand,
    InvalidProfile,
};

pub fn parseArgs(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .{ .run = .{ .rom_path = null, .profile = null } };

    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        return .{ .help = .{} };
    }
    if (std.mem.eql(u8, args[0], "run")) {
        return .{ .run = try parseRunArgs(args[1..]) };
    }
    if (std.mem.eql(u8, args[0], "disasm")) {
        if (args.len < 2) return error.MissingOperand;
        return .{ .disasm = try parseDisasmArgs(args[1..]) };
    }
    if (std.mem.eql(u8, args[0], "asm")) {
        if (args.len < 2) return error.MissingOperand;
        return .{ .assemble = .{
            .source_path = args[1],
            .output_path = try parseOptionalOutput(args[2..]),
        } };
    }
    if (std.mem.eql(u8, args[0], "check")) {
        if (args.len != 2) return if (args.len < 2) error.MissingOperand else error.UnexpectedArgument;
        return .{ .check = .{ .source_path = args[1] } };
    }
    if (std.mem.eql(u8, args[0], "get")) {
        if (args.len < 2) return error.MissingOperand;
        return .{ .get = .{ .source = args[1] } };
    }
    if (std.mem.eql(u8, args[0], "search")) {
        if (args.len < 2) return error.MissingOperand;
        return .{ .search = .{ .query = args[1] } };
    }
    if (std.mem.eql(u8, args[0], "list")) {
        return .{ .list = .{} };
    }
    if (std.mem.eql(u8, args[0], "remove")) {
        if (args.len < 2) return error.MissingOperand;
        return .{ .remove = .{ .id = args[1] } };
    }
    if (std.mem.eql(u8, args[0], "update")) {
        return .{ .update = .{ .id = if (args.len > 1) args[1] else null } };
    }
    if (std.mem.eql(u8, args[0], "refresh")) {
        return .{ .refresh = .{} };
    }
    if (std.mem.eql(u8, args[0], "registries")) {
        return .{ .registries = .{} };
    }
    if (std.mem.eql(u8, args[0], "sync")) {
        return .{ .sync = .{} };
    }

    return .{ .run = try parseRunArgs(args) };
}

pub fn defaultAsmOutputPathAlloc(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(source_path);
    const stem = if (std.mem.endsWith(u8, base, ".asm")) base[0 .. base.len - 4] else std.fs.path.stem(base);
    const dir = std.fs.path.dirname(source_path) orelse ".";
    if (std.mem.endsWith(u8, stem, ".ch8")) {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, stem });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}.ch8", .{ dir, stem });
}

pub fn buildEditorGotoTargetAlloc(allocator: std.mem.Allocator, path: []const u8, line: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ path, line });
}

pub fn usage() []const u8 {
    return
        \\Usage:
        \\  chip8 run [rom.ch8] [--profile modern|vip_legacy|schip_11|xo_chip|octo_xo]
        \\  chip8 <rom.ch8> [--profile modern|vip_legacy|schip_11|xo_chip|octo_xo]
        \\  chip8 disasm <rom.ch8> [-o output.asm] [--profile modern|vip_legacy|schip_11|xo_chip|octo_xo]
        \\  chip8 asm <source.asm> [-o output.ch8]
        \\  chip8 check <source.asm>
        \\  chip8 get <source>
        \\  chip8 search <query>
        \\  chip8 list
        \\  chip8 remove <id>
        \\  chip8 update [<id>]
        \\  chip8 refresh
        \\  chip8 registries
        \\  chip8 sync
    ;
}

fn parseOptionalOutput(args: []const []const u8) ParseError!?[]const u8 {
    if (args.len == 0) return null;
    if (args.len == 2 and std.mem.eql(u8, args[0], "-o")) return args[1];
    if (args.len == 1 and std.mem.eql(u8, args[0], "-o")) return error.MissingOperand;
    return error.UnexpectedArgument;
}

fn parseRunArgs(args: []const []const u8) ParseError!RunCommand {
    var rom_path: ?[]const u8 = null;
    var profile: ?emulation.QuirkProfile = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingOperand;
            profile = emulation.parseProfile(args[i]) orelse return error.InvalidProfile;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "-")) return error.UnexpectedArgument;
        if (rom_path != null) return error.UnexpectedArgument;
        rom_path = args[i];
    }
    return .{ .rom_path = rom_path, .profile = profile };
}

fn parseDisasmArgs(args: []const []const u8) ParseError!DisasmCommand {
    var rom_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var profile: ?emulation.QuirkProfile = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingOperand;
            output_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, args[i], "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingOperand;
            profile = emulation.parseProfile(args[i]) orelse return error.InvalidProfile;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "-")) return error.UnexpectedArgument;
        if (rom_path != null) return error.UnexpectedArgument;
        rom_path = args[i];
    }
    return .{
        .rom_path = rom_path orelse return error.MissingOperand,
        .output_path = output_path,
        .profile = profile,
    };
}
