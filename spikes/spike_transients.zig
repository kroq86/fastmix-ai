const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
});

// Spike: roadmap §15.3 -- transient/onset detection for the two-step
// analyze_transients -> split_at_transients API. `aubio`/`aubioonset` was not
// installed on this machine; installed via `brew install aubio` (user
// confirmed). Runs on a REAL 10s drum segment (127 BPM stem) and checks the
// onsets are musically plausible (roughly line up with the known tempo's
// eighth-note grid), not just that the command exits 0.
//
// IMPORTANT FINDING: aubioonset's CLI only prints onset positions (one per
// line), NOT a confidence/strength value per onset -- unlike what the
// roadmap's first draft of `analyze_transients`'s response shape assumed
// (`{"frame":18320,"strength":0.91}`). `-t` is an input THRESHOLD controlling
// sensitivity, not an output score. Real implementation must either drop
// "strength" from the response or compute it itself (e.g. local energy at
// each detected frame) -- aubio doesn't hand us one for free.

const BPM = 127.0;
const EIGHTH_NOTE_SEC = 60.0 / BPM / 2.0;

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const drums_path = "/Users/ll/Downloads/999 Stems (127BPM)/2 Drums.wav";
    if (!c.FileExists(drums_path)) {
        std.debug.print("SKIP: real stem not found at {s} on this machine\n", .{drums_path});
        return;
    }

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Cut a manageable 10s segment first.
    {
        const result = try std.process.run(gpa, io, .{
            .argv = &.{
                "/opt/homebrew/bin/ffmpeg", "-y",
                "-ss",                      "20",
                "-t",                       "10",
                "-i",                       drums_path,
                "spikes/onset_drums.wav",
            },
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("region cut failed:\n{s}\n", .{result.stderr});
                return error.FfmpegFailed;
            },
            else => return error.FfmpegFailed,
        }
    }

    // -T samples gives frame numbers directly, matching our AudioRegion model
    // (frames, not seconds -- see §1).
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "/opt/homebrew/bin/aubioonset", "-i", "spikes/onset_drums.wav", "-T", "samples" },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("aubioonset failed (exit {}):\n{s}\n", .{ code, result.stderr });
            return error.AubioFailed;
        },
        else => return error.AubioFailed,
    }

    var frames = std.ArrayList(u64).empty;
    defer frames.deinit(gpa);
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const frame = try std.fmt.parseInt(u64, std.mem.trim(u8, line, " \r"), 10);
        try frames.append(gpa, frame);
    }

    std.debug.print("aubioonset found {} onsets in 10s of real drums\n", .{frames.items.len});
    if (frames.items.len < 5) {
        std.debug.print("FAIL: suspiciously few onsets for 10s of a drum track\n", .{});
        return error.TooFewOnsets;
    }

    // Sanity: median spacing between onsets should be in the right ballpark
    // for a 127 BPM track's rhythmic grid (eighth notes ~= 0.236s), not
    // wildly off (which would suggest we're detecting noise, not real hits).
    const sample_rate: f64 = 48000.0;
    var total_gap_sec: f64 = 0;
    for (1..frames.items.len) |i| {
        const gap_frames = frames.items[i] - frames.items[i - 1];
        total_gap_sec += @as(f64, @floatFromInt(gap_frames)) / sample_rate;
    }
    const avg_gap_sec = total_gap_sec / @as(f64, @floatFromInt(frames.items.len - 1));
    std.debug.print("average onset spacing: {d:.4}s (127bpm eighth-note = {d:.4}s)\n", .{ avg_gap_sec, EIGHTH_NOTE_SEC });

    // Loose bound -- real drum patterns skip/double some subdivisions, this
    // just checks we're in the right musical ballpark, not exact.
    if (avg_gap_sec < EIGHTH_NOTE_SEC * 0.3 or avg_gap_sec > EIGHTH_NOTE_SEC * 4.0) {
        std.debug.print("FAIL: average onset spacing not musically plausible for a 127bpm track\n", .{});
        return error.ImplausibleSpacing;
    }

    std.debug.print("PASS: aubioonset detects musically-plausible onsets on real 127bpm drums; NOTE no per-onset strength/confidence is provided by the CLI (see comment above)\n", .{});
}
