const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("unistd.h");
});

// Spike: does shelling out to `ffmpeg` for sidechaincompress actually duck one
// signal under another, and can we drive it from Zig's std.process.run (which,
// in this Zig version, needs an std.Io.Threaded instance -- subprocess spawning
// got folded into the same new async-I/O redesign as sockets/files)?
//
// Generates a synthetic "kick" (short percussive pulses every 0.5s) and a
// synthetic "bass" (sustained 80Hz tone) as WAVs, runs them through
// `sidechaincompress`, then measures mean volume of the OUTPUT in a
// just-after-a-kick window vs. a window right before the next kick to prove
// the bass actually got quieter when the kick hit.

const SAMPLE_RATE: u32 = 44100;
const DURATION_SEC: u32 = 3;
const FRAME_COUNT: usize = SAMPLE_RATE * DURATION_SEC;

fn writeWav(path: [:0]const u8, samples: []const f32) !void {
    const wave = c.Wave{
        .frameCount = @intCast(samples.len),
        .sampleRate = SAMPLE_RATE,
        .sampleSize = 32,
        .channels = 1,
        .data = @constCast(samples.ptr),
    };
    if (!c.ExportWave(wave, path.ptr)) return error.ExportWaveFailed;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var kick: [FRAME_COUNT]f32 = undefined;
    var bass: [FRAME_COUNT]f32 = undefined;

    const kick_period_sec: f32 = 0.5;
    for (0..FRAME_COUNT) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));

        // Kick: a short decaying 60Hz thump retriggered every kick_period_sec.
        const phase_in_period = @mod(t, kick_period_sec);
        const kick_len: f32 = 0.08;
        if (phase_in_period < kick_len) {
            const env = 1.0 - phase_in_period / kick_len;
            kick[i] = @sin(2.0 * std.math.pi * phase_in_period * 60.0) * env * env;
        } else {
            kick[i] = 0.0;
        }

        // Bass: constant sustained 80Hz tone, nothing ducking it yet -- that's
        // ffmpeg's job downstream.
        bass[i] = @sin(2.0 * std.math.pi * t * 80.0) * 0.6;
    }

    try writeWav("spikes/sc_kick.wav", &kick);
    try writeWav("spikes/sc_bass.wav", &bass);
    std.debug.print("wrote spikes/sc_kick.wav and spikes/sc_bass.wav\n", .{});

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // bass is input 0 (the signal to be compressed), kick is input 1 (the sidechain trigger).
    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            "/opt/homebrew/bin/ffmpeg", "-y",
            "-i",     "spikes/sc_bass.wav",
            "-i",     "spikes/sc_kick.wav",
            "-filter_complex",
            "[0:a][1:a]sidechaincompress=threshold=0.05:ratio=15:attack=5:release=200[out]",
            "-map",   "[out]",
            "spikes/sc_out.wav",
        },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("ffmpeg failed (exit {}):\n{s}\n", .{ code, result.stderr });
            return error.FfmpegFailed;
        },
        else => {
            std.debug.print("ffmpeg terminated abnormally:\n{s}\n", .{result.stderr});
            return error.FfmpegFailed;
        },
    }
    std.debug.print("ffmpeg sidechaincompress OK -> spikes/sc_out.wav\n", .{});

    // Measure mean volume in a "right after kick #3" window (kick hits at
    // 1.0s, so 1.0-1.08s is the thump + a bit of decay) vs. a "quiet, right
    // before the next kick" window (1.4-1.48s, bass had time to recover).
    const after_kick = try measureMeanVolumeDb(gpa, &threaded, "spikes/sc_out.wav", 1.00, 0.08);
    const before_next_kick = try measureMeanVolumeDb(gpa, &threaded, "spikes/sc_out.wav", 1.40, 0.08);

    std.debug.print("mean volume right after kick:  {d:.2} dB\n", .{after_kick});
    std.debug.print("mean volume right before next kick: {d:.2} dB\n", .{before_next_kick});

    if (after_kick >= before_next_kick - 3.0) {
        std.debug.print("FAIL: expected the bass to be at least ~3dB quieter right after the kick (sidechain ducking not detected)\n", .{});
        return error.NoDuckingDetected;
    }
    std.debug.print("PASS (synthetic): bass measurably ducks under the kick ({d:.2}dB drop)\n", .{before_next_kick - after_kick});

    try testRealStems(gpa, &threaded);
}

