const std = @import("std");
const rl = @import("raylib");
const assembly = @import("core/assembly.zig");
const Chip8 = @import("core/chip8.zig").Chip8;
const cli = @import("core/cli.zig");
const registry = @import("core/registry.zig");
const url_mod = @import("core/url.zig");
const config_mod = @import("core/config.zig");
const models = @import("core/registry_models.zig");
const cache = @import("core/cache.zig");
const state_mod = @import("core/state.zig");
const chip8_db_cache = @import("core/chip8_db_cache.zig");
const spec_mod = @import("core/spec.zig");
const github_mod = @import("core/github.zig");
const runtime_check = @import("core/verification/runtime_check.zig");
const fonts = @import("core/fonts.zig");
const verify_report = @import("core/verification/report.zig");
const verify_test_suite = @import("core/verification/test_suite.zig");
const axis_opcodes = @import("core/verification/axis/opcodes.zig");
const axis_memory = @import("core/verification/axis/memory.zig");
const axis_sound = @import("core/verification/axis/sound.zig");
const axis_quirks = @import("core/verification/axis/quirks.zig");
const axis_timing = @import("core/verification/axis/timing.zig");
const inference_audit = @import("core/verification/inference_audit.zig");
const corpus_mod = @import("core/verification/corpus.zig");
const ref_fb_mod = @import("core/verification/oracle/reference_framebuffers.zig");
const control = @import("core/control_spec.zig");
const cpu_mod = @import("core/cpu.zig");
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
    sha1: [20]u8,
    sha1_hex: []u8,
    analysis: assembly.RomAnalysis,
    // Mirror of the resolved start_address / font_style so reload/reset,
    // disasm, and source export don't silently drop them back to 0x200 /
    // default font. Owned by this struct when non-null.
    start_address: u16,
    font_style: ?[]u8,

    fn deinit(self: *LoadedRom, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.display_name);
        allocator.free(self.data);
        allocator.free(self.sha1_hex);
        if (self.font_style) |f| allocator.free(f);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const command = cli.parseArgs(args[1..]) catch |err| {
        try printCliUsage(init, err);
        std.process.exit(1);
    };

    runCommand(init, command) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Error: File not found.\n", .{});
        } else if (err == error.AccessDenied) {
            std.debug.print("Error: Access denied.\n", .{});
        } else if (err == error.InvalidUrl) {
            std.debug.print("Error: Invalid URL or ROM identifier.\n", .{});
        } else {
            // For other errors, use a name check to avoid compile-time error set issues
            const err_name = @errorName(err);
            if (std.mem.eql(u8, err_name, "NetworkUnavailable")) {
                std.debug.print("Error: Network unavailable.\n", .{});
            } else if (std.mem.eql(u8, err_name, "RateLimited")) {
                std.debug.print("Error: GitHub API rate limit exceeded. Try again later or set GITHUB_TOKEN.\n", .{});
            } else {
                std.debug.print("Error: {s}\n", .{err_name});
            }
        }
        std.process.exit(1);
    };
}

fn runCommand(init: std.process.Init, command: cli.Command) !void {
    switch (command) {
        .run => |cmd| try runGui(init, cmd.rom_path, cmd.profile),
        .disasm => |cmd| try runDisasmCommand(init, cmd.rom_path, cmd.output_path, cmd.profile),
        .assemble => |cmd| try runAssembleCommand(init, cmd.source_path, cmd.output_path),
        .check => |cmd| try runCheckCommand(init, cmd.source_path),
        .get => |cmd| try runGetCommand(init, cmd.source, cmd.launch),
        .search => |cmd| try runSearchCommand(init, cmd.query),
        .list => try runListCommand(init),
        .remove => |cmd| try runRemoveCommand(init, cmd.id),
        .update => |cmd| try runUpdateCommand(init, cmd.id),
        .refresh => |cmd| try runRefreshCommand(init, cmd),
        .registries => try runRegistriesCommand(init),
        .init_manifest => |cmd| try runInitCommand(init, cmd.path),
        .validate_manifest => |cmd| try runValidateCommand(init, cmd.path),
        .verify => |cmd| try runVerifyCommand(init, cmd),
        .override_config => |cmd| try runOverrideCommand(init, cmd),
        .help => try runHelpCommand(init),
    }
}

// Counts installed ROMs whose on-disk path isn't already listed in recents —
// these are the ones worth showing as a separate section.
fn countInstalledNotInRecent(installed: []const models.InstalledRom, recents: []const persistence.RecentRom) usize {
    var count: usize = 0;
    for (installed) |rom| {
        if (!recentsContainPath(recents, rom.local.path)) count += 1;
    }
    return count;
}

fn recentsContainPath(recents: []const persistence.RecentRom, path: []const u8) bool {
    for (recents) |r| {
        if (std.mem.eql(u8, r.path, path)) return true;
    }
    return false;
}

// Overlay layout is `[installed_unique..., recent...]`. Resolves `index`
// back to the ROM path that should be loaded.
fn resolveOverlaySelection(
    installed: []const models.InstalledRom,
    recents: []const persistence.RecentRom,
    index: usize,
) ?[]const u8 {
    var cursor: usize = 0;
    for (installed) |rom| {
        if (recentsContainPath(recents, rom.local.path)) continue;
        if (cursor == index) return rom.local.path;
        cursor += 1;
    }
    const recent_idx = index - cursor;
    if (recent_idx < recents.len) return recents[recent_idx].path;
    return null;
}

fn resolveRomPathAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    app_data_root: []const u8,
    arg: []const u8,
) ![]u8 {
    // If the argument is a readable file on disk, use it as-is.
    if (std.Io.Dir.cwd().statFile(io, arg, .{})) |_| {
        return try allocator.dupe(u8, arg);
    } else |_| {}

    const qualified = registry.parseQualifiedId(arg);

    // Namespaced form: `<registry>:<id>` → installed_roms/<registry>/<id>.ch8.
    if (qualified.registry) |ns| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/installed_roms/{s}/{s}.ch8", .{ app_data_root, ns, qualified.id });
        if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }

    // Bare id: try root installed_roms/ first, then scan every namespaced
    // subdirectory for a matching sidecar. Ambiguous hits fall through to the
    // first one (listing is still available via `chip8 list`).
    {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/installed_roms/{s}.ch8", .{ app_data_root, qualified.id });
        if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    if (try lookupInstalledByBareId(io, allocator, app_data_root, qualified.id)) |p| return p;

    // Nothing matched — return the original so the downstream caller surfaces
    // the "file not found" error naturally.
    return try allocator.dupe(u8, arg);
}

