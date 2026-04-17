const assembly = @import("assembly.zig");
const cli = @import("cli.zig");
const std = @import("std");
const chip8_mod = @import("chip8.zig");
const control = @import("control_spec.zig");
const cpu = @import("cpu.zig");
const debugger = @import("debugger.zig");
const display_layout = @import("display_layout.zig");
const emulation = @import("emulation_config.zig");
const persistence = @import("persistence.zig");
const timing = @import("timing.zig");
const trace = @import("trace.zig");

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
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    // Place CLS (0x00E0) at PC
    c.program_counter = 0;
    memory[0] = 0x00;
    memory[1] = 0xE0;

    // Set some display pixels first
    c.display_planes[0][0] = 1;
    c.display_planes[0][100] = 1;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u16, 2), c.program_counter);
    try std.testing.expectEqual(@as(u2, 0), c.compositePixel(0, 0));
    try std.testing.expectEqual(@as(u1, 0), c.display_planes[0][100]);
    try std.testing.expect(c.draw_flag);
}

test "Jump to address" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x12;
    memory[1] = 0x34;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u16, 0x234), c.program_counter);
}

test "Set VX = KK" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x61;
    memory[1] = 0xAB;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u8, 0xAB), c.registers[1]);
    try std.testing.expectEqual(@as(u16, 2), c.program_counter);
}

test "Add VX, KK" {
    var c = cpu.CPU.init();
    c.registers[2] = 0x10;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x72;
    memory[1] = 0xCD;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u8, 0xDD), c.registers[2]);
    try std.testing.expectEqual(@as(u16, 2), c.program_counter);
}

test "Add VX, KK wraps on overflow" {
    var c = cpu.CPU.init();
    c.registers[0] = 0xFF;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x70; // ADD V0, 0x02
    memory[1] = 0x02;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u8, 0x01), c.registers[0]);
}

test "ADD VX, VY with carry" {
    var c = cpu.CPU.init();
    c.registers[0] = 0xFF;
    c.registers[1] = 0x02;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x80; // ADD V0, V1
    memory[1] = 0x14;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u8, 0x01), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 1), c.registers[0xF]); // carry
}

test "SUB VX, VY with borrow" {
    var c = cpu.CPU.init();
    c.registers[0] = 0x01;
    c.registers[1] = 0x02;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x80; // SUB V0, V1
    memory[1] = 0x15;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u8, 0xFF), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 0), c.registers[0xF]); // borrow
}

test "SUB VX, VY no borrow" {
    var c = cpu.CPU.init();
    c.registers[0] = 0x05;
    c.registers[1] = 0x02;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x80;
    memory[1] = 0x15;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u8, 0x03), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 1), c.registers[0xF]); // no borrow
}

test "BCD store" {
    var c = cpu.CPU.init();
    c.registers[0] = 123;
    c.index_register = 0x300;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0xF0; // LD B, V0
    memory[1] = 0x33;

    try execModern(&c, &memory);

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
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    // Store V0..V2 (FX55 where X=2)
    c.program_counter = 0;
    memory[0] = 0xF2;
    memory[1] = 0x55;

    try execModern(&c, &memory);

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

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u8, 0xAA), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), c.registers[1]);
    try std.testing.expectEqual(@as(u8, 0xCC), c.registers[2]);
}

test "Draw sprite" {
    var c = cpu.CPU.init();
    c.registers[0] = 0; // X position
    c.registers[1] = 0; // Y position
    c.index_register = 0x300;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    // Sprite: one row, 0xF0 = 11110000
    memory[0x300] = 0xF0;

    c.program_counter = 0;
    memory[0] = 0xD0; // DRW V0, V1, 1
    memory[1] = 0x11;

    try execModern(&c, &memory);

    // First 4 pixels should be on
    try std.testing.expectEqual(@as(u2, 1), c.compositePixel(0, 0));
    try std.testing.expectEqual(@as(u2, 1), c.compositePixel(1, 0));
    try std.testing.expectEqual(@as(u2, 1), c.compositePixel(2, 0));
    try std.testing.expectEqual(@as(u2, 1), c.compositePixel(3, 0));
    // Next 4 should be off
    try std.testing.expectEqual(@as(u2, 0), c.compositePixel(4, 0));
    // No collision
    try std.testing.expectEqual(@as(u8, 0), c.registers[0xF]);
    try std.testing.expect(c.draw_flag);
}

