//! ITU-R BS.1770-5 / EBU R128 loudness + true-peak analysis (from scratch).
//! Pure f32 stereo interleaved analysis — no filesystem or JSON.
const std = @import("std");

pub const true_peak_oversample_factor: u32 = 4;
pub const true_peak_method: []const u8 = "linear_interp_4x_approx";

pub const AnalysisScope = enum { measure_window, full_program };

pub const LoudnessResult = struct {
    standard: []const u8 = "ITU-R BS.1770-5 / EBU R128 (from-scratch)",
    integrated_lufs: ?f32 = null,
    short_term_lufs: ?f32 = null,
    momentary_lufs: ?f32 = null,
    window_loudness_lufs: ?f32 = null,
    lra_lu: ?f32 = null,
    lra_null_reason: ?[]const u8 = null,
    gated: bool = true,
    analysis_scope: AnalysisScope = .measure_window,
    sample_peak_dbfs: f32 = -120,
    true_peak_dbtp: f32 = -120,
    true_peak_oversample_factor: u32 = true_peak_oversample_factor,
    true_peak_method: []const u8 = true_peak_method,
    crest_factor_db: f32 = 0,
    clipped_samples: u64 = 0,
};

const BiquadCoeffs = struct { b0: f32, b1: f32, b2: f32, a1: f32, a2: f32 };

const BiquadState = struct {
    x1: f32 = 0,
    x2: f32 = 0,
    y1: f32 = 0,
    y2: f32 = 0,

    fn process(self: *BiquadState, x: f32, c: BiquadCoeffs) f32 {
        const y = c.b0 * x + c.b1 * self.x1 + c.b2 * self.x2 - c.a1 * self.y1 - c.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        return y;
    }
};

// BS.1770-5 Annex 1 K-weighting @ 48 kHz (stage1 shelf + stage2 HP).
const k48_stage1 = BiquadCoeffs{
    .b0 = 1.53512485958697,
    .b1 = -2.69169618940627,
    .b2 = 1.19839281085285,
    .a1 = -1.69065929318241,
    .a2 = 0.73248077421585,
};
const k48_stage2 = BiquadCoeffs{
    .b0 = 1.0,
    .b1 = -2.0,
    .b2 = 1.0,
    .a1 = -1.99004745483398,
    .a2 = 0.99007225036621,
};

const block_ms: f32 = 400.0;
const overlap: f32 = 0.75;
const abs_gate_lufs: f32 = -70.0;
const rel_gate_integrated_lu: f32 = 10.0;
const rel_gate_lra_lu: f32 = 20.0;
const short_term_ms: f32 = 3000.0;
const lra_hop_ms: f32 = 100.0;
const min_lra_windows: usize = 10;
const lufs_offset: f32 = -0.691;
const min_power: f32 = 1.0e-12;

fn dbFromAmplitude(a: f32) f32 {
    return 20.0 * std.math.log10(@max(a, 1.0e-10));
}

fn lufsFromPower(z: f32) f32 {
    return lufs_offset + 10.0 * std.math.log10(@max(z, min_power));
}

/// Approximate bilinear rescale of 48 kHz K-weight biquads for other rates.
fn scaleBiquadApprox(c: BiquadCoeffs, rate_ratio: f32) BiquadCoeffs {
    const r = rate_ratio;
    return .{
        .b0 = c.b0,
        .b1 = c.b1 * r,
        .b2 = c.b2 * r * r,
        .a1 = c.a1 * r,
        .a2 = c.a2 * r * r,
    };
}

fn kWeightCoeffs(sample_rate: u32) struct { stage1: BiquadCoeffs, stage2: BiquadCoeffs } {
    if (sample_rate == 48000) return .{ .stage1 = k48_stage1, .stage2 = k48_stage2 };
    const ratio = @as(f32, @floatFromInt(sample_rate)) / 48000.0;
    return .{
        .stage1 = scaleBiquadApprox(k48_stage1, ratio),
        .stage2 = scaleBiquadApprox(k48_stage2, ratio),
    };
}

/// Apply two-stage K-weighting in place on interleaved stereo f32 (len = frames*2).
pub fn applyKWeightStereo(samples: []f32, sample_rate: u32) void {
    const c = kWeightCoeffs(sample_rate);
    var s1_l: BiquadState = .{};
    var s1_r: BiquadState = .{};
    var s2_l: BiquadState = .{};
    var s2_r: BiquadState = .{};
    var i: usize = 0;
    while (i + 1 < samples.len) : (i += 2) {
        const yl = s2_l.process(s1_l.process(samples[i], c.stage1), c.stage2);
        const yr = s2_r.process(s1_r.process(samples[i + 1], c.stage1), c.stage2);
        samples[i] = yl;
        samples[i + 1] = yr;
    }
}

