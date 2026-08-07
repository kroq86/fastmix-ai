const std = @import("std");
const app = @import("main.zig");
const model = @import("model.zig");
const mixer = @import("mixer.zig");

// Positive EQ DSP suite: peaking biquad (fixed Q) must change measure when
// gain_db changes. Closes the research mixing EQ gap for observe+hearability
// (docs/research/02 §2) — implement, don't assert absence.

const SAMPLE_RATE: u32 = 44100;
const N: usize = 40000;
const ASSET_ID: model.AssetId = 8001;

const Fixture = struct {
    gpa: std.mem.Allocator,
    project: model.Project = .{},
    asset_cache: mixer.AssetCache,
    samples: []f32,
    track_id: model.TrackId = 0,

    fn init(gpa: std.mem.Allocator) !Fixture {
        var self: Fixture = .{
            .gpa = gpa,
            .asset_cache = mixer.AssetCache.init(gpa),
            .samples = try gpa.alloc(f32, N),
        };
        // Strong 1 kHz component so a peaking boost/cut at 1 kHz is unambiguous in RMS.
        for (0..N) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
            self.samples[i] = 0.3 * @sin(2.0 * std.math.pi * 1000.0 * t) +
                0.1 * @sin(2.0 * std.math.pi * 110.0 * t);
        }
        try self.project.assets.append(gpa, .{
            .id = ASSET_ID,
            .relative_path = try gpa.dupe(u8, "synthetic-eq"),
            .sample_rate = SAMPLE_RATE,
            .channels = 1,
            .frame_count = N,
        });
        try self.asset_cache.put(ASSET_ID, .{ .samples = self.samples, .channels = 1, .frame_count = N });
        const tr = try self.project.addTrack(gpa, "Synth");
        try tr.clips.append(gpa, .{ .audio = .{ .id = model.allocId(), .source_id = ASSET_ID, .timeline_start_frame = 0 } });
        self.track_id = tr.id;
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.project.deinit(self.gpa);
        self.asset_cache.deinit();
        self.gpa.free(self.samples);
    }
};

fn testPeakBoostRaisesRms(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: peaking EQ +12dB @ 1kHz raises measure RMS ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const start: u64 = 2000;
    const len: u64 = 20000;

    const dry = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);

    const track = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
    var bands: std.ArrayList(model.EqBand) = .empty;
    try bands.append(gpa, .{ .frequency_hz = 1000, .gain_db = 12 });
    try track.effects.append(gpa, .{
        .id = model.allocId(),
        .params = .{ .eq = .{ .bands = bands } },
    });

    const boosted = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);
    std.debug.print("dry rms={d:.3} peak={d:.3}  boost rms={d:.3} peak={d:.3}\n", .{
        dry.rms_dbfs, dry.peak_dbfs, boosted.rms_dbfs, boosted.peak_dbfs,
    });
    if (boosted.rms_dbfs < dry.rms_dbfs + 3.0) return error.BoostShouldRaiseRmsByAtLeast3db;
    if (boosted.peak_dbfs <= dry.peak_dbfs) return error.BoostShouldRaisePeak;

    std.debug.print("PASS\n\n", .{});
}

fn testPeakCutLowersRms(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: peaking EQ -12dB @ 1kHz lowers measure RMS ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const start: u64 = 2000;
    const len: u64 = 20000;

    const dry = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);

    const track = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
    var bands: std.ArrayList(model.EqBand) = .empty;
    try bands.append(gpa, .{ .frequency_hz = 1000, .gain_db = -12 });
    try track.effects.append(gpa, .{
        .id = model.allocId(),
        .params = .{ .eq = .{ .bands = bands } },
    });

    const cut = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, start, len, SAMPLE_RATE, null, false);
    std.debug.print("dry rms={d:.3}  cut rms={d:.3}\n", .{ dry.rms_dbfs, cut.rms_dbfs });
    if (cut.rms_dbfs > dry.rms_dbfs - 3.0) return error.CutShouldLowerRmsByAtLeast3db;

    std.debug.print("PASS\n\n", .{});
}

