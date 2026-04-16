# Chip-8 Emulator

A Chip-8 emulator with a built-in debug UI showing registers, memory, and a live disassembler.

## Requirements

- Zig 0.16.0

## Build & Run

```
zig build run -- path/to/rom.ch8
```

You can also launch without a ROM path and then drag/drop a `.ch8` / `.rom` file or open the recent-ROM overlay with `O`.

Run tests:

```
zig build test
```

## Controls

| Key | Action |
|-----|--------|
| SPACE | Run / Pause |
| N | Step into (when paused) |
| Shift + N | Step over CALL (when paused) |
| BACKSPACE | Reset |
| B | Toggle breakpoint at the current PC (when paused) |
| O | Open recent ROM overlay |
| F5 / F9 | Quick save / quick load current slot |
| Shift + F5 / Shift + F9 | Open save/load slot overlay |
| [ / ] | Adjust CPU speed in 120 Hz steps |
| M | Toggle mute |
| P | Toggle compatibility profile |
| Tab | Cycle Flow / History / Watches gutter tabs |
| ; | Edit the selected watch address |
| G / Shift + G | Cycle palette / display effect |
| F11 | Toggle fullscreen |
| - / = | Decrease / increase volume |
| W / A / S / D or Arrow Keys | Directional gameplay aliases |

Runtime footer text uses:

`SPACE Run/Pause  N/Shift+N Step/Over  B Break  O Recent  F5/F9 Save/Load  [ ] Speed  M Mute  P Profile  G FX  F11 Full`

## Keypad

```
Keyboard        Chip-8
1 2 3 4    ->   1 2 3 C
Q W E R    ->   4 5 6 D
A S D F    ->   7 8 9 E
Z X C V    ->   A 0 B F
```

Arrow keys mirror the same CHIP-8 slots as `W/A/S/D`: `Up -> 5`, `Left -> 7`, `Down -> 8`, `Right -> 9`.

## Extras

- Profiles: `modern` and `vip_legacy` are remembered per ROM.
- Save states: slots `1..5` are stored under your user app-data directory together with recent ROMs and display settings.
- Drag/drop: dropping a ROM into the window loads it immediately and applies any remembered profile/speed for that ROM.
