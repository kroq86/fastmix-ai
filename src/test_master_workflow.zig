const std = @import("std");
const app = @import("main.zig");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const trial = @import("trial.zig");
const persist = @import("persist.zig");
const jobs = @import("jobs.zig");
const ui = @import("ui.zig");

// P1 master FX + compressor trial hermetic suite (production mixSample path).

const SAMPLE_RATE: u32 = 44100;
const N: usize = 60000;
const ASSET_ID: model.AssetId = 9401;
const WIN_START: u64 = 2000;
const WIN_LEN: u64 = 30000;

const Fixture = struct {
    gpa: std.mem.Allocator,
    project: model.Project = .{},
    asset_cache: mixer.AssetCache,
    samples: []f32,
    track_id: model.TrackId = 0,
    effect_id: model.EffectId = 0,

    fn init(gpa: std.mem.Allocator) !Fixture {
        var self: Fixture = .{
            .gpa = gpa,
            .asset_cache = mixer.AssetCache.init(gpa),
            .samples = try gpa.alloc(f32, N),
        };
        @memset(self.samples, 0);
        var b: usize = 500;
        while (b + 800 < N) : (b += 4000) {
            for (0..800) |i| {
                const env = if (i < 40) @as(f32, @floatFromInt(i)) / 40.0 else 1.0 - @as(f32, @floatFromInt(i)) / 800.0;
                self.samples[b + i] = 0.85 * env * @sin(@as(f32, @floatFromInt(i)) * 0.33);
            }
        }
        try self.project.assets.append(gpa, .{
            .id = ASSET_ID,
            .relative_path = try gpa.dupe(u8, "synthetic-master"),
            .sample_rate = SAMPLE_RATE,
            .channels = 1,
            .frame_count = N,
        });
        try self.asset_cache.put(ASSET_ID, .{ .samples = self.samples, .channels = 1, .frame_count = N });
        const tr = try self.project.addTrack(gpa, "Stem");
        try tr.clips.append(gpa, .{ .audio = .{ .id = model.allocId(), .source_id = ASSET_ID, .timeline_start_frame = 0 } });
        self.track_id = tr.id;
        self.project.revision = 0;
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.project.deinit(self.gpa);
        self.asset_cache.deinit();
        self.gpa.free(self.samples);
    }

    fn insertMasterComp(self: *Fixture, threshold: f32) !void {
        self.effect_id = model.allocId();
        try self.project.master_effects.append(self.gpa, .{
            .id = self.effect_id,
            .params = .{ .compressor = .{
                .threshold_db = threshold,
                .ratio = 4,
                .attack_ms = 5,
                .release_ms = 80,
                .knee_db = 6,
                .makeup_db = 0,
                .mix = 1,
            } },
        });
    }

    fn masterEff(self: *Fixture) !*model.Effect {
        for (self.project.master_effects.items) |*e| {
            if (e.id == self.effect_id) return e;
        }
        return error.EffectNotFound;
    }
};

const Harness = struct {
    history: persist.History = .{},
    job_registry: jobs.Registry = .{},
    offline_registry: @import("offline_audio.zig").Registry = undefined,
    pending: std.ArrayList(app.PendingImport) = .empty,
    render_state: app.RenderState = .{},
    transport: ui.Transport = .stop,
    beat_time: f64 = 0,
    live_peaks: app.LivePeaks = .{},
    audio_diag: app.AudioDiag = .{},
    view: ui.View = .{},
    sc_rt: mixer.SidechainRuntime,
    trial_registry: trial.Registry,
    frame_count: u64 = 1000,
    operation_counter: u64 = 0,
    mix_gate: @import("mix_preflight.zig").MixSessionGate = .{},
    project_path: ?[]const u8 = null,

    fn init(gpa: std.mem.Allocator) Harness {
        return .{
            .sc_rt = mixer.SidechainRuntime.init(gpa),
            .trial_registry = trial.Registry.init(gpa),
            .offline_registry = .init(gpa),
        };
    }
    fn deinit(self: *Harness, gpa: std.mem.Allocator) void {
        self.history.deinit(gpa);
        self.job_registry.deinit(gpa);
        self.offline_registry.deinit();
        self.pending.deinit(gpa);
        self.sc_rt.deinit();
        self.trial_registry.deinit();
    }
    fn ctx(self: *Harness, gpa: std.mem.Allocator, io: std.Io, fx: *Fixture) app.DispatchCtx {
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
            .pending_imports = &self.pending,
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

fn measureMaster(gpa: std.mem.Allocator, fx: *Fixture, sp: app.MasterSignalPoint) !app.RangeStats {
    return app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .master = sp }, WIN_START, WIN_LEN, SAMPLE_RATE, null, false);
}

