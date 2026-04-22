const std = @import("std");
const registry = @import("registry.zig");

pub const SlotOverlayMode = enum {
    save,
    load,
};

pub const WatchEditState = struct {
    slot: usize,
    text: [4]u8 = [_]u8{0} ** 4,
    len: usize = 0,
};

// Small text-edit buffer for the registry search box. Fixed capacity keeps
// ownership trivial — no allocator tracking. Query text is validated char by
// char in the input handler (printable ASCII only).
pub const SearchQueryText = struct {
    buf: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,

    pub fn slice(self: *const SearchQueryText) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn appendChar(self: *SearchQueryText, ch: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    pub fn backspace(self: *SearchQueryText) void {
        if (self.len > 0) self.len -= 1;
    }
};

pub const RegistrySearchState = struct {
    query: SearchQueryText = .{},
    // Owned results from the latest `registry.search` call. Freed on every
    // query change and when the overlay closes.
    results: []registry.SearchResult = &.{},
    selection: usize = 0,
    scroll: usize = 0,
    // Index into `results` of the ROM currently being installed, so the UI
    // can highlight which row the spinner is attached to. null when idle.
    installing_index: ?usize = null,

    pub fn deinit(self: *RegistrySearchState, allocator: std.mem.Allocator) void {
        for (self.results) |r| r.deinit(allocator);
        allocator.free(self.results);
        self.results = &.{};
        self.selection = 0;
        self.scroll = 0;
        self.installing_index = null;
    }
};

// Piggybacked on the recent_roms overlay: once the user hits X on an
// installed selection, the overlay parks in this state until confirmed or
// dismissed. Keeps the remove flow gated behind an explicit second
// keypress without introducing a separate overlay variant.
pub const RemoveConfirm = struct {
    // Index into the installed + recents listing that the recent_roms
    // overlay is rendering. Null = no pending confirmation.
    target_index: usize,
};

pub const Overlay = union(enum) {
    none,
    recent_roms,
    save_slots: SlotOverlayMode,
    watch_edit: WatchEditState,
    registry_search: RegistrySearchState,
};

pub const UiState = struct {
    overlay: Overlay = .none,
    active_save_slot: u8 = 1,
    recent_selection: usize = 0,
    last_latched_key: ?u4 = null,
    status_text: [256]u8 = [_]u8{0} ** 256,
    status_len: usize = 0,
    // Armed when the user hits X/Delete on an installed row in the recent
    // overlay; a second press confirms removal. Cleared whenever the
    // selection moves or the overlay closes.
    pending_remove: ?RemoveConfirm = null,

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
