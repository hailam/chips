const std = @import("std");
const rl = @import("raylib");
const Chip8 = @import("core/chip8.zig").Chip8;
const control = @import("core/control_spec.zig");
const debugger_mod = @import("core/debugger.zig");
const display = @import("core/display.zig");
const emulation = @import("core/emulation_config.zig");
const input = @import("core/input.zig");
const layout = @import("core/display_layout.zig");
const persistence = @import("core/persistence.zig");
const sound = @import("core/sound.zig");
const timing = @import("core/timing.zig");
const ui_mod = @import("core/ui_state.zig");

const LoadedRom = struct {
    path: []u8,
    display_name: []u8,
    data: []u8,
    sha256: [32]u8,
    sha256_hex: []u8,

    fn deinit(self: *LoadedRom, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.display_name);
        allocator.free(self.data);
        allocator.free(self.sha256_hex);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.skip();
    const initial_rom_path = args_iter.next();

    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    var app_state = try persistence.loadAppState(init.io, init.gpa, app_data_root);
    defer app_state.deinit();

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(display.DEFAULT_WINDOW_WIDTH, display.DEFAULT_WINDOW_HEIGHT, "Chip-8 Emulator");
    defer rl.closeWindow();
    rl.setWindowMinSize(display.MIN_WINDOW_WIDTH, display.MIN_WINDOW_HEIGHT);
    rl.setTargetFPS(60);

    display.initFont();
    defer display.deinitFont();

    sound.init();
    defer sound.deinit();
    sound.setVolume(app_state.global_settings.volume);

    if (app_state.global_settings.fullscreen) {
        rl.toggleFullscreen();
    }

    var chip8 = Chip8.init();
    seedChip8(&chip8);

    var loaded_rom: ?LoadedRom = null;
    defer if (loaded_rom) |*rom| rom.deinit(init.gpa);

    var debugger_state = debugger_mod.DebuggerState.init();
    var ui_state = ui_mod.UiState{};
    var state: display.EmulatorState = .paused;
    var timing_state = timing.TimingState.init();
    var mem_scroll: i32 = 0x20;
    var disasm_scroll: i32 = 0;

    if (initial_rom_path) |rom_path| {
        loaded_rom = try loadRomIntoRuntime(
            &init,
            app_data_root,
            &app_state,
            rom_path,
            &chip8,
            &timing_state,
            &ui_state,
        );
        debugger_state = debugger_mod.DebuggerState.init();
        state = .running;
    } else if (app_state.recent_roms.items.len > 0) {
        ui_state.overlay = .recent_roms;
    }

    while (!rl.windowShouldClose()) {
        const shift_down = isShiftDown();
        const ui_layout = layout.computeLayout(rl.getScreenWidth(), rl.getScreenHeight());
        const mouse_x = rl.getMouseX();
        const mouse_y = rl.getMouseY();

        if (rl.isFileDropped()) {
            if (try loadDroppedRom(
                &init,
                app_data_root,
                &app_state,
                &chip8,
                &timing_state,
                &ui_state,
            )) |new_rom| {
                if (loaded_rom) |*current| current.deinit(init.gpa);
                loaded_rom = new_rom;
                debugger_state = debugger_mod.DebuggerState.init();
                mem_scroll = 0x20;
                disasm_scroll = 0;
                state = .running;
            }
        }

        if (handleOverlayInput(
            &init,
            app_data_root,
            &app_state,
            &loaded_rom,
            &chip8,
            &debugger_state,
            &timing_state,
            &ui_state,
            &state,
        )) |overlay_loaded| {
            if (overlay_loaded) {
                mem_scroll = 0x20;
                disasm_scroll = 0;
            }
        } else |err| switch (err) {
            error.FileNotFound, error.InvalidWatchAddress, error.InvalidSaveStateMagic, error.UnsupportedSaveStateVersion, error.InvalidSaveStateProfile => {},
            else => return err,
        }

        if (ui_state.overlay == .none) {
            if (rl.isKeyPressed(.space)) {
                if (state == .running) {
                    state = .paused;
                } else if (loaded_rom != null) {
                    debugger_state.beginResume(chip8.cpu.program_counter);
                    state = .running;
                }
            }

            if (rl.isKeyPressed(.n) and loaded_rom != null) {
                if (state == .paused) {
                    if (shift_down and isCallOpcode(peekOpcode(&chip8, chip8.cpu.program_counter) orelse 0)) {
                        debugger_state.temp_run_until = chip8.cpu.program_counter + 2;
                        debugger_state.beginResume(chip8.cpu.program_counter);
                        state = .running;
                    } else {
                        debugger_state.beginResume(chip8.cpu.program_counter);
                        state = .stepping;
                    }
                }
            }

            if (rl.isKeyPressed(.backspace) and loaded_rom != null) {
                try reloadLoadedRom(&chip8, loaded_rom.?, chip8.config);
                debugger_state.trace_len = 0;
                debugger_state.trace_cursor = 0;
                debugger_state.trace_scroll = 0;
                debugger_state.selected_trace_index = null;
                debugger_state.trace_follow_live = true;
                debugger_state.temp_run_until = null;
                state = .paused;
            }

            if (rl.isKeyPressed(.right_bracket)) {
                timing_state.cpu_hz_target = @floatFromInt(timing.applySpeedAction(@intFromFloat(timing_state.cpu_hz_target), .faster));
                try persistCurrentRomPreference(&init, app_data_root, &app_state, loaded_rom, &chip8, &timing_state, &ui_state);
            }
            if (rl.isKeyPressed(.left_bracket)) {
                timing_state.cpu_hz_target = @floatFromInt(timing.applySpeedAction(@intFromFloat(timing_state.cpu_hz_target), .slower));
                try persistCurrentRomPreference(&init, app_data_root, &app_state, loaded_rom, &chip8, &timing_state, &ui_state);
            }
            if (rl.isKeyPressed(.m)) {
                _ = sound.toggleMuted();
            }
            if (rl.isKeyPressed(.o)) {
                ui_state.overlay = .recent_roms;
                state = .paused;
                ui_state.recent_selection = 0;
            }
            if (rl.isKeyPressed(.b) and state == .paused) {
                debugger_state.toggleBreakpoint(chip8.cpu.program_counter);
            }
            if (rl.isKeyPressed(.tab)) {
                debugger_state.cycleTab();
            }
            if (rl.isKeyPressed(.end)) {
                debugger_state.resumeTraceFollow();
            }
            if (rl.isKeyPressed(.semicolon) and debugger_state.active_middle_tab == .watches) {
                ui_state.overlay = .{ .watch_edit = initWatchEdit(
                    debugger_state.selected_watch_slot,
                    debugger_state.watch_addrs[debugger_state.selected_watch_slot],
                ) };
                state = .paused;
            }
            if (rl.isKeyPressed(.p) and loaded_rom != null) {
                chip8.config.setProfile(cycleProfile(chip8.config.quirk_profile));
                try persistCurrentRomPreference(&init, app_data_root, &app_state, loaded_rom, &chip8, &timing_state, &ui_state);
            }
            if (rl.isKeyPressed(.f5) and loaded_rom != null) {
                if (shift_down) {
                    ui_state.overlay = .{ .save_slots = .save };
                    state = .paused;
                } else {
                    try saveCurrentSlot(&init, app_data_root, loaded_rom.?, &chip8, &timing_state, state, ui_state.active_save_slot);
                    try persistCurrentRomPreference(&init, app_data_root, &app_state, loaded_rom, &chip8, &timing_state, &ui_state);
                }
            }
            if (rl.isKeyPressed(.f9) and loaded_rom != null) {
                if (shift_down) {
                    ui_state.overlay = .{ .save_slots = .load };
                    state = .paused;
                } else {
                    try loadCurrentSlot(&init, app_data_root, loaded_rom.?, &chip8, &timing_state, &state, ui_state.active_save_slot);
                    try persistCurrentRomPreference(&init, app_data_root, &app_state, loaded_rom, &chip8, &timing_state, &ui_state);
                }
            }
            if (rl.isKeyPressed(.f11)) {
                rl.toggleFullscreen();
                app_state.global_settings.fullscreen = !app_state.global_settings.fullscreen;
                try persistence.saveAppState(init.io, init.gpa, app_data_root, &app_state);
            }
            if (rl.isKeyPressed(.minus)) {
                app_state.global_settings.volume = clampVolume(app_state.global_settings.volume - 0.1);
                sound.setVolume(app_state.global_settings.volume);
                try persistence.saveAppState(init.io, init.gpa, app_data_root, &app_state);
            }
            if (rl.isKeyPressed(.equal)) {
                app_state.global_settings.volume = clampVolume(app_state.global_settings.volume + 0.1);
                sound.setVolume(app_state.global_settings.volume);
                try persistence.saveAppState(init.io, init.gpa, app_data_root, &app_state);
            }
            if (rl.isKeyPressed(.g)) {
                if (shift_down) {
                    app_state.global_settings.effect = cycleEffect(app_state.global_settings.effect);
                } else {
                    app_state.global_settings.palette = cyclePalette(app_state.global_settings.palette);
                }
                try persistence.saveAppState(init.io, init.gpa, app_data_root, &app_state);
            }

            const wheel = rl.getMouseWheelMove();
            if (wheel != 0 and pointInRect(mouse_x, mouse_y, ui_layout.gutter.body()) and debugger_state.active_middle_tab == .trace) {
                debugger_state.scrollTrace(-@as(i32, @intFromFloat(wheel * 3)), gutterRowsVisible(ui_layout.gutter));
            }

            if (rl.isMouseButtonPressed(.left)) {
                if (breakpointAddressAtPoint(ui_layout, chip8.cpu.program_counter, disasm_scroll, mouse_x, mouse_y)) |pc| {
                    debugger_state.toggleBreakpoint(pc);
                } else if (gutterTabAtPoint(ui_layout.gutter, mouse_x, mouse_y)) |tab| {
                    debugger_state.active_middle_tab = tab;
                } else if (debugger_state.active_middle_tab == .trace) {
                    if (traceRowAtPoint(ui_layout.gutter, mouse_x, mouse_y, debugger_state.trace_scroll, debugger_state.trace_len)) |trace_index| {
                        debugger_state.selectTraceIndex(trace_index, gutterRowsVisible(ui_layout.gutter));
                    }
                } else if (debugger_state.active_middle_tab == .watches) {
                    if (watchSlotAtPoint(ui_layout.gutter, mouse_x, mouse_y)) |slot| {
                        debugger_state.selected_watch_slot = slot;
                    }
                }
            }
        }

        const overlay_open = ui_state.overlay != .none;
        var held_keys = [_]bool{false} ** 16;
        var just_pressed_keys = [_]bool{false} ** 16;
        if (!overlay_open) {
            held_keys = input.pollKeys();
            just_pressed_keys = input.pollJustPressedKeys();
            chip8.cpu.keys = held_keys;
        } else {
            chip8.cpu.keys = [_]bool{false} ** 16;
        }

        if (input.firstPressedKey(just_pressed_keys)) |pressed_key| {
            ui_state.last_latched_key = pressed_key;
        }

        if (chip8.cpu.waiting_for_key) {
            if (input.firstPressedKey(just_pressed_keys) orelse input.firstPressedKey(held_keys)) |pressed_key| {
                chip8.cpu.registers[chip8.cpu.key_register] = pressed_key;
                chip8.cpu.waiting_for_key = false;
                chip8.cpu.program_counter += 2;
                ui_state.last_latched_key = pressed_key;
            }
        }

        if (loaded_rom != null and !overlay_open and (state == .running or state == .stepping)) {
            const step_result = timing.advance(&timing_state, rl.getFrameTime());
            const cycle_budget: usize = if (state == .stepping) 1 else step_result.cpu_cycles;

            if (state == .running) {
                for (0..step_result.timer_ticks) |_| chip8.tickTimers();
            }

            var cycles_executed: usize = 0;
            while (cycles_executed < cycle_budget) : (cycles_executed += 1) {
                if (debugger_state.shouldPauseBeforeExecute(chip8.cpu.program_counter)) {
                    state = .paused;
                    break;
                }

                if (chip8.cpu.waiting_for_key) break;

                chip8.update() catch break;
                debugger_state.recordTrace(chip8.cpu.last_trace);
                chip8.cpu.snapshotRegisters();

                if (state == .stepping) {
                    state = .paused;
                    break;
                }
            }
        } else {
            timing_state.cpu_accumulator_s = 0;
            timing_state.timer_accumulator_s = 0;
        }

        rl.beginDrawing();
        rl.clearBackground(display.BG_WINDOW_PUB);
        display.renderAll(
            &chip8,
            state,
            &debugger_state,
            &ui_state,
            app_state.recent_roms.items,
            app_state.global_settings,
            @intFromFloat(timing_state.cpu_hz_target),
            &mem_scroll,
            &disasm_scroll,
            sound.isMuted(),
            if (loaded_rom) |rom| rom.display_name else null,
        );
        rl.endDrawing();
    }
}

