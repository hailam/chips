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
    verify: VerifyCommand,
    help: struct {},
};

pub const VerifyCommand = union(enum) {
    // `chip8 verify tests <test-id> [<rom-path>] [--reference=<hex>]`
    // rom_path is optional: when omitted, the runner looks for an installed
    // copy from the Timendus test suite (installed via
    // `chip8 get timendus:<id>`).
    tests: struct {
        test_id: []const u8,
        rom_path: ?[]const u8 = null,
        reference_hash: ?[]const u8 = null,
    },
    // `chip8 verify axis <name> [<rom-path>] [--reference=<hex>] [--start=<hex>]`
    // rom_path is optional for axes with a synthetic-only mode (memory, sound).
    axis: struct {
        axis_name: []const u8,
        rom_path: ?[]const u8 = null,
        reference_hash: ?[]const u8 = null,
        start_address: ?u16 = null,
    },
    // `chip8 verify inference [--disagreements=<N>]` — grades inference
    // against chip-8-database using installed ROMs as the audit sample.
    inference: struct {
        max_disagreements: u32 = 10,
    },
    // `chip8 verify all` — runs spec-invariant axes + per-ROM memory axis
    // across every installed ROM, plus inference audit.
    all: struct {},
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
    if (std.mem.eql(u8, args[0], "verify")) {
        if (args.len < 2) return error.MissingOperand;
        return .{ .verify = try parseVerifyArgs(args[1..]) };
    }

    return .{ .run = try parseRunArgs(args) };
}

fn parseVerifyArgs(args: []const []const u8) ParseError!VerifyCommand {
    if (args.len < 1) return error.MissingOperand;
    const sub = args[0];
    // tests <test-id> [<rom-path>] [--reference=<hex>]
    if (std.mem.eql(u8, sub, "tests")) {
        if (args.len < 2) return error.MissingOperand;
        var rom_path: ?[]const u8 = null;
        var reference: ?[]const u8 = null;
        for (args[2..]) |a| {
            if (std.mem.startsWith(u8, a, "--reference=")) {
                reference = a["--reference=".len..];
            } else if (std.mem.startsWith(u8, a, "-")) {
                return error.UnexpectedArgument;
            } else {
                if (rom_path != null) return error.UnexpectedArgument;
                rom_path = a;
            }
        }
        return .{ .tests = .{ .test_id = args[1], .rom_path = rom_path, .reference_hash = reference } };
    }
    // axis <axis-name> [<rom-path>] [--reference=<hex>] [--start=<hex>]
    if (std.mem.eql(u8, sub, "axis")) {
        var rom_path: ?[]const u8 = null;
        var reference: ?[]const u8 = null;
        var start_address: ?u16 = null;
        for (args[2..]) |a| {
            if (std.mem.startsWith(u8, a, "--reference=")) {
                reference = a["--reference=".len..];
            } else if (std.mem.startsWith(u8, a, "--start=")) {
                const hex = a["--start=".len..];
                const stripped = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;
                start_address = std.fmt.parseInt(u16, stripped, 16) catch return error.InvalidCommand;
            } else if (std.mem.startsWith(u8, a, "-")) {
                return error.UnexpectedArgument;
            } else {
                if (rom_path != null) return error.UnexpectedArgument;
                rom_path = a;
            }
        }
        return .{ .axis = .{ .axis_name = args[1], .rom_path = rom_path, .reference_hash = reference, .start_address = start_address } };
    }
    if (std.mem.eql(u8, sub, "all")) {
        if (args.len > 1) return error.UnexpectedArgument;
        return .{ .all = .{} };
    }
    if (std.mem.eql(u8, sub, "inference")) {
        var max_disagreements: u32 = 10;
        for (args[1..]) |a| {
            if (std.mem.startsWith(u8, a, "--disagreements=")) {
                const v = a["--disagreements=".len..];
                max_disagreements = std.fmt.parseInt(u32, v, 10) catch return error.InvalidCommand;
            } else return error.UnexpectedArgument;
        }
        return .{ .inference = .{ .max_disagreements = max_disagreements } };
    }
    return error.InvalidCommand;
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
        \\  chip8 verify tests <id> [<rom>] [--reference=<hex>]
        \\                                  # run a Timendus test ROM headlessly; installs are auto-resolved
        \\  chip8 verify axis <name> [<rom>] [--reference=<hex>] [--start=<hex>]
        \\                                  # run a single correctness axis (opcodes, memory, sound)
        \\  chip8 verify inference [--disagreements=<N>]
        \\                                  # grade the inference engine against chip-8-database
        \\  chip8 verify all                # run every fixture-free axis + inference audit
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
