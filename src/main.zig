const std = @import("std");

const model = @import("model.zig");
const mixer = @import("mixer.zig");
const socket = @import("socket.zig");
const persist = @import("persist.zig");
const jobs = @import("jobs.zig");
const offline_audio = @import("offline_audio.zig");
const trial = @import("trial.zig");
const ui = @import("ui.zig");
const window_config = @import("window_config.zig");
const audio_config = @import("audio_config.zig");
const loudness = @import("loudness.zig");
const stereo_analysis = @import("stereo_analysis.zig");
const master_qc = @import("master_qc.zig");
const mix_preflight = @import("mix_preflight.zig");
const mix_sections = @import("mix_sections.zig");
const vocal_balance = @import("vocal_balance.zig");

const c = @cImport({
    @cInclude("raylib.h");
});
const libc = @cImport({
    @cInclude("sys/stat.h");
});

const AUBIOONSET_PATH = "/opt/homebrew/bin/aubioonset";
const FFMPEG_PATH = "/opt/homebrew/bin/ffmpeg";

fn loadWavAsAsset(gpa: std.mem.Allocator, path: []const u8) !mixer.LoadedAsset {
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const wave = c.LoadWave(path_z.ptr);
    defer c.UnloadWave(wave);
    if (wave.data == null) return error.LoadWaveFailed;
    const frame_count: usize = @intCast(wave.frameCount);
    const channels: usize = @intCast(wave.channels);
    const total = frame_count * channels;
    const samples = try gpa.alloc(f32, total);
    switch (wave.sampleSize) {
        16 => {
            const src: [*]const i16 = @ptrCast(@alignCast(wave.data));
            for (0..total) |i| samples[i] = @as(f32, @floatFromInt(src[i])) / 32768.0;
        },
        8 => {
            const src: [*]const u8 = @ptrCast(@alignCast(wave.data));
            for (0..total) |i| samples[i] = (@as(f32, @floatFromInt(src[i])) - 128.0) / 128.0;
        },
        32 => {
            const src: [*]const f32 = @ptrCast(@alignCast(wave.data));
            for (0..total) |i| samples[i] = src[i];
        },
        else => return error.UnsupportedSampleSize,
    }
    return .{ .samples = samples, .channels = @intCast(wave.channels), .frame_count = wave.frameCount };
}

const SAMPLE_RATE: u32 = 44100;
/// Hard ceiling for stack audio fill buffer; live size comes from `audio_config`.
const MAX_AUDIO_BLOCK: usize = audio_config.MAX_BLOCK_SIZE;
const CLICK_SAMPLES: u32 = SAMPLE_RATE / 40;
const SOCKET_PATH = "/tmp/fastmix-ai.sock";

const KEYBOARD_COUNT: usize = 13;
const KEYBOARD = [KEYBOARD_COUNT]c_int{
    c.KEY_Z, c.KEY_S, c.KEY_X, c.KEY_D, c.KEY_C, c.KEY_V, c.KEY_G,
    c.KEY_B, c.KEY_H, c.KEY_N, c.KEY_J, c.KEY_M, c.KEY_COMMA,
};

fn fmodCycling(a: f64, b: f64) f64 {
    const r = @mod(a, b);
    return if (r < 0) r + b else r;
}

fn clipBars(events: []const model.Event, bar_quant: i64) i64 {
    if (events.len == 0) return 1;
    const last_quant = events[events.len - 1].quant;
    return @divFloor(last_quant, bar_quant) + 1;
}

pub const PendingImport = struct {
    job_id: jobs.JobId,
    track_id: model.TrackId,
    asset_id: model.AssetId,
    cache_path: [256]u8 = undefined,
    cache_path_len: usize,
    start_frame: i64,
    source_offset_frames: u64,
    source_bpm: ?f64,
};

pub const RenderState = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    path: ?[]u8 = null,
};

pub const LivePeaks = struct {
    track_l: [64]f32 = [_]f32{0} ** 64,
    track_r: [64]f32 = [_]f32{0} ** 64,
    bus_l: [32]f32 = [_]f32{0} ** 32,
    bus_r: [32]f32 = [_]f32{0} ** 32,
    bus_in_peak: [32]f32 = [_]f32{0} ** 32,
    bus_out_peak: [32]f32 = [_]f32{0} ** 32,
    master: f32 = 0,
    track_count: usize = 0,
    bus_count: usize = 0,
};

/// Fill-loop hitch proxy (main thread `IsAudioStreamProcessed` drains).
/// Not a CoreAudio/device XRun counter — see `max_fill_gap_ms`.
pub const AudioDiag = struct {
    /// Main-thread buffer fills (`UpdateAudioStream` iterations).
    audio_fill_count: u64 = 0,
    /// Legacy alias of `audio_fill_count` in JSON.
    audio_callback_count: u64 = 0,
    last_fill_timestamp: f64 = 0,
    max_fill_gap_ms: f64 = 0,
    /// Legacy alias of `max_fill_gap_ms` in JSON.
    max_callback_gap_ms: f64 = 0,
    buffer_underrun_events: u64 = 0,
    /// Legacy alias of `buffer_underrun_events`.
    underrun_count: u64 = 0,
    buffer_low_watermark_frames: i64 = std.math.maxInt(i64),
    stream_capacity_frames: u64 = 2048 * 2,
    command_duration_ms: f64 = 0,
    max_command_duration_ms: f64 = 0,
    measure_duration_ms: f64 = 0,
    audition_duration_ms: f64 = 0,
    level_match_duration_ms: f64 = 0,
    trial_duration_ms: f64 = 0,
    last_fill_time_s: f64 = 0,

    pub fn reset(self: *AudioDiag) void {
        const cap = self.stream_capacity_frames;
        self.* = .{};
        self.stream_capacity_frames = cap;
        self.buffer_low_watermark_frames = @intCast(cap);
    }

    pub fn noteFillGap(self: *AudioDiag, gap_ms: f64, expected_gap_ms: f64, sample_rate: u32) void {
        if (gap_ms > self.max_fill_gap_ms) self.max_fill_gap_ms = gap_ms;
        self.max_callback_gap_ms = self.max_fill_gap_ms;
        if (gap_ms > expected_gap_ms * 2.5) {
            self.buffer_underrun_events += 1;
            self.underrun_count = self.buffer_underrun_events;
        }
        const gap_frames: i64 = @intFromFloat(gap_ms / 1000.0 * @as(f64, @floatFromInt(if (sample_rate == 0) 44100 else sample_rate)));
        const remaining: i64 = @as(i64, @intCast(self.stream_capacity_frames)) - gap_frames;
        const wm = if (remaining < 0) 0 else remaining;
        if (wm < self.buffer_low_watermark_frames) self.buffer_low_watermark_frames = wm;
    }

    pub fn noteCommandMs(self: *AudioDiag, ms: f64) void {
        self.command_duration_ms = ms;
        if (ms > self.max_command_duration_ms) self.max_command_duration_ms = ms;
    }
};

pub const DispatchCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    project: *model.Project,
    project_path: *?[]const u8,
    history: *persist.History,
    asset_cache: *mixer.AssetCache,
    job_registry: *jobs.Registry,
    offline_registry: *offline_audio.Registry,
    pending_imports: *std.ArrayList(PendingImport),
    render_state: *RenderState,
    transport: *ui.Transport,
    beat_time: *f64,
    live_peaks: *LivePeaks,
    audio_diag: *AudioDiag,
    view: *ui.View,
    sc_rt: *mixer.SidechainRuntime,
    trial_registry: *trial.Registry,
    frame_count: *const u64,
    operation_counter: *u64,
    /// High-level mix gate (preflight must pass; revision must match).
    mix_gate: *mix_preflight.MixSessionGate,
    /// Pending audio block size from socket; main applies (recreates stream).
    pending_audio_block_size: ?*?u32 = null,
    /// Currently applied block size (frames).
    audio_block_size: ?*u32 = null,
};

fn getField(args: ?std.json.Value, key: []const u8) ?std.json.Value {
    const a = args orelse return null;
    if (a != .object) return null;
    return a.object.get(key);
}
fn getStr(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const v = getField(args, key) orelse return null;
    return if (v == .string) v.string else null;
}
fn getF64(args: ?std.json.Value, key: []const u8) ?f64 {
    const v = getField(args, key) orelse return null;
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}
fn getU64(args: ?std.json.Value, key: []const u8) ?u64 {
    const v = getField(args, key) orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}
fn getBool(args: ?std.json.Value, key: []const u8) ?bool {
    const v = getField(args, key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn eqBandTypeName(t: model.EqBandType) []const u8 {
    return switch (t) {
        .peak => "peak",
        .low_shelf => "low_shelf",
        .high_shelf => "high_shelf",
        .highpass => "highpass",
    };
}

fn parseEqBandType(s: []const u8) ?model.EqBandType {
    if (std.mem.eql(u8, s, "peak")) return .peak;
    if (std.mem.eql(u8, s, "low_shelf")) return .low_shelf;
    if (std.mem.eql(u8, s, "high_shelf")) return .high_shelf;
    if (std.mem.eql(u8, s, "highpass") or std.mem.eql(u8, s, "high_pass") or std.mem.eql(u8, s, "hpf")) return .highpass;
    return null;
}

/// Inverse of `@intFromEnum(EqBandType)` -- decodes the ordinal an offline
/// assess job stashed in `apply_value` (a plain f32 field, no room for a real
/// enum) back into a band type when replaying a committed EQ change onto the
/// live project. Matches declaration order: peak=0, low_shelf=1, high_shelf=2,
/// highpass=3 (anything else falls back to highpass rather than trusting an
/// out-of-range ordinal).
fn eqBandTypeFromOrdinal(v: u8) model.EqBandType {
    return switch (v) {
        0 => .peak,
        1 => .low_shelf,
        2 => .high_shelf,
        else => .highpass,
    };
}

fn maxEqFrequencyHz(sample_rate: u32) f32 {
    return @min(22000.0, @as(f32, @floatFromInt(sample_rate)) * 0.49);
}

fn validateEqFrequency(freq: f32, sample_rate: u32) bool {
    return freq >= 10.0 and freq <= maxEqFrequencyHz(sample_rate);
}

fn validateEqGain(gain_db: f32) bool {
    return gain_db >= -24.0 and gain_db <= 24.0;
}

fn validateEqQ(q: f32) bool {
    return q >= 0.1 and q <= 18.0;
}

/// Parse one EQ band from JSON object. Accepts `frequency_hz` or legacy `freq`.
/// Highpass with non-zero gain → error.HighpassGainForbidden.
fn parseEqBandObject(obj: ?std.json.Value, sample_rate: u32) error{
    MissingBandFreq,
    InvalidBandType,
    FrequencyOutOfRange,
    GainOutOfRange,
    QOutOfRange,
    HighpassGainForbidden,
}!model.EqBand {
    const band_type = if (getStr(obj, "band_type")) |s|
        parseEqBandType(s) orelse return error.InvalidBandType
    else
        model.EqBandType.peak;
    const freq_f64 = getF64(obj, "frequency_hz") orelse getF64(obj, "freq") orelse return error.MissingBandFreq;
    const freq: f32 = @floatCast(freq_f64);
    if (!validateEqFrequency(freq, sample_rate)) return error.FrequencyOutOfRange;
    const gain: f32 = @floatCast(getF64(obj, "gain_db") orelse 0.0);
    if (!validateEqGain(gain)) return error.GainOutOfRange;
    if (band_type == .highpass and gain != 0.0) return error.HighpassGainForbidden;
    const q: f32 = @floatCast(getF64(obj, "q") orelse 0.707);
    if (!validateEqQ(q)) return error.QOutOfRange;
    const bypass = getBool(obj, "bypass") orelse false;
    return .{
        .band_type = band_type,
        .frequency_hz = freq,
        .gain_db = if (band_type == .highpass) 0.0 else gain,
        .q = q,
        .bypass = bypass,
    };
}

fn eqParseErrName(e: anyerror) []const u8 {
    return switch (e) {
        error.MissingBandFreq => "missing_band_freq",
        error.InvalidBandType => "invalid_band_type",
        error.FrequencyOutOfRange => "frequency_out_of_range",
        error.GainOutOfRange => "gain_out_of_range",
        error.QOutOfRange => "q_out_of_range",
        error.HighpassGainForbidden => "highpass_gain_forbidden",
        else => "eq_parse_failed",
    };
}

fn meanSelectedBands(energy: *const [SPECTRAL_BAND_COUNT]f32, indices: []const usize) f32 {
    var s: f32 = 0;
    for (indices) |i| s += energy.*[i];
    return s / @as(f32, @floatFromInt(indices.len));
}

fn lowBandEnergy(energy: *const [SPECTRAL_BAND_COUNT]f32) f32 {
    return meanSelectedBands(energy, &.{ 0, 1 }); // 62.5, 125
}
fn midBandEnergy(energy: *const [SPECTRAL_BAND_COUNT]f32) f32 {
    return meanSelectedBands(energy, &.{ 3, 4, 5 }); // 500, 1k, 2k
}
fn highBandEnergy(energy: *const [SPECTRAL_BAND_COUNT]f32) f32 {
    return meanSelectedBands(energy, &.{ 6, 7 }); // 4k, 8k
}

fn errResp(buf: []u8, id: i64, msg: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"id\":{d},\"ok\":false,\"error\":\"{s}\"}}", .{ id, msg }) catch "{\"ok\":false}";
}
/// Every tracked-command response carries the same causality envelope: which
/// operation this was, what revision existed right before it ran, what
/// revision exists now, and which audio frame was playing when it ran --
/// enough for a caller to line up a `measure` before and after a change with
/// the exact command that caused the difference.
fn okResp(buf: []u8, id: i64, op_id: u64, revision_before: u64, revision_after: u64, applied_at_audio_frame: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d}}}", .{ id, revision_after, op_id, revision_before, applied_at_audio_frame }) catch "{\"ok\":true}";
}

const MUTATING_COMMANDS = [_][]const u8{ "add_track", "remove_track", "set_track_param", "set_tempo", "transport", "import_audio", "set_effect_param", "set_master_param", "new_project", "insert_effect", "add_bus", "remove_bus", "set_bus_param", "add_send", "remove_send", "set_send_param", "sidechain_assess_and_adjust", "eq_assess_and_adjust", "compressor_assess_and_adjust", "bus_compressor_assess_and_adjust", "master_compressor_assess_and_adjust", "master_limiter_assess_and_adjust", "stereo_width_assess_and_adjust", "lead_vocal_balance_assess", "resolve_trial", "confirm_trial", "reject_trial", "abort_trial" };
const TRACKED_COMMANDS = MUTATING_COMMANDS ++ [_][]const u8{ "undo", "redo", "save", "load", "measure", "audition", "begin_trial", "get_routing_state", "reset_audio_diag", "analyze_master_program", "validate_master_delivery", "mix_session_preflight", "analyze_mix_sections", "analyze_wav_file", "compare_program_stereo", "get_audio_config", "set_audio_config" };
const MIX_GATED_COMMANDS = [_][]const u8{ "sidechain_assess_and_adjust", "eq_assess_and_adjust", "compressor_assess_and_adjust", "bus_compressor_assess_and_adjust", "master_compressor_assess_and_adjust", "master_limiter_assess_and_adjust", "stereo_width_assess_and_adjust", "lead_vocal_balance_assess" };

fn requireMixGate(ctx: *DispatchCtx, cmd: []const u8) ?[]const u8 {
    for (MIX_GATED_COMMANDS) |g| {
        if (std.mem.eql(u8, g, cmd)) return ctx.mix_gate.requirePassed(ctx.project.revision);
    }
    return null;
}

fn heavyBlockedWhileRecording(ctx: *DispatchCtx) bool {
    // count_in is the armed-record approach — same stall risk as record.
    return ctx.transport.* == .record or ctx.transport.* == .count_in;
}

fn preferOfflineAsync(ctx: *const DispatchCtx) bool {
    return ctx.transport.* == .play;
}

pub const SignalPoint = enum { track_post_fx, bus_pre_fx, bus_post_fx, master_pre_fx, master_post_fx, master_output };
pub const BusSignalPoint = enum { bus_pre_fx, bus_post_fx };
pub const MasterSignalPoint = enum { master_pre_fx, master_post_fx, master_output };

pub const MeasureTarget = union(enum) {
    master: MasterSignalPoint,
    track: model.TrackId,
    bus: struct { bus_id: model.BusId, signal_point: BusSignalPoint = .bus_post_fx },
};

/// Rough octave-spaced analysis bins for EQ observe (not R128 / not a full FFT).
pub const SPECTRAL_BAND_COUNT: usize = 8;
pub const SPECTRAL_BAND_HZ: [SPECTRAL_BAND_COUNT]f32 = .{ 62.5, 125, 250, 500, 1000, 2000, 4000, 8000 };

pub const RangeStats = struct {
    window_start_frame: u64 = 0,
    window_length_frames: u64 = 0,
    preroll_frames: u64 = 0,
    peak_dbfs: f32 = -120,
    rms_dbfs: f32 = -120,
    sum_sq: f64 = 0,
    n: u64 = 0,
    // Peak (not mean) GR/detector over the window: sidechain sources are
    // transient (kick/snare hits), so averaging across a window that's
    // mostly silence between hits would wash out the compression event
    // that actually matters -- a GR meter is read at its peak deflection.
    // Named _peak_db explicitly (not gain_reduction_db) so a future
    // mean/percentile-over-active-samples field can't collide with this one
    // or be confused for it.
    gr_db_seen: bool = false,
    det_db_seen: bool = false,
    gain_reduction_peak_db: ?f32 = null,
    detector_peak_db: ?f32 = null,
    /// Goertzel energy per SPECTRAL_BAND_HZ, dB relative to full-scale sinusoid
    /// over the same window length (rough spectral observe for EQ workflows).
    band_energy_db: [SPECTRAL_BAND_COUNT]f32 = [_]f32{-120} ** SPECTRAL_BAND_COUNT,
    // Track-compressor window stats (null when no compressor observed on target).
    comp_seen: bool = false,
    active_gr_threshold_db: f32 = 0.1,
    comp_gr_peak_db: ?f32 = null,
    comp_gr_mean_active_db: ?f32 = null,
    comp_gr_p50_active_db: ?f32 = null,
    comp_gr_p95_active_db: ?f32 = null,
    comp_active_sample_ratio: ?f32 = null,
    comp_input_peak_dbfs: ?f32 = null,
    comp_input_rms_dbfs: ?f32 = null,
    comp_output_peak_dbfs: ?f32 = null,
    comp_output_rms_dbfs: ?f32 = null,
    crest_factor_before_db: ?f32 = null,
    crest_factor_after_db: ?f32 = null,
    signal_point: SignalPoint = .master_output,
    // Loudness / true-peak (null when analysis not run or inapplicable).
    sample_peak_dbfs: ?f32 = null,
    true_peak_dbtp: ?f32 = null,
    true_peak_oversample_factor: u32 = 4,
    momentary_lufs: ?f32 = null,
    short_term_lufs: ?f32 = null,
    integrated_lufs: ?f32 = null,
    window_loudness_lufs: ?f32 = null,
    lra_lu: ?f32 = null,
    lra_null_reason: ?[]const u8 = null,
    loudness_gated: bool = true,
    loudness_scope: loudness.AnalysisScope = .measure_window,
    clipped_samples: u64 = 0,
    // Stereo / M-S (filled when capture buffer available).
    mid_rms_dbfs: ?f32 = null,
    side_rms_dbfs: ?f32 = null,
    side_to_mid_db: ?f32 = null,
    correlation_mean: ?f32 = null,
    correlation_min: ?f32 = null,
    correlation_p05: ?f32 = null,
    mono_sum_peak_dbfs: ?f32 = null,
    mono_sum_rms_dbfs: ?f32 = null,
    mono_loss_db: ?f32 = null,
    anti_phase_sample_ratio: ?f32 = null,
    stereo: ?stereo_analysis.StereoResult = null,
};

const Goertzel = struct {
    coeff: f64,
    s1: f64 = 0,
    s2: f64 = 0,

    fn init(freq_hz: f32, sample_rate: f32) Goertzel {
        const w = 2.0 * std.math.pi * @as(f64, freq_hz) / @as(f64, sample_rate);
        return .{ .coeff = 2.0 * @cos(w) };
    }

    fn push(self: *Goertzel, x: f32) void {
        const s0 = @as(f64, x) + self.coeff * self.s1 - self.s2;
        self.s2 = self.s1;
        self.s1 = s0;
    }

    fn magnitudeSq(self: *const Goertzel) f64 {
        return self.s1 * self.s1 + self.s2 * self.s2 - self.coeff * self.s1 * self.s2;
    }
};

fn parseMasterSignalPoint(s: []const u8) !MasterSignalPoint {
    if (std.mem.eql(u8, s, "master_pre_fx")) return .master_pre_fx;
    if (std.mem.eql(u8, s, "master_post_fx")) return .master_post_fx;
    if (std.mem.eql(u8, s, "master_output") or std.mem.eql(u8, s, "master_sum")) return .master_output;
    return error.BadSignalPoint;
}

fn parseMeasureTarget(args: ?std.json.Value) !MeasureTarget {
    var default_master_sp: MasterSignalPoint = .master_output;
    if (getStr(args, "signal_point")) |s| {
        default_master_sp = parseMasterSignalPoint(s) catch default_master_sp;
    }
    if (getField(args, "target")) |tv| {
        if (tv == .object) {
            const kind = getStr(tv, "kind") orelse return error.MissingKind;
            if (std.mem.eql(u8, kind, "master")) {
                var sp = default_master_sp;
                if (getStr(tv, "signal_point")) |s| sp = try parseMasterSignalPoint(s);
                return .{ .master = sp };
            }
            if (std.mem.eql(u8, kind, "track")) {
                const tid = getU64(tv, "track_id") orelse return error.MissingTrackId;
                return .{ .track = tid };
            }
            if (std.mem.eql(u8, kind, "bus")) {
                const bid = getU64(tv, "bus_id") orelse return error.MissingBusId;
                var sp: BusSignalPoint = .bus_post_fx;
                if (getStr(tv, "signal_point")) |s| {
                    if (std.mem.eql(u8, s, "bus_pre_fx")) {
                        sp = .bus_pre_fx;
                    } else if (std.mem.eql(u8, s, "bus_post_fx")) {
                        sp = .bus_post_fx;
                    } else return error.BadSignalPoint;
                }
                return .{ .bus = .{ .bus_id = bid, .signal_point = sp } };
            }
            return error.BadKind;
        }
        if (tv == .string) {
            if (std.mem.eql(u8, tv.string, "master")) return .{ .master = default_master_sp };
        }
    }
    if (getU64(args, "track_id")) |tid| return .{ .track = tid };
    if (getU64(args, "bus_id")) |bid| {
        var sp: BusSignalPoint = .bus_post_fx;
        if (getStr(args, "signal_point")) |s| {
            if (std.mem.eql(u8, s, "bus_pre_fx")) sp = .bus_pre_fx;
        }
        return .{ .bus = .{ .bus_id = bid, .signal_point = sp } };
    }
    return .{ .master = default_master_sp };
}

fn measureTargetKindStr(t: MeasureTarget) []const u8 {
    return switch (t) {
        .master => "master",
        .track => "track",
        .bus => "bus",
    };
}

fn measureTargetId(t: MeasureTarget) u64 {
    return switch (t) {
        .master => 0,
        .track => |id| id,
        .bus => |b| b.bus_id,
    };
}

fn measureErrStr(e: anyerror) []const u8 {
    return switch (e) {
        error.TrackNotFound => "track_not_found",
        error.BusNotFound => "bus_not_found",
        else => "measure_failed",
    };
}

pub fn nearestSpectralBandIndex(freq_hz: f32) usize {
    var best: usize = 0;
    var best_dist: f32 = @abs(@log2(@max(freq_hz, 1.0) / SPECTRAL_BAND_HZ[0]));
    for (SPECTRAL_BAND_HZ, 0..) |hz, i| {
        const d = @abs(@log2(@max(freq_hz, 1.0) / hz));
        if (d < best_dist) {
            best_dist = d;
            best = i;
        }
    }
    return best;
}

/// Deterministically re-derives what frames [start_frame, start_frame+length_frames)
/// sound like for `target` (a single track's own post-FX contribution, or the
/// master bus), independent of realtime playback state -- the same
/// (start_frame, length_frames, target) always produces the same numbers.
///
/// A fresh SidechainRuntime / EqRuntime / CompressorRuntime is driven from a
/// short preroll before start_frame so envelopes aren't reported at cold-start.
/// Not bit-equivalent to full playback-from-project-start (documented).
pub fn measureRange(
    gpa: std.mem.Allocator,
    project: *const model.Project,
    asset_cache: *const mixer.AssetCache,
    target: MeasureTarget,
    start_frame: u64,
    length_frames: u64,
    sample_rate: u32,
    samples_out: ?[]f32,
    fx_bypass_all: bool,
) !RangeStats {
    return measureRangeObserving(gpa, project, asset_cache, target, start_frame, length_frames, sample_rate, samples_out, null, fx_bypass_all);
}

/// Like measureRange; when `observe_compressor_id` is set (or the track has a
/// compressor), fills compressor active-GR / I/O window statistics.
pub fn measureRangeObserving(
    gpa: std.mem.Allocator,
    project: *const model.Project,
    asset_cache: *const mixer.AssetCache,
    target: MeasureTarget,
    start_frame: u64,
    length_frames: u64,
    sample_rate: u32,
    samples_out: ?[]f32,
    observe_compressor_id: ?model.EffectId,
    fx_bypass_all: bool,
) !RangeStats {
    var sc_rt = mixer.SidechainRuntime.init(gpa);
    defer sc_rt.deinit();
    var eq_rt = mixer.EqRuntime.init(gpa);
    defer eq_rt.deinit();
    var comp_rt = mixer.CompressorRuntime.init(gpa);
    defer comp_rt.deinit();
    var delay_rt = mixer.DelayRuntime.init(gpa);
    defer delay_rt.deinit();
    var lim_rt = mixer.LimiterRuntime.init(gpa);
    defer lim_rt.deinit();
    var width_rt = mixer.StereoWidthRuntime.init(gpa);
    defer width_rt.deinit();

    var preroll_frames: u64 = 0;
    var sidechain_effect_id: ?model.EffectId = null;
    var compressor_effect_id: ?model.EffectId = observe_compressor_id;
    var target_ti: ?usize = null;
    var target_bi: ?usize = null;
    var bus_signal_point: SignalPoint = .master_output;
    const eq_preroll: u64 = @max(@as(u64, sample_rate) / 50, 256);

    switch (target) {
        .master => |msp| {
            bus_signal_point = switch (msp) {
                .master_pre_fx => .master_pre_fx,
                .master_post_fx => .master_post_fx,
                .master_output => .master_output,
            };
            for (project.master_effects.items) |eff| {
                switch (eff.params) {
                    .compressor => |p| {
                        if (compressor_effect_id == null) compressor_effect_id = eff.id;
                        const pf: u64 = @intFromFloat(@max(p.release_ms * 5.0, 250.0) / 1000.0 * @as(f64, @floatFromInt(sample_rate)));
                        preroll_frames = @max(preroll_frames, pf);
                    },
                    .limiter => |p| {
                        if (compressor_effect_id == null) compressor_effect_id = eff.id;
                        const pf: u64 = @intFromFloat(@max(p.release_ms * 5.0 + p.lookahead_ms, 250.0) / 1000.0 * @as(f64, @floatFromInt(sample_rate)));
                        preroll_frames = @max(preroll_frames, pf);
                    },
                    .delay => |p| {
                        const pf: u64 = @intFromFloat(@max(p.time_ms * 2.0, 250.0) / 1000.0 * @as(f64, @floatFromInt(sample_rate)));
                        preroll_frames = @max(preroll_frames, pf);
                    },
                    .eq => |eq| {
                        if (eq.bands.items.len > 0) preroll_frames = @max(preroll_frames, eq_preroll);
                    },
                    else => {},
                }
            }
        },
        .track => |tid| {
            bus_signal_point = .track_post_fx;
            for (project.tracks.items, 0..) |t, ti| {
                if (t.id != tid) continue;
                target_ti = ti;
                for (t.effects.items) |eff| {
                    switch (eff.params) {
                        .sidechain_compressor => |p| {
                            sidechain_effect_id = eff.id;
                            const pf: u64 = @intFromFloat(@max(p.release_ms * 5.0, 250.0) / 1000.0 * @as(f64, @floatFromInt(sample_rate)));
                            preroll_frames = @max(preroll_frames, pf);
                        },
                        .compressor => |p| {
                            if (compressor_effect_id == null) compressor_effect_id = eff.id;
                            const pf: u64 = @intFromFloat(@max(p.release_ms * 5.0, 250.0) / 1000.0 * @as(f64, @floatFromInt(sample_rate)));
                            preroll_frames = @max(preroll_frames, pf);
                        },
                        .eq => |eq| {
                            if (eq.bands.items.len > 0) preroll_frames = @max(preroll_frames, eq_preroll);
                        },
                        .delay => |p| {
                            const pf: u64 = @intFromFloat(@max(p.time_ms * 2.0, 250.0) / 1000.0 * @as(f64, @floatFromInt(sample_rate)));
                            preroll_frames = @max(preroll_frames, pf);
                        },
                        else => {},
                    }
                }
                break;
            }
            if (target_ti == null) return error.TrackNotFound;
        },
        .bus => |bt| {
            bus_signal_point = if (bt.signal_point == .bus_pre_fx) .bus_pre_fx else .bus_post_fx;
            for (project.buses.items, 0..) |b, bi| {
                if (b.id != bt.bus_id) continue;
                target_bi = bi;
                for (b.effects.items) |eff| {
                    switch (eff.params) {
                        .compressor => |p| {
                            if (compressor_effect_id == null) compressor_effect_id = eff.id;
                            const pf: u64 = @intFromFloat(@max(p.release_ms * 5.0, 250.0) / 1000.0 * @as(f64, @floatFromInt(sample_rate)));
                            preroll_frames = @max(preroll_frames, pf);
                        },
                        .delay => |p| {
                            const pf: u64 = @intFromFloat(@max(p.time_ms * 2.0, 250.0) / 1000.0 * @as(f64, @floatFromInt(sample_rate)));
                            preroll_frames = @max(preroll_frames, pf);
                        },
                        .eq => |eq| {
                            if (eq.bands.items.len > 0) preroll_frames = @max(preroll_frames, eq_preroll);
                        },
                        else => {},
                    }
                }
                break;
            }
            if (target_bi == null) return error.BusNotFound;
        },
    }

    const pre_start = start_frame -| preroll_frames;
    const end_frame = start_frame + length_frames;

    var voice_pool: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;
    var track_levels: [64]mixer.TrackLevel = [_]mixer.TrackLevel{.{}} ** 64;
    const tl_slice = track_levels[0..@min(64, project.tracks.items.len)];
    var bus_levels: [32]mixer.BusLevel = [_]mixer.BusLevel{.{}} ** 32;
    const bl_slice = bus_levels[0..@min(32, project.buses.items.len)];
    var master_lvl: mixer.MasterLevel = .{};

    var stats: RangeStats = .{
        .window_start_frame = start_frame,
        .window_length_frames = length_frames,
        .preroll_frames = start_frame - pre_start,
        .active_gr_threshold_db = mixer.ACTIVE_GR_THRESHOLD_DB,
        .signal_point = bus_signal_point,
    };
    var goertzel: [SPECTRAL_BAND_COUNT]Goertzel = undefined;
    for (&goertzel, SPECTRAL_BAND_HZ) |*g, hz| {
        g.* = Goertzel.init(hz, @floatFromInt(if (sample_rate == 0) 44100 else sample_rate));
    }

    var active_gr: std.ArrayList(f32) = .empty;
    defer active_gr.deinit(gpa);
    var in_sum_sq: f64 = 0;
    var out_sum_sq: f64 = 0;
    var in_n: u64 = 0;
    var comp_samples: u64 = 0;

    const need_loud_buf = samples_out == null;
    const loud_owned: ?[]f32 = if (need_loud_buf) try gpa.alloc(f32, length_frames * 2) else null;
    defer if (loud_owned) |b| gpa.free(b);
    const capture_buf: ?[]f32 = samples_out orelse loud_owned;

    var frame = pre_start;
    while (frame < end_frame) : (frame += 1) {
        var l: f32 = 0;
        var r: f32 = 0;
        mixer.mixSample(project, &voice_pool, asset_cache, frame, frame, .{}, &sc_rt, &eq_rt, &comp_rt, &delay_rt, &lim_rt, &width_rt, sample_rate, &l, &r, tl_slice, bl_slice, &master_lvl, fx_bypass_all);

        if (frame >= start_frame) {
            const out_idx = frame - start_frame;
            var vl = l;
            var vr = r;
            if (target_ti) |ti| {
                vl = tl_slice[ti].l;
                vr = tl_slice[ti].r;
            } else if (target_bi) |bi| {
                if (bi < bl_slice.len) {
                    if (bus_signal_point == .bus_pre_fx) {
                        vl = bl_slice[bi].in_l;
                        vr = bl_slice[bi].in_r;
                    } else {
                        vl = bl_slice[bi].post_fx_l;
                        vr = bl_slice[bi].post_fx_r;
                    }
                }
            } else {
                switch (bus_signal_point) {
                    .master_pre_fx => {
                        vl = master_lvl.pre_l;
                        vr = master_lvl.pre_r;
                    },
                    .master_post_fx => {
                        vl = master_lvl.post_l;
                        vr = master_lvl.post_r;
                    },
                    .master_output => {
                        vl = master_lvl.out_l;
                        vr = master_lvl.out_r;
                    },
                    else => {},
                }
            }
            if (capture_buf) |so| {
                const bi = out_idx * 2;
                if (bi + 1 < so.len) {
                    so[bi + 0] = vl;
                    so[bi + 1] = vr;
                }
            }
            const peak = @max(@abs(vl), @abs(vr));
            stats.peak_dbfs = @max(stats.peak_dbfs, mixer.linearToDb(peak));
            stats.sum_sq += (@as(f64, vl) * @as(f64, vl) + @as(f64, vr) * @as(f64, vr)) * 0.5;
            stats.n += 1;
            const mid = 0.5 * (vl + vr);
            for (&goertzel) |*g| g.push(mid);

            if (sidechain_effect_id) |eid| {
                if (sc_rt.gainReductionDb(eid)) |gr| {
                    stats.gain_reduction_peak_db = @max(stats.gain_reduction_peak_db orelse 0, gr);
                    stats.gr_db_seen = true;
                }
                if (sc_rt.detectorLevelDb(eid)) |d| {
                    stats.detector_peak_db = @max(stats.detector_peak_db orelse -120, d);
                    stats.det_db_seen = true;
                }
            }

            if (compressor_effect_id) |eid| {
                if (comp_rt.gainReductionDb(eid)) |gr| {
                    stats.comp_gr_peak_db = @max(stats.comp_gr_peak_db orelse 0, gr);
                    stats.comp_seen = true;
                    comp_samples += 1;
                    if (gr > mixer.ACTIVE_GR_THRESHOLD_DB) {
                        active_gr.append(gpa, gr) catch {};
                    }
                } else if (lim_rt.gainReductionDb(eid)) |gr| {
                    stats.comp_gr_peak_db = @max(stats.comp_gr_peak_db orelse 0, gr);
                    stats.comp_seen = true;
                    comp_samples += 1;
                    if (gr > mixer.ACTIVE_GR_THRESHOLD_DB) {
                        active_gr.append(gpa, gr) catch {};
                    }
                }
                if (comp_rt.inputPeak(eid)) |ip| {
                    stats.comp_input_peak_dbfs = @max(stats.comp_input_peak_dbfs orelse -120, mixer.linearToDb(ip));
                    in_sum_sq += @as(f64, ip) * @as(f64, ip);
                    in_n += 1;
                }
                if (comp_rt.outputPeak(eid)) |op| {
                    stats.comp_output_peak_dbfs = @max(stats.comp_output_peak_dbfs orelse -120, mixer.linearToDb(op));
                    out_sum_sq += @as(f64, op) * @as(f64, op);
                }
            }
        }
    }

    if (stats.n > 0) {
        stats.rms_dbfs = @floatCast(10.0 * std.math.log10(@max(stats.sum_sq / @as(f64, @floatFromInt(stats.n)), 1.0e-12)));
        const n2 = @as(f64, @floatFromInt(stats.n)) * @as(f64, @floatFromInt(stats.n));
        for (&stats.band_energy_db, goertzel) |*out_db, g| {
            const mag2 = @max(g.magnitudeSq() / n2, 1.0e-24);
            out_db.* = @floatCast(10.0 * std.math.log10(mag2));
        }
    }
    if (!stats.gr_db_seen) stats.gain_reduction_peak_db = null;
    if (!stats.det_db_seen) stats.detector_peak_db = null;

    if (stats.comp_seen) {
        if (comp_samples > 0) {
            stats.comp_active_sample_ratio = @as(f32, @floatFromInt(active_gr.items.len)) / @as(f32, @floatFromInt(comp_samples));
        }
        if (active_gr.items.len > 0) {
            std.mem.sort(f32, active_gr.items, {}, std.sort.asc(f32));
            var sum: f64 = 0;
            for (active_gr.items) |g| sum += g;
            stats.comp_gr_mean_active_db = @floatCast(sum / @as(f64, @floatFromInt(active_gr.items.len)));
            stats.comp_gr_p50_active_db = active_gr.items[active_gr.items.len / 2];
            const p95_i = @min(active_gr.items.len - 1, (active_gr.items.len * 95) / 100);
            stats.comp_gr_p95_active_db = active_gr.items[p95_i];
        } else {
            stats.comp_gr_mean_active_db = 0;
            stats.comp_gr_p50_active_db = 0;
            stats.comp_gr_p95_active_db = 0;
        }
        if (in_n > 0) {
            stats.comp_input_rms_dbfs = @floatCast(10.0 * std.math.log10(@max(in_sum_sq / @as(f64, @floatFromInt(in_n)), 1.0e-12)));
            stats.comp_output_rms_dbfs = @floatCast(10.0 * std.math.log10(@max(out_sum_sq / @as(f64, @floatFromInt(in_n)), 1.0e-12)));
        }
        if (stats.comp_input_peak_dbfs) |ip| {
            if (stats.comp_input_rms_dbfs) |ir| stats.crest_factor_before_db = ip - ir;
        }
        if (stats.comp_output_peak_dbfs) |op| {
            if (stats.comp_output_rms_dbfs) |orms| stats.crest_factor_after_db = op - orms;
        }
    } else {
        stats.comp_gr_peak_db = null;
        stats.comp_input_peak_dbfs = null;
        stats.comp_output_peak_dbfs = null;
        stats.comp_input_rms_dbfs = null;
        stats.comp_output_rms_dbfs = null;
        stats.crest_factor_before_db = null;
        stats.crest_factor_after_db = null;
        stats.comp_gr_mean_active_db = null;
        stats.comp_gr_p50_active_db = null;
        stats.comp_gr_p95_active_db = null;
        stats.comp_active_sample_ratio = null;
    }

    if (capture_buf) |buf| {
        const lr = loudness.analyzeStereo(buf[0 .. length_frames * 2], sample_rate, .measure_window);
        stats.sample_peak_dbfs = lr.sample_peak_dbfs;
        stats.true_peak_dbtp = lr.true_peak_dbtp;
        stats.true_peak_oversample_factor = lr.true_peak_oversample_factor;
        stats.momentary_lufs = lr.momentary_lufs;
        stats.short_term_lufs = lr.short_term_lufs;
        stats.integrated_lufs = lr.integrated_lufs;
        stats.window_loudness_lufs = lr.window_loudness_lufs;
        stats.lra_lu = lr.lra_lu;
        stats.lra_null_reason = lr.lra_null_reason;
        stats.loudness_gated = lr.gated;
        stats.loudness_scope = lr.analysis_scope;
        stats.clipped_samples = lr.clipped_samples;
        const st = stereo_analysis.analyzeStereo(buf[0 .. length_frames * 2], sample_rate);
        stats.mid_rms_dbfs = st.mid_rms_dbfs;
        stats.side_rms_dbfs = st.side_rms_dbfs;
        stats.side_to_mid_db = st.side_to_mid_db;
        stats.correlation_mean = st.correlation_mean;
        stats.correlation_min = st.correlation_min;
        stats.correlation_p05 = st.correlation_p05;
        stats.mono_sum_peak_dbfs = st.mono_sum_peak_dbfs;
        stats.mono_sum_rms_dbfs = st.mono_sum_rms_dbfs;
        stats.mono_loss_db = st.mono_loss_db;
        stats.anti_phase_sample_ratio = st.anti_phase_sample_ratio;
        stats.stereo = st;
    }
    return stats;
}

