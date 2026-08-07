const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
});

// Spike: does manually constructing a raylib `Wave` around an in-memory
// buffer (never touched by LoadWave/RL_MALLOC) and calling ExportWave()
// actually produce a valid, playable .wav? This is the mechanism the future
// "bounce whole project offline" feature depends on.

const SAMPLE_RATE: u32 = 44100;
const SECONDS: u32 = 1;
const FRAME_COUNT: usize = SAMPLE_RATE * SECONDS;

pub fn main() !void {
    var samples: [FRAME_COUNT]f32 = undefined;
    for (0..FRAME_COUNT) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        // A4 for the first half, A5 for the second half -- makes it obvious
        // on playback whether the whole buffer got exported or just part of it.
        const freq: f32 = if (t < 0.5) 440.0 else 880.0;
        samples[i] = @sin(2.0 * std.math.pi * t * freq) * 0.4;
    }

    const wave = c.Wave{
        .frameCount = @intCast(FRAME_COUNT),
        .sampleRate = SAMPLE_RATE,
        .sampleSize = 32,
        .channels = 1,
        .data = &samples,
    };

    const ok = c.ExportWave(wave, "spikes/spike_wav_output.wav");
    if (!ok) {
        std.debug.print("FAIL: ExportWave returned false\n", .{});
        return error.ExportWaveFailed;
    }

    std.debug.print("OK: exported {} frames ({d:.2}s) to spikes/spike_wav_output.wav\n", .{ FRAME_COUNT, @as(f32, @floatFromInt(FRAME_COUNT)) / @as(f32, @floatFromInt(SAMPLE_RATE)) });

    // Read it straight back with raylib itself as a same-process sanity check
    // (independent of any external tool's WAV parsing quirks).
    const wave_back = c.LoadWave("spikes/spike_wav_output.wav");
    defer c.UnloadWave(wave_back);
    std.debug.print("read-back: frameCount={} sampleRate={} sampleSize={} channels={}\n", .{ wave_back.frameCount, wave_back.sampleRate, wave_back.sampleSize, wave_back.channels });

    if (wave_back.frameCount != FRAME_COUNT) {
        std.debug.print("FAIL: frameCount mismatch, expected {}\n", .{FRAME_COUNT});
        return error.FrameCountMismatch;
    }
    if (wave_back.data == null) {
        std.debug.print("FAIL: read-back data is null\n", .{});
        return error.NullData;
    }
    std.debug.print("PASS\n", .{});
}
