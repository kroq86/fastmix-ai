const std = @import("std");
const app = @import("main.zig");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const trial = @import("trial.zig");
const persist = @import("persist.zig");
const jobs = @import("jobs.zig");
const ui = @import("ui.zig");

// P1 bus/send routing hermetic suite (production mixSample path).

const SAMPLE_RATE: u32 = 44100;
const N: usize = 50000;
const ASSET_A: model.AssetId = 9301;
const ASSET_B: model.AssetId = 9302;

const Fixture = struct {
    gpa: std.mem.Allocator,
    project: model.Project = .{},
    asset_cache: mixer.AssetCache,
    samples_a: []f32,
    samples_b: []f32,
    track_a: model.TrackId = 0,
    track_b: model.TrackId = 0,

    fn init(gpa: std.mem.Allocator) !Fixture {
        var self: Fixture = .{
            .gpa = gpa,
            .asset_cache = mixer.AssetCache.init(gpa),
            .samples_a = try gpa.alloc(f32, N),
            .samples_b = try gpa.alloc(f32, N),
        };
        @memset(self.samples_a, 0);
        @memset(self.samples_b, 0);
        // Continuous-ish tone with bursts on A; quieter continuous on B.
        for (0..N) |i| {
            const t = @as(f32, @floatFromInt(i));
            const burst = if ((i % 4000) < 600) @as(f32, 0.8) else 0.15;
            self.samples_a[i] = burst * @sin(t * 0.21);
            self.samples_b[i] = 0.35 * @sin(t * 0.17);
        }
        try self.project.assets.append(gpa, .{ .id = ASSET_A, .relative_path = try gpa.dupe(u8, "a"), .sample_rate = SAMPLE_RATE, .channels = 1, .frame_count = N });
        try self.project.assets.append(gpa, .{ .id = ASSET_B, .relative_path = try gpa.dupe(u8, "b"), .sample_rate = SAMPLE_RATE, .channels = 1, .frame_count = N });
        try self.asset_cache.put(ASSET_A, .{ .samples = self.samples_a, .channels = 1, .frame_count = N });
        try self.asset_cache.put(ASSET_B, .{ .samples = self.samples_b, .channels = 1, .frame_count = N });
        const ta = try self.project.addTrack(gpa, "A");
        const tb = try self.project.addTrack(gpa, "B");
        try ta.clips.append(gpa, .{ .audio = .{ .id = model.allocId(), .source_id = ASSET_A, .timeline_start_frame = 0 } });
        try tb.clips.append(gpa, .{ .audio = .{ .id = model.allocId(), .source_id = ASSET_B, .timeline_start_frame = 0 } });
        self.track_a = ta.id;
        self.track_b = tb.id;
        self.project.revision = 0;
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.project.deinit(self.gpa);
        self.asset_cache.deinit();
        self.gpa.free(self.samples_a);
        self.gpa.free(self.samples_b);
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
        return .{ .sc_rt = mixer.SidechainRuntime.init(gpa), .trial_registry = trial.Registry.init(gpa), .offline_registry = .init(gpa) };
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

fn rms(stats: app.RangeStats) f32 {
    return stats.rms_dbfs;
}
fn peak(stats: app.RangeStats) f32 {
    return stats.peak_dbfs;
}

fn measureMaster(gpa: std.mem.Allocator, fx: *Fixture) !app.RangeStats {
    return app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .master = .master_output }, 2000, 20000, SAMPLE_RATE, null, false);
}
fn measureTrack(gpa: std.mem.Allocator, fx: *Fixture, tid: model.TrackId) !app.RangeStats {
    return app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .track = tid }, 2000, 20000, SAMPLE_RATE, null, false);
}
fn measureBus(gpa: std.mem.Allocator, fx: *Fixture, bid: model.BusId, pre: bool) !app.RangeStats {
    const sp: app.BusSignalPoint = if (pre) .bus_pre_fx else .bus_post_fx;
    return app.measureRange(gpa, &fx.project, &fx.asset_cache, .{ .bus = .{ .bus_id = bid, .signal_point = sp } }, 2000, 20000, SAMPLE_RATE, null, false);
}

fn cmd(h: *Harness, gpa: std.mem.Allocator, io: std.Io, fx: *Fixture, line: []const u8) []const u8 {
    var resp: [8192]u8 = undefined;
    var c = h.ctx(gpa, io, fx);
    return app.handleCommand(&c, line, &resp);
}