/// Writes the `gain_reduction_peak_db`/`detector_peak_db`/`state_initialization`
/// tail shared by `measure` and `audition` responses. Caller has already
/// written the opening `"gain_reduction_peak_db":` key.
///
/// `state_initialization` makes the preroll approximation part of the
/// contract instead of an undocumented implementation detail: the envelope
/// follower is warmed up from `preroll_frames` samples before the window, not
/// replayed from the actual project start, so before/after comparisons of the
/// SAME window are self-consistent but this is not bit-equivalent to what a
/// full playback-from-start would show for effects with long memory
/// (long release times, feedback delay/reverb, automation earlier in the
/// song).
fn writeRangeStatsTail(w: *std.Io.Writer, stats: RangeStats) void {
    if (stats.gain_reduction_peak_db) |gr| w.print("{d:.2}", .{gr}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"detector_peak_db\":") catch {};
    if (stats.detector_peak_db) |d| w.print("{d:.2}", .{d}) catch {} else w.writeAll("null") catch {};
    w.print(",\"state_initialization\":{{\"mode\":\"preroll\",\"preroll_frames\":{d},\"exact_from_project_start\":false}}", .{stats.preroll_frames}) catch {};
    w.writeAll(",\"band_hz\":[") catch {};
    for (SPECTRAL_BAND_HZ, 0..) |hz, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{d}", .{hz}) catch {};
    }
    w.writeAll("],\"band_energy_db\":[") catch {};
    for (stats.band_energy_db, 0..) |e, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{d:.2}", .{e}) catch {};
    }
    w.print("],\"low_band_energy_db\":{d:.2},\"mid_band_energy_db\":{d:.2},\"high_band_energy_db\":{d:.2},\"signal_path\":\"post_implemented_realtime_dsp\"", .{
        lowBandEnergy(&stats.band_energy_db),
        midBandEnergy(&stats.band_energy_db),
        highBandEnergy(&stats.band_energy_db),
    }) catch {};
    w.print(",\"signal_point\":\"{s}\"", .{switch (stats.signal_point) {
        .track_post_fx => "track_post_fx",
        .bus_pre_fx => "bus_pre_fx",
        .bus_post_fx => "bus_post_fx",
        .master_pre_fx => "master_pre_fx",
        .master_post_fx => "master_post_fx",
        .master_output => "master_output",
    }}) catch {};
    w.print(",\"active_gr_threshold_db\":{d:.2}", .{stats.active_gr_threshold_db}) catch {};
    w.writeAll(",\"compressor\":{") catch {};
    if (stats.comp_seen) {
        w.print("\"gain_reduction_peak_db\":{d:.2}", .{stats.comp_gr_peak_db orelse 0}) catch {};
        w.print(",\"gain_reduction_mean_active_db\":{d:.2}", .{stats.comp_gr_mean_active_db orelse 0}) catch {};
        w.print(",\"gain_reduction_p50_active_db\":{d:.2}", .{stats.comp_gr_p50_active_db orelse 0}) catch {};
        w.print(",\"gain_reduction_p95_active_db\":{d:.2}", .{stats.comp_gr_p95_active_db orelse 0}) catch {};
        w.print(",\"active_sample_ratio\":{d:.4}", .{stats.comp_active_sample_ratio orelse 0}) catch {};
        w.print(",\"input_peak_dbfs\":{d:.2}", .{stats.comp_input_peak_dbfs orelse -120}) catch {};
        w.print(",\"input_rms_dbfs\":{d:.2}", .{stats.comp_input_rms_dbfs orelse -120}) catch {};
        w.print(",\"output_peak_dbfs\":{d:.2}", .{stats.comp_output_peak_dbfs orelse -120}) catch {};
        w.print(",\"output_rms_dbfs\":{d:.2}", .{stats.comp_output_rms_dbfs orelse -120}) catch {};
        w.print(",\"crest_factor_before_db\":{d:.2}", .{stats.crest_factor_before_db orelse 0}) catch {};
        w.print(",\"crest_factor_after_db\":{d:.2}", .{stats.crest_factor_after_db orelse 0}) catch {};
    } else {
        w.writeAll("\"present\":false") catch {};
    }
    w.writeAll("}") catch {};
    // Loudness / true-peak block
    w.writeAll(",\"loudness\":{") catch {};
    w.writeAll("\"standard\":\"ITU-R BS.1770-5 / EBU R128 (from-scratch)\",\"gated\":") catch {};
    w.print("{}", .{stats.loudness_gated}) catch {};
    w.print(",\"analysis_scope\":\"{s}\"", .{switch (stats.loudness_scope) {
        .measure_window => "measure_window",
        .full_program => "full_program",
    }}) catch {};
    w.writeAll(",\"integrated_lufs\":") catch {};
    if (stats.integrated_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"short_term_lufs\":") catch {};
    if (stats.short_term_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"momentary_lufs\":") catch {};
    if (stats.momentary_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"window_loudness_lufs\":") catch {};
    if (stats.window_loudness_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"lra_lu\":") catch {};
    if (stats.lra_lu) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"lra_null_reason\":") catch {};
    if (stats.lra_null_reason) |r| w.print("\"{s}\"", .{r}) catch {} else w.writeAll("null") catch {};
    w.writeAll("},\"sample_peak_dbfs\":") catch {};
    if (stats.sample_peak_dbfs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"true_peak_dbtp\":") catch {};
    if (stats.true_peak_dbtp) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.print(",\"true_peak_oversample_factor\":{d},\"true_peak_method\":\"{s}\",\"clipped_samples\":{d}", .{
        stats.true_peak_oversample_factor,
        loudness.true_peak_method,
        stats.clipped_samples,
    }) catch {};
    // Stereo / M-S observability
    w.writeAll(",\"mid_rms_dbfs\":") catch {};
    if (stats.mid_rms_dbfs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"side_rms_dbfs\":") catch {};
    if (stats.side_rms_dbfs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"side_to_mid_db\":") catch {};
    if (stats.side_to_mid_db) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"correlation_mean\":") catch {};
    if (stats.correlation_mean) |v| w.print("{d:.4}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"correlation_min\":") catch {};
    if (stats.correlation_min) |v| w.print("{d:.4}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"correlation_p05\":") catch {};
    if (stats.correlation_p05) |v| w.print("{d:.4}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"mono_sum_peak_dbfs\":") catch {};
    if (stats.mono_sum_peak_dbfs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"mono_sum_rms_dbfs\":") catch {};
    if (stats.mono_sum_rms_dbfs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"mono_loss_db\":") catch {};
    if (stats.mono_loss_db) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"anti_phase_sample_ratio\":") catch {};
    if (stats.anti_phase_sample_ratio) |v| w.print("{d:.4}", .{v}) catch {} else w.writeAll("null") catch {};
    if (stats.stereo) |st| {
        w.writeAll(",\"stereo\":{") catch {};
        w.print("\"narrowness_localization\":\"{s}\",\"bands\":[", .{st.narrowness_localization}) catch {};
        for (st.bands, 0..) |b, bi| {
            if (bi > 0) w.writeAll(",") catch {};
            w.print("{{\"name\":\"{s}\",\"mid_energy_db\":{d:.2},\"side_energy_db\":{d:.2},\"side_to_mid_db\":{d:.2}}}", .{
                b.name, b.mid_energy_db, b.side_energy_db, b.side_to_mid_db,
            }) catch {};
        }
        w.writeAll("]}") catch {};
    }
}

fn exportRangeWav(buf: []f32, length_frames: u64, sample_rate: u32, path_z: [:0]const u8) bool {
    const wave = c.Wave{
        .frameCount = @intCast(length_frames),
        .sampleRate = sample_rate,
        .sampleSize = 32,
        .channels = 2,
        .data = buf.ptr,
    };
    return c.ExportWave(wave, path_z.ptr);
}

const WavF32 = struct { samples: []f32, sample_rate: u32 };

/// Load wav as interleaved stereo f32 (mono duplicated). Uses raylib LoadWave.
fn loadWavInterleavedF32(gpa: std.mem.Allocator, path: []const u8) !WavF32 {
    var path_z_buf: [1024]u8 = undefined;
    if (path.len >= path_z_buf.len) return error.PathTooLong;
    @memcpy(path_z_buf[0..path.len], path);
    path_z_buf[path.len] = 0;
    const wave = c.LoadWave(&path_z_buf);
    defer c.UnloadWave(wave);
    if (wave.frameCount == 0 or wave.data == null) return error.WavLoadFailed;
    const frames: usize = @intCast(wave.frameCount);
    const ch: usize = @intCast(if (wave.channels == 0) 1 else wave.channels);
    const out = try gpa.alloc(f32, frames * 2);
    errdefer gpa.free(out);
    // Convert via LoadWaveSamples → f32
    const samples_ptr = c.LoadWaveSamples(wave);
    defer c.UnloadWaveSamples(samples_ptr);
    if (samples_ptr == null) return error.WavLoadFailed;
    const src: [*]f32 = @ptrCast(@alignCast(samples_ptr));
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        if (ch == 1) {
            const v = src[i];
            out[i * 2] = v;
            out[i * 2 + 1] = v;
        } else {
            out[i * 2] = src[i * ch];
            out[i * 2 + 1] = src[i * ch + 1];
        }
    }
    return .{ .samples = out, .sample_rate = wave.sampleRate };
}

fn getSidechainParam(p: model.SidechainParams, name: []const u8) ?f32 {
    if (std.mem.eql(u8, name, "threshold_db")) return p.threshold_db;
    if (std.mem.eql(u8, name, "ratio")) return p.ratio;
    if (std.mem.eql(u8, name, "attack_ms")) return p.attack_ms;
    if (std.mem.eql(u8, name, "release_ms")) return p.release_ms;
    return null;
}

fn setSidechainParam(p: *model.SidechainParams, name: []const u8, value: f32) bool {
    if (std.mem.eql(u8, name, "threshold_db")) {
        p.threshold_db = value;
        return true;
    }
    if (std.mem.eql(u8, name, "ratio")) {
        p.ratio = @max(value, 1.0);
        return true;
    }
    if (std.mem.eql(u8, name, "attack_ms")) {
        p.attack_ms = @max(value, 0.1);
        return true;
    }
    if (std.mem.eql(u8, name, "release_ms")) {
        p.release_ms = @max(value, 0.1);
        return true;
    }
    return false;
}

/// One bounded, complete audio-engineer workflow: fix a range, measure
/// baseline, change exactly ONE sidechain parameter, re-measure the SAME
/// range, create before/after auditions, check the result against explicit
/// technical constraints (target GR range, max RMS loss, no clipping), and
/// commit or roll back accordingly. This is the P0 proof that the
/// measure/audition/operation-envelope primitives compose into a real
/// engineer decision cycle, not just individually-callable building blocks.
///
/// Deliberately narrow: it only ever asserts a bounded technical outcome
/// ("GR landed in range without exceeding the RMS-loss limit"), never a
/// musical/perceptual judgment ("the mix sounds better") -- that would
/// require capabilities this project doesn't have yet (see
/// docs/P0_AUDIO_FEEDBACK_LOOP_EVIDENCE.md).
fn handleSidechainAssessAndAdjust(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const track_id = getU64(args, "track_id") orelse return errResp(response_buf, id, "missing_track_id");
    const effect_id = getU64(args, "effect_id") orelse return errResp(response_buf, id, "missing_effect_id");
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    const param = getStr(args, "param") orelse return errResp(response_buf, id, "missing_param");
    const new_value_f64 = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");

    const target_gr_min_db: f32 = @floatCast(getF64(args, "target_gr_min_db") orelse 3.0);
    const target_gr_max_db: f32 = @floatCast(getF64(args, "target_gr_max_db") orelse 6.0);
    const max_rms_loss_db: f32 = @floatCast(getF64(args, "max_rms_loss_db") orelse 3.0);
    const max_peak_dbfs: f32 = @floatCast(getF64(args, "max_peak_dbfs") orelse 0.0);

    const track = ctx.project.findTrack(track_id) orelse return errResp(response_buf, id, "track_not_found");
    const effect = for (track.effects.items) |*e| {
        if (e.id == effect_id) break e;
    } else return errResp(response_buf, id, "effect_not_found");
    if (effect.params != .sidechain_compressor) return errResp(response_buf, id, "effect_not_sidechain_compressor");
    const old_value = getSidechainParam(effect.params.sidechain_compressor, param) orelse return errResp(response_buf, id, "unknown_param");
    const new_value: f32 = @floatCast(new_value_f64);

    const target: MeasureTarget = .{ .track = track_id };

    // 1. Baseline -- measured (and auditioned) BEFORE anything changes.
    const before_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(before_buf);
    const before_stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, before_buf, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else "measure_failed");

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    var before_path_buf: [256]u8 = undefined;
    const before_path_z = std.fmt.bufPrintZ(&before_path_buf, ".cache/audition/{d}_before.wav", .{op_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_buf, length_frames, ctx.project.sample_rate, before_path_z)) return errResp(response_buf, id, "export_failed");

    // 2. Change exactly one parameter.
    if (!setSidechainParam(&effect.params.sidechain_compressor, param, new_value)) return errResp(response_buf, id, "unknown_param");
    ensureDryClipSources(ctx.project, track_id);
    ctx.project.revision += 1;
    ui.markDirty(ctx.view);

    // 3. Re-measure + audition the SAME range, post-change.
    const after_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(after_buf);
    const after_stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, after_buf, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else "measure_failed");
    var after_path_buf: [256]u8 = undefined;
    const after_path_z = std.fmt.bufPrintZ(&after_path_buf, ".cache/audition/{d}_after.wav", .{op_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_buf, length_frames, ctx.project.sample_rate, after_path_z)) return errResp(response_buf, id, "export_failed");

    // 4. Check bounded technical constraints, never a musical judgment.
    const gr_after = after_stats.gain_reduction_peak_db orelse 0.0;
    const gr_ok = gr_after >= target_gr_min_db and gr_after <= target_gr_max_db;
    const rms_delta = before_stats.rms_dbfs - after_stats.rms_dbfs; // positive = got quieter
    const rms_ok = rms_delta <= max_rms_loss_db;
    const clip_ok = after_stats.peak_dbfs <= max_peak_dbfs;
    const committed = gr_ok and rms_ok and clip_ok;

    // 5. Commit (leave the change in place) or roll back by reverting this
    // ONE parameter directly. Self-contained on purpose -- this handler also
    // runs from the offline worker thread (see enqueueOfflineAssess), which
    // calls it directly and never goes through handleCommand's MUTATING_COMMANDS
    // preamble, so a `ctx.history.undo()`-based rollback would silently find
    // nothing to undo there.
    if (!committed) {
        _ = setSidechainParam(&effect.params.sidechain_compressor, param, old_value);
        ensureDryClipSources(ctx.project, track_id);
        ctx.project.revision += 1;
        ui.markDirty(ctx.view);
    }

    var reason_buf: [512]u8 = undefined;
    var reason_w: std.Io.Writer = .fixed(&reason_buf);
    if (committed) {
        reason_w.print("gain_reduction_peak_db={d:.2}dB is within the target range [{d:.2},{d:.2}]dB; rms_dbfs moved by {d:.2}dB (limit {d:.2}dB); peak_dbfs={d:.2}dBFS (limit {d:.2}dBFS). This confirms the sidechain compressor's measured technical behavior on this range only -- not a claim about musical quality.", .{ gr_after, target_gr_min_db, target_gr_max_db, rms_delta, max_rms_loss_db, after_stats.peak_dbfs, max_peak_dbfs }) catch {};
    } else {
        reason_w.writeAll("rolled back: ") catch {};
        if (!gr_ok) reason_w.print("gain_reduction_peak_db={d:.2}dB outside target range [{d:.2},{d:.2}]dB; ", .{ gr_after, target_gr_min_db, target_gr_max_db }) catch {};
        if (!rms_ok) reason_w.print("rms_dbfs dropped by {d:.2}dB, exceeding the {d:.2}dB limit; ", .{ rms_delta, max_rms_loss_db }) catch {};
        if (!clip_ok) reason_w.print("peak_dbfs={d:.2}dBFS exceeds the {d:.2}dBFS clipping limit; ", .{ after_stats.peak_dbfs, max_peak_dbfs }) catch {};
    }
    const reason_str = reason_w.buffered();

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"track_id\":{d},\"effect_id\":{d},\"param\":\"{s}\",\"old_value\":{d:.4},\"new_value\":{d:.4}," ++
        "\"window_start_frame\":{d},\"window_length_frames\":{d}," ++
        "\"before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
        id,                     ctx.project.revision,
        op_id,                  revision_before,
        applied_at_audio_frame, track_id,
        effect_id,              param,
        old_value,              new_value,
        start_frame,            length_frames,
        before_stats.peak_dbfs, before_stats.rms_dbfs,
    }) catch {};
    writeRangeStatsTail(&w, before_stats);
    w.print("}},\"after\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{ after_stats.peak_dbfs, after_stats.rms_dbfs }) catch {};
    writeRangeStatsTail(&w, after_stats);
    w.print("}},\"constraints\":{{\"target_gr_min_db\":{d:.2},\"target_gr_max_db\":{d:.2},\"max_rms_loss_db\":{d:.2},\"max_peak_dbfs\":{d:.2}}}," ++
        "\"decision\":\"{s}\",\"reason\":\"{s}\",\"before_audition_path\":\"{s}\",\"after_audition_path\":\"{s}\"}}}}", .{
        target_gr_min_db, target_gr_max_db,
        max_rms_loss_db,  max_peak_dbfs,
        if (committed) "committed" else "rolled_back",
        reason_str,
        before_path_z,    after_path_z,
    }) catch {};
    return w.buffered();
}

fn getEqBandPtr(effect: *model.Effect, band_index: usize) ?*model.EqBand {
    if (effect.params != .eq) return null;
    if (band_index >= effect.params.eq.bands.items.len) return null;
    return &effect.params.eq.bands.items[band_index];
}

fn getEqBandGain(effect: *const model.Effect, band_index: usize) ?f32 {
    if (effect.params != .eq) return null;
    if (band_index >= effect.params.eq.bands.items.len) return null;
    return effect.params.eq.bands.items[band_index].gain_db;
}

fn setEqBandGain(effect: *model.Effect, band_index: usize, gain_db: f32) bool {
    if (effect.params != .eq) return false;
    if (band_index >= effect.params.eq.bands.items.len) return false;
    if (effect.params.eq.bands.items[band_index].band_type == .highpass and gain_db != 0.0) return false;
    effect.params.eq.bands.items[band_index].gain_db = gain_db;
    return true;
}

/// Bounded EQ workflow: one parameter trial (`gain_db` | `frequency_hz` | `q` | `band_type`),
/// same-window before/after measure, audition WAVs, commit or roll back.

fn getStereoWidthParam(p: model.StereoWidthParams, name: []const u8) ?f32 {
    if (std.mem.eql(u8, name, "width")) return p.width;
    if (std.mem.eql(u8, name, "high_width")) return p.high_width;
    if (std.mem.eql(u8, name, "low_width")) return p.low_width;
    if (std.mem.eql(u8, name, "crossover_hz")) return p.crossover_hz;
    return null;
}

fn setStereoWidthParam(p: *model.StereoWidthParams, name: []const u8, value: f32) bool {
    if (std.mem.eql(u8, name, "width")) {
        p.width = std.math.clamp(value, 0.0, 2.0);
        return true;
    }
    if (std.mem.eql(u8, name, "high_width")) {
        p.high_width = std.math.clamp(value, 0.0, 2.0);
        return true;
    }
    if (std.mem.eql(u8, name, "low_width")) {
        p.low_width = std.math.clamp(value, 0.0, 2.0);
        return true;
    }
    if (std.mem.eql(u8, name, "crossover_hz")) {
        p.crossover_hz = std.math.clamp(value, 40.0, 2000.0);
        return true;
    }
    return false;
}

fn findStereoWidthEffect(project: *model.Project, args: ?std.json.Value, effect_id: model.EffectId) ?*model.Effect {
    if (getU64(args, "track_id")) |tid| {
        const track = project.findTrack(tid) orelse return null;
        for (track.effects.items) |*e| {
            if (e.id == effect_id) return e;
        }
        return null;
    }
    if (getU64(args, "bus_id")) |bid| {
        const bus = project.findBus(bid) orelse return null;
        for (bus.effects.items) |*e| {
            if (e.id == effect_id) return e;
        }
        return null;
    }
    for (project.master_effects.items) |*e| {
        if (e.id == effect_id) return e;
    }
    return null;
}

fn handleStereoWidthAssessAndAdjust(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const effect_id = getU64(args, "effect_id") orelse return errResp(response_buf, id, "missing_effect_id");
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    const param = getStr(args, "param") orelse return errResp(response_buf, id, "missing_param");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");

    const constraints = getField(args, "constraints");
    const max_correlation: f32 = @floatCast(getF64(constraints, "max_correlation") orelse getF64(args, "max_correlation") orelse 0.99);
    const min_correlation: f32 = @floatCast(getF64(constraints, "min_correlation") orelse getF64(args, "min_correlation") orelse 0.15);
    const max_mono_loss_db: f32 = @floatCast(getF64(constraints, "max_mono_loss_db") orelse getF64(args, "max_mono_loss_db") orelse 1.5);
    const max_true_peak_dbtp: f32 = @floatCast(getF64(constraints, "max_true_peak_dbtp") orelse getF64(args, "max_true_peak_dbtp") orelse -1.0);
    const max_side_gain_db: f32 = @floatCast(getF64(constraints, "max_side_gain_db") orelse getF64(args, "max_side_gain_db") orelse 4.0);
    const max_low_band_side_delta_db: f32 = @floatCast(getF64(constraints, "max_low_band_side_delta_db") orelse getF64(args, "max_low_band_side_delta_db") orelse 1.0);
    const max_anti_phase: f32 = @floatCast(getF64(constraints, "max_anti_phase_sample_ratio") orelse getF64(args, "max_anti_phase_sample_ratio") orelse 0.35);
    const auto_commit = getBool(args, "auto_commit") orelse false;

    const expected_rev = getU64(args, "expected_revision");
    if (expected_rev) |er| {
        if (er != ctx.project.revision) return errResp(response_buf, id, "stale_revision");
    }

    const effect = findStereoWidthEffect(ctx.project, args, effect_id) orelse return errResp(response_buf, id, "effect_not_found");
    if (effect.params != .stereo_width) return errResp(response_buf, id, "effect_not_stereo_width");
    const p = &effect.params.stereo_width;
    const old_value = getStereoWidthParam(p.*, param) orelse return errResp(response_buf, id, "unsupported_stereo_width_param");
    const vf = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
    const new_value: f32 = @floatCast(vf);
    if (new_value < 0.0 or new_value > 2.0) return errResp(response_buf, id, "width_out_of_range");
    // Expanding above 1.5 requires tighter mono/phase defaults already in constraints.

    const target: MeasureTarget = parseMeasureTarget(args) catch .{ .master = .master_output };
    const before_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(before_buf);
    const before_stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, before_buf, ctx.view.fx_bypass_all) catch
        return errResp(response_buf, id, "measure_failed");

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    var before_path_buf: [256]u8 = undefined;
    const before_path_z = std.fmt.bufPrintZ(&before_path_buf, ".cache/audition/{d}_width_before.wav", .{op_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_buf, length_frames, ctx.project.sample_rate, before_path_z)) return errResp(response_buf, id, "export_failed");

    if (!setStereoWidthParam(p, param, new_value)) return errResp(response_buf, id, "unsupported_stereo_width_param");
    ctx.project.revision += 1;
    ui.markDirty(ctx.view);

    const after_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(after_buf);
    const after_stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, after_buf, ctx.view.fx_bypass_all) catch
        return errResp(response_buf, id, "measure_failed");
    var after_path_buf: [256]u8 = undefined;
    const after_path_z = std.fmt.bufPrintZ(&after_path_buf, ".cache/audition/{d}_width_after.wav", .{op_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_buf, length_frames, ctx.project.sample_rate, after_path_z)) return errResp(response_buf, id, "export_failed");

    const before_st = before_stats.stereo orelse stereo_analysis.analyzeStereo(before_buf[0 .. length_frames * 2], ctx.project.sample_rate);
    const after_st = after_stats.stereo orelse stereo_analysis.analyzeStereo(after_buf[0 .. length_frames * 2], ctx.project.sample_rate);

    const widening = new_value > old_value and (std.mem.eql(u8, param, "high_width") or std.mem.eql(u8, param, "width"));
    const side_delta = after_st.side_rms_dbfs - before_st.side_rms_dbfs;
    const high_side_delta = 0.5 * ((after_st.bands[3].side_to_mid_db - before_st.bands[3].side_to_mid_db) + (after_st.bands[4].side_to_mid_db - before_st.bands[4].side_to_mid_db));
    const low_side_delta = after_st.bands[0].side_to_mid_db - before_st.bands[0].side_to_mid_db;
    const mono_loss_delta = after_st.mono_loss_db - before_st.mono_loss_db;
    const corr_after = after_st.correlation_mean;
    const tp_after = after_stats.true_peak_dbtp orelse 0;

    var fail = false;
    var reason_buf: [1024]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&reason_buf);
    if (corr_after < min_correlation) {
        fail = true;
        rw.print("correlation_mean {d:.3} below min {d:.3}; ", .{ corr_after, min_correlation }) catch {};
    }
    if (corr_after > max_correlation and widening) {
        // still too correlated for an expanding trial that claimed a max_correlation target
        fail = true;
        rw.print("correlation_mean {d:.3} still above max_correlation {d:.3}; ", .{ corr_after, max_correlation }) catch {};
    }
    if (mono_loss_delta > max_mono_loss_db) {
        fail = true;
        rw.print("mono_loss delta {d:.2} exceeds {d:.2}; ", .{ mono_loss_delta, max_mono_loss_db }) catch {};
    }
    if (after_st.anti_phase_sample_ratio > max_anti_phase) {
        fail = true;
        rw.print("anti_phase_sample_ratio {d:.3} exceeds {d:.3}; ", .{ after_st.anti_phase_sample_ratio, max_anti_phase }) catch {};
    }
    if (tp_after > max_true_peak_dbtp) {
        fail = true;
        rw.print("true_peak_dbtp {d:.2} exceeds {d:.2}; ", .{ tp_after, max_true_peak_dbtp }) catch {};
    }
    if (side_delta > max_side_gain_db) {
        fail = true;
        rw.print("side energy gain {d:.2}dB exceeds {d:.2}; ", .{ side_delta, max_side_gain_db }) catch {};
    }
    if (std.mem.eql(u8, param, "high_width") or std.mem.eql(u8, param, "width")) {
        if (low_side_delta > max_low_band_side_delta_db) {
            fail = true;
            rw.print("low-band side_to_mid rose {d:.2}dB (policy max {d:.2}); ", .{ low_side_delta, max_low_band_side_delta_db }) catch {};
        }
    }
    if (widening and high_side_delta < 0.15 and side_delta < 0.15) {
        fail = true;
        rw.writeAll("upper-band side energy did not increase measurably; ") catch {};
    }

    var decision: []const u8 = "committed";
    if (fail) {
        _ = setStereoWidthParam(p, param, old_value);
        ctx.project.revision += 1;
        ui.markDirty(ctx.view);
        decision = "rolled_back";
    } else if (!auto_commit) {
        decision = "needs_human_listening";
        rw.writeAll("In the matched A/B, does the wider version feel more open without making the center weaker or the stereo image unstable? Technical limits passed — artistic width judgment required.") catch {};
    } else {
        rw.writeAll("Side-to-mid energy increased in the selected upper bands while mono loss and true peak remained within the requested limits.") catch {};
    }
    const reason = rw.buffered();

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"effect_id\":{d},\"param\":\"{s}\",\"old_value\":{d:.4},\"new_value\":{d:.4}," ++
        "\"window_start_frame\":{d},\"window_length_frames\":{d},\"analysis_scope\":\"measure_window\"," ++
        "\"decision\":\"{s}\",\"reason\":", .{
        id,                     ctx.project.revision,
        op_id,                  revision_before,
        applied_at_audio_frame, effect_id,
        param,                  old_value,
        new_value,              start_frame,
        length_frames,          decision,
    }) catch {};
    w.print("\"{s}\"", .{reason}) catch {};
    w.print(",\"before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
        before_stats.peak_dbfs, before_stats.rms_dbfs,
    }) catch {};
    writeRangeStatsTail(&w, before_stats);
    w.print("}},\"after\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
        after_stats.peak_dbfs, after_stats.rms_dbfs,
    }) catch {};
    writeRangeStatsTail(&w, after_stats);
    w.print("}},\"stereo_delta\":{{\"side_rms_delta_db\":{d:.2},\"high_band_side_to_mid_delta_db\":{d:.2},\"low_band_side_to_mid_delta_db\":{d:.2},\"mono_loss_delta_db\":{d:.2},\"correlation_before\":{d:.4},\"correlation_after\":{d:.4}}},\"before_audition_path\":\"{s}\",\"after_audition_path\":\"{s}\"}}}}", .{
        side_delta, high_side_delta, low_side_delta, mono_loss_delta, before_st.correlation_mean, after_st.correlation_mean, before_path_z, after_path_z,
    }) catch {};
    return w.buffered();
}

