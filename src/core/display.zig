const std = @import("std");
const rl = @import("raylib");
const cpu_mod = @import("cpu.zig");
const Instruction = cpu_mod.Instruction;
const layout = @import("display_layout.zig");

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
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    state: EmulatorState,
    ips: i32,
    mem_scroll: *i32,
    disasm_scroll: *i32,
    muted: bool,
) void {
    anim_tick +%= 1;

    const ui = layout.computeLayout(rl.getScreenWidth(), rl.getScreenHeight());
    const mouse_x = rl.getMouseX();
    const mouse_y = rl.getMouseY();
    const wheel = rl.getMouseWheelMove();

    if (state == .running) {
        disasm_scroll.* = 0;
    } else if (wheel != 0 and pointInRect(mouse_x, mouse_y, ui.disassembler.body())) {
        disasm_scroll.* -= @intFromFloat(wheel * 2);
    }

    if (wheel != 0 and pointInRect(mouse_x, mouse_y, ui.memory.body())) {
        mem_scroll.* -= @intFromFloat(wheel * 3);
    }

    mem_scroll.* = layout.clampMemoryScroll(mem_scroll.*, ui.memory_rows_visible);
    disasm_scroll.* = layout.clampDisasmScroll(disasm_scroll.*, cpu.program_counter, ui.disasm_rows_visible);

    renderDisplay(cpu, ui.display, ui.display_scale);
    renderRegisters(cpu, memory, state, ui.registers);
    renderDisassembler(cpu, memory, ui.disassembler, ui.disasm_rows_visible, disasm_scroll.*);
    renderFlowGutter(cpu, ui.gutter);
    renderMemoryView(cpu, memory, ui.memory, ui.memory_rows_visible, mem_scroll.*);
    renderFlowPipes(cpu, ui, mem_scroll.*);
    renderFooter(ui.footer, ui.footer_two_rows, ips, cpu.sound_timer, muted);
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

fn flowColor(kind: cpu_mod.CPU.FlowKind) rl.Color {
    return switch (kind) {
        .fetch => FG_GREEN,
        .sprite_read, .i_read => FG_BLUE,
        .i_write, .call => FG_AMBER,
        .key_wait, .timer => FG_CYAN,
        .reg_load, .reg_op, .skip, .jump => FG_GREEN,
        .ret => FG_AMBER,
        .none => TEXT_DIM,
    };
}

fn flowLabel(kind: cpu_mod.CPU.FlowKind) []const u8 {
    return switch (kind) {
        .fetch => "FETCH",
        .sprite_read => "SPRITE",
        .i_read => "LOAD",
        .i_write => "STORE",
        .key_wait => "KEY",
        .reg_load => "REG",
        .reg_op => "ALU",
        .call => "CALL",
        .ret => "RET",
        .skip => "SKIP",
        .jump => "JUMP",
        .timer => "TIMER",
        .none => "",
    };
}

fn drawAnimatedPipe(x1: i32, y1: i32, x2: i32, y2: i32, color: rl.Color, dot_count: u32) void {
    const dim = rl.Color{ .r = color.r / 3, .g = color.g / 3, .b = color.b / 3, .a = 80 };
    rl.drawLine(x1, y1, x2, y2, dim);
    rl.drawLine(x1 + 1, y1, x2 + 1, y2, dim);

    const dx = @as(f32, @floatFromInt(x2 - x1));
    const dy = @as(f32, @floatFromInt(y2 - y1));
    const phase = @as(f32, @floatFromInt(anim_tick % 20)) / 20.0;
    const min_y = @min(y1, y2);
    const max_y = @max(y1, y2);

    for (0..dot_count) |i| {
        const t = @mod(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(dot_count)) + phase, 1.0);
        const px = @as(i32, @intFromFloat(@as(f32, @floatFromInt(x1)) + dx * t));
        var py = @as(i32, @intFromFloat(@as(f32, @floatFromInt(y1)) + dy * t));
        py = @max(min_y, @min(py, max_y));

        const brightness = 1.0 - @abs(t - phase) * 2;
        const alpha: u8 = @intFromFloat(@max(brightness, 0.3) * 255);
        rl.drawRectangle(px - 1, py - 1, 3, 3, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = alpha });
    }
}

