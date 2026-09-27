const std = @import("std");
const model = @import("model.zig");
const stereo_analysis = @import("stereo_analysis.zig");

// Multi-track voice pool + stereo mixing. ADSR/Voice logic carried over from
// Phase 1 (src/main.zig, now tagged per-track); mute/solo/pan summing rule
// proven correct in spikes/spike_mixer.zig via Goertzel frequency analysis.
// Realtime inserts: sidechain compressor, peaking EQ, compressor, delay, sample-peak limiter, stereo width.

pub const ROOT_NOTE: f32 = 440.0; // A4

pub fn semitoneToFreq(semitone: f32) f32 {
    return ROOT_NOTE * std.math.pow(f32, 2.0, semitone / 12.0);
}

pub fn envelopeValue(adsr: model.Adsr, age_sec: f32, released_age_sec: ?f32) f32 {
    if (released_age_sec) |rel| {
        if (rel >= adsr.release_sec) return 0.0;
        return adsr.sustain_level * (1.0 - rel / adsr.release_sec);
    }
    if (age_sec < adsr.attack_sec) return age_sec / adsr.attack_sec;
    const decay_age = age_sec - adsr.attack_sec;
    if (decay_age < adsr.decay_sec) {
        const t = decay_age / adsr.decay_sec;
        return 1.0 + (adsr.sustain_level - 1.0) * t;
    }
    return adsr.sustain_level;
}

pub const VoiceSource = enum { monitor, replay };

pub const Voice = struct {
    active: bool = false,
    track_id: model.TrackId = 0,
    semitone: i32 = 0,
    velocity: f32 = 1.0,
    source: VoiceSource = .monitor,
    started_at: u64 = 0,
    released_at: ?u64 = null,
};

pub const MAX_VOICES: usize = 64;

pub fn voiceOn(voices: []Voice, track_id: model.TrackId, semitone: i32, velocity: f32, source: VoiceSource, frame_count: u64) void {
    for (voices) |*v| {
        if (!v.active) {
            v.* = .{ .active = true, .track_id = track_id, .semitone = semitone, .velocity = velocity, .source = source, .started_at = frame_count, .released_at = null };
            return;
        }
    }
    var oldest: usize = 0;
    for (voices, 0..) |v, idx| {
        if (v.started_at < voices[oldest].started_at) oldest = idx;
    }
    voices[oldest] = .{ .active = true, .track_id = track_id, .semitone = semitone, .velocity = velocity, .source = source, .started_at = frame_count, .released_at = null };
}

pub fn voiceOff(voices: []Voice, track_id: model.TrackId, semitone: i32, source: VoiceSource, frame_count: u64) void {
    for (voices) |*v| {
        if (v.active and v.track_id == track_id and v.semitone == semitone and v.source == source and v.released_at == null) {
            v.released_at = frame_count;
            return;
        }
    }
}

/// Note-off (with release tail) for every held voice of `source`, all tracks.
pub fn releaseSource(voices: []Voice, source: VoiceSource, frame_count: u64) void {
    for (voices) |*v| {
        if (v.active and v.source == source and v.released_at == null) v.released_at = frame_count;
    }
}

pub fn silenceSource(voices: []Voice, track_id: model.TrackId, source: VoiceSource) void {
    for (voices) |*v| {
        if (v.active and v.track_id == track_id and v.source == source) v.active = false;
    }
}

fn panGains(pan: f32) struct { l: f32, r: f32 } {
    const angle = (pan + 1.0) * (std.math.pi / 4.0);
    return .{ .l = @cos(angle), .r = @sin(angle) };
}

/// An imported audio stem, resampled to the project's sample rate and
/// decoded to f32 at import time (roadmap §12). Lives in an engine-side
/// cache, never inside `Project`/the DTO -- a single real stem is ~100MB
/// (see spikes/spike_stems.zig), which is why `AudioSource` in model.zig only
/// stores a path/metadata, not samples.
pub const LoadedAsset = struct {
    samples: []const f32, // interleaved if channels == 2
    channels: u8,
    frame_count: u64,
};
pub const AssetCache = std.AutoHashMap(model.AssetId, LoadedAsset);

/// Per-effect envelope follower state for realtime sidechain (not persisted).
/// `last_gr_db`/`last_detector_db` are measured telemetry (gain reduction
/// actually applied, and the detector signal level that drove it) -- the
/// values `sidechainGain` used to compute and throw away.
pub const SidechainRuntime = struct {
    env: std.AutoHashMap(model.EffectId, f32),
    last_gr_db: std.AutoHashMap(model.EffectId, f32),
    last_detector_db: std.AutoHashMap(model.EffectId, f32),

    pub fn init(gpa: std.mem.Allocator) SidechainRuntime {
        return .{
            .env = std.AutoHashMap(model.EffectId, f32).init(gpa),
            .last_gr_db = std.AutoHashMap(model.EffectId, f32).init(gpa),
            .last_detector_db = std.AutoHashMap(model.EffectId, f32).init(gpa),
        };
    }

    pub fn deinit(self: *SidechainRuntime) void {
        self.env.deinit();
        self.last_gr_db.deinit();
        self.last_detector_db.deinit();
    }

    pub fn reset(self: *SidechainRuntime) void {
        self.env.clearRetainingCapacity();
        self.last_gr_db.clearRetainingCapacity();
        self.last_detector_db.clearRetainingCapacity();
    }

    pub fn gainReductionDb(self: *const SidechainRuntime, effect_id: model.EffectId) ?f32 {
        return self.last_gr_db.get(effect_id);
    }

    pub fn detectorLevelDb(self: *const SidechainRuntime, effect_id: model.EffectId) ?f32 {
        return self.last_detector_db.get(effect_id);
    }
};

