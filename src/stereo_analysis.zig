//! Stereo / Mid-Side observability on interleaved f32 stereo.
//! Pure analysis — no filesystem. Used by measure + offline program compare.
const std = @import("std");
const loudness = @import("loudness.zig");

pub const MS_BAND_COUNT: usize = 5;
pub const MS_BAND_NAMES = [_][]const u8{ "low", "low_mid", "mid", "high_mid", "high" };
/// Edge frequencies separating the five bands (Hz): 20–150 | 150–500 | 500–2k | 2k–6k | 6k–16k.
pub const MS_CROSSOVERS_HZ = [_]f32{ 150.0, 500.0, 2000.0, 6000.0 };

pub const BandMs = struct {
    name: []const u8,
    mid_energy_db: f32 = -120,
    side_energy_db: f32 = -120,
    /// side_to_mid_db = side_energy_db - mid_energy_db (more negative = narrower).
    side_to_mid_db: f32 = -120,
};

pub const StereoResult = struct {
    mid_rms_dbfs: f32 = -120,
    side_rms_dbfs: f32 = -120,
    side_to_mid_db: f32 = -120,
    correlation_mean: f32 = 1.0,
    correlation_min: f32 = 1.0,
    correlation_p05: f32 = 1.0,
    mono_sum_peak_dbfs: f32 = -120,
    mono_sum_rms_dbfs: f32 = -120,
    /// stereo_rms_db - mono_sum_rms_db (positive => mono quieter / energy lost in fold-down).
    mono_loss_db: f32 = 0,
    anti_phase_sample_ratio: f32 = 0,
    bands: [MS_BAND_COUNT]BandMs = .{
        .{ .name = "low" },
        .{ .name = "low_mid" },
        .{ .name = "mid" },
        .{ .name = "high_mid" },
        .{ .name = "high" },
    },
    /// Deterministic summary for agents (not a quality judgment).
    narrowness_localization: []const u8 = "all bands are strongly mid-dominant",
};

pub const ProgramCompareMetrics = struct {
    analysis_scope: loudness.AnalysisScope,
    window_start_frame: u64 = 0,
    window_length_frames: u64 = 0,
    integrated_lufs: ?f32 = null,
    lra_lu: ?f32 = null,
    lra_null_reason: ?[]const u8 = null,
    crest_factor_db: f32 = 0,
    sample_peak_dbfs: f32 = -120,
    true_peak_dbtp: f32 = -120,
    stereo_correlation_mean: f32 = 1.0,
    stereo_correlation_min: f32 = 1.0,
    side_to_mid_energy_db: f32 = -120,
    stereo: StereoResult = .{},
};

fn dbAmp(a: f32) f32 {
    return 20.0 * std.math.log10(@max(a, 1.0e-10));
}

fn dbPow(p: f64) f32 {
    return @floatCast(10.0 * std.math.log10(@max(p, 1.0e-24)));
}

const OnePole = struct {
    a: f32 = 0,
    z: f32 = 0,
    pub fn initLpf(cutoff_hz: f32, sample_rate: f32) OnePole {
        const x = std.math.exp(-2.0 * std.math.pi * cutoff_hz / sample_rate);
        return .{ .a = 1.0 - @as(f32, @floatCast(x)) };
    }
    pub fn process(self: *OnePole, x: f32) f32 {
        self.z += self.a * (x - self.z);
        return self.z;
    }
};

