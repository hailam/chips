pub const PhysicalKey = enum {
    one,
    two,
    three,
    four,
    q,
    w,
    e,
    r,
    a,
    s,
    d,
    f,
    z,
    x,
    c,
    v,
    up,
    down,
    left,
    right,
    left_bracket,
    right_bracket,
    // Binding targets for chip-8-database's `keys.a` / `keys.b` overrides —
    // the "confirm" / "cancel" buttons many test ROMs expose. These don't
    // appear in `canonical_chip8_bindings` (they have no fixed CHIP-8 hex
    // position), only in the runtime override path in input.zig.
    space,
    left_shift,
    // Player-2 physical targets (classic arcade layout): IJKL for the
    // second-player d-pad, Period/Slash for action buttons. Same runtime-
    // only binding pattern as A/B.
    i,
    j,
    k,
    l,
    period,
    slash,
};

pub const Chip8Binding = struct {
    chip8_index: usize,
    physical_key: PhysicalKey,
};

pub const SpeedAction = enum {
    slower,
    faster,
};

pub const controls_label = "SPACE Run/Pause  N/Shift+N Step/Over  B Break  O Recent  F2 Source  F5/F9 Save/Load  [ ] Speed  M Mute  P Profile  G FX  F11 Full";
pub const controls_hint = "W/A/S/D or arrows play  Tab switches trace/cycle/watches  ; edits watch  Wheel over Memory, Code, or Trace to scroll";

pub const canonical_chip8_bindings = [_]Chip8Binding{
    .{ .chip8_index = 0x0, .physical_key = .x },
    .{ .chip8_index = 0x1, .physical_key = .one },
    .{ .chip8_index = 0x2, .physical_key = .two },
    .{ .chip8_index = 0x3, .physical_key = .three },
    .{ .chip8_index = 0x4, .physical_key = .q },
    .{ .chip8_index = 0x5, .physical_key = .w },
    .{ .chip8_index = 0x6, .physical_key = .e },
    .{ .chip8_index = 0x7, .physical_key = .a },
    .{ .chip8_index = 0x8, .physical_key = .s },
    .{ .chip8_index = 0x9, .physical_key = .d },
    .{ .chip8_index = 0xA, .physical_key = .z },
    .{ .chip8_index = 0xB, .physical_key = .c },
    .{ .chip8_index = 0xC, .physical_key = .four },
    .{ .chip8_index = 0xD, .physical_key = .r },
    .{ .chip8_index = 0xE, .physical_key = .f },
    .{ .chip8_index = 0xF, .physical_key = .v },
};

pub const arrow_alias_bindings = [_]Chip8Binding{
    .{ .chip8_index = 0x5, .physical_key = .up },
    .{ .chip8_index = 0x7, .physical_key = .left },
    .{ .chip8_index = 0x8, .physical_key = .down },
    .{ .chip8_index = 0x9, .physical_key = .right },
};

pub const speed_bindings = [_]struct {
    action: SpeedAction,
    physical_key: PhysicalKey,
}{
    .{ .action = .slower, .physical_key = .left_bracket },
    .{ .action = .faster, .physical_key = .right_bracket },
};

pub fn foldPressedChip8Keys(pressed: []const bool) [16]bool {
    var keys = [_]bool{false} ** 16;
    foldBindings(&keys, pressed, &canonical_chip8_bindings);
    foldBindings(&keys, pressed, &arrow_alias_bindings);
    return keys;
}

pub fn physicalKeyIndex(key: PhysicalKey) usize {
    return @intFromEnum(key);
}

fn foldBindings(keys: *[16]bool, pressed: []const bool, bindings: []const Chip8Binding) void {
    for (bindings) |binding| {
        if (pressed[physicalKeyIndex(binding.physical_key)]) {
            keys[binding.chip8_index] = true;
        }
    }
}
