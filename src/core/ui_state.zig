const std = @import("std");

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
    status_text: [256]u8 = [_]u8{0} ** 256,
    status_len: usize = 0,

    pub fn clearStatus(self: *UiState) void {
        self.status_len = 0;
    }

    pub fn setStatus(self: *UiState, text: []const u8) void {
        self.status_len = @min(text.len, self.status_text.len);
        @memcpy(self.status_text[0..self.status_len], text[0..self.status_len]);
    }

    pub fn setStatusFmt(self: *UiState, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.status_text, fmt, args) catch "";
        self.status_len = written.len;
    }

    pub fn status(self: *const UiState) []const u8 {
        return self.status_text[0..self.status_len];
    }
};
