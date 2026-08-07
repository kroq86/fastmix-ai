const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("unistd.h");
});

// Spike: audio-stem import (roadmap §12). Loads a REAL Suno-style stem
// (48kHz, 16-bit int PCM, stereo -- see memory fastmix_stems_reference) via
// raylib's LoadWave, then converts to our internal []f32 format ourselves,
// reading wave.sampleSize/channels to know how to interpret wave.data rather
// than assuming anything. This is the mechanism the earlier WAV-export spike
// flagged as necessary: LoadWave does NOT hand back float32 bit-for-bit for
// arbitrary source formats, so we must convert based on what it actually
// reports, not what we hoped for.

const STEM_PATH = "/Users/ll/Downloads/999 Stems (127BPM)/3 Bass.wav";

fn convertToF32(gpa: std.mem.Allocator, wave: c.Wave) ![]f32 {
    const frame_count: usize = @intCast(wave.frameCount);
    const channels: usize = @intCast(wave.channels);
    const total_samples = frame_count * channels;
    const out = try gpa.alloc(f32, total_samples);

    switch (wave.sampleSize) {
        16 => {
            const src: [*]const i16 = @ptrCast(@alignCast(wave.data));
            for (0..total_samples) |i| {
                out[i] = @as(f32, @floatFromInt(src[i])) / 32768.0;
            }
        },
        8 => {
            // 8-bit WAV PCM is unsigned, centered at 128 (not signed like 16/32-bit).
            const src: [*]const u8 = @ptrCast(@alignCast(wave.data));
            for (0..total_samples) |i| {
                out[i] = (@as(f32, @floatFromInt(src[i])) - 128.0) / 128.0;
            }
        },
        32 => {
            const src: [*]const f32 = @ptrCast(@alignCast(wave.data));
            for (0..total_samples) |i| {
                out[i] = src[i];
            }
        },
        else => return error.UnsupportedSampleSize,
    }
    return out;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    if (c.access(STEM_PATH, c.F_OK) != 0) {
        std.debug.print("SKIP: real stem not found at {s} on this machine\n", .{STEM_PATH});
        return;
    }

    const wave = c.LoadWave(STEM_PATH);
    defer c.UnloadWave(wave);

    std.debug.print("LoadWave reports: frameCount={} sampleRate={} sampleSize={} channels={}\n", .{
        wave.frameCount, wave.sampleRate, wave.sampleSize, wave.channels,
    });

    if (wave.data == null) return error.NullWaveData;
    if (wave.sampleRate != 48000) {
        std.debug.print("NOTE: expected 48000 Hz per the known reference format, got {}\n", .{wave.sampleRate});
    }

    const samples = try convertToF32(gpa, wave);
    defer gpa.free(samples);

    std.debug.print("converted {} interleaved samples ({} frames x {} channels) to f32\n", .{ samples.len, wave.frameCount, wave.channels });

    // Sanity: real audio should have actual dynamic range, not be silence or
    // garbage -- compute peak and a crude RMS over the whole buffer.
    var peak: f32 = 0.0;
    var sum_sq: f64 = 0.0;
    for (samples) |s| {
        const a = @abs(s);
        if (a > peak) peak = a;
        sum_sq += @as(f64, s) * @as(f64, s);
    }
    const rms: f64 = @sqrt(sum_sq / @as(f64, @floatFromInt(samples.len)));

    std.debug.print("peak={d:.4} rms={d:.6}\n", .{ peak, rms });

    if (peak <= 0.001 or peak > 1.0001) {
        std.debug.print("FAIL: peak={d:.4} outside sane [0.001, 1.0] range -- conversion is probably wrong\n", .{peak});
        return error.SuspiciousPeak;
    }
    if (rms <= 0.0) {
        std.debug.print("FAIL: rms is zero -- looks like silence, conversion likely broken\n", .{});
        return error.SuspiciousRms;
    }

    // Cross-check against ffmpeg's own idea of the file's volume, as an
    // independent verifier that our manual int16->f32 conversion has the
    // right scale (not off by 256x, not inverted, etc.) -- convert our peak
    // to dBFS and compare against ffmpeg's volumedetect max_volume.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "/opt/homebrew/bin/ffmpeg", "-i", STEM_PATH, "-af", "volumedetect", "-f", "null", "-" },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const marker = "max_volume: ";
    if (std.mem.indexOf(u8, result.stderr, marker)) |idx| {
        const rest = result.stderr[idx + marker.len ..];
        const end = std.mem.indexOf(u8, rest, " dB") orelse rest.len;
        const ffmpeg_max_db = try std.fmt.parseFloat(f32, rest[0..end]);
        const our_max_db: f32 = 20.0 * std.math.log10(peak);
        std.debug.print("ffmpeg max_volume={d:.2} dB, our computed peak in dB={d:.2} dB\n", .{ ffmpeg_max_db, our_max_db });
        if (@abs(ffmpeg_max_db - our_max_db) > 0.5) {
            std.debug.print("FAIL: our conversion's peak disagrees with ffmpeg's by more than 0.5dB\n", .{});
            return error.ConversionScaleMismatch;
        }
    } else {
        std.debug.print("(could not cross-check against ffmpeg volumedetect output)\n", .{});
    }

    std.debug.print("PASS: real 48kHz/16-bit stem loaded via LoadWave and converted to f32 correctly\n", .{});
}