fn handleOverlayInput(
    init: *const std.process.Init,
    app_data_root: []const u8,
    app_state: *persistence.AppState,
    loaded_rom: *?LoadedRom,
    chip8: *Chip8,
    debugger_state: *debugger_mod.DebuggerState,
    timing_state: *timing.TimingState,
    ui_state: *ui_mod.UiState,
    state: *display.EmulatorState,
) !bool {
    switch (ui_state.overlay) {
        .none => return false,
        .recent_roms => {
            if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.o)) {
                ui_state.overlay = .none;
                return false;
            }
            if (app_state.recent_roms.items.len == 0) return false;
            if (rl.isKeyPressed(.down)) ui_state.recent_selection = @min(ui_state.recent_selection + 1, app_state.recent_roms.items.len - 1);
            if (rl.isKeyPressed(.up)) ui_state.recent_selection -|= 1;
            if (rl.isKeyPressed(.enter)) {
                const recent = app_state.recent_roms.items[ui_state.recent_selection];
                const new_rom = try loadRomIntoRuntime(init, app_data_root, app_state, recent.path, chip8, timing_state, ui_state);
                if (loaded_rom.*) |*current| current.deinit(init.gpa);
                loaded_rom.* = new_rom;
                debugger_state.* = debugger_mod.DebuggerState.init();
                ui_state.overlay = .none;
                state.* = .running;
                return true;
            }
            return false;
        },
        .save_slots => |mode| {
            if (rl.isKeyPressed(.escape)) {
                ui_state.overlay = .none;
                return false;
            }
            if (rl.isKeyPressed(.down) or rl.isKeyPressed(.right)) {
                ui_state.active_save_slot = clampSlot(ui_state.active_save_slot + 1);
            }
            if (rl.isKeyPressed(.up) or rl.isKeyPressed(.left)) {
                ui_state.active_save_slot = clampSlot(ui_state.active_save_slot -| 1);
            }

            if (numberKeyToSlot()) |slot| {
                ui_state.active_save_slot = slot;
            }

            if (rl.isKeyPressed(.enter) or numberKeyToSlot() != null) {
                if (loaded_rom.*) |rom| switch (mode) {
                    .save => try saveCurrentSlot(init, app_data_root, rom, chip8, timing_state, state.*, ui_state.active_save_slot),
                    .load => try loadCurrentSlot(init, app_data_root, rom, chip8, timing_state, state, ui_state.active_save_slot),
                };
                try persistCurrentRomPreference(init, app_data_root, app_state, loaded_rom.*, chip8, timing_state, ui_state);
                ui_state.overlay = .none;
            }
            return false;
        },
        .watch_edit => |watch_edit| {
            var next = watch_edit;
            if (rl.isKeyPressed(.escape)) {
                ui_state.overlay = .none;
                return false;
            }

            while (true) {
                const codepoint = rl.getCharPressed();
                if (codepoint == 0) break;
                if (next.len >= next.text.len) continue;
                const ch: u8 = @intCast(codepoint);
                if (std.ascii.isHex(ch)) {
                    next.text[next.len] = std.ascii.toUpper(ch);
                    next.len += 1;
                }
            }

            if (rl.isKeyPressed(.backspace) and next.len > 0) next.len -= 1;

            if (rl.isKeyPressed(.enter)) {
                const addr = try debugger_mod.parseWatchAddress(next.text[0..next.len]);
                debugger_state.setWatchAddress(next.slot, addr);
                ui_state.overlay = .none;
                return false;
            }

            ui_state.overlay = .{ .watch_edit = next };
            return false;
        },
    }
}

