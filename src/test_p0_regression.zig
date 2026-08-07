const std = @import("std");
const app = @import("main.zig");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const persist = @import("persist.zig");
const jobs = @import("jobs.zig");
const ui = @import("ui.zig");

// Regression spike for the P0 audio-feedback-loop work (real per-track meters,
// gain_reduction_peak_db/detector_peak_db, deterministic measure, audition,
// operation/revision envelope). Uses a fully synthetic in-memory project
// (no real WAV files, no ffmpeg, no socket) so it's fast and hermetic --
// exercises the ACTUAL production functions (mixer.mixSample, app.measureRange,
// app.handleCommand), not reimplementations, so it can't silently drift from
// what the running app does.

const SAMPLE_RATE: u32 = 44100;

fn dbfsFromSamples(buf: []const f32) struct { peak: f32, rms: f32 } {
    var peak: f32 = 0;
    var sum_sq: f64 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) {
        const l = buf[i];
        const r = buf[i + 1];
        peak = @max(peak, @max(@abs(l), @abs(r)));
        sum_sq += (@as(f64, l) * @as(f64, l) + @as(f64, r) * @as(f64, r)) * 0.5;
        n += 1;
    }
    const peak_db = 20.0 * std.math.log10(@max(peak, 1.0e-7));
    const rms_db: f32 = if (n > 0) @floatCast(10.0 * std.math.log10(@max(sum_sq / @as(f64, @floatFromInt(n)), 1.0e-12))) else -120;
    return .{ .peak = peak_db, .rms = rms_db };
}

/// Drums: silence with periodic decaying kick-like bursts every 5000 frames.
/// Bass: a sustained 55Hz tone, so it has a stable baseline to compress.
/// Bass carries a sidechain_compressor keyed off Drums (mirrors the real
/// bootstrapped 999-stems project's Bass<-Drums sidechain).
const Fixture = struct {
    gpa: std.mem.Allocator,
    project: model.Project = .{},
    asset_cache: mixer.AssetCache,
    drums_samples: []f32,
    bass_samples: []f32,
    drums_id: model.TrackId = 0,
    bass_id: model.TrackId = 0,
    sidechain_effect_id: model.EffectId = 0,

    const DRUMS_ASSET: model.AssetId = 9001;
    const BASS_ASSET: model.AssetId = 9002;
    const N: usize = 50000;

    fn init(gpa: std.mem.Allocator) !Fixture {
        var self: Fixture = .{
            .gpa = gpa,
            .asset_cache = mixer.AssetCache.init(gpa),
            .drums_samples = try gpa.alloc(f32, N),
            .bass_samples = try gpa.alloc(f32, N),
        };
        @memset(self.drums_samples, 0);
        var burst_start: usize = 2000;
        while (burst_start + 200 < N) : (burst_start += 5000) {
            for (0..200) |i| {
                const decay = 1.0 - @as(f32, @floatFromInt(i)) / 200.0;
                self.drums_samples[burst_start + i] = 0.9 * decay * @sin(@as(f32, @floatFromInt(i)) * 0.9);
            }
        }
        for (0..N) |i| {
            self.bass_samples[i] = 0.4 * @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) * 55.0 / @as(f32, @floatFromInt(SAMPLE_RATE)));
        }

        try self.project.assets.append(gpa, .{ .id = DRUMS_ASSET, .relative_path = try gpa.dupe(u8, "synthetic-drums"), .sample_rate = SAMPLE_RATE, .channels = 1, .frame_count = N });
        try self.project.assets.append(gpa, .{ .id = BASS_ASSET, .relative_path = try gpa.dupe(u8, "synthetic-bass"), .sample_rate = SAMPLE_RATE, .channels = 1, .frame_count = N });
        try self.asset_cache.put(DRUMS_ASSET, .{ .samples = self.drums_samples, .channels = 1, .frame_count = N });
        try self.asset_cache.put(BASS_ASSET, .{ .samples = self.bass_samples, .channels = 1, .frame_count = N });

        const drums = try self.project.addTrack(gpa, "Drums");
        try drums.clips.append(gpa, .{ .audio = .{ .id = model.allocId(), .source_id = DRUMS_ASSET, .timeline_start_frame = 0 } });
        self.drums_id = drums.id;

        const bass = try self.project.addTrack(gpa, "Bass");
        try bass.clips.append(gpa, .{ .audio = .{ .id = model.allocId(), .source_id = BASS_ASSET, .timeline_start_frame = 0 } });
        self.sidechain_effect_id = model.allocId();
        try bass.effects.append(gpa, .{
            .id = self.sidechain_effect_id,
            .params = .{ .sidechain_compressor = .{
                .source_track_id = drums.id,
                .threshold_db = -18,
                .ratio = 15,
                .attack_ms = 5,
                .release_ms = 50,
            } },
        });
        self.bass_id = bass.id;
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.project.deinit(self.gpa);
        self.asset_cache.deinit();
        self.gpa.free(self.drums_samples);
        self.gpa.free(self.bass_samples);
    }
};