fn handleEqAssessAndAdjust(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const track_id = getU64(args, "track_id") orelse return errResp(response_buf, id, "missing_track_id");
    const effect_id = getU64(args, "effect_id") orelse return errResp(response_buf, id, "missing_effect_id");
    const band_index_u = getU64(args, "band_index") orelse return errResp(response_buf, id, "missing_band_index");
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    const param = getStr(args, "param") orelse return errResp(response_buf, id, "missing_param");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
    if (band_index_u > 255) return errResp(response_buf, id, "band_index_out_of_range");
    const band_index: usize = @intCast(band_index_u);

    const min_band_delta_db: f32 = @floatCast(getF64(args, "min_band_energy_delta_db") orelse 2.0);
    const max_rms_change_db: f32 = @floatCast(getF64(args, "max_rms_change_db") orelse 6.0);
    const max_peak_dbfs: f32 = @floatCast(getF64(args, "max_peak_dbfs") orelse 0.0);
    const max_mid_change_db: f32 = @floatCast(getF64(args, "max_mid_change_db") orelse 3.0);
    const max_neighbour_spill_db: f32 = @floatCast(getF64(args, "max_neighbour_spill_db") orelse 6.0);

    const track = ctx.project.findTrack(track_id) orelse return errResp(response_buf, id, "track_not_found");
    const effect = for (track.effects.items) |*e| {
        if (e.id == effect_id) break e;
    } else return errResp(response_buf, id, "effect_not_found");
    if (effect.params != .eq) return errResp(response_buf, id, "effect_not_eq");
    const band_pre = getEqBandPtr(effect, band_index) orelse return errResp(response_buf, id, "band_index_out_of_range");

    const old_type = band_pre.band_type;
    const old_freq = band_pre.frequency_hz;
    const old_gain = band_pre.gain_db;
    const old_q = band_pre.q;
    const spectral_i = nearestSpectralBandIndex(old_freq);

    // Validate + stage new values without applying yet.
    var new_type = old_type;
    var new_freq = old_freq;
    var new_gain = old_gain;
    var new_q = old_q;
    var old_value_num: f32 = 0;
    var new_value_num: f32 = 0;
    const old_value_type: []const u8 = eqBandTypeName(old_type);
    var new_value_type: []const u8 = eqBandTypeName(old_type);
    const value_is_type = std.mem.eql(u8, param, "band_type");

    if (std.mem.eql(u8, param, "band_type")) {
        const value_field = getField(args, "value");
        const s = if (value_field) |v| (if (v == .string) v.string else null) else getStr(args, "band_type");
        new_type = parseEqBandType(s orelse return errResp(response_buf, id, "missing_value")) orelse
            return errResp(response_buf, id, "invalid_band_type");
        if (new_type == .highpass and old_gain != 0.0) return errResp(response_buf, id, "highpass_gain_forbidden");
        if (new_type == .highpass) new_gain = 0.0;
        new_value_type = eqBandTypeName(new_type);
    } else if (std.mem.eql(u8, param, "frequency_hz") or std.mem.eql(u8, param, "freq")) {
        const vf = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
        new_freq = @floatCast(vf);
        if (!validateEqFrequency(new_freq, ctx.project.sample_rate)) return errResp(response_buf, id, "frequency_out_of_range");
        old_value_num = old_freq;
        new_value_num = new_freq;
    } else if (std.mem.eql(u8, param, "gain_db")) {
        if (old_type == .highpass) return errResp(response_buf, id, "highpass_gain_forbidden");
        const vf = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
        new_gain = @floatCast(vf);
        if (!validateEqGain(new_gain)) return errResp(response_buf, id, "gain_out_of_range");
        old_value_num = old_gain;
        new_value_num = new_gain;
    } else if (std.mem.eql(u8, param, "q")) {
        const vf = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
        new_q = @floatCast(vf);
        if (!validateEqQ(new_q)) return errResp(response_buf, id, "q_out_of_range");
        old_value_num = old_q;
        new_value_num = new_q;
    } else return errResp(response_buf, id, "unsupported_eq_param");

    const target: MeasureTarget = .{ .track = track_id };
    const before_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(before_buf);
    const before_stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, before_buf, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else "measure_failed");

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    var before_path_buf: [256]u8 = undefined;
    const before_path_z = std.fmt.bufPrintZ(&before_path_buf, ".cache/audition/{d}_eq_before.wav", .{op_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_buf, length_frames, ctx.project.sample_rate, before_path_z)) return errResp(response_buf, id, "export_failed");

    // Apply single-parameter mutation (plus HPF gain clear when switching type to highpass).
    band_pre.band_type = new_type;
    band_pre.frequency_hz = new_freq;
    band_pre.gain_db = new_gain;
    band_pre.q = new_q;
    ctx.project.revision += 1;
    ui.markDirty(ctx.view);

    const after_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(after_buf);
    const after_stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, after_buf, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else "measure_failed");
    var after_path_buf: [256]u8 = undefined;
    const after_path_z = std.fmt.bufPrintZ(&after_path_buf, ".cache/audition/{d}_eq_after.wav", .{op_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_buf, length_frames, ctx.project.sample_rate, after_path_z)) return errResp(response_buf, id, "export_failed");

    const d20_60 = after_stats.band_energy_db[0] - before_stats.band_energy_db[0];
    const d80_200 = after_stats.band_energy_db[1] - before_stats.band_energy_db[1];
    const d1_4k = meanSelectedBands(&after_stats.band_energy_db, &.{ 4, 5, 6 }) - meanSelectedBands(&before_stats.band_energy_db, &.{ 4, 5, 6 });
    const d_low = lowBandEnergy(&after_stats.band_energy_db) - lowBandEnergy(&before_stats.band_energy_db);
    const d_mid = midBandEnergy(&after_stats.band_energy_db) - midBandEnergy(&before_stats.band_energy_db);
    const d_high = highBandEnergy(&after_stats.band_energy_db) - highBandEnergy(&before_stats.band_energy_db);
    const target_delta = after_stats.band_energy_db[spectral_i] - before_stats.band_energy_db[spectral_i];
    const neighbour_i = if (spectral_i + 1 < SPECTRAL_BAND_COUNT) spectral_i + 1 else spectral_i -| 1;
    const neighbour_delta = after_stats.band_energy_db[neighbour_i] - before_stats.band_energy_db[neighbour_i];
    const rms_change = @abs(after_stats.rms_dbfs - before_stats.rms_dbfs);
    const rms_ok = rms_change <= max_rms_change_db;
    const clip_ok = after_stats.peak_dbfs <= max_peak_dbfs;
    const mid_ok = @abs(d_mid) <= max_mid_change_db;

    var effect_ok = true;
    const effective_type = new_type;
    if (effective_type == .peak) {
        if (std.mem.eql(u8, param, "gain_db")) {
            const gain_delta = new_gain - old_gain;
            effect_ok = if (gain_delta >= 0) target_delta >= min_band_delta_db else target_delta <= -min_band_delta_db;
            if (@abs(neighbour_delta) > max_neighbour_spill_db and @abs(neighbour_delta) > @abs(target_delta)) effect_ok = false;
        } else if (std.mem.eql(u8, param, "q")) {
            // Narrower Q (higher) should reduce neighbour spill vs broad; require measurable energy change at target or neighbour.
            effect_ok = @abs(target_delta) >= 0.5 or @abs(neighbour_delta) >= 0.5;
        } else {
            effect_ok = @abs(target_delta) >= min_band_delta_db * 0.5;
        }
    } else if (effective_type == .low_shelf) {
        effect_ok = @abs(d_low) >= min_band_delta_db * 0.5 and mid_ok;
        if (std.mem.eql(u8, param, "gain_db") and new_gain < old_gain) effect_ok = effect_ok and d_low <= -min_band_delta_db * 0.25;
        if (std.mem.eql(u8, param, "gain_db") and new_gain > old_gain) effect_ok = effect_ok and d_low >= min_band_delta_db * 0.25;
    } else if (effective_type == .high_shelf) {
        effect_ok = @abs(d_high) >= min_band_delta_db * 0.5 and mid_ok;
        if (std.mem.eql(u8, param, "gain_db") and new_gain < old_gain) effect_ok = effect_ok and d_high <= -min_band_delta_db * 0.25;
        if (std.mem.eql(u8, param, "gain_db") and new_gain > old_gain) effect_ok = effect_ok and d_high >= min_band_delta_db * 0.25;
    } else {
        // highpass: energy below cutoff reduced; mid within tolerance; LF not fully wiped (still above floor)
        effect_ok = d_low <= -min_band_delta_db * 0.5 and mid_ok;
        const after_low = lowBandEnergy(&after_stats.band_energy_db);
        if (after_low < -90.0 and before_stats.rms_dbfs > -40.0) effect_ok = false; // total LF wipe
    }

    const committed = effect_ok and rms_ok and clip_ok;
    if (!committed) {
        // Self-contained revert (see handleSidechainAssessAndAdjust for why:
        // this also runs from the offline worker thread, which bypasses
        // handleCommand's auto-snapshot, so ctx.history.undo() would be a
        // no-op there).
        band_pre.band_type = old_type;
        band_pre.frequency_hz = old_freq;
        band_pre.gain_db = old_gain;
        band_pre.q = old_q;
        ctx.project.revision += 1;
        ui.markDirty(ctx.view);
    }

    var reason_buf: [768]u8 = undefined;
    var reason_w: std.Io.Writer = .fixed(&reason_buf);
    if (committed) {
        reason_w.print("Energy change observed (low {d:.2}dB, mid {d:.2}dB, high {d:.2}dB); mid stayed within {d:.2}dB; |rms| {d:.2}dB; peak_dbfs={d:.2}. Technical EQ observe only — not musical quality; not a reference match claim.", .{
            d_low, d_mid, d_high, max_mid_change_db, rms_change, after_stats.peak_dbfs,
        }) catch {};
    } else {
        reason_w.writeAll("rolled back: ") catch {};
        if (!effect_ok) reason_w.writeAll("band-type spectral policy failed; ") catch {};
        if (!rms_ok) reason_w.print("|rms| change {d:.2}dB exceeds {d:.2}dB; ", .{ rms_change, max_rms_change_db }) catch {};
        if (!clip_ok) reason_w.print("peak_dbfs={d:.2} exceeds {d:.2}; ", .{ after_stats.peak_dbfs, max_peak_dbfs }) catch {};
    }
    const reason_str = reason_w.buffered();

    const gain_json: []const u8 = if (new_type == .highpass) "null" else "num";
    _ = gain_json;

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"track_id\":{d},\"effect_id\":{d},\"band_index\":{d},\"band_freq\":{d:.2},\"spectral_band_index\":{d},\"spectral_band_hz\":{d}," ++
        "\"param\":\"{s}\",", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame,
        track_id, effect_id, band_index, new_freq, spectral_i, SPECTRAL_BAND_HZ[spectral_i], param,
    }) catch {};
    if (value_is_type) {
        w.print("\"old_value\":\"{s}\",\"new_value\":\"{s}\",", .{ old_value_type, new_value_type }) catch {};
    } else {
        w.print("\"old_value\":{d:.4},\"new_value\":{d:.4},", .{ old_value_num, new_value_num }) catch {};
    }
    w.print("\"window_start_frame\":{d},\"window_length_frames\":{d}," ++
        "\"before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
        start_frame, length_frames, before_stats.peak_dbfs, before_stats.rms_dbfs,
    }) catch {};
    writeRangeStatsTail(&w, before_stats);
    w.print("}},\"after\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
        after_stats.peak_dbfs, after_stats.rms_dbfs,
    }) catch {};
    writeRangeStatsTail(&w, after_stats);
    w.print("}},\"eq\":{{\"band_type\":\"{s}\",\"frequency_hz\":{d:.2},\"q\":{d:.4},", .{
        eqBandTypeName(new_type), new_freq, new_q,
    }) catch {};
    if (new_type == .highpass) {
        w.writeAll("\"gain_db\":null,") catch {};
    } else {
        w.print("\"gain_db\":{d:.2},", .{new_gain}) catch {};
    }
    w.print("\"measured_delta_db\":{{\"20_60_hz\":{d:.2},\"80_200_hz\":{d:.2},\"1_4_khz\":{d:.2}}}," ++
        "\"low_band_delta_db\":{d:.2},\"mid_band_delta_db\":{d:.2},\"high_band_delta_db\":{d:.2}}}," ++
        "\"constraints\":{{\"min_band_energy_delta_db\":{d:.2},\"max_rms_change_db\":{d:.2},\"max_peak_dbfs\":{d:.2},\"max_mid_change_db\":{d:.2}}}," ++
        "\"band_energy_delta_db\":{d:.2},\"decision\":\"{s}\",\"reason\":\"{s}\",\"before_audition_path\":\"{s}\",\"after_audition_path\":\"{s}\"}}}}", .{
        d20_60, d80_200, d1_4k, d_low, d_mid, d_high,
        min_band_delta_db, max_rms_change_db, max_peak_dbfs, max_mid_change_db,
        target_delta,
        if (committed) "committed" else "rolled_back",
        reason_str, before_path_z, after_path_z,
    }) catch {};
    return w.buffered();
}

fn rangeStatsToTrial(stats: RangeStats) trial.Stats {
    var out: trial.Stats = .{
        .peak_dbfs = stats.peak_dbfs,
        .rms_dbfs = stats.rms_dbfs,
        .preroll_frames = stats.preroll_frames,
    };
    const n = @min(out.band_energy_db.len, stats.band_energy_db.len);
    @memcpy(out.band_energy_db[0..n], stats.band_energy_db[0..n]);
    return out;
}

fn decisionStr(d: trial.Decision) []const u8 {
    return switch (d) {
        .committed => "committed",
        .rolled_back => "rolled_back",
        .needs_human_listening => "needs_human_listening",
        .conflict => "conflict",
    };
}

fn parseTrialConstraints(args: ?std.json.Value) trial.Constraints {
    var constraints: trial.Constraints = .{};
    if (getF64(args, "max_peak_dbfs")) |v| constraints.max_peak_dbfs = @floatCast(v);
    if (getF64(args, "max_rms_change_db")) |v| constraints.max_rms_change_db = @floatCast(v);
    if (getF64(args, "min_band_energy_delta_db")) |v| constraints.min_band_energy_delta_db = @floatCast(v);
    if (getU64(args, "spectral_band_index")) |v| constraints.spectral_band_index = @intCast(v);
    if (getBool(args, "expect_band_energy_up")) |v| constraints.expect_band_energy_up = v;
    constraints.require_human_listening = getBool(args, "require_human_listening") orelse false;
    return constraints;
}

fn applyGainToStereoBuf(buf: []f32, gain_db: f32) void {
    const g = std.math.pow(f32, 10.0, gain_db / 20.0);
    for (buf) |*s| s.* *= g;
}

fn handleBeginTrial(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
    if (ctx.trial_registry.hasActive()) return errResp(response_buf, id, "trial_already_open");

    const track_id_opt = getU64(args, "track_id");
    const target: MeasureTarget = if (track_id_opt) |tid| .{ .track = tid } else .{ .master = .master_output };

    const before_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(before_buf);
    const before_stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, before_buf, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else "measure_failed");

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    var before_path_buf: [256]u8 = undefined;
    // provisional id = next_id before begin
    const provisional_id = ctx.trial_registry.next_id;
    const before_path_z = std.fmt.bufPrintZ(&before_path_buf, ".cache/audition/trial_{d}_before.wav", .{provisional_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_buf, length_frames, ctx.project.sample_rate, before_path_z)) return errResp(response_buf, id, "export_failed");

    const tid = ctx.trial_registry.begin(ctx.project, track_id_opt, start_frame, length_frames, rangeStatsToTrial(before_stats), before_path_z) catch |e|
        return errResp(response_buf, id, if (e == error.TrialAlreadyOpen) "trial_already_open" else "trial_begin_failed");

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"trial_id\":{d},\"phase\":\"open\",\"track_id\":{d},\"window_start_frame\":{d},\"window_length_frames\":{d}," ++
        "\"before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
        id,                     ctx.project.revision,
        op_id,                  revision_before,
        applied_at_audio_frame, tid,
        track_id_opt orelse 0,  start_frame,
        length_frames,          before_stats.peak_dbfs,
        before_stats.rms_dbfs,
    }) catch {};
    writeRangeStatsTail(&w, before_stats);
    w.print("}},\"before_audition_path\":\"{s}\"}}}}", .{before_path_z}) catch {};
    return w.buffered();
}

fn handleResolveTrial(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const trial_id = getU64(args, "trial_id") orelse return errResp(response_buf, id, "missing_trial_id");
    const t = ctx.trial_registry.get(trial_id) orelse return errResp(response_buf, id, "trial_not_found");
    if (t.phase != .open) return errResp(response_buf, id, "trial_not_open");

    const constraints = parseTrialConstraints(args);
    const target: MeasureTarget = if (t.track_id) |tid| .{ .track = tid } else .{ .master = .master_output };
    const before_peak = t.before.peak_dbfs;
    const before_rms = t.before.rms_dbfs;
    var before_recon: [256]u8 = undefined;
    const before_path_out = std.fmt.bufPrint(&before_recon, ".cache/audition/trial_{d}_before.wav", .{t.id}) catch return errResp(response_buf, id, "internal");

    const after_buf = ctx.gpa.alloc(f32, t.length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(after_buf);
    const after_range = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, t.start_frame, t.length_frames, ctx.project.sample_rate, after_buf, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else "measure_failed");
    const after = rangeStatsToTrial(after_range);

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    var after_path_buf: [256]u8 = undefined;
    const after_path_z = std.fmt.bufPrintZ(&after_path_buf, ".cache/audition/trial_{d}_after.wav", .{t.id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_buf, t.length_frames, ctx.project.sample_rate, after_path_z)) return errResp(response_buf, id, "export_failed");

    const match_gain = trial.Registry.levelMatchGainDb(before_rms, after.rms_dbfs);
    var matched_path_buf: [256]u8 = undefined;
    const matched_path_z = std.fmt.bufPrintZ(&matched_path_buf, ".cache/audition/trial_{d}_after_level_matched.wav", .{t.id}) catch return errResp(response_buf, id, "internal");
    applyGainToStereoBuf(after_buf, match_gain);
    if (!exportRangeWav(after_buf, t.length_frames, ctx.project.sample_rate, matched_path_z)) return errResp(response_buf, id, "export_failed");

    const obj = trial.Registry.objectivesOk(t.before, after, constraints);
    const decision = trial.decide(obj.ok, constraints.require_human_listening);

    switch (decision) {
        .rolled_back => {
            ctx.trial_registry.restoreSnapshot(ctx.project) catch return errResp(response_buf, id, "restore_failed");
            ui.markDirty(ctx.view);
            ctx.trial_registry.close();
        },
        .committed => {
            ctx.trial_registry.close();
        },
        .needs_human_listening => {
            ctx.trial_registry.markAwaitingHuman() catch {};
        },
        .conflict => unreachable,
    }

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"trial_id\":{d},\"decision\":\"{s}\",\"objective_detail\":\"{s}\"," ++
        "\"level_match\":{{\"method\":\"rms\",\"reference\":\"before\",\"applied_gain_db\":{d:.2}}}," ++
        "\"before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2}}}," ++
        "\"after\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2}}}," ++
        "\"before_audition_path\":\"{s}\",\"after_audition_path\":\"{s}\",\"after_level_matched_path\":\"{s}\"}}}}", .{
        id,                     ctx.project.revision,
        op_id,                  revision_before,
        applied_at_audio_frame, trial_id,
        decisionStr(decision),  obj.detail,
        match_gain,             before_peak,
        before_rms,             after.peak_dbfs,
        after.rms_dbfs,         before_path_out,
        after_path_z,           matched_path_z,
    }) catch {};
    return w.buffered();
}

fn handleConfirmTrial(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const trial_id = getU64(args, "trial_id") orelse return errResp(response_buf, id, "missing_trial_id");
    const t = ctx.trial_registry.get(trial_id) orelse return errResp(response_buf, id, "trial_not_found");
    if (t.phase != .awaiting_human) return errResp(response_buf, id, "trial_not_awaiting_human");
    ctx.trial_registry.close();
    return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"trial_id\":{d},\"decision\":\"committed\"}}}}", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, trial_id,
    }) catch errResp(response_buf, id, "response_too_large");
}

fn handleRejectTrial(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const trial_id = getU64(args, "trial_id") orelse return errResp(response_buf, id, "missing_trial_id");
    const t = ctx.trial_registry.get(trial_id) orelse return errResp(response_buf, id, "trial_not_found");
    if (t.phase != .awaiting_human) return errResp(response_buf, id, "trial_not_awaiting_human");
    ctx.trial_registry.restoreSnapshot(ctx.project) catch return errResp(response_buf, id, "restore_failed");
    ui.markDirty(ctx.view);
    ctx.trial_registry.close();
    return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"trial_id\":{d},\"decision\":\"rolled_back\"}}}}", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, trial_id,
    }) catch errResp(response_buf, id, "response_too_large");
}

fn handleAbortTrial(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const trial_id = getU64(args, "trial_id") orelse return errResp(response_buf, id, "missing_trial_id");
    const t = ctx.trial_registry.get(trial_id) orelse return errResp(response_buf, id, "trial_not_found");
    _ = t;
    ctx.trial_registry.restoreSnapshot(ctx.project) catch return errResp(response_buf, id, "restore_failed");
    ui.markDirty(ctx.view);
    ctx.trial_registry.close();
    return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"trial_id\":{d},\"decision\":\"rolled_back\"}}}}", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, trial_id,
    }) catch errResp(response_buf, id, "response_too_large");
}

fn getCompressorParam(p: model.CompressorParams, name: []const u8) ?f32 {
    if (std.mem.eql(u8, name, "threshold_db")) return p.threshold_db;
    if (std.mem.eql(u8, name, "ratio")) return p.ratio;
    if (std.mem.eql(u8, name, "attack_ms")) return p.attack_ms;
    if (std.mem.eql(u8, name, "release_ms")) return p.release_ms;
    if (std.mem.eql(u8, name, "knee_db")) return p.knee_db;
    if (std.mem.eql(u8, name, "makeup_db")) return p.makeup_db;
    if (std.mem.eql(u8, name, "mix")) return p.mix;
    return null;
}

fn setCompressorParam(p: *model.CompressorParams, name: []const u8, value: f32) bool {
    if (std.mem.eql(u8, name, "threshold_db")) {
        p.threshold_db = value;
        return true;
    }
    if (std.mem.eql(u8, name, "ratio")) {
        p.ratio = @max(value, 1.0);
        return true;
    }
    if (std.mem.eql(u8, name, "attack_ms")) {
        p.attack_ms = @max(value, 0.1);
        return true;
    }
    if (std.mem.eql(u8, name, "release_ms")) {
        p.release_ms = @max(value, 0.1);
        return true;
    }
    if (std.mem.eql(u8, name, "knee_db")) {
        p.knee_db = @max(value, 0.0);
        return true;
    }
    if (std.mem.eql(u8, name, "makeup_db")) {
        p.makeup_db = value;
        return true;
    }
    if (std.mem.eql(u8, name, "mix")) {
        p.mix = std.math.clamp(value, 0.0, 1.0);
        return true;
    }
    return false;
}

fn needsHumanCompressorParam(name: []const u8) bool {
    return std.mem.eql(u8, name, "attack_ms") or std.mem.eql(u8, name, "release_ms");
}

/// Bounded compressor workflow facading trial snapshot restore (not blind undo).
fn handleCompressorAssessAndAdjust(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const track_id = getU64(args, "track_id") orelse return errResp(response_buf, id, "missing_track_id");
    const effect_id = getU64(args, "effect_id") orelse return errResp(response_buf, id, "missing_effect_id");
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    const param = getStr(args, "param") orelse return errResp(response_buf, id, "missing_param");
    const new_value_f64 = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
    if (ctx.trial_registry.hasActive()) return errResp(response_buf, id, "trial_already_open");

    const constraints_obj = getField(args, "constraints") orelse args;
    const gr_peak_min: f32 = @floatCast(getF64(constraints_obj, "gr_peak_min_db") orelse 1.0);
    const gr_peak_max: f32 = @floatCast(getF64(constraints_obj, "gr_peak_max_db") orelse 6.0);
    const gr_mean_active_max: f32 = @floatCast(getF64(constraints_obj, "gr_mean_active_max_db") orelse 4.0);
    const max_rms_change: f32 = @floatCast(getF64(constraints_obj, "max_rms_change_db") orelse 2.0);
    const max_peak: f32 = @floatCast(getF64(constraints_obj, "max_peak_dbfs") orelse -0.1);
    const max_active_ratio: f32 = @floatCast(getF64(constraints_obj, "max_active_ratio") orelse 0.8);
    const force_human = getBool(args, "require_human_listening") orelse needsHumanCompressorParam(param);

    const track = ctx.project.findTrack(track_id) orelse return errResp(response_buf, id, "track_not_found");
    const effect = for (track.effects.items) |*e| {
        if (e.id == effect_id) break e;
    } else return errResp(response_buf, id, "effect_not_found");
    if (effect.params != .compressor) return errResp(response_buf, id, "effect_not_compressor");
    const old_value = getCompressorParam(effect.params.compressor, param) orelse return errResp(response_buf, id, "unknown_param");
    const new_value: f32 = @floatCast(new_value_f64);

    const target: MeasureTarget = .{ .track = track_id };
    const before_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(before_buf);
    const before_stats = measureRangeObserving(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, before_buf, effect_id, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else "measure_failed");

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    var before_path_buf: [256]u8 = undefined;
    const provisional = ctx.trial_registry.next_id;
    const before_path_z = std.fmt.bufPrintZ(&before_path_buf, ".cache/audition/comp_trial_{d}_before.wav", .{provisional}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_buf, length_frames, ctx.project.sample_rate, before_path_z)) return errResp(response_buf, id, "export_failed");

    const trial_id = ctx.trial_registry.begin(ctx.project, track_id, start_frame, length_frames, rangeStatsToTrial(before_stats), before_path_z) catch
        return errResp(response_buf, id, "trial_begin_failed");

    if (!setCompressorParam(&effect.params.compressor, param, new_value)) {
        ctx.trial_registry.close();
        return errResp(response_buf, id, "unknown_param");
    }
    ctx.project.revision += 1;
    ui.markDirty(ctx.view);
    const revision_after = ctx.project.revision;

    const after_buf = ctx.gpa.alloc(f32, length_frames * 2) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "oom");
    };
    defer ctx.gpa.free(after_buf);
    const after_stats = measureRangeObserving(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, after_buf, effect_id, ctx.view.fx_bypass_all) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "measure_failed");
    };

    var after_raw_buf: [256]u8 = undefined;
    const after_raw_z = std.fmt.bufPrintZ(&after_raw_buf, ".cache/audition/comp_trial_{d}_after_raw.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_buf, length_frames, ctx.project.sample_rate, after_raw_z)) return errResp(response_buf, id, "export_failed");

    const match_gain = trial.Registry.levelMatchGainDb(before_stats.rms_dbfs, after_stats.rms_dbfs);
    const after_matched = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(after_matched);
    @memcpy(after_matched, after_buf);
    applyGainToStereoBuf(after_matched, match_gain);
    var after_matched_buf: [256]u8 = undefined;
    const after_matched_z = std.fmt.bufPrintZ(&after_matched_buf, ".cache/audition/comp_trial_{d}_after_level_matched.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_matched, length_frames, ctx.project.sample_rate, after_matched_z)) return errResp(response_buf, id, "export_failed");

    const gr_peak = after_stats.comp_gr_peak_db orelse 0;
    const gr_mean = after_stats.comp_gr_mean_active_db orelse 0;
    const active_ratio = after_stats.comp_active_sample_ratio orelse 0;
    const rms_change = @abs(after_stats.rms_dbfs - before_stats.rms_dbfs);
    const gr_ok = gr_peak >= gr_peak_min and gr_peak <= gr_peak_max;
    const mean_ok = gr_mean <= gr_mean_active_max;
    const rms_ok = rms_change <= max_rms_change;
    const peak_ok = after_stats.peak_dbfs <= max_peak;
    const active_ok = active_ratio <= max_active_ratio;
    const objectives_ok = gr_ok and mean_ok and rms_ok and peak_ok and active_ok;

    var decision: trial.Decision = undefined;
    var human_q: []const u8 = "";
    if (!objectives_ok) {
        if (ctx.project.revision != revision_after) {
            decision = .conflict;
            // leave trial open? close without restore
            ctx.trial_registry.close();
        } else {
            ctx.trial_registry.restoreSnapshot(ctx.project) catch return errResp(response_buf, id, "restore_failed");
            ui.markDirty(ctx.view);
            ctx.trial_registry.close();
            decision = .rolled_back;
        }
    } else if (force_human) {
        decision = .needs_human_listening;
        human_q = "Does the level-matched after version preserve the drum transient and groove better than before?";
        ctx.trial_registry.markAwaitingHuman() catch {};
    } else {
        decision = .committed;
        ctx.trial_registry.close();
    }

    // Verify model param after decision
    var final_param: f32 = old_value;
    if (ctx.project.findTrack(track_id)) |t2| {
        for (t2.effects.items) |e| {
            if (e.id == effect_id and e.params == .compressor) {
                final_param = getCompressorParam(e.params.compressor, param) orelse old_value;
            }
        }
    }

    var reason_buf: [640]u8 = undefined;
    var reason_w: std.Io.Writer = .fixed(&reason_buf);
    switch (decision) {
        .committed => reason_w.writeAll("Committed: gain reduction and output-level constraints were satisfied on the selected range. This confirms measured compressor behavior only, not improved musical quality.") catch {},
        .rolled_back => reason_w.print("rolled_back: technical constraint failed (gr_peak={d:.2} mean_active={d:.2} rms_change={d:.2} peak={d:.2} active_ratio={d:.3})", .{ gr_peak, gr_mean, rms_change, after_stats.peak_dbfs, active_ratio }) catch {},
        .needs_human_listening => reason_w.writeAll("Objectives passed; musical attack/release character requires human listening on level-matched A/B.") catch {},
        .conflict => reason_w.writeAll("conflict: project revision changed before rollback; foreign changes were not undone.") catch {},
    }

    var before_recon: [256]u8 = undefined;
    const before_out = std.fmt.bufPrint(&before_recon, ".cache/audition/comp_trial_{d}_before.wav", .{trial_id}) catch before_path_z;

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"trial_id\":{d},\"track_id\":{d},\"effect_id\":{d},\"param\":\"{s}\",\"old_value\":{d:.4},\"new_value\":{d:.4},\"final_value\":{d:.4}," ++
        "\"window_start_frame\":{d},\"window_length_frames\":{d}," ++
        "\"decision\":\"{s}\",\"reason\":\"{s}\",\"human_question\":\"{s}\"," ++
        "\"level_match\":{{\"method\":\"rms\",\"reference\":\"before\",\"applied_gain_db\":{d:.2}}}," ++
        "\"before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
        id,                     ctx.project.revision,
        op_id,                  revision_before,
        applied_at_audio_frame, trial_id,
        track_id,               effect_id,
        param,                  old_value,
        new_value,              final_param,
        start_frame,            length_frames,
        decisionStr(decision),  reason_w.buffered(),
        human_q,                match_gain,
        before_stats.peak_dbfs, before_stats.rms_dbfs,
    }) catch {};
    writeRangeStatsTail(&w, before_stats);
    w.print("}},\"after\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{ after_stats.peak_dbfs, after_stats.rms_dbfs }) catch {};
    writeRangeStatsTail(&w, after_stats);
    w.print("}},\"constraints\":{{\"gr_peak_min_db\":{d:.2},\"gr_peak_max_db\":{d:.2},\"gr_mean_active_max_db\":{d:.2},\"max_rms_change_db\":{d:.2},\"max_peak_dbfs\":{d:.2},\"max_active_ratio\":{d:.3}}}," ++
        "\"before_audition_path\":\"{s}\",\"after_raw_audition_path\":\"{s}\",\"after_level_matched_path\":\"{s}\"}}}}", .{
        gr_peak_min,     gr_peak_max,
        gr_mean_active_max, max_rms_change,
        max_peak,        max_active_ratio,
        before_out,      after_raw_z,
        after_matched_z,
    }) catch {};
    return w.buffered();
}


/// Offline measure while transport is playing — avoids multi-second fill gaps.
fn enqueueOfflineMeasure(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    if (ctx.offline_registry.busy()) return errResp(response_buf, id, "offline_job_busy");
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
    const target = parseMeasureTarget(args) catch return errResp(response_buf, id, "bad_target");

    const reg = ctx.offline_registry;
    const job_id = reg.next_id;
    reg.next_id += 1;
    if (reg.job.result_json) |old| reg.gpa.free(old);
    reg.discardPendingGate();
    reg.job = .{
        .id = job_id,
        .kind = .measure,
        .revision_at_start = ctx.project.revision,
        .status = .init(@intFromEnum(offline_audio.Status.running)),
    };

    const Work = struct {
        gpa: std.mem.Allocator,
        reg: *offline_audio.Registry,
        project: model.Project,
        asset_cache: *const mixer.AssetCache,
        target: MeasureTarget,
        start_frame: u64,
        length_frames: u64,
        sample_rate: u32,
        audio_diag: *AudioDiag,
        fx_bypass_all: bool,

        fn run(self: *@This()) void {
            defer {
                self.project.deinit(self.gpa);
                self.gpa.destroy(self);
            }
            const t0 = offline_audio.nowNs();
            const stats = measureRange(self.gpa, &self.project, self.asset_cache, self.target, self.start_frame, self.length_frames, self.sample_rate, null, self.fx_bypass_all) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                self.reg.job.err_msg = "measure_failed";
                return;
            };
            const ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t0)) / 1e6;
            var payload: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&payload);
            w.print("{{\"target\":\"{s}\",\"track_id\":{d},\"bus_id\":{d},\"window_start_frame\":{d},\"window_length_frames\":{d},\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
                measureTargetKindStr(self.target),
                if (self.target == .track) measureTargetId(self.target) else 0,
                if (self.target == .bus) measureTargetId(self.target) else 0,
                stats.window_start_frame,
                stats.window_length_frames,
                stats.peak_dbfs,
                stats.rms_dbfs,
            }) catch {};
            writeRangeStatsTail(&w, stats);
            w.writeAll("}") catch {};
            const owned = self.gpa.dupe(u8, w.buffered()) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                return;
            };
            self.reg.job.result_json = owned;
            self.reg.job.measure_duration_ms = ms;
            self.reg.job.revision_at_compute = self.project.revision;
            self.reg.job.status.store(@intFromEnum(offline_audio.Status.succeeded), .release);
            self.audio_diag.measure_duration_ms = ms;
        }
    };

    const snap = offline_audio.cloneProject(ctx.gpa, ctx.project) catch return errResp(response_buf, id, "snapshot_failed");
    const work = ctx.gpa.create(Work) catch {
        var p = snap;
        p.deinit(ctx.gpa);
        return errResp(response_buf, id, "oom");
    };
    work.* = .{
        .gpa = ctx.gpa,
        .reg = reg,
        .project = snap,
        .asset_cache = ctx.asset_cache,
        .target = target,
        .start_frame = start_frame,
        .length_frames = length_frames,
        .sample_rate = ctx.project.sample_rate,
        .audio_diag = ctx.audio_diag,
        .fx_bypass_all = ctx.view.fx_bypass_all,
    };
    const th = std.Thread.spawn(.{}, Work.run, .{work}) catch {
        work.project.deinit(ctx.gpa);
        ctx.gpa.destroy(work);
reg.job.status.store(@intFromEnum(offline_audio.Status.idle), .release);
        return errResp(response_buf, id, "thread_spawn_failed");
    };
reg.job.thread = th;

    return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"job_id\":{d},\"status\":\"running\",\"kind\":\"measure\",\"revision_at_start\":{d}}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, job_id, revision_before }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
}

fn enqueueOfflineAudition(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    if (ctx.offline_registry.busy()) return errResp(response_buf, id, "offline_job_busy");
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
    const target = parseMeasureTarget(args) catch return errResp(response_buf, id, "bad_target");
    var path_owned: ?[]u8 = null;
    if (getStr(args, "path")) |p| {
        path_owned = ctx.gpa.dupe(u8, p) catch return errResp(response_buf, id, "oom");
    }

    const reg = ctx.offline_registry;
    const job_id = reg.next_id;
    reg.next_id += 1;
    if (reg.job.result_json) |old| reg.gpa.free(old);
    reg.discardPendingGate();
    reg.job = .{
        .id = job_id,
        .kind = .audition,
        .revision_at_start = ctx.project.revision,
        .status = .init(@intFromEnum(offline_audio.Status.running)),
    };

    const Work = struct {
        gpa: std.mem.Allocator,
        reg: *offline_audio.Registry,
        project: model.Project,
        asset_cache: *const mixer.AssetCache,
        target: MeasureTarget,
        start_frame: u64,
        length_frames: u64,
        sample_rate: u32,
        path_owned: ?[]u8,
        op_id: u64,
        audio_diag: *AudioDiag,
        fx_bypass_all: bool,

        fn run(self: *@This()) void {
            defer {
                if (self.path_owned) |p| self.gpa.free(p);
                self.project.deinit(self.gpa);
                self.gpa.destroy(self);
            }
            const buf = self.gpa.alloc(f32, self.length_frames * 2) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                self.reg.job.err_msg = "oom";
                return;
            };
            defer self.gpa.free(buf);
            const t0 = offline_audio.nowNs();
            const stats = measureRange(self.gpa, &self.project, self.asset_cache, self.target, self.start_frame, self.length_frames, self.sample_rate, buf, self.fx_bypass_all) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                self.reg.job.err_msg = "audition_failed";
                return;
            };
            const ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t0)) / 1e6;
            _ = libc.mkdir(".cache", 0o755);
            _ = libc.mkdir(".cache/audition", 0o755);
            var path_buf: [256]u8 = undefined;
            const path_z: [:0]const u8 = blk: {
                if (self.path_owned) |p| break :blk std.fmt.bufPrintZ(&path_buf, "{s}", .{p}) catch {
                    self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                    self.reg.job.err_msg = "path_too_long";
                    return;
                };
                break :blk std.fmt.bufPrintZ(&path_buf, ".cache/audition/{d}.wav", .{self.op_id}) catch {
                    self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                    return;
                };
            };
            if (!exportRangeWav(buf, self.length_frames, self.sample_rate, path_z)) {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                self.reg.job.err_msg = "export_failed";
                return;
            }
            var payload: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&payload);
            w.print("{{\"path\":\"{s}\",\"target\":\"{s}\",\"track_id\":{d},\"bus_id\":{d},\"window_start_frame\":{d},\"window_length_frames\":{d},\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
                path_z,
                measureTargetKindStr(self.target),
                if (self.target == .track) measureTargetId(self.target) else 0,
                if (self.target == .bus) measureTargetId(self.target) else 0,
                stats.window_start_frame,
                stats.window_length_frames,
                stats.peak_dbfs,
                stats.rms_dbfs,
            }) catch {};
            writeRangeStatsTail(&w, stats);
            w.writeAll("}") catch {};
            const owned = self.gpa.dupe(u8, w.buffered()) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                return;
            };
            self.reg.job.result_json = owned;
            self.reg.job.audition_duration_ms = ms;
            self.reg.job.revision_at_compute = self.project.revision;
            self.reg.job.status.store(@intFromEnum(offline_audio.Status.succeeded), .release);
            self.audio_diag.audition_duration_ms = ms;
        }
    };

    const snap = offline_audio.cloneProject(ctx.gpa, ctx.project) catch {
        if (path_owned) |p| ctx.gpa.free(p);
        return errResp(response_buf, id, "snapshot_failed");
    };
    const work = ctx.gpa.create(Work) catch {
        var p = snap;
        p.deinit(ctx.gpa);
        if (path_owned) |po| ctx.gpa.free(po);
        return errResp(response_buf, id, "oom");
    };
    work.* = .{
        .gpa = ctx.gpa,
        .reg = reg,
        .project = snap,
        .asset_cache = ctx.asset_cache,
        .target = target,
        .start_frame = start_frame,
        .length_frames = length_frames,
        .sample_rate = ctx.project.sample_rate,
        .path_owned = path_owned,
        .op_id = op_id,
        .audio_diag = ctx.audio_diag,
        .fx_bypass_all = ctx.view.fx_bypass_all,
    };
    const th = std.Thread.spawn(.{}, Work.run, .{work}) catch {
        if (work.path_owned) |po| ctx.gpa.free(po);
        work.project.deinit(ctx.gpa);
        ctx.gpa.destroy(work);
        reg.job.status.store(@intFromEnum(offline_audio.Status.idle), .release);
        return errResp(response_buf, id, "thread_spawn_failed");
    };
    reg.job.thread = th;
    return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"job_id\":{d},\"status\":\"running\",\"kind\":\"audition\",\"revision_at_start\":{d}}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, job_id, revision_before }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
}

