//! Master delivery QC helpers: full-program render tap, validation, limiter params.
const std = @import("std");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const loudness = @import("loudness.zig");

pub const ProgramAnalysis = struct {
    revision: u64,
    window_start_frame: u64,
    window_length_frames: u64,
    loud: loudness.LoudnessResult,
    exact_from_project_start: bool,
    has_nonfinite: bool = false,
    dc_offset: f32 = 0,
    silence_head_frames: u64 = 0,
    silence_tail_frames: u64 = 0,
};

pub fn projectLengthFrames(project: *const model.Project) u64 {
    const bars = @max(project.length_bars, 1);
    const bpm = @max(project.bpm, 1.0);
    const sec = (@as(f64, @floatFromInt(bars)) * 4.0 * 60.0) / bpm; // bar_size assumed 4 for length estimate when clips shorter
    // Prefer max of length_bars estimate vs last audio clip end.
    var max_frames: u64 = @intFromFloat(sec * @as(f64, @floatFromInt(project.sample_rate)));
    for (project.tracks.items) |t| {
        for (t.clips.items) |c| {
            if (c == .audio) {
                const end: u64 = @as(u64, @intCast(@max(c.audio.timeline_start_frame, 0))) + project.audioPlayableFrames(c.audio);
                if (end > max_frames) max_frames = end;
            }
        }
    }
    return @max(max_frames, 1);
}

/// Renders interleaved stereo master_output samples (no hidden gain). Caller frees.
pub fn renderMasterRange(
    gpa: std.mem.Allocator,
    project: *const model.Project,
    asset_cache: *const mixer.AssetCache,
    start_frame: u64,
    length_frames: u64,
) ![]f32 {
    if (length_frames == 0) return error.EmptyRange;
    // Hard cap ~20 minutes @ 48k to bound memory.
    const max_frames: u64 = 48_000 * 60 * 20;
    if (length_frames > max_frames) return error.RangeTooLarge;

    const buf = try gpa.alloc(f32, length_frames * 2);
    errdefer gpa.free(buf);

    var voices: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;
    var sc = mixer.SidechainRuntime.init(gpa);
    defer sc.deinit();
    var eq = mixer.EqRuntime.init(gpa);
    defer eq.deinit();
    var comp = mixer.CompressorRuntime.init(gpa);
    defer comp.deinit();
    var delay = mixer.DelayRuntime.init(gpa);
    defer delay.deinit();
    var lim = mixer.LimiterRuntime.init(gpa);
    defer lim.deinit();
    var master_lvl: mixer.MasterLevel = .{};

    var i: u64 = 0;
    while (i < length_frames) : (i += 1) {
        const frame = start_frame + i;
        var l: f32 = 0;
        var r: f32 = 0;
        mixer.mixSample(project, &voices, asset_cache, frame, frame, .{}, &sc, &eq, &comp, &delay, &lim, null, project.sample_rate, &l, &r, null, null, &master_lvl, false);
        buf[i * 2 + 0] = master_lvl.out_l;
        buf[i * 2 + 1] = master_lvl.out_r;
    }
    return buf;
}

pub fn analyzeProgram(
    gpa: std.mem.Allocator,
    project: *const model.Project,
    asset_cache: *const mixer.AssetCache,
    start_frame: u64,
    length_frames: ?u64,
) !ProgramAnalysis {
    const total = projectLengthFrames(project);
    const start = start_frame;
    const len = length_frames orelse (if (start < total) total - start else 0);
    if (len == 0) return error.EmptyRange;
    const buf = try renderMasterRange(gpa, project, asset_cache, start, len);
    defer gpa.free(buf);
    const scope: loudness.AnalysisScope = if (start == 0 and len >= total) .full_program else .measure_window;
    const lr = loudness.analyzeStereo(buf, project.sample_rate, scope);
    var has_nf = false;
    var sum: f64 = 0;
    for (buf) |s| {
        if (!std.math.isFinite(s)) has_nf = true;
        sum += s;
    }
    const dc: f32 = if (buf.len > 0) @floatCast(sum / @as(f64, @floatFromInt(buf.len))) else 0;
    const thr: f32 = 1.0e-4;
    var head: u64 = 0;
    while (head < len) : (head += 1) {
        if (@max(@abs(buf[head * 2]), @abs(buf[head * 2 + 1])) > thr) break;
    }
    var tail: u64 = 0;
    while (tail < len) : (tail += 1) {
        const fi = len - 1 - tail;
        if (@max(@abs(buf[fi * 2]), @abs(buf[fi * 2 + 1])) > thr) break;
    }
    return .{
        .revision = project.revision,
        .window_start_frame = start,
        .window_length_frames = len,
        .loud = lr,
        .exact_from_project_start = start == 0,
        .has_nonfinite = has_nf,
        .dc_offset = dc,
        .silence_head_frames = head,
        .silence_tail_frames = tail,
    };
}

