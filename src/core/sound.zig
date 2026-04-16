const std = @import("std");
const rl = @import("raylib");

const SAMPLE_RATE: u32 = 48_000;
const BUFFER_FRAMES: usize = 512;
const CLASSIC_BEEP_HZ: f32 = 440.0;

var audio_initialized: bool = false;
var base_volume: f32 = 1.0;
var muted: bool = false;
var stream: ?rl.AudioStream = null;
var sample_buffer: [BUFFER_FRAMES]f32 = [_]f32{0} ** BUFFER_FRAMES;
var square_phase: f32 = 0;
var pattern_phase: f32 = 0;
var was_sound_active: bool = false;

pub fn init() void {
    rl.initAudioDevice();
    stream = rl.loadAudioStream(SAMPLE_RATE, 32, 1) catch null;
    if (stream) |audio_stream| {
        rl.playAudioStream(audio_stream);
    }
    applyVolume();
    audio_initialized = true;
}

pub fn deinit() void {
    if (stream) |audio_stream| {
        rl.stopAudioStream(audio_stream);
        rl.unloadAudioStream(audio_stream);
        stream = null;
    }
    if (audio_initialized) {
        rl.closeAudioDevice();
        audio_initialized = false;
    }
}

pub fn update(sound_timer: u8, audio_pattern: *const [16]u8, audio_pitch: u8) void {
    if (!audio_initialized) return;
    const audio_stream = stream orelse return;
    if (!rl.isAudioStreamProcessed(audio_stream)) return;

    const has_pattern = patternHasAudibleBits(audio_pattern);
    const active = sound_timer > 0 and (!muted);

    if (!active and was_sound_active) {
        square_phase = 0;
        pattern_phase = 0;
    }
    was_sound_active = active;

    if (!active) {
        @memset(&sample_buffer, 0);
        rl.updateAudioStream(audio_stream, &sample_buffer, BUFFER_FRAMES);
        return;
    }

    if (has_pattern) {
        fillPatternBuffer(audio_pattern, audio_pitch);
    } else {
        fillClassicBuffer();
    }

    rl.updateAudioStream(audio_stream, &sample_buffer, BUFFER_FRAMES);
}

pub fn setVolume(volume: f32) void {
    base_volume = clampVolume(volume);
    applyVolume();
}

pub fn toggleMuted() bool {
    muted = !muted;
    applyVolume();
    return muted;
}

pub fn setMuted(value: bool) void {
    muted = value;
    applyVolume();
}

pub fn isMuted() bool {
    return muted;
}

pub fn currentVolume() f32 {
    return base_volume;
}

fn fillClassicBuffer() void {
    const step = CLASSIC_BEEP_HZ / @as(f32, @floatFromInt(SAMPLE_RATE));
    for (&sample_buffer) |*sample| {
        square_phase += step;
        if (square_phase >= 1.0) square_phase -= 1.0;
        sample.* = if (square_phase < 0.5) 0.25 else -0.25;
    }
}

fn fillPatternBuffer(audio_pattern: *const [16]u8, audio_pitch: u8) void {
    const playback_rate = 4000.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(audio_pitch)) - 64.0) / 48.0);
    const step = playback_rate / @as(f32, @floatFromInt(SAMPLE_RATE));

    for (&sample_buffer) |*sample| {
        const sample_index = @as(usize, @intFromFloat(pattern_phase)) % 128;
        const byte_index = sample_index / 8;
        const bit_index: u3 = @intCast(7 - (sample_index % 8));
        const on = ((audio_pattern[byte_index] >> bit_index) & 1) == 1;
        sample.* = if (on) 0.25 else -0.25;

        pattern_phase += step;
        while (pattern_phase >= 128.0) pattern_phase -= 128.0;
    }
}

fn patternHasAudibleBits(audio_pattern: *const [16]u8) bool {
    for (audio_pattern) |byte| {
        if (byte != 0) return true;
    }
    return false;
}

fn applyVolume() void {
    if (audio_initialized) {
        rl.setMasterVolume(if (muted) 0 else base_volume);
    }
}

fn clampVolume(value: f32) f32 {
    if (value < 0) return 0;
    if (value > 1.0) return 1.0;
    return value;
}