const CtxHarness = struct {
    project_path: ?[]const u8 = null,
    history: persist.History = .{},
    job_registry: jobs.Registry = .{},
    offline_registry: @import("offline_audio.zig").Registry = undefined,
    pending_imports: std.ArrayList(app.PendingImport) = .empty,
    render_state: app.RenderState = .{},
    transport: ui.Transport = .stop,
    beat_time: f64 = 0,
    live_peaks: app.LivePeaks = .{},
    audio_diag: app.AudioDiag = .{},
    view: ui.View = .{},
    sc_rt: mixer.SidechainRuntime,
    trial_registry: @import("trial.zig").Registry,
    frame_count: u64 = 0,
    operation_counter: u64 = 0,
    mix_gate: @import("mix_preflight.zig").MixSessionGate = .{},

    fn init(gpa: std.mem.Allocator) CtxHarness {
        return .{
            .sc_rt = mixer.SidechainRuntime.init(gpa),
            .trial_registry = @import("trial.zig").Registry.init(gpa),
            .offline_registry = .init(gpa),
        };
    }

    fn deinit(self: *CtxHarness, gpa: std.mem.Allocator) void {
        self.history.deinit(gpa);
        self.job_registry.deinit(gpa);
        self.offline_registry.deinit();
        self.pending_imports.deinit(gpa);
        self.sc_rt.deinit();
        self.trial_registry.deinit();
    }

    fn ctx(self: *CtxHarness, gpa: std.mem.Allocator, io: std.Io, fx: *Fixture) app.DispatchCtx {
        self.mix_gate.passed = true;
        self.mix_gate.revision = fx.project.revision;
        return .{
            .gpa = gpa,
            .io = io,
            .project = &fx.project,
            .project_path = &self.project_path,
            .history = &self.history,
            .asset_cache = &fx.asset_cache,
            .job_registry = &self.job_registry,
            .offline_registry = &self.offline_registry,
            .pending_imports = &self.pending_imports,
            .render_state = &self.render_state,
            .transport = &self.transport,
            .beat_time = &self.beat_time,
            .live_peaks = &self.live_peaks,
            .audio_diag = &self.audio_diag,
            .view = &self.view,
            .sc_rt = &self.sc_rt,
            .trial_registry = &self.trial_registry,
            .frame_count = &self.frame_count,
            .operation_counter = &self.operation_counter,
            .mix_gate = &self.mix_gate,
        };
    }
};

