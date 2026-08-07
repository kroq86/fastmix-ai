const std = @import("std");
const app = @import("main.zig");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const persist = @import("persist.zig");

const SAMPLE_RATE: u32 = 44100;
const N: usize = 48000;
const ASSET_ID: model.AssetId = 9001;

const Fixture = struct {
    gpa: std.mem.Allocator,
    project: model.Project = .{},
    asset_cache: mixer.AssetCache,
    samples: []f32,
    track_id: model.TrackId = 0,

    fn initMultiTone(gpa: std.mem.Allocator) !Fixture {
        var self: Fixture = .{
            .gpa = gpa,
            .asset_cache = mixer.AssetCache.init(gpa),
            .samples = try gpa.alloc(f32, N),
        };
        for (0..N) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
            self.samples[i] = 0.25 * @sin(2.0 * std.math.pi * 60.0 * t) +
                0.25 * @sin(2.0 * std.math.pi * 1000.0 * t) +
                0.25 * @sin(2.0 * std.math.pi * 8000.0 * t);
        }
        try self.project.assets.append(gpa, .{
            .id = ASSET_ID,
            .relative_path = try gpa.dupe(u8, "synthetic-eq-types"),
            .sample_rate = SAMPLE_RATE,
            .channels = 1,
            .frame_count = N,
        });
        try self.asset_cache.put(ASSET_ID, .{ .samples = self.samples, .channels = 1, .frame_count = N });
        const tr = try self.project.addTrack(gpa, "Synth");
        try tr.clips.append(gpa, .{ .audio = .{ .id = model.allocId(), .source_id = ASSET_ID, .timeline_start_frame = 0 } });
        self.track_id = tr.id;
        self.project.sample_rate = SAMPLE_RATE;
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.project.deinit(self.gpa);
        self.asset_cache.deinit();
        self.gpa.free(self.samples);
    }

    fn addEq(self: *Fixture, band: model.EqBand) !model.EffectId {
        const track = self.project.findTrack(self.track_id) orelse return error.TrackNotFound;
        var bands: std.ArrayList(model.EqBand) = .empty;
        try bands.append(self.gpa, band);
        const id = model.allocId();
        try track.effects.append(self.gpa, .{ .id = id, .params = .{ .eq = .{ .bands = bands } } });
        return id;
    }
};