/// Default Q for new peak / HPF / shelf bands (RBJ cookbook).
pub const EQ_DEFAULT_Q: f32 = 0.707;

pub const BiquadCoeffs = struct { b0: f32, b1: f32, b2: f32, a1: f32, a2: f32 };

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

const StereoBiquad = struct { l: BiquadState = .{}, r: BiquadState = .{} };

/// Per-(effect, band) Direct Form I state for EQ. Fresh instance in
/// measureRange (like SidechainRuntime) so hermetic windows don't inherit
/// playback filter memory.
pub const EqRuntime = struct {
    /// key = (effect_id << 8) | band_index  (max 256 bands per effect)
    bands: std.AutoHashMap(u64, StereoBiquad),

    pub fn init(gpa: std.mem.Allocator) EqRuntime {
        return .{ .bands = std.AutoHashMap(u64, StereoBiquad).init(gpa) };
    }

    pub fn deinit(self: *EqRuntime) void {
        self.bands.deinit();
    }

    pub fn reset(self: *EqRuntime) void {
        self.bands.clearRetainingCapacity();
    }

    fn bandKey(effect_id: model.EffectId, band_index: usize) u64 {
        return (@as(u64, effect_id) << 8) | @as(u64, @intCast(band_index & 0xff));
    }

    fn stateFor(self: *EqRuntime, effect_id: model.EffectId, band_index: usize) ?*StereoBiquad {
        const gop = self.bands.getOrPut(bandKey(effect_id, band_index)) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }
};

fn sanitizeFreq(freq_hz: f32, sample_rate: f32) f32 {
    const sr = @max(sample_rate, 1.0);
    const nyquist = sr * 0.5;
    return std.math.clamp(freq_hz, 10.0, nyquist * 0.99);
}

fn sanitizeQ(q: f32) f32 {
    return std.math.clamp(q, 0.1, 18.0);
}

/// RBJ Audio EQ Cookbook coefficients (normalized a0=1). Shared by realtime
/// and offline paths. Gain is unused for `.highpass`.
///
/// Shelf `q`: interpreted as cookbook **Q** in
/// `alpha = sin(w0)/2 * sqrt((A+1/A)*(1/Q-1)+2)` (not the separate `S` form).
pub fn biquadCoeffs(
    band_type: model.EqBandType,
    frequency_hz: f32,
    gain_db: f32,
    q: f32,
    sample_rate: f32,
) BiquadCoeffs {
    const sr = @max(sample_rate, 1.0);
    const f = sanitizeFreq(frequency_hz, sr);
    const qq = sanitizeQ(q);
    const w0 = 2.0 * std.math.pi * f / sr;
    const cos_w0 = @cos(w0);
    const sin_w0 = @sin(w0);
    const alpha_q = sin_w0 / (2.0 * qq);

    const identity = BiquadCoeffs{ .b0 = 1, .b1 = 0, .b2 = 0, .a1 = 0, .a2 = 0 };

    var b0: f32 = 1;
    var b1: f32 = 0;
    var b2: f32 = 0;
    var a0: f32 = 1;
    var a1: f32 = 0;
    var a2: f32 = 0;

    switch (band_type) {
        .peak => {
            const A = std.math.pow(f32, 10.0, gain_db / 40.0);
            b0 = 1.0 + alpha_q * A;
            b1 = -2.0 * cos_w0;
            b2 = 1.0 - alpha_q * A;
            a0 = 1.0 + alpha_q / A;
            a1 = -2.0 * cos_w0;
            a2 = 1.0 - alpha_q / A;
        },
        .low_shelf => {
            const A = std.math.pow(f32, 10.0, gain_db / 40.0);
            const alpha = sin_w0 / 2.0 * @sqrt((A + 1.0 / A) * (1.0 / qq - 1.0) + 2.0);
            const two_sqrt_A_alpha = 2.0 * @sqrt(A) * alpha;
            b0 = A * ((A + 1.0) - (A - 1.0) * cos_w0 + two_sqrt_A_alpha);
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cos_w0);
            b2 = A * ((A + 1.0) - (A - 1.0) * cos_w0 - two_sqrt_A_alpha);
            a0 = (A + 1.0) + (A - 1.0) * cos_w0 + two_sqrt_A_alpha;
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cos_w0);
            a2 = (A + 1.0) + (A - 1.0) * cos_w0 - two_sqrt_A_alpha;
        },
        .high_shelf => {
            const A = std.math.pow(f32, 10.0, gain_db / 40.0);
            const alpha = sin_w0 / 2.0 * @sqrt((A + 1.0 / A) * (1.0 / qq - 1.0) + 2.0);
            const two_sqrt_A_alpha = 2.0 * @sqrt(A) * alpha;
            b0 = A * ((A + 1.0) + (A - 1.0) * cos_w0 + two_sqrt_A_alpha);
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cos_w0);
            b2 = A * ((A + 1.0) + (A - 1.0) * cos_w0 - two_sqrt_A_alpha);
            a0 = (A + 1.0) - (A - 1.0) * cos_w0 + two_sqrt_A_alpha;
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cos_w0);
            a2 = (A + 1.0) - (A - 1.0) * cos_w0 - two_sqrt_A_alpha;
        },
        .highpass => {
            b0 = (1.0 + cos_w0) / 2.0;
            b1 = -(1.0 + cos_w0);
            b2 = (1.0 + cos_w0) / 2.0;
            a0 = 1.0 + alpha_q;
            a1 = -2.0 * cos_w0;
            a2 = 1.0 - alpha_q;
        },
    }

    if (a0 == 0 or !std.math.isFinite(a0) or !std.math.isFinite(b0)) return identity;
    const inv_a0 = 1.0 / a0;
    const out = BiquadCoeffs{
        .b0 = b0 * inv_a0,
        .b1 = b1 * inv_a0,
        .b2 = b2 * inv_a0,
        .a1 = a1 * inv_a0,
        .a2 = a2 * inv_a0,
    };
    if (!std.math.isFinite(out.b0) or !std.math.isFinite(out.a1)) return identity;
    return out;
}

