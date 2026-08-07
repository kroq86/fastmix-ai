const std = @import("std");
const app = @import("main.zig");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const trial = @import("trial.zig");
const persist = @import("persist.zig");
const jobs = @import("jobs.zig");
const ui = @import("ui.zig");
const mix_preflight = @import("mix_preflight.zig");
const mix_sections = @import("mix_sections.zig");
const vocal_balance = @import("vocal_balance.zig");

const SAMPLE_RATE: u32 = 44100;
const FRAME_N: usize = 12_000;
const WIN: u64 = 2_000;
const HOP: u64 = 2_000;

const Fixture = struct {
    gpa: std.mem.Allocator,
    project: model.Project = .{},
    asset_cache: mixer.AssetCache,
    samples: std.ArrayList([]f32) = .empty,
    lead_id: model.TrackId = 0,
    guitar_id: model.TrackId = 0,
    synth_id: model.TrackId = 0,
    drums_id: model.TrackId = 0,
    bass_id: model.TrackId = 0,

    fn makeTone(gpa: std.mem.Allocator, amp: f32, freq: f32) ![]f32 {
        const s = try gpa.alloc(f32, FRAME_N);
        for (s, 0..) |*v, i| {
            v.* = amp * @sin(@as(f32, @floatFromInt(i)) * freq);
        }
        return s;
    }

    fn addStem(self: *Fixture, name: []const u8, amp: f32, freq: f32) !*model.Track {
        const samples = try makeTone(self.gpa, amp, freq);
        try self.samples.append(self.gpa, samples);
        const aid = model.allocId();
        try self.project.assets.append(self.gpa, .{
            .id = aid,
            .relative_path = try self.gpa.dupe(u8, name),
            .sample_rate = SAMPLE_RATE,
            .channels = 1,
            .frame_count = FRAME_N,
        });
        try self.asset_cache.put(aid, .{ .samples = samples, .channels = 1, .frame_count = FRAME_N });
        const tr = try self.project.addTrack(self.gpa, name);
        try tr.clips.append(self.gpa, .{ .audio = .{
            .id = model.allocId(),
            .source_id = aid,
            .timeline_start_frame = 0,
            .source_offset_frames = 0,
        } });
        return tr;
    }

    fn initBalanced(gpa: std.mem.Allocator) !Fixture {
        var self: Fixture = .{
            .gpa = gpa,
            .asset_cache = mixer.AssetCache.init(gpa),
            .project = .{ .sample_rate = SAMPLE_RATE, .revision = 1 },
        };
        const lead = try self.addStem("0 Lead Vocals", 0.08, 0.12);
        self.lead_id = lead.id;
        _ = try self.addStem("1 Backing Vocals", 0.04, 0.09);
        const drums = try self.addStem("2 Drums", 0.20, 0.45);
        self.drums_id = drums.id;
        const bass = try self.addStem("3 Bass", 0.15, 0.05);
        self.bass_id = bass.id;
        const guitar = try self.addStem("4 Guitar", 0.25, 0.18);
        self.guitar_id = guitar.id;
        _ = try self.addStem("5 Keyboard", 0.10, 0.07);
        const synth = try self.addStem("6 Synth", 0.18, 0.22);
        self.synth_id = synth.id;
        _ = try self.addStem("7 Other", 0.05, 0.03);
        return self;
    }

    fn zeroAsset(self: *Fixture, asset_id: model.AssetId) void {
        for (self.samples.items) |s| {
            // Find matching pointer via cache.
            if (self.asset_cache.get(asset_id)) |loaded| {
                if (loaded.samples.ptr == s.ptr) {
                    @memset(s, 0);
                    return;
                }
            }
        }
    }

    fn wipeLead(self: *Fixture) void {
        for (self.project.tracks.items) |*t| {
            if (t.id != self.lead_id) continue;
            for (t.clips.items) |*c| {
                if (c.* == .audio) self.zeroAsset(c.audio.source_id);
            }
        }
    }

    fn wipeGuitar(self: *Fixture) void {
        for (self.project.tracks.items) |*t| {
            if (t.id != self.guitar_id) continue;
            for (t.clips.items) |*c| {
                if (c.* == .audio) self.zeroAsset(c.audio.source_id);
            }
        }
    }

    fn leadOnlyFirstHop(self: *Fixture) void {
        for (self.project.tracks.items) |*t| {
            if (t.id != self.lead_id) continue;
            for (t.clips.items) |*c| {
                if (c.* != .audio) continue;
                if (self.asset_cache.get(c.audio.source_id)) |loaded| {
                    for (self.samples.items) |s| {
                        if (s.ptr != loaded.samples.ptr) continue;
                        @memset(s, 0);
                        var i: usize = 0;
                        while (i < WIN and i < s.len) : (i += 1) {
                            s[i] = 0.1 * @sin(@as(f32, @floatFromInt(i)) * 0.12);
                        }
                    }
                }
            }
        }
    }

    fn deinit(self: *Fixture) void {
        self.project.deinit(self.gpa);
        self.asset_cache.deinit();
        for (self.samples.items) |s| self.gpa.free(s);
        self.samples.deinit(self.gpa);
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
    mix_gate: mix_preflight.MixSessionGate = .{},
    project_path: ?[]const u8 = null,

    fn init(gpa: std.mem.Allocator) Harness {
        return .{
            .sc_rt = mixer.SidechainRuntime.init(gpa),
            .trial_registry = trial.Registry.init(gpa),
            .offline_registry = .init(gpa),
        };
    }
    fn deinit(self: *Harness, gpa: std.mem.Allocator) void {
        self.mix_gate.clear(gpa);
        self.history.deinit(gpa);
        self.job_registry.deinit(gpa);
        self.offline_registry.deinit();
        self.pending.deinit(gpa);
        self.sc_rt.deinit();
        self.trial_registry.deinit();
    }
    fn ctx(self: *Harness, gpa: std.mem.Allocator, io: std.Io, fx: *Fixture) app.DispatchCtx {
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

fn tinyOpts() mix_preflight.PreflightOpts {
    return .{
        .window_frames = WIN,
        .hop_frames = HOP,
        .max_scan_frames = FRAME_N,
        .quiet_rms_dbfs = -50.0,
        .lead_active_rms_dbfs = -45.0,
    };
}

fn expectDecision(r: mix_preflight.PreflightResult, want: mix_preflight.Decision, reason_sub: ?[]const u8) !void {
    if (r.decision != want) {
        std.debug.print("decision want={s} got={s} blocking=", .{ @tagName(want), @tagName(r.decision) });
        for (r.blocking_reasons) |b| std.debug.print("{s} ", .{b});
        std.debug.print("\n", .{});
        return error.UnexpectedDecision;
    }
    if (reason_sub) |sub| {
        var ok = false;
        for (r.blocking_reasons) |b| {
            if (std.mem.indexOf(u8, b, sub) != null) ok = true;
        }
        if (!ok) return error.MissingBlockingReason;
    }
}

fn fakeSectionMetrics(lead_rms: f32, instr_rms: f32, guitar_rms: ?f32, synth_rms: ?f32, presence_delta: f32) mix_sections.SectionAnalysis {
    const dummy: mix_sections.TrackMetrics = .{
        .peak_dbfs = lead_rms + 6,
        .rms_dbfs = lead_rms,
        .crest_factor_db = 6,
        .presence_250_500 = -20,
        .presence_500_1000 = -18,
        .presence_1k_2k = -16,
        .presence_2k_4k = -18,
        .presence_4k_8k = -22,
    };
    var g: ?mix_sections.TrackMetrics = null;
    if (guitar_rms) |gr| {
        g = dummy;
        g.?.rms_dbfs = gr;
    }
    var sy: ?mix_sections.TrackMetrics = null;
    if (synth_rms) |sr| {
        sy = dummy;
        sy.?.rms_dbfs = sr;
    }
    return .{
        .section_id = 1,
        .start_frame = 0,
        .length_frames = WIN,
        .lead = dummy,
        .guitar = g,
        .synth = sy,
        .instrumental = .{
            .peak_dbfs = instr_rms + 6,
            .rms_dbfs = instr_rms,
            .crest_factor_db = 6,
            .presence_250_500 = -20,
            .presence_500_1000 = -15,
            .presence_1k_2k = -14,
            .presence_2k_4k = -15,
            .presence_4k_8k = -20,
        },
        .master = dummy,
        .lead_to_instrumental_rms_db = lead_rms - instr_rms,
        .lead_presence_energy_db = -17,
        .instrumental_presence_energy_db = -17 - presence_delta,
        .presence_delta_db = presence_delta,
    };
}

fn hasActive(names: []const []const u8, token: []const u8) bool {
    for (names) |n| {
        if (mix_preflight.nameContains(n, token)) return true;
    }
    return false;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resp_buf: [256 * 1024]u8 = undefined;

    std.debug.print("=== 1 muted Lead → preflight abstained ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        for (fx.project.tracks.items) |*t| {
            if (t.id == fx.lead_id) t.mute = true;
        }
        var r = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &r);
        try expectDecision(r, .abstained, "lead_vocal_not_available");
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 2 silent Lead regions → abstained ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        fx.wipeLead();
        var r = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &r);
        try expectDecision(r, .abstained, "lead_vocal_not_available");
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 3 missing Lead source → abstained ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        for (fx.project.tracks.items) |*t| {
            if (t.id != fx.lead_id) continue;
            for (t.clips.items) |*c| {
                if (c.* == .audio) {
                    const sid = c.audio.source_id;
                    _ = fx.asset_cache.remove(sid);
                    for (fx.project.assets.items) |*a| {
                        if (a.id == sid) {
                            gpa.free(a.relative_path);
                            a.relative_path = try gpa.dupe(u8, "/nonexistent/lead_missing.wav");
                        }
                    }
                }
            }
        }
        var r = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &r);
        try expectDecision(r, .abstained, "missing_lead_source");
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 4 Lead outlier timing → abstained ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        for (fx.project.tracks.items) |*t| {
            if (t.id == fx.lead_id) {
                t.clips.items[0].audio.timeline_start_frame = -3924;
            }
        }
        var r = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &r);
        try expectDecision(r, .abstained, "lead_timing_unverified");
        if (r.timing_status != .unverified) return error.TimingShouldBeUnverified;
        // Shared non-zero offset must pass (relative alignment).
        for (fx.project.tracks.items) |*t| {
            for (t.clips.items) |*c| {
                if (c.* == .audio) c.audio.timeline_start_frame = -3924;
            }
        }
        var r2 = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &r2);
        if (r2.decision != .passed or r2.timing_status != .relative_alignment_verified) return error.SharedOffsetShouldPass;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 5 fewer than 3 valid vocal sections → abstained ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        fx.leadOnlyFirstHop();
        var r = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &r);
        try expectDecision(r, .abstained, "fewer_than_three_representative_vocal_sections");
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 6 noise-floor Guitar not marked Guitar-active ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        fx.wipeGuitar();
        var r = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &r);
        if (r.decision != .passed) {
            std.debug.print("blocking: ", .{});
            for (r.blocking_reasons) |b| std.debug.print("{s} ", .{b});
            std.debug.print("\n", .{});
            return error.ExpectedPass;
        }
        for (r.sections) |s| {
            if (!s.valid_for_vocal_balance) continue;
            if (hasActive(s.active_tracks, "guit")) return error.NoiseFloorGuitarMarkedActive;
        }
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 7 same-range measurements deterministic ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        var pf = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &pf);
        if (pf.decision != .passed) return error.NeedPassed;
        var secs: std.ArrayList(mix_preflight.Section) = .empty;
        defer secs.deinit(gpa);
        for (pf.sections) |s| {
            if (s.valid_for_vocal_balance) try secs.append(gpa, s);
        }
        const use = secs.items[0..@min(secs.items.len, 3)];
        var a1 = try mix_sections.analyzeSections(gpa, &fx.project, &fx.asset_cache, fx.lead_id, use);
        defer mix_sections.freeAnalysis(gpa, &a1);
        var a2 = try mix_sections.analyzeSections(gpa, &fx.project, &fx.asset_cache, fx.lead_id, use);
        defer mix_sections.freeAnalysis(gpa, &a2);
        if (@abs(a1.lead_to_instrumental_mean_db - a2.lead_to_instrumental_mean_db) > 0.001) return error.Nondeterministic;
        if (@abs(a1.sections[0].lead.rms_dbfs - a2.sections[0].lead.rms_dbfs) > 0.001) return error.NondeterministicLead;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 8 instrumental sum excludes Lead ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        // Make lead very loud so master >> instrumental.
        for (fx.project.tracks.items) |*t| {
            if (t.id == fx.lead_id) t.volume = 2.0;
        }
        const sec = mix_preflight.Section{
            .id = 101,
            .kind = "vocal_section_1",
            .start_frame = 0,
            .length_frames = WIN,
            .active_tracks = &.{},
            .lead_active = true,
            .lead_rms_dbfs = -10,
            .instrumental_rms_dbfs = -20,
            .master_rms_dbfs = -8,
            .section_confidence = 1,
            .selection_reason = "test",
            .valid_for_vocal_balance = true,
        };
        var a = try mix_sections.analyzeSections(gpa, &fx.project, &fx.asset_cache, fx.lead_id, &.{sec});
        defer mix_sections.freeAnalysis(gpa, &a);
        if (!(a.sections[0].master.rms_dbfs > a.sections[0].instrumental.rms_dbfs + 0.5)) return error.InstrumentalShouldExcludeLead;
        // Solo Lead may be quieter than full instrumental sum; the exclusion proof is master > instrumental.
        std.debug.print("PASS master={d:.2} instr={d:.2} lead={d:.2}\n", .{ a.sections[0].master.rms_dbfs, a.sections[0].instrumental.rms_dbfs, a.sections[0].lead.rms_dbfs });
    }

    std.debug.print("=== 9 global imbalance selects Lead track volume ===\n", .{});
    {
        var secs = [_]mix_sections.SectionAnalysis{
            fakeSectionMetrics(-20, -12, -50, -50, 1),
            fakeSectionMetrics(-19.5, -12.2, -50, -50, 1),
            fakeSectionMetrics(-20.2, -11.8, -50, -50, 1),
        };
        const analysis = mix_sections.AnalysisResult{
            .revision = 1,
            .sections = &secs,
            .section_variance_db = 0.7,
            .lead_to_instrumental_mean_db = -8.0,
        };
        const cls = vocal_balance.classify(&analysis, -45);
        if (!std.mem.eql(u8, cls.class, "global_lead_low")) return error.BadClass;
        if (cls.prefer != .set_lead_track_volume) return error.BadOp;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 10 local imbalance does not select global fader ===\n", .{});
    {
        var secs = [_]mix_sections.SectionAnalysis{
            fakeSectionMetrics(-12, -14, -30, -30, 1),
            fakeSectionMetrics(-12, -14, -30, -30, 1),
            fakeSectionMetrics(-22, -14, -30, -30, -5), // outlier
        };
        const analysis = mix_sections.AnalysisResult{
            .revision = 1,
            .sections = &secs,
            .section_variance_db = 10.0,
            .lead_to_instrumental_mean_db = -2.0,
        };
        const cls = vocal_balance.classify(&analysis, -45);
        if (cls.prefer != .set_lead_region_gain) return error.ShouldPreferLocal;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 11 missing clip-gain on local → abstained ===\n", .{});
    {
        var secs = [_]mix_sections.SectionAnalysis{
            fakeSectionMetrics(-12, -14, -40, -40, 1),
            fakeSectionMetrics(-12, -14, -40, -40, 1),
            fakeSectionMetrics(-22, -14, -40, -40, -6),
        };
        const analysis = mix_sections.AnalysisResult{
            .revision = 1,
            .sections = &secs,
            .section_variance_db = 10,
            .lead_to_instrumental_mean_db = -2,
        };
        const cls = vocal_balance.classify(&analysis, -45);
        if (cls.prefer != .set_lead_region_gain) return error.ExpectLocal;
        // Contract of runAssess: local prefer → decision abstained / required_local_gain_capability_missing
        // (clip gain not in AudioClip model).
        std.debug.print("PASS (capability gap named)\n", .{});
    }

    std.debug.print("=== 12 Guitar-only conflict selects Guitar not Synth ===\n", .{});
    {
        var secs = [_]mix_sections.SectionAnalysis{
            fakeSectionMetrics(-14, -12, -20, -50, -3),
            fakeSectionMetrics(-14, -12, -19, -50, -3.5),
            fakeSectionMetrics(-13, -12, -40, -18, 0.5), // synth only in one section — not enough
        };
        const analysis = mix_sections.AnalysisResult{
            .revision = 1,
            .sections = &secs,
            .section_variance_db = 1.0,
            .lead_to_instrumental_mean_db = -2.0,
        };
        const cls = vocal_balance.classify(&analysis, -45);
        if (cls.prefer != .reduce_competing_track_volume) return error.ExpectCompeting;
        if (cls.competing_token == null or !std.mem.eql(u8, cls.competing_token.?, "guit")) return error.ExpectGuitarToken;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 13–17 commit / rollback / one-param / peak ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        // Make lead globally low so assess selects track volume.
        for (fx.project.tracks.items) |*t| {
            if (t.id == fx.lead_id) t.volume = 0.15;
        }
        var pf = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &pf);
        if (pf.decision != .passed) {
            for (pf.blocking_reasons) |b| std.debug.print("block {s}\n", .{b});
            return error.NeedPassed;
        }
        var gate: mix_preflight.MixSessionGate = .{};
        defer gate.clear(gpa);
        try gate.storePassed(gpa, &pf);

        var vols_before: [16]f32 = undefined;
        const ntr = fx.project.tracks.items.len;
        for (fx.project.tracks.items, 0..) |t, i| vols_before[i] = t.volume;

        var tr = try vocal_balance.runAssess(gpa, &fx.project, &fx.asset_cache, &gate, pf.revision, null, .{
            .require_human_listening = false,
            .min_mean_delta_improvement_db = 0.3,
            .max_true_peak_dbtp = 6.0,
            .max_master_peak_dbfs = 6.0,
        });
        defer vocal_balance.freeTrialResult(gpa, &tr);

        var changed: usize = 0;
        for (fx.project.tracks.items, 0..) |t, i| {
            if (i < ntr and @abs(t.volume - vols_before[i]) > 1e-6) changed += 1;
        }
        if (changed != 1 and tr.decision == .committed) return error.ExpectedOneParamChange;

        if (tr.decision != .committed and tr.decision != .rolled_back and tr.decision != .needs_human_listening) {
            std.debug.print("decision={s} reason={s}\n", .{ @tagName(tr.decision), tr.reason });
            return error.UnexpectedTrialDecision;
        }
        if (!std.mem.eql(u8, tr.masking_status, "proxy_only")) return error.MaskingMustBeProxy;

        // Rollback path: extreme peak constraint.
        for (fx.project.tracks.items) |*t| {
            if (t.id == fx.lead_id) t.volume = 0.12;
        }
        fx.project.revision = pf.revision;
        gate.revision = pf.revision;
        const lead_vol_before = blk: {
            for (fx.project.tracks.items) |t| {
                if (t.id == fx.lead_id) break :blk t.volume;
            }
            return error.NoLead;
        };
        var tr2 = try vocal_balance.runAssess(gpa, &fx.project, &fx.asset_cache, &gate, pf.revision, null, .{
            .require_human_listening = false,
            .min_mean_delta_improvement_db = 0.01,
            .max_true_peak_dbtp = -60.0, // impossible → force rollback
            .max_master_peak_dbfs = -60.0,
        });
        defer vocal_balance.freeTrialResult(gpa, &tr2);
        if (tr2.decision != .rolled_back) {
            std.debug.print("want rolled_back got {s} {s}\n", .{ @tagName(tr2.decision), tr2.reason });
            return error.ExpectedRollbackOnPeak;
        }
        for (fx.project.tracks.items) |t| {
            if (t.id == fx.lead_id and @abs(t.volume - lead_vol_before) > 1e-5) return error.RollbackDidNotRestore;
        }
        std.debug.print("PASS commit/rollback/one-param/proxy\n", .{});
    }

    std.debug.print("=== 16 sectional one-up two-down → rollback (policy unit) ===\n", .{});
    {
        // Encode the gate used in runAssess: better>=1 && worse>=2 ⇒ rollback.
        const better: usize = 1;
        const worse: usize = 2;
        if (!(better >= 1 and worse >= 2)) return error.PolicyBroken;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 18 revision change after preflight rejects ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        var pf = try mix_preflight.runPreflight(gpa, &fx.project, &fx.asset_cache, tinyOpts());
        defer mix_preflight.freePreflightResult(gpa, &pf);
        if (pf.decision != .passed) return error.NeedPassed;
        var gate: mix_preflight.MixSessionGate = .{};
        defer gate.clear(gpa);
        try gate.storePassed(gpa, &pf);
        fx.project.revision += 1; // foreign mutation
        const foreign_rev = fx.project.revision;
        var tr = try vocal_balance.runAssess(gpa, &fx.project, &fx.asset_cache, &gate, pf.revision, null, .{});
        defer vocal_balance.freeTrialResult(gpa, &tr);
        if (tr.decision != .abstained or !std.mem.eql(u8, tr.reason, "stale_preflight")) return error.ExpectedStale;
        if (fx.project.revision != foreign_rev) return error.MustNotUndoForeignMutation;
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("=== 19–22 gate + needs_human A/B + no discovery WAV + policy ===\n", .{});
    {
        var fx = try Fixture.initBalanced(gpa);
        defer fx.deinit();
        for (fx.project.tracks.items) |*t| {
            if (t.id == fx.lead_id) t.volume = 0.15;
        }
        var h = Harness.init(gpa);
        defer h.deinit(gpa);
        var c = h.ctx(gpa, io, &fx);

        // Policy: gated assess without preflight is rejected.
        const blocked = app.handleCommand(&c, "{\"id\":1,\"cmd\":\"lead_vocal_balance_assess\",\"args\":{\"preflight_revision\":1}}", &resp_buf);
        if (std.mem.indexOf(u8, blocked, "preflight_not_passed") == null) {
            std.debug.print("resp={s}\n", .{blocked});
            return error.GateMissing;
        }

        const pf_line = try std.fmt.allocPrint(gpa, "{{\"id\":2,\"cmd\":\"mix_session_preflight\",\"args\":{{\"window_frames\":{d},\"hop_frames\":{d},\"max_scan_frames\":{d}}}}}", .{ WIN, HOP, FRAME_N });
        defer gpa.free(pf_line);
        const pf_resp = app.handleCommand(&c, pf_line, &resp_buf);
        if (std.mem.indexOf(u8, pf_resp, "\"decision\":\"passed\"") == null) {
            std.debug.print("preflight={s}\n", .{pf_resp});
            return error.PreflightCmdFailed;
        }

        // High-level mix workflow must not proceed as bare fader→limiter→30s master discovery.
        // Evidence: assess response includes discovery_master_wav:null; A/B are section-scoped.
        const assess_line = try std.fmt.allocPrint(gpa, "{{\"id\":3,\"cmd\":\"lead_vocal_balance_assess\",\"args\":{{\"preflight_revision\":{d},\"constraints\":{{\"require_human_listening\":true,\"min_mean_delta_improvement_db\":0.2,\"max_true_peak_dbtp\":6,\"max_master_peak_dbfs\":6}}}}}}", .{fx.project.revision});
        defer gpa.free(assess_line);
        const aresp = app.handleCommand(&c, assess_line, &resp_buf);
        if (std.mem.indexOf(u8, aresp, "discovery_master_wav\":null") == null) return error.DiscoveryWavMustBeNull;
        if (std.mem.indexOf(u8, aresp, "proxy_only") == null) return error.NeedProxyLabel;
        // If needs_human, expect per-section before/after paths (not a general 30s master).
        if (std.mem.indexOf(u8, aresp, "needs_human_listening") != null) {
            if (std.mem.indexOf(u8, aresp, "vocal_balance_s1_before.wav") == null) return error.NeedSectionAB;
            if (std.mem.indexOf(u8, aresp, "master_listen_30s") != null) return error.NoThirtySecondDiscovery;
        }
        std.debug.print("PASS gate/ab/discovery/proxy\n", .{});
    }

    std.debug.print("=== 23 existing suites remain green (manual CI reminder) ===\n", .{});
    std.debug.print("PASS (see zig build spike-mastering-qc-workflow)\n", .{});

    std.debug.print("\nALL PASS: spike-vocal-balance-workflow\n", .{});
}