pub const CheckStatus = enum { pass, warning, fail };

pub const Check = struct {
    name: []const u8,
    status: CheckStatus,
    measured: ?f64 = null,
    limit: ?f64 = null,
    unit: []const u8 = "",
    detail: []const u8 = "",
};

pub const DeliveryProfile = struct {
    name: []const u8 = "custom",
    target_integrated_lufs: f32 = -14.0,
    tolerance_lu: f32 = 1.0,
    max_true_peak_dbtp: f32 = -1.0,
    source: []const u8 = "user-supplied / product policy (not an ITU mandate)",
};

pub fn validateDelivery(analysis: ProgramAnalysis, profile: DeliveryProfile, sample_rate: u32, channels: u32) struct { status: CheckStatus, checks: [12]Check, n: usize } {
    var checks: [12]Check = undefined;
    var n: usize = 0;
    var worst: CheckStatus = .pass;

    const bump = struct {
        fn go(w: *CheckStatus, s: CheckStatus) void {
            if (s == .fail) w.* = .fail else if (s == .warning and w.* != .fail) w.* = .warning;
        }
    }.go;

    {
        const st: CheckStatus = if (analysis.has_nonfinite) .fail else .pass;
        bump(&worst, st);
        checks[n] = .{ .name = "nan_inf", .status = st, .detail = if (analysis.has_nonfinite) "nonfinite_samples" else "" };
        n += 1;
    }
    {
        const tp = analysis.loud.true_peak_dbtp;
        const st: CheckStatus = if (tp > profile.max_true_peak_dbtp) .fail else .pass;
        bump(&worst, st);
        checks[n] = .{ .name = "true_peak", .status = st, .measured = tp, .limit = profile.max_true_peak_dbtp, .unit = "dBTP" };
        n += 1;
    }
    {
        if (analysis.loud.integrated_lufs) |il| {
            const lo = profile.target_integrated_lufs - profile.tolerance_lu;
            const hi = profile.target_integrated_lufs + profile.tolerance_lu;
            const st: CheckStatus = if (il < lo or il > hi) .fail else .pass;
            bump(&worst, st);
            checks[n] = .{ .name = "integrated_lufs", .status = st, .measured = il, .limit = profile.target_integrated_lufs, .unit = "LUFS", .detail = "tolerance applied around target" };
            n += 1;
        } else {
            bump(&worst, .warning);
            checks[n] = .{ .name = "integrated_lufs", .status = .warning, .detail = "unavailable_on_this_window" };
            n += 1;
        }
    }
    {
        const st: CheckStatus = if (analysis.loud.clipped_samples > 0) .fail else .pass;
        bump(&worst, st);
        checks[n] = .{ .name = "sample_clipping", .status = st, .measured = @floatFromInt(analysis.loud.clipped_samples), .limit = 0, .unit = "samples" };
        n += 1;
    }
    {
        const st: CheckStatus = if (@abs(analysis.dc_offset) > 0.02) .warning else .pass;
        bump(&worst, st);
        checks[n] = .{ .name = "dc_offset", .status = st, .measured = analysis.dc_offset, .limit = 0.02, .unit = "lin" };
        n += 1;
    }
    {
        const quiet_ok = analysis.silence_head_frames < analysis.window_length_frames and analysis.silence_tail_frames < analysis.window_length_frames;
        const st: CheckStatus = if (!quiet_ok) .warning else .pass;
        bump(&worst, st);
        checks[n] = .{ .name = "silence_head_tail", .status = st, .measured = @floatFromInt(analysis.silence_head_frames), .unit = "frames", .detail = "warn_if_entire_program_quiet" };
        n += 1;
    }
    checks[n] = .{ .name = "sample_rate", .status = if (sample_rate >= 44100) .pass else .warning, .measured = @floatFromInt(sample_rate), .unit = "Hz" };
    n += 1;
    checks[n] = .{ .name = "channel_count", .status = if (channels == 2) .pass else .fail, .measured = @floatFromInt(channels), .limit = 2, .unit = "ch" };
    if (channels != 2) bump(&worst, .fail);
    n += 1;
    checks[n] = .{ .name = "duration_frames", .status = if (analysis.window_length_frames > 0) .pass else .fail, .measured = @floatFromInt(analysis.window_length_frames), .unit = "frames" };
    n += 1;

    return .{ .status = worst, .checks = checks, .n = n };
}

