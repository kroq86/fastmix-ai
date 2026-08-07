const std = @import("std");
const app = @import("main.zig");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const trial = @import("trial.zig");
const persist = @import("persist.zig");
const jobs = @import("jobs.zig");
const ui = @import("ui.zig");

// Professional-trial scaffold: begin → mutate → resolve →
// committed | rolled_back | needs_human_listening (+ confirm/reject).

const SAMPLE_RATE: u32 = 44100;
const N: usize = 40000;
const ASSET_ID: model.AssetId = 8101;

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
        for (0..N) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
            self.samples[i] = 0.25 * @sin(2.0 * std.math.pi * 440.0 * t);
        }
        try self.project.assets.append(gpa, .{
            .id = ASSET_ID,
            .relative_path = try gpa.dupe(u8, "synthetic-trial"),
            .sample_rate = SAMPLE_RATE,
            .channels = 1,
            .frame_count = N,
        });
        try self.asset_cache.put(ASSET_ID, .{ .samples = self.samples, .channels = 1, .frame_count = N });
        const tr = try self.project.addTrack(gpa, "Tone");
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
    frame_count: u64 = 0,
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

fn testCommitAndRollback(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== test: trial commit + objective rollback ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    var h = Harness.init(gpa);
    defer h.deinit(gpa);
    var ctx = h.ctx(gpa, io, &fx);

    var cmd: [512]u8 = undefined;
    var resp: [8192]u8 = undefined;

    const begin = try std.fmt.bufPrint(&cmd, "{{\"id\":1,\"cmd\":\"begin_trial\",\"args\":{{\"track_id\":{d},\"start_frame\":1000,\"length_frames\":10000}}}}", .{fx.track_id});
    const begin_resp = app.handleCommand(&ctx, begin, &resp);
    std.debug.print("begin: {s}\n", .{begin_resp});
    if (std.mem.indexOf(u8, begin_resp, "\"trial_id\":1") == null) return error.ExpectedTrialId1;

    // Soft volume change — should pass max_peak and modest max_rms_change.
    const track = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
    track.volume = 0.7;
    fx.project.revision += 1;

    const resolve_ok = try std.fmt.bufPrint(&cmd, "{{\"id\":2,\"cmd\":\"resolve_trial\",\"args\":{{\"trial_id\":1,\"max_peak_dbfs\":0,\"max_rms_change_db\":12}}}}", .{});
    const ok_resp = app.handleCommand(&ctx, resolve_ok, &resp);
    std.debug.print("resolve commit: {s}\n", .{ok_resp});
    if (std.mem.indexOf(u8, ok_resp, "\"decision\":\"committed\"") == null) return error.ExpectedCommit;
    if (!h.trial_registry.hasActive()) {} else return error.TrialShouldCloseOnCommit;

    // New trial for rollback: huge boost clips hard.
    const begin2 = try std.fmt.bufPrint(&cmd, "{{\"id\":3,\"cmd\":\"begin_trial\",\"args\":{{\"track_id\":{d},\"start_frame\":1000,\"length_frames\":10000}}}}", .{fx.track_id});
    _ = app.handleCommand(&ctx, begin2, &resp);
    const t2 = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
    const vol_before = t2.volume;
    t2.volume = 8.0;
    fx.project.revision += 1;

    const resolve_bad = try std.fmt.bufPrint(&cmd, "{{\"id\":4,\"cmd\":\"resolve_trial\",\"args\":{{\"trial_id\":2,\"max_peak_dbfs\":-1,\"max_rms_change_db\":40}}}}", .{});
    const bad_resp = app.handleCommand(&ctx, resolve_bad, &resp);
    std.debug.print("resolve rollback: {s}\n", .{bad_resp});
    if (std.mem.indexOf(u8, bad_resp, "\"decision\":\"rolled_back\"") == null) return error.ExpectedRollback;
    const t3 = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
    if (@abs(t3.volume - vol_before) > 0.001) return error.VolumeShouldRestore;

    std.debug.print("PASS\n\n", .{});
}

fn testNeedsHumanThenReject(gpa: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("=== test: needs_human_listening then reject_trial ===\n", .{});
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    var h = Harness.init(gpa);
    defer h.deinit(gpa);
    var ctx = h.ctx(gpa, io, &fx);

    var cmd: [512]u8 = undefined;
    var resp: [8192]u8 = undefined;

    const begin = try std.fmt.bufPrint(&cmd, "{{\"id\":1,\"cmd\":\"begin_trial\",\"args\":{{\"track_id\":{d},\"start_frame\":1000,\"length_frames\":10000}}}}", .{fx.track_id});
    _ = app.handleCommand(&ctx, begin, &resp);

    const track = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
    track.volume = 0.8;
    fx.project.revision += 1;

    const resolve = try std.fmt.bufPrint(&cmd, "{{\"id\":2,\"cmd\":\"resolve_trial\",\"args\":{{\"trial_id\":1,\"max_peak_dbfs\":0,\"max_rms_change_db\":12,\"require_human_listening\":true}}}}", .{});
    const r = app.handleCommand(&ctx, resolve, &resp);
    std.debug.print("resolve: {s}\n", .{r});
    if (std.mem.indexOf(u8, r, "\"decision\":\"needs_human_listening\"") == null) return error.ExpectedNeedsHuman;
    if (h.trial_registry.active) |*t| {
        if (t.phase != .awaiting_human) return error.ExpectedAwaitingHuman;
    } else return error.TrialShouldStayOpen;

    const reject = try std.fmt.bufPrint(&cmd, "{{\"id\":3,\"cmd\":\"reject_trial\",\"args\":{{\"trial_id\":1}}}}", .{});
    const rr = app.handleCommand(&ctx, reject, &resp);
    std.debug.print("reject: {s}\n", .{rr});
    if (std.mem.indexOf(u8, rr, "\"decision\":\"rolled_back\"") == null) return error.ExpectedRejectRollback;
    const t2 = fx.project.findTrack(fx.track_id) orelse return error.TrackNotFound;
    if (@abs(t2.volume - 1.0) > 0.001) return error.VolumeShouldRestoreToBaseline;

    std.debug.print("PASS\n\n", .{});
}

fn testUnitDecide() !void {
    std.debug.print("=== test: trial.decide matrix ===\n", .{});
    if (trial.decide(false, true) != .rolled_back) return error.Fail;
    if (trial.decide(true, true) != .needs_human_listening) return error.Fail;
    if (trial.decide(true, false) != .committed) return error.Fail;
    std.debug.print("PASS\n\n", .{});
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testUnitDecide();
    try testCommitAndRollback(gpa, io);
    try testNeedsHumanThenReject(gpa, io);

    std.debug.print("ALL PASS: professional trial scaffold\n", .{});
}
