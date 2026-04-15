const std = @import("std");
const cpu_mod = @import("cpu.zig");

pub const DISPLAY_BASE_W = cpu_mod.DISPLAY_WIDTH;
pub const DISPLAY_BASE_H = cpu_mod.DISPLAY_HEIGHT;

pub const MARGIN: i32 = 12;
pub const HEADER_H: i32 = 24;
pub const GUTTER_H: i32 = 66;
pub const FONT_SIZE: f32 = 15;
pub const FONT_SIZE_SMALL: f32 = 13;
pub const LINE_H: i32 = 18;
pub const LINE_H_SMALL: i32 = 15;

pub const DEFAULT_DISPLAY_SCALE: i32 = 8;
pub const MIN_DISPLAY_SCALE: i32 = 5;
const MAX_DISPLAY_SCALE: i32 = 16;

pub const RIGHT_MIN_W: i32 = 360;
pub const RIGHT_DEFAULT_W: i32 = 420;
pub const REG_TARGET_H: i32 = 180;
pub const REG_MIN_H: i32 = 168;
pub const DISASM_MIN_H: i32 = HEADER_H + LINE_H * 2 + 8;
pub const MEMORY_MIN_H: i32 = 170;
pub const MEMORY_DEFAULT_H: i32 = 326;
pub const FOOTER_H_SINGLE: i32 = 20;
pub const FOOTER_H_DOUBLE: i32 = 38;

pub const DEFAULT_WINDOW_WIDTH = DISPLAY_BASE_W * DEFAULT_DISPLAY_SCALE + RIGHT_DEFAULT_W + MARGIN * 3;
pub const DEFAULT_WINDOW_HEIGHT = DISPLAY_BASE_H * DEFAULT_DISPLAY_SCALE + GUTTER_H + MEMORY_DEFAULT_H + MARGIN * 4 + FOOTER_H_SINGLE;

pub const MIN_TOP_ROW_H = @max(DISPLAY_BASE_H * MIN_DISPLAY_SCALE, REG_MIN_H + MARGIN + DISASM_MIN_H);
pub const MIN_WINDOW_WIDTH = DISPLAY_BASE_W * MIN_DISPLAY_SCALE + RIGHT_MIN_W + MARGIN * 3;
pub const MIN_WINDOW_HEIGHT = MIN_TOP_ROW_H + GUTTER_H + MEMORY_MIN_H + MARGIN * 4 + FOOTER_H_DOUBLE;

pub const PanelRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: PanelRect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: PanelRect) i32 {
        return self.y + self.h;
    }

    pub fn body(self: PanelRect) PanelRect {
        return .{
            .x = self.x + 1,
            .y = self.y + HEADER_H + 1,
            .w = @max(self.w - 2, 0),
            .h = @max(self.h - HEADER_H - 2, 0),
        };
    }
};

pub const LayoutMetrics = struct {
    screen_w: i32,
    screen_h: i32,
    display_scale: i32,
    footer_two_rows: bool,
    display: PanelRect,
    right_column: PanelRect,
    registers: PanelRect,
    disassembler: PanelRect,
    gutter: PanelRect,
    memory: PanelRect,
    footer: PanelRect,
    top_row_h: i32,
    memory_rows_visible: usize,
    disasm_rows_visible: usize,
};

pub const MemoryRange = struct {
    start_addr: u16,
    end_addr: u16,
};

pub fn computeLayout(screen_w: i32, screen_h: i32) LayoutMetrics {
    const footer_two_rows = wantsTwoRowFooter(screen_w);
    const footer_h = if (footer_two_rows) FOOTER_H_DOUBLE else FOOTER_H_SINGLE;

    var display_scale = MIN_DISPLAY_SCALE;
    var candidate = MIN_DISPLAY_SCALE;
    while (candidate <= MAX_DISPLAY_SCALE) : (candidate += 1) {
        if (layoutFits(screen_w, screen_h, candidate, footer_h)) {
            display_scale = candidate;
        }
    }

    const display_w = DISPLAY_BASE_W * display_scale;
    const display_h = DISPLAY_BASE_H * display_scale;
    const top_row_h = @max(display_h, REG_MIN_H + MARGIN + DISASM_MIN_H);
    const right_w = @max(screen_w - display_w - MARGIN * 3, RIGHT_MIN_W);
    const right_x = MARGIN + display_w + MARGIN;
    const footer_y = screen_h - footer_h;
    const gutter_y = MARGIN + top_row_h + MARGIN;
    const memory_y = gutter_y + GUTTER_H + MARGIN;
    const memory_h = @max(footer_y - MARGIN - memory_y, MEMORY_MIN_H);
    const reg_max_h = top_row_h - DISASM_MIN_H - MARGIN;
    const reg_h = clampI32(REG_TARGET_H, REG_MIN_H, reg_max_h);
    const disasm_h = @max(top_row_h - reg_h - MARGIN, DISASM_MIN_H);

    const display = PanelRect{ .x = MARGIN, .y = MARGIN, .w = display_w, .h = display_h };
    const right_column = PanelRect{ .x = right_x, .y = MARGIN, .w = right_w, .h = top_row_h };
    const registers = PanelRect{ .x = right_x, .y = MARGIN, .w = right_w, .h = reg_h };
    const disassembler = PanelRect{ .x = right_x, .y = registers.bottom() + MARGIN, .w = right_w, .h = disasm_h };
    const gutter = PanelRect{ .x = MARGIN, .y = gutter_y, .w = screen_w - MARGIN * 2, .h = GUTTER_H };
    const memory = PanelRect{ .x = MARGIN, .y = memory_y, .w = screen_w - MARGIN * 2, .h = memory_h };
    const footer = PanelRect{ .x = 0, .y = footer_y, .w = screen_w, .h = footer_h };

    return .{
        .screen_w = screen_w,
        .screen_h = screen_h,
        .display_scale = display_scale,
        .footer_two_rows = footer_two_rows,
        .display = display,
        .right_column = right_column,
        .registers = registers,
        .disassembler = disassembler,
        .gutter = gutter,
        .memory = memory,
        .footer = footer,
        .top_row_h = top_row_h,
        .memory_rows_visible = visibleMemoryRows(memory.h),
        .disasm_rows_visible = visibleDisasmRows(disassembler.h),
    };
}

