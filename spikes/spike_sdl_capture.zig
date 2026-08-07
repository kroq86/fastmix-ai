const std = @import("std");

const ray = @cImport({
    @cInclude("raylib.h");
});
const sdl = @cImport({
    // Zig's translate-c chokes on this SDK's <arm_neon.h> (unrelated to SDL
    // itself -- a known Zig/Apple-SDK NEON-header incompatibility). SDL2
    // conveniently has an explicit escape hatch for this exact situation.
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
});

// Spike: roadmap §13 -- raylib/miniaudio (as we use it, via LoadAudioStream) has
// no input-capture path, but SDL2 is already installed on this machine and has
// a straightforward capture API. Can raylib (output+graphics) and SDL2 (input
// only) both run in the SAME process without conflicting when they each claim
// an audio subsystem? This spike:
//   1. Starts raylib's audio device and plays a synthesized tone (proves raylib
//      output still works normally alongside SDL).
//   2. Starts SDL2 in audio-only mode and opens a capture device using the
//      "simple queued audio" API (no C callback needed -- poll each frame,
//      matching this project's established no-callback style).
//   3. Runs both concurrently for ~2s, then reports how many bytes were
//      captured and basic signal stats (peak/RMS) to confirm real data came in
//      (not just that nothing crashed).

const SAMPLE_RATE: u32 = 44100;
const BUFFER_SIZE: usize = 2048;

pub fn main() !void {
    // --- raylib output side ---
    ray.SetTraceLogLevel(ray.LOG_WARNING); // quiet down raylib's usual INFO spam for this console spike
    ray.InitAudioDevice();
    defer ray.CloseAudioDevice();

    ray.SetAudioStreamBufferSizeDefault(@intCast(BUFFER_SIZE));
    const stream = ray.LoadAudioStream(SAMPLE_RATE, 32, 1);
    defer ray.UnloadAudioStream(stream);
    ray.PlayAudioStream(stream);

    var out_buffer: [BUFFER_SIZE]f32 = undefined;
    var frame_count: u64 = 0;

    // --- SDL2 input side ---
    if (sdl.SDL_Init(sdl.SDL_INIT_AUDIO) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();

    const num_capture_devices = sdl.SDL_GetNumAudioDevices(1);
    std.debug.print("SDL capture devices found: {}\n", .{num_capture_devices});
    var i: c_int = 0;
    while (i < num_capture_devices) : (i += 1) {
        std.debug.print("  [{}] {s}\n", .{ i, sdl.SDL_GetAudioDeviceName(i, 1) });
    }
    if (num_capture_devices <= 0) {
        std.debug.print("SKIP: no capture devices available on this machine/sandbox (no mic permission or no input hardware exposed)\n", .{});
        return;
    }

    var desired: sdl.SDL_AudioSpec = std.mem.zeroes(sdl.SDL_AudioSpec);
    desired.freq = SAMPLE_RATE;
    desired.format = sdl.AUDIO_F32;
    desired.channels = 1;
    desired.samples = 1024;
    desired.callback = null; // simple queued-audio API, polled below -- no C callback trampoline needed

    var obtained: sdl.SDL_AudioSpec = undefined;
    const dev = sdl.SDL_OpenAudioDevice(null, 1, &desired, &obtained, 0);
    if (dev == 0) {
        std.debug.print("SDL_OpenAudioDevice failed: {s}\n", .{sdl.SDL_GetError()});
        return error.SdlOpenDeviceFailed;
    }
    defer sdl.SDL_CloseAudioDevice(dev);

    std.debug.print("opened capture device: freq={} format={} channels={} samples={}\n", .{ obtained.freq, obtained.format, obtained.channels, obtained.samples });

    sdl.SDL_PauseAudioDevice(dev, 0); // 0 = unpause = start recording

    var captured = std.ArrayList(f32).empty;
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    defer captured.deinit(gpa);

    var poll_buf: [4096]u8 = undefined;
    var frames: u32 = 0;
    const target_frames: u32 = 150; // ~2.4s at 16ms/frame

    while (frames < target_frames) : (frames += 1) {
        // Drain whatever SDL has queued from the mic this "frame".
        const queued = sdl.SDL_DequeueAudio(dev, &poll_buf, poll_buf.len);
        if (queued > 0) {
            const n_floats: usize = @intCast(@divTrunc(queued, @sizeOf(f32)));
            const as_floats: [*]const f32 = @ptrCast(@alignCast(&poll_buf));
            try captured.appendSlice(gpa, as_floats[0..n_floats]);
        }

        // Keep raylib's output stream fed too, proving it isn't starved by SDL
        // running alongside it.
        if (ray.IsAudioStreamProcessed(stream)) {
            for (0..BUFFER_SIZE) |s| {
                const t: f32 = @as(f32, @floatFromInt(frame_count)) / @as(f32, @floatFromInt(SAMPLE_RATE));
                out_buffer[s] = @sin(2.0 * std.math.pi * t * 440.0) * 0.2;
                frame_count += 1;
            }
            ray.UpdateAudioStream(stream, &out_buffer, @intCast(BUFFER_SIZE));
        }

        sdl.SDL_Delay(16);
    }

    std.debug.print("captured {} samples ({d:.2}s) while raylib output ran concurrently\n", .{ captured.items.len, @as(f32, @floatFromInt(captured.items.len)) / @as(f32, @floatFromInt(SAMPLE_RATE)) });

    if (captured.items.len == 0) {
        std.debug.print("FAIL: zero samples captured -- either no mic permission or device never produced data\n", .{});
        return error.NoAudioCaptured;
    }

    var peak: f32 = 0.0;
    var sum_sq: f64 = 0.0;
    for (captured.items) |s| {
        const a = @abs(s);
        if (a > peak) peak = a;
        sum_sq += @as(f64, s) * @as(f64, s);
    }
    const rms: f64 = @sqrt(sum_sq / @as(f64, @floatFromInt(captured.items.len)));
    std.debug.print("peak={d:.6} rms={d:.6}\n", .{ peak, rms });
    std.debug.print("PASS: SDL2 capture + raylib output coexisted in one process without crashing or blocking each other\n", .{});
}