fn lookupInstalledByBareId(
    io: std.Io,
    allocator: std.mem.Allocator,
    app_data_root: []const u8,
    id: []const u8,
) !?[]u8 {
    const installed_dir = try std.fmt.allocPrint(allocator, "{s}/installed_roms", .{app_data_root});
    defer allocator.free(installed_dir);

    var dir = std.Io.Dir.cwd().openDir(io, installed_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.ch8", .{ installed_dir, entry.name, id });
        if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return null;
}

fn runGui(init: std.process.Init, initial_rom_path: ?[]const u8, requested_profile: ?emulation.QuirkProfile) !void {

    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    var app_state = try persistence.loadAppState(init.io, init.gpa, app_data_root);
    defer app_state.deinit();

    // Catalog of installed ROMs — shown in the startup overlay so users can
    // launch `chip8 get`-installed ROMs they haven't opened yet.
    const installed_list = registry.listInstalled(init.io, init.gpa, app_data_root) catch &.{};
    defer {
        for (installed_list) |r| r.deinit(init.gpa);
        init.gpa.free(installed_list);
    }

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(display.DEFAULT_WINDOW_WIDTH, display.DEFAULT_WINDOW_HEIGHT, "Chip-8 Emulator");
    defer rl.closeWindow();
    rl.setWindowMinSize(display.MIN_WINDOW_WIDTH, display.MIN_WINDOW_HEIGHT);
    rl.setTargetFPS(60);
    // Raylib defaults Escape to "exit app" via WindowShouldClose. We bind
    // Escape to Run/Pause ourselves, so disable the built-in exit key.
    rl.setExitKey(.null);

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
        const resolved = try resolveRomPathAlloc(init.io, init.gpa, app_data_root, rom_path);
        defer init.gpa.free(resolved);
        var mutable_init = init;
        loaded_rom = try loadRomIntoRuntime(
            &mutable_init,
            app_data_root,
            &app_state,
            resolved,
            requested_profile,
            &chip8,
            &timing_state,
            &ui_state,
        );
        debugger_state = debugger_mod.DebuggerState.init();
        state = .running;
    } else if (app_state.recent_roms.items.len > 0 or installed_list.len > 0) {
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
            installed_list,
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
            if (rl.isKeyPressed(.escape)) {
                if (state == .running) {
                    state = .paused;
                } else if (loaded_rom != null and chip8.cpu.trap_reason == null) {
                    debugger_state.beginResume(chip8.cpu.program_counter);
                    state = .running;
                }
            }

            if (rl.isKeyPressed(.n) and loaded_rom != null) {
                if (state == .paused and chip8.cpu.trap_reason == null) {
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
                ui_state.clearStatus();
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
            if (rl.isKeyPressed(.f2) and loaded_rom != null) {
                try exportCurrentSource(&init, app_data_root, loaded_rom.?, &chip8, &ui_state);
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
                try reloadLoadedRom(&chip8, loaded_rom.?, chip8.config);
                debugger_state = debugger_mod.DebuggerState.init();
                ui_state.clearStatus();
                state = .paused;
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
            // FX0A on VIP/Octo resumes on a new press transition, not on a
            // key that was already held when the instruction began. The
            // previous held-key fallback caused games to spuriously resume
            // on whatever the user had down at the time.
            if (input.firstPressedKey(just_pressed_keys)) |pressed_key| {
                chip8.cpu.registers[chip8.cpu.key_register] = pressed_key;
                chip8.cpu.waiting_for_key = false;
                chip8.cpu.program_counter += 2;
                ui_state.last_latched_key = pressed_key;
            }
        }

        if (loaded_rom != null and !overlay_open and (state == .running or state == .stepping)) {
            const step_result = timing.advance(&timing_state, rl.getFrameTime());
            const cycle_budget: usize = if (state == .stepping) 1 else step_result.cpu_cycles;

            // FX0A is a blocking instruction on both VIP and XO-CHIP spec:
            // delay/sound timers must NOT continue ticking while the CPU is
            // parked waiting for a keypress. Previously this ticked timers
            // unconditionally, which let sound cues expire during a pause.
            if (state == .running and !chip8.cpu.waiting_for_key) {
                for (0..step_result.timer_ticks) |_| chip8.tickTimers();
            }

            var cycles_executed: usize = 0;
            while (cycles_executed < cycle_budget) : (cycles_executed += 1) {
                if (debugger_state.shouldPauseBeforeExecute(chip8.cpu.program_counter)) {
                    state = .paused;
                    break;
                }

                if (chip8.cpu.trap_reason != null) {
                    state = .paused;
                    break;
                }
                if (chip8.cpu.waiting_for_key) break;
                // vblank_wait: DRW stalled until the next 60Hz frame. The
                // cycle budget is already spent — drop out and let the
                // outer loop roll around so tickTimers can release it.
                if (chip8.cpu.draw_stalled) break;

                chip8.update() catch |err| switch (err) {
                    error.CpuTrapped => {
                        state = .paused;
                        if (chip8.cpu.trap_reason) |trap| {
                            var trap_buf: [96]u8 = undefined;
                            ui_state.setStatus(trap.format(&trap_buf));
                        }
                        break;
                    },
                };
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

        sound.update(chip8.cpu.sound_timer, &chip8.cpu.audio_pattern, chip8.cpu.audio_pitch);

        rl.beginDrawing();
        rl.clearBackground(display.BG_WINDOW_PUB);
        display.renderAll(
            &chip8,
            state,
            &debugger_state,
            &ui_state,
            app_state.recent_roms.items,
            installed_list,
            app_state.global_settings,
            @intFromFloat(timing_state.cpu_hz_target),
            &mem_scroll,
            &disasm_scroll,
            sound.isMuted(),
            if (loaded_rom) |rom| &rom.analysis else null,
            if (loaded_rom) |rom| rom.display_name else null,
        );
        rl.endDrawing();
    }
}

fn handleOverlayInput(
    init: *const std.process.Init,
    app_data_root: []const u8,
    app_state: *persistence.AppState,
    installed: []const models.InstalledRom,
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
            const installed_visible = countInstalledNotInRecent(installed, app_state.recent_roms.items);
            const total = installed_visible + app_state.recent_roms.items.len;
            if (total == 0) return false;
            if (rl.isKeyPressed(.down)) ui_state.recent_selection = @min(ui_state.recent_selection + 1, total - 1);
            if (rl.isKeyPressed(.up)) ui_state.recent_selection -|= 1;
            if (rl.isKeyPressed(.enter)) {
                const path = resolveOverlaySelection(installed, app_state.recent_roms.items, ui_state.recent_selection) orelse return false;
                var mutable_init = init.*;
                const new_rom = try loadRomIntoRuntime(&mutable_init, app_data_root, app_state, path, null, chip8, timing_state, ui_state);
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

fn runHelpCommand(init: std.process.Init) !void {
    _ = init;
    std.debug.print("{s}\n", .{cli.usage()});
}

fn loadRomIntoRuntime(
    init: *std.process.Init,
    app_data_root: []const u8,
    app_state: *persistence.AppState,
    rom_path: []const u8,
    requested_profile: ?emulation.QuirkProfile,
    chip8: *Chip8,
    timing_state: *timing.TimingState,
    ui_state: *ui_mod.UiState,
) !LoadedRom {
    var rom_data: []u8 = undefined;

    // Try to open the path directly first
    rom_data = std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, init.gpa, .limited(cpu_mod.CHIP8_MEMORY_SIZE - @as(usize, 0x200))) catch |err| blk: {
        if (err == error.FileNotFound) {
            // Try in installed_roms
            const installed_path = try std.fmt.allocPrint(init.gpa, "installed_roms/{s}.ch8", .{rom_path});
            defer init.gpa.free(installed_path);
            
            const full_installed_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ app_data_root, installed_path });
            defer init.gpa.free(full_installed_path);

            break :blk try std.Io.Dir.cwd().readFileAlloc(init.io, full_installed_path, init.gpa, .limited(cpu_mod.CHIP8_MEMORY_SIZE - @as(usize, 0x200)));
        }
        return err;
    };
    errdefer init.gpa.free(rom_data);


    const sha1 = persistence.computeRomSha1(rom_data);
    const sha1_hex = try persistence.sha1HexAlloc(init.gpa, sha1);
    errdefer init.gpa.free(sha1_hex);

    const path_copy = try init.gpa.dupe(u8, rom_path);
    errdefer init.gpa.free(path_copy);
    const display_name = try init.gpa.dupe(u8, persistence.basename(rom_path));
    errdefer init.gpa.free(display_name);

    const pref = app_state.findRomPreference(sha1_hex);

    // Run the runtime-check resolver: consults chip-8-database first, falls
    // back to inference, then to the user profile. Emits a notification so
    // the user can see which layer won.
    const config = try config_mod.loadConfig(init.io, init.gpa, app_data_root);
    defer config.deinit(init.gpa);

    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    const sidecar_override = try loadSidecarOverrideAlloc(init.io, init.gpa, app_data_root, rom_path);
    defer if (sidecar_override) |o| o.deinit(init.gpa);

    const resolution = try runtime_check.resolveConfigForRom(
        init.gpa,
        rom_data,
        requested_profile,
        sidecar_override,
        &db_cache,
        config.auto_apply_db_config,
    );
    defer resolution.deinit(init.gpa);

    printRuntimeNotification(display_name, resolution);

    const inferred_profile = assembly.inferProfile(rom_data);
    const resolved_profile: ?emulation.QuirkProfile = emulation.platformIdToProfile(resolution.config.platform);
    const profile = requested_profile orelse resolved_profile orelse if (pref) |value|
        preferredProfile(value.quirk_profile, inferred_profile)
    else
        inferred_profile;
    const saved_hz = if (pref) |value| value.cpu_hz_target else null;
    const analysis = assembly.analyzeRomForProfile(profile, rom_data);

    // Build the emulation config. When a user explicitly requested a profile
    // on the CLI, honor that over the resolver's guess; otherwise use the
    // full resolved bundle so database `quirkyPlatforms` overrides actually
    // reach the CPU. Non-db QuirkFlags (hires, xo support, rpl depth, etc.)
    // stay at the profile's defaults.
    //
    // If the resolution targets a platform we don't simulate (chip8x,
    // megachip8), refuse to run rather than silently coercing to .modern.
    // Users can still force a profile with --profile to bypass the reject.
    const emulation_config = if (requested_profile != null)
        emulation.EmulationConfig.init(profile)
    else
        runtime_check.emulationConfigFromResolution(resolution) catch |err| switch (err) {
            error.UnsupportedPlatform => {
                std.debug.print(
                    "error: platform '{s}' is not supported by this build.\n" ++
                        "       Re-run with --profile <modern|vip|schip|xo|octo> to force a profile.\n",
                    .{resolution.config.platform},
                );
                return error.UnsupportedPlatform;
            },
        };

    // CPU speed: db tickrate (cycles per frame at 60Hz) wins over the
    // inferred profile default, unless the user has a saved preference for
    // this exact ROM.
    const hz_from_resolution: i32 = @intCast(resolution.config.tickrate * 60);
    const hz = if (saved_hz) |v|
        v
    else if (requested_profile == null and resolution.layer == .database_match)
        timing.clampCpuHz(hz_from_resolution)
    else
        timing.preferredStartupCpuHz(saved_hz, profile);
    const save_slot = if (pref) |value| clampSlot(value.last_save_slot) else @as(u8, 1);

    chip8.* = Chip8.initWithConfig(emulation_config);
    applyFontFromResolution(chip8, resolution);
    seedChip8(chip8);
    try chip8.loadRomAt(rom_data, resolution.config.start_address);

    // Apply per-ROM keypad mapping when the oracle supplied one. Clears
    // otherwise so the previous ROM's mapping doesn't bleed into this one.
    applyArrowOverridesFromResolution(resolution);
    // Same treatment for the foreground pixel color.
    applyDisplayColorFromResolution(resolution);
    // Screen rotation: 0/90/180/270 from chip-8-database.
    display.setScreenRotation(resolution.config.screen_rotation);

    timing_state.* = timing.TimingState.init();
    timing_state.cpu_hz_target = @floatFromInt(hz);
    ui_state.active_save_slot = save_slot;
    ui_state.overlay = .none;
    const profile_upgraded = requested_profile == null and pref != null and pref.?.quirk_profile != profile;
    const speed_upgraded = requested_profile == null and saved_hz != null and saved_hz.? != hz;
    // Priority order for the visible status line:
    //   1. Per-ROM override wins — users want to SEE their override took effect.
    //   2. Database match — "DB:<platform> <cpf>".
    //   3. Inference result with confidence if it won.
    //   4. Fallback for the "couldn't resolve" case.
    //   5. Auto upgrade messages (older behavior) when none of the above fire.
    if (resolution.override_applied) {
        ui_state.setStatusFmt("override  {s} @ {d}Hz", .{ emulation.profileLabel(profile), hz });
    } else switch (resolution.layer) {
        .database_match => {
            ui_state.setStatusFmt("DB:{s}  {d}cpf  @ {d}Hz", .{ resolution.config.platform, resolution.config.tickrate, hz });
        },
        .inference => {
            ui_state.setStatusFmt("inferred:{s}  conf={d:.2}  @ {d}Hz", .{ resolution.config.platform, resolution.confidence, hz });
        },
        .fallback => {
            if (profile_upgraded and speed_upgraded) {
                ui_state.setStatusFmt("Auto: {s} {d}Hz", .{ emulation.profileLabel(profile), hz });
            } else if (profile_upgraded) {
                ui_state.setStatusFmt("Auto profile: {s}", .{emulation.profileLabel(profile)});
            } else if (speed_upgraded) {
                ui_state.setStatusFmt("Auto speed: {d}Hz", .{hz});
            } else {
                ui_state.setStatusFmt("default:{s}  @ {d}Hz", .{ emulation.profileLabel(profile), hz });
            }
        },
    }
    // An embedded-title mismatch overrides the layer line — it's a loader
    // warning the user should see.
    if (resolution.embedded_title_mismatch != null) {
        ui_state.setStatusFmt("! embedded title mismatch for {s}", .{display_name});
    }

    try app_state.upsertRecentRom(rom_path, display_name, sha1_hex, std.Io.Clock.now(.real, init.io).toMilliseconds());
    try app_state.upsertRomPreference(sha1_hex, rom_path, chip8.config.quirk_profile, hz, ui_state.active_save_slot);
    try persistence.saveAppState(init.io, init.gpa, app_data_root, app_state);

    const font_style_owned = if (resolution.config.font_style) |f|
        try init.gpa.dupe(u8, f)
    else
        null;
    errdefer if (font_style_owned) |f| init.gpa.free(f);

    return .{
        .path = path_copy,
        .display_name = display_name,
        .data = rom_data,
        .sha1 = sha1,
        .sha1_hex = sha1_hex,
        .analysis = analysis,
        .start_address = resolution.config.start_address,
        .font_style = font_style_owned,
    };
}

// Applies the resolution's `font_style` string to the emulator's font
// memory region. Falls back to the default (octo) on unknown/missing
// values so ROMs with no hint still render digits sensibly.
fn applyFontFromResolution(chip8: *Chip8, resolution: runtime_check.ConfigResolution) void {
    const name = resolution.config.font_style orelse return;
    const style = fonts.FontStyle.fromString(name) orelse return;
    chip8.loadFont(style);
}

// Applies the resolution's `colors.pixels[1]` (foreground) to the display
// module's primary-color override. `pixels[0]` (background) isn't wired
// yet — our display pads the canvas with a fixed dark rectangle and
// pixel-off cells aren't drawn at all, so only the foreground affects
// rendering today.
fn applyDisplayColorFromResolution(resolution: runtime_check.ConfigResolution) void {
    // Clear first so partial/absent db colors don't leave stale bindings
    // from a previous ROM.
    display.clearPrimaryColorOverride();

    const colors = resolution.config.colors orelse return;
    const pixels = colors.pixels orelse return;

    // `pixels` is ordered by the plane-mask encoding:
    //   [0] = 00 (off / canvas background),
    //   [1] = 01 (plane-1 on),
    //   [2] = 10 (plane-2 on),
    //   [3] = 11 (both planes on).
    // CHIP-8 ROMs only need [1]; XO-CHIP can supply all four.
    if (pixels.len >= 1) {
        if (display.parseHexColor(pixels[0])) |c| display.setBackgroundColorOverride(c);
    }
    if (pixels.len >= 2) {
        if (display.parseHexColor(pixels[1])) |c| display.setPrimaryColorOverride(c);
    }
    if (pixels.len >= 3) {
        if (display.parseHexColor(pixels[2])) |c| display.setSecondaryColorOverride(c);
    }
    if (pixels.len >= 4) {
        if (display.parseHexColor(pixels[3])) |c| display.setBlendedColorOverride(c);
    }
}

// Push the resolution's `keys.up/down/left/right` into input.zig's
// module-level arrow-override state. Clears when the oracle didn't supply
// keys so previous bindings don't leak between loads.
fn applyArrowOverridesFromResolution(resolution: runtime_check.ConfigResolution) void {
    const keys = resolution.config.keys orelse {
        input.clearArrowOverrides();
        return;
    };
    input.setArrowOverrides(.{
        .up = narrowKey(keys.up),
        .down = narrowKey(keys.down),
        .left = narrowKey(keys.left),
        .right = narrowKey(keys.right),
        .a = narrowKey(keys.a),
        .b = narrowKey(keys.b),
        .p2_up = narrowKey(keys.player2Up),
        .p2_down = narrowKey(keys.player2Down),
        .p2_left = narrowKey(keys.player2Left),
        .p2_right = narrowKey(keys.player2Right),
        .p2_a = narrowKey(keys.player2A),
        .p2_b = narrowKey(keys.player2B),
    });
}

// The database schema stores keypad targets as integers, but CHIP-8 only
// has 16 keys — anything outside [0,15] is malformed data; drop it.
fn narrowKey(v: ?u8) ?u4 {
    const n = v orelse return null;
    if (n > 0xF) return null;
    return @intCast(n);
}

// If the ROM path points to a sidecar-carrying installed file, return its
// config_override. Otherwise null. Best-effort: failures are swallowed so
// a missing/corrupt sidecar doesn't block ROM load.
fn loadSidecarOverrideAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    app_data_root: []const u8,
    rom_path: []const u8,
) !?models.RomConfigOverride {
    _ = app_data_root;
    if (!std.mem.endsWith(u8, rom_path, ".ch8")) return null;
    const sidecar = try std.fmt.allocPrint(allocator, "{s}.json", .{rom_path[0 .. rom_path.len - 4]});
    defer allocator.free(sidecar);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, sidecar, allocator, .limited(1 * 1024 * 1024)) catch return null;
    defer allocator.free(bytes);

    const parsed = std.json.parseFromSlice(models.InstalledRom, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    if (parsed.value.config_override) |o| {
        return try o.clone(allocator);
    }
    return null;
}

fn printRuntimeNotification(display_name: []const u8, resolution: runtime_check.ConfigResolution) void {
    switch (resolution.layer) {
        .database_match => {
            std.debug.print("[db] {s}  platform={s}  tickrate={d}", .{ display_name, resolution.config.platform, resolution.config.tickrate });
            if (resolution.config.start_address != 0x200) std.debug.print("  start=0x{X:0>3}", .{resolution.config.start_address});
            if (resolution.config.font_style) |f| std.debug.print("  font={s}", .{f});
            if (resolution.override_applied) std.debug.print("  +override", .{});
            std.debug.print("\n", .{});
        },
        .inference => {
            std.debug.print("[inferred] {s}  platform={s}  confidence={d:.2}  reason={s}", .{
                display_name,
                resolution.config.platform,
                resolution.confidence,
                resolution.reasoning orelse "",
            });
            if (resolution.override_applied) std.debug.print("  +override", .{});
            std.debug.print("\n", .{});
        },
        .fallback => {
            std.debug.print("[fallback] {s}  platform={s}", .{ display_name, resolution.config.platform });
            if (resolution.override_applied) std.debug.print("  +override", .{});
            std.debug.print("\n", .{});
        },
    }
    if (resolution.embedded_title_mismatch) |m| {
        std.debug.print("  ! embedded title mismatch: expected \"{s}\", found \"{s}\"\n", .{ m.expected, m.found });
    }
}

fn preferredProfile(saved: emulation.QuirkProfile, inferred: emulation.QuirkProfile) emulation.QuirkProfile {
    return if (profileRank(inferred) > profileRank(saved) or inferred == .octo_xo and saved != .octo_xo)
        inferred
    else
        saved;
}

fn profileRank(profile: emulation.QuirkProfile) u8 {
    return switch (profile) {
        .modern, .vip_legacy => 0,
        .chip48 => 1,
        .schip_legacy, .schip_modern => 2,
        .xo_chip => 3,
        .octo_xo => 4,
    };
}

fn reloadLoadedRom(chip8: *Chip8, loaded_rom: LoadedRom, config: emulation.EmulationConfig) !void {
    // Preserve the resolved font variant and start address across reload.
    // Previously this reinitialized with the default font and loaded the
    // ROM at hardcoded 0x200, silently dropping ETI-660 layouts and any
    // platform-specific font (vip/dream6800/etc.) on every reset.
    const style: fonts.FontStyle = if (loaded_rom.font_style) |name|
        fonts.FontStyle.fromString(name) orelse fonts.default_style
    else
        fonts.default_style;
    chip8.* = Chip8.initWithConfigAndFont(config, style);
    seedChip8(chip8);
    try chip8.loadRomAt(loaded_rom.data, loaded_rom.start_address);
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
        .rom_sha1 = loaded_rom.sha1,
        .quirk_profile = chip8.config.quirk_profile,
        .chip8_state = chip8.snapshot(),
        .cpu_hz_target = @intFromFloat(timing_state.cpu_hz_target),
        .paused_state = state != .running,
    };
    try persistence.saveEnvelopeToFile(init.io, init.gpa, app_data_root, loaded_rom.sha1_hex, slot, &envelope);
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
    const envelope = try persistence.loadEnvelopeFromFile(init.io, init.gpa, app_data_root, loaded_rom.sha1_hex, slot);
    if (!std.mem.eql(u8, &envelope.rom_sha1, &loaded_rom.sha1)) return error.SaveStateRomMismatch;
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
            rom.sha1_hex,
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
            var mutable_init = init.*;
            return try loadRomIntoRuntime(&mutable_init, app_data_root, app_state, path, null, chip8, timing_state, ui_state);
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

fn exportCurrentSource(
    init: *const std.process.Init,
    app_data_root: []const u8,
    loaded_rom: LoadedRom,
    chip8: *const Chip8,
    ui_state: *ui_mod.UiState,
) !void {
    const export_path = try persistence.sourceExportPathAlloc(init.gpa, app_data_root, loaded_rom.sha1_hex, loaded_rom.display_name);
    defer init.gpa.free(export_path);

    const export_dir = std.fs.path.dirname(export_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(init.io, export_dir);

    var exported = try assembly.exportAnnotatedSource(init.gpa, .{
        .rom_name = loaded_rom.display_name,
        .sha1_hex = loaded_rom.sha1_hex,
        .profile = chip8.config.quirk_profile,
        .start_address = loaded_rom.start_address,
    }, loaded_rom.data);
    defer exported.deinit(init.gpa);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = export_path,
        .data = exported.source,
    });

    const goto_line = exported.lineForAddress(chip8.cpu.program_counter) orelse exported.lineForAddress(loaded_rom.start_address) orelse 1;
    if (try isVsCodeAvailable(init)) {
        try openInVsCode(init, export_path, goto_line);
        ui_state.setStatusFmt("Opened source in VS Code: {s}", .{export_path});
    } else {
        ui_state.setStatusFmt("Exported source: {s}", .{export_path});
    }
}

fn isVsCodeAvailable(init: *const std.process.Init) !bool {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ "sh", "-c", "command -v code >/dev/null 2>&1" },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn openInVsCode(init: *const std.process.Init, path: []const u8, line: usize) !void {
    const goto_target = try cli.buildEditorGotoTargetAlloc(init.gpa, path, line);
    defer init.gpa.free(goto_target);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{
            "sh",
            "-c",
            "command -v code >/dev/null 2>&1 || exit 127; code --goto \"$1\" >/dev/null 2>&1 &",
            "sh",
            goto_target,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(init.io);
}

fn resolveToken(init: std.process.Init, config: config_mod.Config) !?[]const u8 {
    return try github_mod.resolveToken(init.gpa, init.minimal.environ, config.github_token);
}

fn runGetCommand(init: std.process.Init, source: []const u8, launch: bool) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    var config = try config_mod.loadConfig(init.io, init.gpa, app_data_root);
    defer config.deinit(init.gpa);

    const tok = try resolveToken(init, config);
    if (config.github_token == null and tok != null) config.github_token = tok.?;
    defer if (config.github_token != null and tok != null) init.gpa.free(tok.?);

    const source_url = url_mod.parse(init.gpa, source) catch |err| switch (err) {
        error.UnquotedGlob => {
            std.debug.print("Error: the argument looks like an unquoted glob. Try quoting it:\n  chip8 get '{s}'\n", .{source});
            return;
        },
        else => return err,
    };
    defer source_url.deinit(init.gpa);

    var state = try state_mod.loadState(init.io, init.gpa, app_data_root);
    defer state.deinit();
    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    var ctx = registry.InstallContext{
        .io = init.io,
        .allocator = init.gpa,
        .app_data_root = app_data_root,
        .config = config,
        .state = &state,
        .db_cache = &db_cache,
    };

    std.debug.print("Fetching {s}...\n", .{source});
    const installed = registry.install(&ctx, source_url) catch |err| {
        printRegistryError(err, source);
        return;
    };
    defer installed.deinit(init.gpa);

    try state_mod.saveState(init.io, init.gpa, app_data_root, &state);
    try chip8_db_cache.save(init.io, init.gpa, app_data_root, &db_cache);

    if (registry.installedRegistryName(installed)) |ns| {
        std.debug.print("Installed {s}:{s}  (run with: chip8 {s}:{s})\n", .{ ns, installed.metadata.id, ns, installed.metadata.id });
    } else {
        std.debug.print("Installed {s}  (run with: chip8 {s})\n", .{ installed.metadata.id, installed.metadata.id });
    }
    if (installed.metadata.chip8_db_entry) |e| {
        std.debug.print("  {s} ({s})\n", .{ e.title, e.release });
    }

    if (launch) {
        // Dupe the path before `installed` is freed by its defer.
        const launch_path = try init.gpa.dupe(u8, installed.local.path);
        defer init.gpa.free(launch_path);
        try runGui(init, launch_path, null);
    }
}

fn runSearchCommand(init: std.process.Init, query: []const u8) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    var state = try state_mod.loadState(init.io, init.gpa, app_data_root);
    defer state.deinit();
    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    const results = try registry.search(init.gpa, query, &state, &db_cache);
    defer {
        for (results) |r| r.deinit(init.gpa);
        init.gpa.free(results);
    }

    if (results.len == 0) {
        std.debug.print("No results found. Try `chip8 refresh` to fetch registry state.\n", .{});
        return;
    }

    for (results) |res| {
        const title = if (res.metadata.chip8_db_entry) |e| e.title else res.metadata.id;
        std.debug.print("  {s}:{s}  -  {s}\n", .{ res.registry_name, res.metadata.id, title });
    }
}

