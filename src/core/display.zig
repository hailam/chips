const rl = @import("raylib");
const cpu_mod = @import("cpu.zig");

pub const SCALE = 10;
pub const WINDOW_WIDTH = cpu_mod.DISPLAY_WIDTH * SCALE;
pub const WINDOW_HEIGHT = cpu_mod.DISPLAY_HEIGHT * SCALE;

pub fn render(display_buffer: *const [cpu_mod.DISPLAY_SIZE]u1) void {
    for (0..cpu_mod.DISPLAY_HEIGHT) |y| {
        for (0..cpu_mod.DISPLAY_WIDTH) |x| {
            const color = if (display_buffer[y * cpu_mod.DISPLAY_WIDTH + x] == 1)
                rl.Color.green
            else
                rl.Color.black;
            rl.drawRectangle(
                @intCast(x * SCALE),
                @intCast(y * SCALE),
                SCALE,
                SCALE,
                color,
            );
        }
    }
}
