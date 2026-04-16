const std = @import("std");
const cpu = @import("cpu.zig");
const emulation = @import("emulation_config.zig");

pub const ROM_START: u16 = 0x200;

pub const Diagnostic = struct {
    line: usize,
    column: usize,
    message: []u8,
};

pub const RomAnalysis = struct {
    rom_end: u16,
    profile: emulation.QuirkProfile,
    label_targets: [cpu.CHIP8_MEMORY_SIZE]bool,

    pub fn hasLabel(self: *const RomAnalysis, addr: u16) bool {
        return addr < self.label_targets.len and self.label_targets[addr];
    }

    pub fn containsAddress(self: *const RomAnalysis, addr: u16) bool {
        return addr >= ROM_START and addr < self.rom_end;
    }
};

pub const UiCodeRow = struct {
    byte_len: u8,
    opcode_text: []const u8,
    asm_text: []const u8,
    comment_text: []const u8,
    is_db: bool,
};

pub const ExportMeta = struct {
    rom_name: []const u8,
    sha256_hex: []const u8,
    profile: emulation.QuirkProfile,
};

pub const ExportSourceResult = struct {
    source: []u8,
    line_for_addr: [cpu.CHIP8_MEMORY_SIZE]u32,

    pub fn deinit(self: *ExportSourceResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.* = undefined;
    }

    pub fn lineForAddress(self: *const ExportSourceResult, addr: u16) ?usize {
        if (addr >= self.line_for_addr.len) return null;
        const line = self.line_for_addr[addr];
        if (line == 0) return null;
        return line;
    }
};

pub const AssembleResult = struct {
    bytes: ?[]u8 = null,
    diagnostics: std.ArrayList(Diagnostic),

    pub fn init() AssembleResult {
        return .{
            .bytes = null,
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *AssembleResult, allocator: std.mem.Allocator) void {
        if (self.bytes) |bytes| allocator.free(bytes);
        for (self.diagnostics.items) |diag| allocator.free(diag.message);
        self.diagnostics.deinit(allocator);
        self.* = undefined;
    }

    pub fn succeeded(self: *const AssembleResult) bool {
        return self.bytes != null and self.diagnostics.items.len == 0;
    }
};

const ParsedLineKind = enum {
    instruction,
    db,
};

const ParsedLine = struct {
    line_no: usize,
    address: u16,
    text: []const u8,
    kind: ParsedLineKind,
};

const Operands = struct {
    items: [3][]const u8 = .{ "", "", "" },
    len: usize = 0,
};

const EncodedInstruction = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: usize = 2,
};

pub fn analyzeRom(rom_bytes: []const u8) RomAnalysis {
    return analyzeRomForProfile(.modern, rom_bytes);
}

pub fn analyzeRomForProfile(profile: emulation.QuirkProfile, rom_bytes: []const u8) RomAnalysis {
    var labels = [_]bool{false} ** cpu.CHIP8_MEMORY_SIZE;
    const rom_len = @min(rom_bytes.len, cpu.CHIP8_MEMORY_SIZE - @as(usize, ROM_START));
    const rom_end: u16 = @intCast(ROM_START + rom_len);

    var offset: usize = 0;
    var rom_memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    @memcpy(rom_memory[ROM_START .. ROM_START + rom_len], rom_bytes[0..rom_len]);
    while (offset + 1 < rom_len) {
        const addr: u16 = @intCast(ROM_START + offset);
        const decoded = cpu.DecodedInstruction.decodeForProfile(&rom_memory, addr, profile);
        switch (decoded.instruction) {
            .jmp => |target| {
                if (target >= ROM_START and target < rom_end) labels[target] = true;
            },
            .call => |target| {
                if (target >= ROM_START and target < rom_end) labels[target] = true;
            },
            else => {},
        }
        offset += decoded.byte_len;
    }

    return .{
        .rom_end = rom_end,
        .profile = profile,
        .label_targets = labels,
    };
}

pub fn inferProfile(rom_bytes: []const u8) emulation.QuirkProfile {
    const rom_len = @min(rom_bytes.len, cpu.CHIP8_MEMORY_SIZE - @as(usize, ROM_START));
    var rom_memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    @memcpy(rom_memory[ROM_START .. ROM_START + rom_len], rom_bytes[0..rom_len]);

    var saw_schip = false;
    var offset: usize = 0;
    while (offset + 1 < rom_len) {
        const addr: u16 = @intCast(ROM_START + offset);
        const raw_opcode = @as(u16, rom_memory[addr]) << 8 | @as(u16, rom_memory[addr + 1]);
        if (raw_opcode == 0xF000 and offset + 3 < rom_len) return .octo_xo;
        const decoded = cpu.DecodedInstruction.decode(&rom_memory, addr);
        switch (decoded.instruction) {
            .scu, .save_range, .load_range, .ld_i_long, .plane, .audio, .ld_pitch_vx => return .octo_xo,
            .scd, .scr, .scl, .exit, .low, .high, .ld_hf_vx, .ld_r_vx, .ld_vx_r => saw_schip = true,
            .drw => |s| {
                if (s.n == 0) saw_schip = true;
            },
            else => {},
        }
        offset += decoded.byte_len;
    }
    return if (saw_schip) .schip_11 else .modern;
}

pub fn labelName(addr: u16, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "loc_{X:0>4}", .{addr}) catch "";
}