/// Analyze interleaved stereo buffer. Deterministic for identical buffers.
pub fn analyzeStereo(samples: []const f32, sample_rate: u32) StereoResult {
    var out: StereoResult = .{};
    const frames = samples.len / 2;
    if (frames == 0) return out;

    const sr: f32 = @floatFromInt(if (sample_rate == 0) 44100 else sample_rate);
    const corr_block: usize = @max(1, @as(usize, @intFromFloat(0.05 * sr))); // 50 ms

    var mid_sum_sq: f64 = 0;
    var side_sum_sq: f64 = 0;
    var stereo_sum_sq: f64 = 0;
    var mono_sum_sq: f64 = 0;
    var mono_peak: f32 = 0;
    var anti_n: u64 = 0;
    const anti_floor: f32 = 1.0e-4;

    // Band energy accumulators (mid/side) via complementary one-pole tree.
    var mid_band_e: [MS_BAND_COUNT]f64 = [_]f64{0} ** MS_BAND_COUNT;
    var side_band_e: [MS_BAND_COUNT]f64 = [_]f64{0} ** MS_BAND_COUNT;
    var lpf_m: [MS_CROSSOVERS_HZ.len]OnePole = undefined;
    var lpf_s: [MS_CROSSOVERS_HZ.len]OnePole = undefined;
    for (&lpf_m, &lpf_s, MS_CROSSOVERS_HZ) |*lm, *ls, hz| {
        lm.* = OnePole.initLpf(hz, sr);
        ls.* = OnePole.initLpf(hz, sr);
    }

    var corr_blocks: std.ArrayListUnmanaged(f32) = .empty;
    defer corr_blocks.deinit(std.heap.page_allocator);

    var b_sum_ll: f64 = 0;
    var b_sum_rr: f64 = 0;
    var b_sum_lr: f64 = 0;
    var b_sum_l: f64 = 0;
    var b_sum_r: f64 = 0;
    var b_n: usize = 0;

    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const l = samples[i * 2];
        const r = samples[i * 2 + 1];
        const mid = 0.5 * (l + r);
        const side = 0.5 * (l - r);
        mid_sum_sq += @as(f64, mid) * @as(f64, mid);
        side_sum_sq += @as(f64, side) * @as(f64, side);
        stereo_sum_sq += 0.5 * (@as(f64, l) * @as(f64, l) + @as(f64, r) * @as(f64, r));
        const mono = l + r;
        mono_sum_sq += @as(f64, mono) * @as(f64, mono);
        mono_peak = @max(mono_peak, @abs(mono));
        if (@abs(l) > anti_floor and @abs(r) > anti_floor and l * r < 0) anti_n += 1;

        // Split mid/side into 5 bands.
        const m0 = mid;
        const s0 = side;
        const m1 = lpf_m[0].process(m0);
        const s1 = lpf_s[0].process(s0);
        const m_hi0 = m0 - m1;
        const s_hi0 = s0 - s1;
        const m2 = lpf_m[1].process(m_hi0);
        const s2 = lpf_s[1].process(s_hi0);
        const m_hi1 = m_hi0 - m2;
        const s_hi1 = s_hi0 - s2;
        const m3 = lpf_m[2].process(m_hi1);
        const s3 = lpf_s[2].process(s_hi1);
        const m_hi2 = m_hi1 - m3;
        const s_hi2 = s_hi1 - s3;
        const m4 = lpf_m[3].process(m_hi2);
        const s4 = lpf_s[3].process(s_hi2);
        const m5 = m_hi2 - m4;
        const s5 = s_hi2 - s4;
        const m_bands = [_]f32{ m1, m2, m3, m4, m5 };
        const s_bands = [_]f32{ s1, s2, s3, s4, s5 };
        for (&mid_band_e, &side_band_e, m_bands, s_bands) |*me, *se, mb, sb| {
            me.* += @as(f64, mb) * @as(f64, mb);
            se.* += @as(f64, sb) * @as(f64, sb);
        }

        b_sum_l += l;
        b_sum_r += r;
        b_sum_ll += @as(f64, l) * @as(f64, l);
        b_sum_rr += @as(f64, r) * @as(f64, r);
        b_sum_lr += @as(f64, l) * @as(f64, r);
        b_n += 1;
        if (b_n >= corr_block or i + 1 == frames) {
            const n = @as(f64, @floatFromInt(b_n));
            const mean_l = b_sum_l / n;
            const mean_r = b_sum_r / n;
            const var_l = @max(b_sum_ll / n - mean_l * mean_l, 0);
            const var_r = @max(b_sum_rr / n - mean_r * mean_r, 0);
            const cov = b_sum_lr / n - mean_l * mean_r;
            const den = @sqrt(var_l * var_r);
            const c: f32 = if (den > 1.0e-18) @floatCast(std.math.clamp(cov / den, -1.0, 1.0)) else 1.0;
            corr_blocks.append(std.heap.page_allocator, c) catch {};
            b_sum_ll = 0;
            b_sum_rr = 0;
            b_sum_lr = 0;
            b_sum_l = 0;
            b_sum_r = 0;
            b_n = 0;
        }
    }

    const n_f = @as(f64, @floatFromInt(frames));
    const mid_rms = @sqrt(mid_sum_sq / n_f);
    const side_rms = @sqrt(side_sum_sq / n_f);
    const stereo_rms = @sqrt(stereo_sum_sq / n_f);
    const mono_rms = @sqrt(mono_sum_sq / n_f);
    out.mid_rms_dbfs = dbAmp(@floatCast(mid_rms));
    out.side_rms_dbfs = dbAmp(@floatCast(side_rms));
    out.side_to_mid_db = out.side_rms_dbfs - out.mid_rms_dbfs;
    out.mono_sum_peak_dbfs = dbAmp(mono_peak);
    out.mono_sum_rms_dbfs = dbAmp(@floatCast(mono_rms));
    out.mono_loss_db = dbAmp(@floatCast(stereo_rms)) - out.mono_sum_rms_dbfs;
    out.anti_phase_sample_ratio = @as(f32, @floatFromInt(anti_n)) / @as(f32, @floatFromInt(frames));

    if (corr_blocks.items.len > 0) {
        var sum: f64 = 0;
        var min_c: f32 = 1.0;
        for (corr_blocks.items) |c| {
            sum += c;
            min_c = @min(min_c, c);
        }
        out.correlation_mean = @floatCast(sum / @as(f64, @floatFromInt(corr_blocks.items.len)));
        out.correlation_min = min_c;
        std.mem.sort(f32, corr_blocks.items, {}, std.sort.asc(f32));
        const p05_i = @min(corr_blocks.items.len - 1, (corr_blocks.items.len * 5) / 100);
        out.correlation_p05 = corr_blocks.items[p05_i];
    }

    for (&out.bands, mid_band_e, side_band_e, MS_BAND_NAMES) |*b, me, se, name| {
        b.name = name;
        b.mid_energy_db = dbPow(me / n_f);
        b.side_energy_db = dbPow(se / n_f);
        b.side_to_mid_db = b.side_energy_db - b.mid_energy_db;
    }
    out.narrowness_localization = localizeNarrowness(&out.bands);
    return out;
}