fn loadRomIntoRuntime(
    init: *const std.process.Init,
    app_data_root: []const u8,
    app_state: *persistence.AppState,
    rom_path: []const u8,
    chip8: *Chip8,
    timing_state: *timing.TimingState,
    ui_state: *ui_mod.UiState,
) !LoadedRom {
    const rom_data = try std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, init.gpa, .limited(4096 - 0x200));
    errdefer init.gpa.free(rom_data);

    const sha256 = persistence.computeRomSha256(rom_data);
    const sha256_hex = try persistence.sha256HexAlloc(init.gpa, sha256);
    errdefer init.gpa.free(sha256_hex);

    const path_copy = try init.gpa.dupe(u8, rom_path);
    errdefer init.gpa.free(path_copy);
    const display_name = try init.gpa.dupe(u8, persistence.basename(rom_path));
    errdefer init.gpa.free(display_name);

    const pref = app_state.findRomPreference(sha256_hex);
    const profile = if (pref) |value| value.quirk_profile else emulation.QuirkProfile.modern;
    const hz = if (pref) |value| timing.clampCpuHz(value.cpu_hz_target) else timing.CPU_HZ_DEFAULT;
    const save_slot = if (pref) |value| clampSlot(value.last_save_slot) else @as(u8, 1);

    chip8.* = Chip8.initWithConfig(emulation.EmulationConfig.init(profile));
    seedChip8(chip8);
    try chip8.loadRom(rom_data);

    timing_state.* = timing.TimingState.init();
    timing_state.cpu_hz_target = @floatFromInt(hz);
    ui_state.active_save_slot = save_slot;
    ui_state.overlay = .none;

    try app_state.upsertRecentRom(rom_path, display_name, sha256_hex, std.Io.Clock.now(.real, init.io).toMilliseconds());
    try app_state.upsertRomPreference(sha256_hex, rom_path, chip8.config.quirk_profile, hz, ui_state.active_save_slot);
    try persistence.saveAppState(init.io, init.gpa, app_data_root, app_state);

    return .{
        .path = path_copy,
        .display_name = display_name,
        .data = rom_data,
        .sha256 = sha256,
        .sha256_hex = sha256_hex,
    };
}