pub fn formatUiCodeRow(
    memory: *const [cpu.CHIP8_MEMORY_SIZE]u8,
    analysis: *const RomAnalysis,
    addr: u16,
    opcode_buf: []u8,
    asm_buf: []u8,
    comment_buf: []u8,
) UiCodeRow {
    if (addr >= memory.len) {
        return .{
            .byte_len = 0,
            .opcode_text = opcode_buf[0..0],
            .asm_text = asm_buf[0..0],
            .comment_text = comment_buf[0..0],
            .is_db = false,
        };
    }

    if (addr + 1 >= memory.len or (analysis.containsAddress(addr) and addr + 1 >= analysis.rom_end)) {
        const byte = memory[addr];
        const opcode_text = std.fmt.bufPrint(opcode_buf, "{X:0>2}", .{byte}) catch "";
        const asm_text = std.fmt.bufPrint(asm_buf, "DB   0x{X:0>2}", .{byte}) catch "";
        const comment = std.fmt.bufPrint(comment_buf, "raw byte @0x{X:0>3}", .{addr}) catch "";
        return .{
            .byte_len = 1,
            .opcode_text = opcode_text,
            .asm_text = asm_text,
            .comment_text = comment,
            .is_db = true,
        };
    }

    const decoded = cpu.DecodedInstruction.decodeForProfile(memory, addr, analysis.profile);
    const inst = decoded.instruction;
    const opcode_text = if (decoded.byte_len == 4)
        std.fmt.bufPrint(opcode_buf, "{X:0>4} {X:0>4}", .{ decoded.opcode_hi, decoded.opcode_lo }) catch ""
    else
        std.fmt.bufPrint(opcode_buf, "{X:0>4}", .{decoded.opcode_hi}) catch "";
    const asm_text = formatAssemblySource(inst, analysis, asm_buf);

    if (std.meta.activeTag(inst) == .unknown) {
        const comment = std.fmt.bufPrint(comment_buf, "raw bytes @0x{X:0>3}", .{addr}) catch "";
        return .{
            .byte_len = decoded.byte_len,
            .opcode_text = opcode_text,
            .asm_text = if (decoded.byte_len == 4)
                std.fmt.bufPrint(asm_buf, "DB   0x{X:0>2}, 0x{X:0>2}, 0x{X:0>2}, 0x{X:0>2}", .{ memory[addr], memory[addr + 1], memory[addr + 2], memory[addr + 3] }) catch asm_text
            else
                std.fmt.bufPrint(asm_buf, "DB   0x{X:0>2}, 0x{X:0>2}", .{ memory[addr], memory[addr + 1] }) catch asm_text,
            .comment_text = comment,
            .is_db = true,
        };
    }

    const comment = formatPseudocode(inst, analysis, comment_buf);
    return .{
        .byte_len = decoded.byte_len,
        .opcode_text = opcode_text,
        .asm_text = asm_text,
        .comment_text = comment,
        .is_db = false,
    };
}

pub fn exportAnnotatedSource(
    allocator: std.mem.Allocator,
    meta: ExportMeta,
    rom_bytes: []const u8,
) !ExportSourceResult {
    const max_rom_len: usize = cpu.CHIP8_MEMORY_SIZE - @as(usize, ROM_START);
    const limited_rom = rom_bytes[0..@min(rom_bytes.len, max_rom_len)];
    const analysis = analyzeRomForProfile(meta.profile, limited_rom);
    var line_map = [_]u32{0} ** cpu.CHIP8_MEMORY_SIZE;
    var rom_memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    @memcpy(rom_memory[ROM_START .. ROM_START + limited_rom.len], limited_rom);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var line_no: u32 = 1;
    try appendLine(&writer.writer, &line_no, "; ROM: {s}\n", .{meta.rom_name});
    try appendLine(&writer.writer, &line_no, "; SHA256: {s}\n", .{meta.sha256_hex});
    try appendLine(&writer.writer, &line_no, "; Dialect: {s}\n", .{profileName(meta.profile)});
    try appendLine(&writer.writer, &line_no, "; CHIP-8 syntax: VX/VY registers, N nibble, KK byte, NNN address\n", .{});
    try appendLine(&writer.writer, &line_no, "; Assembly is authoritative; right-side comments are inferred pseudocode.\n", .{});
    try appendLine(&writer.writer, &line_no, "ORG 0x200\n", .{});
    try appendLine(&writer.writer, &line_no, "\n", .{});

    var offset: usize = 0;
    while (offset < limited_rom.len) {
        const addr: u16 = @intCast(ROM_START + offset);
        if (analysis.hasLabel(addr)) {
            var label_buf: [16]u8 = undefined;
            try appendLine(&writer.writer, &line_no, "{s}:\n", .{labelName(addr, &label_buf)});
        }

        line_map[addr] = line_no;

        var opcode_buf: [16]u8 = undefined;
        var asm_buf: [128]u8 = undefined;
        var comment_buf: [160]u8 = undefined;

        if (offset + 1 < limited_rom.len) {
            const row = formatUiCodeRow(&rom_memory, &analysis, addr, &opcode_buf, &asm_buf, &comment_buf);
            const padding: usize = if (row.asm_text.len < 22) 22 - row.asm_text.len else 1;
            try writer.writer.writeAll("    ");
            try writer.writer.writeAll(row.asm_text);
            try writer.writer.splatByteAll(' ', padding);
            try writer.writer.print("; @{X:0>4} {s}", .{ addr, row.opcode_text });
            if (row.comment_text.len > 0) {
                try writer.writer.print(" | {s}", .{row.comment_text});
            }
            try writer.writer.writeByte('\n');
            line_no += 1;

            offset += row.byte_len;
        } else {
            const asm_text = std.fmt.bufPrint(&asm_buf, "DB   0x{X:0>2}", .{limited_rom[offset]}) catch "";
            try writer.writer.print("    {s}              ; @{X:0>4} {X:0>2} | raw byte\n", .{ asm_text, addr, limited_rom[offset] });
            line_no += 1;
            offset += 1;
        }
    }

    return .{
        .source = try writer.toOwnedSlice(),
        .line_for_addr = line_map,
    };
}