fn localizeNarrowness(bands: *const [MS_BAND_COUNT]BandMs) []const u8 {
    // More negative side_to_mid = narrower. Find where mid dominance is strongest
    // among upper bands vs whether all bands are mid-dominant.
    const mid_dom_thresh: f32 = -6.0; // side at least 6 dB below mid
    var all_mid = true;
    var strongest_i: usize = 0;
    var strongest_neg: f32 = 0;
    for (bands.*, 0..) |b, i| {
        if (b.side_to_mid_db > mid_dom_thresh) all_mid = false;
        if (b.side_to_mid_db < strongest_neg) {
            strongest_neg = b.side_to_mid_db;
            strongest_i = i;
        }
    }
    if (all_mid) return "all bands are strongly mid-dominant";
    // Prefer calling out high-mid/high when those are the narrowest among mid-upward.
    const hi_avg = 0.5 * (bands[3].side_to_mid_db + bands[4].side_to_mid_db);
    const lo_avg = 0.5 * (bands[0].side_to_mid_db + bands[1].side_to_mid_db);
    if (hi_avg < lo_avg - 3.0 and hi_avg < mid_dom_thresh)
        return "narrowness is concentrated in high-mid/high bands";
    if (lo_avg < hi_avg - 3.0 and lo_avg < mid_dom_thresh)
        return "narrowness is concentrated in low/low-mid bands";
    if (strongest_i >= 3) return "narrowness is concentrated in high-mid/high bands";
    if (strongest_i <= 1) return "narrowness is concentrated in low/low-mid bands";
    return "narrowness is concentrated in mid band";
}

/// Loudness + stereo for a comparable program/section scope.
pub fn analyzeProgramBuffer(
    samples: []const f32,
    sample_rate: u32,
    scope: loudness.AnalysisScope,
    start_frame: u64,
) ProgramCompareMetrics {
    const loud = loudness.analyzeStereo(samples, sample_rate, scope);
    const st = analyzeStereo(samples, sample_rate);
    return .{
        .analysis_scope = scope,
        .window_start_frame = start_frame,
        .window_length_frames = samples.len / 2,
        .integrated_lufs = loud.integrated_lufs,
        .lra_lu = loud.lra_lu,
        .lra_null_reason = loud.lra_null_reason,
        .crest_factor_db = loud.crest_factor_db,
        .sample_peak_dbfs = loud.sample_peak_dbfs,
        .true_peak_dbtp = loud.true_peak_dbtp,
        .stereo_correlation_mean = st.correlation_mean,
        .stereo_correlation_min = st.correlation_min,
        .side_to_mid_energy_db = st.side_to_mid_db,
        .stereo = st,
    };
}

/// Apply stereo width with optional crossover (no makeup gain).
pub fn applyWidthSample(
    l: f32,
    r: f32,
    low_width: f32,
    high_width: f32,
    lpf_m: *OnePole,
    lpf_s: *OnePole,
    use_crossover: bool,
) struct { l: f32, r: f32 } {
    const mid = 0.5 * (l + r);
    const side = 0.5 * (l - r);
    if (!use_crossover) {
        const s2 = side * high_width;
        return .{ .l = mid + s2, .r = mid - s2 };
    }
    const low_m = lpf_m.process(mid);
    const low_s = lpf_s.process(side);
    const high_m = mid - low_m;
    const high_s = side - low_s;
    const s2 = low_s * low_width + high_s * high_width;
    const m2 = low_m + high_m;
    return .{ .l = m2 + s2, .r = m2 - s2 };
}

pub const WidthOnePole = OnePole;