fn reloadLoadedRom(chip8: *Chip8, loaded_rom: LoadedRom, config: emulation.EmulationConfig) !void {
    chip8.* = Chip8.initWithConfig(config);
    seedChip8(chip8);
    try chip8.loadRom(loaded_rom.data);
}

fn saveCurrentSlot(
    init: *const std.process.Init,
    app_data_root: []const u8,
    loaded_rom: LoadedRom,
    chip8: *Chip8,
    timing_state: *const timing.TimingState,
    state: display.EmulatorState,
    slot: u8,
) !void {
    const envelope = persistence.SaveStateEnvelope{
        .rom_sha256 = loaded_rom.sha256,
        .quirk_profile = chip8.config.quirk_profile,
        .chip8_state = chip8.snapshot(),
        .cpu_hz_target = @intFromFloat(timing_state.cpu_hz_target),
        .paused_state = state != .running,
    };
    try persistence.saveEnvelopeToFile(init.io, init.gpa, app_data_root, loaded_rom.sha256_hex, slot, &envelope);
}

fn loadCurrentSlot(
    init: *const std.process.Init,
    app_data_root: []const u8,
    loaded_rom: LoadedRom,
    chip8: *Chip8,
    timing_state: *timing.TimingState,
    state: *display.EmulatorState,
    slot: u8,
) !void {
    const envelope = try persistence.loadEnvelopeFromFile(init.io, init.gpa, app_data_root, loaded_rom.sha256_hex, slot);
    if (!std.mem.eql(u8, &envelope.rom_sha256, &loaded_rom.sha256)) return error.SaveStateRomMismatch;
    chip8.restore(envelope.chip8_state);
    timing_state.cpu_hz_target = @floatFromInt(timing.clampCpuHz(envelope.cpu_hz_target));
    state.* = if (envelope.paused_state) .paused else .running;
}

