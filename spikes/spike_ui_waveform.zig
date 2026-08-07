const std = @import("std");

// Spike: SPEC_UI_REAPER.md §5.3 + roadmap note "waveform render never spiked".
// Proves: (1) source_offset_frames shifts which samples feed columns,
// (2) off-screen columns cull, (3) bounded work for a stem-sized buffer
// (~12M frames) at 60fps budget on one item width.
// Headless — same algorithm as src/main.zig drawWaveform, with offset.

const Wave = struct {
    samples: []const f32, // mono for spike simplicity
    frame_count: u64,
};

fn columnMinMax(wave: Wave, source_offset: u64, visible_frames: u64, col: usize, num_cols: usize) struct { f32, f32 } {
    if (num_cols == 0 or visible_frames == 0) return .{ 0, 0 };
    const frames_per_col = @as(f64, @floatFromInt(visible_frames)) / @as(f64, @floatFromInt(num_cols));
    const start_rel: u64 = @intFromFloat(@as(f64, @floatFromInt(col)) * frames_per_col);
    var end_rel: u64 = @intFromFloat(@as(f64, @floatFromInt(col + 1)) * frames_per_col);
    if (end_rel > visible_frames) end_rel = visible_frames;
    if (end_rel <= start_rel) return .{ 0, 0 };

    const start_frame = source_offset + start_rel;
    var end_frame = source_offset + end_rel;
    if (end_frame > wave.frame_count) end_frame = wave.frame_count;
    if (start_frame >= wave.frame_count or end_frame <= start_frame) return .{ 0, 0 };

    const span = end_frame - start_frame;
    const step: u64 = @max(1, span / 32);
    var min_v: f32 = 0;
    var max_v: f32 = 0;
    var f = start_frame;
    while (f < end_frame) : (f += step) {
        const s = wave.samples[f];
        if (s < min_v) min_v = s;
        if (s > max_v) max_v = s;
    }
    return .{ min_v, max_v };
}

// Returns number of columns that would actually be scanned (after cull).
fn drawWaveformWork(wave: Wave, source_offset: u64, visible_frames: u64, x0: f32, w: f32, screen_w: f32) struct { cols_total: usize, cols_drawn: usize, sample_reads: u64 } {
    if (w <= 0 or visible_frames == 0) return .{ .cols_total = 0, .cols_drawn = 0, .sample_reads = 0 };
    if (x0 + w < 0 or x0 > screen_w) return .{ .cols_total = 0, .cols_drawn = 0, .sample_reads = 0 };

    const num_cols: usize = @intFromFloat(@max(1.0, w));
    var cols_drawn: usize = 0;
    var sample_reads: u64 = 0;
    var col: usize = 0;
    while (col < num_cols) : (col += 1) {
        const x = x0 + @as(f32, @floatFromInt(col));
        if (x < -1 or x > screen_w + 1) continue;
        cols_drawn += 1;
        const mm = columnMinMax(wave, source_offset, visible_frames, col, num_cols);
        _ = mm;
        // Approximate reads used by the algorithm (span/32 steps, capped).
        const frames_per_col = @as(f64, @floatFromInt(visible_frames)) / @as(f64, @floatFromInt(num_cols));
        const span: u64 = @max(1, @as(u64, @intFromFloat(frames_per_col)));
        sample_reads += @max(1, span / 32);
    }
    return .{ .cols_total = num_cols, .cols_drawn = cols_drawn, .sample_reads = sample_reads };
}

