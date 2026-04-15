const std = @import("std");
const cpu = @import("cpu.zig");
const display_layout = @import("display_layout.zig");

test "CPU initialization" {
    const c = cpu.CPU.init();

    for (c.registers) |reg| {
        try std.testing.expectEqual(@as(u8, 0), reg);
    }
    try std.testing.expectEqual(@as(u16, 0), c.index_register);
    try std.testing.expectEqual(@as(u16, 0x200), c.program_counter);
    for (c.stack) |entry| {
        try std.testing.expectEqual(@as(u16, 0), entry);
    }
    try std.testing.expectEqual(@as(u16, 0), c.stack_pointer);
    try std.testing.expectEqual(@as(u8, 0), c.delay_timer);
    try std.testing.expectEqual(@as(u8, 0), c.sound_timer);
    try std.testing.expectEqual(false, c.draw_flag);
    try std.testing.expectEqual(false, c.waiting_for_key);
}

test "Clear screen" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** 4096;

    // Place CLS (0x00E0) at PC
    c.program_counter = 0;
    memory[0] = 0x00;
    memory[1] = 0xE0;

    // Set some display pixels first
    c.display[0] = 1;
    c.display[100] = 1;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u16, 2), c.program_counter);
    try std.testing.expectEqual(@as(u1, 0), c.display[0]);
    try std.testing.expectEqual(@as(u1, 0), c.display[100]);
    try std.testing.expect(c.draw_flag);
}

test "Jump to address" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** 4096;

    c.program_counter = 0;
    memory[0] = 0x12;
    memory[1] = 0x34;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u16, 0x234), c.program_counter);
}

test "Set VX = KK" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** 4096;

    c.program_counter = 0;
    memory[0] = 0x61;
    memory[1] = 0xAB;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 0xAB), c.registers[1]);
    try std.testing.expectEqual(@as(u16, 2), c.program_counter);
}

test "Add VX, KK" {
    var c = cpu.CPU.init();
    c.registers[2] = 0x10;
    var memory = [_]u8{0} ** 4096;

    c.program_counter = 0;
    memory[0] = 0x72;
    memory[1] = 0xCD;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 0xDD), c.registers[2]);
    try std.testing.expectEqual(@as(u16, 2), c.program_counter);
}

test "Add VX, KK wraps on overflow" {
    var c = cpu.CPU.init();
    c.registers[0] = 0xFF;
    var memory = [_]u8{0} ** 4096;

    c.program_counter = 0;
    memory[0] = 0x70; // ADD V0, 0x02
    memory[1] = 0x02;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 0x01), c.registers[0]);
}

test "ADD VX, VY with carry" {
    var c = cpu.CPU.init();
    c.registers[0] = 0xFF;
    c.registers[1] = 0x02;
    var memory = [_]u8{0} ** 4096;

    c.program_counter = 0;
    memory[0] = 0x80; // ADD V0, V1
    memory[1] = 0x14;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 0x01), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 1), c.registers[0xF]); // carry
}

test "SUB VX, VY with borrow" {
    var c = cpu.CPU.init();
    c.registers[0] = 0x01;
    c.registers[1] = 0x02;
    var memory = [_]u8{0} ** 4096;

    c.program_counter = 0;
    memory[0] = 0x80; // SUB V0, V1
    memory[1] = 0x15;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 0xFF), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 0), c.registers[0xF]); // borrow
}

test "SUB VX, VY no borrow" {
    var c = cpu.CPU.init();
    c.registers[0] = 0x05;
    c.registers[1] = 0x02;
    var memory = [_]u8{0} ** 4096;

    c.program_counter = 0;
    memory[0] = 0x80;
    memory[1] = 0x15;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 0x03), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 1), c.registers[0xF]); // no borrow
}

test "BCD store" {
    var c = cpu.CPU.init();
    c.registers[0] = 123;
    c.index_register = 0x300;
    var memory = [_]u8{0} ** 4096;

    c.program_counter = 0;
    memory[0] = 0xF0; // LD B, V0
    memory[1] = 0x33;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 1), memory[0x300]);
    try std.testing.expectEqual(@as(u8, 2), memory[0x301]);
    try std.testing.expectEqual(@as(u8, 3), memory[0x302]);
}

