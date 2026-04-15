const rl = @import("raylib");
const cpu_mod = @import("cpu.zig");
const Instruction = cpu_mod.Instruction;

pub const PIXEL_SCALE = 8;
pub const DISPLAY_W = cpu_mod.DISPLAY_WIDTH * PIXEL_SCALE; // 512
pub const DISPLAY_H = cpu_mod.DISPLAY_HEIGHT * PIXEL_SCALE; // 256

const PANEL_W = 380;
const MARGIN = 8;
const FONT_SIZE = 14;
const LINE_H = 16;

pub const WINDOW_WIDTH = DISPLAY_W + PANEL_W + MARGIN * 3;
pub const WINDOW_HEIGHT = DISPLAY_H + 280 + MARGIN * 3; // display + memory view below

const FG_GREEN = rl.Color{ .r = 0, .g = 255, .b = 65, .a = 255 };
const FG_AMBER = rl.Color{ .r = 255, .g = 176, .b = 0, .a = 255 };
const BG_PANEL = rl.Color{ .r = 30, .g = 30, .b = 30, .a = 255 };
const BG_DARK = rl.Color{ .r = 15, .g = 15, .b = 15, .a = 255 };
pub const TEXT_DIM_PUB = rl.Color{ .r = 120, .g = 120, .b = 120, .a = 255 };
const TEXT_DIM = TEXT_DIM_PUB;
const TEXT_BRIGHT = rl.Color{ .r = 220, .g = 220, .b = 220, .a = 255 };
const HIGHLIGHT_PC = rl.Color{ .r = 255, .g = 80, .b = 80, .a = 100 };
const HIGHLIGHT_I = rl.Color{ .r = 80, .g = 80, .b = 255, .a = 100 };
const HIGHLIGHT_CURRENT = rl.Color{ .r = 255, .g = 255, .b = 0, .a = 40 };

pub const EmulatorState = enum { running, paused, stepping };

pub fn renderAll(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    state: EmulatorState,
    ips: i32,
    mem_scroll: *i32,
) void {
    // Chip-8 display (top-left)
    renderDisplay(cpu, MARGIN, MARGIN);

    // Registers panel (top-right)
    renderRegisters(cpu, state, ips, DISPLAY_W + MARGIN * 2, MARGIN);

    // Disassembler (right, below registers)
    renderDisassembler(cpu, memory, DISPLAY_W + MARGIN * 2, 300);

    // Memory hex view (bottom)
    renderMemoryView(cpu, memory, MARGIN, DISPLAY_H + MARGIN * 2, mem_scroll);
}

fn renderDisplay(cpu: *const cpu_mod.CPU, x: i32, y: i32) void {
    // Background
    rl.drawRectangle(x, y, DISPLAY_W, DISPLAY_H, BG_DARK);

    for (0..cpu_mod.DISPLAY_HEIGHT) |row| {
        for (0..cpu_mod.DISPLAY_WIDTH) |col| {
            if (cpu.display[row * cpu_mod.DISPLAY_WIDTH + col] == 1) {
                rl.drawRectangle(
                    x + @as(i32, @intCast(col * PIXEL_SCALE)),
                    y + @as(i32, @intCast(row * PIXEL_SCALE)),
                    PIXEL_SCALE,
                    PIXEL_SCALE,
                    FG_GREEN,
                );
            }
        }
    }

    // Border
    rl.drawRectangleLines(x, y, DISPLAY_W, DISPLAY_H, TEXT_DIM);
}

