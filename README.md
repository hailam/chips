# Chip-8 Emulator

A Chip-8 emulator with a built-in debug UI showing registers, memory, and a live disassembler.

## Requirements

- Zig 0.16.0

## Build & Run

```
zig build run -- path/to/rom.ch8
```

Run tests:

```
zig build test
```

## Controls

| Key | Action |
|-----|--------|
| SPACE | Run / Pause |
| N | Step one instruction (when paused) |
| BACKSPACE | Reset |
| [ / ] | Adjust CPU speed |
| W / A / S / D or Arrow Keys | Directional gameplay aliases |

Runtime footer text uses: `SPACE Run/Pause  N Step  BKSP Reset  M Mute  [ ] Speed`

## Keypad

```
Keyboard        Chip-8
1 2 3 4    ->   1 2 3 C
Q W E R    ->   4 5 6 D
A S D F    ->   7 8 9 E
Z X C V    ->   A 0 B F
```

Arrow keys mirror the same CHIP-8 slots as `W/A/S/D`: `Up -> 5`, `Left -> 7`, `Down -> 8`, `Right -> 9`.