pub fn assembleSource(allocator: std.mem.Allocator, source: []const u8) !AssembleResult {
    var result = AssembleResult.init();
    errdefer result.deinit(allocator);

    var labels = std.StringHashMap(u16).init(allocator);
    defer labels.deinit();
    var lines = std.ArrayList(ParsedLine).empty;
    defer lines.deinit(allocator);

    var current_addr: u16 = ROM_START;
    var saw_output = false;

    var line_it = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (line_it.next()) |raw_line| : (line_no += 1) {
        const no_comment = stripComment(raw_line);
        var line = trimAscii(no_comment);
        if (line.len == 0) continue;

        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const label_text = trimAscii(line[0..colon]);
            if (!isValidLabel(label_text)) {
                try addDiagnostic(&result.diagnostics, allocator, line_no, 1, "invalid label '{s}'", .{label_text});
            } else {
                const entry = try labels.getOrPut(label_text);
                if (entry.found_existing) {
                    try addDiagnostic(&result.diagnostics, allocator, line_no, 1, "duplicate label '{s}'", .{label_text});
                } else {
                    entry.key_ptr.* = try allocator.dupe(u8, label_text);
                    entry.value_ptr.* = current_addr;
                }
            }
            line = trimAscii(line[colon + 1 ..]);
            if (line.len == 0) continue;
        }

        const head = nextToken(line);
        if (asciiEq(head, "ORG")) {
            const origin_text = trimAscii(line[head.len..]);
            const origin = parseNumber(origin_text) orelse {
                try addDiagnostic(&result.diagnostics, allocator, line_no, head.len + 2, "invalid ORG address", .{});
                continue;
            };
            if (saw_output or current_addr != ROM_START or origin != ROM_START) {
                try addDiagnostic(&result.diagnostics, allocator, line_no, 1, "only ORG 0x200 is supported", .{});
            }
            current_addr = ROM_START;
            continue;
        }

        const kind: ParsedLineKind = if (asciiEq(head, "DB")) .db else .instruction;
        if (kind == .db) {
            const payload = trimAscii(line[head.len..]);
            const byte_count = countDbBytes(payload);
            if (byte_count == 0) {
                try addDiagnostic(&result.diagnostics, allocator, line_no, head.len + 1, "DB requires at least one byte literal", .{});
            } else {
                current_addr +%= @intCast(byte_count);
                saw_output = true;
            }
        } else {
            current_addr +%= estimateInstructionBytes(line);
            saw_output = true;
        }

        try lines.append(allocator, .{
            .line_no = line_no,
            .address = if (kind == .db) current_addr - @as(u16, @intCast(countDbBytes(trimAscii(line[head.len..])))) else current_addr - estimateInstructionBytes(line),
            .text = line,
            .kind = kind,
        });
    }

    defer {
        var it = labels.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    }

    var output = std.ArrayList(u8).empty;
    defer if (result.bytes == null) output.deinit(allocator);

    for (lines.items) |parsed| {
        switch (parsed.kind) {
            .db => try assembleDbLine(allocator, &result, &output, parsed),
            .instruction => try assembleInstructionLine(allocator, &result, &output, labels, parsed),
        }
    }

    if (result.diagnostics.items.len == 0) {
        result.bytes = try output.toOwnedSlice(allocator);
    }
    return result;
}

fn assembleDbLine(
    allocator: std.mem.Allocator,
    result: *AssembleResult,
    output: *std.ArrayList(u8),
    parsed: ParsedLine,
) !void {
    const head = nextToken(parsed.text);
    var values = std.mem.splitScalar(u8, trimAscii(parsed.text[head.len..]), ',');
    while (values.next()) |part| {
        const value_text = trimAscii(part);
        if (value_text.len == 0) {
            try addDiagnostic(&result.diagnostics, allocator, parsed.line_no, 1, "invalid DB byte", .{});
            continue;
        }
        const value = parseNumber(value_text) orelse {
            try addDiagnostic(&result.diagnostics, allocator, parsed.line_no, 1, "invalid DB byte '{s}'", .{value_text});
            continue;
        };
        if (value > 0xFF) {
            try addDiagnostic(&result.diagnostics, allocator, parsed.line_no, 1, "DB byte out of range '{s}'", .{value_text});
            continue;
        }
        try output.append(allocator, @intCast(value));
    }
}

fn assembleInstructionLine(
    allocator: std.mem.Allocator,
    result: *AssembleResult,
    output: *std.ArrayList(u8),
    labels: std.StringHashMap(u16),
    parsed: ParsedLine,
) !void {
    const encoded = assembleInstructionText(parsed.text, labels, parsed.line_no, allocator, &result.diagnostics) orelse return;
    try output.appendSlice(allocator, encoded.bytes[0..encoded.len]);
}

