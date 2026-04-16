const rl = @import("raylib");

var audio_initialized: bool = false;
var base_volume: f32 = 1.0;
var muted: bool = false;

pub fn init() void {
    rl.initAudioDevice();
    rl.setMasterVolume(base_volume);
    audio_initialized = true;
}

pub fn deinit() void {
    if (audio_initialized) {
        rl.closeAudioDevice();
        audio_initialized = false;
    }
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
