// Embedded, build-time-generated shipped-state assets. Used by state.zig /
// chip8_db_cache.zig to seed app_data_root on first run so users get useful
// offline search without any network calls.
//
// Regenerated at release time by scripts/generate_shipped_state.zig.

pub const registry_state_json: []const u8 = @embedFile("assets/registry_state.json");
pub const chip8_db_cache_json: []const u8 = @embedFile("assets/chip8_db_cache.json");
