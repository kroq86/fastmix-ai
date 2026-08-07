//! Bounded Lead vocal balance trial — one hypothesis, same-section before/after.
//! Does not claim intelligibility improvements.
const std = @import("std");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const master_qc = @import("master_qc.zig");
const mix_preflight = @import("mix_preflight.zig");
const mix_sections = @import("mix_sections.zig");

const libc = @cImport({
    @cInclude("sys/stat.h");
});

pub const Decision = enum { committed, rolled_back, needs_human_listening, abstained };

pub const OpKind = enum {
    set_lead_track_volume,
    set_lead_region_gain,
    reduce_competing_track_volume,
    reduce_competing_eq_band,
};

pub const CandidateOp = struct {
    kind: OpKind,
    track_id: model.TrackId,
    /// Absolute volume (0..1) or relative multiply depending on kind.
    value: f32,
    detail: []const u8,
};

pub const Constraints = struct {
    min_lead_to_instrumental_delta_db: f32 = -12,
    /// Required mean improvement (after - before) of lead_to_instrumental_rms_db.
    min_mean_delta_improvement_db: f32 = 0.5,
    max_section_variance_increase_db: f32 = 1.5,
    max_true_peak_dbtp: f32 = -0.1,
    max_master_peak_dbfs: f32 = -0.1,
    max_competing_rms_drop_db: f32 = 6.0,
    require_human_listening: bool = true,
};

pub const TrialResult = struct {
    decision: Decision,
    reason: []const u8,
    classification: []const u8,
    candidate: ?CandidateOp = null,
    before: ?mix_sections.AnalysisResult = null,
    after: ?mix_sections.AnalysisResult = null,
    ab_paths: [][]const u8 = &.{},
    masking_status: []const u8 = mix_sections.masking_status_label,
};

fn writeFloatWav(path: []const u8, interleaved: []const f32, sample_rate: u32) !void {
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const f = std.c.fopen(path_z.ptr, "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(f);
    const data_bytes: u32 = @intCast(interleaved.len * 4);
    const fmt_size: u32 = 16;
    const riff_size: u32 = 4 + (8 + fmt_size) + (8 + data_bytes);
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], riff_size, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], fmt_size, .little);
    std.mem.writeInt(u16, hdr[20..22], 3, .little); // IEEE float
    std.mem.writeInt(u16, hdr[22..24], 2, .little);
    std.mem.writeInt(u32, hdr[24..28], sample_rate, .little);
    std.mem.writeInt(u32, hdr[28..32], sample_rate * 2 * 4, .little);
    std.mem.writeInt(u16, hdr[32..34], 8, .little);
    std.mem.writeInt(u16, hdr[34..36], 32, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_bytes, .little);
    if (std.c.fwrite(&hdr, 1, hdr.len, f) != hdr.len) return error.ShortWrite;
    const bytes = std.mem.sliceAsBytes(interleaved);
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.ShortWrite;
}

fn levelMatchCopy(dst: []f32, src: []const f32, target_rms: f32) void {
    var sum: f64 = 0;
    for (src) |s| sum += @as(f64, s) * @as(f64, s);
    const rms = @sqrt(sum / @max(@as(f64, @floatFromInt(src.len)), 1));
    const gain: f32 = if (rms > 1e-12) target_rms / @as(f32, @floatCast(rms)) else 1;
    for (dst, src) |*d, s| d.* = s * gain;
}

fn rmsLin(buf: []const f32) f32 {
    var sum: f64 = 0;
    for (buf) |s| sum += @as(f64, s) * @as(f64, s);
    return @floatCast(@sqrt(sum / @max(@as(f64, @floatFromInt(buf.len)), 1)));
}

pub fn classify(
    analysis: *const mix_sections.AnalysisResult,
    guitar_active_threshold_db: f32,
) struct { class: []const u8, prefer: OpKind, competing_token: ?[]const u8 } {
    const mean = analysis.lead_to_instrumental_mean_db;
    const var_db = analysis.section_variance_db;
    // Local outlier: high variance
    if (var_db >= 4.0 and mean > -8.0) {
        return .{ .class = "phrase_local_imbalance", .prefer = .set_lead_region_gain, .competing_token = null };
    }
    // Competing guitar: sections where guitar presence high and presence_delta poor
    var guitar_conflict: usize = 0;
    var synth_conflict: usize = 0;
    for (analysis.sections) |s| {
        if (s.guitar) |g| {
            if (g.rms_dbfs > guitar_active_threshold_db and s.presence_delta_db < -2.0) guitar_conflict += 1;
        }
        if (s.synth) |sy| {
            if (sy.rms_dbfs > guitar_active_threshold_db and s.presence_delta_db < -2.0) synth_conflict += 1;
        }
    }
    if (guitar_conflict >= 2 and guitar_conflict >= synth_conflict) {
        return .{ .class = "competing_guitar_presence_proxy", .prefer = .reduce_competing_track_volume, .competing_token = "guit" };
    }
    if (synth_conflict >= 2) {
        return .{ .class = "competing_synth_presence_proxy", .prefer = .reduce_competing_track_volume, .competing_token = "synth" };
    }
    if (mean < -3.0 and var_db < 4.0) {
        return .{ .class = "global_lead_low", .prefer = .set_lead_track_volume, .competing_token = null };
    }
    return .{ .class = "unclear_or_balanced", .prefer = .set_lead_track_volume, .competing_token = null };
}

