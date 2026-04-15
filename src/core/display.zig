const std = @import("std");
const rl = @import("raylib");
const cpu_mod = @import("cpu.zig");
const Instruction = cpu_mod.Instruction;

// Layout
pub const PIXEL_SCALE = 8;
pub const DISPLAY_W = cpu_mod.DISPLAY_WIDTH * PIXEL_SCALE; // 512
pub const DISPLAY_H = cpu_mod.DISPLAY_HEIGHT * PIXEL_SCALE; // 256

const PANEL_W = 420;
const MARGIN = 12;
const GUTTER_H = 66;
const FOOTER_H = 20;
const FONT_SIZE: f32 = 15;
const FONT_SIZE_SMALL: f32 = 13;
const LINE_H: i32 = 18;
const LINE_H_SMALL: i32 = 15;
const HEADER_H: i32 = 24;
const FONT_SPACING: f32 = 0.5;

const REG_H: i32 = 180;

pub const WINDOW_WIDTH = DISPLAY_W + PANEL_W + MARGIN * 3;
pub const WINDOW_HEIGHT = DISPLAY_H + GUTTER_H + 330 + MARGIN * 4 + FOOTER_H;

// Colors
const FG_GREEN = rl.Color{ .r = 0, .g = 230, .b = 65, .a = 255 };
const FG_AMBER = rl.Color{ .r = 255, .g = 176, .b = 0, .a = 255 };
const FG_BLUE = rl.Color{ .r = 100, .g = 140, .b = 255, .a = 255 };
const FG_CYAN = rl.Color{ .r = 0, .g = 210, .b = 210, .a = 255 };
const BG_PANEL = rl.Color{ .r = 30, .g = 32, .b = 36, .a = 255 };
const BG_HEADER = rl.Color{ .r = 38, .g = 40, .b = 46, .a = 255 };
const BG_DARK = rl.Color{ .r = 12, .g = 12, .b = 14, .a = 255 };
const BG_ROW_ALT = rl.Color{ .r = 34, .g = 36, .b = 40, .a = 255 };
const TEXT_DIM = rl.Color{ .r = 100, .g = 105, .b = 115, .a = 255 };
const TEXT_MID = rl.Color{ .r = 160, .g = 165, .b = 175, .a = 255 };
const TEXT_BRIGHT = rl.Color{ .r = 220, .g = 225, .b = 235, .a = 255 };
const SEPARATOR = rl.Color{ .r = 55, .g = 58, .b = 65, .a = 255 };
const HIGHLIGHT_PC = rl.Color{ .r = 200, .g = 60, .b = 60, .a = 70 };
const HIGHLIGHT_I = rl.Color{ .r = 60, .g = 80, .b = 200, .a = 60 };
const HIGHLIGHT_CURRENT = rl.Color{ .r = 0, .g = 200, .b = 65, .a = 30 };
const REG_CHANGED = rl.Color{ .r = 0, .g = 200, .b = 80, .a = 255 };
const PIPE_BG = rl.Color{ .r = 40, .g = 42, .b = 48, .a = 255 };

pub const TEXT_DIM_PUB = TEXT_DIM;
pub const BG_WINDOW_PUB = rl.Color{ .r = 22, .g = 22, .b = 26, .a = 255 };

pub const EmulatorState = enum { running, paused, stepping };

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
    muted: bool,
) void {
    anim_tick +%= 1;

    const rx = DISPLAY_W + MARGIN * 2;
    const disasm_y = MARGIN + REG_H + MARGIN;
    const gutter_y = MARGIN + DISPLAY_H + MARGIN;
    const mem_y = gutter_y + GUTTER_H + MARGIN;

    // Panels
    renderDisplay(cpu, MARGIN, MARGIN);
    renderRegisters(cpu, memory, state, rx, MARGIN, REG_H);
    renderDisassembler(cpu, memory, rx, disasm_y, gutter_y);
    renderFlowGutter(cpu, MARGIN, gutter_y);
    renderMemoryView(cpu, memory, MARGIN, mem_y, mem_scroll);
    renderFlowPipes(cpu, MARGIN, gutter_y, mem_y, mem_scroll.*);
    renderFooter(state, ips, cpu.sound_timer, muted);
}

// ── Helpers ──