fn renderDisplay(cpu: *const cpu_mod.CPU, panel: layout.PanelRect, scale: i32) void {
    rl.drawRectangle(panel.x, panel.y, panel.w, panel.h, BG_DARK);
    for (0..cpu_mod.DISPLAY_HEIGHT) |row| {
        for (0..cpu_mod.DISPLAY_WIDTH) |col| {
            if (cpu.display[row * cpu_mod.DISPLAY_WIDTH + col] == 1) {
                rl.drawRectangle(
                    panel.x + @as(i32, @intCast(col)) * scale,
                    panel.y + @as(i32, @intCast(row)) * scale,
                    scale,
                    scale,
                    FG_GREEN,
                );
            }
        }
    }
    const rect = rl.Rectangle{
        .x = @floatFromInt(panel.x),
        .y = @floatFromInt(panel.y),
        .width = @floatFromInt(panel.w),
        .height = @floatFromInt(panel.h),
    };
    rl.drawRectangleRoundedLines(rect, 0.008, 4, SEPARATOR);
}

fn renderRegisters(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    state: EmulatorState,
    panel: layout.PanelRect,
) void {
    drawPanel(panel, "REGISTERS");

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

    var cy = panel.y + layout.HEADER_H + 2;
    const row_h = 14;
    var active_vx: ?u4 = null;
    var active_vy: ?u4 = null;
    getInstructionOperands(cpu, memory, &active_vx, &active_vy);

    const reg_col_w: i32 = @divTrunc(panel.w - 20, 4);
    for (0..16) |i| {
        const col: i32 = @intCast(i % 4);
        const row: i32 = @intCast(i / 4);
        const reg_x = panel.x + 10 + col * reg_col_w;
        const reg_y = cy + row * row_h;

        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "V{X}:{X:0>2}", .{ i, cpu.registers[i] }) catch "???";

        const age = cpu.frame_count -% cpu.reg_change_age[i];
        const color = if (age < 20) REG_CHANGED else if (cpu.registers[i] != 0) TEXT_BRIGHT else TEXT_DIM;
        drawText(reg_x, reg_y, label, layout.FONT_SIZE_SMALL, color);

        const vi: u4 = @intCast(i);
        if ((active_vx != null and active_vx.? == vi) or (active_vy != null and active_vy.? == vi)) {
            rl.drawRectangleLines(reg_x - 2, reg_y - 1, reg_col_w - 6, row_h, flowColor(cpu.last_flow.kind));
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
    drawTextFit(panel.x + 10, cy, panel.w - 20, label, layout.FONT_SIZE_SMALL, TEXT_BRIGHT);
    cy += row_h;

    label = std.fmt.bufPrint(&buf, "DT {d:0>3}  ST {d:0>3}  VF {X:0>2}", .{
        cpu.delay_timer,
        cpu.sound_timer,
        cpu.registers[0xF],
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

    drawText(panel.x + 10, cy, "STK", layout.FONT_SIZE_SMALL, TEXT_DIM);
    drawTextFit(panel.x + 40, cy, stack_w - 30, stack_text, layout.FONT_SIZE_SMALL, TEXT_MID);
    drawText(keypad_x - 34, cy, "KEY", layout.FONT_SIZE_SMALL, TEXT_DIM);

    for (KEYPAD_ROWS, 0..) |row_keys, row| {
        const row_y = cy + @as(i32, @intCast(row)) * row_h;
        for (row_keys, 0..) |key_char, col| {
            const key_idx = keyIndexForChar(key_char) orelse continue;
            const cell_x = keypad_x + @as(i32, @intCast(col)) * (cell_w + cell_gap);
            const cell_color = if (cpu.keys[key_idx]) FG_GREEN else BG_KEY;
            const text_color = if (cpu.keys[key_idx]) BG_DARK else TEXT_MID;

            rl.drawRectangle(cell_x, row_y, cell_w, cell_h, cell_color);
            rl.drawRectangleLines(cell_x, row_y, cell_w, cell_h, SEPARATOR);

            var key_buf: [1]u8 = .{key_char};
            const key_w = layout.measureMonoTextWidth(&key_buf, layout.FONT_SIZE_SMALL);
            drawText(cell_x + @divTrunc(cell_w - key_w, 2), row_y - 1, &key_buf, layout.FONT_SIZE_SMALL, text_color);
        }
    }
}

fn renderDisassembler(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    panel: layout.PanelRect,
    visible_rows: usize,
    scroll: i32,
) void {
    var header_buf: [32]u8 = undefined;
    const start_addr = @max(@as(i32, @intCast(cpu.program_counter)) + scroll * 2, 0);
    const end_addr = @min(start_addr + @as(i32, @intCast(visible_rows - 1)) * 2, cpu_mod.CHIP8_MEMORY_SIZE - 2);
    const header = std.fmt.bufPrint(&header_buf, "{X:0>3}-{X:0>3}", .{ start_addr, end_addr }) catch "";

    drawPanel(panel, "DISASSEMBLER");
    headerInfo(panel, header, TEXT_DIM);

    var pc: u16 = @intCast(@min(start_addr, cpu_mod.CHIP8_MEMORY_SIZE - 2));
    var cy = panel.y + layout.HEADER_H + 4;

    beginPanelClip(panel);
    defer endPanelClip();

    for (0..visible_rows) |i| {
        if (pc + 1 >= cpu_mod.CHIP8_MEMORY_SIZE) break;
        if (cy + layout.LINE_H > panel.bottom()) break;
        if (i % 2 == 1) rl.drawRectangle(panel.x + 1, cy, panel.w - 2, layout.LINE_H, BG_ROW_ALT);

        const opcode: u16 = @as(u16, memory[pc]) << 8 | @as(u16, memory[pc + 1]);
        const inst = Instruction.decode(opcode);
        var mnemonic_buf: [32]u8 = undefined;
        const mnemonic = inst.format(&mnemonic_buf);
        const is_current = pc == cpu.program_counter;

        if (is_current) {
            rl.drawRectangle(panel.x + 1, cy, panel.w - 2, layout.LINE_H, HIGHLIGHT_CURRENT);
            drawText(panel.x + 6, cy, ">", layout.FONT_SIZE, FG_GREEN);
        }

        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{X:0>3}: {X:0>4}  {s}", .{ pc, opcode, mnemonic }) catch "???";
        drawTextFit(
            panel.x + 20,
            cy,
            panel.w - 28,
            line,
            layout.FONT_SIZE,
            if (is_current) FG_GREEN else if (opcode == 0) TEXT_DIM else TEXT_MID,
        );

        cy += layout.LINE_H;
        pc +%= 2;
    }
}

fn renderFlowGutter(cpu: *const cpu_mod.CPU, panel: layout.PanelRect) void {
    drawPanel(panel, "DATA FLOW");

    const flow = cpu.last_flow;
    const color = flowColor(flow.kind);
    const kind_label = flowLabel(flow.kind);
    var cy = panel.y + layout.HEADER_H + 4;

    if (flow.kind == .none) {
        drawText(panel.x + 10, cy, "idle", layout.FONT_SIZE, TEXT_DIM);
        return;
    }

    drawText(panel.x + 10, cy, kind_label, layout.FONT_SIZE, color);

    var desc_buf: [96]u8 = undefined;
    const desc: []const u8 = switch (flow.kind) {
        .fetch => std.fmt.bufPrint(&desc_buf, "RAM[{X:0>3}] --> Decode ({X:0>4})", .{ flow.src_addr, flow.opcode }) catch "",
        .sprite_read => std.fmt.bufPrint(&desc_buf, "RAM[{X:0>3}..+{d}] --> Display (V{X},V{X})", .{ flow.src_addr, flow.src_len, flow.vx, flow.vy }) catch "",
        .i_read => std.fmt.bufPrint(&desc_buf, "RAM[{X:0>3}..+{d}] --> V0..V{X}", .{ flow.src_addr, flow.src_len, flow.vx }) catch "",
        .i_write => std.fmt.bufPrint(&desc_buf, "V0..V{X} --> RAM[{X:0>3}..+{d}]", .{ flow.vx, flow.src_addr, flow.src_len }) catch "",
        .key_wait => std.fmt.bufPrint(&desc_buf, "Keypad --> V{X} (waiting)", .{flow.vx}) catch "",
        .reg_load => std.fmt.bufPrint(&desc_buf, "value --> V{X} ({X:0>4})", .{ flow.vx, flow.opcode }) catch "",
        .reg_op => if (flow.vy != 0)
            std.fmt.bufPrint(&desc_buf, "V{X} <-> V{X} ({X:0>4})", .{ flow.vx, flow.vy, flow.opcode }) catch ""
        else
            std.fmt.bufPrint(&desc_buf, "V{X} shift ({X:0>4})", .{ flow.vx, flow.opcode }) catch "",
        .call => std.fmt.bufPrint(&desc_buf, "PC --> Stack, JP {X:0>3}", .{flow.src_addr}) catch "",
        .ret => std.fmt.bufPrint(&desc_buf, "Stack --> PC", .{}) catch "",
        .skip => std.fmt.bufPrint(&desc_buf, "V{X} test --> PC+2 ({X:0>4})", .{ flow.vx, flow.opcode }) catch "",
        .jump => std.fmt.bufPrint(&desc_buf, "JP {X:0>3}", .{flow.src_addr}) catch "",
        .timer => std.fmt.bufPrint(&desc_buf, "V{X} <-> Timer ({X:0>4})", .{ flow.vx, flow.opcode }) catch "",
        .none => "",
    };
    drawTextFit(panel.x + 80, cy, panel.w - 90, desc, layout.FONT_SIZE, TEXT_BRIGHT);

    cy += layout.LINE_H + 2;
    const bar_x = panel.x + 10;
    const bar_w = panel.w - 20;
    rl.drawRectangle(bar_x, cy, bar_w, 4, PIPE_BG);

    const reverse = flow.kind == .i_write or flow.kind == .call;
    const phase = @as(f32, @floatFromInt(anim_tick % 30)) / 30.0;

    for (0..8) |i| {
        var t = @as(f32, @floatFromInt(i)) / 8.0 + phase;
        t = @mod(t, 1.0);
        if (reverse) t = 1.0 - t;
        const dot_x = bar_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(bar_w)) * t));
        rl.drawRectangle(dot_x - 2, cy - 1, 5, 6, color);
    }

    if (reverse) {
        drawText(bar_x - 2, cy - 5, "<", layout.FONT_SIZE_SMALL, color);
    } else {
        drawText(bar_x + bar_w - 2, cy - 5, ">", layout.FONT_SIZE_SMALL, color);
    }
}