fn runListCommand(init: std.process.Init) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    const installed = try registry.listInstalled(init.io, init.gpa, app_data_root);
    defer {
        for (installed) |i| i.deinit(init.gpa);
        init.gpa.free(installed);
    }

    if (installed.len == 0) {
        std.debug.print("No ROMs installed.\n", .{});
        return;
    }

    std.debug.print("Installed ROMs  (run with: chip8 <launch-id>)\n", .{});
    for (installed) |rom| {
        const title = if (rom.metadata.chip8_db_entry) |e| e.title else rom.metadata.file;
        // "*" marks ROMs with a user-set config_override. Keeps the list
        // compact while making override-state discoverable (`chip8 override
        // <id> --show` prints the details).
        const mark: []const u8 = if (rom.config_override != null) " *" else "";
        if (registry.installedRegistryName(rom)) |ns| {
            std.debug.print("  {s}:{s}{s}  ({s})\n", .{ ns, rom.metadata.id, mark, title });
        } else {
            std.debug.print("  {s}{s}  ({s})\n", .{ rom.metadata.id, mark, title });
        }
    }
}

fn runRemoveCommand(init: std.process.Init, id: []const u8) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    try registry.remove(init.io, init.gpa, id, app_data_root);
    std.debug.print("Removed {s}.\n", .{id});
}