fn drawPanel(x: i32, y: i32, w: i32, h: i32, title: []const u8) void {
    rl.drawRectangle(x, y, w, h, BG_PANEL);
    rl.drawRectangle(x, y, w, HEADER_H, BG_HEADER);
    drawText(x + 8, y + 4, title, FONT_SIZE, TEXT_MID);
    rl.drawLine(x, y + HEADER_H, x + w, y + HEADER_H, SEPARATOR);
    const rect = rl.Rectangle{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) };
    rl.drawRectangleRoundedLines(rect, 0.015, 4, SEPARATOR);
}

fn drawText(x: i32, y: i32, text: []const u8, size: f32, color: rl.Color) void {
    var buf: [128]u8 = undefined;
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

// ── Display pane ──

fn renderDisplay(cpu: *const cpu_mod.CPU, x: i32, y: i32) void {
    rl.drawRectangle(x, y, DISPLAY_W, DISPLAY_H, BG_DARK);
    for (0..cpu_mod.DISPLAY_HEIGHT) |row| {
        for (0..cpu_mod.DISPLAY_WIDTH) |col| {
            if (cpu.display[row * cpu_mod.DISPLAY_WIDTH + col] == 1) {
                rl.drawRectangle(
                    x + @as(i32, @intCast(col * PIXEL_SCALE)),
                    y + @as(i32, @intCast(row * PIXEL_SCALE)),
                    PIXEL_SCALE, PIXEL_SCALE, FG_GREEN,
                );
            }
        }
    }
    const rect = rl.Rectangle{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(DISPLAY_W), .height = @floatFromInt(DISPLAY_H) };
    rl.drawRectangleRoundedLines(rect, 0.008, 4, SEPARATOR);
}

// ── Registers pane ──

fn renderRegisters(cpu: *const cpu_mod.CPU, memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8, state: EmulatorState, x: i32, y: i32, h: i32) void {
    const w = PANEL_W;
    drawPanel(x, y, w, h, "REGISTERS");

    var cy = y + HEADER_H + 4;
    var active_vx: ?u4 = null;
    var active_vy: ?u4 = null;
    getInstructionOperands(cpu, memory, &active_vx, &active_vy);

    // V registers: 4x4 grid
    const reg_col_w: i32 = (w - 20) / 4; // evenly divide available width
    for (0..16) |i| {
        const col: i32 = @intCast(i % 4);
        const row: i32 = @intCast(i / 4);
        const regx = x + 10 + col * reg_col_w;
        const regy = cy + row * LINE_H;

        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "V{X}:{X:0>2}", .{ i, cpu.registers[i] }) catch "???";

        const age = cpu.frame_count -% cpu.reg_change_age[i];
        const color = if (age < 20) REG_CHANGED else if (cpu.registers[i] != 0) TEXT_BRIGHT else TEXT_DIM;
        drawText(regx, regy, label, FONT_SIZE, color);

        const vi: u4 = @intCast(i);
        if ((active_vx != null and active_vx.? == vi) or (active_vy != null and active_vy.? == vi)) {
            const box_w: i32 = reg_col_w - 6;
            rl.drawRectangleLines(regx - 2, regy - 1, box_w, LINE_H, flowColor(cpu.last_flow.kind));
        }
    }
    cy += LINE_H * 4 + 6;
    rl.drawLine(x + 8, cy, x + w - 8, cy, SEPARATOR);
    cy += 4;

    // Special registers
    var buf: [80]u8 = undefined;
    var label: []const u8 = undefined;
    label = std.fmt.bufPrint(&buf, "PC:{X:0>3}  I:{X:0>3}  SP:{d}", .{ cpu.program_counter, cpu.index_register, cpu.stack_pointer }) catch "???";
    drawText(x + 10, cy, label, FONT_SIZE, TEXT_BRIGHT);
    cy += LINE_H;
    label = std.fmt.bufPrint(&buf, "DT:{d:0>3}  ST:{d:0>3}", .{ cpu.delay_timer, cpu.sound_timer }) catch "???";
    drawText(x + 10, cy, label, FONT_SIZE, TEXT_MID);
    cy += LINE_H + 4;
    rl.drawLine(x + 8, cy, x + w - 8, cy, SEPARATOR);
    cy += 4;

    // Stack and Keypad side by side
    drawText(x + 10, cy, "STK", FONT_SIZE_SMALL, TEXT_DIM);
    if (cpu.stack_pointer == 0) {
        drawText(x + 40, cy, "-", FONT_SIZE_SMALL, TEXT_DIM);
    } else {
        var sbuf: [48]u8 = undefined;
        var slen: usize = 0;
        const show = @min(@as(usize, cpu.stack_pointer), 4);
        for (0..show) |i| {
            const si: usize = cpu.stack_pointer - 1 - @as(u16, @intCast(i));
            const s = std.fmt.bufPrint(sbuf[slen..], "{X:0>3} ", .{cpu.stack[si]}) catch break;
            slen += s.len;
        }
        drawText(x + 40, cy, sbuf[0..slen], FONT_SIZE_SMALL, TEXT_DIM);
    }

    // Keypad (inline, single row: show which keys are pressed)
    drawText(x + 200, cy, "KEY", FONT_SIZE_SMALL, TEXT_DIM);
    const key_labels = "0123456789ABCDEF";
    for (0..16) |i| {
        const kx = x + 234 + @as(i32, @intCast(i)) * 12;
        var kbuf: [2]u8 = .{ key_labels[i], 0 };
        drawText(kx, cy, &kbuf, FONT_SIZE_SMALL, if (cpu.keys[i]) FG_GREEN else rl.Color{ .r = 50, .g = 52, .b = 58, .a = 255 });
    }

    // State badge (in header, right-aligned)
    const state_label = switch (state) { .running => "RUN", .paused => "PAUSE", .stepping => "STEP" };
    const state_color = switch (state) { .running => FG_GREEN, .paused => FG_AMBER, .stepping => FG_AMBER };
    drawText(x + w - 50, y + 4, state_label, FONT_SIZE_SMALL, state_color);
}

