//! In-process offline audio jobs (measure/audition/assess while playing).
//! Snapshot + thread — status is atomic; one job at a time.
const std = @import("std");
const model = @import("model.zig");
const mix_preflight = @import("mix_preflight.zig");

pub const JobId = u64;

pub const Kind = enum {
    measure,
    audition,
    compressor_assess,
    bus_compressor_assess,
    master_compressor_assess,
    analyze_master_program,
    validate_master_delivery,
    master_limiter_assess,
    mix_session_preflight,
    sidechain_assess,
    eq_assess,
    stereo_width_assess,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .measure => "measure",
            .audition => "audition",
            .compressor_assess => "compressor_assess_and_adjust",
            .bus_compressor_assess => "bus_compressor_assess_and_adjust",
            .master_compressor_assess => "master_compressor_assess_and_adjust",
            .analyze_master_program => "analyze_master_program",
            .validate_master_delivery => "validate_master_delivery",
            .master_limiter_assess => "master_limiter_assess_and_adjust",
            .mix_session_preflight => "mix_session_preflight",
            .sidechain_assess => "sidechain_assess_and_adjust",
            .eq_assess => "eq_assess_and_adjust",
            .stereo_width_assess => "stereo_width_assess_and_adjust",
        };
    }
};

pub const Status = enum(u8) { idle = 0, running = 1, succeeded = 2, failed = 3 };

/// How get_job should mutate the live project after a worker assess finishes.
pub const ApplyTarget = enum(u8) {
    none = 0,
    master_compressor = 1,
    track_compressor = 2,
    bus_compressor = 3,
    master_limiter = 4,
    track_sidechain = 5,
    track_eq = 6,
    track_stereo_width = 7,
    bus_stereo_width = 8,
    master_stereo_width = 9,
};

pub const Job = struct {
    id: JobId = 0,
    kind: Kind = .measure,
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.idle)),
    revision_at_start: u64 = 0,
    revision_at_compute: u64 = 0,
    result_json: ?[]u8 = null,
    err_msg: ?[]const u8 = null,
    measure_duration_ms: f64 = 0,
    audition_duration_ms: f64 = 0,
    level_match_duration_ms: f64 = 0,
    trial_duration_ms: f64 = 0,
    thread: ?std.Thread = null,

    // Assess apply intent (filled by worker; consumed on get_job).
    apply_target: ApplyTarget = .none,
    apply_effect_id: u64 = 0,
    apply_track_id: u64 = 0,
    apply_bus_id: u64 = 0,
    /// EQ only -- which band within the effect's `bands` list.
    apply_band_index: u16 = 0,
    apply_param: [64]u8 = undefined,
    apply_param_len: u8 = 0,
    /// For EQ's `band_type` param (a string, not a float), this holds the
    /// new type's `@intFromEnum(model.EqBandType)` instead of a real value --
    /// `applyOfflineAssessToLive` checks the param name to know which it is.
    apply_value: f32 = 0,
    /// trial.Decision as u8: committed=0 rolled_back=1 needs_human=2 conflict=3
    apply_decision: u8 = 0,

    /// A passed mix_session_preflight, computed by the worker on its project
    /// snapshot -- ownership transfers here (see enqueueOfflineMasterQc's
    /// Work.run) because the worker's own MixSessionGate is thread-local and
    /// gone once the thread returns. get_job moves this onto the live
    /// ctx.mix_gate (if the revision still matches) and clears it.
    pending_gate: ?mix_preflight.MixSessionGate = null,
};

pub const Registry = struct {
    next_id: JobId = 1,
    job: Job = .{},
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        if (self.job.thread) |th| th.join();
        if (self.job.result_json) |r| self.gpa.free(r);
        if (self.job.pending_gate) |*pg| pg.clear(self.gpa);
        self.job = .{};
    }

    /// Discards a leftover pending_gate before a new job overwrites the slot
    /// (a passed preflight that was never consumed via get_job).
    pub fn discardPendingGate(self: *Registry) void {
        if (self.job.pending_gate) |*pg| pg.clear(self.gpa);
        self.job.pending_gate = null;
    }

    pub fn busy(self: *Registry) bool {
        return self.job.status.load(.acquire) == @intFromEnum(Status.running);
    }

    pub fn peek(self: *Registry) *Job {
        return &self.job;
    }

    pub fn statusOf(self: *Registry) Status {
        return @enumFromInt(self.job.status.load(.acquire));
    }
};

pub fn cloneProject(gpa: std.mem.Allocator, src: *const model.Project) !model.Project {
    const dto = try model.toDto(gpa, src);
    defer model.freeProjectDto(gpa, &dto);
    return try model.fromDto(gpa, dto);
}

pub fn nowNs() i128 {
    const C = @cImport({
        @cInclude("time.h");
    });
    var ts: C.struct_timespec = undefined;
    if (C.clock_gettime(C.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
}
