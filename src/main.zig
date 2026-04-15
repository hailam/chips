const std = @import("std");
const rl = @import("raylib");
const Chip8 = @import("core/chip8.zig").Chip8;
const display = @import("core/display.zig");
const input = @import("core/input.zig");
const sound = @import("core/sound.zig");

pub fn main(init: std.process.Init) !void {
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.skip();
    const rom_path = args_iter.next() orelse {
        std.log.err("Usage: chip8 <rom_path>", .{});
        return;
    };

    const rom_data = try std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, init.gpa, .limited(4096 - 0x200));
    defer init.gpa.free(rom_data);

    var chip8 = Chip8.init();
    chip8.cpu.seedRng(@as(u64, @truncate(@intFromPtr(&chip8))));
    try chip8.loadRom(rom_data);

    rl.initWindow(display.WINDOW_WIDTH, display.WINDOW_HEIGHT, "Chip-8 Emulator");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    display.initFont();
    defer display.deinitFont();

    sound.init();
    defer sound.deinit();

    var state: display.EmulatorState = .running;
    var instructions_per_frame: i32 = 10;
    var mem_scroll: i32 = 0x20;
    var muted: bool = false;

    while (!rl.windowShouldClose()) {
        // Controls
        if (rl.isKeyPressed(.space)) state = if (state == .running) .paused else .running;
        if (rl.isKeyPressed(.n) and state == .paused) state = .stepping;
        if (rl.isKeyPressed(.backspace)) {
            chip8 = Chip8.init();
            chip8.cpu.seedRng(@as(u64, @truncate(@intFromPtr(&chip8))));
            chip8.loadRom(rom_data) catch {};
            state = .paused;
        }
        if (rl.isKeyPressed(.up)) instructions_per_frame = @min(instructions_per_frame + 2, 50);
        if (rl.isKeyPressed(.down)) instructions_per_frame = @max(instructions_per_frame - 2, 1);
        if (rl.isKeyPressed(.m)) muted = !muted;

        // Input
        chip8.cpu.keys = input.pollKeys();

        // FX0A wait-for-key
        if (chip8.cpu.waiting_for_key) {
            for (chip8.cpu.keys, 0..) |pressed, i| {
                if (pressed) {
                    chip8.cpu.registers[chip8.cpu.key_register] = @intCast(i);
                    chip8.cpu.waiting_for_key = false;
                    chip8.cpu.program_counter += 2;
                    break;
                }
            }
        }

        // Execute
        if (state == .running or state == .stepping) {
            const count: usize = if (state == .stepping) 1 else @intCast(instructions_per_frame);
            for (0..count) |_| {
                if (!chip8.cpu.waiting_for_key) chip8.update() catch {};
            }
            chip8.cpu.snapshotRegisters();
            if (state == .stepping) state = .paused;
        }

        if (state == .running) chip8.tickTimers();

        // Render
        rl.beginDrawing();
        rl.clearBackground(display.BG_WINDOW_PUB);
        display.renderAll(&chip8.cpu, &chip8.memory, state, instructions_per_frame * 60, &mem_scroll, muted);
        rl.endDrawing();
    }
}