// ── Disassembler pane ──

fn renderDisassembler(cpu: *const cpu_mod.CPU, memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8, x: i32, y: i32, max_y: i32) void {
    const w = PANEL_W;
    const panel_h = @max(max_y - y - MARGIN, HEADER_H + LINE_H * 3);
    drawPanel(x, y, w, panel_h, "DISASSEMBLER");

    var cy = y + HEADER_H + 4;
    var pc = cpu.program_counter;
    const max_lines = @as(usize, @intCast(@max(@divTrunc(panel_h - HEADER_H - 8, LINE_H), 1)));

    for (0..max_lines) |i| {
        if (pc + 1 >= cpu_mod.CHIP8_MEMORY_SIZE) break;
        if (cy + LINE_H > y + panel_h) break;
        if (i % 2 == 1) rl.drawRectangle(x + 1, cy, w - 2, LINE_H, BG_ROW_ALT);

        const opcode: u16 = @as(u16, memory[pc]) << 8 | @as(u16, memory[pc + 1]);
        const inst = Instruction.decode(opcode);
        var mnemonic_buf: [32]u8 = undefined;
        const mnemonic = inst.format(&mnemonic_buf);

        if (i == 0) {
            rl.drawRectangle(x + 1, cy, w - 2, LINE_H, HIGHLIGHT_CURRENT);
            drawText(x + 6, cy, ">", FONT_SIZE, FG_GREEN);
        }

        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{X:0>3}: {X:0>4}  {s}", .{ pc, opcode, mnemonic }) catch "???";
        drawText(x + 20, cy, line, FONT_SIZE, if (i == 0) FG_GREEN else if (opcode == 0) TEXT_DIM else TEXT_MID);
        cy += LINE_H;
        pc += 2;
    }
}

// ── Flow Gutter ──