// Tests 1+2: muted-track meter stays exactly zero; different tracks report
// independent (not master-derived) levels.
fn testPerTrackMeters(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: per-track meters are real (muted=0, tracks independent) ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    var voice_pool: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;
    var sc_rt = mixer.SidechainRuntime.init(gpa);
    defer sc_rt.deinit();
    var track_levels: [8]mixer.TrackLevel = [_]mixer.TrackLevel{.{}} ** 8;

    const frame: u64 = 2050; // inside a drum burst
    var l: f32 = 0;
    var r: f32 = 0;
    mixer.mixSample(&fx.project, &voice_pool, &fx.asset_cache, frame, frame, .{}, &sc_rt, null, null, null, null, null, SAMPLE_RATE, &l, &r, track_levels[0..2], null, null, false);

    const drums_level = @max(@abs(track_levels[0].l), @abs(track_levels[0].r));
    const bass_level = @max(@abs(track_levels[1].l), @abs(track_levels[1].r));
    std.debug.print("drums={d:.4} bass={d:.4}\n", .{ drums_level, bass_level });
    if (drums_level < 0.01) return error.DrumsMeterShouldBeAudible;
    if (bass_level < 0.01) return error.BassMeterShouldBeAudible;

    (fx.project.findTrack(fx.drums_id) orelse return error.TrackNotFound).mute = true;
    track_levels = [_]mixer.TrackLevel{.{}} ** 8;
    mixer.mixSample(&fx.project, &voice_pool, &fx.asset_cache, frame, frame, .{}, &sc_rt, null, null, null, null, null, SAMPLE_RATE, &l, &r, track_levels[0..2], null, null, false);
    std.debug.print("after mute: drums.l={d:.4} bass={d:.4}\n", .{ track_levels[0].l, @max(@abs(track_levels[1].l), @abs(track_levels[1].r)) });
    if (track_levels[0].l != 0 or track_levels[0].r != 0) return error.MutedTrackMeterNotZero;
    if (@max(@abs(track_levels[1].l), @abs(track_levels[1].r)) < 0.01) return error.BassMeterShouldBeUnaffectedByDrumsMute;

    std.debug.print("PASS\n\n", .{});
}

// Test 3: measure is bit-identical when repeated with identical arguments.
fn testMeasureDeterministic(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: measure is bit-identical on repeat ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.bass_id };
    const s1 = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 10000, 20000, SAMPLE_RATE, null, false);
    const s2 = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 10000, 20000, SAMPLE_RATE, null, false);
    const gr1 = s1.gain_reduction_peak_db orelse -999;
    const gr2 = s2.gain_reduction_peak_db orelse -999;
    std.debug.print("run1: peak={d:.4} rms={d:.4} gr={d:.4}\nrun2: peak={d:.4} rms={d:.4} gr={d:.4}\n", .{ s1.peak_dbfs, s1.rms_dbfs, gr1, s2.peak_dbfs, s2.rms_dbfs, gr2 });
    if (s1.peak_dbfs != s2.peak_dbfs or s1.rms_dbfs != s2.rms_dbfs) return error.NotDeterministic;
    if (gr1 != gr2) return error.GrNotDeterministic;
    std.debug.print("PASS\n\n", .{});
}

// Test 4: lowering the sidechain threshold on the same window increases GR.
fn testThresholdChangesGR(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: threshold change alters GR on the same window ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.bass_id };
    const start: u64 = 10000;
    const len: u64 = 20000;
    const before = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);

    const bass = fx.project.findTrack(fx.bass_id) orelse return error.TrackNotFound;
    for (bass.effects.items) |*e| {
        if (e.params == .sidechain_compressor) e.params.sidechain_compressor.threshold_db = -50;
    }
    const after = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);

    const gr_before = before.gain_reduction_peak_db orelse 0;
    const gr_after = after.gain_reduction_peak_db orelse 0;
    std.debug.print("threshold -18: GR={d:.2}dB   threshold -50: GR={d:.2}dB\n", .{ gr_before, gr_after });
    if (gr_after <= gr_before) return error.LoweringThresholdShouldIncreaseGR;
    std.debug.print("PASS\n\n", .{});
}