fn applyEqBands(
    eq_rt: *EqRuntime,
    effect_id: model.EffectId,
    bands: []const model.EqBand,
    sample_rate: f32,
    tl: *f32,
    tr: *f32,
) void {
    for (bands, 0..) |band, bi| {
        if (bi > 255) break;
        if (band.bypass) continue;
        const st = eq_rt.stateFor(effect_id, bi) orelse continue;
        const c = biquadCoeffs(band.band_type, band.frequency_hz, band.gain_db, band.q, sample_rate);
        tl.* = st.l.process(tl.*, c);
        tr.* = st.r.process(tr.*, c);
    }
}

/// Minimum GR (dB) to count a sample as "active" for compressor window stats.
pub const ACTIVE_GR_THRESHOLD_DB: f32 = 0.1;

/// Hard cap on simultaneous compressor insert states (track + bus + master).
/// Fixed slots — no HashMap / heap alloc on the audio path.
pub const MAX_COMPRESSOR_SLOTS: usize = 32;

const CompressorSlot = struct {
    id: model.EffectId = 0,
    active: bool = false,
    env: f32 = 0,
    last_gr_db: f32 = 0,
    last_input_peak: f32 = 0,
    last_output_peak: f32 = 0,
};

/// Per-effect envelope + last telemetry for compressors (fixed slots).
pub const CompressorRuntime = struct {
    slots: [MAX_COMPRESSOR_SLOTS]CompressorSlot = [_]CompressorSlot{.{}} ** MAX_COMPRESSOR_SLOTS,

    /// `gpa` kept for call-site compatibility; unused (no heap).
    pub fn init(_: std.mem.Allocator) CompressorRuntime {
        return .{};
    }

    pub fn deinit(_: *CompressorRuntime) void {}

    pub fn reset(self: *CompressorRuntime) void {
        self.slots = [_]CompressorSlot{.{}} ** MAX_COMPRESSOR_SLOTS;
    }

    fn slotFor(self: *CompressorRuntime, effect_id: model.EffectId) ?*CompressorSlot {
        var free_i: ?usize = null;
        for (&self.slots, 0..) |*s, i| {
            if (s.active and s.id == effect_id) return s;
            if (!s.active and free_i == null) free_i = i;
        }
        if (free_i) |i| {
            self.slots[i] = .{ .id = effect_id, .active = true };
            return &self.slots[i];
        }
        return null;
    }

    fn findSlot(self: *const CompressorRuntime, effect_id: model.EffectId) ?*const CompressorSlot {
        for (&self.slots) |*s| {
            if (s.active and s.id == effect_id) return s;
        }
        return null;
    }

    pub fn gainReductionDb(self: *const CompressorRuntime, effect_id: model.EffectId) ?f32 {
        const s = self.findSlot(effect_id) orelse return null;
        return s.last_gr_db;
    }

    pub fn inputPeak(self: *const CompressorRuntime, effect_id: model.EffectId) ?f32 {
        const s = self.findSlot(effect_id) orelse return null;
        return s.last_input_peak;
    }

    pub fn outputPeak(self: *const CompressorRuntime, effect_id: model.EffectId) ?f32 {
        const s = self.findSlot(effect_id) orelse return null;
        return s.last_output_peak;
    }
};

