const std = @import("std");
const models = @import("registry_models.zig");
const registry = @import("registry.zig");
const state_mod = @import("state.zig");
const chip8_db_cache = @import("chip8_db_cache.zig");
const config_mod = @import("config.zig");
const url_mod = @import("url.zig");

// Single-slot background task queue. The GUI's network ops (ROM install in v1)
// run on a worker thread so the 60 Hz render loop stays smooth. Only one task
// is in flight at a time — start simple, no priority queue or cancellation.
//
// Thread contract: every field after `mutex` is protected by `mutex`. Callers
// on the main thread use the public accessors (`isRunning`, `statusLine`,
// `pollCompletion`); the worker writes `phase`, `status_*`, and `result` under
// the same lock at entry / progress points / completion.
pub const TaskRunner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app_data_root: []const u8,
    // std.Io.Mutex replaces std.Thread.Mutex in Zig 0.16; its lock/unlock
    // take the std.Io handle. We use lockUncancelable everywhere — the GUI
    // can't meaningfully cancel a mutex acquisition mid-install.
    mutex: std.Io.Mutex = .init,
    phase: Phase = .idle,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    result: ?Result = null,
    thread: ?std.Thread = null,
    // Owned copies of the source string and parsed config for the running
    // task. The worker consults these without re-locking and the task_runner
    // frees them on completion.
    current_source: ?[]u8 = null,

    // Shared-mutable registry state. These pointers live longer than the
    // task runner (main.zig owns them); the runner is merely a user of
    // them, serialized against the main thread via a single worker.
    shared: ?Shared = null,

    pub const Shared = struct {
        state: *state_mod.State,
        db_cache: *chip8_db_cache.State,
        config: config_mod.Config,
    };

    pub const Phase = enum { idle, running, completed };

    pub const Result = union(enum) {
        install_ok: models.InstalledRom,
        install_err: []u8, // owned error message
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, app_data_root: []const u8) TaskRunner {
        return .{
            .allocator = allocator,
            .io = io,
            .app_data_root = app_data_root,
        };
    }

    pub fn deinit(self: *TaskRunner) void {
        // Join any in-flight worker before tearing down shared state. The
        // worker never calls back into the runner once it's signalled
        // .completed, so this just drains the thread.
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.current_source) |s| self.allocator.free(s);
        if (self.result) |r| self.freeResult(r);
    }

    fn freeResult(self: *TaskRunner, r: Result) void {
        switch (r) {
            .install_ok => |rom| rom.deinit(self.allocator),
            .install_err => |msg| self.allocator.free(msg),
        }
    }

    pub fn isRunning(self: *TaskRunner) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.phase == .running;
    }

    pub fn statusLine(self: *TaskRunner) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // The slice is into status_buf, which is stable for the lifetime
        // of the runner. Returning a borrow under the lock is OK because
        // the worker only updates status_buf under the same mutex.
        return self.status_buf[0..self.status_len];
    }

    // Returns the completed result (transferring ownership to the caller) and
    // resets the runner to `.idle`. Returns null while the worker is still
    // running or when there is nothing to collect.
    pub fn pollCompletion(self: *TaskRunner) ?Result {
        self.mutex.lockUncancelable(self.io);
        if (self.phase != .completed) {
            self.mutex.unlock(self.io);
            return null;
        }
        const r = self.result.?;
        self.result = null;
        self.phase = .idle;
        self.status_len = 0;
        const thread = self.thread;
        self.thread = null;
        if (self.current_source) |s| {
            self.allocator.free(s);
            self.current_source = null;
        }
        self.mutex.unlock(self.io);
        // Join outside the lock — the worker has already returned; join()
        // just reaps the handle and should not deadlock.
        if (thread) |t| t.join();
        return r;
    }

    pub fn submitInstall(
        self: *TaskRunner,
        shared: Shared,
        source: []const u8,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.phase != .idle) return error.TaskAlreadyRunning;

        const source_copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_copy);

        self.current_source = source_copy;
        self.shared = shared;
        self.phase = .running;
        self.result = null;
        const msg = std.fmt.bufPrint(&self.status_buf, "Installing {s}…", .{source}) catch "Installing…";
        self.status_len = msg.len;

        self.thread = try std.Thread.spawn(.{}, installWorker, .{self});
    }

    fn installWorker(self: *TaskRunner) void {
        // Snapshot what we need without holding the mutex across the blocking
        // call. Source/app_data_root/shared are pinned for the task's
        // lifetime by submitInstall(), so the pointers stay valid.
        self.mutex.lockUncancelable(self.io);
        const source = self.current_source.?;
        const shared = self.shared.?;
        self.mutex.unlock(self.io);

        const r: Result = if (doInstall(self.allocator, self.io, self.app_data_root, shared, source)) |rom|
            .{ .install_ok = rom }
        else |err| blk: {
            const fallback = "Install failed";
            const msg = std.fmt.allocPrint(self.allocator, "Install failed: {s}", .{@errorName(err)}) catch
                (self.allocator.dupe(u8, fallback) catch @panic("OOM building install error"));
            break :blk .{ .install_err = msg };
        };

        self.mutex.lockUncancelable(self.io);
        self.result = r;
        self.phase = .completed;
        const status_msg = switch (r) {
            .install_ok => |rom| std.fmt.bufPrint(&self.status_buf, "Installed {s}", .{rom.metadata.id}) catch "Installed",
            .install_err => |msg| std.fmt.bufPrint(&self.status_buf, "{s}", .{msg}) catch "Install failed",
        };
        self.status_len = status_msg.len;
        self.mutex.unlock(self.io);
    }
};

fn doInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_data_root: []const u8,
    shared: TaskRunner.Shared,
    source: []const u8,
) !models.InstalledRom {
    const source_url = try url_mod.parse(allocator, source);
    defer source_url.deinit(allocator);

    var ctx = registry.InstallContext{
        .io = io,
        .allocator = allocator,
        .app_data_root = app_data_root,
        .config = shared.config,
        .state = shared.state,
        .db_cache = shared.db_cache,
    };

    const rom = try registry.install(&ctx, source_url);
    errdefer rom.deinit(allocator);

    try state_mod.saveState(io, allocator, app_data_root, shared.state);
    try chip8_db_cache.save(io, allocator, app_data_root, shared.db_cache);
    return rom;
}

test "TaskRunner idle by default" {
    var runner = TaskRunner.init(std.testing.allocator, undefined, "");
    defer runner.deinit();
    try std.testing.expect(!runner.isRunning());
    try std.testing.expectEqualStrings("", runner.statusLine());
    try std.testing.expect(runner.pollCompletion() == null);
}

test "TaskRunner result ownership passes through pollCompletion" {
    var runner = TaskRunner.init(std.testing.allocator, undefined, "");
    defer runner.deinit();

    // Synthesize a completed install_err state directly to exercise the
    // collection path without spinning a worker (the worker calls
    // registry.install which needs live IO + state).
    const msg = try std.testing.allocator.dupe(u8, "fake failure");
    runner.phase = .completed;
    runner.result = .{ .install_err = msg };
    const status = "Install failed: fake";
    @memcpy(runner.status_buf[0..status.len], status);
    runner.status_len = status.len;

    const collected = runner.pollCompletion();
    try std.testing.expect(collected != null);
    switch (collected.?) {
        .install_err => |m| {
            try std.testing.expectEqualStrings("fake failure", m);
            std.testing.allocator.free(m);
        },
        .install_ok => try std.testing.expect(false),
    }
    try std.testing.expect(runner.phase == .idle);
    try std.testing.expect(runner.result == null);
    try std.testing.expect(runner.pollCompletion() == null);
}