test "Draw sprite collision" {
    var c = cpu.CPU.init();
    c.registers[0] = 0;
    c.registers[1] = 0;
    c.index_register = 0x300;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    memory[0x300] = 0x80; // 10000000

    // Set logical pixel (0,0) already on in lores backing space.
    c.display_planes[0][0] = 1;
    c.display_planes[0][1] = 1;
    c.display_planes[0][cpu.DISPLAY_HIRES_WIDTH] = 1;
    c.display_planes[0][cpu.DISPLAY_HIRES_WIDTH + 1] = 1;

    c.program_counter = 0;
    memory[0] = 0xD0;
    memory[1] = 0x11;

    try execModern(&c, &memory);

    // Pixel 0 should be XORed off
    try std.testing.expectEqual(@as(u2, 0), c.compositePixel(0, 0));
    // Collision detected
    try std.testing.expectEqual(@as(u8, 1), c.registers[0xF]);
}

test "Call and return subroutine" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    // CALL 0x400
    c.program_counter = 0x200;
    memory[0x200] = 0x24;
    memory[0x201] = 0x00;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u16, 0x400), c.program_counter);
    try std.testing.expectEqual(@as(u16, 1), c.stack_pointer);
    try std.testing.expectEqual(@as(u16, 0x202), c.stack[0]); // return address

    // RET
    memory[0x400] = 0x00;
    memory[0x401] = 0xEE;

    try execModern(&c, &memory);

    try std.testing.expectEqual(@as(u16, 0x202), c.program_counter);
    try std.testing.expectEqual(@as(u16, 0), c.stack_pointer);
}

test "Skip if equal" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    c.registers[0] = 0x42;

    // SE V0, 0x42 - should skip
    c.program_counter = 0;
    memory[0] = 0x30;
    memory[1] = 0x42;

    try execModern(&c, &memory);
    try std.testing.expectEqual(@as(u16, 4), c.program_counter);

    // SE V0, 0x99 - should not skip
    c.program_counter = 0;
    memory[0] = 0x30;
    memory[1] = 0x99;

    try execModern(&c, &memory);
    try std.testing.expectEqual(@as(u16, 2), c.program_counter);
}

test "Font sprite location" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.registers[0] = 0x0A; // character 'A'
    c.program_counter = 0;
    memory[0] = 0xF0; // LD F, V0
    memory[1] = 0x29;

    try execModern(&c, &memory);

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

test "Display layout keeps register and middle-panel content inside panel bodies" {
    const sizes = [_]display_layout.LayoutMetrics{
        display_layout.computeLayout(display_layout.MIN_WINDOW_WIDTH, display_layout.MIN_WINDOW_HEIGHT),
        display_layout.computeLayout(display_layout.DEFAULT_WINDOW_WIDTH, display_layout.DEFAULT_WINDOW_HEIGHT),
        display_layout.computeLayout(display_layout.DEFAULT_WINDOW_WIDTH + 320, display_layout.DEFAULT_WINDOW_HEIGHT + 240),
    };

    for (sizes) |ui| {
        try std.testing.expect(ui.registers.h >= display_layout.REG_CONTENT_MIN_H);
        try std.testing.expect(ui.gutter.h >= display_layout.GUTTER_CONTENT_MIN_H);

        const watch_rows_visible = @divTrunc(ui.gutter.body().h - 6, display_layout.LINE_H_SMALL);
        try std.testing.expect(watch_rows_visible >= 10);
    }
}