/// Soft-knee feed-forward peak compressor. Returns linear gain (<=1) before makeup/mix.
fn compressorReductionLinear(
    env: *f32,
    detector: f32,
    params: model.CompressorParams,
    sample_rate: f32,
) struct { gain: f32, gr_db: f32 } {
    const atk = msToCoeff(params.attack_ms, sample_rate);
    const rel = msToCoeff(params.release_ms, sample_rate);
    const x = @abs(detector);
    const coeff = if (x > env.*) atk else rel;
    env.* = coeff * env.* + (1.0 - coeff) * x;

    const env_db = linearToDb(env.*);
    const thr = params.threshold_db;
    const ratio = @max(params.ratio, 1.0);
    const knee = @max(params.knee_db, 0.0);
    var over_db: f32 = 0;
    if (knee <= 0.0) {
        over_db = @max(env_db - thr, 0.0);
    } else {
        const half = knee * 0.5;
        const delta = env_db - thr;
        if (delta < -half) {
            over_db = 0;
        } else if (delta > half) {
            over_db = delta;
        } else {
            // Soft knee: (delta + half)^2 / (2*knee)
            const t = delta + half;
            over_db = (t * t) / (2.0 * knee);
        }
    }
    const red_db = over_db * (1.0 - 1.0 / ratio);
    const gain = std.math.pow(f32, 10.0, -red_db / 20.0);
    return .{ .gain = gain, .gr_db = red_db };
}

fn applyTrackCompressor(
    comp_rt: *CompressorRuntime,
    effect_id: model.EffectId,
    params: model.CompressorParams,
    sample_rate: f32,
    tl: *f32,
    tr: *f32,
) void {
    const slot = comp_rt.slotFor(effect_id) orelse return;
    const in_peak = @max(@abs(tl.*), @abs(tr.*));
    const red = compressorReductionLinear(&slot.env, in_peak, params, sample_rate);
    const makeup = std.math.pow(f32, 10.0, params.makeup_db / 20.0);
    const mix = std.math.clamp(params.mix, 0.0, 1.0);
    const dry_l = tl.*;
    const dry_r = tr.*;
    const wet_l = dry_l * red.gain * makeup;
    const wet_r = dry_r * red.gain * makeup;
    tl.* = dry_l * (1.0 - mix) + wet_l * mix;
    tr.* = dry_r * (1.0 - mix) + wet_r * mix;
    const out_peak = @max(@abs(tl.*), @abs(tr.*));
    slot.last_gr_db = red.gr_db;
    slot.last_input_peak = in_peak;
    slot.last_output_peak = out_peak;
}

/// 20*log10(|x|), floored so silence doesn't produce -inf.
pub fn linearToDb(x: f32) f32 {
    return 20.0 * std.math.log10(@max(@abs(x), 1.0e-7));
}

fn sampleMonoPeak(loaded: LoadedAsset, rel: u64) f32 {
    if (rel >= loaded.frame_count) return 0;
    if (loaded.channels >= 2) {
        const a = loaded.samples[rel * 2 + 0];
        const b = loaded.samples[rel * 2 + 1];
        return @max(@abs(a), @abs(b));
    }
    return @abs(loaded.samples[rel]);
}

fn readClipStereo(loaded: LoadedAsset, rel: u64) struct { l: f32, r: f32 } {
    if (rel >= loaded.frame_count) return .{ .l = 0, .r = 0 };
    if (loaded.channels >= 2) {
        return .{ .l = loaded.samples[rel * 2 + 0], .r = loaded.samples[rel * 2 + 1] };
    }
    const s = loaded.samples[rel];
    return .{ .l = s, .r = s };
}

fn audioRelFrame(ac: model.AudioClip, playhead: u64, playable: u64) ?u64 {
    if (playable == 0) return null;
    const ph: i64 = @intCast(playhead);
    if (ph < ac.timeline_start_frame) return null;
    const timeline_rel: u64 = @intCast(ph - ac.timeline_start_frame);
    if (timeline_rel >= playable) return null;
    return timeline_rel + ac.source_offset_frames;
}

fn firstAudioClip(track: *const model.Track) ?model.AudioClip {
    for (track.clips.items) |clip| {
        if (clip == .audio) return clip.audio;
    }
    return null;
}

fn dryAssetForTrack(track: *const model.Track) ?model.AssetId {
    for (track.effects.items) |eff| {
        if (eff.params == .sidechain_compressor) {
            if (eff.params.sidechain_compressor.dry_asset_id) |d| return d;
        }
    }
    if (firstAudioClip(track)) |ac| return ac.source_id;
    return null;
}

fn findTrackConst(project: *const model.Project, id: model.TrackId) ?*const model.Track {
    for (project.tracks.items) |*t| {
        if (t.id == id) return t;
    }
    return null;
}

fn detectorPeakAt(
    project: *const model.Project,
    cache: *const AssetCache,
    source_track_id: model.TrackId,
    playhead: u64,
) f32 {
    const src = findTrackConst(project, source_track_id) orelse return 0;
    const asset_id = dryAssetForTrack(src) orelse return 0;
    const loaded = cache.get(asset_id) orelse return 0;
    const ac = firstAudioClip(src) orelse return 0;
    const playable = project.audioPlayableFrames(ac);
    const rel = audioRelFrame(ac, playhead, playable) orelse return 0;
    return sampleMonoPeak(loaded, rel);
}

fn msToCoeff(ms: f32, sample_rate: f32) f32 {
    const sec = @max(ms, 0.1) / 1000.0;
    return @exp(-1.0 / (sec * sample_rate));
}