fn runUpdateCommand(init: std.process.Init, id: ?[]const u8) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    var config = try config_mod.loadConfig(init.io, init.gpa, app_data_root);
    defer config.deinit(init.gpa);

    const tok = try resolveToken(init, config);
    if (config.github_token == null and tok != null) config.github_token = tok.?;
    defer if (config.github_token != null and tok != null) init.gpa.free(tok.?);

    var state = try state_mod.loadState(init.io, init.gpa, app_data_root);
    defer state.deinit();
    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    var ctx = registry.InstallContext{
        .io = init.io,
        .allocator = init.gpa,
        .app_data_root = app_data_root,
        .config = config,
        .state = &state,
        .db_cache = &db_cache,
    };

    if (id) |only_id| {
        const updated = registry.update(&ctx, only_id) catch |err| {
            printRegistryError(err, only_id);
            return;
        };
        defer updated.deinit(init.gpa);
        std.debug.print("Updated {s}.\n", .{only_id});
    } else {
        const installed = try registry.listInstalled(init.io, init.gpa, app_data_root);
        defer {
            for (installed) |i| i.deinit(init.gpa);
            init.gpa.free(installed);
        }
        for (installed) |rom| {
            const updated = registry.update(&ctx, rom.metadata.id) catch |err| {
                std.debug.print("  {s}: {s}\n", .{ rom.metadata.id, @errorName(err) });
                continue;
            };
            defer updated.deinit(init.gpa);
            std.debug.print("  {s}: ok\n", .{rom.metadata.id});
        }
    }

    try state_mod.saveState(init.io, init.gpa, app_data_root, &state);
    try chip8_db_cache.save(init.io, init.gpa, app_data_root, &db_cache);
}

