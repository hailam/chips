const control = @import("control_spec.zig");

pub const CPU_HZ_DEFAULT: i32 = 600;
pub const CPU_HZ_MIN: i32 = 60;
pub const CPU_HZ_MAX: i32 = 3000;
pub const CPU_HZ_STEP: i32 = 120;
pub const TIMER_HZ: f64 = 60.0;
pub const DEFAULT_FRAME_DT_CAP_S: f64 = 0.25;

pub const TimingState = struct {
    cpu_hz_target: f64,
    cpu_accumulator_s: f64,
    timer_accumulator_s: f64,
    frame_dt_cap_s: f64,

    pub fn init() TimingState {
        return .{
            .cpu_hz_target = CPU_HZ_DEFAULT,
            .cpu_accumulator_s = 0,
            .timer_accumulator_s = 0,
            .frame_dt_cap_s = DEFAULT_FRAME_DT_CAP_S,
        };
    }
};

pub const AdvanceResult = struct {
    frame_dt_s: f64,
    cpu_cycles: usize,
    timer_ticks: usize,
};

pub fn advance(state: *TimingState, frame_dt_s: f64) AdvanceResult {
    const dt = if (frame_dt_s > state.frame_dt_cap_s) state.frame_dt_cap_s else frame_dt_s;
    state.cpu_accumulator_s += dt;
    state.timer_accumulator_s += dt;

    var cpu_cycles: usize = 0;
    const cpu_step_s = 1.0 / state.cpu_hz_target;
    const cpu_epsilon = cpu_step_s / 1024.0;
    while (state.cpu_accumulator_s + cpu_epsilon >= cpu_step_s) {
        state.cpu_accumulator_s -= cpu_step_s;
        cpu_cycles += 1;
    }

    var timer_ticks: usize = 0;
    const timer_step_s = 1.0 / TIMER_HZ;
    const timer_epsilon = timer_step_s / 1024.0;
    while (state.timer_accumulator_s + timer_epsilon >= timer_step_s) {
        state.timer_accumulator_s -= timer_step_s;
        timer_ticks += 1;
    }

    return .{
        .frame_dt_s = dt,
        .cpu_cycles = cpu_cycles,
        .timer_ticks = timer_ticks,
    };
}

pub fn applySpeedAction(current_hz: i32, action: control.SpeedAction) i32 {
    return switch (action) {
        .slower => clampCpuHz(current_hz - CPU_HZ_STEP),
        .faster => clampCpuHz(current_hz + CPU_HZ_STEP),
    };
}

pub fn clampCpuHz(value: i32) i32 {
    if (value < CPU_HZ_MIN) return CPU_HZ_MIN;
    if (value > CPU_HZ_MAX) return CPU_HZ_MAX;
    return value;
}