fn renderFlowGutter(cpu: *const cpu_mod.CPU, x: i32, y: i32) void {
    const w = WINDOW_WIDTH - MARGIN * 2;
    drawPanel(x, y, w, GUTTER_H, "DATA FLOW");

    const flow = cpu.last_flow;
    const color = flowColor(flow.kind);
    const kind_label = flowLabel(flow.kind);
    var cy = y + HEADER_H + 4;

    if (flow.kind == .none) {
        drawText(x + 10, cy, "idle", FONT_SIZE, TEXT_DIM);
        return;
    }

    // Flow type badge
    drawText(x + 10, cy, kind_label, FONT_SIZE, color);

    // Flow description
    var desc_buf: [96]u8 = undefined;
    const desc: []const u8 = switch (flow.kind) {
        .fetch => std.fmt.bufPrint(&desc_buf, "RAM[{X:0>3}] --> Decode ({X:0>4})", .{ flow.src_addr, flow.opcode }) catch "",
        .sprite_read => std.fmt.bufPrint(&desc_buf, "RAM[{X:0>3}..+{d}] --> Display (V{X},V{X})", .{ flow.src_addr, flow.src_len, flow.vx, flow.vy }) catch "",
        .i_read => std.fmt.bufPrint(&desc_buf, "RAM[{X:0>3}..+{d}] --> V0..V{X}", .{ flow.src_addr, flow.src_len, flow.vx }) catch "",
        .i_write => std.fmt.bufPrint(&desc_buf, "V0..V{X} --> RAM[{X:0>3}..+{d}]", .{ flow.vx, flow.src_addr, flow.src_len }) catch "",
        .key_wait => std.fmt.bufPrint(&desc_buf, "Keypad --> V{X} (waiting)", .{flow.vx}) catch "",
        .reg_load => std.fmt.bufPrint(&desc_buf, "value --> V{X}  ({X:0>4})", .{ flow.vx, flow.opcode }) catch "",
        .reg_op => if (flow.vy != 0)
            std.fmt.bufPrint(&desc_buf, "V{X} <-> V{X}  ({X:0>4})", .{ flow.vx, flow.vy, flow.opcode }) catch ""
        else
            std.fmt.bufPrint(&desc_buf, "V{X} shift  ({X:0>4})", .{ flow.vx, flow.opcode }) catch "",
        .call => std.fmt.bufPrint(&desc_buf, "PC --> Stack, JP {X:0>3}", .{flow.src_addr}) catch "",
        .ret => std.fmt.bufPrint(&desc_buf, "Stack --> PC", .{}) catch "",
        .skip => std.fmt.bufPrint(&desc_buf, "V{X} test --> PC+2  ({X:0>4})", .{ flow.vx, flow.opcode }) catch "",
        .jump => std.fmt.bufPrint(&desc_buf, "JP {X:0>3}", .{flow.src_addr}) catch "",
        .timer => std.fmt.bufPrint(&desc_buf, "V{X} <-> Timer  ({X:0>4})", .{ flow.vx, flow.opcode }) catch "",
        .none => "",
    };
    drawText(x + 80, cy, desc, FONT_SIZE, TEXT_BRIGHT);

    // Animated flow bar
    cy += LINE_H + 2;
    const bar_x = x + 10;
    const bar_w = w - 20;
    rl.drawRectangle(bar_x, cy, bar_w, 4, PIPE_BG);

    const reverse = (flow.kind == .i_write or flow.kind == .call);
    const phase = @as(f32, @floatFromInt(anim_tick % 30)) / 30.0;

    for (0..8) |i| {
        var t = @as(f32, @floatFromInt(i)) / 8.0 + phase;
        t = @mod(t, 1.0);
        if (reverse) t = 1.0 - t;
        const dot_x = bar_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(bar_w)) * t));
        rl.drawRectangle(dot_x - 2, cy - 1, 5, 6, color);
    }

    if (reverse) {
        drawText(bar_x - 2, cy - 5, "<", FONT_SIZE_SMALL, color);
    } else {
        drawText(bar_x + bar_w - 2, cy - 5, ">", FONT_SIZE_SMALL, color);
    }
}

// ── Flow Pipes ──

fn renderFlowPipes(cpu: *const cpu_mod.CPU, base_x: i32, gutter_y: i32, mem_y: i32, mem_scroll: i32) void {
    const flow = cpu.last_flow;
    if (flow.kind == .none) return;
    const color = flowColor(flow.kind);
    const gutter_bottom = gutter_y + GUTTER_H;

    // Memory pipe (fetch, sprite, i_read, i_write)
    if (flow.src_addr > 0 and (flow.kind == .fetch or flow.kind == .sprite_read or flow.kind == .i_read or flow.kind == .i_write)) {
        const target_row = @as(i32, @intCast(flow.src_addr / 16));
        if (target_row >= mem_scroll and target_row < mem_scroll + 20) {
            const row_off = target_row - mem_scroll;
            const mem_row_y = mem_y + HEADER_H + LINE_H_SMALL + 4 + row_off * LINE_H_SMALL + LINE_H_SMALL / 2;
            const col = @as(i32, @intCast(flow.src_addr % 16));
            const pipe_x = base_x + 46 + col * 28 + @divTrunc(col, 4) * 10 + 12;

            if (flow.kind == .i_write) {
                drawAnimatedPipe(pipe_x, gutter_bottom + 4, pipe_x, mem_row_y, color, 4);
            } else {
                drawAnimatedPipe(pipe_x, mem_row_y, pipe_x, gutter_bottom + 4, color, 4);
            }
        }
    }

    // Display pipe (sprite reads)
    if (flow.kind == .sprite_read) {
        const disp_bottom = MARGIN + DISPLAY_H;
        const pipe_x = base_x + DISPLAY_W / 2;
        drawAnimatedPipe(pipe_x, gutter_y - 2, pipe_x, disp_bottom + 2, FG_BLUE, 3);
    }

    // Register pipe (reg_load, reg_op, i_read) — small arrow in gutter pointing up-right to registers
    if (flow.kind == .reg_load or flow.kind == .reg_op or flow.kind == .i_read or flow.kind == .timer) {
        const rx = DISPLAY_W + MARGIN * 2;
        const pipe_x = rx + 10;
        drawAnimatedPipe(pipe_x, gutter_y - 2, pipe_x, MARGIN + REG_H + 4, FG_GREEN, 3);
    }

    // Stack pipe (call/ret)
    if (flow.kind == .call or flow.kind == .ret) {
        const rx = DISPLAY_W + MARGIN * 2;
        const pipe_x = rx + PANEL_W - 30;
        drawAnimatedPipe(pipe_x, gutter_y - 2, pipe_x, MARGIN + REG_H + 4, FG_AMBER, 3);
    }
}