fn expect(cond: bool, msg: []const u8, failures: *u32) void {
    if (!cond) {
        std.debug.print("FAIL: {s}\n", .{msg});
        failures.* += 1;
    } else {
        std.debug.print("ok: {s}\n", .{msg});
    }
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var failures: u32 = 0;

    // Synthetic wave: first half = -1, second half = +1 (easy to spot offset).
    const n: usize = 1000;
    const samples = try gpa.alloc(f32, n);
    defer gpa.free(samples);
    for (0..n) |i| samples[i] = if (i < n / 2) -1.0 else 1.0;
    const wave = Wave{ .samples = samples, .frame_count = n };

    // Without offset, leftmost column sees negative peak.
    {
        const mm = columnMinMax(wave, 0, n, 0, 10);
        expect(mm[0] <= -0.9, "col0 without offset sees -1 region", &failures);
        const mm_last = columnMinMax(wave, 0, n, 9, 10);
        expect(mm_last[1] >= 0.9, "last col without offset sees +1 region", &failures);
    }

    // With offset = n/2, visible window is only the +1 half — all cols positive.
    {
        const offline: u64 = n / 2;
        const visible: u64 = n / 2;
        var all_pos = true;
        for (0..10) |col| {
            const mm = columnMinMax(wave, offline, visible, col, 10);
            if (mm[0] < -0.1) all_pos = false;
        }
        expect(all_pos, "offset window only samples +1 half", &failures);
    }

    // Current main.zig trap: offset=0 always — document that without offset
    // the trim UI would still show pre-roll silence visually wrong.
    {
        const offline: u64 = 100;
        const mm_wrong = columnMinMax(wave, 0, 100, 0, 1); // pretend visible 100 but ignore offset
        const mm_right = columnMinMax(wave, offline, 100, 0, 1);
        expect(mm_wrong[0] <= -0.9 and mm_right[0] <= -0.9, "both see -1 here (offset region still negative)", &failures);
        // Shift offset into +1 zone:
        const mm_pos = columnMinMax(wave, 600, 100, 0, 1);
        expect(mm_pos[1] >= 0.9 and mm_pos[0] >= 0.0, "offset into +1 changes column contents", &failures);
    }

    // Cull: fully off-screen → zero work
    {
        const work = drawWaveformWork(wave, 0, n, -5000, 200, 1280);
        expect(work.cols_drawn == 0, "fully off-screen culls all columns", &failures);
    }

    // Partial visibility still draws only on-screen cols
    {
        const work = drawWaveformWork(wave, 0, n, -50, 200, 1280);
        expect(work.cols_drawn > 0 and work.cols_drawn < work.cols_total, "partially off-screen draws subset", &failures);
    }

    // Perf: stem-sized buffer, one screen-width item
    {
        const stem_frames: usize = 13_000_000; // ~roadmap §12 stem order of magnitude
        const screen_w: f32 = 1100;
        const item_w = screen_w;
        const num_cols: usize = @intFromFloat(item_w);
        const frames_per_col = @as(f64, @floatFromInt(stem_frames)) / @as(f64, @floatFromInt(num_cols));
        const reads_per_col: u64 = @max(1, @as(u64, @intFromFloat(frames_per_col)) / 32);
        const total_reads = reads_per_col * num_cols;

        // Budget: span/32 per col. stem/1100 ≈ 11818 → ~369 reads/col * 1100 ≈ 400k.
        std.debug.print("perf estimate: cols={d} frames/col={d:.1} reads/col={d} total_reads={d}\n", .{ num_cols, frames_per_col, reads_per_col, total_reads });
        expect(total_reads < 2_000_000, "stem-sized waveform under 2M reads/frame soft budget", &failures);
        expect(reads_per_col <= 512, "per-column reads capped-ish by /32 stepping", &failures);
    }

    // Timed micro-benchmark on real buffer (1M frames). Zig 0.16 moved Timer
    // out of std.time — use libc clock_gettime directly (same FFI style as
    // the rest of the project).
    {
        const libc = @cImport({
            @cInclude("time.h");
        });
        const frames: usize = 1_000_000;
        const buf = try gpa.alloc(f32, frames);
        defer gpa.free(buf);
        for (0..frames) |i| buf[i] = @sin(@as(f32, @floatFromInt(i)) * 0.01);
        const w = Wave{ .samples = buf, .frame_count = frames };

        var t0: libc.timespec = undefined;
        var t1: libc.timespec = undefined;
        _ = libc.clock_gettime(libc.CLOCK_MONOTONIC, &t0);
        const work = drawWaveformWork(w, 0, frames, 0, 1100, 1280);
        var col: usize = 0;
        const num_cols = work.cols_total;
        while (col < num_cols) : (col += 1) {
            _ = columnMinMax(w, 0, frames, col, num_cols);
        }
        _ = libc.clock_gettime(libc.CLOCK_MONOTONIC, &t1);
        const ns: i128 = (@as(i128, t1.tv_sec) - @as(i128, t0.tv_sec)) * 1_000_000_000 + (@as(i128, t1.tv_nsec) - @as(i128, t0.tv_nsec));
        const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        std.debug.print("timed 1M-frame item width=1100: {d:.2} ms, cols_drawn={d}\n", .{ ms, work.cols_drawn });
        expect(ms < 8.0, "1M-frame waveform draw < 8ms", &failures);
    }

    if (failures > 0) {
        std.debug.print("\nSPIKE RESULT: FAIL ({d})\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nSPIKE RESULT: PASS — offset-aware waveform + cull + budget\n", .{});
}