fn runRefreshCommand(init: std.process.Init, cmd: cli.RefreshCommand) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    var config = try config_mod.loadConfig(init.io, init.gpa, app_data_root);
    defer config.deinit(init.gpa);

    const tok = try resolveToken(init, config);
    if (config.github_token == null and tok != null) config.github_token = tok.?;
    defer if (config.github_token != null and tok != null) init.gpa.free(tok.?);

    var state = try state_mod.loadState(init.io, init.gpa, app_data_root);
    defer state.deinit();
    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    if (cmd.db_only) {
        std.debug.print("Refreshing chip-8-database cache...\n", .{});
        chip8_db_cache.refreshAll(init.io, init.gpa, &db_cache) catch |err| {
            std.debug.print("Failed: {s}\n", .{@errorName(err)});
            return;
        };
        try chip8_db_cache.save(init.io, init.gpa, app_data_root, &db_cache);
        std.debug.print("Done.\n", .{});
        return;
    }

    if (cmd.registry_name) |name| {
        std.debug.print("Refreshing {s}...\n", .{name});
        state_mod.syncRegistry(init.io, init.gpa, &state, name, config, &db_cache) catch |err| {
            std.debug.print("Failed: {s}\n", .{@errorName(err)});
            return;
        };
    } else {
        std.debug.print("Refreshing all registries...\n", .{});
        try state_mod.syncAll(init.io, init.gpa, &state, config, &db_cache);
    }

    try state_mod.saveState(init.io, init.gpa, app_data_root, &state);
    try chip8_db_cache.save(init.io, init.gpa, app_data_root, &db_cache);
    std.debug.print("Done.\n", .{});
}

fn runRegistriesCommand(init: std.process.Init) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    const config = try config_mod.loadConfig(init.io, init.gpa, app_data_root);
    defer config.deinit(init.gpa);

    var state = try state_mod.loadState(init.io, init.gpa, app_data_root);
    defer state.deinit();

    std.debug.print("Known Registries:\n", .{});
    for (config.known_registries) |reg| {
        std.debug.print("  - {s} (GitHub: {s})\n", .{ reg.name, reg.repo });
        if (state.get(reg.name)) |rs| {
            std.debug.print("      last_synced: {d}, entries: {d}\n", .{ rs.last_synced, rs.entries.len });
        } else {
            std.debug.print("      last_synced: never\n", .{});
        }
        for (reg.globs) |glob| {
            std.debug.print("      {s}\n", .{glob});
        }
    }
}

fn runInitCommand(init: std.process.Init, path: ?[]const u8) !void {
    const target = path orelse ".";

    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    const manifest = try spec_mod.scaffoldManifest(init.io, init.gpa, target, &db_cache);
    defer manifest.deinit(init.gpa);

    const manifest_path = try std.fmt.allocPrint(init.gpa, "{s}/chip8.json", .{target});
    defer init.gpa.free(manifest_path);

    var writer: std.Io.Writer.Allocating = .init(init.gpa);
    defer writer.deinit();
    try std.json.Stringify.value(manifest, .{ .whitespace = .indent_2 }, &writer.writer);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = manifest_path, .data = writer.written() });

    std.debug.print("Wrote {s} ({d} roms)\n", .{ manifest_path, manifest.roms.len });
}

fn runValidateCommand(init: std.process.Init, path: ?[]const u8) !void {
    const file_path = blk: {
        if (path) |p| {
            if (std.mem.endsWith(u8, p, ".json")) break :blk try init.gpa.dupe(u8, p);
            break :blk try std.fmt.allocPrint(init.gpa, "{s}/chip8.json", .{p});
        }
        break :blk try init.gpa.dupe(u8, "chip8.json");
    };
    defer init.gpa.free(file_path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, init.gpa, .limited(1 * 1024 * 1024));
    defer init.gpa.free(bytes);

    const result = try spec_mod.validateManifest(init.gpa, bytes);
    defer result.deinit(init.gpa);

    switch (result) {
        .ok => |m| std.debug.print("ok — {d} roms, spec_version {d}\n", .{ m.roms.len, m.spec_version }),
        .errors => |errs| {
            std.debug.print("INVALID — {d} errors:\n", .{errs.len});
            for (errs) |e| std.debug.print("  {s}: {s}\n", .{ e.field_path, e.message });
            std.process.exit(1);
        },
    }
}

fn runVerifyCommand(init: std.process.Init, cmd: cli.VerifyCommand) !void {
    switch (cmd) {
        .tests => |t| try runVerifyTest(init, t.test_id, t.rom_path, t.reference_hash, t.json),
        .axis => |a| try runVerifyAxis(init, a),
        .inference => |i| try runVerifyInference(init, i.max_disagreements, i.threshold_pct, i.save, i.json),
        .all => |a| try runVerifyAll(init, a.json, a.diff, a.save, a.diff_age),
    }
}

fn runVerifyAll(init: std.process.Init, json: bool, diff: bool, save: bool, diff_age: u32) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    const installed = try registry.listInstalled(init.io, init.gpa, app_data_root);
    defer {
        for (installed) |r| r.deinit(init.gpa);
        init.gpa.free(installed);
    }

    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    var ref_store = ref_fb_mod.load(init.io, init.gpa, app_data_root) catch ref_fb_mod.Store{ .allocator = init.gpa };
    defer ref_store.deinit();

    const report = try corpus_mod.runAll(.{
        .io = init.io,
        .allocator = init.gpa,
        .installed = installed,
        .db_cache = &db_cache,
        .ref_store = &ref_store,
    });
    defer report.deinit(init.gpa);

    var buf: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const w = &stdout_writer.interface;
    if (json) {
        try verify_report.formatJson(init.gpa, report, w);
    } else {
        try verify_report.formatHuman(report, w);
    }

    const current_entries = try verify_report.entriesForHistory(init.gpa, report);
    defer verify_report.freeHistoryEntries(init.gpa, current_entries);

    const history_path = try std.fmt.allocPrint(init.gpa, "{s}/verification/verify_history.json", .{app_data_root});
    defer init.gpa.free(history_path);

    // Load the existing history file. Try the new rolling-window shape
    // first; fall back to the legacy single-snapshot shape for backward
    // compat with files written before this feature.
    const multi_parsed = cache.readJson(init.io, init.gpa, history_path, verify_report.MultiHistory) catch null;
    defer if (multi_parsed) |p| p.deinit();

    var legacy_parsed: ?std.json.Parsed(verify_report.HistorySnapshot) = null;
    defer if (legacy_parsed) |p| p.deinit();

    const existing_history: verify_report.MultiHistory = if (multi_parsed) |p|
        p.value
    else blk: {
        legacy_parsed = cache.readJson(init.io, init.gpa, history_path, verify_report.HistorySnapshot) catch null;
        if (legacy_parsed) |p| {
            // Legacy single-snapshot file — wrap in a one-run history.
            const runs = try init.gpa.alloc(verify_report.HistorySnapshot, 1);
            runs[0] = p.value;
            break :blk verify_report.MultiHistory{ .runs = runs };
        }
        break :blk verify_report.MultiHistory{ .runs = &.{} };
    };
    // Adopt legacy runs into a gpa slice we can free below.
    const legacy_wrapper: bool = legacy_parsed != null;

    // --diff: pick baseline run, compare, and exit non-zero on regressions.
    var had_regression = false;
    if (diff) {
        const baseline_snapshot = existing_history.nthFromEnd(diff_age);
        const baseline_entries: []const verify_report.HistoryEntry = if (baseline_snapshot) |s| s.entries else &.{};
        const d = try verify_report.diffReports(init.gpa, baseline_entries, current_entries);
        defer d.deinit(init.gpa);

        if (!json) {
            const label = if (diff_age == 0) "last" else "older";
            if (baseline_snapshot == null) {
                try w.print("\nDiff vs {s} run: (no baseline recorded at that depth)\n", .{label});
            } else {
                try w.print("\nDiff vs {s} run [{d} runs back] ({d} unchanged, {d} changed):\n", .{ label, diff_age, d.unchanged_count, d.changed.len });
                for (d.changed) |row| {
                    try w.print("  {s} :: {s}  {s} → {s}\n", .{ row.axis, row.rom_id, row.before, row.after });
                }
                if (d.changed.len == 0) try w.print("  (none)\n", .{});
            }
        }
        had_regression = d.hasRegressions();
    }

    try w.flush();

    if (save) {
        // Append current run + truncate to the rolling window.
        const new_run = verify_report.HistorySnapshot{
            .timestamp_ms = std.Io.Clock.now(.real, init.io).toMilliseconds(),
            .entries = current_entries,
        };
        const combined_len = existing_history.runs.len + 1;
        const start: usize = if (combined_len > verify_report.HISTORY_MAX_RUNS) combined_len - verify_report.HISTORY_MAX_RUNS else 0;
        const keep = combined_len - start;
        const runs = try init.gpa.alloc(verify_report.HistorySnapshot, keep);
        defer init.gpa.free(runs);
        // `start` here is relative to the combined (old + new) list. Copy
        // the appropriate suffix of old runs, then append the new one.
        const old_take = existing_history.runs.len - @min(start, existing_history.runs.len);
        const old_start = existing_history.runs.len - old_take;
        var i: usize = 0;
        while (i < old_take) : (i += 1) runs[i] = existing_history.runs[old_start + i];
        runs[keep - 1] = new_run;

        const view = verify_report.MultiHistory{ .runs = runs };
        try cache.writeJsonAtomic(init.io, init.gpa, history_path, view);
    }

    // If we adopted the legacy file into a one-element slice via alloc,
    // free that slice now that persistence is done.
    if (legacy_wrapper) init.gpa.free(existing_history.runs);

    const s = report.summary();
    if (s.fail > 0 or s.err > 0 or had_regression) std.process.exit(1);
}

