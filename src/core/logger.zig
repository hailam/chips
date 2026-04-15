const std = @import("std");

pub const Logger = struct {
    pub fn init() Logger {
        return .{};
    }

    pub fn info(_: Logger, comptime fmt: []const u8, args: anytype) void {
        std.log.info(fmt, args);
    }

    pub fn err(_: Logger, comptime fmt: []const u8, args: anytype) void {
        std.log.err(fmt, args);
    }
};
