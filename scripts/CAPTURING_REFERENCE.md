# Capturing reference framebuffers

The display and opcodes verification axes need an external oracle to grade
against. We get that by running ROMs in a **reference emulator** (one that
is _not_ this project) and recording the framebuffer hash after a known
cycle count. This file documents that procedure.

## Why this is manual and offline

> Golden framebuffer dumps come from reference emulators, never from our own
> output.

CI cannot regenerate these artifacts. Each capture is a deliberate,
human-reviewed decision citing which emulator and which version produced
the hash. "Octo sometime in 2024" is not a citation.

## Recommended reference emulators

- **Cadmium** — <https://github.com/gulrak/cadmium>. C++ implementation, has
  a headless CLI mode suitable for scripted capture. First choice.
- **Octo** — <https://github.com/JohnEarnest/Octo>. JS, community-reference
  for XO-CHIP. Harder to run headlessly; typically used for visual
  confirmation, not scripted capture.

Both are CHIP-8 implementations with strong reputations. Pick one per ROM
and record which one you used — different emulators resolve ambiguous
quirks differently, so mixing references within a single ROM gives bogus
comparisons.

## Capture procedure (Cadmium example)

1. Check out Cadmium at a **specific release tag** (e.g. `v1.0.12`). Record
   the exact version — `cadmium --version` — so the capture is reproducible.
2. Run the ROM headlessly. Example invocation (verify with `cadmium --help`
   on your version; flags change):

   ```sh
   cadmium --headless \
           --platform originalChip8 \
           --cycles 100000 \
           --dump-framebuffer /tmp/fb.bin \
           <path-to-rom>.ch8
   ```

3. Hash the raw framebuffer bytes with SHA-256:

   ```sh
   shasum -a 256 /tmp/fb.bin
   ```

4. Repeat step 2 at the cycle counts you want to grade. `axis/opcodes.zig`
   currently snapshots at the default `TestId.defaultCycles` value; grab at
   least that count. More cycle points → richer comparison.

5. Add the result to `src/core/assets/reference_framebuffers.json`:

   ```json
   {
     "<rom_sha1>": {
       "rom_name": "3-corax+",
       "platform": "originalChip8",
       "reference_emulator": "cadmium-1.0.12",
       "font_style": "cosmac",
       "snapshots": [
         { "cycle": 100000, "framebuffer_sha256": "...", "display_wh": [64, 32] }
       ]
     }
   }
   ```

   - `rom_sha1` — the SHA-1 of the ROM bytes (what chip-8-database keys on).
     `chip8 get <source>` prints this; or `shasum -a 1 <rom>.ch8`.
   - `font_style` — which font variant Cadmium used. This matters: a
     different font produces a different hash for any ROM that draws
     `FX29` sprites. Match whatever the ROM's chip-8-database entry says.

6. Rebuild. The embedded asset picks up the new entries automatically.

## Developer override

While iterating on a capture, drop your in-progress JSON at
`<app_data_root>/verification/reference_framebuffers.json`. `Store.load`
checks that path first; no rebuild required. Move the content into the
committed asset once stable.

## What makes a good capture

- **Honest cycle counts.** A hash at 100 cycles tests a different slice of
  behavior than one at 100 000. Capture multiple points for ROMs where
  state evolves (test suites, animations).
- **Font disclosure.** Always record `font_style`. An emulator with a
  different small font renders `FX29`-heavy ROMs differently — hashes
  will diverge even though the emulator itself is correct.
- **Platform fidelity.** Use the platform the chip-8-database lists as
  `platforms[0]`. Matching a SCHIP hash against an emulator running VIP
  quirks is a bug in the capture, not in us.
- **Exact tool version.** `cadmium-1.0.12` not `cadmium`. Upstream changes
  over time; two people with "Cadmium" won't necessarily produce the same
  hash in six months.

## Font variants worth knowing about

chip-8-database's `fontStyle` enum: `octo`, `vip`, `schip`, `dream6800`,
`eti660`, `fish`, `akouz1`. For each capture, pick the font the reference
emulator actually loaded. If the reference doesn't expose which font it
used, note the emulator's default in `reference_emulator` and flag the
entry as uncertain in its snapshot comment.

## Non-goals

- We do not capture reference framebuffers from this project's own
  emulator. The whole point is an independent oracle.
- We do not auto-regenerate references in CI. A regression that invalidates
  a captured hash is a signal to investigate, not a signal to recapture.
