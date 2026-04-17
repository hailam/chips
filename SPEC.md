# chip8.json Manifest Convention

A lightweight, opt-in convention for publishing CHIP-8 ROMs from a GitHub
repository so that tools can install and enrich them automatically.

Go-module-inspired: no central registry, no curation authority. Any repo
containing `.ch8` files is usable — a `chip8.json` just makes the experience
richer.

## File location

- `chip8.json` lives at the repo root, or in any subdirectory.
- A resolver walks the path. For `user/repo/games`, it looks for
  `games/chip8.json` first, then root `chip8.json`, then falls back to
  `games/*.ch8` directory behavior.
- A repo may have multiple manifests in different subdirectories.

## Shape

```json
{
  "spec_version": 1,
  "roms": [
    {
      "id": "ibm-logo",
      "file": "ibm_logo.ch8",
      "sha1": "1ba58656810b67fd131eb9af3e3987863bf26c90",
      "tags": ["test", "public-domain"]
    }
  ]
}
```

### Top-level

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `spec_version` | integer | yes | Must be `1`. |
| `roms` | array | yes | One entry per ROM. |

### Per-ROM

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `id` | string | yes | Stable slug within this manifest. |
| `file` | string | yes | Path relative to the manifest file. |
| `sha1` | string (hex) | recommended | Used for checksum verification and chip-8-database lookup. |
| `source_url` | string | optional | Canonical human-facing URL. |
| `raw_url` | string | optional | Direct download URL (bypasses directory listing). |
| `tags` | array of strings | optional | Free-form tags. |

### Enrichment via chip-8-database

Rich metadata (title, authors, description, release, platforms, keys, colors,
quirks, tickrate) is **not** duplicated in `chip8.json`. Tools look it up
against the community-maintained [chip-8-database] by SHA-1 and merge the
entry at install time.

If chip-8-database adds a field, tools pick it up automatically. Do not
invent parallel fields in `chip8.json`.

## spec_version

`spec_version: 1` is the only published version. It will stay 1 until
real-world evidence forces a break.

## Reference implementation

The canonical reference lives in this repository at
[`examples/roms/chip8.json`](examples/roms/chip8.json) — `chip8 validate`
must accept it.

## Credits

Rich metadata comes from the [chip-8-database][chip-8-database] project.
They did the metadata work; this convention just points at it.

[chip-8-database]: https://github.com/chip-8/chip-8-database