test "Store and load registers" {
    var c = cpu.CPU.init();
    c.registers[0] = 0xAA;
    c.registers[1] = 0xBB;
    c.registers[2] = 0xCC;
    c.index_register = 0x300;
    var memory = [_]u8{0} ** 4096;

    // Store V0..V2 (FX55 where X=2)
    c.program_counter = 0;
    memory[0] = 0xF2;
    memory[1] = 0x55;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 0xAA), memory[0x300]);
    try std.testing.expectEqual(@as(u8, 0xBB), memory[0x301]);
    try std.testing.expectEqual(@as(u8, 0xCC), memory[0x302]);

    // Clear registers
    c.registers[0] = 0;
    c.registers[1] = 0;
    c.registers[2] = 0;

    // Load V0..V2 (FX65 where X=2)
    c.program_counter = 0;
    memory[0] = 0xF2;
    memory[1] = 0x65;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u8, 0xAA), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), c.registers[1]);
    try std.testing.expectEqual(@as(u8, 0xCC), c.registers[2]);
}

test "Draw sprite" {
    var c = cpu.CPU.init();
    c.registers[0] = 0; // X position
    c.registers[1] = 0; // Y position
    c.index_register = 0x300;
    var memory = [_]u8{0} ** 4096;

    // Sprite: one row, 0xF0 = 11110000
    memory[0x300] = 0xF0;

    c.program_counter = 0;
    memory[0] = 0xD0; // DRW V0, V1, 1
    memory[1] = 0x11;

    try c.executeInstruction(&memory);

    // First 4 pixels should be on
    try std.testing.expectEqual(@as(u1, 1), c.display[0]);
    try std.testing.expectEqual(@as(u1, 1), c.display[1]);
    try std.testing.expectEqual(@as(u1, 1), c.display[2]);
    try std.testing.expectEqual(@as(u1, 1), c.display[3]);
    // Next 4 should be off
    try std.testing.expectEqual(@as(u1, 0), c.display[4]);
    // No collision
    try std.testing.expectEqual(@as(u8, 0), c.registers[0xF]);
    try std.testing.expect(c.draw_flag);
}

test "Draw sprite collision" {
    var c = cpu.CPU.init();
    c.registers[0] = 0;
    c.registers[1] = 0;
    c.index_register = 0x300;
    var memory = [_]u8{0} ** 4096;

    memory[0x300] = 0x80; // 10000000

    // Set pixel 0 already on
    c.display[0] = 1;

    c.program_counter = 0;
    memory[0] = 0xD0;
    memory[1] = 0x11;

    try c.executeInstruction(&memory);

    // Pixel 0 should be XORed off
    try std.testing.expectEqual(@as(u1, 0), c.display[0]);
    // Collision detected
    try std.testing.expectEqual(@as(u8, 1), c.registers[0xF]);
}

test "Call and return subroutine" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** 4096;

    // CALL 0x400
    c.program_counter = 0x200;
    memory[0x200] = 0x24;
    memory[0x201] = 0x00;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u16, 0x400), c.program_counter);
    try std.testing.expectEqual(@as(u16, 1), c.stack_pointer);
    try std.testing.expectEqual(@as(u16, 0x202), c.stack[0]); // return address

    // RET
    memory[0x400] = 0x00;
    memory[0x401] = 0xEE;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u16, 0x202), c.program_counter);
    try std.testing.expectEqual(@as(u16, 0), c.stack_pointer);
}

test "Skip if equal" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** 4096;
    c.registers[0] = 0x42;

    // SE V0, 0x42 - should skip
    c.program_counter = 0;
    memory[0] = 0x30;
    memory[1] = 0x42;

    try c.executeInstruction(&memory);
    try std.testing.expectEqual(@as(u16, 4), c.program_counter);

    // SE V0, 0x99 - should not skip
    c.program_counter = 0;
    memory[0] = 0x30;
    memory[1] = 0x99;

    try c.executeInstruction(&memory);
    try std.testing.expectEqual(@as(u16, 2), c.program_counter);
}

test "Font sprite location" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** 4096;

    c.registers[0] = 0x0A; // character 'A'
    c.program_counter = 0;
    memory[0] = 0xF0; // LD F, V0
    memory[1] = 0x29;

    try c.executeInstruction(&memory);

    try std.testing.expectEqual(@as(u16, 0x0A * 5), c.index_register);
}

test "Display layout stays inside the window and keeps panel gaps" {
    try expectStableLayout(display_layout.computeLayout(display_layout.DEFAULT_WINDOW_WIDTH, display_layout.DEFAULT_WINDOW_HEIGHT));
    try expectStableLayout(display_layout.computeLayout(display_layout.MIN_WINDOW_WIDTH, display_layout.MIN_WINDOW_HEIGHT));
    try expectStableLayout(display_layout.computeLayout(
        display_layout.DEFAULT_WINDOW_WIDTH + 320,
        display_layout.DEFAULT_WINDOW_HEIGHT + 240,
    ));
}

