const std = @import("std");
const rl = @import("raylib");
const assembly = @import("assembly.zig");
const chip8_mod = @import("chip8.zig");
const cpu_mod = @import("cpu.zig");
const Instruction = cpu_mod.Instruction;
const control = @import("control_spec.zig");
const debugger_mod = @import("debugger.zig");
const emulation = @import("emulation_config.zig");
const layout = @import("display_layout.zig");
const models = @import("registry_models.zig");
const persistence = @import("persistence.zig");
const trace_mod = @import("trace.zig");
const ui_mod = @import("ui_state.zig");

pub const DEFAULT_WINDOW_WIDTH = layout.DEFAULT_WINDOW_WIDTH;
pub const DEFAULT_WINDOW_HEIGHT = layout.DEFAULT_WINDOW_HEIGHT;
pub const MIN_WINDOW_WIDTH = layout.MIN_WINDOW_WIDTH;
pub const MIN_WINDOW_HEIGHT = layout.MIN_WINDOW_HEIGHT;

pub const TEXT_DIM_PUB = TEXT_DIM;
pub const BG_WINDOW_PUB = rl.Color{ .r = 22, .g = 22, .b = 26, .a = 255 };

pub const EmulatorState = enum { running, paused, stepping };

const FG_GREEN = rl.Color{ .r = 0, .g = 230, .b = 65, .a = 255 };
const FG_AMBER = rl.Color{ .r = 255, .g = 176, .b = 0, .a = 255 };
const FG_BLUE = rl.Color{ .r = 100, .g = 140, .b = 255, .a = 255 };
const FG_CYAN = rl.Color{ .r = 0, .g = 210, .b = 210, .a = 255 };
const BG_PANEL = rl.Color{ .r = 30, .g = 32, .b = 36, .a = 255 };
const BG_HEADER = rl.Color{ .r = 38, .g = 40, .b = 46, .a = 255 };
const BG_DARK = rl.Color{ .r = 12, .g = 12, .b = 14, .a = 255 };
const BG_ROW_ALT = rl.Color{ .r = 34, .g = 36, .b = 40, .a = 255 };
const BG_KEY = rl.Color{ .r = 32, .g = 34, .b = 39, .a = 255 };
const TEXT_DIM = rl.Color{ .r = 100, .g = 105, .b = 115, .a = 255 };
const TEXT_MID = rl.Color{ .r = 160, .g = 165, .b = 175, .a = 255 };
const TEXT_BRIGHT = rl.Color{ .r = 220, .g = 225, .b = 235, .a = 255 };
const SEPARATOR = rl.Color{ .r = 55, .g = 58, .b = 65, .a = 255 };
const HIGHLIGHT_PC = rl.Color{ .r = 200, .g = 60, .b = 60, .a = 70 };
const HIGHLIGHT_I = rl.Color{ .r = 60, .g = 80, .b = 200, .a = 60 };
const HIGHLIGHT_CURRENT = rl.Color{ .r = 0, .g = 200, .b = 65, .a = 30 };
const REG_CHANGED = rl.Color{ .r = 0, .g = 200, .b = 80, .a = 255 };
const PIPE_BG = rl.Color{ .r = 40, .g = 42, .b = 48, .a = 255 };

const FONT_SPACING: f32 = 0.5;
const HEX_START_X: i32 = 46;
const HEX_BYTE_W: i32 = 28;
const HEX_GROUP_GAP: i32 = 10;
const KEYPAD_ROWS = [_][]const u8{ "123C", "456D", "789E", "A0BF" };
const DisplayFocus = struct {
    x: u8,
    y: u8,
    w: u8,
    h: u8,
    wraps: bool,
    full_screen: bool,
};

var font: rl.Font = undefined;
var font_loaded: bool = false;
var anim_tick: u32 = 0;

pub fn initFont() void {
    const font_data = @embedFile("FiraMono-Regular.ttf");
    font = rl.loadFontFromMemory(".ttf", font_data, 20, null) catch {
        font_loaded = false;
        return;
    };
    rl.setTextureFilter(font.texture, .bilinear);
    font_loaded = true;
}

pub fn deinitFont() void {
    if (font_loaded) rl.unloadFont(font);
}

pub fn renderAll(
    chip8: *const chip8_mod.Chip8,
    state: EmulatorState,
    debugger_state: *const debugger_mod.DebuggerState,
    ui_state: *const ui_mod.UiState,
    recent_roms: []const persistence.RecentRom,
    installed_roms: []const models.InstalledRom,
    settings: persistence.DisplaySettings,
    cpu_hz: i32,
    mem_scroll: *i32,
    disasm_scroll: *i32,
    muted: bool,
    rom_analysis: ?*const assembly.RomAnalysis,
    rom_name: ?[]const u8,
) void {
    anim_tick +%= 1;

    const cpu = &chip8.cpu;
    const memory = &chip8.memory;
    const ui = layout.computeLayout(rl.getScreenWidth(), rl.getScreenHeight());
    const mouse_x = rl.getMouseX();
    const mouse_y = rl.getMouseY();
    const wheel = rl.getMouseWheelMove();
    const overlay_open = std.meta.activeTag(ui_state.overlay) != .none;

    if (!overlay_open and state == .running) {
        disasm_scroll.* = 0;
    } else if (!overlay_open and wheel != 0 and pointInRect(mouse_x, mouse_y, ui.disassembler.body())) {
        disasm_scroll.* -= @intFromFloat(wheel * 2);
    }

    if (!overlay_open and wheel != 0 and pointInRect(mouse_x, mouse_y, ui.memory.body())) {
        mem_scroll.* -= @intFromFloat(wheel * 3);
    }

    mem_scroll.* = layout.clampMemoryScroll(mem_scroll.*, ui.memory_rows_visible);
    disasm_scroll.* = layout.clampDisasmScroll(disasm_scroll.*, cpu.program_counter, ui.disasm_rows_visible);

    const active_trace = debugger_state.activeTraceEntry();
    const show_trace_focus = active_trace != null and (state != .running or !debugger_state.trace_follow_live or debugger_state.selected_trace_index != null);

    renderDisplay(cpu, ui.display, ui.display_scale, settings, active_trace, show_trace_focus);
    renderRegisters(cpu, state, ui.registers, ui_state.last_latched_key, settings, active_trace, show_trace_focus);
    renderCodePanel(cpu, memory, debugger_state, ui.disassembler, ui.disasm_rows_visible, disasm_scroll.*, rom_analysis);
    renderMiddlePanel(cpu, memory, debugger_state, ui.gutter);
    renderMemoryView(cpu, memory, ui.memory, ui.memory_rows_visible, mem_scroll.*, active_trace, show_trace_focus);
    if (show_trace_focus) {
        if (active_trace) |entry| renderTraceConnector(entry, ui, mem_scroll.*);
    }
    renderFooter(ui.footer, ui.footer_two_rows, cpu_hz, cpu.sound_timer, muted, chip8.config.quirk_profile, ui_state.active_save_slot, settings.volume, ui_state.status(), rom_name);

    if (overlay_open) {
        renderOverlay(ui, ui_state, debugger_state, recent_roms, installed_roms);
    }
}

fn drawPanel(panel: layout.PanelRect, title: []const u8) void {
    rl.drawRectangle(panel.x, panel.y, panel.w, panel.h, BG_PANEL);
    rl.drawRectangle(panel.x, panel.y, panel.w, layout.HEADER_H, BG_HEADER);
    drawText(panel.x + 8, panel.y + 4, title, layout.FONT_SIZE, TEXT_MID);
    rl.drawLine(panel.x, panel.y + layout.HEADER_H, panel.x + panel.w, panel.y + layout.HEADER_H, SEPARATOR);
    const rect = rl.Rectangle{
        .x = @floatFromInt(panel.x),
        .y = @floatFromInt(panel.y),
        .width = @floatFromInt(panel.w),
        .height = @floatFromInt(panel.h),
    };
    rl.drawRectangleRoundedLines(rect, 0.015, 4, SEPARATOR);
}

fn drawText(x: i32, y: i32, text: []const u8, size: f32, color: rl.Color) void {
    var buf: [256]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];
    if (font_loaded) {
        rl.drawTextEx(font, z, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, size, FONT_SPACING, color);
    } else {
        rl.drawText(z, x, y, @intFromFloat(size), color);
    }
}

fn drawTextFit(x: i32, y: i32, max_w: i32, text: []const u8, size: f32, color: rl.Color) void {
    var buf: [256]u8 = undefined;
    const fitted = layout.fitText(text, max_w, size, &buf);
    drawText(x, y, fitted, size, color);
}