fn enqueueOfflineMasterQc(
    ctx: *DispatchCtx,
    kind: offline_audio.Kind,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    if (ctx.offline_registry.busy()) return errResp(response_buf, id, "offline_job_busy");
    const args_val: std.json.Value = args orelse .{ .null = {} };
    const args_text = std.json.Stringify.valueAlloc(ctx.gpa, args_val, .{}) catch return errResp(response_buf, id, "oom");

    const reg = ctx.offline_registry;
    const job_id = reg.next_id;
    reg.next_id += 1;
    if (reg.job.result_json) |old| reg.gpa.free(old);
    reg.discardPendingGate();
    reg.job = .{
        .id = job_id,
        .kind = kind,
        .revision_at_start = ctx.project.revision,
        .status = .init(@intFromEnum(offline_audio.Status.running)),
    };

    const Work = struct {
        gpa: std.mem.Allocator,
        reg: *offline_audio.Registry,
        project: model.Project,
        asset_cache: *mixer.AssetCache,
        kind: offline_audio.Kind,
        args_text: []u8,
        id: i64,
        op_id: u64,
        revision_before: u64,
        applied_at_audio_frame: u64,
        audio_diag: *AudioDiag,

        fn run(self: *@This()) void {
            defer {
                self.gpa.free(self.args_text);
                self.project.deinit(self.gpa);
                self.gpa.destroy(self);
            }
            const t0 = offline_audio.nowNs();
            const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.args_text, .{}) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                self.reg.job.err_msg = "bad_args";
                return;
            };
            defer parsed.deinit();

            var transport: ui.Transport = .stop;
            var beat_time: f64 = 0;
            var history: persist.History = .{};
            defer history.deinit(self.gpa);
            var job_registry: jobs.Registry = .{};
            defer job_registry.deinit(self.gpa);
            var nested_offline = offline_audio.Registry.init(self.gpa);
            defer nested_offline.deinit();
            var pending: std.ArrayList(PendingImport) = .empty;
            defer pending.deinit(self.gpa);
            var render_state: RenderState = .{};
            var live_peaks: LivePeaks = .{};
            var view: ui.View = .{};
            var local_trial = trial.Registry.init(self.gpa);
            defer local_trial.deinit();
            var local_gate: mix_preflight.MixSessionGate = .{};
            defer local_gate.clear(self.gpa);
            var project_path: ?[]const u8 = null;
            var frame_count: u64 = 0;
            var operation_counter: u64 = self.op_id;
            var local_diag: AudioDiag = .{};
            var sc = mixer.SidechainRuntime.init(self.gpa);
            defer sc.deinit();
            var threaded = std.Io.Threaded.init(self.gpa, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var fake = DispatchCtx{
                .gpa = self.gpa,
                .io = io,
                .project = &self.project,
                .project_path = &project_path,
                .history = &history,
                .asset_cache = self.asset_cache,
                .job_registry = &job_registry,
                .offline_registry = &nested_offline,
                .pending_imports = &pending,
                .render_state = &render_state,
                .transport = &transport,
                .beat_time = &beat_time,
                .live_peaks = &live_peaks,
                .audio_diag = &local_diag,
                .view = &view,
                .sc_rt = &sc,
                .trial_registry = &local_trial,
                .frame_count = &frame_count,
                .operation_counter = &operation_counter,
                .mix_gate = &local_gate,
            };

            var resp: [65536]u8 = undefined;
            const out = switch (self.kind) {
                .analyze_master_program => handleAnalyzeMasterProgram(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                .validate_master_delivery => handleValidateMasterDelivery(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                .mix_session_preflight => handleMixSessionPreflight(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                else => {
                    self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                    self.reg.job.err_msg = "bad_kind";
                    return;
                },
            };
            // handleMixSessionPreflight stored its "passed" result into
            // `local_gate` (fake.mix_gate) -- worker-local, gone once this
            // thread returns. Move it onto the job so get_job can replay it
            // onto the REAL ctx.mix_gate; without this, an async preflight
            // (the only path an agent driving playback via MCP takes) always
            // "succeeds" here but every *_assess_and_adjust after it still
            // sees preflight_not_passed.
            if (self.kind == .mix_session_preflight and local_gate.passed) {
                self.reg.job.pending_gate = local_gate;
                local_gate = .{};
            }
            const ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t0)) / 1e6;
            self.reg.job.measure_duration_ms = ms;
            self.audio_diag.measure_duration_ms = ms;

            if (std.mem.indexOf(u8, out, "\"ok\":false") != null) {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                self.reg.job.err_msg = "qc_failed";
                self.reg.job.result_json = self.gpa.dupe(u8, out) catch return;
                return;
            }
            const env = std.json.parseFromSlice(std.json.Value, self.gpa, out, .{}) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                return;
            };
            defer env.deinit();
            const result_v = if (env.value == .object) env.value.object.get("result") else null;
            if (result_v) |rv| {
                self.reg.job.result_json = std.json.Stringify.valueAlloc(self.gpa, rv, .{}) catch {
                    self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                    return;
                };
            } else {
                self.reg.job.result_json = self.gpa.dupe(u8, out) catch {
                    self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                    return;
                };
            }
            self.reg.job.revision_at_compute = self.project.revision;
            self.reg.job.status.store(@intFromEnum(offline_audio.Status.succeeded), .release);
        }
    };

    const snap = offline_audio.cloneProject(ctx.gpa, ctx.project) catch {
        ctx.gpa.free(args_text);
        return errResp(response_buf, id, "snapshot_failed");
    };
    const work = ctx.gpa.create(Work) catch {
        var p = snap;
        p.deinit(ctx.gpa);
        ctx.gpa.free(args_text);
        return errResp(response_buf, id, "oom");
    };
    work.* = .{
        .gpa = ctx.gpa,
        .reg = reg,
        .project = snap,
        .asset_cache = ctx.asset_cache,
        .kind = kind,
        .args_text = args_text,
        .id = id,
        .op_id = op_id,
        .revision_before = revision_before,
        .applied_at_audio_frame = applied_at_audio_frame,
        .audio_diag = ctx.audio_diag,
    };
    const th = std.Thread.spawn(.{}, Work.run, .{work}) catch {
        work.project.deinit(ctx.gpa);
        ctx.gpa.free(work.args_text);
        ctx.gpa.destroy(work);
        reg.job.status.store(@intFromEnum(offline_audio.Status.idle), .release);
        return errResp(response_buf, id, "thread_spawn_failed");
    };
    reg.job.thread = th;
    return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"job_id\":{d},\"status\":\"running\",\"kind\":\"{s}\",\"revision_at_start\":{d}}}}}", .{
        id,
        ctx.project.revision,
        op_id,
        revision_before,
        applied_at_audio_frame,
        job_id,
        kind.name(),
        revision_before,
    }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
}

fn decisionFromStr(s: []const u8) u8 {
    if (std.mem.eql(u8, s, "committed")) return 0;
    if (std.mem.eql(u8, s, "rolled_back")) return 1;
    if (std.mem.eql(u8, s, "needs_human_listening")) return 2;
    return 3; // conflict
}

fn applyOfflineAssessToLive(ctx: *DispatchCtx, oj: *offline_audio.Job) void {
    if (oj.apply_target == .none) return;
    if (ctx.project.revision != oj.revision_at_start) {
        oj.apply_decision = 3; // conflict
        return;
    }
    const decision = oj.apply_decision;
    if (decision != 0 and decision != 2) return; // only committed / needs_human
    const param = oj.apply_param[0..oj.apply_param_len];
    const effect: ?*model.Effect = switch (oj.apply_target) {
        .master_compressor, .master_limiter, .master_stereo_width => blk: {
            for (ctx.project.master_effects.items) |*e| {
                if (e.id == oj.apply_effect_id) break :blk e;
            }
            break :blk null;
        },
        .track_compressor, .track_sidechain, .track_eq, .track_stereo_width => blk: {
            const tr = ctx.project.findTrack(oj.apply_track_id) orelse break :blk null;
            for (tr.effects.items) |*e| {
                if (e.id == oj.apply_effect_id) break :blk e;
            }
            break :blk null;
        },
        .bus_compressor, .bus_stereo_width => blk: {
            const bus = ctx.project.findBus(oj.apply_bus_id) orelse break :blk null;
            for (bus.effects.items) |*e| {
                if (e.id == oj.apply_effect_id) break :blk e;
            }
            break :blk null;
        },
        .none => null,
    };
    const eff = effect orelse return;
    switch (oj.apply_target) {
        .master_limiter => {
            if (eff.params != .limiter) return;
            _ = master_qc.setLimiterParam(&eff.params.limiter, param, oj.apply_value);
        },
        .master_compressor, .bus_compressor, .track_compressor => {
            if (eff.params != .compressor) return;
            _ = setCompressorParam(&eff.params.compressor, param, oj.apply_value);
        },
        .track_sidechain => {
            if (eff.params != .sidechain_compressor) return;
            _ = setSidechainParam(&eff.params.sidechain_compressor, param, oj.apply_value);
            ensureDryClipSources(ctx.project, oj.apply_track_id);
        },
        .track_eq => {
            if (eff.params != .eq) return;
            const band = getEqBandPtr(eff, oj.apply_band_index) orelse return;
            if (std.mem.eql(u8, param, "band_type")) {
                band.band_type = eqBandTypeFromOrdinal(@intFromFloat(@max(oj.apply_value, 0.0)));
                if (band.band_type == .highpass) band.gain_db = 0.0;
            } else if (std.mem.eql(u8, param, "frequency_hz") or std.mem.eql(u8, param, "freq")) {
                band.frequency_hz = oj.apply_value;
            } else if (std.mem.eql(u8, param, "gain_db")) {
                band.gain_db = oj.apply_value;
            } else if (std.mem.eql(u8, param, "q")) {
                band.q = oj.apply_value;
            } else return;
        },
        .track_stereo_width, .bus_stereo_width, .master_stereo_width => {
            if (eff.params != .stereo_width) return;
            _ = setStereoWidthParam(&eff.params.stereo_width, param, oj.apply_value);
        },
        .none => return,
    }
    ctx.project.revision += 1;
    ui.markDirty(ctx.view);
    if (decision == 2 and !ctx.trial_registry.hasActive()) {
        // Open a lightweight awaiting-human trial so confirm/reject still work.
        const start: u64 = 0;
        const len: u64 = 1;
        _ = ctx.trial_registry.begin(ctx.project, null, start, len, .{}, "") catch {};
        ctx.trial_registry.markAwaitingHuman() catch {};
    }
}

/// Moves a worker-computed passed preflight (see enqueueOfflineMasterQc's
/// Work.run) onto the live mix_gate. If the project changed underneath it
/// (revision moved on) the gate is discarded rather than trusted stale --
/// same conflict handling as applyOfflineAssessToLive.
fn applyOfflinePreflightGateToLive(ctx: *DispatchCtx, oj: *offline_audio.Job) void {
    var pg = oj.pending_gate orelse return;
    oj.pending_gate = null;
    if (ctx.project.revision != oj.revision_at_start) {
        pg.clear(ctx.gpa);
        return;
    }
    ctx.mix_gate.clear(ctx.gpa);
    ctx.mix_gate.* = pg;
}

fn enqueueOfflineAssess(
    ctx: *DispatchCtx,
    kind: offline_audio.Kind,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    if (ctx.offline_registry.busy()) return errResp(response_buf, id, "offline_job_busy");
    if (ctx.trial_registry.hasActive()) return errResp(response_buf, id, "trial_already_open");

    const args_val: std.json.Value = args orelse .{ .null = {} };
    const args_text = std.json.Stringify.valueAlloc(ctx.gpa, args_val, .{}) catch return errResp(response_buf, id, "oom");
    errdefer ctx.gpa.free(args_text);

    const effect_id = getU64(args, "effect_id") orelse {
        ctx.gpa.free(args_text);
        return errResp(response_buf, id, "missing_effect_id");
    };
    const param = getStr(args, "param") orelse {
        ctx.gpa.free(args_text);
        return errResp(response_buf, id, "missing_param");
    };
    const track_id = getU64(args, "track_id") orelse 0;
    const bus_id = getU64(args, "bus_id") orelse 0;
    const band_index_u = getU64(args, "band_index") orelse 0;

    // EQ's `band_type` is a string, not a float -- encode the new enum's
    // ordinal into apply_value; applyOfflineAssessToLive checks the param
    // name to know it needs decoding back via @enumFromInt instead of being
    // used as a plain number, matching handleEqAssessAndAdjust's own parsing.
    const is_eq_band_type = kind == .eq_assess and std.mem.eql(u8, param, "band_type");
    var apply_value_f32: f32 = 0;
    if (is_eq_band_type) {
        const value_field = getField(args, "value");
        const s = if (value_field) |v| (if (v == .string) v.string else null) else getStr(args, "band_type");
        const parsed_type = parseEqBandType(s orelse {
            ctx.gpa.free(args_text);
            return errResp(response_buf, id, "missing_value");
        }) orelse {
            ctx.gpa.free(args_text);
            return errResp(response_buf, id, "invalid_band_type");
        };
        apply_value_f32 = @floatFromInt(@intFromEnum(parsed_type));
    } else {
        const new_value_f64 = getF64(args, "value") orelse {
            ctx.gpa.free(args_text);
            return errResp(response_buf, id, "missing_value");
        };
        apply_value_f32 = @floatCast(new_value_f64);
    }

    const apply_target: offline_audio.ApplyTarget = switch (kind) {
        .master_compressor_assess => .master_compressor,
        .compressor_assess => .track_compressor,
        .bus_compressor_assess => .bus_compressor,
        .master_limiter_assess => .master_limiter,
        .sidechain_assess => .track_sidechain,
        .eq_assess => .track_eq,
        .stereo_width_assess => if (getU64(args, "track_id") != null)
            .track_stereo_width
        else if (getU64(args, "bus_id") != null)
            .bus_stereo_width
        else
            .master_stereo_width,
        else => .none,
    };

    const reg = ctx.offline_registry;
    const job_id = reg.next_id;
    reg.next_id += 1;
    if (reg.job.result_json) |old| reg.gpa.free(old);
    reg.discardPendingGate();
    reg.job = .{
        .id = job_id,
        .kind = kind,
        .revision_at_start = ctx.project.revision,
        .status = .init(@intFromEnum(offline_audio.Status.running)),
        .apply_target = apply_target,
        .apply_effect_id = effect_id,
        .apply_track_id = track_id,
        .apply_bus_id = bus_id,
        .apply_band_index = @intCast(@min(band_index_u, 255)),
        .apply_value = apply_value_f32,
        .apply_param_len = @intCast(@min(param.len, 64)),
    };
    @memcpy(reg.job.apply_param[0..reg.job.apply_param_len], param[0..reg.job.apply_param_len]);

    const Work = struct {
        gpa: std.mem.Allocator,
        reg: *offline_audio.Registry,
        project: model.Project,
        asset_cache: *mixer.AssetCache,
        kind: offline_audio.Kind,
        args_text: []u8,
        id: i64,
        op_id: u64,
        revision_before: u64,
        applied_at_audio_frame: u64,
        sample_rate: u32,
        audio_diag: *AudioDiag,
        sc_rt: *mixer.SidechainRuntime,

        fn run(self: *@This()) void {
            defer {
                self.gpa.free(self.args_text);
                self.project.deinit(self.gpa);
                self.gpa.destroy(self);
            }
            const t0 = offline_audio.nowNs();
            const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.args_text, .{}) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                self.reg.job.err_msg = "bad_args";
                return;
            };
            defer parsed.deinit();

            var transport: ui.Transport = .stop;
            var beat_time: f64 = 0;
            var history: persist.History = .{};
            defer history.deinit(self.gpa);
            var job_registry: jobs.Registry = .{};
            defer job_registry.deinit(self.gpa);
            var nested_offline = offline_audio.Registry.init(self.gpa);
            defer nested_offline.deinit();
            var pending: std.ArrayList(PendingImport) = .empty;
            defer pending.deinit(self.gpa);
            var render_state: RenderState = .{};
            var live_peaks: LivePeaks = .{};
            var view: ui.View = .{};
            var local_trial = trial.Registry.init(self.gpa);
            defer local_trial.deinit();
            var local_gate: mix_preflight.MixSessionGate = .{};
            defer local_gate.clear(self.gpa);
            var project_path: ?[]const u8 = null;
            var frame_count: u64 = 0;
            var operation_counter: u64 = self.op_id;
            var local_diag: AudioDiag = .{};

            // io is unused by assess handlers; pass a dummy via threaded.
            var threaded = std.Io.Threaded.init(self.gpa, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var fake = DispatchCtx{
                .gpa = self.gpa,
                .io = io,
                .project = &self.project,
                .project_path = &project_path,
                .history = &history,
                .asset_cache = self.asset_cache,
                .job_registry = &job_registry,
                .offline_registry = &nested_offline,
                .pending_imports = &pending,
                .render_state = &render_state,
                .transport = &transport,
                .beat_time = &beat_time,
                .live_peaks = &live_peaks,
                .audio_diag = &local_diag,
                .view = &view,
                .sc_rt = self.sc_rt,
                .trial_registry = &local_trial,
                .frame_count = &frame_count,
                .operation_counter = &operation_counter,
                .mix_gate = &local_gate,
            };

            var resp: [65536]u8 = undefined;
            const out = switch (self.kind) {
                .master_compressor_assess => handleMasterCompressorAssessAndAdjust(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                .master_limiter_assess => handleMasterLimiterAssessAndAdjust(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                .bus_compressor_assess => handleBusCompressorAssessAndAdjust(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                .compressor_assess => handleCompressorAssessAndAdjust(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                .sidechain_assess => handleSidechainAssessAndAdjust(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                .eq_assess => handleEqAssessAndAdjust(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                .stereo_width_assess => handleStereoWidthAssessAndAdjust(&fake, parsed.value, self.id, self.op_id, self.revision_before, self.applied_at_audio_frame, &resp),
                else => {
                    self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                    self.reg.job.err_msg = "bad_kind";
                    return;
                },
            };
            const ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t0)) / 1e6;
            self.reg.job.trial_duration_ms = ms;
            self.reg.job.level_match_duration_ms = local_diag.level_match_duration_ms;
            self.audio_diag.trial_duration_ms = ms;
            self.audio_diag.level_match_duration_ms = local_diag.level_match_duration_ms;

            if (std.mem.indexOf(u8, out, "\"ok\":false") != null) {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                self.reg.job.err_msg = "assess_failed";
                const owned_err = self.gpa.dupe(u8, out) catch return;
                self.reg.job.result_json = owned_err;
                return;
            }

            // Extract result object for payload + decision.
            const env = std.json.parseFromSlice(std.json.Value, self.gpa, out, .{}) catch {
                self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                return;
            };
            defer env.deinit();
            const result_v = if (env.value == .object) env.value.object.get("result") else null;
            if (result_v) |rv| {
                if (rv == .object) {
                    if (rv.object.get("decision")) |d| {
                        if (d == .string) self.reg.job.apply_decision = decisionFromStr(d.string);
                    }
                }
                const owned = std.json.Stringify.valueAlloc(self.gpa, rv, .{}) catch {
                    self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                    return;
                };
                self.reg.job.result_json = owned;
            } else {
                const owned = self.gpa.dupe(u8, out) catch {
                    self.reg.job.status.store(@intFromEnum(offline_audio.Status.failed), .release);
                    return;
                };
                self.reg.job.result_json = owned;
            }
            self.reg.job.revision_at_compute = self.project.revision;
            self.reg.job.status.store(@intFromEnum(offline_audio.Status.succeeded), .release);
            _ = self.sample_rate;
        }
    };

    const snap = offline_audio.cloneProject(ctx.gpa, ctx.project) catch {
        ctx.gpa.free(args_text);
        return errResp(response_buf, id, "snapshot_failed");
    };
    const work = ctx.gpa.create(Work) catch {
        var p = snap;
        p.deinit(ctx.gpa);
        ctx.gpa.free(args_text);
        return errResp(response_buf, id, "oom");
    };
    work.* = .{
        .gpa = ctx.gpa,
        .reg = reg,
        .project = snap,
        .asset_cache = ctx.asset_cache,
        .kind = kind,
        .args_text = args_text,
        .id = id,
        .op_id = op_id,
        .revision_before = revision_before,
        .applied_at_audio_frame = applied_at_audio_frame,
        .sample_rate = ctx.project.sample_rate,
        .audio_diag = ctx.audio_diag,
        .sc_rt = ctx.sc_rt,
    };
    const th = std.Thread.spawn(.{}, Work.run, .{work}) catch {
        work.project.deinit(ctx.gpa);
        ctx.gpa.free(work.args_text);
        ctx.gpa.destroy(work);
        reg.job.status.store(@intFromEnum(offline_audio.Status.idle), .release);
        return errResp(response_buf, id, "thread_spawn_failed");
    };
    reg.job.thread = th;
    return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"job_id\":{d},\"status\":\"running\",\"kind\":\"{s}\",\"revision_at_start\":{d}}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, job_id, kind.name(), revision_before }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
}

/// Master-bus compressor assess (trial snapshot). Measures master_pre_fx + master_output.
fn handleMasterCompressorAssessAndAdjust(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const effect_id = getU64(args, "effect_id") orelse return errResp(response_buf, id, "missing_effect_id");
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    const param = getStr(args, "param") orelse return errResp(response_buf, id, "missing_param");
    const new_value_f64 = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
    if (ctx.trial_registry.hasActive()) return errResp(response_buf, id, "trial_already_open");

    const constraints_obj = getField(args, "constraints") orelse args;
    const gr_peak_min: f32 = @floatCast(getF64(constraints_obj, "gr_peak_min_db") orelse 0.5);
    const gr_peak_max: f32 = @floatCast(getF64(constraints_obj, "gr_peak_max_db") orelse 3.0);
    const gr_mean_active_max: f32 = @floatCast(getF64(constraints_obj, "gr_mean_active_max_db") orelse 2.0);
    const max_rms_change: f32 = @floatCast(getF64(constraints_obj, "max_rms_change_db") orelse 1.5);
    const max_peak: f32 = @floatCast(getF64(constraints_obj, "max_peak_dbfs") orelse -0.1);
    const max_active_ratio: f32 = @floatCast(getF64(constraints_obj, "max_active_ratio") orelse 1.0);
    const force_human = getBool(args, "require_human_listening") orelse needsHumanCompressorParam(param);

    const effect = for (ctx.project.master_effects.items) |*e| {
        if (e.id == effect_id) break e;
    } else return errResp(response_buf, id, "effect_not_found");
    if (effect.params != .compressor) return errResp(response_buf, id, "effect_not_compressor");
    const old_value = getCompressorParam(effect.params.compressor, param) orelse return errResp(response_buf, id, "unknown_param");
    const new_value: f32 = @floatCast(new_value_f64);

    const pre_target: MeasureTarget = .{ .master = .master_pre_fx };
    const out_target: MeasureTarget = .{ .master = .master_output };

    const before_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(before_buf);
    const before_pre = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, pre_target, start_frame, length_frames, ctx.project.sample_rate, null, ctx.view.fx_bypass_all) catch
        return errResp(response_buf, id, "measure_failed");
    const before_out = measureRangeObserving(ctx.gpa, ctx.project, ctx.asset_cache, out_target, start_frame, length_frames, ctx.project.sample_rate, before_buf, effect_id, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, measureErrStr(e));

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    var before_path_buf: [256]u8 = undefined;
    const provisional = ctx.trial_registry.next_id;
    const before_path_z = std.fmt.bufPrintZ(&before_path_buf, ".cache/audition/master_comp_trial_{d}_before_master.wav", .{provisional}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_buf, length_frames, ctx.project.sample_rate, before_path_z)) return errResp(response_buf, id, "export_failed");

    const trial_id = ctx.trial_registry.begin(ctx.project, null, start_frame, length_frames, rangeStatsToTrial(before_out), before_path_z) catch
        return errResp(response_buf, id, "trial_begin_failed");

    if (!setCompressorParam(&effect.params.compressor, param, new_value)) {
        ctx.trial_registry.close();
        return errResp(response_buf, id, "unknown_param");
    }
    ctx.project.revision += 1;
    const revision_after = ctx.project.revision;
    ui.markDirty(ctx.view);

    const after_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(after_buf);
    const after_out = measureRangeObserving(ctx.gpa, ctx.project, ctx.asset_cache, out_target, start_frame, length_frames, ctx.project.sample_rate, after_buf, effect_id, ctx.view.fx_bypass_all) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "measure_failed");
    };

    var after_raw_buf: [256]u8 = undefined;
    const after_raw_z = std.fmt.bufPrintZ(&after_raw_buf, ".cache/audition/master_comp_trial_{d}_after_master_raw.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_buf, length_frames, ctx.project.sample_rate, after_raw_z)) return errResp(response_buf, id, "export_failed");

    const match_gain = trial.Registry.levelMatchGainDb(before_out.rms_dbfs, after_out.rms_dbfs);
    const t_lm0 = offline_audio.nowNs();
    const after_matched = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(after_matched);
    @memcpy(after_matched, after_buf);
    applyGainToStereoBuf(after_matched, match_gain);
    ctx.audio_diag.level_match_duration_ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t_lm0)) / 1e6;
    var after_matched_buf: [256]u8 = undefined;
    const after_matched_z = std.fmt.bufPrintZ(&after_matched_buf, ".cache/audition/master_comp_trial_{d}_after_master_level_matched.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_matched, length_frames, ctx.project.sample_rate, after_matched_z)) return errResp(response_buf, id, "export_failed");

    const gr_peak = after_out.comp_gr_peak_db orelse 0;
    const gr_mean = after_out.comp_gr_mean_active_db orelse 0;
    const active_ratio = after_out.comp_active_sample_ratio orelse 0;
    const rms_change = @abs(after_out.rms_dbfs - before_out.rms_dbfs);
    const gr_ok = gr_peak >= gr_peak_min and gr_peak <= gr_peak_max and gr_mean <= gr_mean_active_max;
    const level_ok = rms_change <= max_rms_change and after_out.peak_dbfs <= max_peak and active_ratio <= max_active_ratio;
    const objectives_ok = gr_ok and level_ok;

    var decision: trial.Decision = undefined;
    var human_q: []const u8 = "";
    if (!objectives_ok) {
        if (ctx.project.revision != revision_after) {
            decision = .conflict;
            ctx.trial_registry.close();
        } else {
            ctx.trial_registry.restoreSnapshot(ctx.project) catch return errResp(response_buf, id, "restore_failed");
            ui.markDirty(ctx.view);
            ctx.trial_registry.close();
            decision = .rolled_back;
        }
    } else if (force_human) {
        decision = .needs_human_listening;
        human_q = "Does the RMS-level-matched after version preserve the mix transients and movement better than before, without sounding flattened or pumping?";
        ctx.trial_registry.markAwaitingHuman() catch {};
    } else {
        decision = .committed;
        ctx.trial_registry.close();
    }

    var final_param: f32 = old_value;
    for (ctx.project.master_effects.items) |e| {
        if (e.id == effect_id and e.params == .compressor) {
            final_param = getCompressorParam(e.params.compressor, param) orelse old_value;
        }
    }

    var reason_buf: [640]u8 = undefined;
    var reason_w: std.Io.Writer = .fixed(&reason_buf);
    switch (decision) {
        .committed => reason_w.writeAll("Master compressor behavior is within the requested technical limits on this selected range. This is not a claim that the master sounds better or is release-ready.") catch {},
        .rolled_back => reason_w.print("rolled_back: constraint failed (gr_peak={d:.2} rms_change={d:.2} peak={d:.2})", .{ gr_peak, rms_change, after_out.peak_dbfs }) catch {},
        .needs_human_listening => reason_w.writeAll("Objectives passed; attack/release/mix character require human listening on level-matched A/B.") catch {},
        .conflict => reason_w.writeAll("conflict: project revision changed before rollback; foreign changes were not undone.") catch {},
    }

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"trial_id\":{d},\"effect_id\":{d},\"param\":\"{s}\",\"old_value\":{d},\"new_value\":{d},\"final_value\":{d}," ++
        "\"window_start_frame\":{d},\"window_length_frames\":{d},\"decision\":\"{s}\",\"reason\":\"{s}\",\"human_question\":\"{s}\"," ++
        "\"level_match\":{{\"method\":\"rms\",\"reference\":\"before\",\"applied_gain_db\":{d:.2}}}," ++
        "\"before_pre_fx\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2}}}," ++
        "\"before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2}", .{
        id,                   ctx.project.revision,
        op_id,                revision_before,
        applied_at_audio_frame, trial_id,
        effect_id,            param,
        old_value,            new_value,
        final_param,          start_frame,
        length_frames,        decisionStr(decision),
        reason_w.buffered(),  human_q,
        match_gain,      before_pre.peak_dbfs,
        before_pre.rms_dbfs,
        before_out.peak_dbfs,
        before_out.rms_dbfs,
    }) catch {};
    w.writeAll(",\"gain_reduction_peak_db\":") catch {};
    writeRangeStatsTail(&w, before_out);
    w.writeAll("},\"after\":{\"peak_dbfs\":") catch {};
    w.print("{d:.2},\"rms_dbfs\":{d:.2}", .{ after_out.peak_dbfs, after_out.rms_dbfs }) catch {};
    w.writeAll(",\"gain_reduction_peak_db\":") catch {};
    writeRangeStatsTail(&w, after_out);
    w.print("}},\"before_master_audition_path\":\"{s}\",\"after_master_raw_audition_path\":\"{s}\",\"after_master_level_matched_path\":\"{s}\"}}}}", .{
        before_path_z, after_raw_z, after_matched_z,
    }) catch {};
    return w.buffered();
}

fn parseDeliveryProfile(args: ?std.json.Value) master_qc.DeliveryProfile {
    var p: master_qc.DeliveryProfile = .{};
    const prof = getField(args, "profile") orelse return p;
    if (getStr(prof, "name")) |n| p.name = n;
    if (getF64(prof, "target_integrated_lufs")) |v| p.target_integrated_lufs = @floatCast(v);
    if (getF64(prof, "tolerance_lu")) |v| p.tolerance_lu = @floatCast(v);
    if (getF64(prof, "max_true_peak_dbtp")) |v| p.max_true_peak_dbtp = @floatCast(v);
    if (getStr(prof, "source")) |s| p.source = s;
    return p;
}

fn scanF32AfterKey(hay: []const u8, key: []const u8) ?f32 {
    const ei = std.mem.indexOf(u8, hay, key) orelse return null;
    var p = ei + key.len;
    while (p < hay.len and (hay[p] == ' ' or hay[p] == ':')) : (p += 1) {}
    if (p < hay.len and hay[p] == 'n') return null; // null
    var end = p;
    while (end < hay.len and ((hay[end] >= '0' and hay[end] <= '9') or hay[end] == '-' or hay[end] == '+' or hay[end] == '.' or hay[end] == 'e' or hay[end] == 'E')) : (end += 1) {}
    return std.fmt.parseFloat(f32, hay[p..end]) catch null;
}

fn applyMasterQcJsonToView(view: *ui.View, json: []const u8) void {
    if (scanF32AfterKey(json, "\"sample_peak_dbfs\"")) |v| view.master_qc_sample_peak_dbfs = v;
    if (scanF32AfterKey(json, "\"true_peak_dbtp\"")) |v| view.master_qc_true_peak_dbtp = v;
    if (scanF32AfterKey(json, "\"short_term_lufs\"")) |v| view.master_qc_short_lufs = v;
    if (scanF32AfterKey(json, "\"integrated_lufs\"")) |v| {
        view.master_qc_integrated_lufs = v;
        view.master_qc_has_integrated = true;
    }
    if (scanF32AfterKey(json, "\"lra_lu\"")) |v| {
        view.master_qc_lra_lu = v;
        view.master_qc_has_lra = true;
    }
    const done = "Analyze done";
    @memcpy(view.master_qc_status[0..done.len], done);
    view.master_qc_status_len = done.len;
}

fn handleMixSessionPreflight(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    var opts: mix_preflight.PreflightOpts = .{};
    if (getU64(args, "window_frames")) |v| opts.window_frames = v;
    if (getU64(args, "hop_frames")) |v| opts.hop_frames = v;
    if (getU64(args, "max_scan_frames")) |v| opts.max_scan_frames = v;
    if (getF64(args, "quiet_rms_dbfs")) |v| opts.quiet_rms_dbfs = @floatCast(v);
    if (getF64(args, "lead_active_rms_dbfs")) |v| opts.lead_active_rms_dbfs = @floatCast(v);

    var result = mix_preflight.runPreflight(ctx.gpa, ctx.project, ctx.asset_cache, opts) catch
        return errResp(response_buf, id, "preflight_failed");
    defer mix_preflight.freePreflightResult(ctx.gpa, &result);

    ctx.mix_gate.clear(ctx.gpa);
    if (result.decision == .passed) {
        ctx.mix_gate.storePassed(ctx.gpa, &result) catch {};
    }

    const decision_str: []const u8 = switch (result.decision) {
        .passed => "passed",
        .abstained => "abstained",
    };
    const timing_str: []const u8 = switch (result.timing_status) {
        .relative_alignment_verified => "relative_alignment_verified",
        .unverified => "unverified",
    };

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"decision\":\"{s}\",\"status\":\"{s}\",\"timing_status\":\"{s}\",\"revision\":{d},\"sample_rate\":{d}," ++
        "\"vocal_section_count\":{d},\"analysis_scope_note\":\"{s}\",\"presence_band_note\":\"{s}\",", .{
        id,
        ctx.project.revision,
        op_id,
        revision_before,
        applied_at_audio_frame,
        decision_str,
        decision_str,
        timing_str,
        result.revision,
        result.sample_rate,
        result.vocal_section_count,
        result.analysis_scope_note,
        result.presence_band_note,
    }) catch {};
    // Structured timing evidence (shared global offset is not a failure).
    w.print("\"timing\":{{\"mode\":\"{s}\",\"global_offset_frames\":{d},\"relative_alignment_verified\":{},\"lead_outlier\":{},\"source_offsets_consistent\":{},\"sample_rates_consistent\":{},\"all_stems_share_same_offset\":{}}},", .{
        result.timing.mode,
        result.timing.global_offset_frames,
        result.timing.relative_alignment_verified,
        result.timing.lead_outlier,
        result.timing.source_offsets_consistent,
        result.timing.sample_rates_consistent,
        result.timing.all_stems_share_same_offset,
    }) catch {};
    if (result.decision == .passed) {
        w.writeAll("\"allowed_next_actions\":[\"analyze_mix_sections\",\"lead_vocal_balance_assess\"],\"blocked_actions\":[],") catch {};
        w.writeAll("\"required_next_action\":{\"kind\":\"analyze_mix_sections\",\"safe_to_continue\":true},") catch {};
    } else {
        w.writeAll("\"allowed_next_actions\":[\"inspect_timing\",\"repair_timing_candidate\"],\"blocked_actions\":[\"analyze_mix_sections\",\"lead_vocal_balance_assess\"],") catch {};
        const reason0: []const u8 = if (result.blocking_reasons.len > 0) result.blocking_reasons[0] else "preflight_abstained";
        w.print("\"reason\":\"{s}\",\"required_next_action\":{{\"kind\":\"inspect_timing\",\"safe_to_continue\":false}},\"evidence\":{{\"lead_track_id\":", .{reason0}) catch {};
        if (result.lead_track_id) |lid| w.print("{d}", .{lid}) catch {} else w.writeAll("null") catch {};
        w.print(",\"timeline_start_frame\":{d},\"global_offset_frames\":{d},\"all_stems_share_same_offset\":{},\"lead_outlier\":{}}},", .{
            result.timing.global_offset_frames,
            result.timing.global_offset_frames,
            result.timing.all_stems_share_same_offset,
            result.timing.lead_outlier,
        }) catch {};
    }
    if (result.lead_track_id) |lid| w.print("\"lead_track_id\":{d},", .{lid}) catch {} else w.writeAll("\"lead_track_id\":null,") catch {};
    if (result.lead_track_name) |n| w.print("\"lead_track_name\":\"{s}\",", .{n}) catch {} else w.writeAll("\"lead_track_name\":null,") catch {};
    w.writeAll("\"blocking_reasons\":[") catch {};
    for (result.blocking_reasons, 0..) |a, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("\"{s}\"", .{a}) catch {};
    }
    w.writeAll("],\"checks\":[") catch {};
    for (result.checks, 0..) |ch, i| {
        if (i > 0) w.writeAll(",") catch {};
        const st: []const u8 = switch (ch.status) {
            .pass => "pass",
            .fail => "fail",
        };
        w.print("{{\"name\":\"{s}\",\"status\":\"{s}\",\"detail\":\"{s}\"", .{ ch.name, st, ch.detail }) catch {};
        if (ch.track_id) |tid| w.print(",\"track_id\":{d}", .{tid}) catch {};
        w.writeAll("}") catch {};
    }
    w.writeAll("],\"key_tracks\":[") catch {};
    for (result.key_tracks, 0..) |kt, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"role\":\"{s}\",\"present\":{},\"muted\":{},\"volume\":{d:.4},\"pan\":{d:.4},\"active_region_count\":{d}", .{
            kt.role,
            kt.present,
            kt.muted,
            kt.volume,
            kt.pan,
            kt.active_region_count,
        }) catch {};
        if (kt.track_id) |tid| w.print(",\"track_id\":{d}", .{tid}) catch {} else w.writeAll(",\"track_id\":null") catch {};
        if (kt.name) |n| w.print(",\"name\":\"{s}\"", .{n}) catch {} else w.writeAll(",\"name\":null") catch {};
        w.print(",\"timeline_start_frame\":{d},\"source_offset_frames\":{d}", .{ kt.timeline_start_frame, kt.source_offset_frames }) catch {};
        w.writeAll("}") catch {};
    }
    w.writeAll("],\"sections\":[") catch {};
    for (result.sections, 0..) |sec, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"id\":{d},\"kind\":\"{s}\",\"start_frame\":{d},\"length_frames\":{d},\"lead_active\":{},\"lead_rms_dbfs\":{d:.2},\"instrumental_rms_dbfs\":{d:.2},\"master_rms_dbfs\":{d:.2},\"section_confidence\":{d:.2},\"selection_reason\":\"{s}\",\"valid_for_vocal_balance\":{},\"active_tracks\":[", .{
            sec.id,
            sec.kind,
            sec.start_frame,
            sec.length_frames,
            sec.lead_active,
            sec.lead_rms_dbfs,
            sec.instrumental_rms_dbfs,
            sec.master_rms_dbfs,
            sec.section_confidence,
            sec.selection_reason,
            sec.valid_for_vocal_balance,
        }) catch {};
        for (sec.active_tracks, 0..) |n, j| {
            if (j > 0) w.writeAll(",") catch {};
            w.print("\"{s}\"", .{n}) catch {};
        }
        w.writeAll("]}") catch {};
    }
    // Keep suggested_ranges alias for older clients: first vocal-valid sections
    w.writeAll("],\"suggested_ranges\":[") catch {};
    var written: usize = 0;
    for (result.sections) |sec| {
        if (!sec.valid_for_vocal_balance) continue;
        if (written > 0) w.writeAll(",") catch {};
        w.print("{{\"reason\":\"{s}\",\"start_frame\":{d},\"length_frames\":{d},\"master_rms_dbfs\":{d:.2}}}", .{
            sec.kind,
            sec.start_frame,
            sec.length_frames,
            sec.master_rms_dbfs,
        }) catch {};
        written += 1;
    }
    w.writeAll("]}}") catch {};
    return w.buffered();
}

