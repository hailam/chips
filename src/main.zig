const std = @import("std");
const rl = @import("raylib");
const Chip8 = @import("core/chip8.zig").Chip8;
const display = @import("core/display.zig");
const input = @import("core/input.zig");
const sound = @import("core/sound.zig");

pub fn main(init: std.process.Init) !void {
    // Parse ROM path from args
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.skip();
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

    // Emulator state
    var state: display.EmulatorState = .running;
    var instructions_per_frame: i32 = 10; // ~600 Hz at 60fps
    var mem_scroll: i32 = 0x20; // Start scrolled to 0x200 area

    // Main loop
    while (!rl.windowShouldClose()) {
        // Debug controls
        if (rl.isKeyPressed(.space)) {
            state = if (state == .running) .paused else .running;
        }
        if (rl.isKeyPressed(.n) and state == .paused) {
            state = .stepping;
        }
        if (rl.isKeyPressed(.backspace)) {
            chip8 = Chip8.init();
            chip8.cpu.seedRng(@as(u64, @truncate(@intFromPtr(&chip8))));
            chip8.loadRom(rom_data) catch {};
            state = .paused;
        }
        // Speed control: up/down arrows
        if (rl.isKeyPressed(.up)) {
            instructions_per_frame = @min(instructions_per_frame + 2, 50);
        }
        if (rl.isKeyPressed(.down)) {
            instructions_per_frame = @max(instructions_per_frame - 2, 1);
        }

        // Chip-8 input (only when running)
        chip8.cpu.keys = input.pollKeys();

        // Handle FX0A (wait for key)
        // When a key is detected, store it, advance PC past the FX0A, and resume
        if (chip8.cpu.waiting_for_key) {
            for (chip8.cpu.keys, 0..) |pressed, i| {
                if (pressed) {
                    chip8.cpu.registers[chip8.cpu.key_register] = @intCast(i);
                    chip8.cpu.waiting_for_key = false;
                    chip8.cpu.program_counter += 2; // skip past the FX0A
                    break;
                }
            }
        }

        // Execute instructions
        if (state == .running or state == .stepping) {
            const count: usize = if (state == .stepping) 1 else @intCast(instructions_per_frame);
            for (0..count) |_| {
                if (!chip8.cpu.waiting_for_key) {
                    chip8.update() catch {};
                }
            }
            if (state == .stepping) state = .paused;
        }

        // Tick timers at 60Hz
        if (state == .running) {
            chip8.tickTimers();
        }

        // Render
        rl.beginDrawing();
        rl.clearBackground(rl.Color{ .r = 20, .g = 20, .b = 20, .a = 255 });

        display.renderAll(
            &chip8.cpu,
            &chip8.memory,
            state,
            instructions_per_frame * 60,
            &mem_scroll,
        );

        // Controls help bar at very bottom
        const help_y = display.WINDOW_HEIGHT - 18;
        rl.drawText("SPACE:Run/Pause  N:Step  BKSP:Reset  Up/Down:Speed  Keys:1234/QWER/ASDF/ZXCV", 10, help_y, 12, display.TEXT_DIM_PUB);

        rl.endDrawing();
    }
}