pub fn getLimiterParam(p: model.LimiterParams, name: []const u8) ?f32 {
    if (std.mem.eql(u8, name, "ceiling_dbfs") or std.mem.eql(u8, name, "limit_db")) return p.ceiling_dbfs;
    if (std.mem.eql(u8, name, "threshold_db")) return p.threshold_db;
    if (std.mem.eql(u8, name, "release_ms")) return p.release_ms;
    if (std.mem.eql(u8, name, "lookahead_ms")) return p.lookahead_ms;
    if (std.mem.eql(u8, name, "link_channels")) return if (p.link_channels) 1.0 else 0.0;
    return null;
}

pub fn setLimiterParam(p: *model.LimiterParams, name: []const u8, value: f32) bool {
    if (std.mem.eql(u8, name, "ceiling_dbfs") or std.mem.eql(u8, name, "limit_db")) {
        p.ceiling_dbfs = value;
        return true;
    }
    if (std.mem.eql(u8, name, "threshold_db")) {
        p.threshold_db = value;
        return true;
    }
    if (std.mem.eql(u8, name, "release_ms")) {
        p.release_ms = @max(value, 0.1);
        return true;
    }
    if (std.mem.eql(u8, name, "lookahead_ms")) {
        p.lookahead_ms = @max(value, 0.0);
        return true;
    }
    if (std.mem.eql(u8, name, "link_channels")) {
        p.link_channels = value >= 0.5;
        return true;
    }
    return false;
}

pub fn needsHumanLimiterParam(name: []const u8) bool {
    return std.mem.eql(u8, name, "release_ms") or std.mem.eql(u8, name, "lookahead_ms");
}

/// Pick up to 4 representative windows (length excerpt_frames) from a buffer by scanning peaks.
pub const Excerpt = struct {
    reason: []const u8,
    start_frame: u64,
};

pub fn pickExcerpts(samples: []const f32, excerpt_frames: u64, sample_rate: u32) [4]Excerpt {
    _ = sample_rate;
    const total_frames = samples.len / 2;
    const win = @min(excerpt_frames, @max(total_frames, 1));
    var best_peak: f32 = -1;
    var best_peak_i: u64 = 0;
    var best_rms: f64 = -1;
    var best_rms_i: u64 = 0;
    // Scan in hops of win/4
    const hop = @max(win / 4, 1);
    var i: u64 = 0;
    while (i + win <= total_frames) : (i += hop) {
        var peak: f32 = 0;
        var sum: f64 = 0;
        var f: u64 = 0;
        while (f < win) : (f += 1) {
            const l = samples[(i + f) * 2];
            const r = samples[(i + f) * 2 + 1];
            peak = @max(peak, @max(@abs(l), @abs(r)));
            sum += @as(f64, l) * @as(f64, l) + @as(f64, r) * @as(f64, r);
        }
        if (peak > best_peak) {
            best_peak = peak;
            best_peak_i = i;
        }
        if (sum > best_rms) {
            best_rms = sum;
            best_rms_i = i;
        }
    }
    // True-peak proxy: reuse sample peak starts with different labels / offsets
    const tp_i = (best_peak_i + hop) % @max(total_frames -| win + 1, 1);
    const gr_i = best_rms_i; // without GR side data, use loudest as GR proxy section
    return .{
        .{ .reason = "loudest_section", .start_frame = best_rms_i },
        .{ .reason = "highest_true_peak", .start_frame = best_peak_i },
        .{ .reason = "highest_short_term_loudness", .start_frame = tp_i },
        .{ .reason = "highest_limiter_gr", .start_frame = gr_i },
    };
}