fn writeTrackMetrics(w: *std.Io.Writer, m: mix_sections.TrackMetrics) void {
    w.print("{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"crest_factor_db\":{d:.2},\"presence_250_500\":{d:.2},\"presence_500_1000\":{d:.2},\"presence_1k_2k\":{d:.2},\"presence_2k_4k\":{d:.2},\"presence_4k_8k\":{d:.2}}}", .{
        m.peak_dbfs, m.rms_dbfs, m.crest_factor_db, m.presence_250_500, m.presence_500_1000, m.presence_1k_2k, m.presence_2k_4k, m.presence_4k_8k,
    }) catch {};
}

fn handleAnalyzeMixSections(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    if (ctx.mix_gate.requirePassed(ctx.project.revision)) |e| return errResp(response_buf, id, e);
    const lead_id = getU64(args, "lead_track_id") orelse ctx.mix_gate.lead_track_id orelse return errResp(response_buf, id, "missing_lead_track_id");

    var use_secs: std.ArrayList(mix_preflight.Section) = .empty;
    defer use_secs.deinit(ctx.gpa);
    if (getField(args, "section_ids")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |v| {
                if (v != .integer) continue;
                const sid: u64 = @intCast(v.integer);
                for (ctx.mix_gate.sections) |s| {
                    if (s.id == sid) use_secs.append(ctx.gpa, s) catch {};
                }
            }
        }
    } else {
        for (ctx.mix_gate.sections) |s| {
            if (s.valid_for_vocal_balance) use_secs.append(ctx.gpa, s) catch {};
        }
    }
    if (use_secs.items.len == 0) return errResp(response_buf, id, "no_sections");

    var analysis = mix_sections.analyzeSections(ctx.gpa, ctx.project, ctx.asset_cache, lead_id, use_secs.items) catch
        return errResp(response_buf, id, "analyze_mix_sections_failed");
    defer mix_sections.freeAnalysis(ctx.gpa, &analysis);

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"revision\":{d},\"masking_status\":\"{s}\",\"section_variance_db\":{d:.2},\"lead_to_instrumental_mean_db\":{d:.2},\"sections\":[", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame,
        analysis.revision, analysis.masking_status, analysis.section_variance_db, analysis.lead_to_instrumental_mean_db,
    }) catch {};
    for (analysis.sections, 0..) |sec, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"section_id\":{d},\"start_frame\":{d},\"length_frames\":{d},\"lead_to_instrumental_rms_db\":{d:.2},\"lead_presence_energy_db\":{d:.2},\"instrumental_presence_energy_db\":{d:.2},\"presence_delta_db\":{d:.2},\"masking_status\":\"{s}\",\"lead\":", .{
            sec.section_id, sec.start_frame, sec.length_frames, sec.lead_to_instrumental_rms_db, sec.lead_presence_energy_db, sec.instrumental_presence_energy_db, sec.presence_delta_db, sec.masking_status,
        }) catch {};
        writeTrackMetrics(&w, sec.lead);
        w.writeAll(",\"instrumental\":") catch {};
        writeTrackMetrics(&w, sec.instrumental);
        w.writeAll(",\"master\":") catch {};
        writeTrackMetrics(&w, sec.master);
        if (sec.guitar) |g| {
            w.writeAll(",\"guitar\":") catch {};
            writeTrackMetrics(&w, g);
        }
        if (sec.synth) |s| {
            w.writeAll(",\"synth\":") catch {};
            writeTrackMetrics(&w, s);
        }
        if (sec.bass) |b| {
            w.writeAll(",\"bass\":") catch {};
            writeTrackMetrics(&w, b);
        }
        if (sec.drums) |d| {
            w.writeAll(",\"drums\":") catch {};
            writeTrackMetrics(&w, d);
        }
        w.writeAll("}") catch {};
    }
    w.writeAll("],\"allowed_next_actions\":[\"lead_vocal_balance_assess\"],\"blocked_actions\":[]}}") catch {};
    return w.buffered();
}

fn handleLeadVocalBalanceAssess(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const pref_rev = getU64(args, "preflight_revision") orelse return errResp(response_buf, id, "missing_preflight_revision");
    var constraints: vocal_balance.Constraints = .{};
    if (getField(args, "constraints")) |cons| {
        if (getF64(cons, "min_mean_delta_improvement_db")) |v| constraints.min_mean_delta_improvement_db = @floatCast(v);
        if (getF64(cons, "max_true_peak_dbtp")) |v| constraints.max_true_peak_dbtp = @floatCast(v);
        if (getF64(cons, "max_master_peak_dbfs")) |v| constraints.max_master_peak_dbfs = @floatCast(v);
        if (getBool(cons, "require_human_listening")) |v| constraints.require_human_listening = v;
    }
    var filter_buf: [16]u64 = undefined;
    var filter_n: usize = 0;
    var filter_slice: ?[]const u64 = null;
    if (getField(args, "section_ids")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |v| {
                if (v == .integer and filter_n < filter_buf.len) {
                    filter_buf[filter_n] = @intCast(v.integer);
                    filter_n += 1;
                }
            }
            if (filter_n > 0) filter_slice = filter_buf[0..filter_n];
        }
    }

    ctx.history.recordBeforeMutation(ctx.gpa, ctx.project) catch {};
    var result = vocal_balance.runAssess(ctx.gpa, ctx.project, ctx.asset_cache, ctx.mix_gate, pref_rev, filter_slice, constraints) catch
        return errResp(response_buf, id, "vocal_balance_failed");
    defer vocal_balance.freeTrialResult(ctx.gpa, &result);

    // Keep gate revision in sync after mutation/rollback bumps revision
    if (ctx.mix_gate.passed) ctx.mix_gate.revision = ctx.project.revision;

    const decision_str: []const u8 = switch (result.decision) {
        .committed => "committed",
        .rolled_back => "rolled_back",
        .needs_human_listening => "needs_human_listening",
        .abstained => "abstained",
    };

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"decision\":\"{s}\",\"reason\":\"{s}\",\"classification\":\"{s}\",\"masking_status\":\"{s}\"", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame,
        decision_str, result.reason, result.classification, result.masking_status,
    }) catch {};
    if (result.candidate) |cand| {
        const kind: []const u8 = switch (cand.kind) {
            .set_lead_track_volume => "set_lead_track_volume",
            .set_lead_region_gain => "set_lead_region_gain",
            .reduce_competing_track_volume => "reduce_competing_track_volume",
            .reduce_competing_eq_band => "reduce_competing_eq_band",
        };
        w.print(",\"candidate_operation\":{{\"kind\":\"{s}\",\"track_id\":{d},\"value\":{d:.4},\"detail\":\"{s}\"}}", .{ kind, cand.track_id, cand.value, cand.detail }) catch {};
    }
    if (result.before) |b| {
        w.print(",\"before\":{{\"lead_to_instrumental_mean_db\":{d:.2},\"section_variance_db\":{d:.2}}}", .{ b.lead_to_instrumental_mean_db, b.section_variance_db }) catch {};
    }
    if (result.after) |a| {
        w.print(",\"after\":{{\"lead_to_instrumental_mean_db\":{d:.2},\"section_variance_db\":{d:.2}}}", .{ a.lead_to_instrumental_mean_db, a.section_variance_db }) catch {};
    }
    w.writeAll(",\"auditions\":[") catch {};
    for (result.ab_paths, 0..) |path, i| {
        if (i > 0) w.writeAll(",") catch {};
        const role: []const u8 = if (std.mem.indexOf(u8, path, "before") != null) "before" else "after_level_matched";
        w.print("{{\"path\":\"{s}\",\"role\":\"{s}\"}}", .{ path, role }) catch {};
    }
    w.writeAll("],\"ab_paths\":[") catch {};
    for (result.ab_paths, 0..) |path, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("\"{s}\"", .{path}) catch {};
    }
    if (result.decision == .needs_human_listening) {
        w.writeAll("],\"question\":\"In these three matched sections, is the Lead easier to understand without competing sources sounding unnaturally recessed?\",") catch {};
        w.writeAll("\"allowed_next_actions\":[\"confirm_trial\",\"reject_trial\"],\"blocked_actions\":[\"lead_vocal_balance_assess\"],") catch {};
    } else if (result.decision == .committed) {
        w.writeAll("],\"allowed_next_actions\":[\"validate_master_delivery\"],\"blocked_actions\":[],") catch {};
    } else {
        w.writeAll("],\"allowed_next_actions\":[\"mix_session_preflight\"],\"blocked_actions\":[],") catch {};
    }
    w.writeAll("\"discovery_master_wav\":null,\"note\":\"no general 30s master WAV used for discovery\"}}") catch {};
    return w.buffered();
}

fn handleAnalyzeMasterProgram(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const start_frame = getU64(args, "start_frame") orelse 0;
    const length_opt = getU64(args, "length_frames");
    const t0 = offline_audio.nowNs();
    const analysis = master_qc.analyzeProgram(ctx.gpa, ctx.project, ctx.asset_cache, start_frame, length_opt) catch |e| {
        return errResp(response_buf, id, if (e == error.RangeTooLarge) "length_frames_too_large" else if (e == error.EmptyRange) "empty_range" else "analyze_failed");
    };
    ctx.audio_diag.measure_duration_ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t0)) / 1e6;
    const lr = analysis.loud;
    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"revision\":{d},\"window_start_frame\":{d},\"window_length_frames\":{d}," ++
        "\"sample_peak_dbfs\":{d:.2},\"true_peak_dbtp\":{d:.2},\"true_peak_oversample_factor\":{d}," ++
        "\"integrated_lufs\":", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame,
        analysis.revision, analysis.window_start_frame, analysis.window_length_frames,
        lr.sample_peak_dbfs, lr.true_peak_dbtp, lr.true_peak_oversample_factor,
    }) catch {};
    if (lr.integrated_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"short_term_lufs\":") catch {};
    if (lr.short_term_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"momentary_lufs\":") catch {};
    if (lr.momentary_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.writeAll(",\"lra_lu\":") catch {};
    if (lr.lra_lu) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.print(",\"crest_factor_db\":{d:.2},\"clipped_samples\":{d}," ++
        "\"state_initialization\":{{\"mode\":\"{s}\",\"exact_from_project_start\":{}}}," ++
        "\"loudness\":{{\"standard\":\"{s}\",\"gated\":{},\"analysis_scope\":\"{s}\"}}}}}}", .{
        lr.crest_factor_db,
        lr.clipped_samples,
        if (analysis.exact_from_project_start) "from_project_start" else "window",
        analysis.exact_from_project_start,
        lr.standard,
        lr.gated,
        if (lr.analysis_scope == .full_program) "full_program" else "measure_window",
    }) catch {};
    return w.buffered();
}

fn handleValidateMasterDelivery(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const start_frame = getU64(args, "start_frame") orelse 0;
    const length_opt = getU64(args, "length_frames");
    const profile = parseDeliveryProfile(args);
    const analysis = master_qc.analyzeProgram(ctx.gpa, ctx.project, ctx.asset_cache, start_frame, length_opt) catch
        return errResp(response_buf, id, "analyze_failed");
    const v = master_qc.validateDelivery(analysis, profile, ctx.project.sample_rate, 2);
    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"status\":\"{s}\",\"profile\":{{\"name\":\"{s}\",\"source\":\"{s}\"}},\"checks\":[", .{
        id,
        ctx.project.revision,
        op_id,
        revision_before,
        applied_at_audio_frame,
        switch (v.status) {
            .pass => "pass",
            .warning => "warning",
            .fail => "fail",
        },
        profile.name,
        profile.source,
    }) catch {};
    var i: usize = 0;
    while (i < v.n) : (i += 1) {
        if (i > 0) w.writeAll(",") catch {};
        const ch = v.checks[i];
        w.print("{{\"name\":\"{s}\",\"status\":\"{s}\"", .{
            ch.name,
            switch (ch.status) {
                .pass => "pass",
                .warning => "warning",
                .fail => "fail",
            },
        }) catch {};
        if (ch.measured) |m| w.print(",\"measured\":{d:.4}", .{m}) catch {};
        if (ch.limit) |lim| w.print(",\"limit\":{d:.4}", .{lim}) catch {};
        w.print(",\"unit\":\"{s}\"", .{ch.unit}) catch {};
        if (ch.detail.len > 0) {
            // Escape is not implemented; keep detail free of quotes in Check constructors.
            w.print(",\"detail\":\"{s}\"", .{ch.detail}) catch {};
        }
        w.writeAll("}") catch {};
    }
    w.writeAll("]}}}") catch {};
    return w.buffered();
}

fn handleMasterLimiterAssessAndAdjust(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const effect_id = getU64(args, "effect_id") orelse return errResp(response_buf, id, "missing_effect_id");
    const param = getStr(args, "param") orelse return errResp(response_buf, id, "missing_param");
    const new_value_f64 = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
    const start_frame = getU64(args, "start_frame") orelse 0;
    const length_opt = getU64(args, "length_frames");
    if (ctx.trial_registry.hasActive()) return errResp(response_buf, id, "trial_already_open");
    const constraints = getField(args, "constraints") orelse return errResp(response_buf, id, "missing_constraints");
    const target_lufs_min: f32 = @floatCast(getF64(constraints, "target_integrated_lufs_min") orelse return errResp(response_buf, id, "missing_target_integrated_lufs_min"));
    const target_lufs_max: f32 = @floatCast(getF64(constraints, "target_integrated_lufs_max") orelse return errResp(response_buf, id, "missing_target_integrated_lufs_max"));
    const max_tp: f32 = @floatCast(getF64(constraints, "max_true_peak_dbtp") orelse -1.0);
    const max_lra_loss: f32 = @floatCast(getF64(constraints, "max_lra_loss_lu") orelse 99.0);
    const max_crest_loss: f32 = @floatCast(getF64(constraints, "max_crest_factor_loss_db") orelse 99.0);
    const max_gr_peak: f32 = @floatCast(getF64(constraints, "max_limiter_gr_peak_db") orelse 99.0);
    const force_human = getBool(args, "require_human_listening") orelse master_qc.needsHumanLimiterParam(param);

    const effect = for (ctx.project.master_effects.items) |*e| {
        if (e.id == effect_id) break e;
    } else return errResp(response_buf, id, "effect_not_found");
    if (effect.params != .limiter) return errResp(response_buf, id, "effect_not_limiter");
    const old_value = master_qc.getLimiterParam(effect.params.limiter, param) orelse return errResp(response_buf, id, "unknown_param");
    const new_value: f32 = @floatCast(new_value_f64);

    const before = master_qc.analyzeProgram(ctx.gpa, ctx.project, ctx.asset_cache, start_frame, length_opt) catch
        return errResp(response_buf, id, "analyze_failed");
    const before_buf = master_qc.renderMasterRange(ctx.gpa, ctx.project, ctx.asset_cache, before.window_start_frame, before.window_length_frames) catch
        return errResp(response_buf, id, "render_failed");
    defer ctx.gpa.free(before_buf);

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    const provisional = ctx.trial_registry.next_id;
    var before_path_buf: [256]u8 = undefined;
    // short excerpt for WAV (first 2s or full if shorter)
    const excerpt_len = @min(before.window_length_frames, @as(u64, ctx.project.sample_rate) * 2);
    const before_path_z = std.fmt.bufPrintZ(&before_path_buf, ".cache/audition/master_lim_trial_{d}_before.wav", .{provisional}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_buf[0 .. excerpt_len * 2], excerpt_len, ctx.project.sample_rate, before_path_z)) return errResp(response_buf, id, "export_failed");

    const trial_id = ctx.trial_registry.begin(ctx.project, null, before.window_start_frame, before.window_length_frames, .{}, before_path_z) catch
        return errResp(response_buf, id, "trial_begin_failed");
    if (!master_qc.setLimiterParam(&effect.params.limiter, param, new_value)) {
        ctx.trial_registry.close();
        return errResp(response_buf, id, "unknown_param");
    }
    ctx.project.revision += 1;
    const revision_after = ctx.project.revision;
    ui.markDirty(ctx.view);

    const after = master_qc.analyzeProgram(ctx.gpa, ctx.project, ctx.asset_cache, start_frame, length_opt) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "analyze_failed");
    };
    const after_buf = master_qc.renderMasterRange(ctx.gpa, ctx.project, ctx.asset_cache, after.window_start_frame, after.window_length_frames) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "render_failed");
    };
    defer ctx.gpa.free(after_buf);

    var after_raw_buf: [256]u8 = undefined;
    const after_raw_z = std.fmt.bufPrintZ(&after_raw_buf, ".cache/audition/master_lim_trial_{d}_after_raw.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_buf[0 .. excerpt_len * 2], excerpt_len, ctx.project.sample_rate, after_raw_z)) return errResp(response_buf, id, "export_failed");

    const match_gain = trial.Registry.levelMatchGainDb(before.loud.window_loudness_lufs orelse before.loud.integrated_lufs orelse -20, after.loud.window_loudness_lufs orelse after.loud.integrated_lufs orelse -20);
    const matched = ctx.gpa.alloc(f32, excerpt_len * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(matched);
    @memcpy(matched, after_buf[0 .. excerpt_len * 2]);
    applyGainToStereoBuf(matched, match_gain);
    var matched_path_buf: [256]u8 = undefined;
    const matched_z = std.fmt.bufPrintZ(&matched_path_buf, ".cache/audition/master_lim_trial_{d}_after_level_matched.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(matched, excerpt_len, ctx.project.sample_rate, matched_z)) return errResp(response_buf, id, "export_failed");

    // Observe limiter GR via short measure observing.
    const gr_stats = measureRangeObserving(ctx.gpa, ctx.project, ctx.asset_cache, .{ .master = .master_output }, before.window_start_frame, @min(excerpt_len, 100_000), ctx.project.sample_rate, null, effect_id, ctx.view.fx_bypass_all) catch
        return errResp(response_buf, id, "measure_failed");
    const gr_peak = gr_stats.comp_gr_peak_db orelse 0;

    const il_after = after.loud.integrated_lufs;
    const tp_ok = after.loud.true_peak_dbtp <= max_tp;
    const clip_ok = after.loud.clipped_samples == 0;
    const lufs_ok = if (il_after) |il| il >= target_lufs_min and il <= target_lufs_max else false;
    const lra_loss = blk: {
        const b = before.loud.lra_lu orelse break :blk @as(f32, 0);
        const a = after.loud.lra_lu orelse break :blk @as(f32, 0);
        break :blk @max(b - a, 0);
    };
    const crest_loss = @max(before.loud.crest_factor_db - after.loud.crest_factor_db, 0);
    const dyn_ok = lra_loss <= max_lra_loss and crest_loss <= max_crest_loss;
    const gr_ok = gr_peak <= max_gr_peak;
    const objectives_ok = tp_ok and clip_ok and lufs_ok and dyn_ok and gr_ok;

    var decision: trial.Decision = undefined;
    var human_q: []const u8 = "";
    if (!objectives_ok) {
        if (ctx.project.revision != revision_after) {
            decision = .conflict;
            ctx.trial_registry.close();
        } else {
            ctx.trial_registry.restoreSnapshot(ctx.project) catch return errResp(response_buf, id, "restore_failed");
            ui.markDirty(ctx.view);
            ctx.trial_registry.close();
            decision = .rolled_back;
        }
    } else if (force_human) {
        decision = .needs_human_listening;
        human_q = "In the level-matched excerpts, does the limited version preserve punch and movement without audible pumping or transient flattening?";
        ctx.trial_registry.markAwaitingHuman() catch {};
    } else {
        decision = .committed;
        ctx.trial_registry.close();
    }

    // Representative audition excerpts (paths for loudest section already exported; list meta).
    const excerpts = master_qc.pickExcerpts(after_buf, excerpt_len, ctx.project.sample_rate);

    var final_param: f32 = old_value;
    for (ctx.project.master_effects.items) |e| {
        if (e.id == effect_id and e.params == .limiter) {
            final_param = master_qc.getLimiterParam(e.params.limiter, param) orelse old_value;
        }
    }

    var reason_buf: [640]u8 = undefined;
    var reason_w: std.Io.Writer = .fixed(&reason_buf);
    switch (decision) {
        .committed => reason_w.writeAll("Committed: the selected master program meets the requested loudness, true-peak, and dynamics constraints. This is a technical delivery result, not a claim of improved musical quality.") catch {},
        .rolled_back => reason_w.print("rolled_back: constraint failed (tp={d:.2} lufs_ok={} gr={d:.2})", .{ after.loud.true_peak_dbtp, lufs_ok, gr_peak }) catch {},
        .needs_human_listening => reason_w.writeAll("Objectives passed; release/lookahead character require human listening on level-matched excerpts.") catch {},
        .conflict => reason_w.writeAll("conflict: project revision changed before rollback; foreign changes were not undone.") catch {},
    }

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"trial_id\":{d},\"effect_id\":{d},\"param\":\"{s}\",\"old_value\":{d},\"new_value\":{d},\"final_value\":{d}," ++
        "\"decision\":\"{s}\",\"reason\":\"{s}\",\"human_question\":\"{s}\"," ++
        "\"before\":{{\"integrated_lufs\":", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame,
        trial_id, effect_id, param, old_value, new_value, final_param,
        decisionStr(decision), reason_w.buffered(), human_q,
    }) catch {};
    if (before.loud.integrated_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.print(",\"true_peak_dbtp\":{d:.2}}},\"after\":{{\"integrated_lufs\":", .{before.loud.true_peak_dbtp}) catch {};
    if (after.loud.integrated_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
    w.print(",\"true_peak_dbtp\":{d:.2},\"limiter_gr_peak_db\":{d:.2}}},\"level_match\":{{\"method\":\"rms\",\"applied_gain_db\":{d:.2}}},\"auditions\":[", .{
        after.loud.true_peak_dbtp, gr_peak, match_gain,
    }) catch {};
    inline for (0..4) |ei| {
        if (ei > 0) w.writeAll(",") catch {};
        w.print("{{\"reason\":\"{s}\",\"start_frame\":{d},\"before_path\":\"{s}\",\"after_raw_path\":\"{s}\",\"after_level_matched_path\":\"{s}\"}}", .{
            excerpts[ei].reason,
            excerpts[ei].start_frame,
            before_path_z,
            after_raw_z,
            matched_z,
        }) catch {};
    }
    w.writeAll("]}}") catch {};
    return w.buffered();
}

/// Bus-targeted compressor assess (trial snapshot facade). Measures bus + master.
fn handleBusCompressorAssessAndAdjust(
    ctx: *DispatchCtx,
    args: ?std.json.Value,
    id: i64,
    op_id: u64,
    revision_before: u64,
    applied_at_audio_frame: u64,
    response_buf: []u8,
) []const u8 {
    const bus_id = getU64(args, "bus_id") orelse return errResp(response_buf, id, "missing_bus_id");
    const effect_id = getU64(args, "effect_id") orelse return errResp(response_buf, id, "missing_effect_id");
    const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
    const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
    const param = getStr(args, "param") orelse return errResp(response_buf, id, "missing_param");
    const new_value_f64 = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
    if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
    if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
    if (ctx.trial_registry.hasActive()) return errResp(response_buf, id, "trial_already_open");

    const constraints_obj = getField(args, "constraints") orelse args;
    const gr_peak_min: f32 = @floatCast(getF64(constraints_obj, "gr_peak_min_db") orelse 1.0);
    const gr_peak_max: f32 = @floatCast(getF64(constraints_obj, "gr_peak_max_db") orelse 6.0);
    const gr_mean_active_max: f32 = @floatCast(getF64(constraints_obj, "gr_mean_active_max_db") orelse 4.0);
    const max_rms_change: f32 = @floatCast(getF64(constraints_obj, "max_rms_change_db") orelse 2.0);
    const max_peak: f32 = @floatCast(getF64(constraints_obj, "max_peak_dbfs") orelse -0.1);
    const max_master_rms_change: f32 = @floatCast(getF64(constraints_obj, "max_master_rms_change_db") orelse max_rms_change);
    const max_master_peak: f32 = @floatCast(getF64(constraints_obj, "max_master_peak_dbfs") orelse max_peak);
    const max_active_ratio: f32 = @floatCast(getF64(constraints_obj, "max_active_ratio") orelse 0.8);
    const force_human = getBool(args, "require_human_listening") orelse needsHumanCompressorParam(param);

    const bus = ctx.project.findBus(bus_id) orelse return errResp(response_buf, id, "bus_not_found");
    const effect = for (bus.effects.items) |*e| {
        if (e.id == effect_id) break e;
    } else return errResp(response_buf, id, "effect_not_found");
    if (effect.params != .compressor) return errResp(response_buf, id, "effect_not_compressor");
    const old_value = getCompressorParam(effect.params.compressor, param) orelse return errResp(response_buf, id, "unknown_param");
    const new_value: f32 = @floatCast(new_value_f64);

    const bus_target: MeasureTarget = .{ .bus = .{ .bus_id = bus_id, .signal_point = .bus_post_fx } };
    const master_target: MeasureTarget = .{ .master = .master_output };

    const before_bus_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(before_bus_buf);
    const before_master_buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(before_master_buf);

    const before_bus = measureRangeObserving(ctx.gpa, ctx.project, ctx.asset_cache, bus_target, start_frame, length_frames, ctx.project.sample_rate, before_bus_buf, effect_id, ctx.view.fx_bypass_all) catch |e|
        return errResp(response_buf, id, measureErrStr(e));
    const before_master = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, master_target, start_frame, length_frames, ctx.project.sample_rate, before_master_buf, ctx.view.fx_bypass_all) catch
        return errResp(response_buf, id, "measure_failed");

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/audition", 0o755);
    var before_path_buf: [256]u8 = undefined;
    const provisional = ctx.trial_registry.next_id;
    const before_path_z = std.fmt.bufPrintZ(&before_path_buf, ".cache/audition/bus_comp_trial_{d}_before.wav", .{provisional}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_bus_buf, length_frames, ctx.project.sample_rate, before_path_z)) return errResp(response_buf, id, "export_failed");
    var before_master_path_buf: [256]u8 = undefined;
    const before_master_z = std.fmt.bufPrintZ(&before_master_path_buf, ".cache/audition/bus_comp_trial_{d}_master_before.wav", .{provisional}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(before_master_buf, length_frames, ctx.project.sample_rate, before_master_z)) return errResp(response_buf, id, "export_failed");

    const trial_id = ctx.trial_registry.begin(ctx.project, null, start_frame, length_frames, rangeStatsToTrial(before_bus), before_path_z) catch
        return errResp(response_buf, id, "trial_begin_failed");

    if (!setCompressorParam(&effect.params.compressor, param, new_value)) {
        ctx.trial_registry.close();
        return errResp(response_buf, id, "unknown_param");
    }
    ctx.project.revision += 1;
    ui.markDirty(ctx.view);
    const revision_after = ctx.project.revision;

    const after_bus_buf = ctx.gpa.alloc(f32, length_frames * 2) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "oom");
    };
    defer ctx.gpa.free(after_bus_buf);
    const after_master_buf = ctx.gpa.alloc(f32, length_frames * 2) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "oom");
    };
    defer ctx.gpa.free(after_master_buf);

    const after_bus = measureRangeObserving(ctx.gpa, ctx.project, ctx.asset_cache, bus_target, start_frame, length_frames, ctx.project.sample_rate, after_bus_buf, effect_id, ctx.view.fx_bypass_all) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "measure_failed");
    };
    const after_master = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, master_target, start_frame, length_frames, ctx.project.sample_rate, after_master_buf, ctx.view.fx_bypass_all) catch {
        _ = ctx.trial_registry.restoreSnapshot(ctx.project) catch {};
        ctx.trial_registry.close();
        return errResp(response_buf, id, "measure_failed");
    };

    var after_raw_buf: [256]u8 = undefined;
    const after_raw_z = std.fmt.bufPrintZ(&after_raw_buf, ".cache/audition/bus_comp_trial_{d}_after_raw.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_bus_buf, length_frames, ctx.project.sample_rate, after_raw_z)) return errResp(response_buf, id, "export_failed");
    var after_master_raw_buf: [256]u8 = undefined;
    const after_master_raw_z = std.fmt.bufPrintZ(&after_master_raw_buf, ".cache/audition/bus_comp_trial_{d}_master_after_raw.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_master_buf, length_frames, ctx.project.sample_rate, after_master_raw_z)) return errResp(response_buf, id, "export_failed");

    const match_gain = trial.Registry.levelMatchGainDb(before_bus.rms_dbfs, after_bus.rms_dbfs);
    const after_matched = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(after_matched);
    @memcpy(after_matched, after_bus_buf);
    applyGainToStereoBuf(after_matched, match_gain);
    var after_matched_buf: [256]u8 = undefined;
    const after_matched_z = std.fmt.bufPrintZ(&after_matched_buf, ".cache/audition/bus_comp_trial_{d}_after_level_matched.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(after_matched, length_frames, ctx.project.sample_rate, after_matched_z)) return errResp(response_buf, id, "export_failed");

    const master_match = trial.Registry.levelMatchGainDb(before_master.rms_dbfs, after_master.rms_dbfs);
    const master_matched = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
    defer ctx.gpa.free(master_matched);
    @memcpy(master_matched, after_master_buf);
    applyGainToStereoBuf(master_matched, master_match);
    var master_matched_buf: [256]u8 = undefined;
    const master_matched_z = std.fmt.bufPrintZ(&master_matched_buf, ".cache/audition/bus_comp_trial_{d}_master_after_level_matched.wav", .{trial_id}) catch return errResp(response_buf, id, "internal");
    if (!exportRangeWav(master_matched, length_frames, ctx.project.sample_rate, master_matched_z)) return errResp(response_buf, id, "export_failed");

    const gr_peak = after_bus.comp_gr_peak_db orelse 0;
    const gr_mean = after_bus.comp_gr_mean_active_db orelse 0;
    const active_ratio = after_bus.comp_active_sample_ratio orelse 0;
    const rms_change = @abs(after_bus.rms_dbfs - before_bus.rms_dbfs);
    const master_rms_change = @abs(after_master.rms_dbfs - before_master.rms_dbfs);
    const gr_ok = gr_peak >= gr_peak_min and gr_peak <= gr_peak_max;
    const mean_ok = gr_mean <= gr_mean_active_max;
    const rms_ok = rms_change <= max_rms_change;
    const peak_ok = after_bus.peak_dbfs <= max_peak;
    const active_ok = active_ratio <= max_active_ratio;
    const master_rms_ok = master_rms_change <= max_master_rms_change;
    const master_peak_ok = after_master.peak_dbfs <= max_master_peak;
    const objectives_ok = gr_ok and mean_ok and rms_ok and peak_ok and active_ok and master_rms_ok and master_peak_ok;

    var decision: trial.Decision = undefined;
    var human_q: []const u8 = "";
    if (!objectives_ok) {
        if (ctx.project.revision != revision_after) {
            decision = .conflict;
            ctx.trial_registry.close();
        } else {
            ctx.trial_registry.restoreSnapshot(ctx.project) catch return errResp(response_buf, id, "restore_failed");
            ui.markDirty(ctx.view);
            ctx.trial_registry.close();
            decision = .rolled_back;
        }
    } else if (force_human) {
        decision = .needs_human_listening;
        human_q = "Does the level-matched after version preserve the drum transients and groove while providing the intended bus cohesion?";
        ctx.trial_registry.markAwaitingHuman() catch {};
    } else {
        decision = .committed;
        ctx.trial_registry.close();
    }

    var final_param: f32 = old_value;
    if (ctx.project.findBus(bus_id)) |b2| {
        for (b2.effects.items) |e| {
            if (e.id == effect_id and e.params == .compressor) {
                final_param = getCompressorParam(e.params.compressor, param) orelse old_value;
            }
        }
    }

    var reason_buf: [640]u8 = undefined;
    var reason_w: std.Io.Writer = .fixed(&reason_buf);
    switch (decision) {
        .committed => reason_w.writeAll("Committed: bus GR and master-level constraints satisfied. Technical bus compression only, not musical cohesion.") catch {},
        .rolled_back => reason_w.print("rolled_back: constraint failed (bus_gr_peak={d:.2} master_rms_change={d:.2} master_peak={d:.2})", .{ gr_peak, master_rms_change, after_master.peak_dbfs }) catch {},
        .needs_human_listening => reason_w.writeAll("Objectives passed; attack/release character and bus cohesion require human listening on level-matched A/B.") catch {},
        .conflict => reason_w.writeAll("conflict: project revision changed before rollback; foreign changes were not undone.") catch {},
    }

    var before_recon: [256]u8 = undefined;
    const before_out = std.fmt.bufPrint(&before_recon, ".cache/audition/bus_comp_trial_{d}_before.wav", .{trial_id}) catch before_path_z;

    var w: std.Io.Writer = .fixed(response_buf);
    w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{" ++
        "\"trial_id\":{d},\"bus_id\":{d},\"effect_id\":{d},\"param\":\"{s}\",\"old_value\":{d:.4},\"new_value\":{d:.4},\"final_value\":{d:.4}," ++
        "\"window_start_frame\":{d},\"window_length_frames\":{d}," ++
        "\"decision\":\"{s}\",\"reason\":\"{s}\",\"human_question\":\"{s}\"," ++
        "\"level_match\":{{\"method\":\"rms\",\"reference\":\"before\",\"applied_gain_db\":{d:.2}}}," ++
        "\"before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
        id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, trial_id,
        bus_id, effect_id, param, old_value, new_value, final_param,
        start_frame, length_frames, decisionStr(decision), reason_w.buffered(), human_q, match_gain,
        before_bus.peak_dbfs, before_bus.rms_dbfs,
    }) catch {};
    writeRangeStatsTail(&w, before_bus);
    w.print("}},\"after\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{ after_bus.peak_dbfs, after_bus.rms_dbfs }) catch {};
    writeRangeStatsTail(&w, after_bus);
    w.print("}},\"master_before\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2}}},\"master_after\":{{\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2}}}," ++
        "\"before_audition_path\":\"{s}\",\"after_raw_audition_path\":\"{s}\",\"after_level_matched_path\":\"{s}\"," ++
        "\"before_master_audition_path\":\"{s}\",\"after_master_raw_audition_path\":\"{s}\",\"after_master_level_matched_path\":\"{s}\"}}}}", .{
        before_master.peak_dbfs, before_master.rms_dbfs, after_master.peak_dbfs, after_master.rms_dbfs,
        before_out, after_raw_z, after_matched_z, before_master_z, after_master_raw_z, master_matched_z,
    }) catch {};
    return w.buffered();
}

fn handleCommandTimed(ctx: *DispatchCtx, line: []const u8, response_buf: []u8) []const u8 {
    const t0 = offline_audio.nowNs();
    const r = handleCommand(ctx, line, response_buf);
    const ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t0)) / 1e6;
    ctx.audio_diag.noteCommandMs(ms);
    return r;
}