fn runVerifyTest(init: std.process.Init, test_id_str: []const u8, rom_path_opt: ?[]const u8, reference: ?[]const u8, json: bool) !void {
    const test_id = verify_test_suite.TestId.fromString(test_id_str) orelse {
        std.debug.print("Unknown test id: {s}  (known: 1-chip8-logo, 2-ibm-logo, 3-corax+, 4-flags, 5-quirks, 7-beep, 8-scrolling)\n", .{test_id_str});
        std.process.exit(2);
    };

    const resolved_path = if (rom_path_opt) |p|
        try init.gpa.dupe(u8, p)
    else
        (try resolveInstalledTestRom(init, test_id)) orelse {
            std.debug.print("No ROM path supplied and no installed copy found.\n  Install it first: chip8 get timendus:{s}\n", .{test_id.displayName()});
            std.process.exit(2);
        };
    defer init.gpa.free(resolved_path);

    const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, resolved_path, init.gpa, .limited(cpu_mod.CHIP8_MEMORY_SIZE));
    defer init.gpa.free(rom_bytes);

    // SHA-1 of the ROM: lets the axis look up a shipped reference hash
    // without the user typing it on the CLI.
    const sha1_bin = models.computeRomSha1(rom_bytes);
    const sha1_hex = try models.sha1HexAlloc(init.gpa, sha1_bin);
    defer init.gpa.free(sha1_hex);

    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);
    var store = ref_fb_mod.load(init.io, init.gpa, app_data_root) catch ref_fb_mod.Store{ .allocator = init.gpa };
    defer store.deinit();

    // Per-test dispatch: each Timendus test targets a different behavior
    // class, so route to the axis that actually grades that class. Falling
    // through to the framebuffer runner is the default for display-heavy
    // tests; tests that have a dedicated axis use it.
    switch (test_id) {
        .quirks => {
            const reports = try axis_quirks.runForRom(init.gpa, rom_bytes, .{
                .store = &store,
                .rom_sha1 = sha1_hex,
                .rom_id = test_id.displayName(),
            });
            defer {
                for (reports) |r| r.deinit(init.gpa);
                init.gpa.free(reports);
            }
            var worst: verify_report.Verdict = .pass;
            for (reports) |r| {
                try emitAxisReportOut(init, r, json);
                if (r.verdict == .harness_error) worst = .harness_error;
                if (r.verdict == .fail and worst != .harness_error) worst = .fail;
            }
            if (worst == .fail or worst == .harness_error) std.process.exit(1);
            return;
        },
        .beep => {
            const rep = try axis_sound.runForRom(init.gpa, rom_bytes, .{
                .rom_id = test_id.displayName(),
            });
            defer rep.deinit(init.gpa);
            try emitAxisReportOut(init, rep, json);
            if (rep.verdict == .fail or rep.verdict == .harness_error) std.process.exit(1);
            return;
        },
        .chip8_logo, .ibm_logo, .corax_plus, .flags, .scrolling => {
            const rep = try axis_opcodes.runFramebufferAxis(init.gpa, rom_bytes, .{
                .test_id = test_id,
                .rom_id = test_id.displayName(),
                .axis_name = if (test_id == .scrolling) "display" else "opcodes",
                .reference_hash = reference,
                .store = &store,
                .rom_sha1 = sha1_hex,
                .min_lit_pixels = if (test_id == .scrolling) 100 else 0,
            });
            defer rep.deinit(init.gpa);
            try emitAxisReportOut(init, rep, json);
            if (rep.verdict == .fail or rep.verdict == .harness_error) std.process.exit(1);
            return;
        },
    }
}

// Look for a Timendus test ROM that the user has installed. Matches either
// `installed_roms/timendus/<id>.ch8` (the registry-shorthand install path)
// or any installed ROM whose metadata.id equals the test display name.
fn resolveInstalledTestRom(init: std.process.Init, test_id: verify_test_suite.TestId) !?[]u8 {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    const direct = try std.fmt.allocPrint(init.gpa, "{s}/installed_roms/timendus/{s}.ch8", .{ app_data_root, test_id.displayName() });
    if (std.Io.Dir.cwd().statFile(init.io, direct, .{})) |_| {
        return direct;
    } else |_| {
        init.gpa.free(direct);
    }

    // Fall back to scanning sidecars — covers users who installed the test
    // via `chip8 get <url>` rather than `chip8 get timendus:<id>`.
    const installed = try registry.listInstalled(init.io, init.gpa, app_data_root);
    defer {
        for (installed) |r| r.deinit(init.gpa);
        init.gpa.free(installed);
    }
    for (installed) |rom| {
        if (std.mem.eql(u8, rom.metadata.id, test_id.displayName())) {
            return try init.gpa.dupe(u8, rom.local.path);
        }
    }
    return null;
}

fn runVerifyAxis(init: std.process.Init, a: anytype) !void {
    if (std.mem.eql(u8, a.axis_name, "opcodes")) {
        const rom_path = a.rom_path orelse {
            std.debug.print("axis opcodes requires a ROM path\n", .{});
            std.process.exit(2);
        };
        const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, init.gpa, .limited(cpu_mod.CHIP8_MEMORY_SIZE));
        defer init.gpa.free(rom_bytes);
        const rep = try axis_opcodes.runCoraxPlus(init.gpa, rom_bytes, .{
            .rom_id = rom_path,
            .reference_hash = a.reference_hash,
        });
        defer rep.deinit(init.gpa);
        try emitAxisReportOut(init, rep, a.json);
        if (rep.verdict == .fail or rep.verdict == .harness_error) std.process.exit(1);
        return;
    }

    if (std.mem.eql(u8, a.axis_name, "memory")) {
        // Always runs synthetic invariants; if a ROM was supplied, also runs
        // the startAddress-honor check.
        const rep_synth = try axis_memory.runSyntheticInvariants(init.gpa);
        defer rep_synth.deinit(init.gpa);
        try emitAxisReportOut(init, rep_synth, a.json);

        if (a.rom_path) |rom_path| {
            const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, init.gpa, .limited(cpu_mod.CHIP8_MEMORY_SIZE));
            defer init.gpa.free(rom_bytes);
            const rep_rom = try axis_memory.runForRom(init.gpa, rom_bytes, .{
                .rom_id = rom_path,
                .start_address = a.start_address orelse 0x200,
            });
            defer rep_rom.deinit(init.gpa);
            try emitAxisReportOut(init, rep_rom, a.json);
            if (rep_synth.verdict == .fail or rep_rom.verdict == .fail) std.process.exit(1);
        } else if (rep_synth.verdict == .fail) {
            std.process.exit(1);
        }
        return;
    }

    if (std.mem.eql(u8, a.axis_name, "sound")) {
        const rep = try axis_sound.runSyntheticInvariants(init.gpa);
        defer rep.deinit(init.gpa);
        try emitAxisReportOut(init, rep, a.json);
        if (rep.verdict == .fail) std.process.exit(1);
        return;
    }

    if (std.mem.eql(u8, a.axis_name, "timing")) {
        const rep = try axis_timing.runSyntheticInvariants(init.gpa);
        defer rep.deinit(init.gpa);
        try emitAxisReportOut(init, rep, a.json);
        if (rep.verdict == .fail) std.process.exit(1);
        return;
    }

    if (std.mem.eql(u8, a.axis_name, "quirks")) {
        // Auto-resolve 5-quirks.ch8 when no path was passed.
        const rom_path = a.rom_path orelse (try resolveInstalledTestRom(init, .quirks)) orelse {
            std.debug.print("axis quirks needs 5-quirks.ch8. Run `chip8 get timendus:5-quirks` first.\n", .{});
            std.process.exit(2);
        };
        defer if (a.rom_path == null) init.gpa.free(rom_path);
        const rom_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, init.gpa, .limited(cpu_mod.CHIP8_MEMORY_SIZE));
        defer init.gpa.free(rom_bytes);

        // Reference store for precise grading when captures exist.
        const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
        defer init.gpa.free(app_data_root);
        var store = ref_fb_mod.load(init.io, init.gpa, app_data_root) catch ref_fb_mod.Store{ .allocator = init.gpa };
        defer store.deinit();
        const sha1_bin = models.computeRomSha1(rom_bytes);
        const sha1_hex = try models.sha1HexAlloc(init.gpa, sha1_bin);
        defer init.gpa.free(sha1_hex);

        const reports = try axis_quirks.runForRom(init.gpa, rom_bytes, .{
            .rom_id = "5-quirks",
            .store = &store,
            .rom_sha1 = sha1_hex,
        });
        defer {
            for (reports) |r| r.deinit(init.gpa);
            init.gpa.free(reports);
        }
        var any_failed = false;
        for (reports) |r| {
            try emitAxisReportOut(init, r, a.json);
            if (r.verdict == .fail or r.verdict == .harness_error) any_failed = true;
        }
        if (any_failed) std.process.exit(1);
        return;
    }

    std.debug.print("Unknown axis: {s}  (available: opcodes, memory, sound, timing, quirks)\n", .{a.axis_name});
    std.process.exit(2);
}

const AuditCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
};

fn readInstalledBytes(raw_ctx: *anyopaque, rom: models.InstalledRom) anyerror!?[]const u8 {
    const ctx: *AuditCtx = @ptrCast(@alignCast(raw_ctx));
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, rom.local.path, ctx.allocator, .limited(cpu_mod.CHIP8_MEMORY_SIZE)) catch return null;
    return bytes;
}

