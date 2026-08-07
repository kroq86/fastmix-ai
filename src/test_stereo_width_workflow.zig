const std = @import("std");
const app = @import("main.zig");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const stereo_analysis = @import("stereo_analysis.zig");
const loudness = @import("loudness.zig");
const persist = @import("persist.zig");

const SAMPLE_RATE: u32 = 44100;
const N: usize = 44100;

fn db(a: f32) f32 {
    return 20.0 * std.math.log10(@max(a, 1.0e-10));
}

fn makeStereoTone(gpa: std.mem.Allocator, left_hz: f32, right_hz: f32, amp: f32) ![]f32 {
    const buf = try gpa.alloc(f32, N * 2);
    for (0..N) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        buf[i * 2] = amp * @sin(2.0 * std.math.pi * left_hz * t);
        buf[i * 2 + 1] = amp * @sin(2.0 * std.math.pi * right_hz * t);
    }
    return buf;
}

fn applyWidthOffline(in: []const f32, out: []f32, low_w: f32, high_w: f32, xo_hz: f32, crossover: bool) void {
    var lm = stereo_analysis.WidthOnePole.initLpf(xo_hz, @floatFromInt(SAMPLE_RATE));
    var ls = stereo_analysis.WidthOnePole.initLpf(xo_hz, @floatFromInt(SAMPLE_RATE));
    const frames = in.len / 2;
    for (0..frames) |i| {
        const r = stereo_analysis.applyWidthSample(in[i * 2], in[i * 2 + 1], low_w, high_w, &lm, &ls, crossover);
        out[i * 2] = r.l;
        out[i * 2 + 1] = r.r;
    }
}

fn midRms(buf: []const f32) f32 {
    var s: f64 = 0;
    const frames = buf.len / 2;
    for (0..frames) |i| {
        const m = 0.5 * (buf[i * 2] + buf[i * 2 + 1]);
        s += @as(f64, m) * @as(f64, m);
    }
    return @floatCast(@sqrt(s / @as(f64, @floatFromInt(frames))));
}

fn sideRms(buf: []const f32) f32 {
    var s: f64 = 0;
    const frames = buf.len / 2;
    for (0..frames) |i| {
        const side = 0.5 * (buf[i * 2] - buf[i * 2 + 1]);
        s += @as(f64, side) * @as(f64, side);
    }
    return @floatCast(@sqrt(s / @as(f64, @floatFromInt(frames))));
}