pub fn handleCommand(ctx: *DispatchCtx, line: []const u8, response_buf: []u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, line, .{}) catch {
        return errResp(response_buf, 0, "bad_json");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return errResp(response_buf, 0, "expected_object");
    const obj = parsed.value.object;

    const id: i64 = if (obj.get("id")) |v| (if (v == .integer) v.integer else 0) else 0;
    const cmd_val = obj.get("cmd") orelse return errResp(response_buf, id, "missing_cmd");
    if (cmd_val != .string) return errResp(response_buf, id, "cmd_must_be_string");
    const cmd = cmd_val.string;
    const args = obj.get("args");

    const is_mutating = for (MUTATING_COMMANDS) |m| {
        if (std.mem.eql(u8, cmd, m)) break true;
    } else false;
    if (is_mutating) {
        ctx.history.recordBeforeMutation(ctx.gpa, ctx.project) catch {};
    }
    const is_tracked = for (TRACKED_COMMANDS) |m| {
        if (std.mem.eql(u8, cmd, m)) break true;
    } else false;
    const revision_before = ctx.project.revision;
    const applied_at_audio_frame = ctx.frame_count.*;
    const op_id = ctx.operation_counter.*;
    if (is_tracked) ctx.operation_counter.* += 1;

    if (std.mem.eql(u8, cmd, "get_project_summary")) {
        var w: std.Io.Writer = .fixed(response_buf);
        const tr = switch (ctx.transport.*) {
            .stop => "stop",
            .play => "play",
            .count_in => "count_in",
            .record => "record",
        };
        w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"result\":{{\"bpm\":{d},\"transport\":\"{s}\",\"beat_time\":{d},\"tracks\":[", .{ id, ctx.project.revision, ctx.project.bpm, tr, ctx.beat_time.* }) catch {};
        for (ctx.project.tracks.items, 0..) |t, i| {
            if (i > 0) w.writeAll(",") catch {};
            w.print("{{\"id\":{d},\"name\":\"{s}\",\"armed\":{},\"mute\":{},\"solo\":{},\"fx_enabled\":{},\"clip_count\":{d},\"effect_count\":{d}}}", .{ t.id, t.name, t.armed, t.mute, t.solo, t.fx_enabled, t.clips.items.len, t.effects.items.len }) catch {};
        }
        w.writeAll("]}}") catch {};
        return w.buffered();
    } else if (std.mem.eql(u8, cmd, "get_live_state")) {
        var w: std.Io.Writer = .fixed(response_buf);
        const tr = switch (ctx.transport.*) {
            .stop => "stop",
            .play => "play",
            .count_in => "count_in",
            .record => "record",
        };
        w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"result\":{{\"transport\":\"{s}\",\"beat_time\":{d},\"master_peak\":{d},\"tracks\":[", .{ id, ctx.project.revision, tr, ctx.beat_time.*, ctx.live_peaks.master }) catch {};
        for (ctx.project.tracks.items, 0..) |t, i| {
            if (i > 0) w.writeAll(",") catch {};
            const pl = if (i < ctx.live_peaks.track_l.len) ctx.live_peaks.track_l[i] else 0;
            const pr = if (i < ctx.live_peaks.track_r.len) ctx.live_peaks.track_r[i] else 0;
            w.print("{{\"id\":{d},\"name\":\"{s}\",\"peak_l\":{d},\"peak_r\":{d},\"fx_enabled\":{},\"effects\":[", .{ t.id, t.name, pl, pr, t.fx_enabled }) catch {};
            for (t.effects.items, 0..) |e, ei| {
                if (ei > 0) w.writeAll(",") catch {};
                switch (e.params) {
                    .sidechain_compressor => |p| {
                        w.print("{{\"id\":{d},\"kind\":\"sidechain_compressor\",\"bypassed\":{},\"threshold_db\":{d},\"ratio\":{d},\"attack_ms\":{d},\"release_ms\":{d},\"source_track_id\":{d},\"gain_reduction_db\":", .{ e.id, e.bypassed, p.threshold_db, p.ratio, p.attack_ms, p.release_ms, p.source_track_id }) catch {};
                        if (ctx.sc_rt.gainReductionDb(e.id)) |gr| w.print("{d:.2}", .{gr}) catch {} else w.writeAll("null") catch {};
                        w.writeAll(",\"detector_level_db\":") catch {};
                        if (ctx.sc_rt.detectorLevelDb(e.id)) |d| w.print("{d:.2}", .{d}) catch {} else w.writeAll("null") catch {};
                        w.writeAll("}") catch {};
                    },
                    .eq => w.print("{{\"id\":{d},\"kind\":\"eq\",\"bypassed\":{}}}", .{ e.id, e.bypassed }) catch {},
                    .compressor => |p| w.print("{{\"id\":{d},\"kind\":\"compressor\",\"bypassed\":{},\"threshold_db\":{d},\"ratio\":{d}}}", .{ e.id, e.bypassed, p.threshold_db, p.ratio }) catch {},
                    .limiter => |p| w.print("{{\"id\":{d},\"kind\":\"limiter\",\"bypassed\":{},\"ceiling_dbfs\":{d},\"threshold_db\":{d},\"release_ms\":{d},\"lookahead_ms\":{d},\"link_channels\":{}}}", .{ e.id, e.bypassed, p.ceiling_dbfs, p.threshold_db, p.release_ms, p.lookahead_ms, p.link_channels }) catch {},
                    .delay => |p| w.print("{{\"id\":{d},\"kind\":\"delay\",\"bypassed\":{},\"time_ms\":{d},\"feedback\":{d},\"mix\":{d}}}", .{ e.id, e.bypassed, p.time_ms, p.feedback, p.mix }) catch {},
                    .stereo_width => |p| w.print("{{\"id\":{d},\"kind\":\"stereo_width\",\"bypassed\":{},\"mode\":\"{s}\",\"width\":{d:.3},\"crossover_hz\":{d:.1},\"low_width\":{d:.3},\"high_width\":{d:.3}}}", .{
                        e.id,
                        e.bypassed,
                        if (p.mode == .fullband) "fullband" else "crossover",
                        p.width,
                        p.crossover_hz,
                        p.low_width,
                        p.high_width,
                    }) catch {},
                }
            }
            w.writeAll("]}") catch {};
        }
        w.writeAll("],\"buses\":[") catch {};
        for (ctx.project.buses.items, 0..) |b, i| {
            if (i > 0) w.writeAll(",") catch {};
            const pl = if (i < ctx.live_peaks.bus_l.len) ctx.live_peaks.bus_l[i] else 0;
            const pr = if (i < ctx.live_peaks.bus_r.len) ctx.live_peaks.bus_r[i] else 0;
            const in_p = if (i < ctx.live_peaks.bus_in_peak.len) ctx.live_peaks.bus_in_peak[i] else 0;
            const out_p = if (i < ctx.live_peaks.bus_out_peak.len) ctx.live_peaks.bus_out_peak[i] else 0;
            w.print("{{\"id\":{d},\"name\":\"{s}\",\"peak_l\":{d},\"peak_r\":{d},\"input_peak\":{d},\"output_peak\":{d},\"mute\":{},\"solo\":{},\"volume\":{d},\"effects\":[", .{ b.id, b.name, pl, pr, in_p, out_p, b.mute, b.solo, b.volume }) catch {};
            for (b.effects.items, 0..) |e, ei| {
                if (ei > 0) w.writeAll(",") catch {};
                switch (e.params) {
                    .compressor => |p| w.print("{{\"id\":{d},\"kind\":\"compressor\",\"bypassed\":{},\"threshold_db\":{d},\"ratio\":{d}}}", .{ e.id, e.bypassed, p.threshold_db, p.ratio }) catch {},
                    .delay => |p| w.print("{{\"id\":{d},\"kind\":\"delay\",\"bypassed\":{},\"time_ms\":{d},\"mix\":{d}}}", .{ e.id, e.bypassed, p.time_ms, p.mix }) catch {},
                    else => w.print("{{\"id\":{d},\"kind\":\"other\",\"bypassed\":{}}}", .{ e.id, e.bypassed }) catch {},
                }
            }
            w.writeAll("]}") catch {};
        }
        // audio_diag: fill-gap proxy (not device XRuns). Close result+root via writeAll.
        const ad = ctx.audio_diag;
        w.print("],\"routing_revision\":{d},\"audio_diag\":{{\"audio_fill_count\":{d},\"audio_callback_count\":{d},\"last_fill_timestamp\":{d:.6},\"max_fill_gap_ms\":{d:.2},\"max_callback_gap_ms\":{d:.2},\"buffer_underrun_events\":{d},\"underrun_count\":{d},\"buffer_low_watermark_frames\":{d},\"command_duration_ms\":{d:.2},\"max_command_duration_ms\":{d:.2},\"measure_duration_ms\":{d:.2},\"audition_duration_ms\":{d:.2},\"level_match_duration_ms\":{d:.2},\"trial_duration_ms\":{d:.2}}}", .{
            ctx.project.revision,
            ad.audio_fill_count,
            ad.audio_fill_count,
            ad.last_fill_timestamp,
            ad.max_fill_gap_ms,
            ad.max_fill_gap_ms,
            ad.buffer_underrun_events,
            ad.buffer_underrun_events,
            ad.buffer_low_watermark_frames,
            ad.command_duration_ms,
            ad.max_command_duration_ms,
            ad.measure_duration_ms,
            ad.audition_duration_ms,
            ad.level_match_duration_ms,
            ad.trial_duration_ms,
        }) catch {};
        w.writeAll("}}") catch {};
        return w.buffered();
    } else if (std.mem.eql(u8, cmd, "reset_audio_diag")) {
        ctx.audio_diag.reset();
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "set_effect_param")) {
        const effect_id = getU64(args, "effect_id") orelse return errResp(response_buf, id, "missing_effect_id");
        const track_id_opt = getU64(args, "track_id");
        const bus_id_opt = getU64(args, "bus_id");
        var effect: ?*model.Effect = null;
        if (track_id_opt) |track_id| {
            const track = ctx.project.findTrack(track_id) orelse return errResp(response_buf, id, "track_not_found");
            if (getBool(args, "fx_enabled")) |v| track.fx_enabled = v;
            effect = for (track.effects.items) |*e| {
                if (e.id == effect_id) break e;
            } else null;
        } else if (bus_id_opt) |bus_id| {
            const bus = ctx.project.findBus(bus_id) orelse return errResp(response_buf, id, "bus_not_found");
            if (getBool(args, "fx_enabled")) |v| bus.fx_enabled = v;
            effect = for (bus.effects.items) |*e| {
                if (e.id == effect_id) break e;
            } else null;
        } else {
            var master_target = false;
            if (getField(args, "target")) |tv| {
                if (tv == .object) {
                    if (getStr(tv, "kind")) |k| master_target = std.mem.eql(u8, k, "master");
                }
            }
            if (getBool(args, "master")) |m| master_target = master_target or m;
            if (!master_target) {
                // Implicit master if effect id exists on master chain.
                for (ctx.project.master_effects.items) |*e| {
                    if (e.id == effect_id) {
                        master_target = true;
                        effect = e;
                        break;
                    }
                }
            } else {
                if (getBool(args, "fx_enabled")) |v| ctx.project.master_fx_enabled = v;
                effect = for (ctx.project.master_effects.items) |*e| {
                    if (e.id == effect_id) break e;
                } else null;
            }
            if (!master_target and effect == null) return errResp(response_buf, id, "missing_track_id");
        }
        const eff = effect orelse return errResp(response_buf, id, "effect_not_found");
        if (getBool(args, "bypassed")) |v| eff.bypassed = v;
        if (eff.params == .sidechain_compressor) {
            var p = &eff.params.sidechain_compressor;
            if (getF64(args, "threshold_db")) |v| p.threshold_db = @floatCast(v);
            if (getF64(args, "ratio")) |v| p.ratio = @floatCast(@max(v, 1.0));
            if (getF64(args, "attack_ms")) |v| p.attack_ms = @floatCast(@max(v, 0.1));
            if (getF64(args, "release_ms")) |v| p.release_ms = @floatCast(@max(v, 0.1));
        } else if (eff.params == .compressor) {
            var p = &eff.params.compressor;
            if (getF64(args, "threshold_db")) |v| p.threshold_db = @floatCast(v);
            if (getF64(args, "ratio")) |v| p.ratio = @floatCast(@max(v, 1.0));
            if (getF64(args, "attack_ms")) |v| p.attack_ms = @floatCast(@max(v, 0.1));
            if (getF64(args, "release_ms")) |v| p.release_ms = @floatCast(@max(v, 0.1));
            if (getF64(args, "knee_db")) |v| p.knee_db = @floatCast(@max(v, 0.0));
            if (getF64(args, "makeup_db")) |v| p.makeup_db = @floatCast(v);
            if (getF64(args, "mix")) |v| p.mix = @floatCast(std.math.clamp(v, 0.0, 1.0));
        } else if (eff.params == .delay) {
            var p = &eff.params.delay;
            if (getF64(args, "time_ms")) |v| p.time_ms = @floatCast(@max(v, 1.0));
            if (getF64(args, "feedback")) |v| p.feedback = @floatCast(std.math.clamp(v, 0.0, 0.95));
            if (getF64(args, "damping")) |v| p.damping = @floatCast(std.math.clamp(v, 0.0, 1.0));
            if (getF64(args, "mix")) |v| p.mix = @floatCast(std.math.clamp(v, 0.0, 1.0));
        } else if (eff.params == .limiter) {
            var p = &eff.params.limiter;
            if (getF64(args, "ceiling_dbfs") orelse getF64(args, "limit_db")) |v| p.ceiling_dbfs = @floatCast(v);
            if (getF64(args, "threshold_db")) |v| p.threshold_db = @floatCast(v);
            if (getF64(args, "release_ms")) |v| p.release_ms = @floatCast(@max(v, 0.1));
            if (getF64(args, "lookahead_ms")) |v| p.lookahead_ms = @floatCast(@max(v, 0.0));
            if (getBool(args, "link_channels")) |v| p.link_channels = v;
        } else if (eff.params == .stereo_width) {
            var p = &eff.params.stereo_width;
            const param = getStr(args, "param");
            if (param) |pname| {
                const vf = getF64(args, "value");
                if (std.mem.eql(u8, pname, "width")) {
                    p.width = @floatCast(std.math.clamp(vf orelse return errResp(response_buf, id, "missing_value"), 0.0, 2.0));
                    if (p.mode == .fullband) {}
                } else if (std.mem.eql(u8, pname, "high_width")) {
                    p.high_width = @floatCast(std.math.clamp(vf orelse return errResp(response_buf, id, "missing_value"), 0.0, 2.0));
                } else if (std.mem.eql(u8, pname, "low_width")) {
                    p.low_width = @floatCast(std.math.clamp(vf orelse return errResp(response_buf, id, "missing_value"), 0.0, 2.0));
                } else if (std.mem.eql(u8, pname, "crossover_hz")) {
                    p.crossover_hz = @floatCast(std.math.clamp(vf orelse return errResp(response_buf, id, "missing_value"), 40.0, 2000.0));
                } else if (std.mem.eql(u8, pname, "mode")) {
                    const value_field = getField(args, "value");
                    const s = if (value_field) |v| (if (v == .string) v.string else null) else null;
                    if (s == null) return errResp(response_buf, id, "missing_value");
                    if (std.mem.eql(u8, s.?, "fullband")) p.mode = .fullband
                    else if (std.mem.eql(u8, s.?, "crossover")) p.mode = .crossover
                    else return errResp(response_buf, id, "invalid_stereo_width_mode");
                } else return errResp(response_buf, id, "unsupported_stereo_width_param");
            } else {
                if (getF64(args, "width")) |v| p.width = @floatCast(std.math.clamp(v, 0.0, 2.0));
                if (getF64(args, "high_width")) |v| p.high_width = @floatCast(std.math.clamp(v, 0.0, 2.0));
                if (getF64(args, "low_width")) |v| p.low_width = @floatCast(std.math.clamp(v, 0.0, 2.0));
                if (getF64(args, "crossover_hz")) |v| p.crossover_hz = @floatCast(std.math.clamp(v, 40.0, 2000.0));
                if (getStr(args, "mode")) |ms| {
                    if (std.mem.eql(u8, ms, "fullband")) p.mode = .fullband
                    else if (std.mem.eql(u8, ms, "crossover")) p.mode = .crossover
                    else return errResp(response_buf, id, "invalid_stereo_width_mode");
                }
            }
        } else if (eff.params == .eq) {
            const band_index_u = getU64(args, "band_index") orelse return errResp(response_buf, id, "missing_band_index");
            if (band_index_u > 255) return errResp(response_buf, id, "band_index_out_of_range");
            const band_index: usize = @intCast(band_index_u);
            const band = getEqBandPtr(eff, band_index) orelse return errResp(response_buf, id, "band_index_out_of_range");
            const param = getStr(args, "param");
            if (param) |pname| {
                if (std.mem.eql(u8, pname, "band_type")) {
                    const value_field = getField(args, "value");
                    const s = if (value_field) |v| (if (v == .string) v.string else null) else null;
                    const nt = parseEqBandType(s orelse return errResp(response_buf, id, "missing_value")) orelse
                        return errResp(response_buf, id, "invalid_band_type");
                    if (nt == .highpass and band.gain_db != 0.0) return errResp(response_buf, id, "highpass_gain_forbidden");
                    band.band_type = nt;
                    if (nt == .highpass) band.gain_db = 0.0;
                } else if (std.mem.eql(u8, pname, "frequency_hz") or std.mem.eql(u8, pname, "freq")) {
                    const vf = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
                    const f: f32 = @floatCast(vf);
                    if (!validateEqFrequency(f, ctx.project.sample_rate)) return errResp(response_buf, id, "frequency_out_of_range");
                    band.frequency_hz = f;
                } else if (std.mem.eql(u8, pname, "gain_db")) {
                    if (band.band_type == .highpass) return errResp(response_buf, id, "highpass_gain_forbidden");
                    const vf = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
                    const g: f32 = @floatCast(vf);
                    if (!validateEqGain(g)) return errResp(response_buf, id, "gain_out_of_range");
                    band.gain_db = g;
                } else if (std.mem.eql(u8, pname, "q")) {
                    const vf = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
                    const qq: f32 = @floatCast(vf);
                    if (!validateEqQ(qq)) return errResp(response_buf, id, "q_out_of_range");
                    band.q = qq;
                } else if (std.mem.eql(u8, pname, "bypass")) {
                    const value_field = getField(args, "value");
                    const b = if (value_field) |v| (if (v == .bool) v.bool else null) else getBool(args, "bypass");
                    band.bypass = b orelse return errResp(response_buf, id, "missing_value");
                } else return errResp(response_buf, id, "unsupported_eq_param");
            } else {
                // Flat aliases
                if (getStr(args, "band_type")) |s| {
                    const nt = parseEqBandType(s) orelse return errResp(response_buf, id, "invalid_band_type");
                    if (nt == .highpass and band.gain_db != 0.0) return errResp(response_buf, id, "highpass_gain_forbidden");
                    band.band_type = nt;
                    if (nt == .highpass) band.gain_db = 0.0;
                }
                if (getF64(args, "frequency_hz") orelse getF64(args, "freq")) |vf| {
                    const f: f32 = @floatCast(vf);
                    if (!validateEqFrequency(f, ctx.project.sample_rate)) return errResp(response_buf, id, "frequency_out_of_range");
                    band.frequency_hz = f;
                }
                if (getF64(args, "gain_db")) |vf| {
                    if (band.band_type == .highpass) return errResp(response_buf, id, "highpass_gain_forbidden");
                    const g: f32 = @floatCast(vf);
                    if (!validateEqGain(g)) return errResp(response_buf, id, "gain_out_of_range");
                    band.gain_db = g;
                }
                if (getF64(args, "q")) |vf| {
                    const qq: f32 = @floatCast(vf);
                    if (!validateEqQ(qq)) return errResp(response_buf, id, "q_out_of_range");
                    band.q = qq;
                }
                if (getBool(args, "bypass")) |b| band.bypass = b;
            }
        }
        if (track_id_opt) |track_id| ensureDryClipSources(ctx.project, track_id);
        ctx.project.revision += 1;
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "transport")) {
        const action = getStr(args, "action") orelse return errResp(response_buf, id, "missing_action");
        if (std.mem.eql(u8, action, "play")) {
            ctx.transport.* = ui.stepTransport(ctx.transport.*, .play_btn);
        } else if (std.mem.eql(u8, action, "stop")) {
            ctx.transport.* = ui.stepTransport(ctx.transport.*, .stop_btn);
        } else if (std.mem.eql(u8, action, "toggle")) {
            ctx.transport.* = ui.stepTransport(ctx.transport.*, .space);
        } else if (std.mem.eql(u8, action, "record")) {
            ctx.transport.* = ui.stepTransport(ctx.transport.*, .record_key);
        } else return errResp(response_buf, id, "bad_action");
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "get_state")) {
        const dto = model.toDto(ctx.gpa, ctx.project) catch return errResp(response_buf, id, "oom");
        defer model.freeProjectDto(ctx.gpa, &dto);
        const text = std.json.Stringify.valueAlloc(ctx.gpa, dto, .{}) catch return errResp(response_buf, id, "oom");
        defer ctx.gpa.free(text);
        return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"result\":{s}}}", .{ id, text }) catch errResp(response_buf, id, "response_too_large");
    } else if (std.mem.eql(u8, cmd, "set_tempo")) {
        const bpm = getF64(args, "bpm") orelse return errResp(response_buf, id, "missing_bpm");
        if (bpm < 20 or bpm > 400) return errResp(response_buf, id, "bpm_out_of_range");
        ctx.project.bpm = bpm;
        ctx.project.revision += 1;
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "add_track")) {
        const name = getStr(args, "name") orelse "track";
        _ = ctx.project.addTrack(ctx.gpa, name) catch return errResp(response_buf, id, "oom");
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "remove_track")) {
        const track_id = getU64(args, "track_id") orelse return errResp(response_buf, id, "missing_track_id");
        if (!ctx.project.removeTrack(ctx.gpa, track_id)) return errResp(response_buf, id, "track_not_found");
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "set_track_param")) {
        const track_id = getU64(args, "track_id") orelse return errResp(response_buf, id, "missing_track_id");
        const track = ctx.project.findTrack(track_id) orelse return errResp(response_buf, id, "track_not_found");
        if (getF64(args, "volume")) |v| track.volume = std.math.clamp(@as(f32, @floatCast(v)), 0.0, 1.0);
        if (getF64(args, "pan")) |v| track.pan = std.math.clamp(@as(f32, @floatCast(v)), -1.0, 1.0);
        if (getBool(args, "mute")) |v| track.mute = v;
        if (getBool(args, "solo")) |v| track.solo = v;
        if (getBool(args, "master_send_enabled")) |v| {
            track.master_send_enabled = v;
            if (v) track.post_master_enabled = false;
        }
        if (getBool(args, "post_master_enabled")) |v| {
            track.post_master_enabled = v;
            if (v) track.master_send_enabled = false;
        }
        if (getBool(args, "armed")) |v| {
            if (v) {
                for (ctx.project.tracks.items) |*t| t.armed = false;
            }
            track.armed = v;
        }
        ctx.project.revision += 1;
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "save")) {
        const path = getStr(args, "path") orelse return errResp(response_buf, id, "missing_path");
        persist.saveAtomic(ctx.gpa, ctx.project, path) catch return errResp(response_buf, id, "save_failed");
        ui.clearDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "load")) {
        const path = getStr(args, "path") orelse return errResp(response_buf, id, "missing_path");
        const loaded = persist.load(ctx.gpa, path) catch return errResp(response_buf, id, "load_failed");
        freeAssetCache(ctx.gpa, ctx.asset_cache);
        ctx.project.deinit(ctx.gpa);
        ctx.project.* = loaded;
        reloadAssetCache(ctx.gpa, ctx.project, ctx.asset_cache) catch return errResp(response_buf, id, "asset_reload_failed");
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "undo")) {
        const did = ctx.history.undo(ctx.gpa, ctx.project) catch return errResp(response_buf, id, "undo_failed");
        if (!did) return errResp(response_buf, id, "nothing_to_undo");
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "redo")) {
        const did = ctx.history.redo(ctx.gpa, ctx.project) catch return errResp(response_buf, id, "redo_failed");
        if (!did) return errResp(response_buf, id, "nothing_to_redo");
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "new_project")) {
        freeAssetCache(ctx.gpa, ctx.asset_cache);
        ctx.pending_imports.clearRetainingCapacity();
        ctx.project.deinit(ctx.gpa);
        ctx.project.* = .{};
        const first = ctx.project.addTrack(ctx.gpa, "Track 1") catch return errResp(response_buf, id, "oom");
        first.armed = true;
        ctx.project_path.* = null;
        ctx.beat_time.* = 0;
        ctx.transport.* = .stop;
        ctx.view.selected_track = first.id;
        ctx.view.fx_target = .none;
        ui.clearDirty(ctx.view);
        ui.setStatusMsg(ctx.view, "New project");
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "add_bus")) {
        const name = getStr(args, "name") orelse "Bus";
        const bus = ctx.project.addBus(ctx.gpa, name) catch return errResp(response_buf, id, "oom");
        ui.markDirty(ctx.view);
        return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"bus_id\":{d},\"name\":\"{s}\"}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, bus.id, bus.name }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "remove_bus")) {
        const bus_id = getU64(args, "bus_id") orelse return errResp(response_buf, id, "missing_bus_id");
        if (!ctx.project.removeBus(ctx.gpa, bus_id)) return errResp(response_buf, id, "bus_not_found");
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "set_bus_param")) {
        const bus_id = getU64(args, "bus_id") orelse return errResp(response_buf, id, "missing_bus_id");
        const bus = ctx.project.findBus(bus_id) orelse return errResp(response_buf, id, "bus_not_found");
        if (getF64(args, "volume")) |v| bus.volume = @floatCast(@max(v, 0.0));
        if (getF64(args, "pan")) |v| bus.pan = @floatCast(std.math.clamp(v, -1.0, 1.0));
        if (getBool(args, "mute")) |v| bus.mute = v;
        if (getBool(args, "solo")) |v| bus.solo = v;
        if (getBool(args, "fx_enabled")) |v| bus.fx_enabled = v;
        if (getStr(args, "name")) |n| {
            const owned = ctx.gpa.dupe(u8, n) catch return errResp(response_buf, id, "oom");
            ctx.gpa.free(bus.name);
            bus.name = owned;
        }
        ctx.project.revision += 1;
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "add_send")) {
        const src = getU64(args, "source_track_id") orelse return errResp(response_buf, id, "missing_source_track_id");
        const dst = getU64(args, "destination_bus_id") orelse return errResp(response_buf, id, "missing_destination_bus_id");
        const gain_db: f32 = @floatCast(getF64(args, "gain_db") orelse 0);
        var tap: model.SendTap = .post_fader;
        if (getStr(args, "tap")) |ts| {
            if (std.mem.eql(u8, ts, "pre_fader")) {
                tap = .pre_fader;
            } else if (std.mem.eql(u8, ts, "post_fader")) {
                tap = .post_fader;
            } else return errResp(response_buf, id, "bad_tap");
        }
        const sid = ctx.project.addSend(ctx.gpa, src, dst, gain_db, tap) catch |e| return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else if (e == error.BusNotFound) "bus_not_found" else "send_failed");
        ui.markDirty(ctx.view);
        return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"send_id\":{d}}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, sid }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "remove_send")) {
        const send_id = getU64(args, "send_id") orelse return errResp(response_buf, id, "missing_send_id");
        if (!ctx.project.removeSend(send_id)) return errResp(response_buf, id, "send_not_found");
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "set_send_param")) {
        const send_id = getU64(args, "send_id") orelse return errResp(response_buf, id, "missing_send_id");
        const send = ctx.project.findSend(send_id) orelse return errResp(response_buf, id, "send_not_found");
        if (getStr(args, "param")) |pname| {
            if (std.mem.eql(u8, pname, "gain_db")) {
                const v = getF64(args, "value") orelse return errResp(response_buf, id, "missing_value");
                send.gain_db = @floatCast(v);
            } else if (std.mem.eql(u8, pname, "enabled")) {
                send.enabled = getBool(args, "value") orelse ((getF64(args, "value") orelse 0) != 0);
            } else if (std.mem.eql(u8, pname, "tap")) {
                const ts = getStr(args, "value_str") orelse getStr(args, "tap") orelse return errResp(response_buf, id, "missing_tap");
                if (std.mem.eql(u8, ts, "pre_fader")) {
                    send.tap = .pre_fader;
                } else if (std.mem.eql(u8, ts, "post_fader")) {
                    send.tap = .post_fader;
                } else return errResp(response_buf, id, "bad_tap");
            } else return errResp(response_buf, id, "unknown_param");
        } else {
            if (getF64(args, "gain_db")) |v| send.gain_db = @floatCast(v);
            if (getBool(args, "enabled")) |v| send.enabled = v;
            if (getStr(args, "tap")) |ts| {
                if (std.mem.eql(u8, ts, "pre_fader")) {
                    send.tap = .pre_fader;
                } else if (std.mem.eql(u8, ts, "post_fader")) {
                    send.tap = .post_fader;
                } else return errResp(response_buf, id, "bad_tap");
            }
        }
        ctx.project.revision += 1;
        ui.markDirty(ctx.view);
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "get_routing_state")) {
        var w: std.Io.Writer = .fixed(response_buf);
        w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"result\":{{\"routing_revision\":{d},\"buses\":[", .{ id, ctx.project.revision, ctx.project.revision }) catch {};
        for (ctx.project.buses.items, 0..) |b, bi| {
            if (bi > 0) w.writeAll(",") catch {};
            w.print("{{\"id\":{d},\"name\":\"{s}\",\"volume\":{d},\"pan\":{d},\"mute\":{},\"solo\":{},\"fx_enabled\":{},\"effects\":[", .{ b.id, b.name, b.volume, b.pan, b.mute, b.solo, b.fx_enabled }) catch {};
            for (b.effects.items, 0..) |e, ei| {
                if (ei > 0) w.writeAll(",") catch {};
                const kind: []const u8 = switch (e.params) {
                    .eq => "eq",
                    .compressor => "compressor",
                    .limiter => "limiter",
                    .sidechain_compressor => "sidechain_compressor",
                    .delay => "delay",
                    .stereo_width => "stereo_width",
                };
                w.print("{{\"id\":{d},\"kind\":\"{s}\",\"bypassed\":{}}}", .{ e.id, kind, e.bypassed }) catch {};
            }
            w.writeAll("]}") catch {};
        }
        w.writeAll("],\"sends\":[") catch {};
        for (ctx.project.sends.items, 0..) |s, si| {
            if (si > 0) w.writeAll(",") catch {};
            const tap_s: []const u8 = switch (s.tap) {
                .pre_fader => "pre_fader",
                .post_fader => "post_fader",
            };
            w.print("{{\"id\":{d},\"source_track_id\":{d},\"destination_bus_id\":{d},\"gain_db\":{d},\"tap\":\"{s}\",\"enabled\":{}}}", .{ s.id, s.source_track_id, s.destination_bus_id, s.gain_db, tap_s, s.enabled }) catch {};
        }
        w.writeAll("],\"tracks\":[") catch {};
        for (ctx.project.tracks.items, 0..) |t, ti| {
            if (ti > 0) w.writeAll(",") catch {};
            w.print("{{\"id\":{d},\"name\":\"{s}\",\"master_send_enabled\":{},\"post_master_enabled\":{}}}", .{ t.id, t.name, t.master_send_enabled, t.post_master_enabled }) catch {};
        }
        w.writeAll("]}}") catch {};
        return w.buffered();
    } else if (std.mem.eql(u8, cmd, "insert_effect")) {
        const track_id_opt = getU64(args, "track_id");
        const bus_id_opt = getU64(args, "bus_id");
        var master_target = false;
        if (getField(args, "target")) |tv| {
            if (tv == .object) {
                if (getStr(tv, "kind")) |k| master_target = std.mem.eql(u8, k, "master");
            }
        }
        if (getBool(args, "master")) |m| master_target = master_target or m;
        const n_targets = @as(u2, @intFromBool(track_id_opt != null)) + @as(u2, @intFromBool(bus_id_opt != null)) + @as(u2, @intFromBool(master_target));
        if (n_targets > 1) return errResp(response_buf, id, "ambiguous_target");
        if (n_targets == 0) return errResp(response_buf, id, "missing_target");
        const kind = getStr(args, "effect") orelse getStr(args, "kind") orelse return errResp(response_buf, id, "missing_effect");
        const params = getField(args, "params") orelse args;
        const effect_id = model.allocId();
        const bypassed = getBool(params, "bypassed") orelse getBool(args, "bypassed") orelse false;
        var effect: model.Effect = .{ .id = effect_id, .bypassed = bypassed, .params = undefined };
        if (std.mem.eql(u8, kind, "sidechain_compressor")) {
            if (bus_id_opt != null or master_target) return errResp(response_buf, id, "sidechain_on_bus_unsupported");
            const track = ctx.project.findTrack(track_id_opt.?) orelse return errResp(response_buf, id, "track_not_found");
            const source_track_id = getU64(params, "source_track_id") orelse getU64(args, "source_track_id") orelse return errResp(response_buf, id, "missing_source_track_id");
            if (ctx.project.findTrack(source_track_id) == null) return errResp(response_buf, id, "source_track_not_found");
            var p: model.SidechainParams = .{
                .source_track_id = source_track_id,
                .dry_asset_id = firstAudioSourceId(track),
                .wet_asset_id = null,
            };
            if (getF64(params, "threshold_db") orelse getF64(args, "threshold_db")) |v| p.threshold_db = @floatCast(v);
            if (getF64(params, "ratio") orelse getF64(args, "ratio")) |v| p.ratio = @floatCast(@max(v, 1.0));
            if (getF64(params, "attack_ms") orelse getF64(args, "attack_ms")) |v| p.attack_ms = @floatCast(@max(v, 0.1));
            if (getF64(params, "release_ms") orelse getF64(args, "release_ms")) |v| p.release_ms = @floatCast(@max(v, 0.1));
            effect.params = .{ .sidechain_compressor = p };
        } else if (std.mem.eql(u8, kind, "compressor")) {
            var p: model.CompressorParams = .{};
            if (getF64(params, "threshold_db") orelse getF64(args, "threshold_db")) |v| p.threshold_db = @floatCast(v);
            if (getF64(params, "ratio") orelse getF64(args, "ratio")) |v| p.ratio = @floatCast(@max(v, 1.0));
            if (getF64(params, "attack_ms") orelse getF64(args, "attack_ms")) |v| p.attack_ms = @floatCast(@max(v, 0.1));
            if (getF64(params, "release_ms") orelse getF64(args, "release_ms")) |v| p.release_ms = @floatCast(@max(v, 0.1));
            if (getF64(params, "knee_db") orelse getF64(args, "knee_db")) |v| p.knee_db = @floatCast(@max(v, 0.0));
            if (getF64(params, "makeup_db") orelse getF64(args, "makeup_db")) |v| p.makeup_db = @floatCast(v);
            if (getF64(params, "mix") orelse getF64(args, "mix")) |v| p.mix = @floatCast(std.math.clamp(v, 0.0, 1.0));
            effect.params = .{ .compressor = p };
        } else if (std.mem.eql(u8, kind, "limiter")) {
            var p: model.LimiterParams = .{};
            if (getF64(params, "ceiling_dbfs") orelse getF64(args, "ceiling_dbfs") orelse getF64(params, "limit_db") orelse getF64(args, "limit_db")) |v| p.ceiling_dbfs = @floatCast(v);
            if (getF64(params, "threshold_db") orelse getF64(args, "threshold_db")) |v| p.threshold_db = @floatCast(v) else p.threshold_db = p.ceiling_dbfs;
            if (getF64(params, "release_ms") orelse getF64(args, "release_ms")) |v| p.release_ms = @floatCast(@max(v, 0.1));
            if (getF64(params, "lookahead_ms") orelse getF64(args, "lookahead_ms")) |v| p.lookahead_ms = @floatCast(@max(v, 0.0));
            if (getBool(params, "link_channels") orelse getBool(args, "link_channels")) |v| p.link_channels = v;
            effect.params = .{ .limiter = p };
        } else if (std.mem.eql(u8, kind, "delay")) {
            var p: model.DelayParams = .{};
            if (getF64(params, "time_ms") orelse getF64(args, "time_ms")) |v| p.time_ms = @floatCast(@max(v, 1.0));
            if (getF64(params, "feedback") orelse getF64(args, "feedback")) |v| p.feedback = @floatCast(std.math.clamp(v, 0.0, 0.95));
            if (getF64(params, "damping") orelse getF64(args, "damping")) |v| p.damping = @floatCast(std.math.clamp(v, 0.0, 1.0));
            if (getF64(params, "mix") orelse getF64(args, "mix")) |v| p.mix = @floatCast(std.math.clamp(v, 0.0, 1.0));
            effect.params = .{ .delay = p };
        } else if (std.mem.eql(u8, kind, "eq")) {
            var bands: std.ArrayList(model.EqBand) = .empty;
            errdefer bands.deinit(ctx.gpa);
            if (getField(params, "bands")) |bands_v| {
                if (bands_v != .array) return errResp(response_buf, id, "bands_must_be_array");
                for (bands_v.array.items) |band_v| {
                    if (band_v != .object) return errResp(response_buf, id, "band_must_be_object");
                    const band = parseEqBandObject(band_v, ctx.project.sample_rate) catch |e|
                        return errResp(response_buf, id, eqParseErrName(e));
                    bands.append(ctx.gpa, band) catch return errResp(response_buf, id, "oom");
                }
            } else if ((getF64(params, "frequency_hz") orelse getF64(params, "freq") orelse getF64(args, "frequency_hz") orelse getF64(args, "freq")) != null) {
                const band = parseEqBandObject(params, ctx.project.sample_rate) catch
                    parseEqBandObject(args, ctx.project.sample_rate) catch |e|
                        return errResp(response_buf, id, eqParseErrName(e));
                bands.append(ctx.gpa, band) catch return errResp(response_buf, id, "oom");
            }
            // else empty EQ (no bands) allowed
            effect.params = .{ .eq = .{ .bands = bands } };
            bands = .empty;
        } else if (std.mem.eql(u8, kind, "stereo_width")) {
            var p: model.StereoWidthParams = .{};
            if (getStr(params, "mode") orelse getStr(args, "mode")) |ms| {
                if (std.mem.eql(u8, ms, "fullband")) p.mode = .fullband
                else if (std.mem.eql(u8, ms, "crossover")) p.mode = .crossover
                else return errResp(response_buf, id, "invalid_stereo_width_mode");
            }
            if (getF64(params, "width") orelse getF64(args, "width")) |v| p.width = @floatCast(std.math.clamp(v, 0.0, 2.0));
            if (getF64(params, "crossover_hz") orelse getF64(args, "crossover_hz")) |v| p.crossover_hz = @floatCast(std.math.clamp(v, 40.0, 2000.0));
            if (getF64(params, "low_width") orelse getF64(args, "low_width")) |v| p.low_width = @floatCast(std.math.clamp(v, 0.0, 2.0));
            if (getF64(params, "high_width") orelse getF64(args, "high_width")) |v| p.high_width = @floatCast(std.math.clamp(v, 0.0, 2.0));
            effect.params = .{ .stereo_width = p };
        } else {
            return errResp(response_buf, id, "unsupported_effect");
        }
        if (master_target) {
            ctx.project.master_effects.append(ctx.gpa, effect) catch return errResp(response_buf, id, "oom");
            ctx.project.revision += 1;
            ui.markDirty(ctx.view);
            return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"effect_id\":{d},\"target\":\"master\"}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, effect_id }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
        } else if (track_id_opt) |track_id| {
            const track = ctx.project.findTrack(track_id) orelse return errResp(response_buf, id, "track_not_found");
            track.effects.append(ctx.gpa, effect) catch return errResp(response_buf, id, "oom");
            if (effect.params == .sidechain_compressor) ensureDryClipSources(ctx.project, track_id);
            ctx.project.revision += 1;
            ui.markDirty(ctx.view);
            return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"effect_id\":{d},\"track_id\":{d}}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, effect_id, track_id }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
        } else {
            const bus = ctx.project.findBus(bus_id_opt.?) orelse return errResp(response_buf, id, "bus_not_found");
            bus.effects.append(ctx.gpa, effect) catch return errResp(response_buf, id, "oom");
            ctx.project.revision += 1;
            ui.markDirty(ctx.view);
            return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"effect_id\":{d},\"bus_id\":{d}}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, effect_id, bus_id_opt.? }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
        }
    } else if (std.mem.eql(u8, cmd, "set_master_param")) {
        var mutated_project = false;
        if (getF64(args, "volume")) |v| {
            ctx.project.master_volume = @floatCast(@max(v, 0.0));
            mutated_project = true;
        }
        if (getBool(args, "fx_enabled")) |v| {
            ctx.project.master_fx_enabled = v;
            mutated_project = true;
        }
        if (getBool(args, "fx_bypass_all")) |v| ctx.view.fx_bypass_all = v;
        if (mutated_project) {
            ctx.project.revision += 1;
            ui.markDirty(ctx.view);
        }
        return okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "measure")) {
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineMeasure(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
        const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
        if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
        if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
        const target = parseMeasureTarget(args) catch return errResp(response_buf, id, "bad_target");
        const t0 = offline_audio.nowNs();
        const stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, null, ctx.view.fx_bypass_all) catch |e|
            return errResp(response_buf, id, measureErrStr(e));
        ctx.audio_diag.measure_duration_ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t0)) / 1e6;
        var w: std.Io.Writer = .fixed(response_buf);
        w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"target\":\"{s}\",\"track_id\":{d},\"bus_id\":{d},\"window_start_frame\":{d},\"window_length_frames\":{d},\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
            id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame,
            measureTargetKindStr(target),
            if (target == .track) measureTargetId(target) else 0,
            if (target == .bus) measureTargetId(target) else 0,
            stats.window_start_frame, stats.window_length_frames, stats.peak_dbfs, stats.rms_dbfs,
        }) catch {};
        writeRangeStatsTail(&w, stats);
        w.writeAll("}}") catch {};
        return w.buffered();
    } else if (std.mem.eql(u8, cmd, "audition")) {
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineAudition(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        const start_frame = getU64(args, "start_frame") orelse return errResp(response_buf, id, "missing_start_frame");
        const length_frames = getU64(args, "length_frames") orelse return errResp(response_buf, id, "missing_length_frames");
        if (length_frames == 0) return errResp(response_buf, id, "length_frames_must_be_positive");
        if (length_frames > 10 * @as(u64, ctx.project.sample_rate)) return errResp(response_buf, id, "length_frames_too_large");
        const target = parseMeasureTarget(args) catch return errResp(response_buf, id, "bad_target");

        const buf = ctx.gpa.alloc(f32, length_frames * 2) catch return errResp(response_buf, id, "oom");
        defer ctx.gpa.free(buf);
        const t0 = offline_audio.nowNs();
        const stats = measureRange(ctx.gpa, ctx.project, ctx.asset_cache, target, start_frame, length_frames, ctx.project.sample_rate, buf, ctx.view.fx_bypass_all) catch |e|
            return errResp(response_buf, id, if (e == error.TrackNotFound) "track_not_found" else if (e == error.BusNotFound) "bus_not_found" else "audition_failed");
        ctx.audio_diag.audition_duration_ms = @as(f64, @floatFromInt(offline_audio.nowNs() - t0)) / 1e6;

        _ = libc.mkdir(".cache", 0o755);
        _ = libc.mkdir(".cache/audition", 0o755);
        var path_buf: [256]u8 = undefined;
        const path_z: [:0]const u8 = blk: {
            if (getStr(args, "path")) |p| {
                break :blk std.fmt.bufPrintZ(&path_buf, "{s}", .{p}) catch return errResp(response_buf, id, "path_too_long");
            }
            break :blk std.fmt.bufPrintZ(&path_buf, ".cache/audition/{d}.wav", .{op_id}) catch return errResp(response_buf, id, "internal");
        };
        if (!exportRangeWav(buf, length_frames, ctx.project.sample_rate, path_z)) return errResp(response_buf, id, "export_failed");

        var w: std.Io.Writer = .fixed(response_buf);
        w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"path\":\"{s}\",\"target\":\"{s}\",\"track_id\":{d},\"bus_id\":{d},\"window_start_frame\":{d},\"window_length_frames\":{d},\"peak_dbfs\":{d:.2},\"rms_dbfs\":{d:.2},\"gain_reduction_peak_db\":", .{
            id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, path_z,
            measureTargetKindStr(target),
            if (target == .track) measureTargetId(target) else 0,
            if (target == .bus) measureTargetId(target) else 0,
            stats.window_start_frame, stats.window_length_frames, stats.peak_dbfs, stats.rms_dbfs,
        }) catch {};
        writeRangeStatsTail(&w, stats);
        w.writeAll("}}") catch {};
        return w.buffered();
    } else if (std.mem.eql(u8, cmd, "sidechain_assess_and_adjust")) {
        if (requireMixGate(ctx, cmd)) |e| return errResp(response_buf, id, e);
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineAssess(ctx, .sidechain_assess, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleSidechainAssessAndAdjust(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "stereo_width_assess_and_adjust")) {
        if (requireMixGate(ctx, cmd)) |e| return errResp(response_buf, id, e);
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineAssess(ctx, .stereo_width_assess, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleStereoWidthAssessAndAdjust(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "eq_assess_and_adjust")) {
        if (requireMixGate(ctx, cmd)) |e| return errResp(response_buf, id, e);
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineAssess(ctx, .eq_assess, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleEqAssessAndAdjust(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "compressor_assess_and_adjust")) {
        if (requireMixGate(ctx, cmd)) |e| return errResp(response_buf, id, e);
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineAssess(ctx, .compressor_assess, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleCompressorAssessAndAdjust(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "bus_compressor_assess_and_adjust")) {
        if (requireMixGate(ctx, cmd)) |e| return errResp(response_buf, id, e);
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineAssess(ctx, .bus_compressor_assess, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleBusCompressorAssessAndAdjust(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "master_compressor_assess_and_adjust")) {
        if (requireMixGate(ctx, cmd)) |e| return errResp(response_buf, id, e);
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineAssess(ctx, .master_compressor_assess, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleMasterCompressorAssessAndAdjust(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "master_limiter_assess_and_adjust")) {
        if (requireMixGate(ctx, cmd)) |e| return errResp(response_buf, id, e);
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineAssess(ctx, .master_limiter_assess, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleMasterLimiterAssessAndAdjust(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "analyze_wav_file")) {
        const path = getStr(args, "path") orelse return errResp(response_buf, id, "missing_path");
        const scope_s = getStr(args, "analysis_scope") orelse "full_program";
        const scope: loudness.AnalysisScope = if (std.mem.eql(u8, scope_s, "full_program")) .full_program else .measure_window;
        const buf = loadWavInterleavedF32(ctx.gpa, path) catch return errResp(response_buf, id, "wav_load_failed");
        defer ctx.gpa.free(buf.samples);
        const m = stereo_analysis.analyzeProgramBuffer(buf.samples, buf.sample_rate, scope, 0);
        var w: std.Io.Writer = .fixed(response_buf);
        w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"result\":{{\"path\":\"{s}\",\"analysis_scope\":\"{s}\",\"sample_rate\":{d},\"frames\":{d},\"integrated_lufs\":", .{
            id, ctx.project.revision, path, scope_s, buf.sample_rate, m.window_length_frames,
        }) catch {};
        if (m.integrated_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
        w.writeAll(",\"lra_lu\":") catch {};
        if (m.lra_lu) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
        w.writeAll(",\"lra_null_reason\":") catch {};
        if (m.lra_null_reason) |r| w.print("\"{s}\"", .{r}) catch {} else w.writeAll("null") catch {};
        w.print(",\"crest_factor_db\":{d:.2},\"sample_peak_dbfs\":{d:.2},\"true_peak_dbtp\":{d:.2},\"stereo_correlation_mean\":{d:.4},\"stereo_correlation_min\":{d:.4},\"side_to_mid_energy_db\":{d:.2},\"narrowness_localization\":\"{s}\",\"bands\":[", .{
            m.crest_factor_db, m.sample_peak_dbfs, m.true_peak_dbtp, m.stereo_correlation_mean, m.stereo_correlation_min, m.side_to_mid_energy_db, m.stereo.narrowness_localization,
        }) catch {};
        for (m.stereo.bands, 0..) |b, bi| {
            if (bi > 0) w.writeAll(",") catch {};
            w.print("{{\"name\":\"{s}\",\"side_to_mid_db\":{d:.2}}}", .{ b.name, b.side_to_mid_db }) catch {};
        }
        w.writeAll("]}}") catch {};
        return w.buffered();
    } else if (std.mem.eql(u8, cmd, "compare_program_stereo")) {
        const our_path = getStr(args, "our_path") orelse return errResp(response_buf, id, "missing_our_path");
        const ref_path = getStr(args, "ref_path") orelse return errResp(response_buf, id, "missing_ref_path");
        const scope_s = getStr(args, "analysis_scope") orelse "full_program";
        const scope: loudness.AnalysisScope = if (std.mem.eql(u8, scope_s, "full_program")) .full_program else .measure_window;
        const our = loadWavInterleavedF32(ctx.gpa, our_path) catch return errResp(response_buf, id, "our_wav_load_failed");
        defer ctx.gpa.free(our.samples);
        const ref = loadWavInterleavedF32(ctx.gpa, ref_path) catch return errResp(response_buf, id, "ref_wav_load_failed");
        defer ctx.gpa.free(ref.samples);
        const om = stereo_analysis.analyzeProgramBuffer(our.samples, our.sample_rate, scope, 0);
        const rm = stereo_analysis.analyzeProgramBuffer(ref.samples, ref.sample_rate, scope, 0);
        var w: std.Io.Writer = .fixed(response_buf);
        w.print("{{\"id\":{d},\"ok\":true,\"revision\":{d},\"result\":{{\"analysis_scope\":\"{s}\",\"note\":\"Comparable scope only — do not compare measure_window LRA to full_program LRA.\",\"our\":{{\"path\":\"{s}\",\"integrated_lufs\":", .{
            id, ctx.project.revision, scope_s, our_path,
        }) catch {};
        if (om.integrated_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
        w.writeAll(",\"lra_lu\":") catch {};
        if (om.lra_lu) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
        w.print(",\"crest_factor_db\":{d:.2},\"sample_peak_dbfs\":{d:.2},\"true_peak_dbtp\":{d:.2},\"stereo_correlation_mean\":{d:.4},\"stereo_correlation_min\":{d:.4},\"side_to_mid_energy_db\":{d:.2},\"narrowness_localization\":\"{s}\"}},\"ref\":{{\"path\":\"{s}\",\"integrated_lufs\":", .{
            om.crest_factor_db, om.sample_peak_dbfs, om.true_peak_dbtp, om.stereo_correlation_mean, om.stereo_correlation_min, om.side_to_mid_energy_db, om.stereo.narrowness_localization, ref_path,
        }) catch {};
        if (rm.integrated_lufs) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
        w.writeAll(",\"lra_lu\":") catch {};
        if (rm.lra_lu) |v| w.print("{d:.2}", .{v}) catch {} else w.writeAll("null") catch {};
        w.print(",\"crest_factor_db\":{d:.2},\"sample_peak_dbfs\":{d:.2},\"true_peak_dbtp\":{d:.2},\"stereo_correlation_mean\":{d:.4},\"stereo_correlation_min\":{d:.4},\"side_to_mid_energy_db\":{d:.2},\"narrowness_localization\":\"{s}\"}}}}}}", .{
            rm.crest_factor_db, rm.sample_peak_dbfs, rm.true_peak_dbtp, rm.stereo_correlation_mean, rm.stereo_correlation_min, rm.side_to_mid_energy_db, rm.stereo.narrowness_localization,
        }) catch {};
        return w.buffered();
    } else if (std.mem.eql(u8, cmd, "analyze_mix_sections")) {
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        return handleAnalyzeMixSections(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "lead_vocal_balance_assess")) {
        if (requireMixGate(ctx, cmd)) |e| return errResp(response_buf, id, e);
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        return handleLeadVocalBalanceAssess(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "analyze_master_program")) {
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineMasterQc(ctx, .analyze_master_program, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleAnalyzeMasterProgram(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "validate_master_delivery")) {
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineMasterQc(ctx, .validate_master_delivery, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleValidateMasterDelivery(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "mix_session_preflight")) {
        if (heavyBlockedWhileRecording(ctx)) return errResp(response_buf, id, "heavy_command_blocked_while_recording");
        if (preferOfflineAsync(ctx)) {
            return enqueueOfflineMasterQc(ctx, .mix_session_preflight, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
        }
        return handleMixSessionPreflight(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "begin_trial")) {
        return handleBeginTrial(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "resolve_trial")) {
        return handleResolveTrial(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "confirm_trial")) {
        return handleConfirmTrial(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "reject_trial")) {
        return handleRejectTrial(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "abort_trial")) {
        return handleAbortTrial(ctx, args, id, op_id, revision_before, applied_at_audio_frame, response_buf);
    } else if (std.mem.eql(u8, cmd, "get_job")) {
        if (getBool(args, "render") orelse false) {
            const busy = ctx.render_state.thread != null and !ctx.render_state.done.load(.monotonic);
            const done = ctx.render_state.thread != null and ctx.render_state.done.load(.monotonic);
            const status: []const u8 = if (busy) "running" else if (done) (if (ctx.render_state.ok.load(.monotonic)) "succeeded" else "failed") else "idle";
            return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"result\":{{\"kind\":\"render\",\"status\":\"{s}\"}}}}", .{ id, status }) catch errResp(response_buf, id, "response_too_large");
        }
        const job_id = getU64(args, "job_id") orelse return errResp(response_buf, id, "missing_job_id");
        const oj = ctx.offline_registry.peek();
        if (oj.id == job_id and oj.id != 0) {
            const st: offline_audio.Status = @enumFromInt(oj.status.load(.acquire));
            const status: []const u8 = switch (st) {
                .idle => "idle",
                .running => "running",
                .succeeded => "succeeded",
                .failed => "failed",
            };
            if (st == .running) {
                return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"result\":{{\"job_id\":{d},\"status\":\"{s}\",\"kind\":\"{s}\",\"revision_at_start\":{d}}}}}", .{ id, oj.id, status, oj.kind.name(), oj.revision_at_start }) catch errResp(response_buf, id, "response_too_large");
            }
            if (oj.thread) |th| {
                th.join();
                oj.thread = null;
            }
            ctx.audio_diag.measure_duration_ms = oj.measure_duration_ms;
            ctx.audio_diag.audition_duration_ms = oj.audition_duration_ms;
            ctx.audio_diag.level_match_duration_ms = oj.level_match_duration_ms;
            ctx.audio_diag.trial_duration_ms = oj.trial_duration_ms;
            if (st == .failed) {
                return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":false,\"error\":\"{s}\",\"result\":{{\"job_id\":{d},\"status\":\"failed\",\"kind\":\"{s}\"}}}}", .{ id, oj.err_msg orelse "failed", oj.id, oj.kind.name() }) catch errResp(response_buf, id, "response_too_large");
            }
            // Assess: apply clone decision onto live project when revision still matches.
            if (oj.apply_target != .none) {
                applyOfflineAssessToLive(ctx, oj);
            }
            // Preflight: move the worker's passed gate onto the live one.
            if (oj.pending_gate != null) {
                applyOfflinePreflightGateToLive(ctx, oj);
            }
            const payload = oj.result_json orelse "{}";
            const decision_note: []const u8 = switch (oj.apply_decision) {
                0 => "committed",
                1 => "rolled_back",
                2 => "needs_human_listening",
                else => "conflict",
            };
            return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"result\":{{\"job_id\":{d},\"status\":\"succeeded\",\"kind\":\"{s}\",\"revision_at_start\":{d},\"revision_at_compute\":{d},\"measure_duration_ms\":{d:.2},\"audition_duration_ms\":{d:.2},\"level_match_duration_ms\":{d:.2},\"trial_duration_ms\":{d:.2},\"applied_decision\":\"{s}\",\"payload\":{s}}}}}", .{ id, ctx.project.revision, oj.id, oj.kind.name(), oj.revision_at_start, oj.revision_at_compute, oj.measure_duration_ms, oj.audition_duration_ms, oj.level_match_duration_ms, oj.trial_duration_ms, decision_note, payload }) catch errResp(response_buf, id, "response_too_large");
        }
        const job = ctx.job_registry.find(job_id) orelse return errResp(response_buf, id, "job_not_found");
        const status: []const u8 = switch (job.status) {
            .running => "running",
            .succeeded => "succeeded",
            .failed => "failed",
        };
        return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"result\":{{\"job_id\":{d},\"status\":\"{s}\",\"exit_code\":{d}}}}}", .{ id, job.id, status, job.exit_code }) catch errResp(response_buf, id, "response_too_large");
    } else if (std.mem.eql(u8, cmd, "import_audio")) {
        const track_id = getU64(args, "track_id") orelse return errResp(response_buf, id, "missing_track_id");
        const path = getStr(args, "path") orelse return errResp(response_buf, id, "missing_path");
        const start_bar = getF64(args, "start_bar") orelse 0.0;
        const trim_start_ms = getF64(args, "trim_start_ms") orelse 0.0;
        if (ctx.project.findTrack(track_id) == null) return errResp(response_buf, id, "track_not_found");

        _ = libc.mkdir(".cache", 0o755);
        _ = libc.mkdir(".cache/imported", 0o755);

        const asset_id = model.allocId();
        var pi: PendingImport = .{
            .job_id = 0,
            .track_id = track_id,
            .asset_id = asset_id,
            .cache_path_len = 0,
            .start_frame = 0,
            .source_offset_frames = @intFromFloat(@max(0.0, trim_start_ms) / 1000.0 * @as(f64, @floatFromInt(ctx.project.sample_rate))),
            .source_bpm = getF64(args, "source_bpm"),
        };
        const cache_path_z = std.fmt.bufPrintZ(&pi.cache_path, ".cache/imported/{d}.wav", .{asset_id}) catch return errResp(response_buf, id, "path_too_long");
        pi.cache_path_len = cache_path_z.len;
        var rate_buf: [16]u8 = undefined;
        const rate_str = std.fmt.bufPrint(&rate_buf, "{d}", .{ctx.project.sample_rate}) catch return errResp(response_buf, id, "internal");

        const job_id = ctx.job_registry.spawn(ctx.gpa, ctx.io, &.{ FFMPEG_PATH, "-y", "-i", path, "-ar", rate_str, cache_path_z }) catch return errResp(response_buf, id, "ffmpeg_spawn_failed");
        pi.job_id = job_id;

        const beat_sec = 60.0 / ctx.project.bpm;
        const bar_sec = @as(f64, @floatFromInt(ctx.project.bar_size)) * beat_sec;
        pi.start_frame = @intFromFloat(start_bar * bar_sec * @as(f64, @floatFromInt(ctx.project.sample_rate)));

        ctx.pending_imports.append(ctx.gpa, pi) catch return errResp(response_buf, id, "oom");

        // revision doesn't change yet -- the import completes asynchronously
        // (see finishPendingImports); revision_after will show up later via
        // get_project_summary/get_live_state once the job succeeds.
        return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"job_id\":{d},\"asset_id\":{d},\"status\":\"queued\"}}}}", .{ id, ctx.project.revision, op_id, revision_before, applied_at_audio_frame, job_id, asset_id }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "render")) {
        const path = getStr(args, "path") orelse return errResp(response_buf, id, "missing_path");
        if (ctx.render_state.thread != null and !ctx.render_state.done.load(.monotonic)) {
            return errResp(response_buf, id, "render_already_in_progress");
        }
        if (ctx.render_state.thread) |th| {
            th.join();
            ctx.render_state.thread = null;
        }
        const path_owned = ctx.gpa.dupe(u8, path) catch return errResp(response_buf, id, "oom");
        ctx.render_state.done.store(false, .monotonic);
        ctx.render_state.ok.store(false, .monotonic);
        ctx.render_state.path = path_owned;
        ctx.render_state.thread = std.Thread.spawn(.{}, renderThreadFn, .{ ctx.gpa, ctx.project, ctx.asset_cache, path_owned, ctx.render_state }) catch {
            ctx.gpa.free(path_owned);
            ctx.render_state.path = null;
            return errResp(response_buf, id, "thread_spawn_failed");
        };
        return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"result\":{{\"status\":\"rendering\"}}}}", .{id}) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    } else if (std.mem.eql(u8, cmd, "get_audio_config")) {
        const bs = if (ctx.audio_block_size) |p| p.* else audio_config.DEFAULT_BLOCK_SIZE;
        return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"result\":{{\"block_size\":{d},\"allowed\":[512,1024,2048,4096],\"sample_rate_project\":{d}}}}}", .{
            id,
            bs,
            SAMPLE_RATE,
        }) catch errResp(response_buf, id, "response_too_large");
    } else if (std.mem.eql(u8, cmd, "set_audio_config")) {
        const pending_slot = ctx.pending_audio_block_size orelse return errResp(response_buf, id, "audio_config_unavailable");
        const bs = getU64(args, "block_size") orelse return errResp(response_buf, id, "missing_block_size");
        if (bs > std.math.maxInt(u32)) return errResp(response_buf, id, "block_size_out_of_range");
        const n: u32 = @intCast(bs);
        if (!audio_config.isAllowedBlockSize(n)) return errResp(response_buf, id, "invalid_block_size");
        pending_slot.* = n;
        return std.fmt.bufPrint(response_buf, "{{\"id\":{d},\"ok\":true,\"revision\":{d},\"operation_id\":{d},\"revision_before\":{d},\"applied_at_audio_frame\":{d},\"result\":{{\"block_size\":{d},\"status\":\"pending_apply\"}}}}", .{
            id,
            ctx.project.revision,
            op_id,
            revision_before,
            applied_at_audio_frame,
            n,
        }) catch okResp(response_buf, id, op_id, revision_before, ctx.project.revision, applied_at_audio_frame);
    }

    return errResp(response_buf, id, "unknown_command");
}

fn freeAssetCache(gpa: std.mem.Allocator, cache: *mixer.AssetCache) void {
    var it = cache.iterator();
    while (it.next()) |e| gpa.free(e.value_ptr.samples);
    cache.clearRetainingCapacity();
}

fn applyAudioBlockSize(
    stream: *c.AudioStream,
    audio_block_size: *u32,
    view: *ui.View,
    audio_diag: *AudioDiag,
    gpa: std.mem.Allocator,
    new_size: u32,
) void {
    const sz = audio_config.sanitizeBlockSize(new_size);
    if (sz == audio_block_size.*) {
        view.audio_block_size = sz;
        return;
    }
    view.transport = .stop;
    c.StopAudioStream(stream.*);
    c.UnloadAudioStream(stream.*);
    audio_block_size.* = sz;
    view.audio_block_size = sz;
    c.SetAudioStreamBufferSizeDefault(@intCast(sz));
    stream.* = c.LoadAudioStream(SAMPLE_RATE, 32, 2);
    c.PlayAudioStream(stream.*);
    audio_diag.* = .{};
    // Must track the real configured block size -- the struct default
    // (2048*2) silently understated/misstated underrun risk at every other
    // block size, since noteFillGap()'s low-watermark math is computed
    // against this field.
    audio_diag.stream_capacity_frames = @as(u64, sz) * 2;
    audio_diag.buffer_low_watermark_frames = @intCast(audio_diag.stream_capacity_frames);
    audio_config.save(gpa, audio_config.CONFIG_PATH, .{ .block_size = sz }) catch {};
    var msg_buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Block size {d}", .{sz}) catch "Block size set";
    ui.setStatusMsg(view, msg);
    std.debug.print("audio block_size -> {d}\n", .{sz});
}

fn reloadAssetCache(gpa: std.mem.Allocator, project: *const model.Project, cache: *mixer.AssetCache) !void {
    freeAssetCache(gpa, cache);
    for (project.assets.items) |a| {
        const loaded = try loadWavAsAsset(gpa, a.relative_path);
        try cache.put(a.id, loaded);
    }
}

const STEM_FILES = [_][]const u8{
    "0 Lead Vocals.wav",
    "1 Backing Vocals.wav",
    "2 Drums.wav",
    "3 Bass.wav",
    "4 Guitar.wav",
    "5 Keyboard.wav",
    "6 Synth.wav",
    "7 Other.wav",
};

/// RPP-length ~277.64s @ 127bpm 4/4 → ~147 bars. Matches "999 - final master wide".
const BOOTSTRAP_BPM: f64 = 127.0;
const BOOTSTRAP_LENGTH_BARS: i64 = 147;

fn bootstrapStemsProject(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: *model.Project,
    asset_cache: *mixer.AssetCache,
    stems_dir: []const u8,
) !void {
    // Wipe current project content.
    freeAssetCache(gpa, asset_cache);
    project.deinit(gpa);
    project.* = .{};
    model.syncIdCounter(project); // resets nothing useful; alloc starts fresh if next_id already high — ok

    project.bpm = BOOTSTRAP_BPM;
    project.bar_size = 4;
    project.bar_quant = 16;
    project.length_bars = BOOTSTRAP_LENGTH_BARS;
    project.sample_rate = SAMPLE_RATE;

    _ = libc.mkdir(".cache", 0o755);
    _ = libc.mkdir(".cache/imported", 0o755);

    var rate_buf: [16]u8 = undefined;
    const rate_str = try std.fmt.bufPrint(&rate_buf, "{d}", .{SAMPLE_RATE});

    for (STEM_FILES, 0..) |fname, i| {
        var in_buf: [1024]u8 = undefined;
        const in_path = try std.fmt.bufPrint(&in_buf, "{s}/{s}", .{ stems_dir, fname });

        const track_name = fname[0 .. fname.len - 4]; // strip .wav
        const track = try project.addTrack(gpa, track_name);
        if (i == 0) track.armed = true;

        const asset_id = model.allocId();
        var out_buf: [256]u8 = undefined;
        const out_path = try std.fmt.bufPrintZ(&out_buf, ".cache/imported/{d}.wav", .{asset_id});

        std.debug.print("bootstrap: importing {s} ...\n", .{fname});
        const result = try std.process.run(gpa, io, .{
            .argv = &.{ FFMPEG_PATH, "-y", "-i", in_path, "-ar", rate_str, out_path },
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("ffmpeg failed for {s}:\n{s}\n", .{ fname, result.stderr });
                return error.FfmpegFailed;
            },
            else => return error.FfmpegFailed,
        }

        const loaded = try loadWavAsAsset(gpa, out_path);
        try asset_cache.put(asset_id, loaded);

        const path_owned = try gpa.dupe(u8, out_path);
        try project.assets.append(gpa, .{
            .id = asset_id,
            .relative_path = path_owned,
            .sample_rate = SAMPLE_RATE,
            .channels = loaded.channels,
            .frame_count = loaded.frame_count,
            .source_bpm = BOOTSTRAP_BPM,
        });

        try track.clips.append(gpa, .{ .audio = .{
            .id = model.allocId(),
            .source_id = asset_id,
            .timeline_start_frame = 0,
            .source_offset_frames = 0,
        } });
    }

    // Only first track armed
    for (project.tracks.items, 0..) |*t, i| t.armed = (i == 0);

    // RPP sidechain intent (Drums → Bass/Guitar): declared Effect only.
    // Playback stays on clean stems; wet bake happens when FX is un-bypassed (U2).
    try declareRppSidechains(gpa, project);

    project.revision = 0;
    std.debug.print("bootstrap: OK — {d} tracks @ {d} BPM, length_bars={d}\n", .{ project.tracks.items.len, project.bpm, project.length_bars });
}

fn findTrackByNameContains(project: *model.Project, needle: []const u8) ?*model.Track {
    for (project.tracks.items) |*t| {
        if (std.mem.indexOf(u8, t.name, needle) != null) return t;
    }
    return null;
}

fn firstAudioSourceId(track: *const model.Track) ?model.AssetId {
    for (track.clips.items) |clip| {
        if (clip == .audio) return clip.audio.source_id;
    }
    return null;
}

fn declareSidechainOnTrack(gpa: std.mem.Allocator, target: *model.Track, drums: *const model.Track, ratio: f32) !void {
    const dry = firstAudioSourceId(target) orelse return;
    try target.effects.append(gpa, .{
        .id = model.allocId(),
        .bypassed = false,
        .params = .{ .sidechain_compressor = .{
            .source_track_id = drums.id,
            .threshold_db = -18,
            .ratio = ratio,
            .attack_ms = 5,
            .release_ms = 100,
            .dry_asset_id = dry,
            .wet_asset_id = null,
        } },
    });
}

fn declareRppSidechains(gpa: std.mem.Allocator, project: *model.Project) !void {
    const drums = findTrackByNameContains(project, "Drums") orelse return;
    if (findTrackByNameContains(project, "Bass")) |bass| {
        try declareSidechainOnTrack(gpa, bass, drums, 15);
    }
    if (findTrackByNameContains(project, "Guitar")) |gtr| {
        try declareSidechainOnTrack(gpa, gtr, drums, 12);
    }
}

/// Keep clips pointing at dry assets — realtime mixer applies sidechain GR.
fn ensureDryClipSources(project: *model.Project, track_id: model.TrackId) void {
    const track = project.findTrack(track_id) orelse return;
    for (track.effects.items) |eff| {
        if (eff.params != .sidechain_compressor) continue;
        const dry = eff.params.sidechain_compressor.dry_asset_id orelse continue;
        for (track.clips.items) |*clip| {
            if (clip.* == .audio) clip.audio.source_id = dry;
        }
    }
}

fn alignStemsToGrid(gpa: std.mem.Allocator, io: std.Io, project: *model.Project) !i64 {
    const ref_track = findTrackByNameContains(project, "Drums") orelse blk: {
        for (project.tracks.items) |*t| {
            for (t.clips.items) |clip| if (clip == .audio) break :blk t;
        }
        return error.NoAudioToAlign;
    };
    var ref_clip: ?model.AudioClip = null;
    for (ref_track.clips.items) |clip| {
        if (clip == .audio) {
            ref_clip = clip.audio;
            break;
        }
    }
    const rc = ref_clip orelse return error.NoAudioToAlign;
    const asset = for (project.assets.items) |a| {
        if (a.id == rc.source_id) break a;
    } else return error.NoAudioToAlign;

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ AUBIOONSET_PATH, "-i", asset.relative_path, "-T", "samples" },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("aubioonset failed:\n{s}\n", .{result.stderr});
            return error.AubioFailed;
        },
        else => return error.AubioFailed,
    }

    // aubio often reports a spurious onset at sample 0 (file edge). That made
    // ALIGN a no-op while the real first kick sat ~constant offset later →
    // metronome on the BPM grid never locked to drums.
    const min_onset_samples: u64 = 256;
    var first_onset: ?u64 = null;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        const sample = try std.fmt.parseInt(u64, trimmed, 10);
        if (sample < min_onset_samples) continue;
        first_onset = sample;
        break;
    }
    const onset_in_file: i64 = @intCast(first_onset orelse return error.NoOnsetFound);

    // Where that onset currently sits on the project timeline (frames).
    const onset_timeline: i64 = rc.timeline_start_frame + onset_in_file - @as(i64, @intCast(rc.source_offset_frames));

    const beat_sec = 60.0 / project.bpm;
    const beat_frames_f = beat_sec * @as(f64, @floatFromInt(project.sample_rate));
    if (beat_frames_f < 1.0) return error.BadTempo;
    const beat_frames: i64 = @intFromFloat(@round(beat_frames_f));

    // Snap onset to nearest beat line (not only bar) so metro clicks lock to kick.
    const beat_index = @divTrunc(onset_timeline + @divTrunc(beat_frames, 2), beat_frames);
    const target: i64 = beat_index * beat_frames;
    const delta: i64 = target - onset_timeline;

    for (project.tracks.items) |*t| {
        for (t.clips.items) |*clip| {
            if (clip.* != .audio) continue;
            clip.audio.timeline_start_frame += delta;
            // Keep any existing source offset; don't force-zero (lead-in trim).
        }
    }
    project.revision += 1;
    std.debug.print(
        "ALIGN: onset_file={d} onset_tl={d} → beat {d} (target={d}), delta={d} frames (~{d:.3}s)\n",
        .{
            onset_in_file,
            onset_timeline,
            beat_index,
            target,
            delta,
            @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(project.sample_rate)),
        },
    );
    return delta;
}