fn runVerifyInference(init: std.process.Init, max_disagreements: u32, threshold_pct: f32, save: bool, json: bool) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    const installed = try registry.listInstalled(init.io, init.gpa, app_data_root);
    defer {
        for (installed) |r| r.deinit(init.gpa);
        init.gpa.free(installed);
    }

    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    // Arena for the throw-away ROM byte reads during grading.
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    var ctx = AuditCtx{ .io = init.io, .allocator = arena_state.allocator() };

    const report = try inference_audit.gradeInstalled(
        init.gpa,
        installed,
        &db_cache,
        readInstalledBytes,
        @ptrCast(&ctx),
    );
    defer report.deinit(init.gpa);

    var buf: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const w = &stdout_writer.interface;

    // Regression check (needed by both text + JSON paths).
    const history = try inference_audit.loadHistory(init.io, init.gpa, app_data_root);
    defer inference_audit.freeHistory(init.gpa, history);
    const check = inference_audit.checkRegression(history, report, threshold_pct);

    if (json) {
        try emitInferenceJson(init.gpa, w, report, check, threshold_pct, max_disagreements);
    } else {
        if (report.total_roms_graded == 0) {
            try w.print("No installed ROMs had chip-8-database matches to grade against. Install some ROMs first.\n", .{});
        } else {
            try w.print("Inference audit across {d} installed ROMs with db-cache hits\n", .{report.total_roms_graded});
            try w.print("  platform accuracy: {d:.2}%  (exact={d}, acceptable={d}, wrong={d})\n", .{
                report.platformAccuracy() * 100.0,
                report.exact_match,
                report.acceptable,
                report.wrong,
            });
            try w.print("  quirk accuracy (mapped subset): {d:.2}%\n", .{report.overallQuirkAccuracy() * 100.0});
            for (report.per_quirk) |q| {
                try w.print("    {s:<10} {d:.2}%  (tp={d} tn={d} fp={d} fn={d})\n", .{
                    q.quirk,
                    q.matrix.accuracy() * 100.0,
                    q.matrix.true_positive,
                    q.matrix.true_negative,
                    q.matrix.false_positive,
                    q.matrix.false_negative,
                });
            }
            if (report.platform_disagreements.len > 0) {
                const shown = @min(report.platform_disagreements.len, max_disagreements);
                try w.print("  disagreements (showing {d}/{d}):\n", .{ shown, report.platform_disagreements.len });
                for (report.platform_disagreements[0..shown]) |d| {
                    try w.print("    sha1={s}  expected={s}  inferred={s}  reason={s}\n", .{
                        d.sha1,
                        d.expected_platform,
                        d.inferred_platform,
                        d.reasoning,
                    });
                }
            }

            switch (check.verdict) {
                .no_baseline => try w.print("  (no prior run recorded; establishing baseline)\n", .{}),
                .ok => {
                    const plat_delta = (check.current_platform - check.baseline_platform) * 100.0;
                    const quirk_delta = (check.current_quirk - check.baseline_quirk) * 100.0;
                    try w.print("  vs last run: platform {s}{d:.2}%, quirks {s}{d:.2}%  (threshold {d:.1}%)\n", .{ signStr(plat_delta), @abs(plat_delta), signStr(quirk_delta), @abs(quirk_delta), threshold_pct });
                },
                .regressed => {
                    const plat_delta = (check.current_platform - check.baseline_platform) * 100.0;
                    const quirk_delta = (check.current_quirk - check.baseline_quirk) * 100.0;
                    try w.print("  REGRESSION: platform {s}{d:.2}%, quirks {s}{d:.2}%  (threshold {d:.1}%)\n", .{ signStr(plat_delta), @abs(plat_delta), signStr(quirk_delta), @abs(quirk_delta), threshold_pct });
                },
            }
        }
    }

    if (save) {
        const now_ms = std.Io.Clock.now(.real, init.io).toMilliseconds();
        try inference_audit.appendToHistory(init.io, init.gpa, app_data_root, report, now_ms);
    }

    try w.flush();

    if (check.verdict == .regressed) std.process.exit(1);
}

fn runOverrideCommand(init: std.process.Init, cmd: cli.OverrideCommand) !void {
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    const installed = try registry.listInstalled(init.io, init.gpa, app_data_root);
    defer {
        for (installed) |r| r.deinit(init.gpa);
        init.gpa.free(installed);
    }

    // Same match rules as `chip8 remove` / `update`: bare id → single match
    // required, `<registry>:<id>` → scoped, AmbiguousQuery otherwise.
    const requested = registry.parseQualifiedId(cmd.rom_id);
    var match: ?models.InstalledRom = null;
    var multiple = false;
    for (installed) |rom| {
        if (!std.mem.eql(u8, rom.metadata.id, requested.id)) continue;
        if (requested.registry) |want| {
            const ns = registry.installedRegistryName(rom) orelse continue;
            if (!std.mem.eql(u8, ns, want)) continue;
        }
        if (match != null) {
            multiple = true;
            break;
        }
        match = rom;
    }
    if (multiple) {
        std.debug.print("Ambiguous id '{s}' — multiple installed ROMs match. Qualify with <registry>:<id>.\n", .{cmd.rom_id});
        std.process.exit(2);
    }
    const target = match orelse {
        std.debug.print("No installed ROM with id '{s}'. Run `chip8 list`.\n", .{cmd.rom_id});
        std.process.exit(2);
    };

    // --show reads without mutating.
    if (cmd.mode == .show) {
        try printOverride(init, target);
        return;
    }

    // Sidecar path: installed_roms/<...>/<id>.json (where … is the optional
    // registry namespace). The rom's local.path is `.../<id>.ch8`, so strip
    // the `.ch8` suffix and append `.json`.
    const rom_path = target.local.path;
    if (!std.mem.endsWith(u8, rom_path, ".ch8")) {
        std.debug.print("Unexpected rom path (not .ch8): {s}\n", .{rom_path});
        std.process.exit(2);
    }
    const sidecar_path = try std.fmt.allocPrint(init.gpa, "{s}.json", .{rom_path[0 .. rom_path.len - 4]});
    defer init.gpa.free(sidecar_path);

    // Build the next override: start from the current one (if any) and
    // overlay non-null fields from `cmd`. --clear drops it entirely.
    const next_override: ?models.RomConfigOverride = blk: {
        if (cmd.mode == .clear) break :blk null;
        break :blk try mergeOverride(init.gpa, target.config_override, cmd);
    };
    errdefer if (next_override) |o| o.deinit(init.gpa);

    // Rewrite the sidecar. We clone the rest of InstalledRom so ownership
    // stays clean; writing the existing `target` struct works too but is
    // more error-prone w.r.t. the `config_override` replacement.
    var updated = try target.clone(init.gpa);
    defer updated.deinit(init.gpa);
    if (updated.config_override) |o| o.deinit(init.gpa);
    updated.config_override = next_override;

    var writer: std.Io.Writer.Allocating = .init(init.gpa);
    defer writer.deinit();
    try std.json.Stringify.value(updated, .{ .whitespace = .indent_2 }, &writer.writer);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = sidecar_path, .data = writer.written() });

    if (cmd.mode == .clear) {
        std.debug.print("Cleared override for {s}.\n", .{cmd.rom_id});
    } else {
        std.debug.print("Override updated for {s}.\n", .{cmd.rom_id});
        try printOverride(init, updated);
    }
}

fn mergeOverride(
    allocator: std.mem.Allocator,
    existing: ?models.RomConfigOverride,
    cmd: cli.OverrideCommand,
) !models.RomConfigOverride {
    // Start from a clone of the existing override (or an empty one).
    var out: models.RomConfigOverride = if (existing) |e|
        try e.clone(allocator)
    else
        .{};
    errdefer out.deinit(allocator);

    if (cmd.platform) |p| {
        if (out.platform) |old| allocator.free(old);
        out.platform = try allocator.dupe(u8, p);
    }
    if (cmd.font_style) |f| {
        if (out.font_style) |old| allocator.free(old);
        out.font_style = try allocator.dupe(u8, f);
    }
    if (cmd.tickrate) |v| out.tickrate = v;
    if (cmd.start_address) |v| out.start_address = v;
    if (cmd.screen_rotation) |v| out.screen_rotation = v;

    // Quirks: merge field-by-field so the user can tweak one without losing
    // previous overrides.
    var q = out.quirks orelse models.QuirkSet{};
    if (cmd.shift) |v| q.shift = v;
    if (cmd.wrap) |v| q.wrap = v;
    if (cmd.jump) |v| q.jump = v;
    if (cmd.logic) |v| q.logic = v;
    if (cmd.memoryIncrementByX) |v| q.memoryIncrementByX = v;
    if (cmd.memoryLeaveIUnchanged) |v| q.memoryLeaveIUnchanged = v;
    if (cmd.vblank) |v| q.vblank = v;
    out.quirks = q;

    return out;
}

fn printOverride(init: std.process.Init, rom: models.InstalledRom) !void {
    _ = init;
    const o = rom.config_override orelse {
        std.debug.print("No override set for {s}.\n", .{rom.metadata.id});
        return;
    };
    std.debug.print("Override for {s}:\n", .{rom.metadata.id});
    if (o.platform) |v| std.debug.print("  platform = {s}\n", .{v});
    if (o.tickrate) |v| std.debug.print("  tickrate = {d}\n", .{v});
    if (o.start_address) |v| std.debug.print("  start_address = 0x{X:0>3}\n", .{v});
    if (o.screen_rotation) |v| std.debug.print("  screen_rotation = {d}\n", .{v});
    if (o.font_style) |v| std.debug.print("  font_style = {s}\n", .{v});
    if (o.quirks) |q| {
        if (q.shift) |v| std.debug.print("  quirks.shift = {s}\n", .{if (v) "on" else "off"});
        if (q.wrap) |v| std.debug.print("  quirks.wrap = {s}\n", .{if (v) "on" else "off"});
        if (q.jump) |v| std.debug.print("  quirks.jump = {s}\n", .{if (v) "on" else "off"});
        if (q.logic) |v| std.debug.print("  quirks.logic = {s}\n", .{if (v) "on" else "off"});
        if (q.memoryIncrementByX) |v| std.debug.print("  quirks.memoryIncrementByX = {s}\n", .{if (v) "on" else "off"});
        if (q.memoryLeaveIUnchanged) |v| std.debug.print("  quirks.memoryLeaveIUnchanged = {s}\n", .{if (v) "on" else "off"});
        if (q.vblank) |v| std.debug.print("  quirks.vblank = {s}\n", .{if (v) "on" else "off"});
    }
}

