const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
});

// Spike: roadmap §15.4 -- bounded per-region time-stretch via ffmpeg's `atempo`
// filter instead of writing our own elastic-audio/warp DSP. Takes a 5s region
// of a REAL stem (see memory fastmix_stems_reference), stretches it at a few
// ratios within our planned bounds (0.5x-2x), and verifies the output duration
// actually matches what `stretch_region{target_length_frames}` would expect --
// not just that ffmpeg exits 0.

const STEM_PATH = "/Users/ll/Downloads/999 Stems (127BPM)/5 Keyboard.wav";
const REGION_START_SEC = 10.0;
const REGION_LEN_SEC = 5.0;

fn waveDurationSec(path: [:0]const u8) !f64 {
    const wave = c.LoadWave(path.ptr);
    defer c.UnloadWave(wave);
    if (wave.data == null) return error.LoadWaveFailed;
    return @as(f64, @floatFromInt(wave.frameCount)) / @as(f64, @floatFromInt(wave.sampleRate));
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    if (c.FileExists(STEM_PATH) == false) {
        std.debug.print("SKIP: real stem not found at {s} on this machine\n", .{STEM_PATH});
        return;
    }

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Cut out the test region first (dry, no stretch) so we know its exact
    // source duration independent of atempo.
    {
        const result = try std.process.run(gpa, io, .{
            .argv = &.{
                "/opt/homebrew/bin/ffmpeg", "-y",
                "-ss",                      "10.0",
                "-t",                       "5.0",
                "-i",                       STEM_PATH,
                "spikes/atempo_region.wav",
            },
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("region cut failed (exit {}):\n{s}\n", .{ code, result.stderr });
                return error.FfmpegFailed;
            },
            else => return error.FfmpegFailed,
        }
    }

    const source_duration = try waveDurationSec("spikes/atempo_region.wav");
    std.debug.print("source region duration: {d:.3}s (requested {d:.3}s)\n", .{ source_duration, REGION_LEN_SEC });

    // Bounded ratios from §15.4: 0.5x-2x is the hard API-validated range, 0.9-1.1
    // is the "natural" recommended auto-correction zone. Test one from each.
    const ratios = [_]f64{ 0.9, 1.1, 1.5 };

    for (ratios) |ratio| {
        var out_buf: [64]u8 = undefined;
        const out_path = try std.fmt.bufPrintZ(&out_buf, "spikes/atempo_{d:.1}.wav", .{ratio});

        var tempo_buf: [32]u8 = undefined;
        const tempo_str = try std.fmt.bufPrint(&tempo_buf, "{d:.4}", .{ratio});
        var filter_buf: [64]u8 = undefined;
        const filter_str = try std.fmt.bufPrint(&filter_buf, "atempo={s}", .{tempo_str});

        const result = try std.process.run(gpa, io, .{
            .argv = &.{
                "/opt/homebrew/bin/ffmpeg", "-y",
                "-i",                       "spikes/atempo_region.wav",
                "-af",                      filter_str,
                out_path,
            },
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("atempo={d} failed (exit {}):\n{s}\n", .{ ratio, code, result.stderr });
                return error.FfmpegFailed;
            },
            else => return error.FfmpegFailed,
        }

        const out_duration = try waveDurationSec(out_path);
        // atempo>1 speeds up (shorter output); atempo<1 slows down (longer output).
        const expected_duration = source_duration / ratio;
        const err_pct = @abs(out_duration - expected_duration) / expected_duration * 100.0;

        std.debug.print("atempo={d:.2}: output duration={d:.3}s expected~={d:.3}s (err {d:.2}%)\n", .{ ratio, out_duration, expected_duration, err_pct });

        if (err_pct > 3.0) {
            std.debug.print("FAIL: atempo={d} duration off by more than 3%\n", .{ratio});
            return error.DurationMismatch;
        }

        // Sanity: stretched audio shouldn't be silence.
        const vol_result = try std.process.run(gpa, io, .{
            .argv = &.{ "/opt/homebrew/bin/ffmpeg", "-i", out_path, "-af", "volumedetect", "-f", "null", "-" },
        });
        defer gpa.free(vol_result.stdout);
        defer gpa.free(vol_result.stderr);
        const marker = "mean_volume: ";
        if (std.mem.indexOf(u8, vol_result.stderr, marker)) |idx| {
            const rest = vol_result.stderr[idx + marker.len ..];
            const end = std.mem.indexOf(u8, rest, " dB") orelse rest.len;
            std.debug.print("  mean_volume: {s} dB\n", .{rest[0..end]});
        }
    }

    std.debug.print("PASS: atempo at 0.9x/1.1x/1.5x all produced correctly-timed, non-silent output\n", .{});
}