fn assembleInstructionText(
    text: []const u8,
    labels: std.StringHashMap(u16),
    line_no: usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) ?EncodedInstruction {
    const mnemonic = nextToken(text);
    const rest = trimAscii(text[mnemonic.len..]);

    if (asciiEq(mnemonic, "CLS")) {
        if (rest.len != 0) addSimpleDiag(allocator, diagnostics, line_no, "CLS takes no operands") catch {};
        return encodeWord(0x00E0);
    }
    if (asciiEq(mnemonic, "RET")) {
        if (rest.len != 0) addSimpleDiag(allocator, diagnostics, line_no, "RET takes no operands") catch {};
        return encodeWord(0x00EE);
    }
    if (asciiEq(mnemonic, "LOW")) {
        if (rest.len != 0) addSimpleDiag(allocator, diagnostics, line_no, "LOW takes no operands") catch {};
        return encodeWord(0x00FE);
    }
    if (asciiEq(mnemonic, "HIGH")) {
        if (rest.len != 0) addSimpleDiag(allocator, diagnostics, line_no, "HIGH takes no operands") catch {};
        return encodeWord(0x00FF);
    }
    if (asciiEq(mnemonic, "EXIT")) {
        if (rest.len != 0) addSimpleDiag(allocator, diagnostics, line_no, "EXIT takes no operands") catch {};
        return encodeWord(0x00FD);
    }
    if (asciiEq(mnemonic, "SCR")) {
        if (rest.len != 0) addSimpleDiag(allocator, diagnostics, line_no, "SCR takes no operands") catch {};
        return encodeWord(0x00FB);
    }
    if (asciiEq(mnemonic, "SCL")) {
        if (rest.len != 0) addSimpleDiag(allocator, diagnostics, line_no, "SCL takes no operands") catch {};
        return encodeWord(0x00FC);
    }
    if (asciiEq(mnemonic, "AUDIO")) {
        if (rest.len != 0) addSimpleDiag(allocator, diagnostics, line_no, "AUDIO takes no operands") catch {};
        return encodeWord(0xF002);
    }
    if (asciiEq(mnemonic, "SCD")) {
        const amount = parseNibbleOperand(rest, line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0x00C0 | amount);
    }
    if (asciiEq(mnemonic, "SCU")) {
        const amount = parseNibbleOperand(rest, line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0x00D0 | amount);
    }
    if (asciiEq(mnemonic, "PLANE")) {
        const mask = parseNibbleOperand(rest, line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0xF001 | (mask << 8));
    }
    if (asciiEq(mnemonic, "SAVE")) {
        const ops = splitOperands(rest);
        if (ops.len != 1) return invalidOperand(allocator, diagnostics, line_no, "SAVE expects Vx-Vy");
        const range = parseRegisterRange(ops.items[0], line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0x5002 | (@as(u16, range.vx) << 8) | (@as(u16, range.vy) << 4));
    }
    if (asciiEq(mnemonic, "LOAD")) {
        const ops = splitOperands(rest);
        if (ops.len != 1) return invalidOperand(allocator, diagnostics, line_no, "LOAD expects Vx-Vy");
        const range = parseRegisterRange(ops.items[0], line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0x5003 | (@as(u16, range.vx) << 8) | (@as(u16, range.vy) << 4));
    }
    if (asciiEq(mnemonic, "SYS")) {
        const addr = parseAddressOperand(rest, labels, line_no, allocator, diagnostics) orelse return null;
        return encodeWord(addr);
    }
    if (asciiEq(mnemonic, "JP")) {
        const ops = splitOperands(rest);
        if (ops.len == 1) {
            const addr = parseAddressOperand(ops.items[0], labels, line_no, allocator, diagnostics) orelse return null;
            return encodeWord(0x1000 | (addr & 0x0FFF));
        }
        if (ops.len == 2 and asciiEq(ops.items[0], "V0")) {
            const addr = parseAddressOperand(ops.items[1], labels, line_no, allocator, diagnostics) orelse return null;
            return encodeWord(0xB000 | (addr & 0x0FFF));
        }
        addSimpleDiag(allocator, diagnostics, line_no, "invalid JP operands") catch {};
        return null;
    }
    if (asciiEq(mnemonic, "CALL")) {
        const addr = parseAddressOperand(rest, labels, line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0x2000 | (addr & 0x0FFF));
    }
    if (asciiEq(mnemonic, "SE")) {
        const ops = splitOperands(rest);
        if (ops.len != 2) {
            addSimpleDiag(allocator, diagnostics, line_no, "SE expects two operands") catch {};
            return null;
        }
        const vx = parseRegister(ops.items[0]) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VX register");
        if (parseRegister(ops.items[1])) |vy| return encodeWord(0x5000 | (@as(u16, vx) << 8) | (@as(u16, vy) << 4));
        const byte = parseByteOperand(ops.items[1], line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0x3000 | (@as(u16, vx) << 8) | byte);
    }
    if (asciiEq(mnemonic, "SNE")) {
        const ops = splitOperands(rest);
        if (ops.len != 2) {
            addSimpleDiag(allocator, diagnostics, line_no, "SNE expects two operands") catch {};
            return null;
        }
        const vx = parseRegister(ops.items[0]) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VX register");
        if (parseRegister(ops.items[1])) |vy| return encodeWord(0x9000 | (@as(u16, vx) << 8) | (@as(u16, vy) << 4));
        const byte = parseByteOperand(ops.items[1], line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0x4000 | (@as(u16, vx) << 8) | byte);
    }
    if (asciiEq(mnemonic, "LD")) {
        return assembleLd(rest, labels, line_no, allocator, diagnostics);
    }
    if (asciiEq(mnemonic, "ADD")) {
        return assembleAdd(rest, labels, line_no, allocator, diagnostics);
    }
    if (asciiEq(mnemonic, "OR")) return assembleRegOp(rest, 0x8001, allocator, diagnostics, line_no);
    if (asciiEq(mnemonic, "AND")) return assembleRegOp(rest, 0x8002, allocator, diagnostics, line_no);
    if (asciiEq(mnemonic, "XOR")) return assembleRegOp(rest, 0x8003, allocator, diagnostics, line_no);
    if (asciiEq(mnemonic, "SUB")) return assembleRegOp(rest, 0x8005, allocator, diagnostics, line_no);
    if (asciiEq(mnemonic, "SUBN")) return assembleRegOp(rest, 0x8007, allocator, diagnostics, line_no);
    if (asciiEq(mnemonic, "SHR")) return assembleRegOp(rest, 0x8006, allocator, diagnostics, line_no);
    if (asciiEq(mnemonic, "SHL")) return assembleRegOp(rest, 0x800E, allocator, diagnostics, line_no);
    if (asciiEq(mnemonic, "RND")) {
        const ops = splitOperands(rest);
        if (ops.len != 2) return invalidOperand(allocator, diagnostics, line_no, "RND expects VX, byte");
        const vx = parseRegister(ops.items[0]) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VX register");
        const byte = parseByteOperand(ops.items[1], line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0xC000 | (@as(u16, vx) << 8) | byte);
    }
    if (asciiEq(mnemonic, "DRW")) {
        const ops = splitOperands(rest);
        if (ops.len != 3) return invalidOperand(allocator, diagnostics, line_no, "DRW expects VX, VY, nibble");
        const vx = parseRegister(ops.items[0]) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VX register");
        const vy = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VY register");
        const nibble = parseNibbleOperand(ops.items[2], line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0xD000 | (@as(u16, vx) << 8) | (@as(u16, vy) << 4) | nibble);
    }
    if (asciiEq(mnemonic, "SKP")) {
        const vx = parseRegister(rest) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VX register");
        return encodeWord(0xE09E | (@as(u16, vx) << 8));
    }
    if (asciiEq(mnemonic, "SKNP")) {
        const vx = parseRegister(rest) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VX register");
        return encodeWord(0xE0A1 | (@as(u16, vx) << 8));
    }

    addSimpleDiag(allocator, diagnostics, line_no, "unknown mnemonic") catch {};
    return null;
}

