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
};

pub fn pollKeys() [16]bool {
    var pressed = [_]bool{false} ** physical_key_map.len;
    for (physical_key_map, 0..) |mapped_key, i| {
        pressed[i] = rl.isKeyDown(mapped_key);
    }
    return control.foldPressedChip8Keys(&pressed);
}