/// Peak follower + hard-knee downward compressor gain (linear).
fn sidechainGain(
    env: *f32,
    detector: f32,
    params: model.SidechainParams,
    sample_rate: f32,
) f32 {
    const atk = msToCoeff(params.attack_ms, sample_rate);
    const rel = msToCoeff(params.release_ms, sample_rate);
    const x = @abs(detector);
    const coeff = if (x > env.*) atk else rel;
    env.* = coeff * env.* + (1.0 - coeff) * x;

    const thr_lin = std.math.pow(f32, 10.0, params.threshold_db / 20.0);
    if (env.* <= thr_lin or thr_lin <= 0) return 1.0;
    const ratio = @max(params.ratio, 1.0);
    const over_db = 20.0 * std.math.log10(env.* / thr_lin);
    const red_db = over_db * (1.0 - 1.0 / ratio);
    return std.math.pow(f32, 10.0, -red_db / 20.0);
}

pub const TrackLevel = struct { l: f32 = 0, r: f32 = 0 };

pub const BusLevel = struct {
    /// Sum of sends before bus FX.
    in_l: f32 = 0,
    in_r: f32 = 0,
    /// After bus FX, before bus fader/pan (post-FX bus strip).
    post_fx_l: f32 = 0,
    post_fx_r: f32 = 0,
    /// Contribution actually added to master (after mute/solo/fader/pan).
    out_l: f32 = 0,
    out_r: f32 = 0,
};

pub const MAX_LIMITER_LOOKAHEAD: usize = 512; // ~10.6ms @ 48k
pub const MAX_DELAY_SAMPLES: usize = 44100 * 2; // 2s @ 44.1k

pub const LimiterVoiceState = struct {
    gain: f32 = 1.0,
    buf_l: [MAX_LIMITER_LOOKAHEAD]f32 = [_]f32{0} ** MAX_LIMITER_LOOKAHEAD,
    buf_r: [MAX_LIMITER_LOOKAHEAD]f32 = [_]f32{0} ** MAX_LIMITER_LOOKAHEAD,
    write_i: usize = 0,
};

/// Realtime Mid/Side stereo width insert.
pub const StereoWidthRuntime = struct {
    const State = struct {
        lpf_m: stereo_analysis.WidthOnePole = .{},
        lpf_s: stereo_analysis.WidthOnePole = .{},
        last_crossover_hz: f32 = 0,
    };
    states: std.AutoHashMap(model.EffectId, State),

    pub fn init(gpa: std.mem.Allocator) StereoWidthRuntime {
        return .{ .states = std.AutoHashMap(model.EffectId, State).init(gpa) };
    }
    pub fn deinit(self: *StereoWidthRuntime) void {
        self.states.deinit();
    }
    pub fn reset(self: *StereoWidthRuntime) void {
        self.states.clearRetainingCapacity();
    }
};

fn applyStereoWidth(
    width_rt: *StereoWidthRuntime,
    effect_id: model.EffectId,
    params: model.StereoWidthParams,
    sample_rate: f32,
    tl: *f32,
    tr: *f32,
) void {
    const gop = width_rt.states.getOrPut(effect_id) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const st = gop.value_ptr;
    const use_xo = params.mode == .crossover;
    if (use_xo and (st.last_crossover_hz != params.crossover_hz or st.lpf_m.a == 0)) {
        st.lpf_m = stereo_analysis.WidthOnePole.initLpf(params.crossover_hz, sample_rate);
        st.lpf_s = stereo_analysis.WidthOnePole.initLpf(params.crossover_hz, sample_rate);
        st.last_crossover_hz = params.crossover_hz;
    }
    const low_w = if (use_xo) params.low_width else params.width;
    const high_w = if (use_xo) params.high_width else params.width;
    const out = stereo_analysis.applyWidthSample(tl.*, tr.*, low_w, high_w, &st.lpf_m, &st.lpf_s, use_xo);
    tl.* = out.l;
    tr.* = out.r;
}

/// Sample-peak stereo-linked feed-forward brickwall limiter (not true-peak / not oversampled).
pub const LimiterRuntime = struct {
    states: std.AutoHashMap(model.EffectId, LimiterVoiceState),
    last_gr_db: std.AutoHashMap(model.EffectId, f32),

    pub fn init(gpa: std.mem.Allocator) LimiterRuntime {
        return .{
            .states = std.AutoHashMap(model.EffectId, LimiterVoiceState).init(gpa),
            .last_gr_db = std.AutoHashMap(model.EffectId, f32).init(gpa),
        };
    }

    pub fn deinit(self: *LimiterRuntime) void {
        self.states.deinit();
        self.last_gr_db.deinit();
    }

    pub fn reset(self: *LimiterRuntime) void {
        self.states.clearRetainingCapacity();
        self.last_gr_db.clearRetainingCapacity();
    }

    pub fn gainReductionDb(self: *const LimiterRuntime, effect_id: model.EffectId) ?f32 {
        return self.last_gr_db.get(effect_id);
    }
};