fn persistCurrentRomPreference(
    init: *const std.process.Init,
    app_data_root: []const u8,
    app_state: *persistence.AppState,
    loaded_rom: ?LoadedRom,
    chip8: *const Chip8,
    timing_state: *const timing.TimingState,
    ui_state: *const ui_mod.UiState,
) !void {
    if (loaded_rom) |rom| {
        try app_state.upsertRomPreference(
            rom.sha256_hex,
            rom.path,
            chip8.config.quirk_profile,
            @intFromFloat(timing_state.cpu_hz_target),
            ui_state.active_save_slot,
        );
    }
    try persistence.saveAppState(init.io, init.gpa, app_data_root, app_state);
}

fn loadDroppedRom(
    init: *const std.process.Init,
    app_data_root: []const u8,
    app_state: *persistence.AppState,
    chip8: *Chip8,
    timing_state: *timing.TimingState,
    ui_state: *ui_mod.UiState,
) !?LoadedRom {
    const dropped = rl.loadDroppedFiles();
    defer rl.unloadDroppedFiles(dropped);

    var idx: usize = 0;
    while (idx < dropped.count) : (idx += 1) {
        const path = std.mem.span(dropped.paths[idx]);
        if (hasSupportedRomExtension(path)) {
            return try loadRomIntoRuntime(init, app_data_root, app_state, path, chip8, timing_state, ui_state);
        }
    }
    return null;
}