fn assembleLd(
    rest: []const u8,
    labels: std.StringHashMap(u16),
    line_no: usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) ?EncodedInstruction {
    const ops = splitOperands(rest);
    if (ops.len != 2) return invalidOperand(allocator, diagnostics, line_no, "LD expects two operands");

    if (parseRegister(ops.items[0])) |vx| {
        if (parseRegister(ops.items[1])) |vy| return encodeWord(0x8000 | (@as(u16, vx) << 8) | (@as(u16, vy) << 4));
        if (asciiEq(ops.items[1], "DT")) return encodeWord(0xF007 | (@as(u16, vx) << 8));
        if (asciiEq(ops.items[1], "K")) return encodeWord(0xF00A | (@as(u16, vx) << 8));
        if (asciiEq(ops.items[1], "[I]")) return encodeWord(0xF065 | (@as(u16, vx) << 8));
        if (asciiEq(ops.items[1], "R")) return encodeWord(0xF085 | (@as(u16, vx) << 8));
        const byte = parseByteOperand(ops.items[1], line_no, allocator, diagnostics) orelse return null;
        return encodeWord(0x6000 | (@as(u16, vx) << 8) | byte);
    }

    if (asciiEq(ops.items[0], "I")) {
        const addr = parseWideAddressOperand(ops.items[1], labels, line_no, allocator, diagnostics) orelse return null;
        return if (addr > 0x0FFF) encodeLongI(addr) else encodeWord(0xA000 | (addr & 0x0FFF));
    }
    if (asciiEq(ops.items[0], "DT")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "LD DT expects VX");
        return encodeWord(0xF015 | (@as(u16, vx) << 8));
    }
    if (asciiEq(ops.items[0], "ST")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "LD ST expects VX");
        return encodeWord(0xF018 | (@as(u16, vx) << 8));
    }
    if (asciiEq(ops.items[0], "F")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "LD F expects VX");
        return encodeWord(0xF029 | (@as(u16, vx) << 8));
    }
    if (asciiEq(ops.items[0], "HF")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "LD HF expects VX");
        return encodeWord(0xF030 | (@as(u16, vx) << 8));
    }
    if (asciiEq(ops.items[0], "B")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "LD B expects VX");
        return encodeWord(0xF033 | (@as(u16, vx) << 8));
    }
    if (asciiEq(ops.items[0], "[I]")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "LD [I] expects VX");
        return encodeWord(0xF055 | (@as(u16, vx) << 8));
    }
    if (asciiEq(ops.items[0], "R")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "LD R expects VX");
        return encodeWord(0xF075 | (@as(u16, vx) << 8));
    }
    if (asciiEq(ops.items[0], "PITCH")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "LD PITCH expects VX");
        return encodeWord(0xF03A | (@as(u16, vx) << 8));
    }

    return invalidOperand(allocator, diagnostics, line_no, "invalid LD operands");
}

fn assembleAdd(
    rest: []const u8,
    labels: std.StringHashMap(u16),
    line_no: usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) ?EncodedInstruction {
    _ = labels;
    const ops = splitOperands(rest);
    if (ops.len != 2) return invalidOperand(allocator, diagnostics, line_no, "ADD expects two operands");

    if (asciiEq(ops.items[0], "I")) {
        const vx = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "ADD I expects VX");
        return encodeWord(0xF01E | (@as(u16, vx) << 8));
    }

    const vx = parseRegister(ops.items[0]) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VX register");
    if (parseRegister(ops.items[1])) |vy| return encodeWord(0x8004 | (@as(u16, vx) << 8) | (@as(u16, vy) << 4));
    const byte = parseByteOperand(ops.items[1], line_no, allocator, diagnostics) orelse return null;
    return encodeWord(0x7000 | (@as(u16, vx) << 8) | byte);
}

fn assembleRegOp(
    rest: []const u8,
    base: u16,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    line_no: usize,
) ?EncodedInstruction {
    const ops = splitOperands(rest);
    if (ops.len != 2) return invalidOperand(allocator, diagnostics, line_no, "instruction expects VX, VY");
    const vx = parseRegister(ops.items[0]) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VX register");
    const vy = parseRegister(ops.items[1]) orelse return invalidOperand(allocator, diagnostics, line_no, "invalid VY register");
    return encodeWord(base | (@as(u16, vx) << 8) | (@as(u16, vy) << 4));
}

fn parseAddressOperand(
    operand: []const u8,
    labels: std.StringHashMap(u16),
    line_no: usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) ?u16 {
    const token = trimAscii(operand);
    if (parseNumber(token)) |value| {
        if (value > 0x0FFF) {
            addSimpleDiag(allocator, diagnostics, line_no, "address out of range") catch {};
            return null;
        }
        return @intCast(value);
    }
    if (labels.get(token)) |addr| return addr;
    addSimpleDiag(allocator, diagnostics, line_no, "undefined label") catch {};
    return null;
}