fn signStr(v: f32) []const u8 {
    return if (v >= 0) "+" else "-";
}

fn emitInferenceJson(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    report: inference_audit.Report,
    check: inference_audit.RegressionCheck,
    threshold_pct: f32,
    max_disagreements: u32,
) !void {
    const PerQuirk = struct {
        name: []const u8,
        accuracy_pct: f32,
        tp: u32,
        tn: u32,
        fp: u32,
        fn_: u32,
    };
    const Disagree = struct {
        sha1: []const u8,
        expected_platform: []const u8,
        inferred_platform: []const u8,
        reasoning: []const u8,
    };
    const Regression = struct {
        verdict: []const u8,
        baseline_platform_pct: f32,
        current_platform_pct: f32,
        baseline_quirk_pct: f32,
        current_quirk_pct: f32,
        worst_drop_pct: f32,
        threshold_pct: f32,
    };
    const View = struct {
        total_roms_graded: u32,
        platform: struct {
            accuracy_pct: f32,
            exact: u32,
            acceptable: u32,
            wrong: u32,
        },
        quirk: struct {
            overall_accuracy_pct: f32,
            per_quirk: []const PerQuirk,
        },
        disagreements: []const Disagree,
        regression: Regression,
    };

    const per_quirk = try allocator.alloc(PerQuirk, report.per_quirk.len);
    defer allocator.free(per_quirk);
    for (report.per_quirk, 0..) |q, i| {
        per_quirk[i] = .{
            .name = q.quirk,
            .accuracy_pct = q.matrix.accuracy() * 100.0,
            .tp = q.matrix.true_positive,
            .tn = q.matrix.true_negative,
            .fp = q.matrix.false_positive,
            .fn_ = q.matrix.false_negative,
        };
    }

    const shown = @min(report.platform_disagreements.len, max_disagreements);
    const disagreements = try allocator.alloc(Disagree, shown);
    defer allocator.free(disagreements);
    for (report.platform_disagreements[0..shown], 0..) |d, i| {
        disagreements[i] = .{
            .sha1 = d.sha1,
            .expected_platform = d.expected_platform,
            .inferred_platform = d.inferred_platform,
            .reasoning = d.reasoning,
        };
    }

    const verdict_str: []const u8 = switch (check.verdict) {
        .ok => "ok",
        .regressed => "regressed",
        .no_baseline => "no_baseline",
    };

    const view = View{
        .total_roms_graded = report.total_roms_graded,
        .platform = .{
            .accuracy_pct = report.platformAccuracy() * 100.0,
            .exact = report.exact_match,
            .acceptable = report.acceptable,
            .wrong = report.wrong,
        },
        .quirk = .{
            .overall_accuracy_pct = report.overallQuirkAccuracy() * 100.0,
            .per_quirk = per_quirk,
        },
        .disagreements = disagreements,
        .regression = .{
            .verdict = verdict_str,
            .baseline_platform_pct = check.baseline_platform * 100.0,
            .current_platform_pct = check.current_platform * 100.0,
            .baseline_quirk_pct = check.baseline_quirk * 100.0,
            .current_quirk_pct = check.current_quirk * 100.0,
            .worst_drop_pct = check.worst_drop_pct,
            .threshold_pct = threshold_pct,
        },
    };
    try std.json.Stringify.value(view, .{ .whitespace = .indent_2 }, w);
    try w.print("\n", .{});
}

fn emitAxisReport(init: std.process.Init, rep: verify_report.AxisReport) !void {
    try emitAxisReportOut(init, rep, false);
}

fn emitAxisReportOut(init: std.process.Init, rep: verify_report.AxisReport, json: bool) !void {
    var buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const w = &stdout_writer.interface;
    if (json) {
        try verify_report.formatAxisJson(init.gpa, rep, w);
    } else {
        try w.print("[{s}] {s} :: {s}  {s}\n", .{ rep.verdict.asString(), rep.axis_name, rep.rom_id, rep.details });
        for (rep.diagnostics) |d| try w.print("  - {s}: {s}\n", .{ d.kind, d.message });
    }
    try w.flush();
}

fn printRegistryError(err: anyerror, context: []const u8) void {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "UnquotedGlob")) {
        std.debug.print("Did you mean to quote the pattern? Try: chip8 get '{s}'\n", .{context});
    } else if (std.mem.eql(u8, name, "NotFoundStale")) {
        std.debug.print("'{s}' not found and couldn't verify live (network unavailable). Try `chip8 refresh` when online.\n", .{context});
    } else if (std.mem.eql(u8, name, "NoManifestFound")) {
        std.debug.print("No chip8.json in that repo. Try a specific file path or glob, e.g. 'user/repo/games/*.ch8'.\n", .{});
    } else if (std.mem.eql(u8, name, "AmbiguousQuery")) {
        std.debug.print("Multiple matches for '{s}'. Re-run with a specific id.\n", .{context});
    } else {
        std.debug.print("Error: {s} ({s})\n", .{ name, context });
    }
}

fn printCliUsage(init: std.process.Init, err: cli.ParseError) !void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.print("{s}\n\n{s}\n", .{ @errorName(err), cli.usage() });
    try stderr.flush();
}

fn runDisasmCommand(init: std.process.Init, rom_path: []const u8, output_path: ?[]const u8, requested_profile: ?emulation.QuirkProfile) !void {
    const rom_data = try std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, init.gpa, .limited(cpu_mod.CHIP8_MEMORY_SIZE - @as(usize, assembly.ROM_START)));
    defer init.gpa.free(rom_data);

    const sha = persistence.computeRomSha1(rom_data);
    const sha_hex = try persistence.sha1HexAlloc(init.gpa, sha);
    defer init.gpa.free(sha_hex);

    // Consult the resolver (database + sidecar + inference) so ETI-660-style
    // ROMs disassemble under their real start address rather than 0x200.
    const app_data_root = try persistence.defaultAppDataRootAlloc(init.gpa, init.minimal.environ);
    defer init.gpa.free(app_data_root);

    var db_cache = try chip8_db_cache.load(init.io, init.gpa, app_data_root);
    defer db_cache.deinit();

    const sidecar_override = try loadSidecarOverrideAlloc(init.io, init.gpa, app_data_root, rom_path);
    defer if (sidecar_override) |o| o.deinit(init.gpa);

    const config = try config_mod.loadConfig(init.io, init.gpa, app_data_root);
    defer config.deinit(init.gpa);

    const resolution = try runtime_check.resolveConfigForRom(
        init.gpa,
        rom_data,
        requested_profile,
        sidecar_override,
        &db_cache,
        config.auto_apply_db_config,
    );
    defer resolution.deinit(init.gpa);

    var exported = try assembly.exportAnnotatedSource(init.gpa, .{
        .rom_name = persistence.basename(rom_path),
        .sha1_hex = sha_hex,
        .profile = requested_profile orelse assembly.inferProfile(rom_data),
        .start_address = resolution.config.start_address,
    }, rom_data);
    defer exported.deinit(init.gpa);

    if (output_path) |path| {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = exported.source });
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(exported.source);
    try stdout.flush();
}

fn runAssembleCommand(init: std.process.Init, source_path: []const u8, output_path: ?[]const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(source);

    var assembled = try assembly.assembleSource(init.gpa, source);
    defer assembled.deinit(init.gpa);

    if (assembled.diagnostics.items.len > 0) {
        try printDiagnostics(init, source_path, assembled.diagnostics.items);
        std.process.exit(1);
    }

    const final_path = if (output_path) |path|
        try init.gpa.dupe(u8, path)
    else
        try cli.defaultAsmOutputPathAlloc(init.gpa, source_path);
    defer init.gpa.free(final_path);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = final_path,
        .data = assembled.bytes.?,
    });
}

fn runCheckCommand(init: std.process.Init, source_path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(source);

    var assembled = try assembly.assembleSource(init.gpa, source);
    defer assembled.deinit(init.gpa);

    if (assembled.diagnostics.items.len > 0) {
        try printDiagnostics(init, source_path, assembled.diagnostics.items);
        std.process.exit(1);
    }
}

fn printDiagnostics(init: std.process.Init, path: []const u8, diagnostics: []const assembly.Diagnostic) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    for (diagnostics) |diag| {
        try stderr.print("{s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.column, diag.message });
    }
    try stderr.flush();
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
        .vip_legacy => .chip48,
        .chip48 => .schip_legacy,
        .schip_legacy => .schip_modern,
        .schip_modern => .xo_chip,
        .xo_chip => .octo_xo,
        .octo_xo => .modern,
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
    if (addr < 0 or addr >= cpu_mod.CHIP8_MEMORY_SIZE - 1) return null;
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