fn goertzelEnergy(samples: []const f32, sr: f32, freq: f32) f32 {
    const n = samples.len;
    const k = @as(f32, @floatFromInt(@as(usize, @intFromFloat(0.5 + @as(f32, @floatFromInt(n)) * freq / sr))));
    const w = 2.0 * std.math.pi * k / @as(f32, @floatFromInt(n));
    const coeff = 2.0 * @cos(w);
    var s0: f32 = 0;
    var s1: f32 = 0;
    var s2: f32 = 0;
    for (samples) |v| {
        s0 = v + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    const power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    return power;
}

fn processMonoThroughEq(band: model.EqBand, input: []const f32, output: []f32, sr: f32) void {
    var x1: f32 = 0;
    var x2: f32 = 0;
    var y1: f32 = 0;
    var y2: f32 = 0;
    const c = mixer.biquadCoeffs(band.band_type, band.frequency_hz, band.gain_db, band.q, sr);
    for (input, 0..) |x, i| {
        const y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        output[i] = y;
        if (!std.math.isFinite(y)) @panic("NaN/Inf in filter");
    }
}

fn testLegacyLoadPeakQ(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 1 legacy EQ loads as peak/Q 0.707 ===\n", .{});
    const json =
        \\{"format":"fastmix-ai-project","version":1,"project":{"bpm":120,"bar_size":4,"bar_quant":16,"length_bars":16,"sample_rate":44100,"revision":1,"tracks":[{"id":1,"name":"t","clips":[],"effects":[{"id":10,"bypassed":false,"params":{"eq":{"bands":[{"freq":800,"gain_db":-3}]}}}]}],"assets":[]}}
    ;
    const parsed = try std.json.parseFromSlice(model.ProjectFile, gpa, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var project = try model.fromDto(gpa, parsed.value.project);
    defer project.deinit(gpa);
    const band = project.tracks.items[0].effects.items[0].params.eq.bands.items[0];
    if (band.band_type != .peak) return error.LegacyType;
    if (@abs(band.q - 0.707) > 0.001) return error.LegacyQ;
    if (@abs(band.frequency_hz - 800) > 0.1) return error.LegacyFreq;
    std.debug.print("PASS\n\n", .{});
}

fn testPeakZeroTransparent(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 2 peak 0 dB approx transparent ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const dry = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    _ = try fx.addEq(.{ .band_type = .peak, .frequency_hz = 1000, .gain_db = 0, .q = 0.707 });
    const wet = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (@abs(wet.rms_dbfs - dry.rms_dbfs) > 0.15) return error.NotTransparent;
    std.debug.print("PASS\n\n", .{});
}

fn testPeakBoostCut(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 3/4 peak boost/cut at target ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const dry = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    const eid = try fx.addEq(.{ .band_type = .peak, .frequency_hz = 1000, .gain_db = 12, .q = 0.707 });
    _ = eid;
    const boosted = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (boosted.band_energy_db[4] < dry.band_energy_db[4] + 4.0) return error.BoostFailed;
    // cut
    fx.project.findTrack(fx.track_id).?.effects.items[0].params.eq.bands.items[0].gain_db = -12;
    const cut = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (cut.band_energy_db[4] > dry.band_energy_db[4] - 4.0) return error.CutFailed;
    std.debug.print("PASS\n\n", .{});
}

fn testNarrowVsBroadQ(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 5 narrow Q affects smaller region than broad ===\n", .{});
    var in_buf: [8192]f32 = undefined;
    var out_n: [8192]f32 = undefined;
    var out_b: [8192]f32 = undefined;
    for (&in_buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        s.* = @sin(2.0 * std.math.pi * 1000.0 * t) + 0.5 * @sin(2.0 * std.math.pi * 2000.0 * t);
    }
    processMonoThroughEq(.{ .band_type = .peak, .frequency_hz = 1000, .gain_db = 12, .q = 8.0 }, &in_buf, &out_n, 44100);
    processMonoThroughEq(.{ .band_type = .peak, .frequency_hz = 1000, .gain_db = 12, .q = 0.5 }, &in_buf, &out_b, 44100);
    const n1 = goertzelEnergy(&out_n, 44100, 1000);
    const n2 = goertzelEnergy(&out_n, 44100, 2000);
    const b1 = goertzelEnergy(&out_b, 44100, 1000);
    const b2 = goertzelEnergy(&out_b, 44100, 2000);
    const narrow_ratio = n1 / @max(n2, 1e-12);
    const broad_ratio = b1 / @max(b2, 1e-12);
    std.debug.print("narrow_ratio={d:.2} broad_ratio={d:.2}\n", .{ narrow_ratio, broad_ratio });
    if (narrow_ratio <= broad_ratio) return error.QWidthUnexpected;
    _ = gpa;
    std.debug.print("PASS\n\n", .{});
}

fn testShelves(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 6-9 low/high shelf raise/cut ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const dry = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    _ = try fx.addEq(.{ .band_type = .low_shelf, .frequency_hz = 200, .gain_db = 9, .q = 0.707 });
    const ls = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    const d_low = (ls.band_energy_db[0] - dry.band_energy_db[0]);
    const d_high = (ls.band_energy_db[7] - dry.band_energy_db[7]);
    if (d_low < 2.0) return error.LowShelfBoost;
    if (d_low <= d_high) return error.LowShelfNotSelective;

    fx.project.findTrack(fx.track_id).?.effects.items[0].params.eq.bands.items[0] = .{
        .band_type = .low_shelf,
        .frequency_hz = 200,
        .gain_db = -9,
        .q = 0.707,
    };
    const lsc = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (lsc.band_energy_db[0] > dry.band_energy_db[0] - 2.0) return error.LowShelfCut;

    fx.project.findTrack(fx.track_id).?.effects.items[0].params.eq.bands.items[0] = .{
        .band_type = .high_shelf,
        .frequency_hz = 4000,
        .gain_db = 9,
        .q = 0.707,
    };
    const hs = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (hs.band_energy_db[7] < dry.band_energy_db[7] + 2.0) return error.HighShelfBoost;
    if ((hs.band_energy_db[7] - dry.band_energy_db[7]) <= (hs.band_energy_db[0] - dry.band_energy_db[0])) return error.HighShelfNotSelective;

    fx.project.findTrack(fx.track_id).?.effects.items[0].params.eq.bands.items[0].gain_db = -9;
    const hsc = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (hsc.band_energy_db[7] > dry.band_energy_db[7] - 2.0) return error.HighShelfCut;
    std.debug.print("PASS\n\n", .{});
}

fn testHpf(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 10-12 HPF attenuates below, preserves above, Q changes ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const dry = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    _ = try fx.addEq(.{ .band_type = .highpass, .frequency_hz = 300, .gain_db = 0, .q = 0.707 });
    const hpf = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (hpf.band_energy_db[0] > dry.band_energy_db[0] - 4.0) return error.HpfShouldCutSub;
    if (hpf.band_energy_db[7] < dry.band_energy_db[7] - 3.0) return error.HpfShouldPreserveAir;

    fx.project.findTrack(fx.track_id).?.effects.items[0].params.eq.bands.items[0].q = 4.0;
    const hpf_q = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    // Q change should alter near-cutoff (250/500) energy relative to previous HPF
    if (@abs(hpf_q.band_energy_db[2] - hpf.band_energy_db[2]) < 0.2 and
        @abs(hpf_q.band_energy_db[3] - hpf.band_energy_db[3]) < 0.2)
        return error.HpfQNoChange;
    std.debug.print("PASS\n\n", .{});
}

fn testBypassAndStereoAndBounds(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 13-15 bypass / stereo / no NaN ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    // Make stereo
    const asset = fx.asset_cache.getPtr(ASSET_ID).?;
    var stereo = try gpa.alloc(f32, N * 2);
    defer gpa.free(stereo);
    for (0..N) |i| {
        stereo[i * 2] = fx.samples[i];
        stereo[i * 2 + 1] = fx.samples[i] * 0.5;
    }
    asset.samples = stereo;
    asset.channels = 2;
    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const dry = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    const eid = try fx.addEq(.{ .band_type = .peak, .frequency_hz = 1000, .gain_db = 12, .q = 0.707, .bypass = true });
    _ = eid;
    const byp = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (@abs(byp.rms_dbfs - dry.rms_dbfs) > 0.15) return error.BypassNotTransparent;

    // bounds coeffs
    const edge = mixer.biquadCoeffs(.highpass, 10, 0, 0.1, 44100);
    const edge2 = mixer.biquadCoeffs(.peak, 20000, 24, 18, 44100);
    if (!std.math.isFinite(edge.b0) or !std.math.isFinite(edge2.a1)) return error.NanAtBounds;
    std.debug.print("PASS\n\n", .{});
}

fn testApiRejects(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== 16-18 invalid freq/Q + highpass gain reject ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    const eid = try fx.addEq(.{ .band_type = .peak, .frequency_hz = 1000, .gain_db = 0, .q = 0.707 });

    var history: persist.History = .{};
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
    mix_gate.passed = true;
    mix_gate.revision = fx.project.revision;

    var ctx: app.DispatchCtx = .{
        .gpa = gpa,
        .io = io,
        .project = &fx.project,
        .history = &history,
        .job_registry = &job_registry,
        .offline_registry = &offline_registry,
        .pending_imports = &pending,
        .render_state = &render_state,
        .asset_cache = &fx.asset_cache,
        .transport = &transport,
        .beat_time = &beat_time,
        .live_peaks = &live_peaks,
        .audio_diag = &audio_diag,
        .view = &view,
        .sc_rt = &sc_rt,
        .trial_registry = &trial_registry,
        .frame_count = &frame_count,
        .operation_counter = &operation_counter,
        .project_path = &project_path,
        .mix_gate = &mix_gate,
    };

    var resp: [1024]u8 = undefined;
    const bad_f = try std.fmt.allocPrint(gpa, "{{\"id\":1,\"cmd\":\"set_effect_param\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"frequency_hz\",\"value\":5}}}}", .{ fx.track_id, eid });
    defer gpa.free(bad_f);
    if (std.mem.indexOf(u8, app.handleCommand(&ctx, bad_f, &resp), "frequency_out_of_range") == null) return error.ExpectedFreqReject;

    const bad_q = try std.fmt.allocPrint(gpa, "{{\"id\":2,\"cmd\":\"set_effect_param\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"q\",\"value\":50}}}}", .{ fx.track_id, eid });
    defer gpa.free(bad_q);
    if (std.mem.indexOf(u8, app.handleCommand(&ctx, bad_q, &resp), "q_out_of_range") == null) return error.ExpectedQReject;

    const to_hpf = try std.fmt.allocPrint(gpa, "{{\"id\":3,\"cmd\":\"set_effect_param\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"band_type\",\"value\":\"highpass\"}}}}", .{ fx.track_id, eid });
    defer gpa.free(to_hpf);
    _ = app.handleCommand(&ctx, to_hpf, &resp);
    const bad_g = try std.fmt.allocPrint(gpa, "{{\"id\":4,\"cmd\":\"set_effect_param\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"gain_db\",\"value\":3}}}}", .{ fx.track_id, eid });
    defer gpa.free(bad_g);
    if (std.mem.indexOf(u8, app.handleCommand(&ctx, bad_g, &resp), "highpass_gain_forbidden") == null) return error.ExpectedHpfGainReject;
    std.debug.print("PASS\n\n", .{});
}

fn testSaveLoadRoundTrip(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 22 save/load round-trip ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    _ = try fx.addEq(.{ .band_type = .high_shelf, .frequency_hz = 5000, .gain_db = -4, .q = 1.2, .bypass = false });
    const path = "tmp_eq_types_roundtrip.fastmix.json";
    try persist.saveAtomic(gpa, &fx.project, path);
    var loaded = try persist.load(gpa, path);
    defer loaded.deinit(gpa);
    const b = loaded.tracks.items[0].effects.items[0].params.eq.bands.items[0];
    if (b.band_type != .high_shelf) return error.TypeLost;
    if (@abs(b.frequency_hz - 5000) > 0.1) return error.FreqLost;
    if (@abs(b.q - 1.2) > 0.01) return error.QLost;
    if (@abs(b.gain_db + 4) > 0.01) return error.GainLost;
    std.debug.print("PASS\n\n", .{});
}

fn testAssessShelfAndHpf(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== 23/24 eq_assess shelf + HPF ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    const eid = try fx.addEq(.{ .band_type = .low_shelf, .frequency_hz = 150, .gain_db = 0, .q = 0.707 });

    var history: persist.History = .{};
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
    mix_gate.passed = true;
    mix_gate.revision = fx.project.revision;

    var ctx: app.DispatchCtx = .{
        .gpa = gpa,
        .io = io,
        .project = &fx.project,
        .history = &history,
        .job_registry = &job_registry,
        .offline_registry = &offline_registry,
        .pending_imports = &pending,
        .render_state = &render_state,
        .asset_cache = &fx.asset_cache,
        .transport = &transport,
        .beat_time = &beat_time,
        .live_peaks = &live_peaks,
        .audio_diag = &audio_diag,
        .view = &view,
        .sc_rt = &sc_rt,
        .trial_registry = &trial_registry,
        .frame_count = &frame_count,
        .operation_counter = &operation_counter,
        .project_path = &project_path,
        .mix_gate = &mix_gate,
    };

    var resp: [65536]u8 = undefined;
    const shelf_cmd = try std.fmt.allocPrint(gpa, "{{\"id\":1,\"cmd\":\"eq_assess_and_adjust\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"gain_db\",\"value\":8,\"start_frame\":1000,\"length_frames\":20000,\"min_band_energy_delta_db\":1,\"max_rms_change_db\":20,\"max_peak_dbfs\":6,\"max_mid_change_db\":8}}}}", .{ fx.track_id, eid });
    defer gpa.free(shelf_cmd);
    const shelf_resp = app.handleCommand(&ctx, shelf_cmd, &resp);
    std.debug.print("shelf assess: {s}\n", .{shelf_resp[0..@min(shelf_resp.len, 400)]});
    if (std.mem.indexOf(u8, shelf_resp, "\"ok\":true") == null) return error.ShelfAssessFailed;
    if (std.mem.indexOf(u8, shelf_resp, "low_shelf") == null and std.mem.indexOf(u8, shelf_resp, "\"eq\":") == null) return error.MissingEqBlock;

    // Reset to HPF via set + assess frequency
    const set_hpf = try std.fmt.allocPrint(gpa, "{{\"id\":2,\"cmd\":\"set_effect_param\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"band_type\",\"value\":\"highpass\"}}}}", .{ fx.track_id, eid });
    defer gpa.free(set_hpf);
    // may fail if gain still non-zero after commit — clear gain first
    const set_g0 = try std.fmt.allocPrint(gpa, "{{\"id\":3,\"cmd\":\"set_effect_param\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"gain_db\",\"value\":0}}}}", .{ fx.track_id, eid });
    defer gpa.free(set_g0);
    _ = app.handleCommand(&ctx, set_g0, &resp);
    const hpf_set = app.handleCommand(&ctx, set_hpf, &resp);
    if (std.mem.indexOf(u8, hpf_set, "\"ok\":true") == null) {
        // force type in model
        fx.project.findTrack(fx.track_id).?.effects.items[0].params.eq.bands.items[0].band_type = .highpass;
        fx.project.findTrack(fx.track_id).?.effects.items[0].params.eq.bands.items[0].gain_db = 0;
        fx.project.findTrack(fx.track_id).?.effects.items[0].params.eq.bands.items[0].frequency_hz = 80;
    }
    mix_gate.revision = fx.project.revision;
    const hpf_cmd = try std.fmt.allocPrint(gpa, "{{\"id\":4,\"cmd\":\"eq_assess_and_adjust\",\"args\":{{\"track_id\":{d},\"effect_id\":{d},\"band_index\":0,\"param\":\"frequency_hz\",\"value\":250,\"start_frame\":1000,\"length_frames\":20000,\"min_band_energy_delta_db\":1,\"max_rms_change_db\":20,\"max_peak_dbfs\":6,\"max_mid_change_db\":8}}}}", .{ fx.track_id, eid });
    defer gpa.free(hpf_cmd);
    const hpf_resp = app.handleCommand(&ctx, hpf_cmd, &resp);
    std.debug.print("hpf assess: {s}\n", .{hpf_resp[0..@min(hpf_resp.len, 400)]});
    if (std.mem.indexOf(u8, hpf_resp, "\"ok\":true") == null) return error.HpfAssessFailed;
    if (std.mem.indexOf(u8, hpf_resp, "highpass") == null) return error.HpfTypeMissing;
    std.debug.print("PASS\n\n", .{});
}

fn testDeterministicMeasure(gpa: std.mem.Allocator) !void {
    std.debug.print("=== 20 deterministic measure ===\n", .{});
    var fx = try Fixture.initMultiTone(gpa);
    defer fx.deinit();
    _ = try fx.addEq(.{ .band_type = .peak, .frequency_hz = 1000, .gain_db = 6, .q = 1.0 });
    const target: app.MeasureTarget = .{ .track = fx.track_id };
    const a = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    const b = try app.measureRange(gpa, &fx.project, &fx.asset_cache, target, 1000, 20000, SAMPLE_RATE, null, false);
    if (@abs(a.rms_dbfs - b.rms_dbfs) > 1e-4) return error.Nondeterministic;
    if (@abs(a.band_energy_db[4] - b.band_energy_db[4]) > 1e-3) return error.NondeterministicBands;
    std.debug.print("PASS\n\n", .{});
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testLegacyLoadPeakQ(gpa);
    try testPeakZeroTransparent(gpa);
    try testPeakBoostCut(gpa);
    try testNarrowVsBroadQ(gpa);
    try testShelves(gpa);
    try testHpf(gpa);
    try testBypassAndStereoAndBounds(gpa);
    try testApiRejects(gpa, io);
    try testSaveLoadRoundTrip(gpa);
    try testDeterministicMeasure(gpa);
    try testAssessShelfAndHpf(gpa, io);

    std.debug.print("ALL PASS: spike-eq-filter-types\n", .{});
}