const WidthFixture = struct {
    gpa: std.mem.Allocator,
    project: model.Project = .{},
    asset_cache: mixer.AssetCache,
    samples: []f32,

    fn init(gpa: std.mem.Allocator) !WidthFixture {
        const samples = try makeStereoTone(gpa, 300, 500, 0.35);
        var self: WidthFixture = .{
            .gpa = gpa,
            .asset_cache = mixer.AssetCache.init(gpa),
            .samples = samples,
        };
        const aid: model.AssetId = 9101;
        try self.project.assets.append(gpa, .{
            .id = aid,
            .relative_path = try gpa.dupe(u8, "synthetic-width"),
            .sample_rate = SAMPLE_RATE,
            .channels = 2,
            .frame_count = N,
        });
        try self.asset_cache.put(aid, .{ .samples = self.samples, .channels = 2, .frame_count = N });
        const tr = try self.project.addTrack(gpa, "StereoStem");
        try tr.clips.append(gpa, .{ .audio = .{ .id = model.allocId(), .source_id = aid, .timeline_start_frame = 0 } });
        self.project.sample_rate = SAMPLE_RATE;
        return self;
    }

    fn deinit(self: *WidthFixture) void {
        self.project.deinit(self.gpa);
        self.asset_cache.deinit();
        self.gpa.free(self.samples);
    }

    fn addMasterWidth(self: *WidthFixture, p: model.StereoWidthParams) !model.EffectId {
        const id = model.allocId();
        try self.project.master_effects.append(self.gpa, .{ .id = id, .params = .{ .stereo_width = p } });
        return id;
    }
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("=== 1 width 1.0 transparent ===\n", .{});
    {
        const in = try makeStereoTone(gpa, 440, 660, 0.3);
        defer gpa.free(in);
        const out = try gpa.alloc(f32, in.len);
        defer gpa.free(out);
        applyWidthOffline(in, out, 1.0, 1.0, 150, false);
        var max_err: f32 = 0;
        for (in, out) |a, b| max_err = @max(max_err, @abs(a - b));
        if (max_err > 1e-5) return error.NotTransparent;
    }

    std.debug.print("=== 2 width 0.0 mono ===\n", .{});
    {
        const in = try makeStereoTone(gpa, 440, 660, 0.3);
        defer gpa.free(in);
        const out = try gpa.alloc(f32, in.len);
        defer gpa.free(out);
        applyWidthOffline(in, out, 0.0, 0.0, 150, false);
        for (0..N) |i| {
            if (@abs(out[i * 2] - out[i * 2 + 1]) > 1e-5) return error.NotMono;
        }
    }

    std.debug.print("=== 3-4 widen increases side; mid stable ===\n", .{});
    {
        const in = try makeStereoTone(gpa, 400, 700, 0.25);
        defer gpa.free(in);
        const out = try gpa.alloc(f32, in.len);
        defer gpa.free(out);
        applyWidthOffline(in, out, 1.0, 1.4, 150, false);
        if (sideRms(out) <= sideRms(in) * 1.05) return error.SideDidNotIncrease;
        if (@abs(db(midRms(out)) - db(midRms(in))) > 0.05) return error.MidChanged;
    }

    std.debug.print("=== 5 mono source invariant ===\n", .{});
    {
        const in = try makeStereoTone(gpa, 500, 500, 0.3);
        defer gpa.free(in);
        const out = try gpa.alloc(f32, in.len);
        defer gpa.free(out);
        applyWidthOffline(in, out, 1.0, 1.8, 150, false);
        var max_err: f32 = 0;
        for (in, out) |a, b| max_err = @max(max_err, @abs(a - b));
        if (max_err > 1e-4) return error.MonoSourceChanged;
    }

    std.debug.print("=== 6-9 anti-phase + deterministic metrics ===\n", .{});
    {
        const buf = try gpa.alloc(f32, N * 2);
        defer gpa.free(buf);
        for (0..N) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
            const s = 0.4 * @sin(2.0 * std.math.pi * 300.0 * t);
            buf[i * 2] = s;
            buf[i * 2 + 1] = -s;
        }
        const a = stereo_analysis.analyzeStereo(buf, SAMPLE_RATE);
        const b = stereo_analysis.analyzeStereo(buf, SAMPLE_RATE);
        if (@abs(a.correlation_mean - b.correlation_mean) > 1e-6) return error.CorrNondeterministic;
        if (@abs(a.side_to_mid_db - b.side_to_mid_db) > 1e-6) return error.SideNondeterministic;
        if (a.anti_phase_sample_ratio < 0.9) return error.AntiPhaseNotDetected;
        if (a.mono_loss_db < 6.0) return error.MonoLossTooSmall;
    }

    std.debug.print("=== 10-11 crossover low/high separation ===\n", .{});
    {
        const in = try gpa.alloc(f32, N * 2);
        defer gpa.free(in);
        for (0..N) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
            // Low is mono (no side); high is decorrelated — widening high must not invent low side.
            const low = 0.35 * @sin(2.0 * std.math.pi * 80.0 * t);
            const hi_l = 0.2 * @sin(2.0 * std.math.pi * 4000.0 * t);
            const hi_r = 0.2 * @sin(2.0 * std.math.pi * 4500.0 * t);
            in[i * 2] = low + hi_l;
            in[i * 2 + 1] = low + hi_r;
        }
        const out_hi = try gpa.alloc(f32, in.len);
        defer gpa.free(out_hi);
        applyWidthOffline(in, out_hi, 1.0, 1.5, 150, true);
        // High-band open: overall side rises
        if (sideRms(out_hi) <= sideRms(in) * 1.05) return error.HighNotPreferred;
        // Low protection: LPF of mid/side at crossover — low side stays near zero (mono low)
        var lm = stereo_analysis.WidthOnePole.initLpf(150, @floatFromInt(SAMPLE_RATE));
        var ls = stereo_analysis.WidthOnePole.initLpf(150, @floatFromInt(SAMPLE_RATE));
        var low_side_sum: f64 = 0;
        for (0..N) |i| {
            const mid = 0.5 * (out_hi[i * 2] + out_hi[i * 2 + 1]);
            const side = 0.5 * (out_hi[i * 2] - out_hi[i * 2 + 1]);
            _ = lm.process(mid);
            const low_s = ls.process(side);
            low_side_sum += @as(f64, low_s) * @as(f64, low_s);
        }
        const low_side_rms = @sqrt(low_side_sum / @as(f64, @floatFromInt(N)));
        if (low_side_rms > 0.02) return error.LowBandNotProtected;
    }

    std.debug.print("=== 12 TP finite after widen ===\n", .{});
    {
        const in = try makeStereoTone(gpa, 1000, 1200, 0.55);
        defer gpa.free(in);
        const out = try gpa.alloc(f32, in.len);
        defer gpa.free(out);
        applyWidthOffline(in, out, 1.0, 1.8, 150, false);
        if (!std.math.isFinite(loudness.truePeakDbtp(out))) return error.TpNotFinite;
    }

    std.debug.print("=== 13-15 assess needs_human / rollback / commit ===\n", .{});
    {
        var fx = try WidthFixture.init(gpa);
        defer fx.deinit();
        const eid = try fx.addMasterWidth(.{ .mode = .crossover, .crossover_hz = 150, .low_width = 1.0, .high_width = 1.0 });

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

        const nh = try std.fmt.allocPrint(gpa, "{{\"id\":1,\"cmd\":\"stereo_width_assess_and_adjust\",\"args\":{{\"target\":{{\"kind\":\"master\"}},\"effect_id\":{d},\"param\":\"high_width\",\"value\":1.15,\"start_frame\":2000,\"length_frames\":20000,\"auto_commit\":false,\"constraints\":{{\"max_correlation\":0.999,\"min_correlation\":-1.0,\"max_mono_loss_db\":12,\"max_true_peak_dbtp\":6,\"max_side_gain_db\":12,\"max_low_band_side_delta_db\":12,\"max_anti_phase_sample_ratio\":1.0}}}}}}", .{eid});
        defer gpa.free(nh);
        const nh_resp = app.handleCommand(&ctx, nh, &resp);
        if (std.mem.indexOf(u8, nh_resp, "needs_human_listening") == null) {
            std.debug.print("{s}\n", .{nh_resp[0..@min(nh_resp.len, 500)]});
            return error.ExpectedNeedsHuman;
        }
        fx.project.master_effects.items[0].params.stereo_width.high_width = 1.0;
        fx.project.revision += 1;
        mix_gate.revision = fx.project.revision;

        const rb = try std.fmt.allocPrint(gpa, "{{\"id\":2,\"cmd\":\"stereo_width_assess_and_adjust\",\"args\":{{\"target\":{{\"kind\":\"master\"}},\"effect_id\":{d},\"param\":\"high_width\",\"value\":1.9,\"start_frame\":2000,\"length_frames\":20000,\"auto_commit\":true,\"constraints\":{{\"max_correlation\":0.999,\"min_correlation\":-1.0,\"max_mono_loss_db\":0.01,\"max_true_peak_dbtp\":-40,\"max_side_gain_db\":12,\"max_low_band_side_delta_db\":12,\"max_anti_phase_sample_ratio\":1.0}}}}}}", .{eid});
        defer gpa.free(rb);
        const rb_resp = app.handleCommand(&ctx, rb, &resp);
        if (std.mem.indexOf(u8, rb_resp, "rolled_back") == null) {
            std.debug.print("{s}\n", .{rb_resp[0..@min(rb_resp.len, 500)]});
            return error.ExpectedRollback;
        }
        if (@abs(fx.project.master_effects.items[0].params.stereo_width.high_width - 1.0) > 0.001) return error.RollbackDidNotRestore;
        mix_gate.revision = fx.project.revision;

        const cm = try std.fmt.allocPrint(gpa, "{{\"id\":3,\"cmd\":\"stereo_width_assess_and_adjust\",\"args\":{{\"target\":{{\"kind\":\"master\"}},\"effect_id\":{d},\"param\":\"high_width\",\"value\":1.15,\"start_frame\":2000,\"length_frames\":20000,\"auto_commit\":true,\"constraints\":{{\"max_correlation\":0.999,\"min_correlation\":-1.0,\"max_mono_loss_db\":12,\"max_true_peak_dbtp\":6,\"max_side_gain_db\":12,\"max_low_band_side_delta_db\":12,\"max_anti_phase_sample_ratio\":1.0}}}}}}", .{eid});
        defer gpa.free(cm);
        const cm_resp = app.handleCommand(&ctx, cm, &resp);
        if (std.mem.indexOf(u8, cm_resp, "\"decision\":\"committed\"") == null) {
            std.debug.print("{s}\n", .{cm_resp[0..@min(cm_resp.len, 500)]});
            return error.ExpectedCommit;
        }
        if (@abs(fx.project.master_effects.items[0].params.stereo_width.high_width - 1.15) > 0.001) return error.CommitDidNotKeep;
        if (std.mem.indexOf(u8, nh_resp, "before_audition_path") == null) return error.MissingAB;
    }

    std.debug.print("=== 16-17 same-scope compare labeling ===\n", .{});
    {
        const a = try makeStereoTone(gpa, 440, 550, 0.2);
        defer gpa.free(a);
        const ma = stereo_analysis.analyzeProgramBuffer(a, SAMPLE_RATE, .full_program, 0);
        const short = stereo_analysis.analyzeProgramBuffer(a[0 .. 4410 * 2], SAMPLE_RATE, .measure_window, 0);
        if (ma.analysis_scope != .full_program) return error.ScopeMismatch;
        if (short.analysis_scope != .measure_window) return error.WindowScopeWrong;
    }

    std.debug.print("ALL PASS: stereo width DSP + M/S observe + assess decisions\n", .{});
}