fn parseArgs() struct { bootstrap: ?[]const u8, load: ?[]const u8 } {
    var bootstrap: ?[]const u8 = null;
    var load_path: ?[]const u8 = null;

    // Zig 0.16 reshaped process args; on macOS libc exposes argv via CRT helpers.
    const NS = struct {
        extern "c" fn _NSGetArgc() *c_int;
        extern "c" fn _NSGetArgv() *[*][*:0]u8;
    };
    const argc = NS._NSGetArgc().*;
    const argv = NS._NSGetArgv().*;
    var i: c_int = 1;
    while (i < argc) : (i += 1) {
        const a = std.mem.span(argv[@intCast(i)]);
        if (std.mem.eql(u8, a, "--bootstrap") and i + 1 < argc) {
            i += 1;
            bootstrap = std.mem.span(argv[@intCast(i)]);
        } else if (std.mem.eql(u8, a, "--load") and i + 1 < argc) {
            i += 1;
            load_path = std.mem.span(argv[@intCast(i)]);
        }
    }

    // Env fallback (handy when argv plumbing is awkward).
    if (bootstrap == null) {
        if (std.c.getenv("FASTMIX_BOOTSTRAP")) |p| bootstrap = std.mem.span(p);
    }
    if (load_path == null) {
        if (std.c.getenv("FASTMIX_LOAD")) |p| load_path = std.mem.span(p);
    }
    return .{ .bootstrap = bootstrap, .load = load_path };
}