test "Display layout scroll clamps are derived from visible rows" {
    try std.testing.expectEqual(@as(i32, 0), display_layout.clampMemoryScroll(-4, 12));
    try std.testing.expectEqual(@as(i32, @intCast(cpu.CHIP8_MEMORY_SIZE / 16 - 12)), display_layout.clampMemoryScroll(99999, 12));

    const visible_rows: usize = 10;
    const min_scroll = display_layout.clampDisasmScroll(-999, 0x200, visible_rows);
    const max_scroll = display_layout.clampDisasmScroll(std.math.maxInt(i32), 0x200, visible_rows);
    try std.testing.expectEqual(@as(i32, -256), min_scroll);
    try std.testing.expectEqual(@as(i32, @intCast(cpu.CHIP8_MEMORY_SIZE / 2 - visible_rows - 0x200 / 2)), max_scroll);

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

    const overscrolled = display_layout.memoryVisibleRange(display_layout.clampMemoryScroll(999999, 64), 64);
    try std.testing.expectEqual(@as(u16, 0xFC00), overscrolled.start_addr);
    try std.testing.expectEqual(@as(u16, 0xFFFF), overscrolled.end_addr);
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

test "Control spec canonical CHIP-8 bindings stay stable" {
    try std.testing.expectEqual(@as(usize, 16), control.canonical_chip8_bindings.len);
    try expectBinding(control.canonical_chip8_bindings[0], 0x0, .x);
    try expectBinding(control.canonical_chip8_bindings[1], 0x1, .one);
    try expectBinding(control.canonical_chip8_bindings[5], 0x5, .w);
    try expectBinding(control.canonical_chip8_bindings[7], 0x7, .a);
    try expectBinding(control.canonical_chip8_bindings[8], 0x8, .s);
    try expectBinding(control.canonical_chip8_bindings[9], 0x9, .d);
    try expectBinding(control.canonical_chip8_bindings[15], 0xF, .v);
}

test "Control spec arrow aliases fold onto CHIP-8 movement keys" {
    try std.testing.expectEqual(@as(usize, 4), control.arrow_alias_bindings.len);
    try expectBinding(control.arrow_alias_bindings[0], 0x5, .up);
    try expectBinding(control.arrow_alias_bindings[1], 0x7, .left);
    try expectBinding(control.arrow_alias_bindings[2], 0x8, .down);
    try expectBinding(control.arrow_alias_bindings[3], 0x9, .right);
}

test "Control spec fold pressed keys merges canonical and alias inputs" {
    var pressed = [_]bool{false} ** (@intFromEnum(control.PhysicalKey.right_bracket) + 1);

    pressed[control.physicalKeyIndex(.w)] = true;
    var keys = control.foldPressedChip8Keys(&pressed);
    try std.testing.expect(keys[0x5]);
    try std.testing.expect(!keys[0x7]);

    pressed = [_]bool{false} ** (@intFromEnum(control.PhysicalKey.right_bracket) + 1);
    pressed[control.physicalKeyIndex(.up)] = true;
    keys = control.foldPressedChip8Keys(&pressed);
    try std.testing.expect(keys[0x5]);
    try std.testing.expect(!keys[0x8]);

    pressed = [_]bool{false} ** (@intFromEnum(control.PhysicalKey.right_bracket) + 1);
    pressed[control.physicalKeyIndex(.w)] = true;
    pressed[control.physicalKeyIndex(.up)] = true;
    keys = control.foldPressedChip8Keys(&pressed);
    try std.testing.expect(keys[0x5]);
    try std.testing.expectEqual(@as(usize, 1), countPressedKeys(keys));
}

test "Timing speed action uses hz step and clamps to runtime bounds" {
    try std.testing.expectEqual(@as(i32, 480), timing.applySpeedAction(600, .slower));
    try std.testing.expectEqual(@as(i32, 720), timing.applySpeedAction(600, .faster));
    try std.testing.expectEqual(@as(i32, timing.CPU_HZ_MIN), timing.applySpeedAction(timing.CPU_HZ_MIN, .slower));
    try std.testing.expectEqual(@as(i32, timing.CPU_HZ_MAX), timing.applySpeedAction(timing.CPU_HZ_MAX, .faster));
}

test "Timing startup defaults scale with profile and upgrade legacy 600hz saves" {
    try std.testing.expectEqual(@as(i32, timing.CPU_HZ_DEFAULT), timing.defaultCpuHzForProfile(.modern));
    try std.testing.expectEqual(@as(i32, timing.CPU_HZ_SCHIP_DEFAULT), timing.defaultCpuHzForProfile(.schip_11));
    try std.testing.expectEqual(@as(i32, timing.CPU_HZ_XO_DEFAULT), timing.defaultCpuHzForProfile(.octo_xo));

    try std.testing.expectEqual(@as(i32, timing.CPU_HZ_SCHIP_DEFAULT), timing.preferredStartupCpuHz(null, .schip_11));
    try std.testing.expectEqual(@as(i32, timing.CPU_HZ_XO_DEFAULT), timing.preferredStartupCpuHz(@as(i32, timing.CPU_HZ_DEFAULT), .octo_xo));
    try std.testing.expectEqual(@as(i32, 1800), timing.preferredStartupCpuHz(1800, .octo_xo));
}

test "Control spec footer copy is shared and layout uses it" {
    try std.testing.expectEqualStrings("SPACE Run/Pause  N/Shift+N Step/Over  B Break  O Recent  F2 Source  F5/F9 Save/Load  [ ] Speed  M Mute  P Profile  G FX  F11 Full", control.controls_label);
    try std.testing.expectEqualStrings("W/A/S/D or arrows play  Tab switches trace/cycle/watches  ; edits watch  Wheel over Memory, Code, or Trace to scroll", control.controls_hint);

    const narrow_layout = display_layout.computeLayout(display_layout.MIN_WINDOW_WIDTH, display_layout.MIN_WINDOW_HEIGHT);
    const wide_layout = display_layout.computeLayout(display_layout.DEFAULT_WINDOW_WIDTH + 960, display_layout.DEFAULT_WINDOW_HEIGHT);
    try std.testing.expect(narrow_layout.footer_two_rows);
    try std.testing.expect(!wide_layout.footer_two_rows);
}

test "Timing accumulator decouples cpu cycles from timer ticks" {
    var state = timing.TimingState.init();
    const a = timing.advance(&state, 1.0 / 120.0);
    try std.testing.expectEqual(@as(usize, 5), a.cpu_cycles);
    try std.testing.expectEqual(@as(usize, 0), a.timer_ticks);

    const b = timing.advance(&state, 1.0 / 120.0);
    try std.testing.expectEqual(@as(usize, 5), b.cpu_cycles);
    try std.testing.expectEqual(@as(usize, 1), b.timer_ticks);
}

test "Timing accumulator caps large frame gaps" {
    var state = timing.TimingState.init();
    const result = timing.advance(&state, 1.0);
    try std.testing.expectEqual(@as(f64, timing.DEFAULT_FRAME_DT_CAP_S), result.frame_dt_s);
    try std.testing.expectEqual(@as(usize, 150), result.cpu_cycles);
    try std.testing.expectEqual(@as(usize, 15), result.timer_ticks);
}

test "Emulation profiles expose expected quirk flags" {
    const modern = emulation.profileQuirks(.modern);
    try std.testing.expect(!modern.shift_uses_vy);
    try std.testing.expect(!modern.load_store_increment_i);
    try std.testing.expect(modern.logic_ops_clear_vf);
    try std.testing.expect(modern.draw_wrap);
    try std.testing.expect(!modern.jump_uses_vx);

    const vip = emulation.profileQuirks(.vip_legacy);
    try std.testing.expect(vip.shift_uses_vy);
    try std.testing.expect(vip.load_store_increment_i);
    try std.testing.expect(!vip.logic_ops_clear_vf);
    try std.testing.expect(!vip.draw_wrap);
    try std.testing.expect(!vip.jump_uses_vx);
}

test "Legacy shift quirk uses VY as the source register" {
    var c = cpu.CPU.init();
    c.registers[1] = 0xFF;
    c.registers[2] = 0x08;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x81;
    memory[1] = 0x26;
    try c.executeInstruction(&memory, emulation.profileQuirks(.vip_legacy));

    try std.testing.expectEqual(@as(u8, 0x04), c.registers[1]);
    try std.testing.expectEqual(@as(u8, 0), c.registers[0xF]);
}

test "Legacy load store quirk increments I after FX55 and FX65" {
    var c = cpu.CPU.init();
    c.index_register = 0x300;
    c.registers[0] = 0xAA;
    c.registers[1] = 0xBB;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0xF1;
    memory[1] = 0x55;
    try c.executeInstruction(&memory, emulation.profileQuirks(.vip_legacy));
    try std.testing.expectEqual(@as(u16, 0x302), c.index_register);

    c.program_counter = 0;
    c.index_register = 0x300;
    c.registers[0] = 0;
    c.registers[1] = 0;
    memory[0] = 0xF1;
    memory[1] = 0x65;
    try c.executeInstruction(&memory, emulation.profileQuirks(.vip_legacy));
    try std.testing.expectEqual(@as(u16, 0x302), c.index_register);
}

test "Legacy logic ops preserve VF instead of clearing it" {
    var c = cpu.CPU.init();
    c.registers[0] = 0xF0;
    c.registers[1] = 0x0F;
    c.registers[0xF] = 0xAB;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0x80;
    memory[1] = 0x11;
    try c.executeInstruction(&memory, emulation.profileQuirks(.vip_legacy));

    try std.testing.expectEqual(@as(u8, 0xFF), c.registers[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), c.registers[0xF]);
}

test "Draw wrap quirk changes edge behavior" {
    var modern = cpu.CPU.init();
    modern.registers[0] = 63;
    modern.registers[1] = 31;
    modern.index_register = 0x300;
    var modern_memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    modern.program_counter = 0;
    modern_memory[0x300] = 0xC0;
    modern_memory[0] = 0xD0;
    modern_memory[1] = 0x11;
    try execModern(&modern, &modern_memory);
    try std.testing.expectEqual(@as(u2, 1), modern.compositePixel(63, 31));
    try std.testing.expectEqual(@as(u2, 1), modern.compositePixel(0, 31));

    var legacy = cpu.CPU.init();
    legacy.registers[0] = 64;
    legacy.registers[1] = 31;
    legacy.index_register = 0x300;
    var legacy_memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    legacy.program_counter = 0;
    legacy_memory[0x300] = 0x80;
    legacy_memory[0] = 0xD0;
    legacy_memory[1] = 0x11;
    try legacy.executeInstruction(&legacy_memory, emulation.profileQuirks(.vip_legacy));
    try std.testing.expectEqual(@as(u2, 0), legacy.compositePixel(0, 31));
}

test "Jump uses VX quirk changes BNNN base register" {
    var c = cpu.CPU.init();
    c.registers[0] = 1;
    c.registers[2] = 5;
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    c.program_counter = 0;
    memory[0] = 0xB2;
    memory[1] = 0x34;

    var quirks = emulation.profileQuirks(.modern);
    quirks.jump_uses_vx = true;
    try c.executeInstruction(&memory, quirks);

    try std.testing.expectEqual(@as(u16, 0x239), c.program_counter);
}

test "Persistence app state round-trips through JSON" {
    var app_state = persistence.AppState.init(std.testing.allocator);
    defer app_state.deinit();

    app_state.global_settings = .{ .palette = .amber, .effect = .scanlines, .fullscreen = true, .volume = 0.6 };
    try app_state.upsertRecentRom("/tmp/snake.ch8", "snake.ch8", "abc123", 42);
    try app_state.upsertRomPreference("abc123", "/tmp/snake.ch8", .vip_legacy, 720, 3);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try persistence.serializeAppState(&app_state, &writer.writer);

    var roundtrip = persistence.AppState.init(std.testing.allocator);
    defer roundtrip.deinit();
    try persistence.deserializeAppState(std.testing.allocator, writer.written(), &roundtrip);

    try std.testing.expectEqual(@as(usize, 1), roundtrip.recent_roms.items.len);
    try std.testing.expectEqualStrings("/tmp/snake.ch8", roundtrip.recent_roms.items[0].path);
    try std.testing.expectEqual(.vip_legacy, roundtrip.rom_preferences.items[0].quirk_profile);
    try std.testing.expectEqual(@as(i32, 720), roundtrip.rom_preferences.items[0].cpu_hz_target);
    try std.testing.expectEqual(persistence.DisplayPalette.amber, roundtrip.global_settings.palette);
}

test "Persistence save state envelope round-trips and rejects bad metadata" {
    var chip8 = chip8_mod.Chip8.initWithConfig(emulation.EmulationConfig.init(.vip_legacy));
    chip8.cpu.registers[0] = 0xAA;
    chip8.memory[0x300] = 0xBB;

    const envelope = persistence.SaveStateEnvelope{
        .rom_sha1 = [_]u8{0x11} ** 20,
        .quirk_profile = .vip_legacy,
        .chip8_state = chip8.snapshot(),
        .cpu_hz_target = 720,
        .paused_state = true,
    };

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try persistence.serializeSaveStateEnvelope(&envelope, &writer.writer);

    const loaded = try persistence.deserializeSaveStateEnvelope(writer.written());
    try std.testing.expectEqual(@as(u8, 0xAA), loaded.chip8_state.cpu.registers[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), loaded.chip8_state.memory[0x300]);
    try std.testing.expectEqual(@as(i32, 720), loaded.cpu_hz_target);

    var corrupted = try std.testing.allocator.dupe(u8, writer.written());
    defer std.testing.allocator.free(corrupted);
    corrupted[0] = 'B';
    try std.testing.expectError(error.InvalidSaveStateMagic, persistence.deserializeSaveStateEnvelope(corrupted));
}

test "CPU trace captures key wait, draw, memory transfer, and control flow micro-ops" {
    var c = cpu.CPU.init();
    var memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;

    c.program_counter = 0;
    memory[0] = 0xFF;
    memory[1] = 0x0A;
    try execModern(&c, &memory);
    try std.testing.expectEqual(debugger.TraceTag.key, c.last_trace.tag);
    try std.testing.expect(c.last_trace.waits_for_key);
    try std.testing.expectEqual(debugger.MicroOpKind.wait_key, c.last_trace.micro_ops[c.last_trace.micro_op_len - 1].kind);

    c = cpu.CPU.init();
    memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    c.program_counter = 0;
    c.registers[1] = 4;
    c.registers[2] = 6;
    c.index_register = 0x300;
    memory[0] = 0xD1;
    memory[1] = 0x25;
    memory[0x300] = 0xF0;
    try execModern(&c, &memory);
    try std.testing.expectEqual(debugger.TraceTag.draw, c.last_trace.tag);
    switch (c.last_trace.destination) {
        .display => |display_focus| {
            try std.testing.expectEqual(@as(u8, 8), display_focus.w);
            try std.testing.expectEqual(@as(u8, 5), display_focus.h);
            try std.testing.expect(display_focus.wraps);
            try std.testing.expect(!display_focus.full_screen);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(traceContainsMicroOp(c.last_trace, .read_mem_range));
    try std.testing.expect(traceContainsMicroOp(c.last_trace, .draw_sprite));

    c = cpu.CPU.init();
    memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    c.program_counter = 0;
    memory[0] = 0x00;
    memory[1] = 0xE0;
    try execModern(&c, &memory);
    switch (c.last_trace.destination) {
        .display => |display_focus| {
            try std.testing.expect(display_focus.full_screen);
            try std.testing.expectEqual(@as(u8, cpu.DISPLAY_WIDTH), display_focus.w);
            try std.testing.expectEqual(@as(u8, cpu.DISPLAY_HEIGHT), display_focus.h);
        },
        else => return error.TestExpectedEqual,
    }

    c = cpu.CPU.init();
    memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    c.program_counter = 0;
    c.index_register = 0x320;
    c.registers[0] = 0xAA;
    c.registers[1] = 0xBB;
    memory[0] = 0xF1;
    memory[1] = 0x55;
    try execModern(&c, &memory);
    try std.testing.expectEqual(debugger.TraceTag.store, c.last_trace.tag);
    try std.testing.expectEqual(debugger.MicroOpKind.write_mem_range, c.last_trace.micro_ops[c.last_trace.micro_op_len - 1].kind);

    c = cpu.CPU.init();
    memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    c.program_counter = 0;
    c.stack_pointer = 1;
    c.stack[0] = 0x456;
    memory[0] = 0x00;
    memory[1] = 0xEE;
    try execModern(&c, &memory);
    try std.testing.expectEqual(debugger.TraceTag.ret, c.last_trace.tag);
    try std.testing.expectEqual(debugger.MicroOpKind.pop_stack, c.last_trace.micro_ops[c.last_trace.micro_op_len - 1].kind);

    c = cpu.CPU.init();
    memory = [_]u8{0} ** cpu.CHIP8_MEMORY_SIZE;
    c.program_counter = 0;
    memory[0] = 0x12;
    memory[1] = 0x34;
    try execModern(&c, &memory);
    try std.testing.expectEqual(debugger.TraceTag.jump, c.last_trace.tag);
    try std.testing.expectEqual(debugger.MicroOpKind.branch_pc, c.last_trace.micro_ops[c.last_trace.micro_op_len - 1].kind);
}

test "Debugger breakpoint pause, trace ring, and watch parsing are stable" {
    var dbg = debugger.DebuggerState.init();
    dbg.toggleBreakpoint(0x222);
    dbg.beginResume(0x200);

    try std.testing.expect(!dbg.shouldPauseBeforeExecute(0x200));
    try std.testing.expect(dbg.shouldPauseBeforeExecute(0x222));

    for (0..140) |i| {
        dbg.recordTrace(.{
            .pc = @intCast(0x200 + i * 2),
            .opcode_hi = @intCast(0xA000 + i),
            .tag = .fetch,
        });
    }
    try std.testing.expectEqual(@as(usize, debugger.TRACE_CAPACITY), dbg.trace_len);
    const newest = dbg.traceEntryFromNewest(0).?;
    try std.testing.expectEqual(@as(u16, 0x200 + 139 * 2), newest.pc);

    try std.testing.expectEqual(@as(u16, 0x2AF), try debugger.parseWatchAddress("2AF"));
    try std.testing.expectError(error.InvalidWatchAddress, debugger.parseWatchAddress("ZZZZ"));
}

test "Debugger trace selection disables follow and End-style resume snaps back live" {
    var dbg = debugger.DebuggerState.init();
    for (0..6) |i| {
        dbg.recordTrace(.{
            .pc = @intCast(0x200 + i * 2),
            .opcode_hi = @intCast(0x6000 + i),
            .tag = .load,
        });
    }

    try std.testing.expect(dbg.trace_follow_live);
    try std.testing.expectEqual(@as(?usize, 0), dbg.activeTraceIndex());

    dbg.scrollTrace(2, 3);
    try std.testing.expect(!dbg.trace_follow_live);
    try std.testing.expectEqual(@as(usize, 2), dbg.trace_scroll);
    try std.testing.expectEqual(@as(?usize, 2), dbg.activeTraceIndex());

    dbg.selectTraceIndex(4, 3);
    try std.testing.expectEqual(@as(?usize, 4), dbg.activeTraceIndex());

    dbg.resumeTraceFollow();
    try std.testing.expect(dbg.trace_follow_live);
    try std.testing.expectEqual(@as(usize, 0), dbg.trace_scroll);
    try std.testing.expectEqual(@as(?usize, 0), dbg.activeTraceIndex());
}

test "Trace lane mapping is deterministic and suppresses same-lane connectors" {
    const cross_lane = trace.microOpConnector(.{
        .kind = .read_mem_range,
        .source = trace.memoryEndpoint(0x300, 4),
        .destination = trace.registersEndpoint(0, 4),
    }).?;
    try std.testing.expectEqual(trace.Lane.memory, cross_lane.from);
    try std.testing.expectEqual(trace.Lane.registers, cross_lane.to);

    try std.testing.expectEqual(null, trace.microOpConnector(.{
        .kind = .write_reg,
        .source = trace.registersEndpoint(1, 1),
        .destination = trace.registersEndpoint(2, 1),
    }));

    try std.testing.expectEqual(null, trace.microOpConnector(.{
        .kind = .decode_opcode,
        .source = .decode,
        .destination = .decode,
    }));
}

test "Annotated assembly export includes header, labels, comments, and line mapping" {
    const rom = [_]u8{
        0x12, 0x06, // JP 206
        0x61, 0x08, // LD V1, 8
        0xF0, 0x00, // unknown => DB
        0x62, 0x04, // LD V2, 4
    };

    var exported = try assembly.exportAnnotatedSource(std.testing.allocator, .{
        .rom_name = "test.ch8",
        .sha1_hex = "deadbeef",
        .profile = .modern,
    }, &rom);
    defer exported.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, exported.source, "; ROM: test.ch8") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported.source, "ORG 0x200") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported.source, "loc_0206:") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported.source, "JP   loc_0206") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported.source, "DB   0xF0, 0x00") != null);
    try std.testing.expectEqual(@as(?usize, 8), exported.lineForAddress(0x200));
    try std.testing.expectEqual(@as(?usize, 12), exported.lineForAddress(0x206));
}

