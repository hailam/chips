const std = @import("std");
const cpu_mod = @import("cpu.zig");
const trace_mod = @import("trace.zig");

pub const TRACE_CAPACITY: usize = 128;
pub const HISTORY_CAPACITY: usize = TRACE_CAPACITY;
pub const WATCH_COUNT: usize = 4;

pub const MiddleTab = enum {
    trace,
    cycle,
    watches,
};

pub const TraceTag = trace_mod.TraceTag;
pub const TraceEndpoint = trace_mod.TraceEndpoint;
pub const MicroOp = trace_mod.MicroOp;
pub const MicroOpKind = trace_mod.MicroOpKind;
pub const TraceEntry = trace_mod.TraceEntry;
pub const Lane = trace_mod.Lane;

pub const DebuggerState = struct {
    breakpoints: [cpu_mod.CHIP8_MEMORY_SIZE]bool,
    trace_entries: [TRACE_CAPACITY]TraceEntry,
    trace_len: usize,
    trace_cursor: usize,
    trace_scroll: usize,
    selected_trace_index: ?usize,
    trace_follow_live: bool,
    active_middle_tab: MiddleTab,
    watch_addrs: [WATCH_COUNT]u16,
    selected_watch_slot: usize,
    temp_run_until: ?u16,
    skip_breakpoint_once_pc: ?u16,

    pub fn init() DebuggerState {
        return .{
            .breakpoints = [_]bool{false} ** cpu_mod.CHIP8_MEMORY_SIZE,
            .trace_entries = [_]TraceEntry{TraceEntry.init(0, 0, .fetch)} ** TRACE_CAPACITY,
            .trace_len = 0,
            .trace_cursor = 0,
            .trace_scroll = 0,
            .selected_trace_index = null,
            .trace_follow_live = true,
            .active_middle_tab = .trace,
            .watch_addrs = .{ 0x200, 0x210, 0x220, 0x230 },
            .selected_watch_slot = 0,
            .temp_run_until = null,
            .skip_breakpoint_once_pc = null,
        };
    }

    pub fn toggleBreakpoint(self: *DebuggerState, pc: u16) void {
        if (pc < self.breakpoints.len) {
            self.breakpoints[pc] = !self.breakpoints[pc];
        }
    }

    pub fn hasBreakpoint(self: *const DebuggerState, pc: u16) bool {
        return pc < self.breakpoints.len and self.breakpoints[pc];
    }

    pub fn setWatchAddress(self: *DebuggerState, slot: usize, addr: u16) void {
        if (slot < self.watch_addrs.len) {
            self.watch_addrs[slot] = addr;
            self.selected_watch_slot = slot;
        }
    }

    pub fn cycleTab(self: *DebuggerState) void {
        self.active_middle_tab = switch (self.active_middle_tab) {
            .trace => .cycle,
            .cycle => .watches,
            .watches => .trace,
        };
    }

    pub fn recordTrace(self: *DebuggerState, entry: TraceEntry) void {
        self.trace_entries[self.trace_cursor] = entry;
        self.trace_cursor = (self.trace_cursor + 1) % TRACE_CAPACITY;
        if (self.trace_len < TRACE_CAPACITY) {
            self.trace_len += 1;
        }

        if (self.trace_follow_live) {
            self.trace_scroll = 0;
            self.selected_trace_index = null;
            return;
        }

        if (self.selected_trace_index) |selected| {
            self.selected_trace_index = @min(selected + 1, self.trace_len - 1);
        }
        self.trace_scroll = @min(self.trace_scroll + 1, maxTraceScrollForLen(self.trace_len, 1));
    }

    pub fn traceEntryFromNewest(self: *const DebuggerState, index: usize) ?TraceEntry {
        if (index >= self.trace_len) return null;
        const newest = (self.trace_cursor + TRACE_CAPACITY - 1) % TRACE_CAPACITY;
        const pos = (newest + TRACE_CAPACITY - index) % TRACE_CAPACITY;
        return self.trace_entries[pos];
    }

    pub fn activeTraceIndex(self: *const DebuggerState) ?usize {
        if (self.trace_len == 0) return null;
        if (self.trace_follow_live) return 0;
        if (self.selected_trace_index) |selected| {
            if (selected < self.trace_len) return selected;
        }
        return @min(self.trace_scroll, self.trace_len - 1);
    }

    pub fn activeTraceEntry(self: *const DebuggerState) ?TraceEntry {
        const index = self.activeTraceIndex() orelse return null;
        return self.traceEntryFromNewest(index);
    }

    pub fn maxTraceScroll(self: *const DebuggerState, visible_rows: usize) usize {
        return maxTraceScrollForLen(self.trace_len, visible_rows);
    }

    pub fn scrollTrace(self: *DebuggerState, delta: i32, visible_rows: usize) void {
        if (self.trace_len == 0) return;
        self.trace_follow_live = false;

        const max_scroll = self.maxTraceScroll(visible_rows);
        const current: i32 = @intCast(self.trace_scroll);
        const next = std.math.clamp(current + delta, 0, @as(i32, @intCast(max_scroll)));
        self.trace_scroll = @intCast(next);
        self.selected_trace_index = self.trace_scroll;
    }

    pub fn selectTraceIndex(self: *DebuggerState, index_from_newest: usize, visible_rows: usize) void {
        if (index_from_newest >= self.trace_len) return;
        self.trace_follow_live = false;
        self.selected_trace_index = index_from_newest;

        const max_scroll = self.maxTraceScroll(visible_rows);
        if (index_from_newest < self.trace_scroll) {
            self.trace_scroll = index_from_newest;
        } else if (index_from_newest >= self.trace_scroll + visible_rows and visible_rows > 0) {
            self.trace_scroll = @min(index_from_newest - visible_rows + 1, max_scroll);
        }
    }

    pub fn resumeTraceFollow(self: *DebuggerState) void {
        self.trace_follow_live = true;
        self.trace_scroll = 0;
        self.selected_trace_index = null;
    }

    pub fn beginResume(self: *DebuggerState, current_pc: u16) void {
        self.skip_breakpoint_once_pc = current_pc;
    }

    pub fn shouldPauseBeforeExecute(self: *DebuggerState, current_pc: u16) bool {
        if (self.temp_run_until) |target| {
            if (current_pc == target) {
                self.temp_run_until = null;
                return true;
            }
        }

        if (self.skip_breakpoint_once_pc) |skip_pc| {
            if (current_pc == skip_pc) {
                self.skip_breakpoint_once_pc = null;
                return false;
            }
            self.skip_breakpoint_once_pc = null;
        }

        return self.hasBreakpoint(current_pc);
    }
};

fn maxTraceScrollForLen(trace_len: usize, visible_rows: usize) usize {
    if (visible_rows == 0) return 0;
    return if (trace_len > visible_rows) trace_len - visible_rows else 0;
}

pub fn parseWatchAddress(text: []const u8) !u16 {
    if (text.len == 0 or text.len > 4) return error.InvalidWatchAddress;
    return std.fmt.parseInt(u16, text, 16) catch error.InvalidWatchAddress;
}