fn applyLimiter(
    lim_rt: *LimiterRuntime,
    effect_id: model.EffectId,
    params: model.LimiterParams,
    sample_rate: f32,
    tl: *f32,
    tr: *f32,
) void {
    const gop = lim_rt.states.getOrPut(effect_id) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const st = gop.value_ptr;

    const delay_n: usize = blk: {
        const n = @as(usize, @intFromFloat(@max(params.lookahead_ms, 0.0) * 0.001 * sample_rate));
        break :blk @min(@max(n, 0), MAX_LIMITER_LOOKAHEAD - 1);
    };

    // Write current into ring; read delayed for output.
    st.buf_l[st.write_i] = tl.*;
    st.buf_r[st.write_i] = tr.*;
    const read_i = (st.write_i + MAX_LIMITER_LOOKAHEAD - delay_n) % MAX_LIMITER_LOOKAHEAD;
    const out_l = st.buf_l[read_i];
    const out_r = st.buf_r[read_i];
    st.write_i = (st.write_i + 1) % MAX_LIMITER_LOOKAHEAD;

    const det = if (params.link_channels)
        @max(@abs(tl.*), @abs(tr.*))
    else
        @max(@abs(out_l), @abs(out_r));

    const ceiling_lin = std.math.pow(f32, 10.0, @min(params.ceiling_dbfs, 0.0) / 20.0);
    const thr_lin = std.math.pow(f32, 10.0, params.threshold_db / 20.0);
    var target: f32 = 1.0;
    if (det > thr_lin and det > 1.0e-12) {
        target = @min(1.0, ceiling_lin / det);
    }
    // Instant attack, release smooth.
    const rel = msToCoeff(params.release_ms, sample_rate);
    if (target < st.gain) {
        st.gain = target;
    } else {
        st.gain = rel * st.gain + (1.0 - rel) * target;
    }
    const g = st.gain;
    tl.* = out_l * g;
    tr.* = out_r * g;
    // Soft ceil enforce (sample-peak).
    const c = ceiling_lin;
    var ceil_gr: f32 = 1.0;
    if (@abs(tl.*) > c and c > 1.0e-12) {
        ceil_gr = @min(ceil_gr, c / @abs(tl.*));
        tl.* = std.math.copysign(c, tl.*);
    }
    if (@abs(tr.*) > c and c > 1.0e-12) {
        ceil_gr = @min(ceil_gr, c / @abs(tr.*));
        tr.* = std.math.copysign(c, tr.*);
    }

    const effective_g = g * ceil_gr;
    const gr_db = if (effective_g < 1.0) -linearToDb(effective_g) else 0.0;
    lim_rt.last_gr_db.put(effect_id, gr_db) catch {};
}

pub const DelayLine = struct {
    buf_l: [MAX_DELAY_SAMPLES]f32 = [_]f32{0} ** MAX_DELAY_SAMPLES,
    buf_r: [MAX_DELAY_SAMPLES]f32 = [_]f32{0} ** MAX_DELAY_SAMPLES,
    write_i: usize = 0,
    filter_l: f32 = 0,
    filter_r: f32 = 0,
};

pub const DelayRuntime = struct {
    gpa: std.mem.Allocator,
    lines: std.AutoHashMap(model.EffectId, DelayLine),

    pub fn init(gpa: std.mem.Allocator) DelayRuntime {
        return .{ .gpa = gpa, .lines = .init(gpa) };
    }

    pub fn deinit(self: *DelayRuntime) void {
        self.lines.deinit();
    }

    pub fn reset(self: *DelayRuntime) void {
        self.lines.clearRetainingCapacity();
    }
};

fn applyDelay(
    delay_rt: *DelayRuntime,
    effect_id: model.EffectId,
    params: model.DelayParams,
    sample_rate: f32,
    tl: *f32,
    tr: *f32,
) void {
    const gop = delay_rt.lines.getOrPut(effect_id) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    var line = gop.value_ptr;

    const delay_samples: usize = @intFromFloat(@max(params.time_ms, 1.0) / 1000.0 * sample_rate);
    const dlen = @min(@max(delay_samples, 1), MAX_DELAY_SAMPLES - 1);
    const read_i = (line.write_i + MAX_DELAY_SAMPLES - dlen) % MAX_DELAY_SAMPLES;
    const wet_l = line.buf_l[read_i];
    const wet_r = line.buf_r[read_i];

    const fb = std.math.clamp(params.feedback, 0.0, 0.95);
    const damp = std.math.clamp(params.damping, 0.0, 1.0);
    // damping: higher = less filtering (brighter feedback)
    const a = 1.0 - damp * 0.85;
    line.filter_l += a * (wet_l - line.filter_l);
    line.filter_r += a * (wet_r - line.filter_r);

    line.buf_l[line.write_i] = tl.* + line.filter_l * fb;
    line.buf_r[line.write_i] = tr.* + line.filter_r * fb;
    line.write_i = (line.write_i + 1) % MAX_DELAY_SAMPLES;

    const mix = std.math.clamp(params.mix, 0.0, 1.0);
    const dry_l = tl.*;
    const dry_r = tr.*;
    tl.* = dry_l * (1.0 - mix) + wet_l * mix;
    tr.* = dry_r * (1.0 - mix) + wet_r * mix;
}