test "Profile inference ignores bare 0000 data but detects XO opcodes" {
    const mostly_zero = [_]u8{
        0x12, 0x06,
        0x00, 0x00,
        0x00, 0x00,
        0x61, 0x08,
    };
    try std.testing.expectEqual(emulation.QuirkProfile.modern, assembly.inferProfile(&mostly_zero));

    const xo_rom = [_]u8{
        0xF2, 0x01,
        0xF0, 0x00, 0x10, 0x00,
    };
    try std.testing.expectEqual(emulation.QuirkProfile.octo_xo, assembly.inferProfile(&xo_rom));
}

test "Assembler round-trips annotated export back to identical ROM bytes" {
    const rom = [_]u8{
        0x61, 0x08,
        0x62, 0x04,
        0xD1, 0x25,
        0x12, 0x00,
    };

    var exported = try assembly.exportAnnotatedSource(std.testing.allocator, .{
        .rom_name = "roundtrip.ch8",
        .sha1_hex = "bead",
        .profile = .modern,
    }, &rom);
    defer exported.deinit(std.testing.allocator);

    var assembled = try assembly.assembleSource(std.testing.allocator, exported.source);
    defer assembled.deinit(std.testing.allocator);

    try std.testing.expect(assembled.succeeded());
    try std.testing.expectEqualSlices(u8, &rom, assembled.bytes.?);
}