fn hasSupportedRomExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ch8") or std.mem.endsWith(u8, path, ".rom");
}

fn seedChip8(chip8: *Chip8) void {
    chip8.cpu.seedRng(@as(u64, @truncate(@intFromPtr(chip8))));
}

fn peekOpcode(chip8: *const Chip8, pc: u16) ?u16 {
    if (pc + 1 >= chip8.memory.len) return null;
    return @as(u16, chip8.memory[pc]) << 8 | @as(u16, chip8.memory[pc + 1]);
}

fn isCallOpcode(opcode: u16) bool {
    return (opcode & 0xF000) == 0x2000;
}

fn cycleProfile(profile: emulation.QuirkProfile) emulation.QuirkProfile {
    return switch (profile) {
        .modern => .vip_legacy,
        .vip_legacy => .modern,
    };
}

fn cyclePalette(palette: persistence.DisplayPalette) persistence.DisplayPalette {
    return switch (palette) {
        .classic_green => .amber,
        .amber => .ice,
        .ice => .gray,
        .gray => .classic_green,
    };
}

fn cycleEffect(effect: persistence.DisplayEffect) persistence.DisplayEffect {
    return switch (effect) {
        .none => .scanlines,
        .scanlines => .none,
    };
}

fn clampVolume(value: f32) f32 {
    if (value < 0) return 0;
    if (value > 1.0) return 1.0;
    return value;
}