test "Display layout scroll clamps are derived from visible rows" {
    try std.testing.expectEqual(@as(i32, 0), display_layout.clampMemoryScroll(-4, 12));
    try std.testing.expectEqual(@as(i32, 244), display_layout.clampMemoryScroll(999, 12));

    const visible_rows: usize = 10;
    const min_scroll = display_layout.clampDisasmScroll(-999, 0x200, visible_rows);
    const max_scroll = display_layout.clampDisasmScroll(9999, 0x200, visible_rows);
    try std.testing.expectEqual(@as(i32, -256), min_scroll);
    try std.testing.expectEqual(@as(i32, 1782), max_scroll);

    const start_row = @as(i32, 0x200 / 2) + max_scroll;
    try std.testing.expect(start_row + @as(i32, @intCast(visible_rows)) <= cpu.CHIP8_MEMORY_SIZE / 2);
}

test "Display layout memory range stays valid at edge inputs" {
    const normal = display_layout.memoryVisibleRange(0x20, 19);
    try std.testing.expectEqual(@as(u16, 0x200), normal.start_addr);
    try std.testing.expectEqual(@as(u16, 0x32F), normal.end_addr);

    const zero_rows = display_layout.memoryVisibleRange(0, 0);
    try std.testing.expectEqual(@as(u16, 0x000), zero_rows.start_addr);
    try std.testing.expectEqual(@as(u16, 0x00F), zero_rows.end_addr);

    const overscrolled = display_layout.memoryVisibleRange(999, 64);
    try std.testing.expectEqual(@as(u16, 0xFF0), overscrolled.start_addr);
    try std.testing.expectEqual(@as(u16, 0xFFF), overscrolled.end_addr);
}

test "Display layout text helpers clip and align narrow content" {
    var buf: [32]u8 = undefined;
    const fitted = display_layout.fitText("SOUND MUTED", 40, display_layout.FONT_SIZE_SMALL, &buf);
    try std.testing.expect(std.mem.endsWith(u8, fitted, "..."));
    try std.testing.expect(display_layout.measureMonoTextWidth(fitted, display_layout.FONT_SIZE_SMALL) <= 40);

    const same = display_layout.fitText("CPU", 120, display_layout.FONT_SIZE_SMALL, &buf);
    try std.testing.expectEqualStrings("CPU", same);

    const right_x = display_layout.rightAlignX(10, 100, "TEST", display_layout.FONT_SIZE_SMALL);
    try std.testing.expectEqual(
        @as(i32, 10 + 100 - display_layout.measureMonoTextWidth("TEST", display_layout.FONT_SIZE_SMALL)),
        right_x,
    );
}

fn expectStableLayout(ui: display_layout.LayoutMetrics) !void {
    try expectRectInside(ui.display, ui.screen_w, ui.screen_h);
    try expectRectInside(ui.right_column, ui.screen_w, ui.screen_h);
    try expectRectInside(ui.registers, ui.screen_w, ui.screen_h);
    try expectRectInside(ui.disassembler, ui.screen_w, ui.screen_h);
    try expectRectInside(ui.gutter, ui.screen_w, ui.screen_h);
    try expectRectInside(ui.memory, ui.screen_w, ui.screen_h);
    try expectRectInside(ui.footer, ui.screen_w, ui.screen_h);

    try std.testing.expect(ui.display.x >= display_layout.MARGIN);
    try std.testing.expect(ui.display.right() + display_layout.MARGIN <= ui.right_column.x);
    try std.testing.expect(ui.registers.bottom() + display_layout.MARGIN <= ui.disassembler.y);
    try std.testing.expect(ui.disassembler.bottom() + display_layout.MARGIN <= ui.gutter.y);
    try std.testing.expect(ui.gutter.bottom() + display_layout.MARGIN <= ui.memory.y);
    try std.testing.expect(ui.memory.bottom() + display_layout.MARGIN <= ui.footer.y);
    try std.testing.expect(ui.memory_rows_visible >= 1);
    try std.testing.expect(ui.disasm_rows_visible >= 1);
}

fn expectRectInside(rect: display_layout.PanelRect, screen_w: i32, screen_h: i32) !void {
    try std.testing.expect(rect.x >= 0);
    try std.testing.expect(rect.y >= 0);
    try std.testing.expect(rect.w > 0);
    try std.testing.expect(rect.h > 0);
    try std.testing.expect(rect.right() <= screen_w);
    try std.testing.expect(rect.bottom() <= screen_h);
}