// ── Memory hex view ──

fn renderMemoryView(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    x: i32,
    y: i32,
    scroll: *i32,
) void {
    const panel_w = WINDOW_WIDTH - MARGIN * 2;
    const panel_h = WINDOW_HEIGHT - y - MARGIN - FOOTER_H;
    drawPanel(x, y, panel_w, panel_h, "MEMORY");

    const mouse_x = rl.getMouseX();
    const mouse_y = rl.getMouseY();
    if (mouse_x >= x and mouse_x < x + panel_w and mouse_y >= y and mouse_y < y + panel_h) {
        const wheel = rl.getMouseWheelMove();
        scroll.* -= @intFromFloat(wheel * 3);
        if (scroll.* < 0) scroll.* = 0;
        if (scroll.* > 240) scroll.* = 240;
    }

    var cy = y + HEADER_H + 4;

    // Column header
    const byte_w: i32 = 28;
    const grp_gap: i32 = 10;
    const hex_start: i32 = 46;
    drawText(x + 8, cy, "ADDR  00 01 02 03   04 05 06 07   08 09 0A 0B   0C 0D 0E 0F   ASCII", FONT_SIZE_SMALL, TEXT_DIM);
    cy += LINE_H_SMALL + 2;
    rl.drawLine(x + 4, cy - 1, x + panel_w - 4, cy - 1, SEPARATOR);

    const visible_rows = @as(usize, @intCast(@max(@divTrunc(panel_h - HEADER_H - LINE_H_SMALL - 12, LINE_H_SMALL), 1)));
    const start_row: usize = @intCast(scroll.*);

    for (0..visible_rows) |ri| {
        const row = start_row + ri;
        if (row >= 256) break;
        if (cy + LINE_H_SMALL > y + panel_h) break;
        const base_addr: u16 = @intCast(row * 16);

        if (ri % 2 == 1) rl.drawRectangle(x + 1, cy, panel_w - 2, LINE_H_SMALL, BG_ROW_ALT);

        var addr_buf: [8]u8 = undefined;
        drawText(x + 8, cy, std.fmt.bufPrint(&addr_buf, "{X:0>3}:", .{base_addr}) catch "???", FONT_SIZE_SMALL, TEXT_DIM);

        for (0..16) |col| {
            const addr = base_addr + @as(u16, @intCast(col));
            if (addr >= cpu_mod.CHIP8_MEMORY_SIZE) break;

            const gg: i32 = @intCast((col / 4) * grp_gap);
            const bx = x + hex_start + @as(i32, @intCast(col)) * byte_w + gg;

            if (col % 4 == 0 and col > 0) rl.drawLine(bx - 5, cy, bx - 5, cy + LINE_H_SMALL, SEPARATOR);

            if (addr == cpu.program_counter or addr == cpu.program_counter +| 1) {
                rl.drawRectangle(bx - 1, cy, byte_w - 4, LINE_H_SMALL, HIGHLIGHT_PC);
            }
            if (cpu.last_i_target > 0 and addr >= cpu.last_i_target and addr < cpu.last_i_target +| 16) {
                rl.drawRectangle(bx - 1, cy, byte_w - 4, LINE_H_SMALL, HIGHLIGHT_I);
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
            drawText(bx, cy, std.fmt.bufPrint(&byte_buf, "{X:0>2}", .{memory[addr]}) catch "??", FONT_SIZE_SMALL, color);
        }

        // ASCII column (right side)
        const ascii_x = x + hex_start + 16 * byte_w + 3 * grp_gap + 12;
        var ascii_buf: [17]u8 = undefined;
        for (0..16) |col| {
            const addr = base_addr + @as(u16, @intCast(col));
            if (addr >= cpu_mod.CHIP8_MEMORY_SIZE) break;
            const byte = memory[addr];
            ascii_buf[col] = if (byte >= 0x20 and byte < 0x7F) byte else '.';
        }
        drawText(ascii_x, cy, ascii_buf[0..16], FONT_SIZE_SMALL, TEXT_DIM);

        cy += LINE_H_SMALL;
    }
}

// ── Footer ──

fn renderFooter(state: EmulatorState, ips: i32, sound_timer: u8, muted: bool) void {
    const y = WINDOW_HEIGHT - FOOTER_H;
    rl.drawRectangle(0, y, WINDOW_WIDTH, FOOTER_H, BG_HEADER);
    rl.drawLine(0, y, WINDOW_WIDTH, y, SEPARATOR);

    const state_str = switch (state) { .running => "RUN", .paused => "PAUSE", .stepping => "STEP" };
    _ = state_str;

    var buf: [128]u8 = undefined;
    const footer = std.fmt.bufPrint(&buf, "SPACE:Run/Pause  N:Step  BKSP:Reset  M:Mute  Up/Down:Speed", .{}) catch "";
    drawText(8, y + 3, footer, FONT_SIZE_SMALL, TEXT_DIM);

    // Speed
    var speed_buf: [32]u8 = undefined;
    const speed = std.fmt.bufPrint(&speed_buf, "Speed: {d}Hz", .{ips}) catch "";
    drawText(WINDOW_WIDTH - 280, y + 3, speed, FONT_SIZE_SMALL, TEXT_MID);

    // Sound
    if (muted) {
        drawText(WINDOW_WIDTH - 130, y + 3, "SOUND: MUTED", FONT_SIZE_SMALL, TEXT_DIM);
    } else if (sound_timer > 0) {
        // Pulsing BEEP
        const pulse = @as(u8, @intFromFloat((@sin(@as(f32, @floatFromInt(anim_tick)) * 0.3) + 1.0) * 80 + 95));
        const beep_color = rl.Color{ .r = 255, .g = pulse, .b = 0, .a = 255 };
        drawText(WINDOW_WIDTH - 130, y + 3, "SOUND: BEEP", FONT_SIZE_SMALL, beep_color);
    } else {
        drawText(WINDOW_WIDTH - 130, y + 3, "SOUND: ON", FONT_SIZE_SMALL, TEXT_DIM);
    }
}

// ── Instruction operand extraction ──

fn getInstructionOperands(cpu: *const cpu_mod.CPU, memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8, vx: *?u4, vy: *?u4) void {
    const pc = cpu.program_counter;
    if (pc + 1 >= cpu_mod.CHIP8_MEMORY_SIZE) return;
    const opcode: u16 = @as(u16, memory[pc]) << 8 | @as(u16, memory[pc + 1]);
    const inst = Instruction.decode(opcode);
    switch (inst) {
        .se_byte => |s| { vx.* = s.vx; },
        .sne_byte => |s| { vx.* = s.vx; },
        .ld_byte => |s| { vx.* = s.vx; },
        .add_byte => |s| { vx.* = s.vx; },
        .rnd => |s| { vx.* = s.vx; },
        .se_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .sne_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .ld_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .or_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .and_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .xor_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .add_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .sub_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .subn_reg => |s| { vx.* = s.vx; vy.* = s.vy; },
        .shr => |s| { vx.* = s.vx; },
        .shl => |s| { vx.* = s.vx; },
        .drw => |s| { vx.* = s.vx; vy.* = s.vy; },
        .skp => |v| { vx.* = v; },
        .sknp => |v| { vx.* = v; },
        .ld_vx_dt => |v| { vx.* = v; },
        .ld_vx_k => |v| { vx.* = v; },
        .ld_dt_vx => |v| { vx.* = v; },
        .ld_st_vx => |v| { vx.* = v; },
        .add_i_vx => |v| { vx.* = v; },
        .ld_f_vx => |v| { vx.* = v; },
        .ld_b_vx => |v| { vx.* = v; },
        .ld_i_vx => |v| { vx.* = v; },
        .ld_vx_i => |v| { vx.* = v; },
        else => {},
    }
}