fn clampSlot(slot: u8) u8 {
    if (slot < 1) return 1;
    if (slot > 5) return 5;
    return slot;
}

fn isShiftDown() bool {
    return rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
}

fn numberKeyToSlot() ?u8 {
    if (rl.isKeyPressed(.one)) return 1;
    if (rl.isKeyPressed(.two)) return 2;
    if (rl.isKeyPressed(.three)) return 3;
    if (rl.isKeyPressed(.four)) return 4;
    if (rl.isKeyPressed(.five)) return 5;
    return null;
}

fn initWatchEdit(slot: usize, addr: u16) ui_mod.WatchEditState {
    var edit = ui_mod.WatchEditState{ .slot = slot };
    const text = std.fmt.bufPrint(&edit.text, "{X:0>3}", .{addr}) catch "";
    edit.len = text.len;
    return edit;
}

fn breakpointAddressAtPoint(ui: layout.LayoutMetrics, pc: u16, scroll: i32, x: i32, y: i32) ?u16 {
    const body = ui.disassembler.body();
    if (x < body.x or x >= body.x + 20 or y < body.y or y >= body.bottom()) return null;
    const row = @divTrunc(y - (ui.disassembler.y + layout.HEADER_H + 4), layout.LINE_H);
    if (row < 0 or row >= @as(i32, @intCast(ui.disasm_rows_visible))) return null;
    const start_addr = @max(@as(i32, @intCast(pc)) + scroll * 2, 0);
    const addr = start_addr + row * 2;
    if (addr < 0 or addr >= 4096 - 1) return null;
    return @intCast(addr);
}

fn gutterTabAtPoint(panel: layout.PanelRect, x: i32, y: i32) ?debugger_mod.MiddleTab {
    if (y < panel.y or y >= panel.y + layout.HEADER_H or x < panel.x or x >= panel.right()) return null;
    const tab_width = @divTrunc(panel.w, 3);
    const idx = @divTrunc(x - panel.x, tab_width);
    return switch (idx) {
        0 => .trace,
        1 => .cycle,
        2 => .watches,
        else => null,
    };
}

fn traceRowAtPoint(panel: layout.PanelRect, x: i32, y: i32, scroll: usize, trace_len: usize) ?usize {
    const body = panel.body();
    if (trace_len == 0 or x < body.x or x >= body.right() or y < body.y or y >= body.bottom()) return null;
    const row = @divTrunc(y - (panel.y + layout.HEADER_H + 6), layout.LINE_H_SMALL);
    if (row < 0) return null;
    const trace_index = scroll + @as(usize, @intCast(row));
    if (trace_index >= trace_len) return null;
    return trace_index;
}

fn gutterRowsVisible(panel: layout.PanelRect) usize {
    return @intCast(@max(@divTrunc(panel.body().h - 6, layout.LINE_H_SMALL), 1));
}

fn pointInRect(x: i32, y: i32, rect: layout.PanelRect) bool {
    return x >= rect.x and x < rect.right() and y >= rect.y and y < rect.bottom();
}

fn watchSlotAtPoint(panel: layout.PanelRect, x: i32, y: i32) ?usize {
    const body = panel.body();
    if (x < body.x or x >= body.right() or y < body.y + layout.LINE_H_SMALL or y >= body.bottom()) return null;
    const row = @divTrunc(y - (body.y + layout.LINE_H_SMALL), layout.LINE_H_SMALL);
    if (row < 6) return null;
    const slot = row - 6;
    if (slot < 0 or slot >= debugger_mod.WATCH_COUNT) return null;
    return @intCast(slot);
}