test "Assembler diagnostics catch duplicate labels, undefined labels, malformed ORG, and invalid DB" {
    const bad_source =
        \\ORG 0x300
        \\start:
        \\start:
        \\JP missing_label
        \\DB 0x100
    ;

    var result = try assembly.assembleSource(std.testing.allocator, bad_source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.succeeded());
    try std.testing.expect(result.diagnostics.items.len >= 3);
}

test "CLI parses subcommands and bare ROM alias" {
    try std.testing.expectEqualDeep(@as(cli.Command, .{ .run = .{ .rom_path = null, .profile = null } }), try cli.parseArgs(&.{}));
    try std.testing.expectEqualDeep(@as(cli.Command, .{ .run = .{ .rom_path = "roms/snake.ch8", .profile = null } }), try cli.parseArgs(&.{ "roms/snake.ch8" }));
    try std.testing.expectEqualDeep(@as(cli.Command, .{ .run = .{ .rom_path = "roms/ibm_logo.ch8", .profile = null } }), try cli.parseArgs(&.{ "run", "roms/ibm_logo.ch8" }));
    try std.testing.expectEqualDeep(@as(cli.Command, .{ .run = .{ .rom_path = "roms/snake.ch8", .profile = .octo_xo } }), try cli.parseArgs(&.{ "run", "roms/snake.ch8", "--profile", "octo_xo" }));
    try std.testing.expectEqualDeep(@as(cli.Command, .{ .disasm = .{ .rom_path = "roms/snake.ch8", .output_path = "snake.asm", .profile = .xo_chip } }), try cli.parseArgs(&.{ "disasm", "roms/snake.ch8", "-o", "snake.asm", "--profile", "xo_chip" }));
    try std.testing.expectEqualDeep(@as(cli.Command, .{ .assemble = .{ .source_path = "snake.ch8.asm", .output_path = null } }), try cli.parseArgs(&.{ "asm", "snake.ch8.asm" }));
    try std.testing.expectEqualDeep(@as(cli.Command, .{ .check = .{ .source_path = "snake.ch8.asm" } }), try cli.parseArgs(&.{ "check", "snake.ch8.asm" }));
    try std.testing.expectError(cli.ParseError.UnexpectedArgument, cli.parseArgs(&.{ "disasm", "rom.ch8", "extra" }));
    try std.testing.expectError(cli.ParseError.InvalidProfile, cli.parseArgs(&.{ "run", "rom.ch8", "--profile", "nope" }));
}