// Test 5: undo restores both the parameter and the measured result.
fn testUndoRestoresMeasurement(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: undo restores parameter and measurement ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.bass_id };
    const start: u64 = 10000;
    const len: u64 = 20000;

    const before = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);

    var history: persist.History = .{};
    defer history.deinit(gpa);
    try history.recordBeforeMutation(gpa, &fx.project);

    const bass = fx.project.findTrack(fx.bass_id) orelse return error.TrackNotFound;
    for (bass.effects.items) |*e| {
        if (e.params == .sidechain_compressor) e.params.sidechain_compressor.threshold_db = -50;
    }
    fx.project.revision += 1;

    const changed = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);
    if ((changed.gain_reduction_peak_db orelse 0) <= (before.gain_reduction_peak_db orelse 0)) return error.ChangeDidNotIncreaseGR;

    const did_undo = try history.undo(gpa, &fx.project);
    if (!did_undo) return error.UndoFailed;

    const bass2 = fx.project.findTrack(fx.bass_id) orelse return error.TrackNotFound;
    var restored_threshold: f32 = 0;
    for (bass2.effects.items) |e| {
        if (e.params == .sidechain_compressor) restored_threshold = e.params.sidechain_compressor.threshold_db;
    }
    if (restored_threshold != -18) return error.ThresholdNotRestored;

    const after_undo = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);
    std.debug.print("before={d:.2}dB changed={d:.2}dB after_undo={d:.2}dB\n", .{ before.gain_reduction_peak_db orelse 0, changed.gain_reduction_peak_db orelse 0, after_undo.gain_reduction_peak_db orelse 0 });
    if ((after_undo.gain_reduction_peak_db orelse -1) != (before.gain_reduction_peak_db orelse -1)) return error.MeasurementNotRestoredAfterUndo;

    std.debug.print("PASS\n\n", .{});
}

// Test 6: the raw sample buffer audition would write is numerically
// consistent with the stats measure reports for the exact same call.
fn testAuditionMatchesMeasure(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: audition sample buffer matches measure's own stats ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.bass_id };
    const start: u64 = 1900; // spans a drum burst
    const len: u64 = 3000;

    const buf = try gpa.alloc(f32, len * 2);
    defer gpa.free(buf);
    const stats = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, buf, false);

    const independent = dbfsFromSamples(buf);
    std.debug.print("measure: peak={d:.3} rms={d:.3}   from-buffer: peak={d:.3} rms={d:.3}\n", .{ stats.peak_dbfs, stats.rms_dbfs, independent.peak, independent.rms });
    if (@abs(stats.peak_dbfs - independent.peak) > 0.01) return error.AuditionBufferPeakMismatch;
    if (@abs(stats.rms_dbfs - independent.rms) > 0.01) return error.AuditionBufferRmsMismatch;
    std.debug.print("PASS\n\n", .{});
}

// Test 7: master (drums+bass summed) reads louder than the isolated bass
// track during a drums burst -- proves target selection actually changes
// what's measured, not just the label in the response.
fn testMasterDiffersFromTrack(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: master differs from isolated-track measurement ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const start: u64 = 1900;
    const len: u64 = 500;

    const master_stats = try app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .master = .master_output }, start, len, SAMPLE_RATE, null, false);
    const bass_stats = try app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .track = fx.bass_id }, start, len, SAMPLE_RATE, null, false);
    std.debug.print("master peak={d:.2} bass-only peak={d:.2}\n", .{ master_stats.peak_dbfs, bass_stats.peak_dbfs });
    if (master_stats.peak_dbfs <= bass_stats.peak_dbfs + 0.5) return error.MasterShouldBeLouderDuringDrumBurst;
    std.debug.print("PASS\n\n", .{});
}