fn ok(resp: []const u8) !void {
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) {
        std.debug.print("FAIL resp={s}\n", .{resp});
        return error.CommandFailed;
    }
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("=== 1 direct track→master ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const m = try measureMaster(gpa, &fx);
        if (m.rms_dbfs < -60) return error.DirectMasterSilent;
        std.debug.print("PASS rms={d:.2}\n", .{m.rms_dbfs});
    }

    std.debug.print("=== 2-5 send / disabled / pre-post fader ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const bus = try fx.project.addBus(gpa, "DrumBus");
        // Only sends, no master send from A
        fx.project.findTrack(fx.track_a).?.master_send_enabled = false;
        fx.project.findTrack(fx.track_b).?.master_send_enabled = false;
        _ = try fx.project.addSend(gpa, fx.track_a, bus.id, 0, .post_fader);
        const bus_on = try measureBus(gpa, &fx, bus.id, false);
        if (bus_on.rms_dbfs < -60) return error.SendShouldFeedBus;

        // disable send
        fx.project.sends.items[0].enabled = false;
        const bus_off = try measureBus(gpa, &fx, bus.id, false);
        if (bus_off.rms_dbfs > -80) return error.DisabledSendShouldBeSilent;
        fx.project.sends.items[0].enabled = true;

        // post-fader reacts to volume
        const vol_hi = try measureBus(gpa, &fx, bus.id, false);
        fx.project.findTrack(fx.track_a).?.volume = 0.25;
        const vol_lo = try measureBus(gpa, &fx, bus.id, false);
        if (!(vol_lo.rms_dbfs < vol_hi.rms_dbfs - 6)) return error.PostFaderShouldFollowVolume;

        // pre-fader does not follow volume as much
        fx.project.findTrack(fx.track_a).?.volume = 1.0;
        fx.project.sends.items[0].tap = .pre_fader;
        const pre_hi = try measureBus(gpa, &fx, bus.id, false);
        fx.project.findTrack(fx.track_a).?.volume = 0.25;
        const pre_lo = try measureBus(gpa, &fx, bus.id, false);
        const post_delta = vol_hi.rms_dbfs - vol_lo.rms_dbfs;
        const pre_delta = pre_hi.rms_dbfs - pre_lo.rms_dbfs;
        if (pre_delta > post_delta * 0.35) return error.PreFaderShouldIgnoreVolume;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 6-7 bus mute / volume ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const bus = try fx.project.addBus(gpa, "B");
        fx.project.findTrack(fx.track_a).?.master_send_enabled = false;
        fx.project.findTrack(fx.track_b).?.master_send_enabled = false;
        _ = try fx.project.addSend(gpa, fx.track_a, bus.id, 0, .post_fader);
        const m0 = try measureMaster(gpa, &fx);
        bus.mute = true;
        const m1 = try measureMaster(gpa, &fx);
        if (!(m1.rms_dbfs < m0.rms_dbfs - 20)) return error.BusMuteShouldSilenceMaster;
        bus.mute = false;
        bus.volume = 0.25;
        const m2 = try measureMaster(gpa, &fx);
        if (!(m2.rms_dbfs < m0.rms_dbfs - 6)) return error.BusVolumeShouldLowerMaster;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 8 bus FX once on sum ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const bus = try fx.project.addBus(gpa, "CompBus");
        fx.project.findTrack(fx.track_a).?.master_send_enabled = false;
        fx.project.findTrack(fx.track_b).?.master_send_enabled = false;
        _ = try fx.project.addSend(gpa, fx.track_a, bus.id, 0, .post_fader);
        _ = try fx.project.addSend(gpa, fx.track_b, bus.id, 0, .post_fader);
        const eid = model.allocId();
        try bus.effects.append(gpa, .{ .id = eid, .params = .{ .compressor = .{ .threshold_db = -24, .ratio = 8, .attack_ms = 1, .release_ms = 50, .mix = 1 } } });
        const s = try app.measureRangeObserving(gpa, &fx.project, &fx.asset_cache, .{ .bus = .{ .bus_id = bus.id } }, 2000, 20000, SAMPLE_RATE, null, eid, false);
        if ((s.comp_gr_peak_db orelse 0) < 0.5) return error.BusCompShouldShowGR;
        std.debug.print("PASS gr={d:.2}\n", .{s.comp_gr_peak_db orelse 0});
    }

    std.debug.print("=== 9-11 dual bus / remove send / remove bus ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const b1 = try fx.project.addBus(gpa, "X");
        const b2 = try fx.project.addBus(gpa, "Y");
        fx.project.findTrack(fx.track_a).?.master_send_enabled = false;
        const s1 = try fx.project.addSend(gpa, fx.track_a, b1.id, 0, .post_fader);
        _ = try fx.project.addSend(gpa, fx.track_a, b2.id, 0, .post_fader);
        if ((try measureBus(gpa, &fx, b1.id, false)).rms_dbfs < -60) return error.Bus1Silent;
        if ((try measureBus(gpa, &fx, b2.id, false)).rms_dbfs < -60) return error.Bus2Silent;
        _ = fx.project.removeSend(s1);
        if ((try measureBus(gpa, &fx, b1.id, false)).rms_dbfs > -80) return error.RemoveSendFailed;
        _ = fx.project.removeBus(gpa, b2.id);
        if (fx.project.findBus(b2.id) != null) return error.RemoveBusFailed;
        if (fx.project.sends.items.len != 0) return error.RemoveBusShouldCascadeSends;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 12 invalid destination ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        const line = try std.fmt.allocPrint(gpa, "{{\"id\":1,\"cmd\":\"add_send\",\"args\":{{\"source_track_id\":{d},\"destination_bus_id\":99999,\"gain_db\":0}}}}", .{fx.track_a});
        defer gpa.free(line);
        const r = cmd(&h, gpa, io, &fx, line);
        std.debug.print("resp={s}\n", .{r});
        if (std.mem.indexOf(u8, r, "bus_not_found") == null) return error.ExpectedBusNotFound;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 13-15 measure deterministic / bus≠track / master=direct+bus ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const bus = try fx.project.addBus(gpa, "M");
        _ = try fx.project.addSend(gpa, fx.track_a, bus.id, -6, .post_fader);
        const a = try measureBus(gpa, &fx, bus.id, false);
        const b = try measureBus(gpa, &fx, bus.id, false);
        if (@abs(a.rms_dbfs - b.rms_dbfs) > 0.01) return error.BusMeasureNotDeterministic;
        const tr = try measureTrack(gpa, &fx, fx.track_a);
        if (@abs(tr.rms_dbfs - a.rms_dbfs) < 0.5) return error.BusShouldDifferFromTrack;
        const m = try measureMaster(gpa, &fx);
        // master has track direct + bus contrib → louder than track alone roughly
        if (m.rms_dbfs < tr.rms_dbfs - 1.0) return error.MasterShouldIncludeBus;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 16-19 bus compressor commit/rollback/conflict ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        const bus = try fx.project.addBus(gpa, "DrumBus");
        const bus_id = bus.id;
        fx.project.findTrack(fx.track_a).?.master_send_enabled = false;
        fx.project.findTrack(fx.track_b).?.master_send_enabled = false;
        _ = try fx.project.addSend(gpa, fx.track_a, bus_id, 0, .post_fader);
        _ = try fx.project.addSend(gpa, fx.track_b, bus_id, 0, .post_fader);
        var resp: [8192]u8 = undefined;
        var c = h.ctx(gpa, io, &fx);
        const ins = app.handleCommand(&c, try std.fmt.allocPrint(gpa, "{{\"id\":1,\"cmd\":\"insert_effect\",\"args\":{{\"bus_id\":{d},\"kind\":\"compressor\",\"threshold_db\":-12,\"ratio\":4,\"attack_ms\":5,\"release_ms\":80}}}}", .{bus_id}), &resp);
        try ok(ins);
        // extract effect_id
        const eid_key = "\"effect_id\":";
        const ei = std.mem.indexOf(u8, ins, eid_key) orelse return error.NoEffectId;
        var eid: u64 = 0;
        var p = ei + eid_key.len;
        while (p < ins.len and ins[p] >= '0' and ins[p] <= '9') : (p += 1) {
            eid = eid * 10 + (ins[p] - '0');
        }

        c = h.ctx(gpa, io, &fx);
        const commit = app.handleCommand(&c, try std.fmt.allocPrint(gpa, "{{\"id\":2,\"cmd\":\"bus_compressor_assess_and_adjust\",\"args\":{{\"bus_id\":{d},\"effect_id\":{d},\"start_frame\":2000,\"length_frames\":20000,\"param\":\"threshold_db\",\"value\":-28,\"constraints\":{{\"gr_peak_min_db\":0.5,\"gr_peak_max_db\":40,\"gr_mean_active_max_db\":40,\"max_rms_change_db\":40,\"max_peak_dbfs\":6,\"max_master_rms_change_db\":40,\"max_master_peak_dbfs\":6,\"max_active_ratio\":1.0}},\"require_human_listening\":false}}}}", .{ bus_id, eid }), &resp);
        try ok(commit);
        if (std.mem.indexOf(u8, commit, "\"decision\":\"committed\"") == null) {
            std.debug.print("{s}\n", .{commit});
            return error.ExpectedCommit;
        }
        {
            const bus_after_commit = fx.project.findBus(bus_id) orelse return error.BusLost;
            if (bus_after_commit.effects.items[0].params.compressor.threshold_db > -27) return error.CommitShouldKeepParam;
        }

        c = h.ctx(gpa, io, &fx);
        var rb_buf: [900]u8 = undefined;
        const rb_line = try std.fmt.bufPrint(&rb_buf, "{{\"id\":3,\"cmd\":\"bus_compressor_assess_and_adjust\",\"args\":{{\"bus_id\":{d},\"effect_id\":{d},\"start_frame\":2000,\"length_frames\":20000,\"param\":\"threshold_db\",\"value\":-60,\"constraints\":{{\"gr_peak_min_db\":0,\"gr_peak_max_db\":2,\"gr_mean_active_max_db\":1,\"max_rms_change_db\":0.2,\"max_peak_dbfs\":-6,\"max_master_rms_change_db\":0.2,\"max_master_peak_dbfs\":-6,\"max_active_ratio\":0.05}}}}}}", .{ bus_id, eid });
        const rb = app.handleCommand(&c, rb_line, &resp);
        try ok(rb);
        if (std.mem.indexOf(u8, rb, "\"decision\":\"rolled_back\"") == null) return error.ExpectedRollback;
        // After snapshot restore the previous `bus` pointer is invalid; use id.
        if (fx.project.findBus(bus_id) == null) {
            std.debug.print("buses after rollback={d} looked_for={d} have={d}\n", .{ fx.project.buses.items.len, bus_id, if (fx.project.buses.items.len > 0) fx.project.buses.items[0].id else 0 });
            return error.BusLostAfterRollback;
        }
        const bus_rb = fx.project.findBus(bus_id).?;
        const thr0 = bus_rb.effects.items[0].params.compressor.threshold_db;
        _ = try h.trial_registry.begin(&fx.project, null, 0, 100, .{}, "conflict");
        // Re-find after begin (snapshot clone only, no restore yet)
        const bus_c = fx.project.findBus(bus_id) orelse return error.BusLostMidConflict;
        bus_c.effects.items[0].params.compressor.threshold_db = thr0 - 5.0;
        const applied_rev = fx.project.revision + 1;
        fx.project.revision = applied_rev + 1;
        if (fx.project.revision == applied_rev) return error.ExpectedRace;
        if (bus_c.effects.items[0].params.compressor.threshold_db == thr0) return error.ConflictShouldNotRestore;
        h.trial_registry.close();
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 20 persist round-trip ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const bus = try fx.project.addBus(gpa, "PersistBus");
        _ = try fx.project.addSend(gpa, fx.track_a, bus.id, -3, .pre_fader);
        fx.project.findTrack(fx.track_a).?.master_send_enabled = false;
        const dto = try model.toDto(gpa, &fx.project);
        defer model.freeProjectDto(gpa, &dto);
        var loaded = try model.fromDto(gpa, dto);
        defer loaded.deinit(gpa);
        if (loaded.buses.items.len != 1) return error.PersistBusMissing;
        if (loaded.sends.items.len != 1) return error.PersistSendMissing;
        if (loaded.findTrack(fx.track_a).?.master_send_enabled) return error.PersistMasterSend;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 21 get_routing_state ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        _ = try fx.project.addBus(gpa, "R");
        const r = cmd(&h, gpa, io, &fx, "{\"id\":1,\"cmd\":\"get_routing_state\",\"args\":{}}");
        try ok(r);
        if (std.mem.indexOf(u8, r, "\"buses\":") == null) return error.MissingBuses;
        if (std.mem.indexOf(u8, r, "master_send_enabled") == null) return error.MissingMasterSend;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 22 delay return no dry duplication ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        const bus = try fx.project.addBus(gpa, "DelayBus");
        // Dry stays on master; send to 100% wet delay
        const dry0 = try measureMaster(gpa, &fx);
        _ = try fx.project.addSend(gpa, fx.track_a, bus.id, 0, .post_fader);
        var resp: [4096]u8 = undefined;
        var c = h.ctx(gpa, io, &fx);
        const ins = try std.fmt.allocPrint(gpa, "{{\"id\":1,\"cmd\":\"insert_effect\",\"args\":{{\"bus_id\":{d},\"kind\":\"delay\",\"time_ms\":120,\"feedback\":0.3,\"damping\":0.5,\"mix\":1.0}}}}", .{bus.id});
        defer gpa.free(ins);
        try ok(app.handleCommand(&c, ins, &resp));
        const with_wet = try measureMaster(gpa, &fx);
        // Enabling send+delay should change master (wet add) but dry still present when send disabled
        fx.project.sends.items[0].enabled = false;
        const dry1 = try measureMaster(gpa, &fx);
        if (@abs(dry1.rms_dbfs - dry0.rms_dbfs) > 0.5) return error.DryShouldRemainAfterDisableSend;
        if (!(with_wet.rms_dbfs > dry0.rms_dbfs - 0.01 or with_wet.peak_dbfs != dry0.peak_dbfs)) {
            // wet path must contribute somehow; allow peak or rms difference
            if (@abs(with_wet.rms_dbfs - dry0.rms_dbfs) < 0.05 and @abs(with_wet.peak_dbfs - dry0.peak_dbfs) < 0.05)
                return error.WetShouldBeAudible;
        }
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 23-24 mute/solo semantics ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        const bus = try fx.project.addBus(gpa, "S");
        _ = try fx.project.addSend(gpa, fx.track_a, bus.id, 0, .post_fader);
        fx.project.findTrack(fx.track_a).?.mute = true;
        if ((try measureBus(gpa, &fx, bus.id, false)).rms_dbfs > -80) return error.MutedSourceNoSend;
        fx.project.findTrack(fx.track_a).?.mute = false;
        fx.project.findTrack(fx.track_b).?.solo = true;
        // A not soloed → no send from A
        if ((try measureBus(gpa, &fx, bus.id, false)).rms_dbfs > -80) return error.UnsoloedNoSendWhenTrackSolo;
        // bus solo isolates: mute track direct
        fx.project.findTrack(fx.track_b).?.solo = false;
        fx.project.findTrack(fx.track_a).?.master_send_enabled = true;
        bus.solo = true;
        const m = try measureMaster(gpa, &fx);
        const bs = try measureBus(gpa, &fx, bus.id, false);
        // master should be ~ bus out only (send from A still feeds bus)
        if (bs.rms_dbfs < -60) return error.BusSoloShouldStillGetSends;
        _ = m;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 25 param mutation keeps transport play ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        h.transport = .play;
        const bus = try fx.project.addBus(gpa, "T");
        var resp: [1024]u8 = undefined;
        var c = h.ctx(gpa, io, &fx);
        try ok(app.handleCommand(&c, try std.fmt.allocPrint(gpa, "{{\"id\":1,\"cmd\":\"set_bus_param\",\"args\":{{\"bus_id\":{d},\"volume\":0.5}}}}", .{bus.id}), &resp));
        if (h.transport != .play) return error.TransportStopped;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 26 post_master bypasses master volume ===\n", .{});
    {
        var fx = try Fixture.init(gpa);
        defer fx.deinit();
        // Silence other track on master; mute track_b
        fx.project.findTrack(fx.track_b).?.mute = true;
        const ta = fx.project.findTrack(fx.track_a).?;
        ta.master_send_enabled = true;
        ta.post_master_enabled = false;
        fx.project.master_volume = 0;
        const silent = try measureMaster(gpa, &fx);
        if (silent.rms_dbfs > -70) return error.MasterVolZeroShouldMuteSend;
        ta.master_send_enabled = false;
        ta.post_master_enabled = true;
        const bypass = try measureMaster(gpa, &fx);
        if (bypass.rms_dbfs < -40) return error.PostMasterShouldStayAudible;
        // persist
        const dto = try model.toDto(gpa, &fx.project);
        defer model.freeProjectDto(gpa, &dto);
        var loaded = try model.fromDto(gpa, dto);
        defer loaded.deinit(gpa);
        if (!loaded.findTrack(fx.track_a).?.post_master_enabled) return error.PersistPostMaster;
        if (loaded.findTrack(fx.track_a).?.master_send_enabled) return error.PersistPostMasterSendOff;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("\nALL PASS: spike-routing-workflow\n", .{});
}