fn renderFlowPipes(cpu: *const cpu_mod.CPU, ui: layout.LayoutMetrics, mem_scroll: i32) void {
    const flow = cpu.last_flow;
    if (flow.kind == .none) return;

    const color = flowColor(flow.kind);
    const gutter_bottom = ui.gutter.bottom();

    if (flow.src_addr > 0 and (flow.kind == .fetch or flow.kind == .sprite_read or flow.kind == .i_read or flow.kind == .i_write)) {
        const target_row = @as(i32, @intCast(flow.src_addr / 16));
        if (target_row >= mem_scroll and target_row < mem_scroll + @as(i32, @intCast(ui.memory_rows_visible))) {
            const row_off = target_row - mem_scroll;
            const mem_row_y = memoryRowsStartY(ui.memory) + row_off * layout.LINE_H_SMALL + @divTrunc(layout.LINE_H_SMALL, 2);
            const col = @as(i32, @intCast(flow.src_addr % 16));
            const pipe_x = memoryByteX(ui.memory.x, col) + 12;

            if (flow.kind == .i_write) {
                drawAnimatedPipe(pipe_x, gutter_bottom + 4, pipe_x, mem_row_y, color, 4);
            } else {
                drawAnimatedPipe(pipe_x, mem_row_y, pipe_x, gutter_bottom + 4, color, 4);
            }
        }
    }

    if (flow.kind == .sprite_read) {
        const pipe_x = ui.display.x + @divTrunc(ui.display.w, 2);
        drawAnimatedPipe(pipe_x, ui.gutter.y - 2, pipe_x, ui.display.bottom() + 2, FG_BLUE, 3);
    }

    if (flow.kind == .reg_load or flow.kind == .reg_op or flow.kind == .i_read or flow.kind == .timer) {
        const pipe_x = ui.registers.x + 10;
        drawAnimatedPipe(pipe_x, ui.gutter.y - 2, pipe_x, ui.registers.bottom() + 4, FG_GREEN, 3);
    }

    if (flow.kind == .call or flow.kind == .ret) {
        const pipe_x = ui.registers.right() - 30;
        drawAnimatedPipe(pipe_x, ui.gutter.y - 2, pipe_x, ui.registers.bottom() + 4, FG_AMBER, 3);
    }
}