fn makeCtx(
    gpa: std.mem.Allocator,
    io: std.Io,
    fx: *Fixture,
    history: *@import("persist.zig").History,
    job_registry: *@import("jobs.zig").Registry,
    offline_registry: *@import("offline_audio.zig").Registry,
    pending: *std.ArrayList(app.PendingImport),
    render_state: *app.RenderState,
    transport: *@import("ui.zig").Transport,
    beat_time: *f64,
    live_peaks: *app.LivePeaks,
    audio_diag: *app.AudioDiag,
    view: *@import("ui.zig").View,
    sc_rt: *mixer.SidechainRuntime,
    trial_registry: *@import("trial.zig").Registry,
    frame_count: *u64,
    operation_counter: *u64,
    project_path: *?[]const u8,
    mix_gate: *@import("mix_preflight.zig").MixSessionGate,
) app.DispatchCtx {
    mix_gate.passed = true;
    mix_gate.revision = fx.project.revision;
    return .{
        .gpa = gpa,
        .io = io,
        .project = &fx.project,
        .project_path = project_path,
        .history = history,
        .asset_cache = &fx.asset_cache,
        .job_registry = job_registry,
        .offline_registry = offline_registry,
        .pending_imports = pending,
        .render_state = render_state,
        .transport = transport,
        .beat_time = beat_time,
        .live_peaks = live_peaks,
        .audio_diag = audio_diag,
        .view = view,
        .sc_rt = sc_rt,
        .trial_registry = trial_registry,
        .frame_count = frame_count,
        .operation_counter = operation_counter,
        .mix_gate = mix_gate,
    };
}

fn testSpectralBandEnergyHears1k(gpa: std.mem.Allocator) !void {
    std.debug.print("=== test: measure band_energy_db peaks near 1kHz ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const stats = try app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .track = fx.track_id }, 2000, 20000, SAMPLE_RATE, null, false);
    const i1k = app.nearestSpectralBandIndex(1000);
    var loudest: usize = 0;
    for (stats.band_energy_db, 0..) |e, i| {
        if (e > stats.band_energy_db[loudest]) loudest = i;
        std.debug.print("  {d}Hz -> {d:.2} dB\n", .{ app.SPECTRAL_BAND_HZ[i], e });
    }
    if (loudest != i1k) return error.Expected1kBandLoudest;
    std.debug.print("PASS (loudest bin={d}Hz)\n\n", .{app.SPECTRAL_BAND_HZ[loudest]});
}

fn testInsertEffectEqViaSocket(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== test: insert_effect eq is audible via measure ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    var history: @import("persist.zig").History = .{};
    defer history.deinit(gpa);
    var job_registry: @import("jobs.zig").Registry = .{};
    defer job_registry.deinit(gpa);
    var offline_registry = @import("offline_audio.zig").Registry.init(gpa);
    defer offline_registry.deinit();
    var pending: std.ArrayList(app.PendingImport) = .empty;
    defer pending.deinit(gpa);
    var render_state: app.RenderState = .{};
    var transport: @import("ui.zig").Transport = .stop;
    var beat_time: f64 = 0;
    var live_peaks: app.LivePeaks = .{};
    var audio_diag: app.AudioDiag = .{};
    var view: @import("ui.zig").View = .{};
    var sc_rt = mixer.SidechainRuntime.init(gpa);
    defer sc_rt.deinit();
    var trial_registry: @import("trial.zig").Registry = .init(gpa);
    defer trial_registry.deinit();
    var frame_count: u64 = 0;
    var operation_counter: u64 = 0;
    var project_path: ?[]const u8 = null;
    var mix_gate: @import("mix_preflight.zig").MixSessionGate = .{};
    defer mix_gate.clear(gpa);
    var ctx = makeCtx(gpa, io, &fx, &history, &job_registry, &offline_registry, &pending, &render_state, &transport, &beat_time, &live_peaks, &audio_diag, &view, &sc_rt, &trial_registry, &frame_count, &operation_counter, &project_path, &mix_gate);

    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const dry = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 2000, 20000, SAMPLE_RATE, null, false);

    var cmd_buf: [512]u8 = undefined;
    var resp_buf: [2048]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "{{\"id\":1,\"cmd\":\"insert_effect\",\"args\":{{\"track_id\":{d},\"effect\":\"eq\",\"freq\":1000,\"gain_db\":12}}}}", .{fx.track_id});
    const resp = app.handleCommand(&ctx, cmd, &resp_buf);
    std.debug.print("insert: {s}\n", .{resp});
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return error.InsertEqFailed;

    const after = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 2000, 20000, SAMPLE_RATE, null, false);
    std.debug.print("dry rms={d:.3} after insert rms={d:.3}\n", .{ dry.rms_dbfs, after.rms_dbfs });
    if (after.rms_dbfs < dry.rms_dbfs + 3.0) return error.InsertEqShouldRaiseRms;

    std.debug.print("PASS\n\n", .{});
}