fn parseByteOperand(
    operand: []const u8,
    line_no: usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) ?u16 {
    const value = parseNumber(trimAscii(operand)) orelse {
        addSimpleDiag(allocator, diagnostics, line_no, "invalid byte literal") catch {};
        return null;
    };
    if (value > 0xFF) {
        addSimpleDiag(allocator, diagnostics, line_no, "byte literal out of range") catch {};
        return null;
    }
    return value;
}

fn parseNibbleOperand(
    operand: []const u8,
    line_no: usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) ?u16 {
    const value = parseNumber(trimAscii(operand)) orelse {
        addSimpleDiag(allocator, diagnostics, line_no, "invalid nibble literal") catch {};
        return null;
    };
    if (value > 0xF) {
        addSimpleDiag(allocator, diagnostics, line_no, "nibble literal out of range") catch {};
        return null;
    }
    return value;
}

fn invalidOperand(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    line_no: usize,
    message: []const u8,
) ?EncodedInstruction {
    addSimpleDiag(allocator, diagnostics, line_no, message) catch {};
    return null;
}

fn encodeWord(opcode: u16) EncodedInstruction {
    return .{
        .bytes = .{ @truncate(opcode >> 8), @truncate(opcode), 0, 0 },
        .len = 2,
    };
}

fn encodeLongI(addr: u16) EncodedInstruction {
    return .{
        .bytes = .{ 0xF0, 0x00, @truncate(addr >> 8), @truncate(addr) },
        .len = 4,
    };
}

fn estimateInstructionBytes(text: []const u8) u16 {
    const mnemonic = nextToken(text);
    if (!asciiEq(mnemonic, "LD")) return 2;
    const ops = splitOperands(trimAscii(text[mnemonic.len..]));
    if (ops.len != 2 or !asciiEq(ops.items[0], "I")) return 2;
    const value = parseNumber(ops.items[1]) orelse return 2;
    return if (value > 0x0FFF) 4 else 2;
}

fn parseWideAddressOperand(
    operand: []const u8,
    labels: std.StringHashMap(u16),
    line_no: usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) ?u16 {
    const token = trimAscii(operand);
    if (parseNumber(token)) |value| {
        if (value > 0xFFFF) {
            addSimpleDiag(allocator, diagnostics, line_no, "address out of range") catch {};
            return null;
        }
        return @intCast(value);
    }
    if (labels.get(token)) |addr| return addr;
    addSimpleDiag(allocator, diagnostics, line_no, "undefined label") catch {};
    return null;
}

fn parseRegisterRange(
    text: []const u8,
    line_no: usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) ?struct { vx: u4, vy: u4 } {
    const token = trimAscii(text);
    const dash = std.mem.indexOfScalar(u8, token, '-') orelse {
        addSimpleDiag(allocator, diagnostics, line_no, "expected Vx-Vy register range") catch {};
        return null;
    };
    const start = parseRegister(token[0..dash]) orelse {
        addSimpleDiag(allocator, diagnostics, line_no, "expected Vx-Vy register range") catch {};
        return null;
    };
    const end = parseRegister(token[dash + 1 ..]) orelse {
        addSimpleDiag(allocator, diagnostics, line_no, "expected Vx-Vy register range") catch {};
        return null;
    };
    return .{ .vx = start, .vy = end };
}

fn countDbBytes(text: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        if (trimAscii(part).len > 0) count += 1;
    }
    return count;
}

fn appendLine(writer: *std.Io.Writer, line_no: *u32, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt, args);
    line_no.* += @intFromBool(fmt.len > 0 and fmt[fmt.len - 1] == '\n');
}

fn addDiagnostic(
    diagnostics: *std.ArrayList(Diagnostic),
    allocator: std.mem.Allocator,
    line: usize,
    column: usize,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try diagnostics.append(allocator, .{
        .line = line,
        .column = column,
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    });
}

fn addSimpleDiag(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    line: usize,
    message: []const u8,
) !void {
    try addDiagnostic(diagnostics, allocator, line, 1, "{s}", .{message});
}

fn stripComment(line: []const u8) []const u8 {
    return line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len];
}

fn trimAscii(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}

fn nextToken(text: []const u8) []const u8 {
    const trimmed = trimAscii(text);
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

fn asciiEq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn splitOperands(rest: []const u8) Operands {
    var out = Operands{};
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |part| {
        if (out.len >= out.items.len) break;
        const trimmed = trimAscii(part);
        if (trimmed.len == 0) continue;
        out.items[out.len] = trimmed;
        out.len += 1;
    }
    return out;
}

fn parseRegister(text: []const u8) ?u4 {
    const token = trimAscii(text);
    if (token.len != 2) return null;
    if (std.ascii.toUpper(token[0]) != 'V') return null;
    return parseNibbleChar(token[1]);
}

fn parseNibbleChar(ch: u8) ?u4 {
    return switch (std.ascii.toUpper(ch)) {
        '0'...'9' => @intCast(ch - '0'),
        'A'...'F' => @intCast(10 + std.ascii.toUpper(ch) - 'A'),
        else => null,
    };
}

fn parseNumber(text: []const u8) ?u16 {
    const trimmed = trimAscii(text);
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        return std.fmt.parseInt(u16, trimmed[2..], 16) catch null;
    }
    return std.fmt.parseInt(u16, trimmed, 10) catch null;
}

fn isValidLabel(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!isLabelStart(text[0])) return false;
    for (text[1..]) |ch| {
        if (!isLabelContinue(ch)) return false;
    }
    return true;
}