fn applyInsertChain(
    project: *const model.Project,
    effects: []const model.Effect,
    fx_enabled: bool,
    asset_cache: ?*const AssetCache,
    audio_playhead: ?u64,
    sc_rt: ?*SidechainRuntime,
    eq_rt: ?*EqRuntime,
    comp_rt: ?*CompressorRuntime,
    delay_rt: ?*DelayRuntime,
    lim_rt: ?*LimiterRuntime,
    width_rt: ?*StereoWidthRuntime,
    sample_rate: f32,
    tl: *f32,
    tr: *f32,
) void {
    if (!fx_enabled) return;
    for (effects) |eff| {
        if (eff.bypassed) continue;
        switch (eff.params) {
            .eq => |eq| {
                if (eq_rt) |rt| {
                    if (eq.bands.items.len > 0) applyEqBands(rt, eff.id, eq.bands.items, sample_rate, tl, tr);
                }
            },
            .sidechain_compressor => |p| {
                if (sc_rt) |rt| {
                    if (audio_playhead) |playhead| {
                        if (asset_cache) |cache| {
                            const det = detectorPeakAt(project, cache, p.source_track_id, playhead);
                            const gop = rt.env.getOrPut(eff.id) catch continue;
                            if (!gop.found_existing) gop.value_ptr.* = 0;
                            const gr = sidechainGain(gop.value_ptr, det, p, sample_rate);
                            tl.* *= gr;
                            tr.* *= gr;
                            rt.last_gr_db.put(eff.id, -linearToDb(gr)) catch {};
                            rt.last_detector_db.put(eff.id, linearToDb(det)) catch {};
                        }
                    }
                }
            },
            .compressor => |p| {
                if (comp_rt) |rt| {
                    applyTrackCompressor(rt, eff.id, p, sample_rate, tl, tr);
                }
            },
            .delay => |p| {
                if (delay_rt) |rt| {
                    applyDelay(rt, eff.id, p, sample_rate, tl, tr);
                }
            },
            .limiter => |p| {
                if (lim_rt) |rt| {
                    applyLimiter(rt, eff.id, p, sample_rate, tl, tr);
                }
            },
            .stereo_width => |p| {
                if (width_rt) |rt| {
                    applyStereoWidth(rt, eff.id, p, sample_rate, tl, tr);
                }
            },
        }
    }
}

/// Master insert taps: pre FX → post FX → post volume (output).
pub const MasterLevel = struct {
    pre_l: f32 = 0,
    pre_r: f32 = 0,
    post_l: f32 = 0,
    post_r: f32 = 0,
    out_l: f32 = 0,
    out_r: f32 = 0,
};