fn renderMemoryView(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    panel: layout.PanelRect,
    visible_rows: usize,
    scroll: i32,
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

fn renderFooter(panel: layout.PanelRect, two_rows: bool, ips: i32, sound_timer: u8, muted: bool) void {
    rl.drawRectangle(panel.x, panel.y, panel.w, panel.h, BG_HEADER);
    rl.drawLine(panel.x, panel.y, panel.x + panel.w, panel.y, SEPARATOR);

    const controls = "SPACE Run/Pause  N Step  BKSP Reset  M Mute  Up/Down Speed";
    const hint = "Wheel over Memory or Disassembler to scroll";

    var speed_buf: [32]u8 = undefined;
    const speed = std.fmt.bufPrint(&speed_buf, "Speed {d}Hz", .{ips}) catch "";

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

    if (two_rows) {
        const row1_y = panel.y + 3;
        const row2_y = panel.y + 20;
        drawTextFit(8, row1_y, panel.w - 16, controls, layout.FONT_SIZE_SMALL, TEXT_DIM);
        drawTextFit(8, row2_y, panel.w - 220, hint, layout.FONT_SIZE_SMALL, TEXT_MID);
        drawFooterBadges(panel, row2_y, speed, sound_text, sound_color);
    } else {
        const row_y = panel.y + 3;
        const speed_w = layout.measureMonoTextWidth(speed, layout.FONT_SIZE_SMALL);
        const sound_w = layout.measureMonoTextWidth(sound_text, layout.FONT_SIZE_SMALL);
        const right_reserved = speed_w + sound_w + 32;
        drawTextFit(8, row_y, panel.w - right_reserved - 16, controls, layout.FONT_SIZE_SMALL, TEXT_DIM);
        drawFooterBadges(panel, row_y, speed, sound_text, sound_color);
    }
}

fn drawFooterBadges(panel: layout.PanelRect, y: i32, speed: []const u8, sound_text: []const u8, sound_color: rl.Color) void {
    const sound_w = layout.measureMonoTextWidth(sound_text, layout.FONT_SIZE_SMALL);
    const speed_w = layout.measureMonoTextWidth(speed, layout.FONT_SIZE_SMALL);
    const sound_x = panel.w - 8 - sound_w;
    const speed_x = sound_x - 18 - speed_w;
    drawText(speed_x, y, speed, layout.FONT_SIZE_SMALL, TEXT_MID);
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

fn getInstructionOperands(cpu: *const cpu_mod.CPU, memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8, vx: *?u4, vy: *?u4) void {
    const pc = cpu.program_counter;
    if (pc + 1 >= cpu_mod.CHIP8_MEMORY_SIZE) return;
    const opcode: u16 = @as(u16, memory[pc]) << 8 | @as(u16, memory[pc + 1]);
    const inst = Instruction.decode(opcode);
    switch (inst) {
        .se_byte => |s| vx.* = s.vx,
        .sne_byte => |s| vx.* = s.vx,
        .ld_byte => |s| vx.* = s.vx,
        .add_byte => |s| vx.* = s.vx,
        .rnd => |s| vx.* = s.vx,
        .se_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .sne_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .ld_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .or_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .and_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .xor_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .add_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .sub_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .subn_reg => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .shr => |s| vx.* = s.vx,
        .shl => |s| vx.* = s.vx,
        .drw => |s| {
            vx.* = s.vx;
            vy.* = s.vy;
        },
        .skp => |v| vx.* = v,
        .sknp => |v| vx.* = v,
        .ld_vx_dt => |v| vx.* = v,
        .ld_vx_k => |v| vx.* = v,
        .ld_dt_vx => |v| vx.* = v,
        .ld_st_vx => |v| vx.* = v,
        .add_i_vx => |v| vx.* = v,
        .ld_f_vx => |v| vx.* = v,
        .ld_b_vx => |v| vx.* = v,
        .ld_i_vx => |v| vx.* = v,
        .ld_vx_i => |v| vx.* = v,
        else => {},
    }
}
