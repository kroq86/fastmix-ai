const std = @import("std");
const model = @import("model.zig");

/// Process-local professional-trial scaffold.
/// Shape: begin → (caller mutates via normal cmds) → resolve →
///   committed | rolled_back | needs_human_listening
/// then confirm_trial / reject_trial when human listening was required.
///
/// Rollback restores the ProjectDto captured at begin_trial — not History.undo —
/// so multi-step mutations inside a trial still revert cleanly. History stack
/// may still contain intermediate entries after a trial rollback (documented).

pub const Decision = enum {
    committed,
    rolled_back,
    needs_human_listening,
    conflict,
};

pub const Phase = enum {
    open,
    awaiting_human,
};

pub const Stats = struct {
    peak_dbfs: f32 = -120,
    rms_dbfs: f32 = -120,
    band_energy_db: [8]f32 = [_]f32{-120} ** 8,
    preroll_frames: u64 = 0,
};

pub const Constraints = struct {
    max_peak_dbfs: ?f32 = null,
    max_rms_change_db: ?f32 = null,
    /// Optional: require band_energy_db[i] delta magnitude / signed direction.
    min_band_energy_delta_db: ?f32 = null,
    spectral_band_index: ?usize = null,
    expect_band_energy_up: ?bool = null,
    require_human_listening: bool = false,
};

pub const Trial = struct {
    id: u64,
    track_id: ?model.TrackId,
    start_frame: u64,
    length_frames: u64,
    revision_before: u64,
    phase: Phase = .open,
    snapshot: model.ProjectDto,
    before: Stats,
    before_path: [256]u8 = undefined,
    before_path_len: usize = 0,

    pub fn beforePath(self: *const Trial) []const u8 {
        return self.before_path[0..self.before_path_len];
    }

    pub fn deinit(self: *Trial, gpa: std.mem.Allocator) void {
        model.freeProjectDto(gpa, &self.snapshot);
    }
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    next_id: u64 = 1,
    active: ?Trial = null,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        if (self.active) |*t| t.deinit(self.gpa);
        self.active = null;
    }

    pub fn hasActive(self: *const Registry) bool {
        return self.active != null;
    }

    pub fn begin(
        self: *Registry,
        project: *const model.Project,
        track_id: ?model.TrackId,
        start_frame: u64,
        length_frames: u64,
        before: Stats,
        before_path: []const u8,
    ) !u64 {
        if (self.active != null) return error.TrialAlreadyOpen;
        if (before_path.len >= 256) return error.PathTooLong;
        const snap = try model.toDto(self.gpa, project);
        errdefer model.freeProjectDto(self.gpa, &snap);
        var t: Trial = .{
            .id = self.next_id,
            .track_id = track_id,
            .start_frame = start_frame,
            .length_frames = length_frames,
            .revision_before = project.revision,
            .snapshot = snap,
            .before = before,
        };
        @memcpy(t.before_path[0..before_path.len], before_path);
        t.before_path_len = before_path.len;
        self.next_id += 1;
        self.active = t;
        return t.id;
    }

    pub fn get(self: *Registry, id: u64) ?*Trial {
        if (self.active) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    pub fn restoreSnapshot(self: *Registry, project: *model.Project) !void {
        const t = if (self.active) |*tr| tr else return error.NoActiveTrial;
        project.deinit(self.gpa);
        project.* = try model.fromDto(self.gpa, t.snapshot);
    }

    pub fn close(self: *Registry) void {
        if (self.active) |*t| t.deinit(self.gpa);
        self.active = null;
    }

    pub fn markAwaitingHuman(self: *Registry) !void {
        const t = if (self.active) |*tr| tr else return error.NoActiveTrial;
        t.phase = .awaiting_human;
    }

    /// Evaluate objective constraints only. Does not decide human listening.
    pub fn objectivesOk(before: Stats, after: Stats, c: Constraints) struct { ok: bool, detail: []const u8 } {
        if (c.max_peak_dbfs) |lim| {
            if (after.peak_dbfs > lim) return .{ .ok = false, .detail = "peak_exceeds_max_peak_dbfs" };
        }
        if (c.max_rms_change_db) |lim| {
            if (@abs(after.rms_dbfs - before.rms_dbfs) > lim) return .{ .ok = false, .detail = "rms_change_exceeds_max" };
        }
        if (c.min_band_energy_delta_db) |min_d| {
            const idx = c.spectral_band_index orelse return .{ .ok = false, .detail = "missing_spectral_band_index" };
            if (idx >= before.band_energy_db.len) return .{ .ok = false, .detail = "spectral_band_index_out_of_range" };
            const delta = after.band_energy_db[idx] - before.band_energy_db[idx];
            if (c.expect_band_energy_up) |up| {
                if (up and delta < min_d) return .{ .ok = false, .detail = "band_energy_did_not_rise_enough" };
                if (!up and delta > -min_d) return .{ .ok = false, .detail = "band_energy_did_not_fall_enough" };
            } else {
                if (@abs(delta) < min_d) return .{ .ok = false, .detail = "band_energy_delta_too_small" };
            }
        }
        return .{ .ok = true, .detail = "objectives_ok" };
    }

    /// Gain (dB) to apply to *after* so its RMS matches *before* (level-matched A/B helper).
    pub fn levelMatchGainDb(before_rms: f32, after_rms: f32) f32 {
        return before_rms - after_rms;
    }
};

/// Pick Decision from objective result + require_human flag.
pub fn decide(objectives_ok: bool, require_human: bool) Decision {
    if (!objectives_ok) return .rolled_back;
    if (require_human) return .needs_human_listening;
    return .committed;
}

test "decide three outcomes" {
    try std.testing.expect(decide(false, false) == .rolled_back);
    try std.testing.expect(decide(false, true) == .rolled_back);
    try std.testing.expect(decide(true, true) == .needs_human_listening);
    try std.testing.expect(decide(true, false) == .committed);
}

test "objectives peak" {
    const before: Stats = .{ .peak_dbfs = -6, .rms_dbfs = -12 };
    const after_ok: Stats = .{ .peak_dbfs = -1, .rms_dbfs = -11 };
    const after_clip: Stats = .{ .peak_dbfs = 1, .rms_dbfs = -11 };
    const c: Constraints = .{ .max_peak_dbfs = 0 };
    try std.testing.expect(Registry.objectivesOk(before, after_ok, c).ok);
    try std.testing.expect(!Registry.objectivesOk(before, after_clip, c).ok);
}