/// Renders one interleaved stereo sample pair.
/// `voice_frame` advances always (ADSR / live monitor ages).
/// `audio_playhead` is transport timeline in project frames — `null` skips
/// audio-clip playback (paused/stopped) without killing monitor voices.
/// Routing: track FX → sends → bus FX → master sum → master FX → master volume.
/// `fx_bypass_all` (session DRY): skip all track/bus/master inserts; faders/routing unchanged.
pub fn mixSample(
    project: *const model.Project,
    voices: []Voice,
    asset_cache: ?*const AssetCache,
    voice_frame: u64,
    audio_playhead: ?u64,
    adsr: model.Adsr,
    sc_rt: ?*SidechainRuntime,
    eq_rt: ?*EqRuntime,
    comp_rt: ?*CompressorRuntime,
    delay_rt: ?*DelayRuntime,
    lim_rt: ?*LimiterRuntime,
    width_rt: ?*StereoWidthRuntime,
    sample_rate: u32,
    out_l: *f32,
    out_r: *f32,
    track_levels: ?[]TrackLevel,
    bus_levels: ?[]BusLevel,
    master_level: ?*MasterLevel,
    fx_bypass_all: bool,
) void {
    const any_track_solo = for (project.tracks.items) |t| {
        if (t.solo) break true;
    } else false;
    const any_bus_solo = for (project.buses.items) |b| {
        if (b.solo) break true;
    } else false;

    var l: f32 = 0;
    var r: f32 = 0;
    var post_master_l: f32 = 0;
    var post_master_r: f32 = 0;
    const sr_f: f32 = @floatFromInt(if (sample_rate == 0) 44100 else sample_rate);
    const t: f32 = @as(f32, @floatFromInt(voice_frame)) / sr_f;

    // Per-bus input accumulators (indexed like project.buses.items).
    var bus_in_l: [32]f32 = [_]f32{0} ** 32;
    var bus_in_r: [32]f32 = [_]f32{0} ** 32;
    const n_buses = @min(project.buses.items.len, 32);

    if (bus_levels) |bls| {
        for (bls) |*bl| bl.* = .{};
    }

    for (project.tracks.items, 0..) |track, ti| {
        if (track_levels) |tls| {
            if (ti < tls.len) tls[ti] = .{};
        }
        const track_audible = !track.mute and (!any_track_solo or track.solo);
        if (!track_audible) continue;

        // --- Pre-fader dry source (unity volume) ---
        var src_l: f32 = 0;
        var src_r: f32 = 0;
        var track_sample: f32 = 0;
        var active_count: u32 = 0;
        for (voices) |*v| {
            if (!v.active or v.track_id != track.id) continue;
            const age_sec: f32 = @as(f32, @floatFromInt(voice_frame -| v.started_at)) / sr_f;
            var released_age: ?f32 = null;
            if (v.released_at) |rel| {
                released_age = @as(f32, @floatFromInt(voice_frame -| rel)) / sr_f;
            }
            const env = envelopeValue(adsr, age_sec, released_age);
            if (released_age != null and env <= 0.0) {
                v.active = false;
                continue;
            }
            const freq = semitoneToFreq(@floatFromInt(v.semitone));
            track_sample += v.velocity * env * @sin(2.0 * std.math.pi * t * freq);
            active_count += 1;
        }
        if (active_count > 0) track_sample *= 1.0 / @as(f32, @floatFromInt(active_count));
        const gains = panGains(track.pan);
        src_l = track_sample * gains.l;
        src_r = track_sample * gains.r;

        if (audio_playhead) |playhead| {
            if (asset_cache) |cache| {
                const prefer_dry = dryAssetForTrack(&track);
                for (track.clips.items) |clip| {
                    if (clip != .audio) continue;
                    const ac = clip.audio;
                    if (ac.muted) continue;
                    const sid = prefer_dry orelse ac.source_id;
                    const loaded = cache.get(sid) orelse continue;
                    const playable = project.audioPlayableFrames(ac);
                    const rel = audioRelFrame(ac, playhead, playable) orelse continue;
                    const pair = readClipStereo(loaded, rel);
                    const bal_l: f32 = if (track.pan > 0) 1.0 - track.pan else 1.0;
                    const bal_r: f32 = if (track.pan < 0) 1.0 + track.pan else 1.0;
                    src_l += pair.l * bal_l;
                    src_r += pair.r * bal_r;
                }
            }
        }

        // Track FX on pre-fader signal.
        var fx_l = src_l;
        var fx_r = src_r;
        applyInsertChain(project, track.effects.items, track.fx_enabled and !fx_bypass_all, asset_cache, audio_playhead, sc_rt, eq_rt, comp_rt, delay_rt, lim_rt, width_rt, sr_f, &fx_l, &fx_r);

        const post_l = fx_l * track.volume;
        const post_r = fx_r * track.volume;

        // Track meter = post-FX post-fader contribution that *would* go to master
        // (even if master_send is off / bus solo silences direct).
        if (track_levels) |tls| {
            if (ti < tls.len) tls[ti] = .{ .l = post_l, .r = post_r };
        }

        // Direct master (silenced when any bus is soloed). Not for post_master monitors.
        if (track.master_send_enabled and !track.post_master_enabled and !any_bus_solo) {
            l += post_l;
            r += post_r;
        }
        if (track.post_master_enabled) {
            post_master_l += post_l;
            post_master_r += post_r;
        }

        // Sends
        for (project.sends.items) |send| {
            if (!send.enabled) continue;
            if (send.source_track_id != track.id) continue;
            const bi = for (project.buses.items[0..n_buses], 0..) |b, i| {
                if (b.id == send.destination_bus_id) break i;
            } else continue;
            const send_lin = std.math.pow(f32, 10.0, send.gain_db / 20.0);
            const sl: f32 = switch (send.tap) {
                .pre_fader => fx_l * send_lin,
                .post_fader => post_l * send_lin,
            };
            const sr: f32 = switch (send.tap) {
                .pre_fader => fx_r * send_lin,
                .post_fader => post_r * send_lin,
            };
            bus_in_l[bi] += sl;
            bus_in_r[bi] += sr;
        }
    }

    // Phase 2: bus FX once per bus, then to master.
    for (project.buses.items[0..n_buses], 0..) |bus, bi| {
        var bl = bus_in_l[bi];
        var br = bus_in_r[bi];
        if (bus_levels) |bls| {
            if (bi < bls.len) {
                bls[bi].in_l = bl;
                bls[bi].in_r = br;
            }
        }

        applyInsertChain(project, bus.effects.items, bus.fx_enabled and !fx_bypass_all, asset_cache, audio_playhead, sc_rt, eq_rt, comp_rt, delay_rt, lim_rt, width_rt, sr_f, &bl, &br);

        if (bus_levels) |bls| {
            if (bi < bls.len) {
                bls[bi].post_fx_l = bl;
                bls[bi].post_fx_r = br;
            }
        }

        const bus_audible = !bus.mute and (!any_bus_solo or bus.solo);
        if (!bus_audible) continue;

        const bg = panGains(bus.pan);
        const ol = bl * bus.volume * bg.l;
        const or_ = br * bus.volume * bg.r;
        if (bus_levels) |bls| {
            if (bi < bls.len) {
                bls[bi].out_l = ol;
                bls[bi].out_r = or_;
            }
        }
        l += ol;
        r += or_;
    }

    // Master FX once on sum, then master volume.
    if (master_level) |ml| {
        ml.pre_l = l;
        ml.pre_r = r;
    }
    applyInsertChain(project, project.master_effects.items, project.master_fx_enabled and !fx_bypass_all, asset_cache, audio_playhead, sc_rt, eq_rt, comp_rt, delay_rt, lim_rt, width_rt, sr_f, &l, &r);
    if (master_level) |ml| {
        ml.post_l = l;
        ml.post_r = r;
    }
    l *= project.master_volume;
    r *= project.master_volume;

    // REF / monitor path: after master FX + master volume (no glue/limiter on REF).
    l += post_master_l;
    r += post_master_r;

    if (master_level) |ml| {
        ml.out_l = l;
        ml.out_r = r;
    }

    out_l.* = l;
    out_r.* = r;
}
