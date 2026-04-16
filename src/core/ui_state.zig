pub const SlotOverlayMode = enum {
    save,
    load,
};

pub const WatchEditState = struct {
    slot: usize,
    text: [4]u8 = [_]u8{0} ** 4,
    len: usize = 0,
};

pub const Overlay = union(enum) {
    none,
    recent_roms,
    save_slots: SlotOverlayMode,
    watch_edit: WatchEditState,
};

pub const UiState = struct {
    overlay: Overlay = .none,
    active_save_slot: u8 = 1,
    recent_selection: usize = 0,
    last_latched_key: ?u4 = null,
};