fn renderRegisters(cpu: *const cpu_mod.CPU, state: EmulatorState, ips: i32, x: i32, y: i32) void {
    const panel_w = PANEL_W - MARGIN;
    rl.drawRectangle(x, y, panel_w, 286, BG_PANEL);
    rl.drawRectangleLines(x, y, panel_w, 286, TEXT_DIM);

    var cy = y + 4;
    // Title
    drawLabel(x + 6, cy, "REGISTERS", TEXT_BRIGHT);
    cy += LINE_H + 4;

    // V registers in 4x4 grid
    for (0..16) |i| {
        const col_offset: i32 = @intCast((i % 4) * 90);
        const row_offset: i32 = @intCast((i / 4) * LINE_H);
        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "V{X}:{X:0>2}", .{ i, cpu.registers[i] }) catch "???";
        drawLabel(x + 6 + col_offset, cy + row_offset, label, if (cpu.registers[i] != 0) TEXT_BRIGHT else TEXT_DIM);
    }
    cy += LINE_H * 4 + 8;

    // Special registers
    var buf: [64]u8 = undefined;
    var label: []const u8 = undefined;

    label = std.fmt.bufPrint(&buf, "PC:{X:0>3}  I:{X:0>3}  SP:{d}", .{ cpu.program_counter, cpu.index_register, cpu.stack_pointer }) catch "???";
    drawLabel(x + 6, cy, label, TEXT_BRIGHT);
    cy += LINE_H;

    label = std.fmt.bufPrint(&buf, "DT:{d:0>3}  ST:{d:0>3}  Frame:{d}", .{ cpu.delay_timer, cpu.sound_timer, cpu.frame_count }) catch "???";
    drawLabel(x + 6, cy, label, TEXT_BRIGHT);
    cy += LINE_H + 8;

    // Stack visualization
    drawLabel(x + 6, cy, "STACK", TEXT_BRIGHT);
    cy += LINE_H;
    if (cpu.stack_pointer == 0) {
        drawLabel(x + 6, cy, "(empty)", TEXT_DIM);
    } else {
        for (0..@as(usize, cpu.stack_pointer)) |i| {
            const si = cpu.stack_pointer - 1 - @as(u16, @intCast(i));
            label = std.fmt.bufPrint(&buf, " {d}: {X:0>3}", .{ si, cpu.stack[si] }) catch "???";
            drawLabel(x + 6, cy, label, TEXT_DIM);
            cy += LINE_H;
            if (i >= 3) break; // Show at most 4
        }
    }
    cy += LINE_H + 4;

    // Keypad state
    const key_y = y + 286 - LINE_H * 4 - 20;
    drawLabel(x + 6, key_y - LINE_H, "KEYPAD", TEXT_BRIGHT);
    const key_labels = "123C456D789EA0BF";
    for (0..16) |i| {
        const kc: i32 = @intCast(i % 4);
        const kr: i32 = @intCast(i / 4);
        const kx = x + 6 + kc * 28;
        const ky = key_y + kr * LINE_H;
        const pressed = cpu.keys[i];
        var kbuf: [2]u8 = .{ key_labels[i], 0 };
        drawLabel(kx, ky, &kbuf, if (pressed) FG_GREEN else TEXT_DIM);
    }

    // State indicator
    const state_label = switch (state) {
        .running => "RUN",
        .paused => "PAUSE",
        .stepping => "STEP",
    };
    const state_color = switch (state) {
        .running => FG_GREEN,
        .paused => FG_AMBER,
        .stepping => FG_AMBER,
    };
    drawLabel(x + panel_w - 60, y + 4, state_label, state_color);

    // Speed
    label = std.fmt.bufPrint(&buf, "IPS:{d}", .{ips}) catch "???";
    drawLabel(x + panel_w - 80, y + 4 + LINE_H, label, TEXT_DIM);

    // Sound indicator
    if (cpu.sound_timer > 0) {
        drawLabel(x + panel_w - 60, y + 4 + LINE_H * 2, "BEEP", FG_AMBER);
    }
}

fn renderDisassembler(cpu: *const cpu_mod.CPU, memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8, x: i32, y: i32) void {
    const panel_w = PANEL_W - MARGIN;
    const panel_h = WINDOW_HEIGHT - y - MARGIN;
    rl.drawRectangle(x, y, panel_w, panel_h, BG_PANEL);
    rl.drawRectangleLines(x, y, panel_w, panel_h, TEXT_DIM);

    var cy = y + 4;
    drawLabel(x + 6, cy, "DISASSEMBLER", TEXT_BRIGHT);
    cy += LINE_H + 4;

    var pc = cpu.program_counter;
    for (0..14) |i| {
        if (pc + 1 >= cpu_mod.CHIP8_MEMORY_SIZE) break;

        const opcode: u16 = @as(u16, memory[pc]) << 8 | @as(u16, memory[pc + 1]);
        const inst = Instruction.decode(opcode);
        var mnemonic_buf: [32]u8 = undefined;
        const mnemonic = inst.format(&mnemonic_buf);

        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{X:0>3}: {X:0>4}  {s}", .{ pc, opcode, mnemonic }) catch "???";

        // Highlight current instruction
        if (i == 0) {
            rl.drawRectangle(x + 1, cy, panel_w - 2, LINE_H, HIGHLIGHT_CURRENT);
        }

        drawLabel(x + 6, cy, line, if (i == 0) FG_GREEN else TEXT_DIM);
        cy += LINE_H;
        pc += 2;
    }
}