/// Annex 2 approximation: per-channel linear 4× between consecutive frames,
/// plus vector magnitude sqrt(L²+R²) at the same instants (not certified FIR).
pub fn truePeakDbtp(samples: []const f32) f32 {
    if (samples.len == 0) return -120;
    if (samples.len == 1) return dbFromAmplitude(@abs(samples[0]));
    const frames = samples.len / 2;
    var peak: f32 = 0;
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        const l = samples[f * 2];
        const r = samples[f * 2 + 1];
        peak = @max(peak, @abs(l));
        peak = @max(peak, @abs(r));
        peak = @max(peak, @sqrt(l * l + r * r));
    }
    f = 0;
    while (f + 1 < frames) : (f += 1) {
        const l0 = samples[f * 2];
        const r0 = samples[f * 2 + 1];
        const l1 = samples[(f + 1) * 2];
        const r1 = samples[(f + 1) * 2 + 1];
        const dl = l1 - l0;
        const dr = r1 - r0;
        inline for ([_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 }) |t| {
            const li = l0 + dl * t;
            const ri = r0 + dr * t;
            peak = @max(peak, @abs(li));
            peak = @max(peak, @abs(ri));
            peak = @max(peak, @sqrt(li * li + ri * ri));
        }
    }
    return dbFromAmplitude(peak);
}

pub fn samplePeakDbfs(samples: []const f32) f32 {
    var peak: f32 = 0;
    for (samples) |s| peak = @max(peak, @abs(s));
    return dbFromAmplitude(peak);
}

const BlockInfo = struct { z: f32, lufs: f32, start_frame: usize };

fn blockLenFrames(sample_rate: u32) usize {
    return @max(1, @as(usize, @intFromFloat(block_ms * 0.001 * @as(f32, @floatFromInt(sample_rate)) + 0.5)));
}

fn hopLenFrames(sample_rate: u32) usize {
    return @max(1, @as(usize, @intFromFloat(block_ms * 0.001 * (1.0 - overlap) * @as(f32, @floatFromInt(sample_rate)) + 0.5)));
}

fn compute400msBlocks(kw: []const f32, sample_rate: u32, out: *std.ArrayListUnmanaged(BlockInfo)) !void {
    const frames = kw.len / 2;
    const bl = blockLenFrames(sample_rate);
    const hop = hopLenFrames(sample_rate);
    if (frames < bl) return;
    var start: usize = 0;
    while (start + bl <= frames) : (start += hop) {
        var sum_sq: f64 = 0;
        var n: usize = 0;
        var fi: usize = start;
        while (fi < start + bl) : (fi += 1) {
            const l = kw[fi * 2];
            const r = kw[fi * 2 + 1];
            sum_sq += @as(f64, l) * @as(f64, l) + @as(f64, r) * @as(f64, r);
            n += 1;
        }
        const z = if (n > 0) @as(f32, @floatCast(sum_sq / @as(f64, @floatFromInt(n)))) else min_power;
        try out.append(std.heap.page_allocator, .{ .z = z, .lufs = lufsFromPower(z), .start_frame = start });
    }
}

fn meanPowerAboveGate(blocks: []const BlockInfo, gate_lufs: f32) ?f32 {
    var sum: f64 = 0;
    var count: usize = 0;
    for (blocks) |b| {
        if (b.lufs > gate_lufs) {
            sum += b.z;
            count += 1;
        }
    }
    if (count == 0) return null;
    return @as(f32, @floatCast(sum / @as(f64, @floatFromInt(count))));
}

fn integratedLufs(blocks: []const BlockInfo) ?f32 {
    const abs_mean = meanPowerAboveGate(blocks, abs_gate_lufs) orelse return null;
    const rel_gate = lufsFromPower(abs_mean) - rel_gate_integrated_lu;
    var sum: f64 = 0;
    var count: usize = 0;
    for (blocks) |b| {
        if (b.lufs > abs_gate_lufs and b.lufs > rel_gate) {
            sum += b.z;
            count += 1;
        }
    }
    if (count == 0) return null;
    return lufsFromPower(@as(f32, @floatCast(sum / @as(f64, @floatFromInt(count)))));
}

fn ungatedMeanLufs(blocks: []const BlockInfo) ?f32 {
    if (blocks.len == 0) return null;
    var sum: f64 = 0;
    for (blocks) |b| sum += b.z;
    return lufsFromPower(@as(f32, @floatCast(sum / @as(f64, @floatFromInt(blocks.len)))));
}