fn truePeakApprox(buf: []const f32) f32 {
    // Sample peak stand-in for constraint (TP approx = max abs).
    var peak: f32 = 0;
    for (buf) |s| {
        const a = @abs(s);
        if (a > peak) peak = a;
    }
    return 20.0 * std.math.log10(@max(peak, 1e-10));
}

pub fn runAssess(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    gate: *const mix_preflight.MixSessionGate,
    preflight_revision: u64,
    section_filter: ?[]const u64,
    constraints: Constraints,
) !TrialResult {
    if (gate.requirePassed(project.revision)) |err| {
        return .{ .decision = .abstained, .reason = err, .classification = "gate_blocked" };
    }
    if (preflight_revision != gate.revision or preflight_revision != project.revision) {
        return .{ .decision = .abstained, .reason = "stale_preflight", .classification = "gate_blocked" };
    }
    const lead_id = gate.lead_track_id orelse {
        return .{ .decision = .abstained, .reason = "lead_vocal_not_available", .classification = "gate_blocked" };
    };

    // Pick vocal-valid sections
    var secs: std.ArrayList(mix_preflight.Section) = .empty;
    defer secs.deinit(gpa);
    for (gate.sections) |s| {
        if (!s.valid_for_vocal_balance) continue;
        if (section_filter) |filt| {
            var ok = false;
            for (filt) |sid| {
                if (sid == s.id) ok = true;
            }
            if (!ok) continue;
        }
        try secs.append(gpa, s);
    }
    if (secs.items.len < 3) {
        return .{ .decision = .abstained, .reason = "fewer_than_three_representative_vocal_sections", .classification = "insufficient_sections" };
    }
    // Use first 3
    const use = secs.items[0..@min(secs.items.len, 3)];

    var before = try mix_sections.analyzeSections(gpa, project, asset_cache, lead_id, use);
    errdefer mix_sections.freeAnalysis(gpa, &before);

    const cls = classify(&before, -45);
    if (std.mem.eql(u8, cls.class, "unclear_or_balanced") and before.lead_to_instrumental_mean_db >= -3.0) {
        return .{
            .decision = .abstained,
            .reason = "no_clear_balance_hypothesis",
            .classification = cls.class,
            .before = before,
        };
    }
    if (cls.prefer == .set_lead_region_gain) {
        mix_sections.freeAnalysis(gpa, &before);
        return .{
            .decision = .abstained,
            .reason = "required_local_gain_capability_missing",
            .classification = cls.class,
        };
    }
    if (cls.prefer == .reduce_competing_eq_band) {
        mix_sections.freeAnalysis(gpa, &before);
        return .{
            .decision = .abstained,
            .reason = "required_eq_capability_not_selected",
            .classification = cls.class,
        };
    }

    var cand: CandidateOp = undefined;
    var old_volume: f32 = 1;
    var target_track: ?*model.Track = null;

    if (cls.prefer == .set_lead_track_volume) {
        for (project.tracks.items) |*t| {
            if (t.id == lead_id) {
                target_track = t;
                old_volume = t.volume;
                // +1.5 dB
                const new_v = @min(t.volume * 1.1885, 2.0);
                cand = .{
                    .kind = .set_lead_track_volume,
                    .track_id = lead_id,
                    .value = new_v,
                    .detail = "raise_lead_track_volume_+1.5dB",
                };
                break;
            }
        }
    } else if (cls.prefer == .reduce_competing_track_volume) {
        const token = cls.competing_token orelse "guit";
        for (project.tracks.items) |*t| {
            if (mix_preflight.nameContains(t.name, token)) {
                target_track = t;
                old_volume = t.volume;
                const new_v = t.volume * 0.8414; // -1.5 dB
                cand = .{
                    .kind = .reduce_competing_track_volume,
                    .track_id = t.id,
                    .value = new_v,
                    .detail = "reduce_competing_track_volume_-1.5dB",
                };
                break;
            }
        }
    }

    if (target_track == null) {
        mix_sections.freeAnalysis(gpa, &before);
        return .{ .decision = .abstained, .reason = "candidate_track_not_found", .classification = cls.class };
    }

    // Apply ONE mutation
    target_track.?.volume = cand.value;
    project.revision += 1;

    var after = try mix_sections.analyzeSections(gpa, project, asset_cache, lead_id, use);
    errdefer mix_sections.freeAnalysis(gpa, &after);

    // Constraint checks
    const improve = after.lead_to_instrumental_mean_db - before.lead_to_instrumental_mean_db;
    const var_increase = after.section_variance_db - before.section_variance_db;

    // Per-section degradation count
    var worse: usize = 0;
    var better: usize = 0;
    for (before.sections, after.sections) |b, a| {
        if (a.lead_to_instrumental_rms_db + 0.25 < b.lead_to_instrumental_rms_db) worse += 1;
        if (a.lead_to_instrumental_rms_db > b.lead_to_instrumental_rms_db + 0.25) better += 1;
    }

    // Master peak / TP on densest section
    var tp_viol = false;
    var peak_viol = false;
    for (use) |sec| {
        const buf = try master_qc.renderMasterRange(gpa, project, asset_cache, sec.start_frame, sec.length_frames);
        defer gpa.free(buf);
        const tp = truePeakApprox(buf);
        if (tp > constraints.max_true_peak_dbtp) tp_viol = true;
        // peak already in after.master
    }
    for (after.sections) |s| {
        if (s.master.peak_dbfs > constraints.max_master_peak_dbfs) peak_viol = true;
    }

    // Competing track drop
    var competing_drop_viol = false;
    if (cand.kind == .reduce_competing_track_volume) {
        for (before.sections, after.sections) |b, a| {
            const bb = if (mix_preflight.nameContains(cls.competing_token orelse "guit", "guit")) b.guitar else b.synth;
            const aa = if (mix_preflight.nameContains(cls.competing_token orelse "guit", "guit")) a.guitar else a.synth;
            if (bb != null and aa != null) {
                if (bb.?.rms_dbfs - aa.?.rms_dbfs > constraints.max_competing_rms_drop_db) competing_drop_viol = true;
            }
        }
    }

    const rollback = struct {
        fn go(track: *model.Track, old: f32, proj: *model.Project) void {
            track.volume = old;
            proj.revision += 1;
        }
    }.go;

    if (tp_viol or peak_viol or competing_drop_viol or var_increase > constraints.max_section_variance_increase_db or (better >= 1 and worse >= 2) or improve < constraints.min_mean_delta_improvement_db) {
        rollback(target_track.?, old_volume, project);
        mix_sections.freeAnalysis(gpa, &after);
        const reason: []const u8 = if (tp_viol or peak_viol)
            "rolled_back_peak_or_tp_constraint"
        else if (worse >= 2)
            "rolled_back_section_degradation"
        else if (competing_drop_viol)
            "rolled_back_competing_source_over_attenuated"
        else if (var_increase > constraints.max_section_variance_increase_db)
            "rolled_back_section_variance_increase"
        else
            "rolled_back_insufficient_mean_improvement";
        return .{
            .decision = .rolled_back,
            .reason = reason,
            .classification = cls.class,
            .candidate = cand,
            .before = before,
        };
    }

    // Success path: technical improve. Prefer needs_human_listening for intelligibility.
    if (constraints.require_human_listening) {
        _ = libc.mkdir(".cache", 0o755);
        _ = libc.mkdir(".cache/audition", 0o755);
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (paths.items) |p| gpa.free(p);
            paths.deinit(gpa);
        }
        for (use, 0..) |sec, i| {
            // before: temporarily restore old volume
            target_track.?.volume = old_volume;
            const before_buf = try master_qc.renderMasterRange(gpa, project, asset_cache, sec.start_frame, sec.length_frames);
            defer gpa.free(before_buf);
            target_track.?.volume = cand.value;
            const after_buf = try master_qc.renderMasterRange(gpa, project, asset_cache, sec.start_frame, sec.length_frames);
            defer gpa.free(after_buf);

            const bp = try std.fmt.allocPrint(gpa, ".cache/audition/vocal_balance_s{d}_before.wav", .{i + 1});
            const ap = try std.fmt.allocPrint(gpa, ".cache/audition/vocal_balance_s{d}_after_level_matched.wav", .{i + 1});
            try writeFloatWav(bp, before_buf, project.sample_rate);
            const matched = try gpa.alloc(f32, after_buf.len);
            defer gpa.free(matched);
            levelMatchCopy(matched, after_buf, rmsLin(before_buf));
            try writeFloatWav(ap, matched, project.sample_rate);
            try paths.append(gpa, bp);
            try paths.append(gpa, ap);
        }
        return .{
            .decision = .needs_human_listening,
            .reason = "Lead-to-instrumental balance improved on measured sections; intelligibility requires human/audio-model confirmation.",
            .classification = cls.class,
            .candidate = cand,
            .before = before,
            .after = after,
            .ab_paths = try paths.toOwnedSlice(gpa),
        };
    }

    return .{
        .decision = .committed,
        .reason = "Lead-to-instrumental balance improved consistently across the selected vocal sections without exceeding peak constraints. Measured balance change only, not intelligibility.",
        .classification = cls.class,
        .candidate = cand,
        .before = before,
        .after = after,
    };
}

pub fn freeTrialResult(gpa: std.mem.Allocator, r: *TrialResult) void {
    if (r.before) |*b| mix_sections.freeAnalysis(gpa, b);
    if (r.after) |*a| mix_sections.freeAnalysis(gpa, a);
    for (r.ab_paths) |p| gpa.free(p);
    if (r.ab_paths.len > 0) gpa.free(r.ab_paths);
    r.* = undefined;
}
