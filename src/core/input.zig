const rl = @import("raylib");
const control = @import("control_spec.zig");

const physical_key_map = [_]rl.KeyboardKey{
    .one,
    .two,
    .three,
    .four,
    .q,
    .w,
    .e,
    .r,
    .a,
    .s,
    .d,
    .f,
    .z,
    .x,
    .c,
    .v,
    .up,
    .down,
    .left,
    .right,
    .left_bracket,
    .right_bracket,
    // Optional bind targets for the db's `keys.a` / `keys.b` overrides.
    // They're part of the poll so override lookup can see their state.
    .space,
    .left_shift,
    // Player-2 physical targets.
    .i,
    .j,
    .k,
    .l,
    .period,
    .slash,
};

// Per-ROM arrow-key overrides. When a chip-8-database match provides
// `keys.{up,down,left,right}`, loadRomIntoRuntime pushes them here and the
// poll loop prefers the override over the canonical 5/7/8/9 mapping. Null
// entries fall through to the canonical aliases in control_spec.zig so
// users always have *some* d-pad control, even on ROMs without db keys.
var arrow_overrides: ArrowOverrides = .{ .up = null, .down = null, .left = null, .right = null };

pub const ArrowOverrides = struct {
    up: ?u4,
    down: ?u4,
    left: ?u4,
    right: ?u4,
    a: ?u4 = null,
    b: ?u4 = null,
    // Player-2 d-pad + action bindings. Mapped to IJKL + Period/Slash at
    // the physical layer (see control_spec).
    p2_up: ?u4 = null,
    p2_down: ?u4 = null,
    p2_left: ?u4 = null,
    p2_right: ?u4 = null,
    p2_a: ?u4 = null,
    p2_b: ?u4 = null,
};

pub fn setArrowOverrides(next: ArrowOverrides) void {
    arrow_overrides = next;
}

pub fn clearArrowOverrides() void {
    arrow_overrides = .{
        .up = null,
        .down = null,
        .left = null,
        .right = null,
        .a = null,
        .b = null,
        .p2_up = null,
        .p2_down = null,
        .p2_left = null,
        .p2_right = null,
        .p2_a = null,
        .p2_b = null,
    };
}

pub fn pollKeys() [16]bool {
    return pollChip8Keys(rl.isKeyDown);
}

pub fn pollJustPressedKeys() [16]bool {
    return pollChip8Keys(rl.isKeyPressed);
}

pub fn firstPressedKey(keys: [16]bool) ?u4 {
    for (keys, 0..) |pressed, idx| {
        if (pressed) return @intCast(idx);
    }
    return null;
}

fn pollChip8Keys(comptime predicate: fn (rl.KeyboardKey) bool) [16]bool {
    var pressed = [_]bool{false} ** physical_key_map.len;
    for (physical_key_map, 0..) |mapped_key, i| {
        pressed[i] = predicate(mapped_key);
    }
    var keys = control.foldPressedChip8Keys(&pressed);
    applyArrowOverrides(&keys, &pressed);
    return keys;
}

// Overlay the active per-ROM arrow overrides on top of the canonical fold.
// Only touches the four chip-8 indices the override mentions so games that
// use arrows + other keys keep their other bindings.
fn applyArrowOverrides(keys: *[16]bool, pressed: *const [physical_key_map.len]bool) void {
    const up_idx = control.physicalKeyIndex(.up);
    const down_idx = control.physicalKeyIndex(.down);
    const left_idx = control.physicalKeyIndex(.left);
    const right_idx = control.physicalKeyIndex(.right);

    if (arrow_overrides.up) |ch| {
        // Clear the canonical chip-8 index (5) first so the arrow doesn't
        // double-fire; then set the override target.
        if (pressed[up_idx]) {
            keys[0x5] = false;
            keys[ch] = true;
        }
    }
    if (arrow_overrides.down) |ch| {
        if (pressed[down_idx]) {
            keys[0x8] = false;
            keys[ch] = true;
        }
    }
    if (arrow_overrides.left) |ch| {
        if (pressed[left_idx]) {
            keys[0x7] = false;
            keys[ch] = true;
        }
    }
    if (arrow_overrides.right) |ch| {
        if (pressed[right_idx]) {
            keys[0x9] = false;
            keys[ch] = true;
        }
    }
    // A/B buttons don't have a canonical chip-8 index to clear; just set
    // the override target when the physical key is down.
    if (arrow_overrides.a) |ch| {
        if (pressed[control.physicalKeyIndex(.space)]) keys[ch] = true;
    }
    if (arrow_overrides.b) |ch| {
        if (pressed[control.physicalKeyIndex(.left_shift)]) keys[ch] = true;
    }
    // Player-2 overlays — same no-canonical-clear approach.
    if (arrow_overrides.p2_up) |ch| {
        if (pressed[control.physicalKeyIndex(.i)]) keys[ch] = true;
    }
    if (arrow_overrides.p2_down) |ch| {
        if (pressed[control.physicalKeyIndex(.k)]) keys[ch] = true;
    }
    if (arrow_overrides.p2_left) |ch| {
        if (pressed[control.physicalKeyIndex(.j)]) keys[ch] = true;
    }
    if (arrow_overrides.p2_right) |ch| {
        if (pressed[control.physicalKeyIndex(.l)]) keys[ch] = true;
    }
    if (arrow_overrides.p2_a) |ch| {
        if (pressed[control.physicalKeyIndex(.period)]) keys[ch] = true;
    }
    if (arrow_overrides.p2_b) |ch| {
        if (pressed[control.physicalKeyIndex(.slash)]) keys[ch] = true;
    }
}