// Test 8: the operation envelope (operation_id/revision_before/revision/
// applied_at_audio_frame) is correct and increments consistently across a
// sequence of real handleCommand calls.
fn testOperationEnvelope(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== test: operation envelope has correct revision_before/after ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    var h = CtxHarness.init(gpa);
    defer h.deinit(gpa);
    h.frame_count = 12345;
    var ctx = h.ctx(gpa, io, &fx);
    // addTrack() bumps project.revision on its own (two tracks were created
    // in Fixture.init), so the starting revision is whatever that left it at
    // -- not 0. Compare deltas, not a hardcoded absolute.
    const rev0: i64 = @intCast(fx.project.revision);

    var cmd_buf: [256]u8 = undefined;
    var resp_buf: [4096]u8 = undefined;
    const cmd1 = try std.fmt.bufPrint(&cmd_buf, "{{\"id\":1,\"cmd\":\"set_effect_param\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"threshold_db\":-6}}}}", .{ fx.bass_id, fx.sidechain_effect_id });
    const resp1 = app.handleCommand(&ctx, cmd1, &resp_buf);
    std.debug.print("resp1: {s}\n", .{resp1});
    const parsed1 = try std.json.parseFromSlice(std.json.Value, gpa, resp1, .{});
    defer parsed1.deinit();
    const op1 = parsed1.value.object.get("operation_id").?.integer;
    const rev_before1 = parsed1.value.object.get("revision_before").?.integer;
    const rev_after1 = parsed1.value.object.get("revision").?.integer;
    const frame1 = parsed1.value.object.get("applied_at_audio_frame").?.integer;
    if (rev_before1 != rev0) return error.WrongRevisionBefore;
    if (rev_after1 != rev_before1 + 1) return error.RevisionShouldIncrementByOne;
    if (frame1 != 12345) return error.AppliedFrameMismatch;

    var cmd_buf2: [256]u8 = undefined;
    var resp_buf2: [4096]u8 = undefined;
    const cmd2 = try std.fmt.bufPrint(&cmd_buf2, "{{\"id\":2,\"cmd\":\"set_effect_param\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"threshold_db\":-4}}}}", .{ fx.bass_id, fx.sidechain_effect_id });
    const resp2 = app.handleCommand(&ctx, cmd2, &resp_buf2);
    std.debug.print("resp2: {s}\n", .{resp2});
    const parsed2 = try std.json.parseFromSlice(std.json.Value, gpa, resp2, .{});
    defer parsed2.deinit();
    const op2 = parsed2.value.object.get("operation_id").?.integer;
    const rev_before2 = parsed2.value.object.get("revision_before").?.integer;

    if (op2 != op1 + 1) return error.OperationIdShouldIncrementByOne;
    if (rev_before2 != rev_after1) return error.SecondRevisionBeforeShouldEqualFirstRevisionAfter;

    std.debug.print("PASS\n\n", .{});
}

// Test 9: invalid frame ranges / an unknown track abstain with an explicit
// ok:false error, instead of silently fabricating a zero/default result.
fn testInvalidRangeErrors(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== test: invalid range / unknown track abstain with explicit errors ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    const bogus_track: model.TrackId = 999999;
    const result = app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .track = bogus_track }, 0, 1000, SAMPLE_RATE, null, false);
    if (result) |_| {
        return error.ExpectedTrackNotFoundError;
    } else |err| {
        if (err != error.TrackNotFound) return error.WrongErrorKind;
    }

    var h = CtxHarness.init(gpa);
    defer h.deinit(gpa);
    var ctx = h.ctx(gpa, io, &fx);

    var buf1: [1024]u8 = undefined;
    const resp_bad_track = app.handleCommand(&ctx, "{\"id\":1,\"cmd\":\"measure\",\"args\":{\"track_id\":999999,\"start_frame\":0,\"length_frames\":1000}}", &buf1);
    std.debug.print("bad track: {s}\n", .{resp_bad_track});
    if (std.mem.indexOf(u8, resp_bad_track, "\"ok\":false") == null) return error.ExpectedOkFalseForUnknownTrack;

    var buf2: [1024]u8 = undefined;
    const resp_zero_len = app.handleCommand(&ctx, "{\"id\":2,\"cmd\":\"measure\",\"args\":{\"start_frame\":0,\"length_frames\":0}}", &buf2);
    std.debug.print("zero length: {s}\n", .{resp_zero_len});
    if (std.mem.indexOf(u8, resp_zero_len, "\"ok\":false") == null) return error.ExpectedOkFalseForZeroLength;

    var buf3: [1024]u8 = undefined;
    const resp_too_long = app.handleCommand(&ctx, "{\"id\":3,\"cmd\":\"measure\",\"args\":{\"start_frame\":0,\"length_frames\":999999999}}", &buf3);
    std.debug.print("too long: {s}\n", .{resp_too_long});
    if (std.mem.indexOf(u8, resp_too_long, "\"ok\":false") == null) return error.ExpectedOkFalseForTooLong;

    std.debug.print("PASS\n\n", .{});
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testPerTrackMeters(gpa);
    try testMeasureDeterministic(gpa);
    try testThresholdChangesGR(gpa);
    try testUndoRestoresMeasurement(gpa);
    try testAuditionMatchesMeasure(gpa);
    try testMasterDiffersFromTrack(gpa);
    try testOperationEnvelope(gpa, io);
    try testInvalidRangeErrors(gpa, io);
    try testFxBypassAllMutesSidechain(gpa);

    std.debug.print("ALL PASS: P0 audio-feedback-loop regression suite (9 checks covering 9 required behaviors)\n", .{});
}