fn isLabelStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isLabelContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn formatAssemblySource(inst: cpu.Instruction, analysis: *const RomAnalysis, buf: []u8) []const u8 {
    return switch (inst) {
        .cls => copyText(buf, "CLS"),
        .ret => copyText(buf, "RET"),
        .sys => |target| std.fmt.bufPrint(buf, "SYS  0x{X:0>3}", .{target}) catch "",
        .jmp => |target| formatJumpLike(buf, "JP", target, analysis),
        .call => |target| formatJumpLike(buf, "CALL", target, analysis),
        .se_byte => |s| std.fmt.bufPrint(buf, "SE   V{X}, 0x{X:0>2}", .{ s.vx, s.byte }) catch "",
        .sne_byte => |s| std.fmt.bufPrint(buf, "SNE  V{X}, 0x{X:0>2}", .{ s.vx, s.byte }) catch "",
        .se_reg => |s| std.fmt.bufPrint(buf, "SE   V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .ld_byte => |s| std.fmt.bufPrint(buf, "LD   V{X}, 0x{X:0>2}", .{ s.vx, s.byte }) catch "",
        .add_byte => |s| std.fmt.bufPrint(buf, "ADD  V{X}, 0x{X:0>2}", .{ s.vx, s.byte }) catch "",
        .ld_reg => |s| std.fmt.bufPrint(buf, "LD   V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .or_reg => |s| std.fmt.bufPrint(buf, "OR   V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .and_reg => |s| std.fmt.bufPrint(buf, "AND  V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .xor_reg => |s| std.fmt.bufPrint(buf, "XOR  V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .add_reg => |s| std.fmt.bufPrint(buf, "ADD  V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .sub_reg => |s| std.fmt.bufPrint(buf, "SUB  V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .shr => |s| std.fmt.bufPrint(buf, "SHR  V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .subn_reg => |s| std.fmt.bufPrint(buf, "SUBN V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .shl => |s| std.fmt.bufPrint(buf, "SHL  V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .sne_reg => |s| std.fmt.bufPrint(buf, "SNE  V{X}, V{X}", .{ s.vx, s.vy }) catch "",
        .ld_i => |target| formatLoadI(buf, target, analysis),
        .jmp_v0 => |target| std.fmt.bufPrint(buf, "JP   V0, 0x{X:0>3}", .{target}) catch "",
        .rnd => |s| std.fmt.bufPrint(buf, "RND  V{X}, 0x{X:0>2}", .{ s.vx, s.byte }) catch "",
        .drw => |s| std.fmt.bufPrint(buf, "DRW  V{X}, V{X}, {d}", .{ s.vx, s.vy, s.n }) catch "",
        .skp => |vx| std.fmt.bufPrint(buf, "SKP  V{X}", .{vx}) catch "",
        .sknp => |vx| std.fmt.bufPrint(buf, "SKNP V{X}", .{vx}) catch "",
        .ld_vx_dt => |vx| std.fmt.bufPrint(buf, "LD   V{X}, DT", .{vx}) catch "",
        .ld_vx_k => |vx| std.fmt.bufPrint(buf, "LD   V{X}, K", .{vx}) catch "",
        .ld_dt_vx => |vx| std.fmt.bufPrint(buf, "LD   DT, V{X}", .{vx}) catch "",
        .ld_st_vx => |vx| std.fmt.bufPrint(buf, "LD   ST, V{X}", .{vx}) catch "",
        .add_i_vx => |vx| std.fmt.bufPrint(buf, "ADD  I, V{X}", .{vx}) catch "",
        .ld_f_vx => |vx| std.fmt.bufPrint(buf, "LD   F, V{X}", .{vx}) catch "",
        .ld_b_vx => |vx| std.fmt.bufPrint(buf, "LD   B, V{X}", .{vx}) catch "",
        .ld_i_vx => |vx| std.fmt.bufPrint(buf, "LD   [I], V{X}", .{vx}) catch "",
        .ld_vx_i => |vx| std.fmt.bufPrint(buf, "LD   V{X}, [I]", .{vx}) catch "",
        .unknown => |opcode| std.fmt.bufPrint(buf, "DB   0x{X:0>2}, 0x{X:0>2}", .{ @as(u8, @truncate(opcode >> 8)), @as(u8, @truncate(opcode)) }) catch "",
        else => inst.format(buf),
    };
}

fn formatPseudocode(inst: cpu.Instruction, analysis: *const RomAnalysis, buf: []u8) []const u8 {
    return switch (inst) {
        .cls => copyText(buf, "clear display"),
        .ret => copyText(buf, "return from subroutine"),
        .sys => |target| std.fmt.bufPrint(buf, "system call 0x{X:0>3}", .{target}) catch "",
        .jmp => |target| formatGotoComment(buf, target, analysis),
        .call => |target| formatCallComment(buf, target, analysis),
        .se_byte => |s| std.fmt.bufPrint(buf, "if v{X} == 0x{X:0>2} skip next", .{ s.vx, s.byte }) catch "",
        .sne_byte => |s| std.fmt.bufPrint(buf, "if v{X} != 0x{X:0>2} skip next", .{ s.vx, s.byte }) catch "",
        .se_reg => |s| std.fmt.bufPrint(buf, "if v{X} == v{X} skip next", .{ s.vx, s.vy }) catch "",
        .ld_byte => |s| std.fmt.bufPrint(buf, "v{X} = 0x{X:0>2}", .{ s.vx, s.byte }) catch "",
        .add_byte => |s| std.fmt.bufPrint(buf, "v{X} += 0x{X:0>2}", .{ s.vx, s.byte }) catch "",
        .ld_reg => |s| std.fmt.bufPrint(buf, "v{X} = v{X}", .{ s.vx, s.vy }) catch "",
        .or_reg => |s| std.fmt.bufPrint(buf, "v{X} |= v{X}", .{ s.vx, s.vy }) catch "",
        .and_reg => |s| std.fmt.bufPrint(buf, "v{X} &= v{X}", .{ s.vx, s.vy }) catch "",
        .xor_reg => |s| std.fmt.bufPrint(buf, "v{X} ^= v{X}", .{ s.vx, s.vy }) catch "",
        .add_reg => |s| std.fmt.bufPrint(buf, "v{X} += v{X}", .{ s.vx, s.vy }) catch "",
        .sub_reg => |s| std.fmt.bufPrint(buf, "v{X} -= v{X}", .{ s.vx, s.vy }) catch "",
        .shr => |s| std.fmt.bufPrint(buf, "v{X} >>= 1 (uses v{X})", .{ s.vx, s.vy }) catch "",
        .subn_reg => |s| std.fmt.bufPrint(buf, "v{X} = v{X} - v{X}", .{ s.vx, s.vy, s.vx }) catch "",
        .shl => |s| std.fmt.bufPrint(buf, "v{X} <<= 1 (uses v{X})", .{ s.vx, s.vy }) catch "",
        .sne_reg => |s| std.fmt.bufPrint(buf, "if v{X} != v{X} skip next", .{ s.vx, s.vy }) catch "",
        .ld_i => |target| blk: {
            var target_buf: [16]u8 = undefined;
            break :blk std.fmt.bufPrint(buf, "I = {s}", .{targetLabelOrHex(target, analysis, &target_buf)}) catch "";
        },
        .jmp_v0 => |target| std.fmt.bufPrint(buf, "goto 0x{X:0>3} + v0", .{target}) catch "",
        .rnd => |s| std.fmt.bufPrint(buf, "v{X} = rand() & 0x{X:0>2}", .{ s.vx, s.byte }) catch "",
        .drw => |s| std.fmt.bufPrint(buf, "draw {d}-byte sprite at (v{X}, v{X}) from I", .{ s.n, s.vx, s.vy }) catch "",
        .skp => |vx| std.fmt.bufPrint(buf, "if key(v{X}) pressed skip next", .{vx}) catch "",
        .sknp => |vx| std.fmt.bufPrint(buf, "if key(v{X}) not pressed skip next", .{vx}) catch "",
        .ld_vx_dt => |vx| std.fmt.bufPrint(buf, "v{X} = delay timer", .{vx}) catch "",
        .ld_vx_k => |vx| std.fmt.bufPrint(buf, "wait for key, store in v{X}", .{vx}) catch "",
        .ld_dt_vx => |vx| std.fmt.bufPrint(buf, "delay timer = v{X}", .{vx}) catch "",
        .ld_st_vx => |vx| std.fmt.bufPrint(buf, "sound timer = v{X}", .{vx}) catch "",
        .add_i_vx => |vx| std.fmt.bufPrint(buf, "I += v{X}", .{vx}) catch "",
        .ld_f_vx => |vx| std.fmt.bufPrint(buf, "I = font(v{X})", .{vx}) catch "",
        .ld_b_vx => |vx| std.fmt.bufPrint(buf, "store BCD(v{X}) at I..I+2", .{vx}) catch "",
        .ld_i_vx => |vx| std.fmt.bufPrint(buf, "store v0..v{X} at I", .{vx}) catch "",
        .ld_vx_i => |vx| std.fmt.bufPrint(buf, "load v0..v{X} from I", .{vx}) catch "",
        .unknown => copyText(buf, "raw bytes"),
        else => inst.format(buf),
    };
}

fn formatJumpLike(buf: []u8, mnemonic: []const u8, target: u16, analysis: *const RomAnalysis) []const u8 {
    var label_buf: [16]u8 = undefined;
    if (analysis.hasLabel(target)) {
        return std.fmt.bufPrint(buf, "{s:<4} {s}", .{ mnemonic, labelName(target, &label_buf) }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s:<4} 0x{X:0>3}", .{ mnemonic, target }) catch "";
}

fn formatLoadI(buf: []u8, target: u16, analysis: *const RomAnalysis) []const u8 {
    var label_buf: [16]u8 = undefined;
    if (analysis.hasLabel(target)) {
        return std.fmt.bufPrint(buf, "LD   I, {s}", .{labelName(target, &label_buf)}) catch "";
    }
    return std.fmt.bufPrint(buf, "LD   I, 0x{X:0>3}", .{target}) catch "";
}

fn formatGotoComment(buf: []u8, target: u16, analysis: *const RomAnalysis) []const u8 {
    var label_buf: [16]u8 = undefined;
    if (analysis.hasLabel(target)) {
        return std.fmt.bufPrint(buf, "goto {s}", .{labelName(target, &label_buf)}) catch "";
    }
    return std.fmt.bufPrint(buf, "goto 0x{X:0>3}", .{target}) catch "";
}

fn formatCallComment(buf: []u8, target: u16, analysis: *const RomAnalysis) []const u8 {
    var label_buf: [16]u8 = undefined;
    if (analysis.hasLabel(target)) {
        return std.fmt.bufPrint(buf, "call {s}", .{labelName(target, &label_buf)}) catch "";
    }
    return std.fmt.bufPrint(buf, "call 0x{X:0>3}", .{target}) catch "";
}

fn targetLabelOrHex(target: u16, analysis: *const RomAnalysis, scratch: []u8) []const u8 {
    if (analysis.hasLabel(target)) {
        return labelName(target, scratch);
    }
    return std.fmt.bufPrint(scratch, "0x{X:0>3}", .{target}) catch "";
}

fn copyText(buf: []u8, text: []const u8) []const u8 {
    const len = @min(buf.len, text.len);
    @memcpy(buf[0..len], text[0..len]);
    return buf[0..len];
}

fn profileName(profile: emulation.QuirkProfile) []const u8 {
    return switch (profile) {
        .modern => "modern",
        .vip_legacy => "vip_legacy",
        .schip_11 => "schip_11",
        .xo_chip => "xo_chip",
        .octo_xo => "octo_xo",
    };
}
