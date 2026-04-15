const std = @import("std");
const rl = @import("raylib");
const Chip8 = @import("core/chip8.zig").Chip8;
const display = @import("core/display.zig");
const input = @import("core/input.zig");
const sound = @import("core/sound.zig");

const INSTRUCTIONS_PER_FRAME = 10;

pub fn main(init: std.process.Init) !void {
    // Parse ROM path from args
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.skip(); // skip executable name
    const rom_path = args_iter.next() orelse {
        std.log.err("Usage: chip8 <rom_path>", .{});
        return;
    };

    // Load ROM
    const rom_data = try std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, init.gpa, .limited(4096 - 0x200));
    defer init.gpa.free(rom_data);

    // Init Chip8
    var chip8 = Chip8.init();
    chip8.cpu.seedRng(@as(u64, @truncate(@intFromPtr(&chip8))));
    try chip8.loadRom(rom_data);

    // Init raylib window
    rl.initWindow(display.WINDOW_WIDTH, display.WINDOW_HEIGHT, "Chip-8 Emulator");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    // Init audio
    sound.init();
    defer sound.deinit();

    // Main loop
    while (!rl.windowShouldClose()) {
        // Input
        chip8.cpu.keys = input.pollKeys();

        // Handle FX0A (wait for key)
        if (chip8.cpu.waiting_for_key) {
            for (chip8.cpu.keys, 0..) |pressed, i| {
                if (pressed) {
                    chip8.cpu.registers[chip8.cpu.key_register] = @intCast(i);
                    chip8.cpu.waiting_for_key = false;
                    break;
                }
            }
        }

        // Execute instructions (~500Hz at 60fps)
        for (0..INSTRUCTIONS_PER_FRAME) |_| {
            if (!chip8.cpu.waiting_for_key) {
                chip8.update() catch {};
            }
        }

        // Tick timers at 60Hz
        chip8.tickTimers();

        // Render
        rl.beginDrawing();
        rl.clearBackground(rl.Color.black);
        display.render(&chip8.cpu.display);
        rl.endDrawing();
    }
}