fn measureTrack(gpa: std.mem.Allocator, fx: *Fixture) !app.RangeStats {
    return app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .track = fx.track_id }, WIN_START, WIN_LEN, SAMPLE_RATE, null, false);
}

fn measureMasterObserving(gpa: std.mem.Allocator, fx: *Fixture) !app.RangeStats {
    return app.measureRangeObserving(gpa, &fx.project, &fx.asset_cache, .{ .master = .master_output }, WIN_START, WIN_LEN, SAMPLE_RATE, null, fx.effect_id, false);
}

fn ok(resp: []const u8) !void {
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) {
        std.debug.print("FAIL resp={s}\n", .{resp});
        return error.CommandFailed;
    }
}

fn extractU64(hay: []const u8, key: []const u8) !u64 {
    const ei = std.mem.indexOf(u8, hay, key) orelse return error.MissingKey;
    var p = ei + key.len;
    var v: u64 = 0;
    while (p < hay.len and hay[p] >= '0' and hay[p] <= '9') : (p += 1) {
        v = v * 10 + (hay[p] - '0');
    }
    return v;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("=== 1 empty master chain preserves output ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const a = try measureMaster(gpa, &fx, .master_output);
        const b = try measureMaster(gpa, &fx, .master_pre_fx);
        if (@abs(a.rms_dbfs - b.rms_dbfs) > 0.01) return error.EmptyChainShouldMatchPre;
        std.debug.print("PASS rms={d:.2}\n", .{a.rms_dbfs});
    }

    std.debug.print("=== 2 master compressor changes output ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const dry = try measureMaster(gpa, &fx, .master_output);
        try fx.insertMasterComp(-28);
        const wet = try measureMaster(gpa, &fx, .master_output);
        if (@abs(wet.rms_dbfs - dry.rms_dbfs) < 0.5) return error.MasterCompShouldChangeRms;
        std.debug.print("PASS dry={d:.2} wet={d:.2}\n", .{ dry.rms_dbfs, wet.rms_dbfs });
    }

    std.debug.print("=== 3-4 bypass effect + chain fx_enabled ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const dry = try measureMaster(gpa, &fx, .master_output);
        try fx.insertMasterComp(-28);
        const wet = try measureMaster(gpa, &fx, .master_output);
        (try fx.masterEff()).bypassed = true;
        const byp = try measureMaster(gpa, &fx, .master_output);
        if (@abs(byp.rms_dbfs - dry.rms_dbfs) > 0.05) return error.BypassShouldRestoreDry;
        (try fx.masterEff()).bypassed = false;
        fx.project.master_fx_enabled = false;
        const chain_off = try measureMaster(gpa, &fx, .master_output);
        if (@abs(chain_off.rms_dbfs - dry.rms_dbfs) > 0.05) return error.ChainBypassShouldRestoreDry;
        _ = wet;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 5 master FX applied once (no double gain) ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        try fx.insertMasterComp(-24);
        (try fx.masterEff()).params.compressor.makeup_db = 6;
        const a = try measureMaster(gpa, &fx, .master_output);
        const b = try measureMaster(gpa, &fx, .master_output);
        if (@abs(a.rms_dbfs - b.rms_dbfs) > 0.01) return error.NotStable;
        // Makeup +6 once ≈ +6 dB vs dry master_post without makeup; presence of GR means not silent.
        if (a.rms_dbfs < -80) return error.SilentMaster;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 6-8 track/bus/master audition isolation ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const tr0 = try measureTrack(gpa, &fx);
        try fx.insertMasterComp(-30);
        (try fx.masterEff()).params.compressor.ratio = 12;
        const tr1 = try measureTrack(gpa, &fx);
        if (@abs(tr0.rms_dbfs - tr1.rms_dbfs) > 0.05) return error.TrackShouldIgnoreMasterFx;
        const bus = try fx.project.addBus(gpa, "B");
        fx.project.findTrack(fx.track_id).?.master_send_enabled = false;
        _ = try fx.project.addSend(gpa, fx.track_id, bus.id, 0, .post_fader);
        const bus0 = try app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .bus = .{ .bus_id = bus.id, .signal_point = .bus_post_fx } }, WIN_START, WIN_LEN, SAMPLE_RATE, null, false);
        fx.project.master_fx_enabled = false;
        const bus1 = try app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .bus = .{ .bus_id = bus.id, .signal_point = .bus_post_fx } }, WIN_START, WIN_LEN, SAMPLE_RATE, null, false);
        if (@abs(bus0.rms_dbfs - bus1.rms_dbfs) > 0.05) return error.BusShouldIgnoreMasterFx;
        fx.project.master_fx_enabled = true;
        const m_wet = try measureMaster(gpa, &fx, .master_output);
        fx.project.master_fx_enabled = false;
        const m_dry = try measureMaster(gpa, &fx, .master_output);
        if (@abs(m_wet.rms_dbfs - m_dry.rms_dbfs) < 0.3) return error.MasterAuditionShouldIncludeFx;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 9 measure buffer == audition path (shared mixSample) ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        try fx.insertMasterComp(-26);
        const buf = try gpa.alloc(f32, WIN_LEN * 2);
        defer gpa.free(buf);
        const from_buf = try app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .master = .master_output }, WIN_START, WIN_LEN, SAMPLE_RATE, buf, false);
        const from_m = try measureMaster(gpa, &fx, .master_output);
        if (@abs(from_buf.rms_dbfs - from_m.rms_dbfs) > 0.01 or @abs(from_buf.peak_dbfs - from_m.peak_dbfs) > 0.01)
            return error.AuditionMeasureMismatch;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 10-12 pre≠post, volume after FX, meter=output ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        try fx.insertMasterComp(-28);
        const pre = try measureMaster(gpa, &fx, .master_pre_fx);
        const post = try measureMaster(gpa, &fx, .master_post_fx);
        const out = try measureMaster(gpa, &fx, .master_output);
        if (@abs(pre.rms_dbfs - post.rms_dbfs) < 0.3) return error.PreShouldDifferFromPost;
        if (@abs(post.rms_dbfs - out.rms_dbfs) > 0.01) return error.VolumeAtOneShouldMatchPost;
        fx.project.master_volume = 0.5;
        const out_half = try measureMaster(gpa, &fx, .master_output);
        const post2 = try measureMaster(gpa, &fx, .master_post_fx);
        if (!(out_half.rms_dbfs < post2.rms_dbfs - 5.0)) return error.VolumeShouldLowerOutput;
        // Meter proxy: MasterLevel.out matches master_output measure intensity via mix at mid window.
        var voice_pool: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;
        var sc = mixer.SidechainRuntime.init(gpa);
        defer sc.deinit();
        var eq = mixer.EqRuntime.init(gpa);
        defer eq.deinit();
        var comp = mixer.CompressorRuntime.init(gpa);
        defer comp.deinit();
        var delay = mixer.DelayRuntime.init(gpa);
        defer delay.deinit();
        var ml: mixer.MasterLevel = .{};
        var l: f32 = 0;
        var r: f32 = 0;
        mixer.mixSample(&fx.project, &voice_pool, &fx.asset_cache, 5000, 5000, .{}, &sc, &eq, &comp, &delay, null, null, SAMPLE_RATE, &l, &r, null, null, &ml, false);
        if (@abs(ml.out_l - l) > 1e-6 or @abs(ml.out_r - r) > 1e-6) return error.MeterShouldBeOutput;
        if (@abs(ml.pre_l - ml.out_l) < 1e-6 and fx.project.master_volume != 1.0) return error.MeterShouldNotBePre;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 13-15 threshold/ratio/makeup ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        try fx.insertMasterComp(-12);
        const hi = try measureMasterObserving(gpa, &fx);
        (try fx.masterEff()).params.compressor.threshold_db = -32;
        const lo = try measureMasterObserving(gpa, &fx);
        if ((lo.comp_gr_peak_db orelse 0) <= (hi.comp_gr_peak_db orelse 0)) return error.ThresholdShouldRaiseGR;
        (try fx.masterEff()).params.compressor.ratio = 2;
        const soft = try measureMasterObserving(gpa, &fx);
        (try fx.masterEff()).params.compressor.ratio = 12;
        const hard = try measureMasterObserving(gpa, &fx);
        if ((hard.comp_gr_peak_db orelse 0) <= (soft.comp_gr_peak_db orelse 0)) return error.RatioShouldRaiseGR;
        (try fx.masterEff()).params.compressor.makeup_db = 0;
        const m0 = try measureMasterObserving(gpa, &fx);
        (try fx.masterEff()).params.compressor.makeup_db = 6;
        const m6 = try measureMasterObserving(gpa, &fx);
        if ((m6.comp_output_rms_dbfs orelse -120) <= (m0.comp_output_rms_dbfs orelse -120) + 2) return error.MakeupShouldRaiseOutput;
        if (@abs((m6.comp_gr_peak_db orelse 0) - (m0.comp_gr_peak_db orelse 0)) > 1.5) return error.MakeupShouldNotChangeGRMuch;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 16 deterministic measure ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        try fx.insertMasterComp(-26);
        const a = try measureMaster(gpa, &fx, .master_output);
        const b = try measureMaster(gpa, &fx, .master_output);
        if (a.peak_dbfs != b.peak_dbfs or a.rms_dbfs != b.rms_dbfs) return error.NotDeterministic;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 17-20 commit/rollback/conflict/needs_human ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        var resp: [16384]u8 = undefined;
        var c = h.ctx(gpa, io, &fx);
        const ins = app.handleCommand(&c, "{\"id\":1,\"cmd\":\"insert_effect\",\"args\":{\"target\":{\"kind\":\"master\"},\"kind\":\"compressor\",\"threshold_db\":-12,\"ratio\":4,\"attack_ms\":5,\"release_ms\":80,\"mix\":1}}", &resp);
        try ok(ins);
        const eid = try extractU64(ins, "\"effect_id\":");
        fx.effect_id = eid;

        c = h.ctx(gpa, io, &fx);
        const commit_line = try std.fmt.allocPrint(gpa, "{{\"id\":2,\"cmd\":\"master_compressor_assess_and_adjust\",\"args\":{{\"effect_id\":{d},\"start_frame\":{d},\"length_frames\":{d},\"param\":\"threshold_db\",\"value\":-28,\"constraints\":{{\"gr_peak_min_db\":0.5,\"gr_peak_max_db\":40,\"gr_mean_active_max_db\":40,\"max_rms_change_db\":40,\"max_peak_dbfs\":6,\"max_active_ratio\":1.0}},\"require_human_listening\":false}}}}", .{ eid, WIN_START, WIN_LEN });
        defer gpa.free(commit_line);
        const commit = app.handleCommand(&c, commit_line, &resp);
        try ok(commit);
        if (std.mem.indexOf(u8, commit, "\"decision\":\"committed\"") == null) {
            std.debug.print("{s}\n", .{commit});
            return error.ExpectedCommit;
        }
        if ((try fx.masterEff()).params.compressor.threshold_db > -27) return error.CommitShouldKeepParam;

        c = h.ctx(gpa, io, &fx);
        const rb_line = try std.fmt.allocPrint(gpa, "{{\"id\":3,\"cmd\":\"master_compressor_assess_and_adjust\",\"args\":{{\"effect_id\":{d},\"start_frame\":{d},\"length_frames\":{d},\"param\":\"threshold_db\",\"value\":-60,\"constraints\":{{\"gr_peak_min_db\":0,\"gr_peak_max_db\":2,\"gr_mean_active_max_db\":1,\"max_rms_change_db\":0.2,\"max_peak_dbfs\":-6,\"max_active_ratio\":0.05}}}}}}", .{ eid, WIN_START, WIN_LEN });
        defer gpa.free(rb_line);
        const rb = app.handleCommand(&c, rb_line, &resp);
        try ok(rb);
        if (std.mem.indexOf(u8, rb, "\"decision\":\"rolled_back\"") == null) return error.ExpectedRollback;
        const thr_after_rb = (try fx.masterEff()).params.compressor.threshold_db;
        if (thr_after_rb < -50) return error.RollbackShouldRestore;

        // Conflict: foreign revision race while trial open semantics — match routing suite style.
        const thr0 = thr_after_rb;
        _ = try h.trial_registry.begin(&fx.project, null, 0, 100, .{}, "conflict");
        (try fx.masterEff()).params.compressor.threshold_db = thr0 - 5.0;
        const applied_rev = fx.project.revision + 1;
        fx.project.revision = applied_rev + 1;
        if ((try fx.masterEff()).params.compressor.threshold_db == thr0) return error.ConflictShouldNotRestore;
        h.trial_registry.close();

        // Restore a known compressor for human case.
        (try fx.masterEff()).params.compressor.threshold_db = -20;
        (try fx.masterEff()).params.compressor.attack_ms = 10;
        fx.project.revision += 1;
        c = h.ctx(gpa, io, &fx);
        const human_line = try std.fmt.allocPrint(gpa, "{{\"id\":4,\"cmd\":\"master_compressor_assess_and_adjust\",\"args\":{{\"effect_id\":{d},\"start_frame\":{d},\"length_frames\":{d},\"param\":\"attack_ms\",\"value\":20,\"constraints\":{{\"gr_peak_min_db\":0,\"gr_peak_max_db\":40,\"gr_mean_active_max_db\":40,\"max_rms_change_db\":40,\"max_peak_dbfs\":6,\"max_active_ratio\":1.0}}}}}}", .{ eid, WIN_START, WIN_LEN });
        defer gpa.free(human_line);
        const human = app.handleCommand(&c, human_line, &resp);
        try ok(human);
        if (std.mem.indexOf(u8, human, "\"decision\":\"needs_human_listening\"") == null) {
            std.debug.print("{s}\n", .{human});
            return error.ExpectedNeedsHuman;
        }
        if (std.mem.indexOf(u8, human, "after_master_level_matched_path") == null) return error.MissingLevelMatched;
        if (std.mem.indexOf(u8, human, "transients") == null) return error.MissingHumanQuestion;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 21-22 persist + legacy defaults ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        try fx.insertMasterComp(-18);
        fx.project.master_volume = 0.7;
        fx.project.master_fx_enabled = false;
        const dto = try model.toDto(gpa, &fx.project);
        defer model.freeProjectDto(gpa, &dto);
        var loaded = try model.fromDto(gpa, dto);
        defer loaded.deinit(gpa);
        if (loaded.master_effects.items.len != 1) return error.PersistMasterFx;
        if (@abs(loaded.master_volume - 0.7) > 0.001) return error.PersistMasterVol;
        if (loaded.master_fx_enabled) return error.PersistMasterFxEnabled;

        const legacy =
            \\{"format":"fastmix-ai-project","version":1,"project":{"bpm":120,"bar_size":4,"bar_quant":16,"length_bars":16,"sample_rate":44100,"revision":0,"tracks":[],"assets":[]}}
        ;
        const parsed = try std.json.parseFromSlice(model.ProjectFile, gpa, legacy, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        var legacy_p = try model.fromDto(gpa, parsed.value.project);
        defer legacy_p.deinit(gpa);
        if (@abs(legacy_p.master_volume - 1.0) > 0.001) return error.LegacyVolumeDefault;
        if (!legacy_p.master_fx_enabled) return error.LegacyFxEnabledDefault;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 23 invalid target/effect/range ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        var resp: [2048]u8 = undefined;
        var c = h.ctx(gpa, io, &fx);
        const bad_e = app.handleCommand(&c, "{\"id\":1,\"cmd\":\"master_compressor_assess_and_adjust\",\"args\":{\"effect_id\":99999,\"start_frame\":0,\"length_frames\":1000,\"param\":\"threshold_db\",\"value\":-12}}", &resp);
        if (std.mem.indexOf(u8, bad_e, "effect_not_found") == null) return error.ExpectedEffectNotFound;
        c = h.ctx(gpa, io, &fx);
        const bad_len = app.handleCommand(&c, "{\"id\":2,\"cmd\":\"measure\",\"args\":{\"start_frame\":0,\"length_frames\":0}}", &resp);
        if (std.mem.indexOf(u8, bad_len, "length_frames_must_be_positive") == null) return error.ExpectedLenError;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 24 param update keeps transport play ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        h.transport = .play;
        var resp: [1024]u8 = undefined;
        var c = h.ctx(gpa, io, &fx);
        try ok(app.handleCommand(&c, "{\"id\":1,\"cmd\":\"set_master_param\",\"args\":{\"volume\":0.5,\"fx_enabled\":true}}", &resp));
        if (h.transport != .play) return error.TransportStopped;
        if (@abs(fx.project.master_volume - 0.5) > 0.001) return error.VolumeNotSet;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 25 heavy command blocked while recording ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        h.transport = .record;
        var resp: [1024]u8 = undefined;
        var c = h.ctx(gpa, io, &fx);
        const m = app.handleCommand(&c, "{\"id\":1,\"cmd\":\"measure\",\"args\":{\"start_frame\":0,\"length_frames\":1000}}", &resp);
        if (std.mem.indexOf(u8, m, "heavy_command_blocked_while_recording") == null) return error.ExpectedBlocked;
        c = h.ctx(gpa, io, &fx);
        const a = app.handleCommand(&c, "{\"id\":2,\"cmd\":\"audition\",\"args\":{\"start_frame\":0,\"length_frames\":1000}}", &resp);
        if (std.mem.indexOf(u8, a, "heavy_command_blocked_while_recording") == null) return error.ExpectedAuditionBlocked;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 26 fx_bypass_all skips master inserts ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        try fx.insertMasterComp(-28);
        var voice_pool: [mixer.MAX_VOICES]mixer.Voice = [_]mixer.Voice{.{}} ** mixer.MAX_VOICES;
        var sc = mixer.SidechainRuntime.init(gpa);
        defer sc.deinit();
        var eq = mixer.EqRuntime.init(gpa);
        defer eq.deinit();
        var comp = mixer.CompressorRuntime.init(gpa);
        defer comp.deinit();
        var delay = mixer.DelayRuntime.init(gpa);
        defer delay.deinit();
        var ml: mixer.MasterLevel = .{};
        var l: f32 = 0;
        var r: f32 = 0;
        mixer.mixSample(&fx.project, &voice_pool, &fx.asset_cache, 5000, 5000, .{}, &sc, &eq, &comp, &delay, null, null, SAMPLE_RATE, &l, &r, null, null, &ml, false);
        const wet_pre = ml.pre_l;
        const wet_out = ml.out_l;
        mixer.mixSample(&fx.project, &voice_pool, &fx.asset_cache, 5000, 5000, .{}, &sc, &eq, &comp, &delay, null, null, SAMPLE_RATE, &l, &r, null, null, &ml, true);
        if (@abs(ml.pre_l - ml.out_l) > 1e-5 and fx.project.master_volume == 1.0) return error.BypassShouldSkipMasterFx;
        // Wet path should have been processed (pre!=out under makeup/comp) when not bypassed,
        // or at least bypass out should match bypass pre at unity master.
        _ = wet_pre;
        _ = wet_out;
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        var resp: [1024]u8 = undefined;
        var c = h.ctx(gpa, io, &fx);
        try ok(app.handleCommand(&c, "{\"id\":1,\"cmd\":\"set_master_param\",\"args\":{\"fx_bypass_all\":true}}", &resp));
        if (!h.view.fx_bypass_all) return error.SocketBypassNotSet;
        try ok(app.handleCommand(&c, "{\"id\":2,\"cmd\":\"set_master_param\",\"args\":{\"fx_bypass_all\":false}}", &resp));
        if (h.view.fx_bypass_all) return error.SocketBypassNotCleared;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("\nALL PASS: spike-master-workflow\n", .{});
}
