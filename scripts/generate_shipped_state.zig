// Release-time helper: downloads every .ch8 file under each default
// known-registry's globs, computes SHA-1, fetches matching chip-8-database
// entries, and writes populated src/core/assets/registry_state.json and
// src/core/assets/chip8_db_cache.json.
//
// Usage:
//   GITHUB_TOKEN=<token> zig build shipped-state
//
// Network-heavy; run only at release time. Output is committed so end-users
// get fast offline search with zero network calls on first launch.

const std = @import("std");
const core = @import("chip8_core");
const config_mod = core.config;
const state_mod = core.state;
const chip8_db_cache = core.chip8_db_cache;
const github = core.github;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Paths are relative to the invocation cwd (project root).
    const app_data_root = "src/core/assets";

    var config = try config_mod.loadConfig(init.io, gpa, app_data_root);
    defer config.deinit(gpa);

    const tok = try github.resolveToken(gpa, init.minimal.environ, config.github_token);
    if (config.github_token == null and tok != null) config.github_token = tok.?;
    defer if (config.github_token != null and tok != null) gpa.free(tok.?);

    var state = try state_mod.loadState(init.io, gpa, app_data_root);
    defer state.deinit();
    var db_cache = try chip8_db_cache.load(init.io, gpa, app_data_root);
    defer db_cache.deinit();

    std.debug.print("Refreshing chip-8-database cache...\n", .{});
    try chip8_db_cache.refreshAll(init.io, gpa, &db_cache);

    std.debug.print("Syncing all registries...\n", .{});
    try state_mod.syncAll(init.io, gpa, &state, config, &db_cache);

    try state_mod.saveState(init.io, gpa, app_data_root, &state);
    try chip8_db_cache.save(init.io, gpa, app_data_root, &db_cache);

    std.debug.print("Wrote src/core/assets/registry_state.json and src/core/assets/chip8_db_cache.json\n", .{});
}