fn blocksInWindow(blocks: []const BlockInfo, end_frame: usize, window_frames: usize) []const BlockInfo {
    if (blocks.len == 0) return blocks;
    const start_min = if (end_frame > window_frames) end_frame - window_frames else 0;
    var lo: usize = 0;
    while (lo < blocks.len and blocks[lo].start_frame < start_min) : (lo += 1) {}
    return blocks[lo..];
}

fn shortTermFromBlocks(blocks: []const BlockInfo) ?f32 {
    if (blocks.len == 0) return null;
    var sum: f64 = 0;
    for (blocks) |b| sum += b.z;
    return lufsFromPower(@as(f32, @floatCast(sum / @as(f64, @floatFromInt(blocks.len)))));
}

fn percentile(sorted: []const f32, p: f32) f32 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const idx = p * @as(f32, @floatFromInt(sorted.len - 1));
    const lo = @as(usize, @intFromFloat(std.math.floor(idx)));
    const hi = @min(lo + 1, sorted.len - 1);
    const t = idx - @as(f32, @floatFromInt(lo));
    return sorted[lo] * (1.0 - t) + sorted[hi] * t;
}

fn compute3sWindows(kw: []const f32, sample_rate: u32, out: *std.ArrayListUnmanaged(f32)) !void {
    const frames = kw.len / 2;
    const win = @max(1, @as(usize, @intFromFloat(short_term_ms * 0.001 * @as(f32, @floatFromInt(sample_rate)) + 0.5)));
    const hop = @max(1, @as(usize, @intFromFloat(lra_hop_ms * 0.001 * @as(f32, @floatFromInt(sample_rate)) + 0.5)));
    if (frames < win) return;
    var start: usize = 0;
    while (start + win <= frames) : (start += hop) {
        var sum_sq: f64 = 0;
        var n: usize = 0;
        var fi = start;
        while (fi < start + win) : (fi += 1) {
            const l = kw[fi * 2];
            const r = kw[fi * 2 + 1];
            sum_sq += @as(f64, l) * @as(f64, l) + @as(f64, r) * @as(f64, r);
            n += 1;
        }
        const z = if (n > 0) @as(f32, @floatCast(sum_sq / @as(f64, @floatFromInt(n)))) else min_power;
        try out.append(std.heap.page_allocator, lufsFromPower(z));
    }
}

fn computeLra(windows: []const f32) struct { value: ?f32, null_reason: ?[]const u8 } {
    if (windows.len < min_lra_windows) return .{ .value = null, .null_reason = "window_too_short_for_lra" };
    const abs_mean = meanPowerAboveGateLufs(windows, abs_gate_lufs) orelse return .{ .value = null, .null_reason = "window_too_short_for_lra" };
    const rel_gate = abs_mean - rel_gate_lra_lu;
    var gated: std.ArrayListUnmanaged(f32) = .empty;
    defer gated.deinit(std.heap.page_allocator);
    for (windows) |l| {
        if (l > abs_gate_lufs and l > rel_gate) {
            gated.append(std.heap.page_allocator, l) catch return .{ .value = null, .null_reason = "window_too_short_for_lra" };
        }
    }
    if (gated.items.len < min_lra_windows) return .{ .value = null, .null_reason = "window_too_short_for_lra" };
    std.mem.sort(f32, gated.items, {}, std.sort.asc(f32));
    const l10 = percentile(gated.items, 0.10);
    const l95 = percentile(gated.items, 0.95);
    return .{ .value = l95 - l10, .null_reason = null };
}

fn meanPowerAboveGateLufs(values: []const f32, gate_lufs: f32) ?f32 {
    var sum: f64 = 0;
    var count: usize = 0;
    for (values) |l| {
        if (l > gate_lufs) {
            sum += std.math.pow(f64, 10.0, (@as(f64, l) - @as(f64, lufs_offset)) / 10.0);
            count += 1;
        }
    }
    if (count == 0) return null;
    return lufsFromPower(@as(f32, @floatCast(sum / @as(f64, @floatFromInt(count)))));
}

fn rmsDbfs(samples: []const f32) f32 {
    if (samples.len == 0) return -120;
    var sum: f64 = 0;
    for (samples) |s| sum += @as(f64, s) * @as(f64, s);
    const rms = @sqrt(sum / @as(f64, @floatFromInt(samples.len)));
    return 20.0 * std.math.log10(@max(@as(f32, @floatCast(rms)), 1.0e-10));
}