fn testEqAssessAndAdjustCommitAndRollback(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== test: eq_assess_and_adjust commit + clip rollback ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();

    const track = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
    var bands: std.ArrayList(model.EqBand) = .empty;
    try bands.append(gpa, .{ .frequency_hz = 1000, .gain_db = 0 });
    const effect_id = model.allocId();
    try track.effects.append(gpa, .{
        .id = effect_id,
        .params = .{ .eq = .{ .bands = bands } },
    });

    var history: @import("persist.zig").History = .{};
    defer history.deinit(gpa);
    var job_registry: @import("jobs.zig").Registry = .{};
    defer job_registry.deinit(gpa);
    var offline_registry = @import("offline_audio.zig").Registry.init(gpa);
    defer offline_registry.deinit();
    var pending: std.ArrayList(app.PendingImport) = .empty;
    defer pending.deinit(gpa);
    var render_state: app.RenderState = .{};
    var transport: @import("ui.zig").Transport = .stop;
    var beat_time: f64 = 0;
    var live_peaks: app.LivePeaks = .{};
    var audio_diag: app.AudioDiag = .{};
    var view: @import("ui.zig").View = .{};
    var sc_rt = mixer.SidechainRuntime.init(gpa);
    defer sc_rt.deinit();
    var trial_registry: @import("trial.zig").Registry = .init(gpa);
    defer trial_registry.deinit();
    var frame_count: u64 = 0;
    var operation_counter: u64 = 0;
    var project_path: ?[]const u8 = null;
    var mix_gate: @import("mix_preflight.zig").MixSessionGate = .{};
    defer mix_gate.clear(gpa);
    var ctx = makeCtx(gpa, io, &fx, &history, &job_registry, &offline_registry, &pending, &render_state, &transport, &beat_time, &live_peaks, &audio_diag, &view, &sc_rt, &trial_registry, &frame_count, &operation_counter, &project_path, &mix_gate);

    var cmd_buf: [768]u8 = undefined;
    var resp_buf: [16384]u8 = undefined;
    const commit_cmd = try std.fmt.bufPrint(&cmd_buf, "{{\"id\":1,\"cmd\":\"eq_assess_and_adjust\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"gain_db\",\"value\":6,\"start_frame\":2000,\"length_frames\":20000,\"min_band_energy_delta_db\":2,\"max_rms_change_db\":12,\"max_peak_dbfs\":6}}}}", .{ fx.track_id, effect_id });
    const commit_resp = app.handleCommand(&ctx, commit_cmd, &resp_buf);
    std.debug.print("commit: {s}\n", .{commit_resp});
    if (std.mem.indexOf(u8, commit_resp, "\"decision\":\"committed\"") == null) return error.ExpectedCommit;
    {
        const t = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
        const gain_after_commit = t.effects.items[0].params.eq.bands.items[0].gain_db;
        if (@abs(gain_after_commit - 6.0) > 0.01) return error.GainNotCommitted;
    }
    mix_gate.revision = fx.project.revision;

    const rollback_cmd = try std.fmt.bufPrint(&cmd_buf, "{{\"id\":2,\"cmd\":\"eq_assess_and_adjust\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"gain_db\",\"value\":24,\"start_frame\":2000,\"length_frames\":20000,\"min_band_energy_delta_db\":1,\"max_rms_change_db\":40,\"max_peak_dbfs\":-3}}}}", .{ fx.track_id, effect_id });
    const rollback_resp = app.handleCommand(&ctx, rollback_cmd, &resp_buf);
    std.debug.print("rollback: {s}\n", .{rollback_resp});
    if (std.mem.indexOf(u8, rollback_resp, "\"decision\":\"rolled_back\"") == null) return error.ExpectedRollback;
    {
        const t = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
        const gain_after_rb = t.effects.items[0].params.eq.bands.items[0].gain_db;
        if (@abs(gain_after_rb - 6.0) > 0.01) return error.GainShouldStayAtCommitted6;
    }

    std.debug.print("PASS\n\n", .{});
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testPeakBoostRaisesRms(gpa);
    try testPeakCutLowersRms(gpa);
    try testSpectralBandEnergyHears1k(gpa);
    try testInsertEffectEqViaSocket(gpa, io);
    try testEqAssessAndAdjustCommitAndRollback(gpa, io);

    std.debug.print("ALL PASS: peaking EQ DSP + spectral measure + eq_assess_and_adjust\n", .{});
}
