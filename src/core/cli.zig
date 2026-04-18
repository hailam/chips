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
        launch: bool = false,
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
    refresh: RefreshCommand,
    registries: struct {},
    init_manifest: struct {
        path: ?[]const u8,
    },
    validate_manifest: struct {
        path: ?[]const u8,
    },
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

pub const RefreshCommand = struct {
    registry_name: ?[]const u8 = null,
    db_only: bool = false,
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
        return .{ .get = try parseGetArgs(args[1..]) };
    }
    if (std.mem.eql(u8, args[0], "search")) {
        if (args.len < 2) return error.MissingOperand;
        return .{ .search = .{ .query = args[1] } };
    }
    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len != 1) return error.UnexpectedArgument;
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
        return .{ .refresh = try parseRefreshArgs(args[1..]) };
    }
    if (std.mem.eql(u8, args[0], "registries")) {
        if (args.len != 1) return error.UnexpectedArgument;
        return .{ .registries = .{} };
    }
    if (std.mem.eql(u8, args[0], "init")) {
        return .{ .init_manifest = .{ .path = if (args.len > 1) args[1] else null } };
    }
    if (std.mem.eql(u8, args[0], "validate")) {
        return .{ .validate_manifest = .{ .path = if (args.len > 1) args[1] else null } };
    }

    return .{ .run = try parseRunArgs(args) };
}

fn parseGetArgs(args: []const []const u8) ParseError!@FieldType(Command, "get") {
    var source: ?[]const u8 = null;
    var launch: bool = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--launch")) {
            launch = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnexpectedArgument;
        if (source != null) return error.UnexpectedArgument;
        source = arg;
    }
    return .{ .source = source orelse return error.MissingOperand, .launch = launch };
}

fn parseRefreshArgs(args: []const []const u8) ParseError!RefreshCommand {
    var cmd: RefreshCommand = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--db")) {
            cmd.db_only = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnexpectedArgument;
        } else {
            if (cmd.registry_name != null) return error.UnexpectedArgument;
            cmd.registry_name = arg;
        }
    }
    return cmd;
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
        \\  chip8 <rom.ch8> [--profile ...]
        \\  chip8 disasm <rom.ch8> [-o output.asm] [--profile ...]
        \\  chip8 asm <source.asm> [-o output.ch8]
        \\  chip8 check <source.asm>
        \\  chip8 get <source> [--launch]   # install ROM (and optionally launch it immediately)
        \\  chip8 search <query>            # offline search across known registries
        \\  chip8 list                      # list installed ROMs
        \\  chip8 remove <id>               # delete a ROM and its sidecar
        \\  chip8 update [<id>]             # re-fetch one or all installed ROMs
        \\  chip8 refresh [<registry>]      # resync registry state; `--db` refreshes chip-8-database cache
        \\  chip8 registries                # list configured known registries
        \\  chip8 init [path]               # scaffold a chip8.json in a directory
        \\  chip8 validate [path]           # validate a chip8.json against the spec
        \\
        \\Environment:
        \\  GITHUB_TOKEN  Optional. Lifts GitHub API rate limits (60/hr → 5000/hr).
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