// Direct DSP check for the "Dry button doesn't change the sound" report:
// with fx_bypass_all=true, the sidechain insert on Bass must not touch the
// signal at all (bit-identical to the unprocessed dry sample), regardless
// of whether Drums would otherwise be ducking it.
fn testFxBypassAllMutesSidechain(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: fx_bypass_all silences the sidechain insert ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    // A single mixSample() call at a mid-burst frame is not enough -- the
    // sidechain envelope follower starts cold (env=0) and needs real
    // consecutive frames to attack, same reason measureRange needs a
    // preroll. Drive both runs continuously from frame 0 so the envelope is
    // actually warmed up by the time we compare.
    const end_frame: u64 = 2150; // 150 samples into the 200-sample burst starting at 2000
    const bass_track = fx.project.findTrack(fx.bass_id) orelse return error.TrackNotFound;
    const bass_volume = bass_track.volume;

    var track_levels: [8]mixer.TrackLevel = [_]mixer.TrackLevel{.{}} ** 8;
    var l: f32 = 0;
    var r: f32 = 0;

    var voice_pool_wet: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;
    var sc_rt_wet = mixer.SidechainRuntime.init(gpa);
    defer sc_rt_wet.deinit();
    var min_wet_ratio: f32 = 1.0; // wet/dry ratio at its most-reduced point
    var frame: u64 = 0;
    while (frame < end_frame) : (frame += 1) {
        mixer.mixSample(&fx.project, &voice_pool_wet, &fx.asset_cache, frame, frame, .{}, &sc_rt_wet, null, null, null, null, null, SAMPLE_RATE, &l, &r, track_levels[0..2], null, null, false);
        if (frame >= 2000) {
            const wet = @max(@abs(track_levels[1].l), @abs(track_levels[1].r));
            const dry = @abs(fx.bass_samples[frame]) * bass_volume;
            if (dry > 1.0e-6) min_wet_ratio = @min(min_wet_ratio, wet / dry);
        }
    }

    var voice_pool_dry: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;
    var sc_rt_dry = mixer.SidechainRuntime.init(gpa);
    defer sc_rt_dry.deinit();
    var max_dry_deviation: f32 = 0;
    frame = 0;
    while (frame < end_frame) : (frame += 1) {
        track_levels = [_]mixer.TrackLevel{.{}} ** 8;
        mixer.mixSample(&fx.project, &voice_pool_dry, &fx.asset_cache, frame, frame, .{}, &sc_rt_dry, null, null, null, null, null, SAMPLE_RATE, &l, &r, track_levels[0..2], null, null, true);
        const dry_out = @max(@abs(track_levels[1].l), @abs(track_levels[1].r));
        const expected_dry = @abs(fx.bass_samples[frame]) * bass_volume;
        max_dry_deviation = @max(max_dry_deviation, @abs(dry_out - expected_dry));
    }

    std.debug.print("min wet/dry ratio during burst={d:.4} (< 1.0 means sidechain reduced it)   max |fx_bypass_all output - raw dry|={d:.6}\n", .{ min_wet_ratio, max_dry_deviation });
    if (min_wet_ratio >= 0.98) return error.SidechainShouldHaveReducedWetSignal;
    if (max_dry_deviation > 1.0e-5) return error.FxBypassAllShouldMatchUnprocessedDrySample;

    std.debug.print("PASS\n\n", .{});
}