// Real Suno-style stems on disk (see roadmap §12 / memory fastmix_stems_reference):
// 48kHz, 16-bit int PCM, stereo, ~277s, 127 BPM -- a much more convincing proof
// than a synthetic kick, and exercises the real sample-rate mismatch (48k vs
// our SAMPLE_RATE=44100) that motivated resampling-on-import via ffmpeg.
fn testRealStems(gpa: std.mem.Allocator, threaded: *std.Io.Threaded) !void {
    const io = threaded.io();
    const stems_dir = "/Users/ll/Downloads/999 Stems (127BPM)";
    const drums = stems_dir ++ "/2 Drums.wav";
    const bass = stems_dir ++ "/3 Bass.wav";

    if (c.access(drums, c.F_OK) != 0) {
        std.debug.print("SKIP real-stems test: {s} not found on this machine\n", .{drums});
        return;
    }

    // Only the first 15s -- plenty to prove ducking, much faster than the full ~277s.
    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            "/opt/homebrew/bin/ffmpeg", "-y",
            "-t",     "15",
            "-i",     bass,
            "-t",     "15",
            "-i",     drums,
            "-filter_complex",
            "[0:a][1:a]sidechaincompress=threshold=0.005:ratio=15:attack=1:release=100:detection=peak[out]",
            "-map",   "[out]",
            "spikes/sc_real_out.wav",
        },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("real-stems ffmpeg failed (exit {}):\n{s}\n", .{ code, result.stderr });
            return error.FfmpegFailed;
        },
        else => {
            std.debug.print("real-stems ffmpeg terminated abnormally:\n{s}\n", .{result.stderr});
            return error.FfmpegFailed;
        },
    }
    std.debug.print("ffmpeg on REAL stems OK -> spikes/sc_real_out.wav (also proves 48kHz input into a stereo sidechain filter graph just works)\n", .{});

    const original_bass_db = try measureMeanVolumeDb(gpa, threaded, bass, 0.0, 15.0);
    const sidechained_db = try measureMeanVolumeDb(gpa, threaded, "spikes/sc_real_out.wav", 0.0, 15.0);

    std.debug.print("real bass mean volume (dry):         {d:.2} dB\n", .{original_bass_db});
    std.debug.print("real bass mean volume (sidechained):  {d:.2} dB\n", .{sidechained_db});

    if (sidechained_db >= original_bass_db - 0.5) {
        std.debug.print("FAIL: expected the sidechained real bass to average measurably quieter than the dry bass over 15s of a real drum track\n", .{});
        return error.NoDuckingDetectedOnRealStems;
    }
    std.debug.print("PASS (real stems): sidechained bass is {d:.2}dB quieter on average than dry bass\n", .{original_bass_db - sidechained_db});
}

fn measureMeanVolumeDb(gpa: std.mem.Allocator, threaded: *std.Io.Threaded, path: []const u8, start_sec: f32, len_sec: f32) !f32 {
    const io = threaded.io();
    var start_buf: [32]u8 = undefined;
    var len_buf: [32]u8 = undefined;
    const start_str = try std.fmt.bufPrint(&start_buf, "{d:.3}", .{start_sec});
    const len_str = try std.fmt.bufPrint(&len_buf, "{d:.3}", .{len_sec});

    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            "/opt/homebrew/bin/ffmpeg", "-y",
            "-ss",    start_str,
            "-t",     len_str,
            "-i",     path,
            "-af",    "volumedetect",
            "-f",     "null",
            "-",
        },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // volumedetect prints "mean_volume: -XX.X dB" to stderr.
    const marker = "mean_volume: ";
    const idx = std.mem.indexOf(u8, result.stderr, marker) orelse {
        std.debug.print("could not find mean_volume in ffmpeg output:\n{s}\n", .{result.stderr});
        return error.NoVolumeInfo;
    };
    const rest = result.stderr[idx + marker.len ..];
    const end = std.mem.indexOf(u8, rest, " dB") orelse rest.len;
    return std.fmt.parseFloat(f32, rest[0..end]);
}