test "CLI derives assembler output path and VS Code goto target" {
    const output_path = try cli.defaultAsmOutputPathAlloc(std.testing.allocator, "/tmp/snake.ch8.asm");
    defer std.testing.allocator.free(output_path);
    try std.testing.expectEqualStrings("/tmp/snake.ch8", output_path);

    const goto_target = try cli.buildEditorGotoTargetAlloc(std.testing.allocator, "/tmp/snake.ch8.asm", 42);
    defer std.testing.allocator.free(goto_target);
    try std.testing.expectEqualStrings("/tmp/snake.ch8.asm:42", goto_target);
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

fn expectBinding(binding: control.Chip8Binding, chip8_index: usize, physical_key: control.PhysicalKey) !void {
    try std.testing.expectEqual(chip8_index, binding.chip8_index);
    try std.testing.expectEqual(physical_key, binding.physical_key);
}

fn countPressedKeys(keys: [16]bool) usize {
    var count: usize = 0;
    for (keys) |pressed| {
        if (pressed) count += 1;
    }
    return count;
}

fn traceContainsMicroOp(entry: debugger.TraceEntry, kind: debugger.MicroOpKind) bool {
    for (entry.micro_ops[0..entry.micro_op_len]) |micro_op| {
        if (micro_op.kind == kind) return true;
    }
    return false;
}

fn execModern(c: *cpu.CPU, memory: *[cpu.CHIP8_MEMORY_SIZE]u8) !void {
    try c.executeInstruction(memory, emulation.profileQuirks(.modern));
}