fn finishPendingImports(gpa: std.mem.Allocator, project: *model.Project, asset_cache: *mixer.AssetCache, registry: *jobs.Registry, pending: *std.ArrayList(PendingImport)) void {
    var i: usize = 0;
    while (i < pending.items.len) {
        const pi = pending.items[i];
        const job = registry.find(pi.job_id) orelse {
            i += 1;
            continue;
        };
        if (job.status == .running) {
            i += 1;
            continue;
        }
        defer _ = pending.orderedRemove(i);
        if (job.status != .succeeded) continue;

        const path = pi.cache_path[0..pi.cache_path_len];
        const loaded = loadWavAsAsset(gpa, path) catch continue;
        asset_cache.put(pi.asset_id, loaded) catch {
            gpa.free(loaded.samples);
            continue;
        };
        const path_owned = gpa.dupe(u8, path) catch continue;
        project.assets.append(gpa, .{
            .id = pi.asset_id,
            .relative_path = path_owned,
            .sample_rate = project.sample_rate,
            .channels = loaded.channels,
            .frame_count = loaded.frame_count,
            .source_bpm = pi.source_bpm,
        }) catch {
            gpa.free(path_owned);
            continue;
        };
        const track = project.findTrack(pi.track_id) orelse continue;
        track.clips.append(gpa, .{ .audio = .{
            .id = model.allocId(),
            .source_id = pi.asset_id,
            .timeline_start_frame = pi.start_frame,
            .source_offset_frames = pi.source_offset_frames,
        } }) catch continue;
        for (track.effects.items) |*eff| {
            if (eff.params == .sidechain_compressor and eff.params.sidechain_compressor.dry_asset_id == null) {
                eff.params.sidechain_compressor.dry_asset_id = pi.asset_id;
            }
        }
        project.revision += 1;
    }
}

fn beginMidiRecord(gpa: std.mem.Allocator, project: *model.Project, voice_pool: []mixer.Voice, notes_monitor: []const bool, notes_capture: []bool, beat_time: f64, bar_sec: f64) void {
    var armed_track_id: ?model.TrackId = null;
    for (project.tracks.items) |t| {
        if (t.armed) {
            armed_track_id = t.id;
            break;
        }
    }
    if (armed_track_id) |tid| {
        mixer.silenceSource(voice_pool, tid, .replay);
        const track = project.findTrack(tid).?;
        const start_bar: i64 = @intFromFloat(@floor(beat_time / bar_sec));
        track.clips.append(gpa, .{ .midi = .{ .id = model.allocId(), .start_bar = start_bar, .bars = 1, .events = .empty } }) catch return;
        const clip = &track.clips.items[track.clips.items.len - 1].midi;
        for (0..KEYBOARD_COUNT) |i| {
            if (notes_monitor[i]) {
                notes_capture[i] = true;
                clip.events.append(gpa, .{ .quant = 0, .semitone = @intCast(i), .start = true }) catch {};
            } else {
                notes_capture[i] = false;
            }
        }
    }
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Temporary window so raylib/GLFW can query the monitor; first launch
    // writes fastmix_window.json with that resolution, then we size+maximize.
    c.SetConfigFlags(c.FLAG_MSAA_4X_HINT | c.FLAG_WINDOW_RESIZABLE | c.FLAG_WINDOW_MAXIMIZED);
    c.InitWindow(800, 600, "FastMix AI");
    defer c.CloseWindow();

    const monitor = c.GetCurrentMonitor();
    const detect_w = c.GetMonitorWidth(monitor);
    const detect_h = c.GetMonitorHeight(monitor);
    const win_cfg = window_config.loadOrCreate(gpa, window_config.CONFIG_PATH, detect_w, detect_h) catch window_config.WindowConfig{
        .width = if (detect_w > 0) detect_w else 1280,
        .height = if (detect_h > 0) detect_h else 720,
    };
    c.SetWindowSize(win_cfg.width, win_cfg.height);
    c.MaximizeWindow();

    c.SetTargetFPS(60);
    c.SetExitKey(c.KEY_NULL);

    c.InitAudioDevice();
    defer c.CloseAudioDevice();

    const audio_cfg = audio_config.loadOrDefault(gpa, audio_config.CONFIG_PATH);
    var audio_block_size: u32 = audio_cfg.block_size;
    var pending_audio_block_size: ?u32 = null;
    c.SetAudioStreamBufferSizeDefault(@intCast(audio_block_size));
    var stream = c.LoadAudioStream(SAMPLE_RATE, 32, 2);
    defer c.UnloadAudioStream(stream);
    c.PlayAudioStream(stream);

    var audio_buffer: [MAX_AUDIO_BLOCK * 2]f32 = undefined;
    var frame_count: u64 = 0;
    var click_remaining: u32 = 0;

    var voice_pool: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;

    var notes_monitor = [_]bool{false} ** KEYBOARD_COUNT;
    var notes_monitor_prev = [_]bool{false} ** KEYBOARD_COUNT;
    var notes_capture = [_]bool{false} ** KEYBOARD_COUNT;

    var project: model.Project = .{};
    defer project.deinit(gpa);

    var history: persist.History = .{};
    defer history.deinit(gpa);

    var server = try socket.Server.init(SOCKET_PATH);
    defer server.deinit();

    var job_registry: jobs.Registry = .{};
    defer job_registry.deinit(gpa);
    var offline_registry = offline_audio.Registry.init(gpa);
    defer offline_registry.deinit();


    var asset_cache = mixer.AssetCache.init(gpa);
    defer {
        freeAssetCache(gpa, &asset_cache);
        asset_cache.deinit();
    }

    var pending_imports: std.ArrayList(PendingImport) = .empty;
    defer pending_imports.deinit(gpa);

    var render_state: RenderState = .{};
    defer if (render_state.thread) |th| th.join();

    var sc_rt = mixer.SidechainRuntime.init(gpa);
    defer sc_rt.deinit();
    var eq_rt = mixer.EqRuntime.init(gpa);
    defer eq_rt.deinit();
    var comp_rt = mixer.CompressorRuntime.init(gpa);
    defer comp_rt.deinit();
    var delay_rt = mixer.DelayRuntime.init(gpa);
    defer delay_rt.deinit();
    var lim_rt = mixer.LimiterRuntime.init(gpa);
    defer lim_rt.deinit();
    var width_rt = mixer.StereoWidthRuntime.init(gpa);
    defer width_rt.deinit();
    var trial_registry = trial.Registry.init(gpa);
    defer trial_registry.deinit();

    var live_peaks: LivePeaks = .{};
    var audio_diag = AudioDiag{};

    const cli = parseArgs();
    var project_path: ?[]const u8 = null;
    if (cli.load) |path| {
        const loaded = try persist.load(gpa, path);
        project = loaded;
        try reloadAssetCache(gpa, &project, &asset_cache);
        project_path = path;
        std.debug.print("loaded project {s} ({d} tracks)\n", .{ path, project.tracks.items.len });
    } else if (cli.bootstrap) |dir| {
        try bootstrapStemsProject(gpa, io, &project, &asset_cache, dir);
        project_path = "999.fastmix.json";
        persist.saveAtomic(gpa, &project, project_path.?) catch |err| {
            std.debug.print("warning: auto-save after bootstrap failed: {}\n", .{err});
        };
    } else {
        const first = try project.addTrack(gpa, "Track 1");
        first.armed = true;
        _ = try project.addTrack(gpa, "Track 2");
        project.revision = 0;
    }

    var view: ui.View = .{};
    view.audio_block_size = audio_block_size;
    if (project.tracks.items.len > 0) view.selected_track = project.tracks.items[0].id;

    var beat_time: f64 = 0.0;
    var last_replay_quant: ?i64 = null;
    var operation_counter: u64 = 0;

    var mix_gate: mix_preflight.MixSessionGate = .{};
    defer mix_gate.clear(gpa);

    var dispatch_ctx = DispatchCtx{
        .gpa = gpa,
        .io = io,
        .project = &project,
        .project_path = &project_path,
        .history = &history,
        .asset_cache = &asset_cache,
        .job_registry = &job_registry,
        .offline_registry = &offline_registry,
        .pending_imports = &pending_imports,
        .render_state = &render_state,
        .transport = &view.transport,
        .beat_time = &beat_time,
        .live_peaks = &live_peaks,
        .audio_diag = &audio_diag,
        .view = &view,
        .sc_rt = &sc_rt,
        .trial_registry = &trial_registry,
        .frame_count = &frame_count,
        .operation_counter = &operation_counter,
        .mix_gate = &mix_gate,
        .pending_audio_block_size = &pending_audio_block_size,
        .audio_block_size = &audio_block_size,
    };

    while (!c.WindowShouldClose()) {
        server.poll(*DispatchCtx, &dispatch_ctx, handleCommandTimed);
        job_registry.poll();
        finishPendingImports(gpa, &project, &asset_cache, &job_registry, &pending_imports);

        if (pending_audio_block_size) |n| {
            pending_audio_block_size = null;
            applyAudioBlockSize(&stream, &audio_block_size, &view, &audio_diag, gpa, n);
        }

        if (render_state.thread != null and render_state.done.load(.monotonic)) {
            if (render_state.thread) |th| {
                th.join();
                render_state.thread = null;
            }
            if (render_state.ok.load(.monotonic)) {
                ui.setStatusMsg(&view, "Render done");
            } else {
                ui.setStatusMsg(&view, "Render failed");
            }
        }

        const beat_sec: f64 = 60.0 / project.bpm;
        const bar_sec: f64 = @as(f64, @floatFromInt(project.bar_size)) * beat_sec;
        const quant_sec: f64 = bar_sec / @as(f64, @floatFromInt(project.bar_quant));
        const project_sec: f64 = @as(f64, @floatFromInt(project.length_bars)) * bar_sec;

        const sw = c.GetScreenWidth();
        const sh = c.GetScreenHeight();
        const chrome = ui.computeChrome(sw, sh);

        var seek_bar: ?f64 = null;
        ui.handleInputAlloc(gpa, &history, &project, &view, chrome, &seek_bar);
        if (seek_bar) |bar| {
            beat_time = std.math.clamp(bar, 0.0, @as(f64, @floatFromInt(project.length_bars))) * bar_sec;
            if (view.transport == .play) {} else view.transport = .stop;
            last_replay_quant = null;
            sc_rt.reset();
            eq_rt.reset();
            comp_rt.reset();
            delay_rt.reset();
            lim_rt.reset();
            width_rt.reset();
        }

        if (view.fx_apply_track) |tid| {
            view.fx_apply_track = null;
            // Live DSP — only keep dry clips pointed right; no bake, no stop.
            ensureDryClipSources(&project, tid);
        }

        // Ctrl/Cmd+S/O/N — before menu_action dispatch this frame
        const mod = c.IsKeyDown(c.KEY_LEFT_CONTROL) or c.IsKeyDown(c.KEY_RIGHT_CONTROL) or c.IsKeyDown(c.KEY_LEFT_SUPER) or c.IsKeyDown(c.KEY_RIGHT_SUPER);
        if (mod and c.IsKeyPressed(c.KEY_S) and view.menu_action == .none) {
            view.menu_action = .save;
        }
        if (mod and c.IsKeyPressed(c.KEY_O) and view.menu_action == .none) {
            ui.requestDestructive(&view, .open);
        }
        if (mod and c.IsKeyPressed(c.KEY_N) and view.menu_action == .none) {
            ui.requestDestructive(&view, .new_project);
        }

        switch (view.menu_action) {
            .none => {},
            .save => {
                view.menu_action = .none;
                if (project_path) |path| {
                    if (persist.saveAtomic(gpa, &project, path)) |_| {
                        ui.clearDirty(&view);
                        ui.setStatusMsg(&view, "Saved");
                        std.debug.print("saved {s}\n", .{path});
                    } else |err| {
                        ui.setStatusMsg(&view, "Save failed");
                        std.debug.print("save failed: {}\n", .{err});
                    }
                } else {
                    ui.openPathModal(&view, .save_as, "project.fastmix.json");
                }
            },
            .save_as_confirm => {
                view.menu_action = .none;
                const path = view.open_path_buf[0..view.open_path_len];
                if (path.len == 0) {
                    ui.setStatusMsg(&view, "Save As: empty path");
                } else if (persist.saveAtomic(gpa, &project, path)) |_| {
                    project_path = gpa.dupe(u8, path) catch path;
                    ui.clearDirty(&view);
                    ui.setStatusMsg(&view, "Saved");
                    std.debug.print("saved as {s}\n", .{path});
                    if (view.dirty_pending != .none) ui.resolveDirtyContinue(&view);
                } else |err| {
                    ui.setStatusMsg(&view, "Save As failed");
                    std.debug.print("save as failed: {}\n", .{err});
                    view.dirty_pending = .none;
                    view.show_dirty_confirm = false;
                }
            },
            .open_confirm => {
                view.menu_action = .none;
                const path = view.open_path_buf[0..view.open_path_len];
                if (path.len > 0) {
                    if (persist.load(gpa, path)) |loaded| {
                        freeAssetCache(gpa, &asset_cache);
                        project.deinit(gpa);
                        project = loaded;
                        reloadAssetCache(gpa, &project, &asset_cache) catch |err| {
                            std.debug.print("asset reload failed: {}\n", .{err});
                        };
                        project_path = gpa.dupe(u8, path) catch "999.fastmix.json";
                        if (project.tracks.items.len > 0) view.selected_track = project.tracks.items[0].id else view.selected_track = null;
                        beat_time = 0;
                        last_replay_quant = null;
                        view.transport = .stop;
                        view.fx_target = .none;
                        ui.clearDirty(&view);
                        ui.setStatusMsg(&view, "Opened");
                        std.debug.print("loaded {s}\n", .{path});
                    } else |_| {
                        ui.setStatusMsg(&view, "Open failed");
                        std.debug.print("load failed: {s}\n", .{path});
                    }
                }
            },
            .new_project => {
                view.menu_action = .none;
                freeAssetCache(gpa, &asset_cache);
                project.deinit(gpa);
                project = .{};
                _ = project.addTrack(gpa, "Track 1") catch {};
                project_path = null;
                view.selected_track = if (project.tracks.items.len > 0) project.tracks.items[0].id else null;
                beat_time = 0;
                last_replay_quant = null;
                view.transport = .stop;
                view.fx_target = .none;
                ui.clearDirty(&view);
                ui.setStatusMsg(&view, "New project");
            },
            .close_project => {
                view.menu_action = .none;
                freeAssetCache(gpa, &asset_cache);
                project.deinit(gpa);
                project = .{};
                _ = project.addTrack(gpa, "Track 1") catch {};
                project_path = null;
                view.selected_track = if (project.tracks.items.len > 0) project.tracks.items[0].id else null;
                beat_time = 0;
                last_replay_quant = null;
                view.transport = .stop;
                view.fx_target = .none;
                ui.clearDirty(&view);
                ui.setStatusMsg(&view, "Closed");
            },
            .dirty_save => {
                view.menu_action = .none;
                if (project_path) |p| {
                    if (persist.saveAtomic(gpa, &project, p)) |_| {
                        ui.clearDirty(&view);
                        ui.resolveDirtyContinue(&view);
                        std.debug.print("saved {s}\n", .{p});
                    } else |err| {
                        ui.setStatusMsg(&view, "Save failed");
                        std.debug.print("save failed: {}\n", .{err});
                        view.show_dirty_confirm = false;
                        view.dirty_pending = .none;
                    }
                } else {
                    // Untitled: Save As, then continue pending action.
                    view.show_dirty_confirm = false;
                    ui.openPathModal(&view, .save_as, "project.fastmix.json");
                }
            },
            .dirty_discard => {
                view.menu_action = .none;
                ui.clearDirty(&view);
                ui.resolveDirtyContinue(&view);
            },
            .quit => {
                view.menu_action = .none;
                break;
            },
            .render_start => {
                view.menu_action = .none;
                const path = view.render_path_buf[0..view.render_path_len];
                if (path.len == 0) {
                    ui.setStatusMsg(&view, "Render: empty path");
                } else if (render_state.thread != null and !render_state.done.load(.monotonic)) {
                    ui.setStatusMsg(&view, "Render already in progress");
                } else {
                    if (render_state.thread) |th| {
                        th.join();
                        render_state.thread = null;
                    }
                    view.transport = .stop;
                    click_remaining = 0;
                    const path_owned = gpa.dupe(u8, path) catch {
                        ui.setStatusMsg(&view, "Render: OOM");
                        continue;
                    };
                    render_state.done.store(false, .monotonic);
                    render_state.ok.store(false, .monotonic);
                    render_state.path = path_owned;
                    render_state.thread = std.Thread.spawn(.{}, renderThreadFn, .{ gpa, &project, &asset_cache, path_owned, &render_state }) catch {
                        gpa.free(path_owned);
                        render_state.path = null;
                        ui.setStatusMsg(&view, "Render: thread spawn failed");
                        continue;
                    };
                    ui.setStatusMsg(&view, "Rendering master WAV…");
                    std.debug.print("render started → {s}\n", .{path});
                }
            },
            .analyze_master_program => {
                view.menu_action = .none;
                var resp: [65536]u8 = undefined;
                const out = handleCommand(&dispatch_ctx, "{\"id\":9001,\"cmd\":\"analyze_master_program\",\"args\":{}}", &resp);
                if (std.mem.indexOf(u8, out, "\"ok\":true") != null) {
                    if (std.mem.indexOf(u8, out, "\"job_id\"")) |_| {
                        const msg = "Analyze queued…";
                        @memcpy(view.master_qc_status[0..msg.len], msg);
                        view.master_qc_status_len = msg.len;
                        ui.setStatusMsg(&view, "Master analyze running");
                    } else {
                        applyMasterQcJsonToView(&view, out);
                        ui.setStatusMsg(&view, "Master analyze done");
                    }
                } else {
                    ui.setStatusMsg(&view, "Analyze failed");
                }
            },
            .validate_master_delivery => {
                view.menu_action = .none;
                var resp: [65536]u8 = undefined;
                const out = handleCommand(&dispatch_ctx, "{\"id\":9002,\"cmd\":\"validate_master_delivery\",\"args\":{\"profile\":{\"name\":\"custom\",\"target_integrated_lufs\":-14,\"tolerance_lu\":2,\"max_true_peak_dbtp\":-1}}}", &resp);
                if (std.mem.indexOf(u8, out, "\"ok\":true") != null) {
                    if (std.mem.indexOf(u8, out, "\"job_id\"")) |_| {
                        const msg = "Validate queued…";
                        @memcpy(view.master_qc_status[0..msg.len], msg);
                        view.master_qc_status_len = msg.len;
                        ui.setStatusMsg(&view, "Delivery QC running");
                    } else {
                        const st = if (std.mem.indexOf(u8, out, "\"status\":\"pass\"")) |_| "QC pass" else if (std.mem.indexOf(u8, out, "\"status\":\"warning\"")) |_| "QC warning" else "QC fail";
                        @memcpy(view.master_qc_status[0..st.len], st);
                        view.master_qc_status_len = st.len;
                        ui.setStatusMsg(&view, st);
                    }
                } else {
                    ui.setStatusMsg(&view, "Validate failed");
                }
            },
            .reset_master_peak => {
                view.menu_action = .none;
                view.master_peak_hold = 0;
                view.master_clip_flag = false;
                view.master_peak = 0;
            },
            .cycle_audio_block_size => {
                view.menu_action = .none;
                const next = audio_config.nextBlockSize(audio_block_size);
                applyAudioBlockSize(&stream, &audio_block_size, &view, &audio_diag, gpa, next);
            },
        }

        // Keyboard transport (SPEC_UI_REAPER / spike_ui_transport)
        if (!ui.blocksGlobalHotkeys(&view)) {
            if (c.IsKeyPressed(c.KEY_SPACE)) {
                view.transport = ui.stepTransport(view.transport, .space);
            }
            if (c.IsKeyPressed(c.KEY_R) and !c.IsKeyDown(c.KEY_LEFT_CONTROL) and !c.IsKeyDown(c.KEY_LEFT_SUPER)) {
                view.transport = ui.stepTransport(view.transport, .record_key);
            }
            if (c.IsKeyPressed(c.KEY_TAB) and project.tracks.items.len > 0) {
                var idx: usize = 0;
                for (project.tracks.items, 0..) |t, i| {
                    if (t.armed) {
                        idx = i;
                        break;
                    }
                }
                project.tracks.items[idx].armed = false;
                const next = (idx + 1) % project.tracks.items.len;
                project.tracks.items[next].armed = true;
                view.selected_track = project.tracks.items[next].id;
            }
        }

        const dt: f64 = c.GetFrameTime();
        _ = dt;
        var crossed_bar = false;
        const was_running = ui.isRunning(view.transport);
        // Transport clock advances with audio buffers below (sample-accurate).
        // GetFrameTime-driven beat_time caused stutter/overlap crackle with stems.

        // ALIGN: hard-pause, move items on the arrange, stay paused (no glitch mid-buffer).
        if (view.align_requested) {
            view.align_requested = false;
            view.transport = .stop;
            click_remaining = 0;
            beat_time = 0;
            last_replay_quant = null;
            _ = alignStemsToGrid(gpa, io, &project) catch |err| {
                std.debug.print("ALIGN failed: {}\n", .{err});
            };
            ui.markDirty(&view);
        }

        // Click on Play from pause if metro is on and we're on a beat boundary (incl. start).
        if (view.metronome and !was_running and ui.isRunning(view.transport)) {
            const on_beat = @mod(beat_time, beat_sec) < 0.001 or @mod(beat_time, beat_sec) > beat_sec - 0.001;
            if (on_beat or beat_time < 0.001) click_remaining = CLICK_SAMPLES;
        }

        // Entering record only via count-in bar boundary (checked after audio clock advances).

        var armed_track_id: ?model.TrackId = null;
        for (project.tracks.items) |t| {
            if (t.armed) {
                armed_track_id = t.id;
                break;
            }
        }

        for (0..KEYBOARD_COUNT) |i| {
            const down = c.IsKeyDown(KEYBOARD[i]);
            if (down and !notes_monitor_prev[i]) {
                if (armed_track_id) |tid| mixer.voiceOn(&voice_pool, tid, @intCast(i), 1.0, .monitor, frame_count);
            } else if (!down and notes_monitor_prev[i]) {
                if (armed_track_id) |tid| mixer.voiceOff(&voice_pool, tid, @intCast(i), .monitor, frame_count);
            }
            notes_monitor_prev[i] = down;
            notes_monitor[i] = down;
        }

        if (view.transport == .record) {
            if (armed_track_id) |tid| {
                const track = project.findTrack(tid).?;
                if (track.clips.items.len > 0 and track.clips.items[track.clips.items.len - 1] == .midi) {
                    const clip = &track.clips.items[track.clips.items.len - 1].midi;
                    const clip_start_sec = @as(f64, @floatFromInt(clip.start_bar)) * bar_sec;
                    const current_quant: i64 = @intFromFloat(@floor((beat_time - clip_start_sec) / quant_sec));
                    for (0..KEYBOARD_COUNT) |i| {
                        if (notes_monitor[i] and !notes_capture[i]) {
                            notes_capture[i] = true;
                            clip.events.append(gpa, .{ .quant = current_quant, .semitone = @intCast(i), .start = true }) catch {};
                        } else if (!notes_monitor[i] and notes_capture[i]) {
                            notes_capture[i] = false;
                            clip.events.append(gpa, .{ .quant = current_quant, .semitone = @intCast(i), .start = false }) catch {};
                        }
                    }
                    clip.bars = clipBars(clip.events.items, project.bar_quant);
                }
            }
        }

        const global_quant: i64 = @intFromFloat(@floor(beat_time / quant_sec));
        if (view.transport == .play or view.transport == .count_in) {
            if (last_replay_quant == null or last_replay_quant.? != global_quant) {
                for (project.tracks.items) |*track| {
                    for (track.clips.items) |*clip_u| {
                        if (clip_u.* != .midi) continue;
                        const clip = &clip_u.midi;
                        const clip_len_quants = clip.bars * project.bar_quant;
                        const rel_quant = global_quant - clip.start_bar * project.bar_quant;
                        if (rel_quant < 0 or rel_quant >= clip_len_quants) continue;
                        for (clip.events.items) |ev| {
                            if (ev.quant == rel_quant) {
                                if (ev.start) {
                                    mixer.voiceOn(&voice_pool, track.id, ev.semitone, ev.velocity, .replay, frame_count);
                                } else {
                                    mixer.voiceOff(&voice_pool, track.id, ev.semitone, .replay, frame_count);
                                }
                            }
                        }
                    }
                }
                last_replay_quant = global_quant;
            }
        }

        var block_peaks_l: [64]f32 = [_]f32{0} ** 64;
        var block_peaks_r: [64]f32 = [_]f32{0} ** 64;
        var master_peak: f32 = 0;
        var track_levels: [64]mixer.TrackLevel = [_]mixer.TrackLevel{.{}} ** 64;
        const track_levels_slice = track_levels[0..@min(track_levels.len, project.tracks.items.len)];
        var bus_levels: [32]mixer.BusLevel = [_]mixer.BusLevel{.{}} ** 32;
        const bus_levels_slice = bus_levels[0..@min(bus_levels.len, project.buses.items.len)];
        var block_bus_l: [32]f32 = [_]f32{0} ** 32;
        var block_bus_r: [32]f32 = [_]f32{0} ** 32;
        var block_bus_in: [32]f32 = [_]f32{0} ** 32;

        // Drain every exhausted buffer this frame (one Update/frame → underrun crackles).
        const project_frames: u64 = @intFromFloat(project_sec * @as(f64, @floatFromInt(SAMPLE_RATE)));
        const beat_frames: u64 = @max(1, @as(u64, @intFromFloat(beat_sec * @as(f64, @floatFromInt(SAMPLE_RATE)))));
        const bar_frames: u64 = @max(1, @as(u64, @intFromFloat(bar_sec * @as(f64, @floatFromInt(SAMPLE_RATE)))));
        // Output is mixSample master_output (post FX + master_volume). No hidden
        // headroom gain — level comes from master_volume / master FX only.
        // Hard-clamp only when |sample| > 1 for device buffer safety.
        const expected_gap_ms = 1000.0 * @as(f64, @floatFromInt(audio_block_size)) / @as(f64, @floatFromInt(SAMPLE_RATE));

        while (c.IsAudioStreamProcessed(stream)) {
            const now = c.GetTime();
            if (audio_diag.last_fill_time_s > 0) {
                const gap_ms = (now - audio_diag.last_fill_time_s) * 1000.0;
                audio_diag.noteFillGap(gap_ms, expected_gap_ms, SAMPLE_RATE);
            }
            audio_diag.last_fill_time_s = now;
            audio_diag.last_fill_timestamp = now;
            audio_diag.audio_fill_count += 1;
            audio_diag.audio_callback_count = audio_diag.audio_fill_count;

            const running = ui.isRunning(view.transport);
            const playhead0: u64 = @intFromFloat(beat_time * @as(f64, @floatFromInt(SAMPLE_RATE)));
            for (0..audio_block_size) |s| {
                var l: f32 = 0;
                var r: f32 = 0;
                const abs_ph = playhead0 + s;
                const audio_ph: ?u64 = if (running)
                    (if (project_frames > 0) abs_ph % project_frames else abs_ph)
                else
                    null;
                mixer.mixSample(&project, &voice_pool, &asset_cache, frame_count, audio_ph, .{}, &sc_rt, &eq_rt, &comp_rt, &delay_rt, &lim_rt, &width_rt, SAMPLE_RATE, &l, &r, track_levels_slice, bus_levels_slice, null, view.fx_bypass_all);

                if (running and view.metronome and abs_ph > 0) {
                    const prev_beat = (abs_ph - 1) / beat_frames;
                    const cur_beat = abs_ph / beat_frames;
                    if (cur_beat != prev_beat) click_remaining = CLICK_SAMPLES;
                }

                if (click_remaining > 0) {
                    const t: f32 = @as(f32, @floatFromInt(frame_count)) / @as(f32, @floatFromInt(SAMPLE_RATE));
                    const envelope = @as(f32, @floatFromInt(click_remaining)) / @as(f32, @floatFromInt(CLICK_SAMPLES));
                    const click = 0.2 * envelope * @sin(2.0 * std.math.pi * t * 1760.0);
                    l += click;
                    r += click;
                    click_remaining -= 1;
                }

                l = std.math.clamp(l, -1.0, 1.0);
                r = std.math.clamp(r, -1.0, 1.0);
                audio_buffer[s * 2 + 0] = l;
                audio_buffer[s * 2 + 1] = r;
                master_peak = @max(master_peak, @max(@abs(l), @abs(r)));

                for (0..track_levels_slice.len) |ti| {
                    const tlv = track_levels_slice[ti];
                    const al = @abs(tlv.l);
                    const ar = @abs(tlv.r);
                    if (al > block_peaks_l[ti]) block_peaks_l[ti] = al;
                    if (ar > block_peaks_r[ti]) block_peaks_r[ti] = ar;
                }
                for (0..bus_levels_slice.len) |bi| {
                    const blv = bus_levels_slice[bi];
                    const ol = @abs(blv.out_l);
                    const or_ = @abs(blv.out_r);
                    if (ol > block_bus_l[bi]) block_bus_l[bi] = ol;
                    if (or_ > block_bus_r[bi]) block_bus_r[bi] = or_;
                    const ip = @max(@abs(blv.in_l), @abs(blv.in_r));
                    if (ip > block_bus_in[bi]) block_bus_in[bi] = ip;
                }

                frame_count += 1;
            }
            c.UpdateAudioStream(stream, &audio_buffer, @intCast(audio_block_size));

            if (running) {
                const beat_time_prev = beat_time;
                const beat_time_raw = beat_time + @as(f64, @floatFromInt(audio_block_size)) / @as(f64, @floatFromInt(SAMPLE_RATE));
                if (fmodCycling(beat_time_raw, bar_sec) < fmodCycling(beat_time_prev, bar_sec)) {
                    crossed_bar = true;
                }
                beat_time = fmodCycling(beat_time_raw, project_sec);
            }
        }
        _ = bar_frames;

        // Count-in → record on bar boundary (after sample clock move)
        if (view.transport == .count_in and crossed_bar) {
            view.transport = ui.stepTransport(view.transport, .bar_crossed);
            if (view.transport == .record) {
                beginMidiRecord(gpa, &project, &voice_pool, &notes_monitor, &notes_capture, beat_time, bar_sec);
                last_replay_quant = null;
            }
        }

        ui.updatePeaks(&view, project.tracks.items.len, &block_peaks_l, &block_peaks_r, master_peak);
        for (project.master_effects.items) |eff| {
            if (eff.params == .limiter and !eff.bypassed) {
                if (lim_rt.gainReductionDb(eff.id)) |gr| {
                    view.master_qc_limiter_gr_db = @max(view.master_qc_limiter_gr_db * 0.9, gr);
                }
                break;
            }
        }
        var block_bus_out: [32]f32 = [_]f32{0} ** 32;
        for (0..@min(32, project.buses.items.len)) |bi| {
            block_bus_out[bi] = @max(block_bus_l[bi], block_bus_r[bi]);
        }
        ui.updateBusPeaks(&view, project.buses.items.len, &block_bus_out);
        live_peaks.master = master_peak;
        live_peaks.track_count = project.tracks.items.len;
        live_peaks.bus_count = project.buses.items.len;
        @memcpy(live_peaks.track_l[0..], block_peaks_l[0..]);
        @memcpy(live_peaks.track_r[0..], block_peaks_r[0..]);
        @memcpy(live_peaks.bus_l[0..], block_bus_l[0..]);
        @memcpy(live_peaks.bus_r[0..], block_bus_r[0..]);
        @memcpy(live_peaks.bus_in_peak[0..], block_bus_in[0..]);
        for (0..@min(32, project.buses.items.len)) |bi| {
            live_peaks.bus_out_peak[bi] = @max(block_bus_l[bi], block_bus_r[bi]);
        }

        // Envelopes keep decaying while paused; next Play continues smoothly.

        const bar_pos_ui = beat_time / bar_sec;
        ui.followPlayhead(&view, chrome, bar_pos_ui, project.length_bars);

        // Window title with dirty marker
        {
            var title_buf: [256]u8 = undefined;
            const base = project_path orelse "Untitled";
            const name = std.fs.path.basename(base);
            const title = if (view.project_dirty)
                (std.fmt.bufPrintZ(&title_buf, "FastMix AI — {s} *", .{name}) catch "FastMix AI *")
            else
                (std.fmt.bufPrintZ(&title_buf, "FastMix AI — {s}", .{name}) catch "FastMix AI");
            c.SetWindowTitle(title);
        }

        c.BeginDrawing();
        ui.draw(&project, &view, chrome, &asset_cache, beat_time, bar_sec);
        c.EndDrawing();
    }
}

fn renderThreadFn(gpa: std.mem.Allocator, project: *model.Project, asset_cache: *mixer.AssetCache, path: []u8, render_state: *RenderState) void {
    defer {
        gpa.free(path);
        render_state.path = null;
        render_state.done.store(true, .monotonic);
    }
    renderMasterToPath(gpa, project, asset_cache, path) catch {
        render_state.ok.store(false, .monotonic);
        return;
    };
    render_state.ok.store(true, .monotonic);
}

fn renderMasterToPath(gpa: std.mem.Allocator, project: *model.Project, asset_cache: *mixer.AssetCache, path: []const u8) !void {
    const beat_sec = 60.0 / project.bpm;
    const bar_sec = @as(f64, @floatFromInt(project.bar_size)) * beat_sec;
    const quant_sec = bar_sec / @as(f64, @floatFromInt(project.bar_quant));
    const sample_rate_f: f64 = @floatFromInt(project.sample_rate);

    var total_frames: u64 = @intFromFloat(@as(f64, @floatFromInt(project.length_bars)) * bar_sec * sample_rate_f);
    for (project.tracks.items) |track| {
        for (track.clips.items) |clip| {
            switch (clip) {
                .midi => |m| {
                    const end_frame: u64 = @intFromFloat(@as(f64, @floatFromInt(m.start_bar + m.bars)) * bar_sec * sample_rate_f);
                    if (end_frame > total_frames) total_frames = end_frame;
                },
                .audio => |a| {
                    const playable = project.audioPlayableFrames(a);
                    if (playable > 0) {
                        const end_frame: u64 = @intCast(a.timeline_start_frame + @as(i64, @intCast(playable)));
                        if (end_frame > total_frames) total_frames = end_frame;
                    }
                },
            }
        }
    }
    if (total_frames == 0) return error.NothingToRender;

    const buffer = try gpa.alloc(f32, total_frames * 2);
    defer gpa.free(buffer);

    var render_voices: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;
    var last_quant: ?i64 = null;
    var sc_rt = mixer.SidechainRuntime.init(gpa);
    defer sc_rt.deinit();
    var eq_rt = mixer.EqRuntime.init(gpa);
    defer eq_rt.deinit();
    var comp_rt = mixer.CompressorRuntime.init(gpa);
    defer comp_rt.deinit();
    var delay_rt = mixer.DelayRuntime.init(gpa);
    defer delay_rt.deinit();
    var lim_rt = mixer.LimiterRuntime.init(gpa);
    defer lim_rt.deinit();
    var width_rt = mixer.StereoWidthRuntime.init(gpa);
    defer width_rt.deinit();

    var frame: u64 = 0;
    while (frame < total_frames) : (frame += 1) {
        const t_sec = @as(f64, @floatFromInt(frame)) / sample_rate_f;
        const global_quant: i64 = @intFromFloat(@floor(t_sec / quant_sec));
        if (last_quant == null or last_quant.? != global_quant) {
            for (project.tracks.items) |track| {
                for (track.clips.items) |clip| {
                    if (clip != .midi) continue;
                    const m = clip.midi;
                    const clip_len_quants = m.bars * project.bar_quant;
                    const rel_quant = global_quant - m.start_bar * project.bar_quant;
                    if (rel_quant < 0 or rel_quant >= clip_len_quants) continue;
                    for (m.events.items) |ev| {
                        if (ev.quant == rel_quant) {
                            if (ev.start) {
                                mixer.voiceOn(&render_voices, track.id, ev.semitone, ev.velocity, .replay, frame);
                            } else {
                                mixer.voiceOff(&render_voices, track.id, ev.semitone, .replay, frame);
                            }
                        }
                    }
                }
            }
            last_quant = global_quant;
        }

        var l: f32 = 0;
        var r: f32 = 0;
        mixer.mixSample(project, &render_voices, asset_cache, frame, frame, .{}, &sc_rt, &eq_rt, &comp_rt, &delay_rt, &lim_rt, &width_rt, project.sample_rate, &l, &r, null, null, null, false);
        // Same as playback: master_output floats, hard-clip only if overs.
        buffer[frame * 2 + 0] = std.math.clamp(l, -1.0, 1.0);
        buffer[frame * 2 + 1] = std.math.clamp(r, -1.0, 1.0);
    }

    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const wave = c.Wave{
        .frameCount = @intCast(total_frames),
        .sampleRate = project.sample_rate,
        .sampleSize = 32,
        .channels = 2,
        .data = buffer.ptr,
    };
    if (!c.ExportWave(wave, path_z.ptr)) return error.ExportWaveFailed;
}