pub fn visibleMemoryRows(panel_h: i32) usize {
    return @intCast(@max(@divTrunc(panel_h - HEADER_H - LINE_H_SMALL - 12, LINE_H_SMALL), 1));
}

pub fn visibleDisasmRows(panel_h: i32) usize {
    return @intCast(@max(@divTrunc(panel_h - HEADER_H - 8, LINE_H), 1));
}

pub fn clampMemoryScroll(scroll: i32, visible_rows: usize) i32 {
    const total_rows: i32 = @intCast(cpu_mod.CHIP8_MEMORY_SIZE / 16);
    const max_scroll = @max(total_rows - @as(i32, @intCast(visible_rows)), 0);
    return clampI32(scroll, 0, max_scroll);
}

pub fn clampDisasmScroll(scroll: i32, pc: u16, visible_rows: usize) i32 {
    const total_rows: i32 = @intCast(cpu_mod.CHIP8_MEMORY_SIZE / 2);
    const current_row: i32 = @intCast(pc / 2);
    const min_scroll = -current_row;
    const max_scroll = @max(total_rows - @as(i32, @intCast(visible_rows)) - current_row, 0);
    return clampI32(scroll, min_scroll, max_scroll);
}

pub fn memoryVisibleRange(scroll: i32, visible_rows: usize) MemoryRange {
    const total_rows: i32 = @intCast(cpu_mod.CHIP8_MEMORY_SIZE / 16);
    const start_row = clampI32(scroll, 0, total_rows - 1);
    const safe_visible: i32 = @max(@as(i32, @intCast(visible_rows)), 1);
    const end_row = @min(start_row + safe_visible - 1, total_rows - 1);

    return .{
        .start_addr = @intCast(start_row * 16),
        .end_addr = @intCast(end_row * 16 + 0x0F),
    };
}

pub fn measureMonoTextWidth(text: []const u8, size: f32) i32 {
    if (text.len == 0) return 0;
    return @as(i32, @intCast(text.len)) * monoAdvance(size);
}

pub fn fitText(text: []const u8, max_width: i32, size: f32, buf: []u8) []const u8 {
    if (max_width <= 0 or buf.len == 0) return buf[0..0];
    if (measureMonoTextWidth(text, size) <= max_width) return text;

    const advance = monoAdvance(size);
    const max_chars: usize = @intCast(@max(@divTrunc(max_width, advance), 0));
    if (max_chars == 0) return buf[0..0];
    if (max_chars <= 3) {
        const dot_count = @min(max_chars, buf.len);
        @memset(buf[0..dot_count], '.');
        return buf[0..dot_count];
    }

    const keep = @min(text.len, @min(max_chars - 3, buf.len - 3));
    @memcpy(buf[0..keep], text[0..keep]);
    @memcpy(buf[keep .. keep + 3], "...");
    return buf[0 .. keep + 3];
}

pub fn rightAlignX(bounds_x: i32, bounds_w: i32, text: []const u8, size: f32) i32 {
    return bounds_x + @max(bounds_w - measureMonoTextWidth(text, size), 0);
}

fn monoAdvance(size: f32) i32 {
    return @max(@as(i32, @intFromFloat(@round(size * 0.5 + 1.0))), 6);
}

fn wantsTwoRowFooter(screen_w: i32) bool {
    const controls = "SPACE Run/Pause  N Step  BKSP Reset  M Mute  [ ] Speed";
    const status = "Speed 3000Hz  Sound MUTED";
    const comfortable_single_row = measureMonoTextWidth(controls, FONT_SIZE_SMALL) +
        measureMonoTextWidth(status, FONT_SIZE_SMALL) +
        MARGIN * 8 +
        120;
    return screen_w < comfortable_single_row;
}

fn layoutFits(screen_w: i32, screen_h: i32, scale: i32, footer_h: i32) bool {
    const display_w = DISPLAY_BASE_W * scale;
    const display_h = DISPLAY_BASE_H * scale;
    const top_row_h = @max(display_h, REG_MIN_H + MARGIN + DISASM_MIN_H);
    const min_w = display_w + RIGHT_MIN_W + MARGIN * 3;
    const min_h = top_row_h + GUTTER_H + MEMORY_MIN_H + MARGIN * 4 + footer_h;
    return screen_w >= min_w and screen_h >= min_h;
}

fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    if (value < min_value) return min_value;
    if (value > max_value) return max_value;
    return value;
}
