const rl = @import("raylib");

// Chip-8 hex keypad mapping:
// Chip-8:  1 2 3 C    Keyboard: 1 2 3 4
//          4 5 6 D               Q W E R
//          7 8 9 E               A S D F
//          A 0 B F               Z X C V

const key_map = [16]rl.KeyboardKey{
    .x, // 0
    .one, // 1
    .two, // 2
    .three, // 3
    .q, // 4
    .w, // 5
    .e, // 6
    .a, // 7
    .s, // 8
    .d, // 9
    .z, // A
    .c, // B
    .four, // C
    .r, // D
    .f, // E
    .v, // F
};

const arrow_aliases = [_]struct { chip8_key: usize, keyboard_key: rl.KeyboardKey }{
    .{ .chip8_key = 5, .keyboard_key = .up },
    .{ .chip8_key = 7, .keyboard_key = .left },
    .{ .chip8_key = 8, .keyboard_key = .down },
    .{ .chip8_key = 9, .keyboard_key = .right },
};

pub fn pollKeys() [16]bool {
    var keys = [_]bool{false} ** 16;
    for (key_map, 0..) |mapped_key, i| {
        keys[i] = rl.isKeyDown(mapped_key);
    }
    for (arrow_aliases) |alias| {
        keys[alias.chip8_key] = keys[alias.chip8_key] or rl.isKeyDown(alias.keyboard_key);
    }
    return keys;
}