/// Analyze interleaved stereo f32 samples (len = frames*2).
pub fn analyzeStereo(samples: []const f32, sample_rate: u32, scope: AnalysisScope) LoudnessResult {
    var result: LoudnessResult = .{ .analysis_scope = scope };
    if (samples.len < 2 or sample_rate == 0) return result;

    result.sample_peak_dbfs = samplePeakDbfs(samples);
    result.true_peak_dbtp = truePeakDbtp(samples);

    var clipped: u64 = 0;
    for (samples) |s| {
        if (@abs(s) >= 1.0) clipped += 1;
    }
    result.clipped_samples = clipped;

    const rms_db = rmsDbfs(samples);
    result.crest_factor_db = result.sample_peak_dbfs - rms_db;

    const gpa = std.heap.page_allocator;
    const kw = gpa.alloc(f32, samples.len) catch return result;
    defer gpa.free(kw);
    @memcpy(kw, samples);
    applyKWeightStereo(kw, sample_rate);

    var blocks: std.ArrayListUnmanaged(BlockInfo) = .empty;
    defer blocks.deinit(gpa);
    compute400msBlocks(kw, sample_rate, &blocks) catch return result;

    result.window_loudness_lufs = ungatedMeanLufs(blocks.items);
    // Integrated needs a meaningful gated window — keep null under ~1s of audio.
    const frames = samples.len / 2;
    if (frames >= sample_rate) {
        result.integrated_lufs = integratedLufs(blocks.items);
    } else {
        result.integrated_lufs = null;
    }

    if (blocks.items.len > 0) {
        result.momentary_lufs = blocks.items[blocks.items.len - 1].lufs;
        const st_frames = @as(usize, @intFromFloat(short_term_ms * 0.001 * @as(f32, @floatFromInt(sample_rate)) + 0.5));
        const st_blocks = blocksInWindow(blocks.items, frames, st_frames);
        result.short_term_lufs = shortTermFromBlocks(st_blocks);
    }

    var windows_3s: std.ArrayListUnmanaged(f32) = .empty;
    defer windows_3s.deinit(gpa);
    compute3sWindows(kw, sample_rate, &windows_3s) catch return result;
    const lra = computeLra(windows_3s.items);
    result.lra_lu = lra.value;
    result.lra_null_reason = lra.null_reason;

    return result;
}

/// Fill `out` (interleaved stereo) with a sine for hermetic loudness tests.
pub fn generateStereoSine(out: []f32, sample_rate: u32, freq_hz: f32, amplitude: f32) void {
    const frames = out.len / 2;
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        const t = @as(f32, @floatFromInt(f)) / @as(f32, @floatFromInt(sample_rate));
        const s = amplitude * @sin(2.0 * std.math.pi * freq_hz * t);
        out[f * 2] = s;
        out[f * 2 + 1] = s;
    }
}

/// Synthetic stereo burst: sample peak 0 dBFS per channel, vector magnitude √2 (> sample peak).
pub fn generateInterSamplePeakTest(out: []f32, sample_rate: u32) void {
    _ = sample_rate;
    @memset(out, 0);
    const frames = out.len / 2;
    if (frames == 0) return;
    var f: usize = 0;
    while (f < frames) : (f += 4) {
        out[f * 2] = 1.0;
        out[f * 2 + 1] = 1.0;
    }
    f = 2;
    while (f + 1 < frames) : (f += 4) {
        out[f * 2] = -1.0;
        out[f * 2 + 1] = 1.0;
    }
}

test "stereo sine yields finite LUFS" {
    var buf: [48000 * 2 * 2]f32 = undefined;
    generateStereoSine(&buf, 48000, 1000.0, 0.25);
    const r = analyzeStereo(&buf, 48000, .measure_window);
    try std.testing.expect(r.integrated_lufs != null);
    try std.testing.expect(std.math.isFinite(r.integrated_lufs.?));
    try std.testing.expect(r.window_loudness_lufs != null);
    try std.testing.expect(std.math.isFinite(r.sample_peak_dbfs));
    try std.testing.expect(std.math.isFinite(r.true_peak_dbtp));
}

test "inter-sample peak helper exceeds sample peak" {
    var buf: [4800 * 2]f32 = undefined;
    generateInterSamplePeakTest(&buf, 48000);
    const sp = samplePeakDbfs(&buf);
    const tp = truePeakDbtp(&buf);
    try std.testing.expect(std.math.isFinite(sp));
    try std.testing.expect(std.math.isFinite(tp));
    try std.testing.expect(tp > sp + 2.0); // √2 vector ≈ +3 dB over 0 dBFS sample peak
}

test "short window nulls LRA" {
    var buf: [4800 * 2]f32 = undefined;
    generateStereoSine(&buf, 48000, 440.0, 0.1);
    const r = analyzeStereo(&buf, 48000, .measure_window);
    try std.testing.expect(r.lra_lu == null);
    try std.testing.expect(r.lra_null_reason != null);
    try std.testing.expectEqualStrings("window_too_short_for_lra", r.lra_null_reason.?);
}