fn drawTextRightFit(right_x: i32, y: i32, max_w: i32, text: []const u8, size: f32, color: rl.Color) void {
    var buf: [256]u8 = undefined;
    const fitted = layout.fitText(text, max_w, size, &buf);
    const width = layout.measureMonoTextWidth(fitted, size);
    drawText(right_x - width, y, fitted, size, color);
}

fn beginPanelClip(panel: layout.PanelRect) void {
    const body = panel.body();
    if (body.w > 0 and body.h > 0) {
        rl.beginScissorMode(body.x, body.y, body.w, body.h);
    }
}

fn endPanelClip() void {
    rl.endScissorMode();
}

fn pointInRect(x: i32, y: i32, rect: layout.PanelRect) bool {
    return x >= rect.x and x < rect.right() and y >= rect.y and y < rect.bottom();
}

fn headerInfo(panel: layout.PanelRect, text: []const u8, color: rl.Color) void {
    drawTextRightFit(panel.x + panel.w - 8, panel.y + 4, @max(panel.w - 120, 60), text, layout.FONT_SIZE_SMALL, color);
}

fn divider(panel: layout.PanelRect, y: i32) void {
    rl.drawLine(panel.x + 8, y, panel.x + panel.w - 8, y, SEPARATOR);
}

fn blendColor(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * (1 - t) + @as(f32, @floatFromInt(b.r)) * t),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * (1 - t) + @as(f32, @floatFromInt(b.g)) * t),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * (1 - t) + @as(f32, @floatFromInt(b.b)) * t),
        .a = 255,
    };
}

fn withAlpha(color: rl.Color, alpha: u8) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha };
}

// Per-ROM color overrides pulled from chip-8-database `colors.pixels`.
// The display stores up to four plane-mask colors (CHIP-8 uses index 1
// only; XO-CHIP extends to 2 and 3 for 2-plane sprites). Any null index
// falls back to the palette-derived default so partial overrides stay
// consistent with the user's chrome palette.
var primary_color_override: ?rl.Color = null;
var secondary_color_override: ?rl.Color = null;
var blended_color_override: ?rl.Color = null;
var background_color_override: ?rl.Color = null;
var screen_rotation_override: u16 = 0; // 0/90/180/270

pub fn setScreenRotation(degrees: u16) void {
    screen_rotation_override = switch (degrees) {
        90, 180, 270 => degrees,
        else => 0,
    };
}

pub fn clearScreenRotation() void {
    screen_rotation_override = 0;
}

pub fn setPrimaryColorOverride(color: rl.Color) void {
    primary_color_override = color;
}

pub fn setSecondaryColorOverride(color: rl.Color) void {
    secondary_color_override = color;
}

pub fn setBlendedColorOverride(color: rl.Color) void {
    blended_color_override = color;
}

pub fn setBackgroundColorOverride(color: rl.Color) void {
    background_color_override = color;
}

pub fn clearPrimaryColorOverride() void {
    primary_color_override = null;
    secondary_color_override = null;
    blended_color_override = null;
    background_color_override = null;
}

fn primaryAccent(settings: persistence.DisplaySettings) rl.Color {
    if (primary_color_override) |c| return c;
    return switch (settings.palette) {
        .classic_green => FG_GREEN,
        .amber => FG_AMBER,
        .ice => rl.Color{ .r = 140, .g = 220, .b = 255, .a = 255 },
        .gray => rl.Color{ .r = 210, .g = 215, .b = 220, .a = 255 },
    };
}