fn renderMemoryView(
    cpu: *const cpu_mod.CPU,
    memory: *const [cpu_mod.CHIP8_MEMORY_SIZE]u8,
    x: i32,
    y: i32,
    scroll: *i32,
) void {
    const panel_w = DISPLAY_W;
    const panel_h = WINDOW_HEIGHT - y - MARGIN;
    rl.drawRectangle(x, y, panel_w, panel_h, BG_PANEL);
    rl.drawRectangleLines(x, y, panel_w, panel_h, TEXT_DIM);

    var cy = y + 4;
    drawLabel(x + 6, cy, "MEMORY", TEXT_BRIGHT);

    // Scroll with mouse wheel when hovering
    const mouse_x = rl.getMouseX();
    const mouse_y = rl.getMouseY();
    if (mouse_x >= x and mouse_x < x + panel_w and mouse_y >= y and mouse_y < y + panel_h) {
        const wheel = rl.getMouseWheelMove();
        scroll.* -= @intFromFloat(wheel * 3);
        if (scroll.* < 0) scroll.* = 0;
        if (scroll.* > 240) scroll.* = 240; // 256 rows - ~16 visible
    }

    cy += LINE_H + 2;

    // Header row
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "ADDR  00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F", .{}) catch "";
    drawLabel(x + 6, cy, header, TEXT_DIM);
    cy += LINE_H;

    const visible_rows = @as(usize, @intCast(@divTrunc(panel_h - 40, LINE_H)));
    const start_row: usize = @intCast(scroll.*);

    for (0..visible_rows) |ri| {
        const row = start_row + ri;
        if (row >= 256) break; // 4096 / 16 = 256 rows
        const base_addr: u16 = @intCast(row * 16);

        // Address label
        var addr_buf: [8]u8 = undefined;
        const addr_label = std.fmt.bufPrint(&addr_buf, "{X:0>3}:", .{base_addr}) catch "???";
        drawLabel(x + 6, cy, addr_label, TEXT_DIM);

        // Hex bytes
        for (0..16) |col| {
            const addr = base_addr + @as(u16, @intCast(col));
            if (addr >= cpu_mod.CHIP8_MEMORY_SIZE) break;

            const bx = x + 42 + @as(i32, @intCast(col)) * 24 + @as(i32, @intCast(col / 4)) * 4;

            // Highlight PC bytes
            if (addr == cpu.program_counter or addr == cpu.program_counter + 1) {
                rl.drawRectangle(bx - 1, cy, 22, LINE_H, HIGHLIGHT_PC);
            }
            // Highlight I target
            if (addr >= cpu.last_i_target and addr < cpu.last_i_target + 16 and cpu.last_i_target > 0) {
                rl.drawRectangle(bx - 1, cy, 22, LINE_H, HIGHLIGHT_I);
            }

            // Fade based on write age
            const age = cpu.frame_count -% cpu.mem_write_age[addr];
            const color = if (age < 30)
                FG_GREEN
            else if (age < 120)
                rl.Color{ .r = 0, .g = @intCast(255 - @min(age * 2, 200)), .b = 50, .a = 255 }
            else if (memory[addr] != 0)
                TEXT_DIM
            else
                rl.Color{ .r = 60, .g = 60, .b = 60, .a = 255 };

            var byte_buf: [4]u8 = undefined;
            const byte_str = std.fmt.bufPrint(&byte_buf, "{X:0>2}", .{memory[addr]}) catch "??";
            drawLabel(bx, cy, byte_str, color);
        }
        cy += LINE_H;
    }
}

const std = @import("std");

fn drawLabel(x: i32, y: i32, text: []const u8, color: rl.Color) void {
    // raylib needs null-terminated strings - use a stack buffer
    var buf: [128]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    rl.drawText(buf[0..len :0], x, y, FONT_SIZE, color);
}
