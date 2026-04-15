const rl = @import("raylib");

var audio_initialized: bool = false;

pub fn init() void {
    rl.initAudioDevice();
    audio_initialized = true;
}

pub fn deinit() void {
    if (audio_initialized) {
        rl.closeAudioDevice();
        audio_initialized = false;
    }
}