// Parse a `#RRGGBB` hex color string into rl.Color. Returns null for
// anything that doesn't fit the shape — callers fall back to the palette.
pub fn parseHexColor(s: []const u8) ?rl.Color {
    if (s.len != 7 or s[0] != '#') return null;
    const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

test "parseHexColor handles well-formed input" {
    const c = parseHexColor("#1a2b3c").?;
    try std.testing.expectEqual(@as(u8, 0x1a), c.r);
    try std.testing.expectEqual(@as(u8, 0x2b), c.g);
    try std.testing.expectEqual(@as(u8, 0x3c), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);
}

test "parseHexColor rejects malformed input" {
    try std.testing.expect(parseHexColor("") == null);
    try std.testing.expect(parseHexColor("1a2b3c") == null);
    try std.testing.expect(parseHexColor("#GGHHII") == null);
    try std.testing.expect(parseHexColor("#123") == null);
}

fn accentHighlight(settings: persistence.DisplaySettings) rl.Color {
    return withAlpha(primaryAccent(settings), 40);
}

fn traceTagColor(tag: debugger_mod.TraceTag) rl.Color {
    return switch (tag) {
        .key => FG_CYAN,
        .draw => FG_BLUE,
        .store, .call, .ret => FG_AMBER,
        .load, .alu, .skip, .jump, .timer, .fetch, .misc => FG_GREEN,
    };
}

fn traceTagLabel(tag: debugger_mod.TraceTag) []const u8 {
    return switch (tag) {
        .alu => "ALU",
        .load => "LOAD",
        .store => "STORE",
        .key => "KEY",
        .draw => "DRAW",
        .call => "CALL",
        .ret => "RET",
        .jump => "JUMP",
        .skip => "SKIP",
        .timer => "TIMER",
        .fetch => "FETCH",
        .misc => "MISC",
    };
}

fn traceRowsVisible(panel: layout.PanelRect) usize {
    return @intCast(@max(@divTrunc(panel.body().h - 6, layout.LINE_H_SMALL), 1));
}

fn drawTraceHeader(panel: layout.PanelRect, debugger_state: *const debugger_mod.DebuggerState) void {
    const status = if (debugger_state.trace_follow_live) "LIVE FOLLOW" else "MANUAL";
    headerInfo(panel, status, if (debugger_state.trace_follow_live) FG_GREEN else FG_AMBER);
}

fn formatTraceSummary(entry: debugger_mod.TraceEntry, buf: []u8) []const u8 {
    var src_buf: [48]u8 = undefined;
    var dst_buf: [48]u8 = undefined;
    const src = endpointDetailLabel(entry.source, &src_buf);
    const dst = endpointDetailLabel(entry.destination, &dst_buf);
    const inst = traceInstruction(entry);
    return switch (entry.tag) {
        .key => if (entry.waits_for_key)
            std.fmt.bufPrint(buf, "{s} -> {s} (waiting)", .{ src, dst }) catch ""
        else
            std.fmt.bufPrint(buf, "{s} -> {s}", .{ src, dst }) catch "",
        .draw => std.fmt.bufPrint(buf, "{s} -> {s}", .{ src, dst }) catch "",
        .load => std.fmt.bufPrint(buf, "{s} -> {s}", .{ src, dst }) catch "",
        .store => std.fmt.bufPrint(buf, "{s} -> {s}", .{ src, dst }) catch "",
        .call => if (traceBranchTarget(entry)) |target|
            std.fmt.bufPrint(buf, "PC -> stack, jump {X:0>3}", .{target}) catch ""
        else
            std.fmt.bufPrint(buf, "PC -> stack", .{}) catch "",
        .ret => copyInto(buf, "stack -> PC"),
        .jump => if (traceBranchTarget(entry)) |target|
            std.fmt.bufPrint(buf, "jump -> {X:0>3}", .{target}) catch ""
        else
            copyInto(buf, "branch"),
        .skip => inst.format(buf),
        .timer => std.fmt.bufPrint(buf, "{s} -> {s}", .{ src, dst }) catch "",
        .alu => inst.format(buf),
        .fetch => formatTraceOpcodeText(entry, buf),
        .misc => inst.format(buf),
    };
}

fn traceInstruction(entry: debugger_mod.TraceEntry) Instruction {
    return if (entry.byte_len == 4)
        .{ .ld_i_long = entry.opcode_lo }
    else
        Instruction.decode(entry.opcode_hi);
}

fn formatTraceOpcodeText(entry: debugger_mod.TraceEntry, buf: []u8) []const u8 {
    return if (entry.byte_len == 4)
        std.fmt.bufPrint(buf, "{X:0>4} {X:0>4}", .{ entry.opcode_hi, entry.opcode_lo }) catch ""
    else
        std.fmt.bufPrint(buf, "{X:0>4}", .{entry.opcode_hi}) catch "";
}

fn formatTraceBadges(entry: debugger_mod.TraceEntry, buf: []u8) []const u8 {
    var src_buf: [16]u8 = undefined;
    var dst_buf: [16]u8 = undefined;
    const src = endpointBadgeLabel(entry.source, &src_buf);
    const dst = endpointBadgeLabel(entry.destination, &dst_buf);
    if (src.len == 0 and dst.len == 0) return buf[0..0];
    return std.fmt.bufPrint(buf, "{s} -> {s}", .{ src, dst }) catch "";
}

fn endpointDetailLabel(endpoint: debugger_mod.TraceEndpoint, buf: []u8) []const u8 {
    return switch (endpoint) {
        .none => "-",
        .pc => "PC",
        .memory => |mem| if (mem.len <= 1)
            std.fmt.bufPrint(buf, "RAM[{X:0>3}]", .{mem.addr}) catch ""
        else
            std.fmt.bufPrint(buf, "RAM[{X:0>3}..{X:0>3}]", .{ mem.addr, mem.addr + mem.len - 1 }) catch "",
        .decode => "decode",
        .index => "I",
        .registers => |regs| if (regs.len <= 1)
            std.fmt.bufPrint(buf, "V{X}", .{regs.start}) catch ""
        else
            std.fmt.bufPrint(buf, "V{X}..V{X}", .{ regs.start, @as(u16, regs.start) + regs.len - 1 }) catch "",
        .stack => "stack",
        .display => "display",
        .keypad => |keypad| if (keypad.key != trace_mod.NO_KEY_INDEX)
            std.fmt.bufPrint(buf, "key {X}", .{keypad.key}) catch ""
        else
            "keypad",
        .timers => |timers| if (timers.delay and timers.sound)
            "timers"
        else if (timers.delay)
            "DT"
        else if (timers.sound)
            "ST"
        else
            "timer",
    };
}

fn endpointBadgeLabel(endpoint: debugger_mod.TraceEndpoint, buf: []u8) []const u8 {
    _ = buf;
    return switch (endpoint) {
        .none => "",
        .pc => "PC",
        .memory => "MEM",
        .decode => "DEC",
        .index, .registers => "REG",
        .stack => "STACK",
        .display => "DSP",
        .keypad => "KEY",
        .timers => "TIM",
    };
}

fn traceBranchTarget(entry: debugger_mod.TraceEntry) ?u16 {
    for (entry.micro_ops[0..entry.micro_op_len]) |micro_op| {
        if (micro_op.kind != .branch_pc) continue;
        switch (micro_op.destination) {
            .pc => |pc| return pc,
            else => {},
        }
    }
    return null;
}

fn microOpLabel(kind: debugger_mod.MicroOpKind) []const u8 {
    return switch (kind) {
        .fetch_opcode => "FETCH",
        .decode_opcode => "DECODE",
        .read_mem_range => "READ MEM",
        .write_mem_range => "WRITE MEM",
        .read_reg => "READ REG",
        .write_reg => "WRITE REG",
        .read_keypad => "READ KEY",
        .write_timer => "WRITE TIM",
        .read_timer => "READ TIM",
        .push_stack => "PUSH",
        .pop_stack => "POP",
        .branch_pc => "BRANCH",
        .draw_sprite => "DRAW",
        .wait_key => "WAIT KEY",
    };
}

fn laneCenterX(lane_area_x: i32, lane_w: i32, lane: trace_mod.Lane) i32 {
    return lane_area_x + @as(i32, @intFromEnum(lane)) * lane_w + @divTrunc(lane_w, 2);
}

fn drawArrowHead(x: i32, y: i32, direction: i32, color: rl.Color) void {
    rl.drawLine(x, y, x - 4 * direction, y - 3, color);
    rl.drawLine(x, y, x - 4 * direction, y + 3, color);
}

fn copyInto(buf: []u8, text: []const u8) []const u8 {
    const len = @min(buf.len, text.len);
    @memcpy(buf[0..len], text[0..len]);
    return buf[0..len];
}

fn collectTraceEndpoints(entry: debugger_mod.TraceEntry, buf: *[trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint) []const debugger_mod.TraceEndpoint {
    var len: usize = 0;
    buf[len] = entry.source;
    len += 1;
    buf[len] = entry.destination;
    len += 1;
    for (entry.micro_ops[0..entry.micro_op_len]) |micro_op| {
        buf[len] = micro_op.source;
        len += 1;
        buf[len] = micro_op.destination;
        len += 1;
    }
    return buf[0..len];
}

fn traceTouchesRegister(entry: debugger_mod.TraceEntry, reg_index: usize) bool {
    var endpoints_buf: [trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint = undefined;
    for (collectTraceEndpoints(entry, &endpoints_buf)) |endpoint| {
        switch (endpoint) {
            .registers => |regs| {
                const start: usize = regs.start;
                const end = start + regs.len;
                if (reg_index >= start and reg_index < end) return true;
            },
            else => {},
        }
    }
    return false;
}

fn traceTouchesProgramCounter(entry: debugger_mod.TraceEntry) bool {
    var endpoints_buf: [trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint = undefined;
    for (collectTraceEndpoints(entry, &endpoints_buf)) |endpoint| {
        switch (endpoint) {
            .pc => return true,
            else => {},
        }
    }
    return false;
}

fn traceTouchesIndex(entry: debugger_mod.TraceEntry) bool {
    var endpoints_buf: [trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint = undefined;
    for (collectTraceEndpoints(entry, &endpoints_buf)) |endpoint| {
        switch (endpoint) {
            .index => return true,
            else => {},
        }
    }
    return false;
}

fn traceTouchesTimers(entry: debugger_mod.TraceEntry) bool {
    var endpoints_buf: [trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint = undefined;
    for (collectTraceEndpoints(entry, &endpoints_buf)) |endpoint| {
        switch (endpoint) {
            .timers => return true,
            else => {},
        }
    }
    return false;
}

fn traceTouchesStack(entry: debugger_mod.TraceEntry) bool {
    var endpoints_buf: [trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint = undefined;
    for (collectTraceEndpoints(entry, &endpoints_buf)) |endpoint| {
        switch (endpoint) {
            .stack => return true,
            else => {},
        }
    }
    return false;
}

fn traceKeyFocus(entry: debugger_mod.TraceEntry) ?usize {
    var endpoints_buf: [trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint = undefined;
    for (collectTraceEndpoints(entry, &endpoints_buf)) |endpoint| {
        switch (endpoint) {
            .keypad => |keypad| {
                if (keypad.key != trace_mod.NO_KEY_INDEX) return keypad.key;
            },
            else => {},
        }
    }
    return null;
}

fn traceMemoryContains(entry: debugger_mod.TraceEntry, addr: u16) bool {
    var endpoints_buf: [trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint = undefined;
    for (collectTraceEndpoints(entry, &endpoints_buf)) |endpoint| {
        switch (endpoint) {
            .memory => |mem| {
                if (addr >= mem.addr and addr < mem.addr + mem.len) return true;
            },
            else => {},
        }
    }
    return false;
}

fn traceDisplayFocus(entry: debugger_mod.TraceEntry) ?DisplayFocus {
    var endpoints_buf: [trace_mod.MAX_MICRO_OPS * 2 + 2]debugger_mod.TraceEndpoint = undefined;
    for (collectTraceEndpoints(entry, &endpoints_buf)) |endpoint| {
        switch (endpoint) {
            .display => |display_focus| return .{
                .x = display_focus.x,
                .y = display_focus.y,
                .w = display_focus.w,
                .h = display_focus.h,
                .wraps = display_focus.wraps,
                .full_screen = display_focus.full_screen,
            },
            else => {},
        }
    }
    return null;
}

fn displayCellWidth(panel: layout.PanelRect, mode: cpu_mod.DisplayMode) f32 {
    const logical_w_i32: i32 = if (mode == .hires) cpu_mod.DISPLAY_HIRES_WIDTH else cpu_mod.DISPLAY_WIDTH;
    const logical_w: f32 = @floatFromInt(logical_w_i32);
    return @as(f32, @floatFromInt(panel.w)) / logical_w;
}

fn displayCellHeight(panel: layout.PanelRect, mode: cpu_mod.DisplayMode) f32 {
    const logical_h_i32: i32 = if (mode == .hires) cpu_mod.DISPLAY_HIRES_HEIGHT else cpu_mod.DISPLAY_HEIGHT;
    const logical_h: f32 = @floatFromInt(logical_h_i32);
    return @as(f32, @floatFromInt(panel.h)) / logical_h;
}

fn drawDisplayFocus(panel: layout.PanelRect, cpu: *const cpu_mod.CPU, focus: DisplayFocus, color: rl.Color) void {
    if (focus.full_screen) {
        rl.drawRectangleLines(panel.x, panel.y, panel.w, panel.h, color);
        return;
    }

    var width = @as(i32, @max(focus.w, 1));
    var height = @as(i32, @max(focus.h, 1));
    const start_x = @as(i32, focus.x);
    const start_y = @as(i32, focus.y);
    const logical_w: i32 = @intCast(cpu.displayWidth());
    const logical_h: i32 = @intCast(cpu.displayHeight());

    if (!focus.wraps) {
        if (start_x >= logical_w or start_y >= logical_h) return;
        width = @min(width, logical_w - start_x);
        height = @min(height, logical_h - start_y);
    }

    drawDisplayFocusRect(panel, cpu.display_mode, start_x, start_y, width, height, color);

    if (!focus.wraps) return;

    const overflow_x = start_x + width - logical_w;
    const overflow_y = start_y + height - logical_h;

    if (overflow_x > 0) {
        drawDisplayFocusRect(panel, cpu.display_mode, 0, start_y, overflow_x, height, color);
    }
    if (overflow_y > 0) {
        drawDisplayFocusRect(panel, cpu.display_mode, start_x, 0, width, overflow_y, color);
    }
    if (overflow_x > 0 and overflow_y > 0) {
        drawDisplayFocusRect(panel, cpu.display_mode, 0, 0, overflow_x, overflow_y, color);
    }
}

fn drawDisplayFocusRect(panel: layout.PanelRect, mode: cpu_mod.DisplayMode, x: i32, y: i32, width: i32, height: i32, color: rl.Color) void {
    if (width <= 0 or height <= 0) return;
    const cell_w = displayCellWidth(panel, mode);
    const cell_h = displayCellHeight(panel, mode);
    const rect_x: i32 = @intFromFloat(@as(f32, @floatFromInt(panel.x)) + @as(f32, @floatFromInt(x)) * cell_w);
    const rect_y: i32 = @intFromFloat(@as(f32, @floatFromInt(panel.y)) + @as(f32, @floatFromInt(y)) * cell_h);
    const rect_w = @min(@as(i32, @intFromFloat(@as(f32, @floatFromInt(width)) * cell_w)), panel.right() - rect_x);
    const rect_h = @min(@as(i32, @intFromFloat(@as(f32, @floatFromInt(height)) * cell_h)), panel.bottom() - rect_y);
    if (rect_w <= 0 or rect_h <= 0) return;
    rl.drawRectangleLines(rect_x, rect_y, rect_w, rect_h, color);
}

const PanelAnchor = struct {
    panel: layout.PanelRect,
    y: i32,
};

fn renderTraceConnector(entry: debugger_mod.TraceEntry, ui: layout.LayoutMetrics, mem_scroll: i32) void {
    const source = endpointAnchor(entry.source, ui, mem_scroll) orelse return;
    const destination = endpointAnchor(entry.destination, ui, mem_scroll) orelse return;
    if (source.panel.x == destination.panel.x and source.panel.y == destination.panel.y and source.panel.w == destination.panel.w and source.panel.h == destination.panel.h) {
        return;
    }

    const left_to_right = source.panel.x < destination.panel.x;
    const from_x = if (left_to_right) source.panel.right() - 2 else source.panel.x + 2;
    const to_x = if (left_to_right) destination.panel.x + 2 else destination.panel.right() - 2;
    const color = withAlpha(traceTagColor(entry.tag), 180);

    rl.drawRectangle(from_x - 2, source.y - 2, 4, 4, color);
    rl.drawRectangle(to_x - 2, destination.y - 2, 4, 4, color);
    rl.drawLine(from_x, source.y, to_x, destination.y, color);
}

fn endpointAnchor(endpoint: debugger_mod.TraceEndpoint, ui: layout.LayoutMetrics, mem_scroll: i32) ?PanelAnchor {
    return switch (endpoint) {
        .none, .decode => null,
        .pc => .{ .panel = ui.registers, .y = ui.registers.y + layout.HEADER_H + layout.REG_ROW_H * 4 + 13 },
        .index => .{ .panel = ui.registers, .y = ui.registers.y + layout.HEADER_H + layout.REG_ROW_H * 4 + 13 },
        .timers => .{ .panel = ui.registers, .y = ui.registers.y + layout.HEADER_H + layout.REG_ROW_H * 4 + 27 },
        .registers => |regs| .{
            .panel = ui.registers,
            .y = ui.registers.y + layout.HEADER_H + 2 + @as(i32, regs.start / 4) * layout.REG_ROW_H + @divTrunc(layout.REG_ROW_H, 2),
        },
        .stack => .{ .panel = ui.registers, .y = ui.registers.bottom() - layout.REG_ROW_H * 2 },
        .keypad => |keypad| .{
            .panel = ui.registers,
            .y = if (keypad.key != trace_mod.NO_KEY_INDEX)
                ui.registers.bottom() - layout.REG_ROW_H * (4 - @as(i32, @divTrunc(keypad.key, 4)))
            else
                ui.registers.bottom() - layout.REG_ROW_H * 2,
        },
        .memory => |mem| blk: {
            const row = @as(i32, @intCast(mem.addr / 16));
            const row_offset = row - mem_scroll;
            const y = if (row_offset >= 0 and row_offset < @as(i32, @intCast(ui.memory_rows_visible)))
                memoryRowsStartY(ui.memory) + row_offset * layout.LINE_H_SMALL + @divTrunc(layout.LINE_H_SMALL, 2)
            else
                ui.memory.y + @divTrunc(ui.memory.h, 2);
            break :blk .{ .panel = ui.memory, .y = y };
        },
        .display => |display_focus| .{
            .panel = ui.display,
            .y = @intFromFloat(
                @as(f32, @floatFromInt(ui.display.y)) +
                    (@as(f32, @floatFromInt(display_focus.y)) + @as(f32, @floatFromInt(@max(@as(i32, display_focus.h), 1))) * 0.5) *
                    displayCellHeight(ui.display, if (display_focus.w > cpu_mod.DISPLAY_WIDTH or display_focus.h > cpu_mod.DISPLAY_HEIGHT) .hires else .lores),
            ),
        },
    };
}

fn renderDisplay(
    cpu: *const cpu_mod.CPU,
    panel: layout.PanelRect,
    _: i32,
    settings: persistence.DisplaySettings,
    active_trace: ?debugger_mod.TraceEntry,
    show_trace_focus: bool,
) void {
    const primary = primaryAccent(settings);
    const secondary = secondary_color_override orelse blendColor(primary, FG_CYAN, 0.55);
    const blended = blended_color_override orelse blendColor(primary, secondary, 0.5);
    const logical_w = cpu.displayWidth();
    const logical_h = cpu.displayHeight();
    const cell_w = displayCellWidth(panel, cpu.display_mode);
    const cell_h = displayCellHeight(panel, cpu.display_mode);
    // ROM-specified background wins over the app's default dark fill when
    // the db supplies one. Typical XO-CHIP palettes want a near-black but
    // non-pitch background (e.g. garlicscape's #001000).
    const bg = background_color_override orelse BG_DARK;
    rl.drawRectangle(panel.x, panel.y, panel.w, panel.h, bg);
    for (0..logical_h) |row| {
        for (0..logical_w) |col| {
            const pixel = cpu.compositePixel(col, row);
            if (pixel == 0) continue;
            const color = switch (pixel) {
                1 => primary,
                2 => secondary,
                3 => blended,
                else => primary,
            };
            // Apply the per-ROM screen rotation when shipping pixels to
            // the canvas. 0/180 keep the source aspect; 90/270 swap axes,
            // so the rendered canvas is taller-than-wide for those cases.
            // Cell sizing itself is unchanged — any aspect mismatch with
            // the panel just leaves letterboxing, acceptable for the rare
            // `screen_rotation`-using ROM.
            const lw = logical_w;
            const lh = logical_h;
            const rot = screen_rotation_override;
            const pos = layout.rotatedCell(rot, col, row, lw, lh);
            rl.drawRectangleRec(.{
                .x = @as(f32, @floatFromInt(panel.x)) + @as(f32, @floatFromInt(pos.col)) * cell_w,
                .y = @as(f32, @floatFromInt(panel.y)) + @as(f32, @floatFromInt(pos.row)) * cell_h,
                .width = cell_w,
                .height = cell_h,
            }, color);
        }
    }
    if (settings.effect == .scanlines and cell_h > 1.5) {
        var y = panel.y;
        while (y < panel.bottom()) : (y += 2) {
            rl.drawRectangle(panel.x, y, panel.w, 1, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 40 });
        }
    }
    const rect = rl.Rectangle{
        .x = @floatFromInt(panel.x),
        .y = @floatFromInt(panel.y),
        .width = @floatFromInt(panel.w),
        .height = @floatFromInt(panel.h),
    };
    rl.drawRectangleRoundedLines(rect, 0.008, 4, SEPARATOR);

    if (show_trace_focus) {
        if (active_trace) |entry| {
            if (traceDisplayFocus(entry)) |focus| {
                drawDisplayFocus(panel, cpu, focus, withAlpha(primary, 220));
            }
        }
    }
}

fn renderRegisters(
    cpu: *const cpu_mod.CPU,
    state: EmulatorState,
    panel: layout.PanelRect,
    last_latched_key: ?u4,
    settings: persistence.DisplaySettings,
    active_trace: ?debugger_mod.TraceEntry,
    show_trace_focus: bool,
) void {
    drawPanel(panel, "REGISTERS");
    const primary = primaryAccent(settings);

    const state_label = switch (state) {
        .running => "RUN",
        .paused => "PAUSE",
        .stepping => "STEP",
    };
    const state_color = switch (state) {
        .running => FG_GREEN,
        .paused, .stepping => FG_AMBER,
    };
    headerInfo(panel, state_label, state_color);

    beginPanelClip(panel);
    defer endPanelClip();

    var cy = panel.y + layout.HEADER_H + 2;
    const row_h = layout.REG_ROW_H;

    const reg_col_w: i32 = @divTrunc(panel.w - 20, 4);
    for (0..16) |i| {
        const col: i32 = @intCast(i % 4);
        const row: i32 = @intCast(i / 4);
        const reg_x = panel.x + 10 + col * reg_col_w;
        const reg_y = cy + row * row_h;

        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "V{X}:{X:0>2}", .{ i, cpu.registers[i] }) catch "???";

        const age = cpu.frame_count -% cpu.reg_change_age[i];
        const color = if (age < 20) primary else if (cpu.registers[i] != 0) TEXT_BRIGHT else TEXT_DIM;
        drawText(reg_x, reg_y, label, layout.FONT_SIZE_SMALL, color);

        if (show_trace_focus and active_trace != null and traceTouchesRegister(active_trace.?, i)) {
            rl.drawRectangleLines(reg_x - 2, reg_y - 1, reg_col_w - 6, row_h, withAlpha(primary, 220));
        }
    }

    cy += row_h * 4 + 2;
    divider(panel, cy);
    cy += 4;

    var buf: [96]u8 = undefined;
    var label = std.fmt.bufPrint(&buf, "PC {X:0>3}  I {X:0>3}  SP {d}", .{
        cpu.program_counter,
        cpu.index_register,
        cpu.stack_pointer,
    }) catch "???";
    if (show_trace_focus and active_trace != null and (traceTouchesProgramCounter(active_trace.?) or traceTouchesIndex(active_trace.?))) {
        rl.drawRectangle(panel.x + 8, cy - 1, panel.w - 16, row_h, accentHighlight(settings));
    }
    drawTextFit(panel.x + 10, cy, panel.w - 20, label, layout.FONT_SIZE_SMALL, TEXT_BRIGHT);
    cy += row_h;

    label = std.fmt.bufPrint(&buf, "DT {d:0>3}  ST {d:0>3}  VF {X:0>2}", .{
        cpu.delay_timer,
        cpu.sound_timer,
        cpu.registers[0xF],
    }) catch "???";
    if (show_trace_focus and active_trace != null and (traceTouchesTimers(active_trace.?) or traceTouchesRegister(active_trace.?, 0xF))) {
        rl.drawRectangle(panel.x + 8, cy - 1, panel.w - 16, row_h, accentHighlight(settings));
    }
    drawTextFit(panel.x + 10, cy, panel.w - 20, label, layout.FONT_SIZE_SMALL, TEXT_MID);
    cy += row_h;

    var held_buf: [32]u8 = undefined;
    var last_buf: [2]u8 = undefined;
    label = std.fmt.bufPrint(&buf, "KEYS {s}  LAST {s}", .{
        heldKeysLine(cpu, &held_buf),
        lastKeyLabel(last_latched_key, &last_buf),
    }) catch "???";
    drawTextFit(panel.x + 10, cy, panel.w - 20, label, layout.FONT_SIZE_SMALL, TEXT_MID);
    cy += row_h + 2;
    divider(panel, cy);
    cy += 4;

    var stack_buf: [80]u8 = undefined;
    const stack_text = formatStackLine(cpu, &stack_buf);
    const cell_w: i32 = 18;
    const cell_h: i32 = 12;
    const cell_gap: i32 = 4;
    const keypad_w = cell_w * 4 + cell_gap * 3;
    const keypad_x = panel.x + panel.w - keypad_w - 12;
    const stack_w = @max(keypad_x - (panel.x + 10) - 16, 80);

    if (show_trace_focus and active_trace != null and traceTouchesStack(active_trace.?)) {
        rl.drawRectangle(panel.x + 8, cy - 1, stack_w + 32, row_h, accentHighlight(settings));
    }
    drawText(panel.x + 10, cy, "STK", layout.FONT_SIZE_SMALL, TEXT_DIM);
    drawTextFit(panel.x + 40, cy, stack_w - 30, stack_text, layout.FONT_SIZE_SMALL, TEXT_MID);
    drawText(keypad_x - 34, cy, "KEY", layout.FONT_SIZE_SMALL, TEXT_DIM);

    const trace_key_color = blendColor(BG_KEY, primary, 0.4);
    for (KEYPAD_ROWS, 0..) |row_keys, row| {
        const row_y = cy + @as(i32, @intCast(row)) * row_h;
        for (row_keys, 0..) |key_char, col| {
            const key_idx = keyIndexForChar(key_char) orelse continue;
            const cell_x = keypad_x + @as(i32, @intCast(col)) * (cell_w + cell_gap);
            const trace_key = if (show_trace_focus and active_trace != null) traceKeyFocus(active_trace.?) else null;
            const is_trace_key = trace_key != null and trace_key.? == key_idx;
            const is_pressed = cpu.keys[key_idx];
            const cell_color = if (is_pressed)
                primary
            else if (is_trace_key)
                trace_key_color
            else
                BG_KEY;
            const text_color = if (is_pressed)
                BG_DARK
            else if (is_trace_key)
                TEXT_BRIGHT
            else
                TEXT_MID;

            rl.drawRectangle(cell_x, row_y, cell_w, cell_h, cell_color);
            rl.drawRectangleLines(cell_x, row_y, cell_w, cell_h, SEPARATOR);

            var key_buf: [1]u8 = .{key_char};
            const key_w = layout.measureMonoTextWidth(&key_buf, layout.FONT_SIZE_SMALL);
            drawText(cell_x + @divTrunc(cell_w - key_w, 2), row_y - 1, &key_buf, layout.FONT_SIZE_SMALL, text_color);
        }
    }
}

fn renderCodePanel(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    debugger_state: *const debugger_mod.DebuggerState,
    panel: layout.PanelRect,
    visible_rows: usize,
    scroll: i32,
    rom_analysis: ?*const assembly.RomAnalysis,
) void {
    var header_buf: [32]u8 = undefined;
    const start_addr = @max(@as(i32, @intCast(cpu.program_counter)) + scroll * 2, 0);
    const end_addr = @min(start_addr + @as(i32, @intCast(visible_rows - 1)) * 2, cpu_mod.CHIP8_MEMORY_SIZE - 2);
    const header = std.fmt.bufPrint(&header_buf, "{X:0>3}-{X:0>3}", .{ start_addr, end_addr }) catch "";

    drawPanel(panel, "CODE");
    headerInfo(panel, header, TEXT_DIM);

    var pc: u16 = @intCast(@min(start_addr, cpu_mod.CHIP8_MEMORY_SIZE - 2));
    var cy = panel.y + layout.HEADER_H + 4;
    const empty_analysis = assembly.RomAnalysis{
        .rom_end = assembly.ROM_START,
        .profile = .modern,
        .label_targets = [_]bool{false} ** cpu_mod.CHIP8_MEMORY_SIZE,
    };
    const analysis = rom_analysis orelse &empty_analysis;

    beginPanelClip(panel);
    defer endPanelClip();

    for (0..visible_rows) |i| {
        if (pc + 1 >= cpu_mod.CHIP8_MEMORY_SIZE) break;
        if (cy + layout.LINE_H > panel.bottom()) break;
        if (i % 2 == 1) rl.drawRectangle(panel.x + 1, cy, panel.w - 2, layout.LINE_H, BG_ROW_ALT);

        const is_current = pc == cpu.program_counter;

        if (is_current) {
            rl.drawRectangle(panel.x + 1, cy, panel.w - 2, layout.LINE_H, HIGHLIGHT_CURRENT);
            drawText(panel.x + 6, cy, ">", layout.FONT_SIZE, FG_GREEN);
        }

        if (debugger_state.hasBreakpoint(pc)) {
            drawText(panel.x + 6, cy, "*", layout.FONT_SIZE, FG_AMBER);
        }

        var opcode_text_buf: [16]u8 = undefined;
        var asm_buf: [128]u8 = undefined;
        var comment_buf: [160]u8 = undefined;
        const row = assembly.formatUiCodeRow(memory, analysis, pc, &opcode_text_buf, &asm_buf, &comment_buf);

        var code_buf: [196]u8 = undefined;
        const code_text = std.fmt.bufPrint(&code_buf, "{X:0>3}: {s}  {s}", .{ pc, row.opcode_text, row.asm_text }) catch "???";
        const split_x = panel.x + @max(@divTrunc(panel.w, 2), 188);
        const code_color = if (is_current) FG_GREEN else if (row.is_db) TEXT_DIM else TEXT_MID;
        drawTextFit(panel.x + 18, cy, split_x - (panel.x + 24), code_text, layout.FONT_SIZE_SMALL, code_color);
        if (row.comment_text.len > 0) {
            drawTextFit(split_x, cy, panel.right() - 8 - split_x, row.comment_text, layout.FONT_SIZE_SMALL, if (is_current) TEXT_BRIGHT else TEXT_DIM);
        }

        cy += layout.LINE_H;
        pc +%= row.byte_len;
    }
}

fn renderMiddlePanel(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    debugger_state: *const debugger_mod.DebuggerState,
    panel: layout.PanelRect,
) void {
    drawPanel(panel, "");
    renderMiddleTabs(panel, debugger_state.active_middle_tab);

    switch (debugger_state.active_middle_tab) {
        .trace => renderTraceTab(debugger_state, panel),
        .cycle => renderCycleTab(debugger_state, panel),
        .watches => renderWatchesTab(cpu, memory, debugger_state, panel),
    }
}

fn renderMiddleTabs(panel: layout.PanelRect, active: debugger_mod.MiddleTab) void {
    const labels = [_][]const u8{ "TRACE", "CYCLE", "WATCHES" };
    const body_w = @divTrunc(panel.w, 3);
    for (labels, 0..) |label, idx| {
        const x = panel.x + @as(i32, @intCast(idx)) * body_w;
        const is_active = @as(usize, @intFromEnum(active)) == idx;
        rl.drawRectangle(x, panel.y, body_w, layout.HEADER_H, if (is_active) BG_PANEL else BG_HEADER);
        drawTextFit(x + 8, panel.y + 4, body_w - 16, label, layout.FONT_SIZE_SMALL, if (is_active) TEXT_BRIGHT else TEXT_DIM);
    }
}

fn renderTraceTab(debugger_state: *const debugger_mod.DebuggerState, panel: layout.PanelRect) void {
    drawTraceHeader(panel, debugger_state);

    beginPanelClip(panel);
    defer endPanelClip();

    if (debugger_state.trace_len == 0) {
        drawText(panel.x + 10, panel.y + layout.HEADER_H + 8, "No instruction trace yet.", layout.FONT_SIZE, TEXT_DIM);
        return;
    }

    const badge_w: i32 = 126;
    const visible_rows = traceRowsVisible(panel);
    var cy = panel.y + layout.HEADER_H + 6;

    for (0..visible_rows) |row| {
        const trace_index = debugger_state.trace_scroll + row;
        const entry = debugger_state.traceEntryFromNewest(trace_index) orelse break;
        const is_active = debugger_state.activeTraceIndex() != null and debugger_state.activeTraceIndex().? == trace_index;

        if (row % 2 == 1) rl.drawRectangle(panel.x + 1, cy, panel.w - 2, layout.LINE_H_SMALL, BG_ROW_ALT);
        if (is_active) rl.drawRectangle(panel.x + 1, cy, panel.w - 2, layout.LINE_H_SMALL, HIGHLIGHT_CURRENT);

        var opcode_buf: [16]u8 = undefined;
        const opcode_text = formatTraceOpcodeText(entry, &opcode_buf);
        var summary_buf: [128]u8 = undefined;
        const summary = formatTraceSummary(entry, &summary_buf);
        var badges_buf: [64]u8 = undefined;
        const badges = formatTraceBadges(entry, &badges_buf);

        const tag_color = traceTagColor(entry.tag);
        drawText(panel.x + 8, cy, traceTagLabel(entry.tag), layout.FONT_SIZE_SMALL, tag_color);
        drawText(panel.x + 54, cy, opcode_text, layout.FONT_SIZE_SMALL, if (is_active) TEXT_BRIGHT else TEXT_MID);
        drawTextFit(panel.x + 102, cy, panel.w - 110 - badge_w, summary, layout.FONT_SIZE_SMALL, if (is_active) TEXT_BRIGHT else TEXT_MID);
        drawTextRightFit(panel.x + panel.w - 8, cy, badge_w, badges, layout.FONT_SIZE_SMALL, TEXT_DIM);
        cy += layout.LINE_H_SMALL;
    }
}

fn renderCycleTab(debugger_state: *const debugger_mod.DebuggerState, panel: layout.PanelRect) void {
    const entry = debugger_state.activeTraceEntry() orelse {
        beginPanelClip(panel);
        defer endPanelClip();
        drawText(panel.x + 10, panel.y + layout.HEADER_H + 8, "No instruction trace yet.", layout.FONT_SIZE, TEXT_DIM);
        return;
    };

    var mnemonic_buf: [32]u8 = undefined;
    headerInfo(panel, traceInstruction(entry).format(&mnemonic_buf), traceTagColor(entry.tag));

    const body = panel.body();
    const label_w: i32 = 88;
    const lane_names = [_][]const u8{ "PC", "Memory", "Decode", "Registers", "Stack", "Display", "Keypad", "Timers" };
    const lane_area_x = body.x + label_w;
    const lane_area_w = @max(body.w - label_w - 8, 64);
    const lane_w = @max(@divTrunc(lane_area_w, @as(i32, @intCast(lane_names.len))), 18);

    beginPanelClip(panel);
    defer endPanelClip();

    for (lane_names, 0..) |name, idx| {
        const lane_x = lane_area_x + @as(i32, @intCast(idx)) * lane_w;
        drawTextFit(lane_x + 2, body.y + 2, lane_w - 4, name, layout.FONT_SIZE_SMALL, TEXT_DIM);
        rl.drawLine(lane_x + @divTrunc(lane_w, 2), body.y + layout.LINE_H_SMALL + 2, lane_x + @divTrunc(lane_w, 2), body.bottom(), SEPARATOR);
    }

    var cy = body.y + layout.LINE_H_SMALL + 8;
    for (entry.micro_ops[0..entry.micro_op_len]) |micro_op| {
        if (cy + layout.LINE_H_SMALL > body.bottom()) break;

        drawTextFit(body.x + 6, cy, label_w - 12, microOpLabel(micro_op.kind), layout.FONT_SIZE_SMALL, TEXT_MID);

        if (trace_mod.microOpConnector(micro_op)) |connector| {
            const from_x = laneCenterX(lane_area_x, lane_w, connector.from);
            const to_x = laneCenterX(lane_area_x, lane_w, connector.to);
            const y = cy + 6;
            rl.drawLine(from_x, y, to_x, y, traceTagColor(entry.tag));
            drawArrowHead(to_x, y, if (to_x >= from_x) 1 else -1, traceTagColor(entry.tag));
        } else {
            const lane = trace_mod.endpointLane(micro_op.destination) orelse trace_mod.endpointLane(micro_op.source) orelse .decode;
            const marker_x = laneCenterX(lane_area_x, lane_w, lane);
            rl.drawRectangle(marker_x - 3, cy + 3, 6, 6, traceTagColor(entry.tag));
        }

        cy += layout.LINE_H_SMALL;
    }
}

fn renderWatchesTab(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    debugger_state: *const debugger_mod.DebuggerState,
    panel: layout.PanelRect,
) void {
    var cy = panel.y + layout.HEADER_H + 6;
    const watch_primary = [_]struct { label: []const u8, value: u16 }{
        .{ .label = "PC", .value = cpu.program_counter },
        .{ .label = "I", .value = cpu.index_register },
        .{ .label = "SP", .value = cpu.stack_pointer },
        .{ .label = "DT", .value = cpu.delay_timer },
        .{ .label = "ST", .value = cpu.sound_timer },
        .{ .label = "VF", .value = cpu.registers[0xF] },
    };

    beginPanelClip(panel);
    defer endPanelClip();

    for (watch_primary) |entry| {
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}  {X:0>3}", .{ entry.label, entry.value }) catch "";
        drawText(panel.x + 8, cy, line, layout.FONT_SIZE_SMALL, TEXT_MID);
        cy += layout.LINE_H_SMALL;
    }

    divider(panel, cy + 2);
    cy += layout.LINE_H_SMALL;

    for (debugger_state.watch_addrs, 0..) |addr, idx| {
        const is_selected = debugger_state.selected_watch_slot == idx;
        if (is_selected) {
            rl.drawRectangle(panel.x + 2, cy - 1, panel.w - 4, layout.LINE_H_SMALL, accentHighlight(.{ .palette = .classic_green }));
        }

        var line_buf: [64]u8 = undefined;
        const b0 = memory[addr];
        const b1 = if (addr + 1 < memory.len) memory[addr + 1] else 0;
        const line = std.fmt.bufPrint(&line_buf, "{s}{d} {X:0>3}: {X:0>2} {X:0>2}", .{
            if (is_selected) ">" else " ",
            idx + 1,
            addr,
            b0,
            b1,
        }) catch "";
        drawText(panel.x + 8, cy, line, layout.FONT_SIZE_SMALL, if (is_selected) TEXT_BRIGHT else TEXT_MID);
        cy += layout.LINE_H_SMALL;
    }
}

fn renderMemoryView(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    panel: layout.PanelRect,
    visible_rows: usize,
    scroll: i32,
    active_trace: ?debugger_mod.TraceEntry,
    show_trace_focus: bool,
) void {
    const visible_range = layout.memoryVisibleRange(scroll, visible_rows);
    const start_row: usize = @intCast(scroll);

    var header_buf: [32]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{X:0>3}-{X:0>3}", .{ visible_range.start_addr, visible_range.end_addr }) catch "";

    drawPanel(panel, "MEMORY");
    headerInfo(panel, header, TEXT_DIM);

    var cy = panel.y + layout.HEADER_H + 4;
    drawTextFit(
        panel.x + 8,
        cy,
        panel.w - 16,
        "ADDR  00 01 02 03   04 05 06 07   08 09 0A 0B   0C 0D 0E 0F   ASCII",
        layout.FONT_SIZE_SMALL,
        TEXT_DIM,
    );
    cy += layout.LINE_H_SMALL + 2;
    rl.drawLine(panel.x + 4, cy - 1, panel.x + panel.w - 4, cy - 1, SEPARATOR);

    beginPanelClip(panel);
    defer endPanelClip();

    for (0..visible_rows) |ri| {
        const row = start_row + ri;
        if (row >= cpu_mod.CHIP8_MEMORY_SIZE / 16) break;
        if (cy + layout.LINE_H_SMALL > panel.bottom()) break;

        const base_addr: u16 = @intCast(row * 16);
        if (ri % 2 == 1) rl.drawRectangle(panel.x + 1, cy, panel.w - 2, layout.LINE_H_SMALL, BG_ROW_ALT);

        var addr_buf: [8]u8 = undefined;
        drawText(panel.x + 8, cy, std.fmt.bufPrint(&addr_buf, "{X:0>3}:", .{base_addr}) catch "???", layout.FONT_SIZE_SMALL, TEXT_DIM);

        for (0..16) |col| {
            const addr = base_addr + @as(u16, @intCast(col));
            if (addr >= cpu_mod.CHIP8_MEMORY_SIZE) break;

            const bx = memoryByteX(panel.x, @intCast(col));
            if (col % 4 == 0 and col > 0) rl.drawLine(bx - 5, cy, bx - 5, cy + layout.LINE_H_SMALL, SEPARATOR);

            if (addr == cpu.program_counter or addr == cpu.program_counter +| 1) {
                rl.drawRectangle(bx - 1, cy, HEX_BYTE_W - 4, layout.LINE_H_SMALL, HIGHLIGHT_PC);
            }
            if (cpu.last_i_target > 0 and addr >= cpu.last_i_target and addr < cpu.last_i_target +| 16) {
                rl.drawRectangle(bx - 1, cy, HEX_BYTE_W - 4, layout.LINE_H_SMALL, HIGHLIGHT_I);
            }
            if (show_trace_focus and active_trace != null) {
                if (traceMemoryContains(active_trace.?, addr)) {
                    rl.drawRectangle(bx - 1, cy, HEX_BYTE_W - 4, layout.LINE_H_SMALL, accentHighlight(.{ .palette = .classic_green }));
                }
            }

            const age = cpu.frame_count -% cpu.mem_write_age[addr];
            const color = if (age < 15)
                FG_GREEN
            else if (age < 60)
                blendColor(FG_GREEN, TEXT_DIM, @min(@as(f32, @floatFromInt(age)) / 60.0, 1.0))
            else if (memory[addr] != 0)
                TEXT_MID
            else
                rl.Color{ .r = 50, .g = 52, .b = 58, .a = 255 };

            var byte_buf: [4]u8 = undefined;
            drawText(bx, cy, std.fmt.bufPrint(&byte_buf, "{X:0>2}", .{memory[addr]}) catch "??", layout.FONT_SIZE_SMALL, color);
        }

        const ascii_x = memoryAsciiX(panel.x);
        var ascii_buf: [17]u8 = undefined;
        for (0..16) |col| {
            const addr = base_addr + @as(u16, @intCast(col));
            const byte = memory[addr];
            ascii_buf[col] = if (byte >= 0x20 and byte < 0x7F) byte else '.';
        }
        drawText(ascii_x, cy, ascii_buf[0..16], layout.FONT_SIZE_SMALL, TEXT_DIM);

        cy += layout.LINE_H_SMALL;
    }
}

fn renderFooter(
    panel: layout.PanelRect,
    two_rows: bool,
    cpu_hz: i32,
    sound_timer: u8,
    muted: bool,
    profile: emulation.QuirkProfile,
    active_save_slot: u8,
    volume: f32,
    status_text: []const u8,
    rom_name: ?[]const u8,
) void {
    rl.drawRectangle(panel.x, panel.y, panel.w, panel.h, BG_HEADER);
    rl.drawLine(panel.x, panel.y, panel.x + panel.w, panel.y, SEPARATOR);

    const controls = control.controls_label;
    const hint = control.controls_hint;

    var status_buf: [128]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "{s}  SLOT {d}  VOL {d}%  {d}Hz", .{
        emulation.profileLabel(profile),
        active_save_slot,
        @as(i32, @intFromFloat(volume * 100.0)),
        cpu_hz,
    }) catch "";

    const sound_text = if (muted)
        "Sound MUTED"
    else if (sound_timer > 0)
        "Sound BEEP"
    else
        "Sound ON";

    const sound_color = if (muted)
        TEXT_DIM
    else if (sound_timer > 0)
        rl.Color{
            .r = 255,
            .g = @as(u8, @intFromFloat((@sin(@as(f32, @floatFromInt(anim_tick)) * 0.3) + 1.0) * 80 + 95)),
            .b = 0,
            .a = 255,
        }
    else
        TEXT_DIM;

    var subline_buf: [160]u8 = undefined;
    const footer_body = if (status_text.len > 0) status_text else hint;
    const subline = if (rom_name) |name|
        std.fmt.bufPrint(&subline_buf, "{s}  |  {s}", .{ name, footer_body }) catch footer_body
    else
        footer_body;

    if (two_rows) {
        const row1_y = panel.y + 3;
        const row2_y = panel.y + 20;
        drawTextFit(8, row1_y, panel.w - 16, controls, layout.FONT_SIZE_SMALL, TEXT_DIM);
        drawTextFit(8, row2_y, panel.w - 280, subline, layout.FONT_SIZE_SMALL, TEXT_MID);
        drawFooterBadges(panel, row2_y, status, sound_text, sound_color);
    } else {
        const row_y = panel.y + 3;
        const speed_w = layout.measureMonoTextWidth(status, layout.FONT_SIZE_SMALL);
        const sound_w = layout.measureMonoTextWidth(sound_text, layout.FONT_SIZE_SMALL);
        const right_reserved = speed_w + sound_w + 32;
        drawTextFit(8, row_y, panel.w - right_reserved - 16, controls, layout.FONT_SIZE_SMALL, TEXT_DIM);
        drawFooterBadges(panel, row_y, status, sound_text, sound_color);
    }
}

fn drawFooterBadges(panel: layout.PanelRect, y: i32, status: []const u8, sound_text: []const u8, sound_color: rl.Color) void {
    const sound_w = layout.measureMonoTextWidth(sound_text, layout.FONT_SIZE_SMALL);
    const speed_w = layout.measureMonoTextWidth(status, layout.FONT_SIZE_SMALL);
    const sound_x = panel.w - 8 - sound_w;
    const speed_x = sound_x - 18 - speed_w;
    drawText(speed_x, y, status, layout.FONT_SIZE_SMALL, TEXT_MID);
    drawText(sound_x, y, sound_text, layout.FONT_SIZE_SMALL, sound_color);
}

fn formatStackLine(cpu: *const cpu_mod.CPU, buf: []u8) []const u8 {
    if (cpu.stack_pointer == 0) return "-";

    var len: usize = 0;
    const show = @min(@as(usize, cpu.stack_pointer), 4);
    for (0..show) |i| {
        const si: usize = cpu.stack_pointer - 1 - @as(u16, @intCast(i));
        const text = std.fmt.bufPrint(buf[len..], "{X:0>3} ", .{cpu.stack[si]}) catch break;
        len += text.len;
    }
    while (len > 0 and buf[len - 1] == ' ') : (len -= 1) {}
    return buf[0..len];
}

fn keyIndexForChar(ch: u8) ?usize {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'A' => 0xA,
        'B' => 0xB,
        'C' => 0xC,
        'D' => 0xD,
        'E' => 0xE,
        'F' => 0xF,
        else => null,
    };
}

fn memoryRowsStartY(panel: layout.PanelRect) i32 {
    return panel.y + layout.HEADER_H + layout.LINE_H_SMALL + 6;
}

fn memoryByteX(panel_x: i32, col: i32) i32 {
    return panel_x + HEX_START_X + col * HEX_BYTE_W + @divTrunc(col, 4) * HEX_GROUP_GAP;
}

fn memoryAsciiX(panel_x: i32) i32 {
    return panel_x + HEX_START_X + 16 * HEX_BYTE_W + 3 * HEX_GROUP_GAP + 12;
}

fn heldKeysLine(cpu: *const cpu_mod.CPU, buf: []u8) []const u8 {
    var len: usize = 0;
    for (cpu.keys, 0..) |pressed, idx| {
        if (!pressed) continue;
        const digit = nibbleChar(@intCast(idx));
        buf[len] = digit;
        len += 1;
        if (len < buf.len) {
            buf[len] = ' ';
            len += 1;
        }
    }
    if (len == 0) return "-";
    if (buf[len - 1] == ' ') len -= 1;
    return buf[0..len];
}

fn lastKeyLabel(key: ?u4, buf: []u8) []const u8 {
    if (key) |value| {
        buf[0] = nibbleChar(value);
        return buf[0..1];
    }
    return "-";
}

fn nibbleChar(value: u4) u8 {
    return if (value < 10) '0' + @as(u8, value) else 'A' + @as(u8, value - 10);
}

fn renderOverlay(
    ui: layout.LayoutMetrics,
    ui_state: *const ui_mod.UiState,
    debugger_state: *const debugger_mod.DebuggerState,
    recent_roms: []const persistence.RecentRom,
    installed_roms: []const models.InstalledRom,
) void {
    rl.drawRectangle(0, 0, ui.screen_w, ui.screen_h, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 150 });
    const overlay = layout.PanelRect{
        .x = @max(@divTrunc(ui.screen_w - 520, 2), 24),
        .y = @max(@divTrunc(ui.screen_h - 320, 2), 24),
        .w = @min(520, ui.screen_w - 48),
        .h = @min(320, ui.screen_h - 48),
    };
    drawPanel(overlay, "OVERLAY");

    switch (ui_state.overlay) {
        .recent_roms => renderRecentRomOverlay(overlay, recent_roms, installed_roms, ui_state.recent_selection),
        .save_slots => |mode| renderSlotOverlay(overlay, mode, ui_state.active_save_slot),
        .watch_edit => |edit| renderWatchEditOverlay(overlay, edit, debugger_state.selected_watch_slot),
        .none => {},
    }
}

fn isInstalledPathInRecents(recents: []const persistence.RecentRom, path: []const u8) bool {
    for (recents) |r| {
        if (std.mem.eql(u8, r.path, path)) return true;
    }
    return false;
}

fn renderRecentRomOverlay(
    panel: layout.PanelRect,
    recent_roms: []const persistence.RecentRom,
    installed_roms: []const models.InstalledRom,
    selection: usize,
) void {
    drawText(panel.x + 12, panel.y + layout.HEADER_H + 6, "ROM LIBRARY  (Enter to load, Esc to close, drag/drop also works)", layout.FONT_SIZE_SMALL, TEXT_MID);
    var cy = panel.y + layout.HEADER_H + 28;
    var cursor: usize = 0;

    // Section: installed ROMs that aren't already in the recent list.
    var any_installed = false;
    for (installed_roms) |rom| {
        if (isInstalledPathInRecents(recent_roms, rom.local.path)) continue;
        if (!any_installed) {
            drawText(panel.x + 12, cy, "INSTALLED", layout.FONT_SIZE_SMALL, TEXT_DIM);
            cy += layout.LINE_H;
            any_installed = true;
        }
        const is_selected = cursor == selection;
        if (is_selected) rl.drawRectangle(panel.x + 8, cy - 1, panel.w - 16, layout.LINE_H, HIGHLIGHT_CURRENT);

        const title = if (rom.metadata.chip8_db_entry) |e| e.title else rom.metadata.id;
        var line_buf: [192]u8 = undefined;
        const ns_opt: ?[]const u8 = switch (rom.local.source) {
            .known_registry => |v| v.name,
            else => null,
        };
        const line = if (ns_opt) |ns|
            std.fmt.bufPrint(&line_buf, "* {s}:{s}  ({s})", .{ ns, rom.metadata.id, title }) catch rom.metadata.id
        else
            std.fmt.bufPrint(&line_buf, "* {s}  ({s})", .{ rom.metadata.id, title }) catch rom.metadata.id;
        drawTextFit(panel.x + 12, cy, panel.w - 24, line, layout.FONT_SIZE, if (is_selected) TEXT_BRIGHT else TEXT_MID);
        cy += layout.LINE_H;
        cursor += 1;
    }

    // Section: recently-opened ROMs (by path).
    if (recent_roms.len > 0) {
        if (any_installed) cy += 6;
        drawText(panel.x + 12, cy, "RECENT", layout.FONT_SIZE_SMALL, TEXT_DIM);
        cy += layout.LINE_H;
        for (recent_roms, 0..) |rom, idx| {
            if (idx >= persistence.MAX_RECENT_ROMS) break;
            const is_selected = cursor == selection;
            if (is_selected) rl.drawRectangle(panel.x + 8, cy - 1, panel.w - 16, layout.LINE_H, HIGHLIGHT_CURRENT);

            var line_buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{d}. {s}", .{ idx + 1, rom.display_name }) catch rom.display_name;
            drawTextFit(panel.x + 12, cy, panel.w - 24, line, layout.FONT_SIZE, if (is_selected) TEXT_BRIGHT else TEXT_MID);
            cy += layout.LINE_H;
            cursor += 1;
        }
    }

    if (cursor == 0) {
        drawText(panel.x + 12, cy, "No ROMs yet. Try `chip8 get <source>`.", layout.FONT_SIZE, TEXT_DIM);
    }
}

fn renderSlotOverlay(panel: layout.PanelRect, mode: ui_mod.SlotOverlayMode, active_slot: u8) void {
    drawText(panel.x + 12, panel.y + layout.HEADER_H + 6, if (mode == .save) "SAVE SLOTS" else "LOAD SLOTS", layout.FONT_SIZE, TEXT_BRIGHT);
    drawText(panel.x + 12, panel.y + layout.HEADER_H + 24, "Use 1-5 or arrows + Enter", layout.FONT_SIZE_SMALL, TEXT_DIM);

    var cy = panel.y + layout.HEADER_H + 52;
    for (1..6) |slot| {
        const is_selected = slot == active_slot;
        if (is_selected) rl.drawRectangle(panel.x + 10, cy - 1, panel.w - 20, layout.LINE_H, HIGHLIGHT_CURRENT);
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "SLOT {d:0>2}", .{slot}) catch "";
        drawText(panel.x + 16, cy, line, layout.FONT_SIZE, if (is_selected) TEXT_BRIGHT else TEXT_MID);
        cy += layout.LINE_H + 6;
    }
}

fn renderWatchEditOverlay(panel: layout.PanelRect, edit: ui_mod.WatchEditState, selected_slot: usize) void {
    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "WATCH {d} ADDRESS", .{selected_slot + 1}) catch "WATCH ADDRESS";
    drawText(panel.x + 12, panel.y + layout.HEADER_H + 8, title, layout.FONT_SIZE, TEXT_BRIGHT);
    drawText(panel.x + 12, panel.y + layout.HEADER_H + 28, "Type 1-4 hex digits, Enter to apply", layout.FONT_SIZE_SMALL, TEXT_DIM);
    rl.drawRectangle(panel.x + 12, panel.y + layout.HEADER_H + 56, panel.w - 24, 36, BG_DARK);
    rl.drawRectangleLines(panel.x + 12, panel.y + layout.HEADER_H + 56, panel.w - 24, 36, SEPARATOR);
    drawText(panel.x + 22, panel.y + layout.HEADER_H + 64, edit.text[0..edit.len], 22, TEXT_BRIGHT);
}
