//! Mix session preflight — session integrity before any high-level mix mutation.
//! Read-only. decision is only `passed` or `abstained` (no soft-pass-then-mix).
const std = @import("std");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const master_qc = @import("master_qc.zig");

pub const CheckStatus = enum { pass, fail };

pub const Check = struct {
    name: []const u8,
    status: CheckStatus,
    detail: []const u8 = "",
    track_id: ?u64 = null,
};

pub const TimingStatus = enum { relative_alignment_verified, unverified };

pub const TimingInfo = struct {
    mode: []const u8 = "unverified",
    global_offset_frames: i64 = 0,
    relative_alignment_verified: bool = false,
    lead_outlier: bool = false,
    source_offsets_consistent: bool = false,
    sample_rates_consistent: bool = false,
    all_stems_share_same_offset: bool = false,
};

pub const Decision = enum { passed, abstained };

pub const KeyTrackInfo = struct {
    role: []const u8,
    track_id: ?u64 = null,
    name: ?[]const u8 = null,
    present: bool = false,
    muted: bool = true,
    volume: f32 = 0,
    pan: f32 = 0,
    active_region_count: u32 = 0,
    source_asset_id: ?u64 = null,
    source_path: ?[]const u8 = null,
    timeline_start_frame: i64 = 0,
    source_offset_frames: u64 = 0,
    length_frames: ?u64 = null,
    asset_sample_rate: ?u32 = null,
    asset_available: bool = false,
};

pub const Section = struct {
    id: u64,
    kind: []const u8,
    start_frame: u64,
    length_frames: u64,
    active_tracks: [][]const u8,
    lead_active: bool,
    lead_rms_dbfs: f32,
    instrumental_rms_dbfs: f32,
    master_rms_dbfs: f32,
    section_confidence: f32,
    selection_reason: []const u8,
    valid_for_vocal_balance: bool,
};

pub const PreflightOpts = struct {
    window_frames: u64 = 220_500, // ~5s @ 44.1k
    hop_frames: u64 = 220_500,
    max_scan_frames: u64 = 44100 * 60 * 5,
    quiet_rms_dbfs: f32 = -50.0,
    lead_active_rms_dbfs: f32 = -45.0,
};

pub const PreflightResult = struct {
    decision: Decision,
    blocking_reasons: [][]const u8,
    revision: u64,
    sample_rate: u32,
    timing_status: TimingStatus,
    timing: TimingInfo = .{},
    lead_track_id: ?u64 = null,
    lead_track_name: ?[]const u8 = null,
    key_tracks: []KeyTrackInfo,
    checks: []Check,
    sections: []Section,
    vocal_section_count: u32 = 0,
    analysis_scope_note: []const u8 = "sections are energy/activity candidates; not true semantic verse/chorus labels",
    presence_band_note: []const u8 = "presence metrics in analyze_mix_sections use Goertzel proxies (masking_status=proxy_only)",
};

const REQUIRED_ROLES = [_][]const u8{
    "Lead Vocals",
    "Backing Vocals",
    "Drums",
    "Bass",
    "Guitar",
    "Keyboard",
    "Synth",
    "Other",
};

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub fn nameContains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (asciiLower(hay[i + j]) != asciiLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

pub fn findLeadTrack(project: *const model.Project) ?*model.Track {
    for (project.tracks.items) |*t| {
        if (nameContains(t.name, "lead")) return t;
    }
    for (project.tracks.items) |*t| {
        if (nameContains(t.name, "vocal")) return t;
    }
    return null;
}

fn findTrackByRole(project: *const model.Project, role: []const u8) ?*model.Track {
    // Prefer name containing distinctive token from role.
    const token: []const u8 = blk: {
        if (nameContains(role, "lead")) break :blk "lead";
        if (nameContains(role, "back")) break :blk "back";
        if (nameContains(role, "drum")) break :blk "drum";
        if (nameContains(role, "bass")) break :blk "bass";
        if (nameContains(role, "guit")) break :blk "guit";
        if (nameContains(role, "key")) break :blk "key";
        if (nameContains(role, "synth")) break :blk "synth";
        if (nameContains(role, "other")) break :blk "other";
        break :blk role;
    };
    for (project.tracks.items) |*t| {
        if (nameContains(t.name, token)) return t;
    }
    return null;
}

fn rmsDbfsInterleaved(buf: []const f32) f32 {
    if (buf.len == 0) return -120;
    var sum: f64 = 0;
    for (buf) |s| sum += @as(f64, s) * @as(f64, s);
    const rms = @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
    return 20.0 * std.math.log10(@max(@as(f32, @floatCast(rms)), 1e-10));
}

fn assetFor(project: *const model.Project, id: model.AssetId) ?*const model.AudioSource {
    for (project.assets.items) |*a| {
        if (a.id == id) return a;
    }
    return null;
}

fn firstAudioClip(track: *const model.Track) ?model.AudioClip {
    for (track.clips.items) |c| {
        if (c == .audio) return c.audio;
    }
    return null;
}

fn countAudioClips(track: *const model.Track) u32 {
    var n: u32 = 0;
    for (track.clips.items) |c| {
        if (c == .audio and !c.audio.muted) n += 1;
    }
    return n;
}

fn pathExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    const f = std.c.fopen(path_z.ptr, "rb") orelse return false;
    _ = std.c.fclose(f);
    return true;
}

fn hasNanInfClipState(project: *const model.Project) bool {
    for (project.tracks.items) |t| {
        if (!std.math.isFinite(t.volume) or !std.math.isFinite(t.pan)) return true;
    }
    return false;
}

/// Relative stem alignment — NOT "must be at zero".
/// Shared global offset (e.g. all stems at -3924) is OK.
/// Block only when Lead is an outlier or source mapping policy breaks.
pub fn checkRelativeAlignment(project: *const model.Project, lead: *const model.Track) struct { status: TimingStatus, info: TimingInfo } {
    const lc = firstAudioClip(lead) orelse {
        return .{ .status = .unverified, .info = .{ .mode = "unverified", .lead_outlier = true } };
    };

    var stem_count: usize = 0;
    var mismatch: bool = false;
    var soffs_ok: bool = true;
    var sr_consistent: bool = true;
    var lead_sr: ?u32 = null;
    if (assetFor(project, lc.source_id)) |a| lead_sr = a.sample_rate;

    // Consensus among non-lead stems (if any).
    var ref_tl: ?i64 = null;
    var ref_so: ?u64 = null;
    var non_lead_consensus = true;
    for (project.tracks.items) |t| {
        if (t.id == lead.id) continue;
        const clip = firstAudioClip(&t) orelse continue;
        if (ref_tl == null) {
            ref_tl = clip.timeline_start_frame;
            ref_so = clip.source_offset_frames;
        } else if (clip.timeline_start_frame != ref_tl.? or clip.source_offset_frames != ref_so.?) {
            non_lead_consensus = false;
        }
    }

    for (project.tracks.items) |t| {
        const clip = firstAudioClip(&t) orelse continue;
        stem_count += 1;
        if (clip.timeline_start_frame != lc.timeline_start_frame) mismatch = true;
        if (clip.source_offset_frames != lc.source_offset_frames) {
            mismatch = true;
            soffs_ok = false;
        }
        if (assetFor(project, clip.source_id)) |a| {
            if (lead_sr) |lsr| {
                if (a.sample_rate != lsr) sr_consistent = false;
            }
        }
    }

    const lead_outlier = blk: {
        if (ref_tl) |rtl| {
            const rso = ref_so.?;
            break :blk (lc.timeline_start_frame != rtl or lc.source_offset_frames != rso);
        }
        break :blk false; // only lead has audio — no sibling to disagree with
    };

    const shared = !mismatch and stem_count > 0;
    const mode: []const u8 = if (!shared and !non_lead_consensus)
        "unverified"
    else if (shared and lc.timeline_start_frame == 0 and lc.source_offset_frames == 0)
        "sibling_zero"
    else if (shared)
        "shared_global_offset"
    else
        "unverified";

    // Pass when all stems (including Lead) share one offset policy — including non-zero.
    const ok = shared and !lead_outlier and sr_consistent and soffs_ok;
    return .{
        .status = if (ok) .relative_alignment_verified else .unverified,
        .info = .{
            .mode = mode,
            .global_offset_frames = lc.timeline_start_frame,
            .relative_alignment_verified = ok,
            .lead_outlier = lead_outlier,
            .source_offsets_consistent = soffs_ok and (non_lead_consensus or stem_count <= 1),
            .sample_rates_consistent = sr_consistent,
            .all_stems_share_same_offset = shared,
        },
    };
}

/// Back-compat alias.
pub fn checkSiblingZeroTiming(project: *const model.Project, lead: *const model.Track) TimingStatus {
    return checkRelativeAlignment(project, lead).status;
}

const Hop = struct {
    start: u64,
    lead_rms: f32,
    instrumental_rms: f32,
    master_rms: f32,
};

fn measureMutedMaster(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    start: u64,
    len: u64,
    mute_lead: bool,
    lead_id: ?model.TrackId,
) !f32 {
    var saved_mute: ?bool = null;
    var lead_ptr: ?*model.Track = null;
    if (mute_lead) {
        if (lead_id) |lid| {
            for (project.tracks.items) |*t| {
                if (t.id == lid) {
                    lead_ptr = t;
                    saved_mute = t.mute;
                    t.mute = true;
                    break;
                }
            }
        }
    }
    defer {
        if (saved_mute) |m| {
            if (lead_ptr) |t| t.mute = m;
        }
    }
    const buf = try master_qc.renderMasterRange(gpa, project, asset_cache, start, len);
    defer gpa.free(buf);
    return rmsDbfsInterleaved(buf);
}

fn scanHops(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    opts: PreflightOpts,
    lead_id: ?model.TrackId,
) ![]Hop {
    const total = master_qc.projectLengthFrames(project);
    const scan_end = @min(total, opts.max_scan_frames);
    const hop = @max(opts.hop_frames, 1);
    const win = @max(@min(opts.window_frames, hop), 1);
    var hops: std.ArrayList(Hop) = .empty;
    errdefer hops.deinit(gpa);

    var start: u64 = 0;
    while (start < scan_end) : (start += hop) {
        const len = @min(win, scan_end - start);
        if (len == 0) break;
        const master_rms = try measureMutedMaster(gpa, project, asset_cache, start, len, false, lead_id);
        const instrumental_rms = try measureMutedMaster(gpa, project, asset_cache, start, len, true, lead_id);
        var saved: std.ArrayList(MuteSave) = .empty;
        defer saved.deinit(gpa);
        for (project.tracks.items) |*t| {
            try saved.append(gpa, .{ .id = t.id, .mute = t.mute });
            if (lead_id) |lid| {
                t.mute = (t.id != lid);
            } else {
                t.mute = true;
            }
        }
        const lead_buf = master_qc.renderMasterRange(gpa, project, asset_cache, start, len) catch |e| {
            restoreMutes(project, saved.items);
            return e;
        };
        defer gpa.free(lead_buf);
        const lead_db = rmsDbfsInterleaved(lead_buf);
        restoreMutes(project, saved.items);
        try hops.append(gpa, .{
            .start = start,
            .lead_rms = lead_db,
            .instrumental_rms = instrumental_rms,
            .master_rms = master_rms,
        });
    }
    return try hops.toOwnedSlice(gpa);
}

const MuteSave = struct { id: model.TrackId, mute: bool };

fn restoreMutes(project: *model.Project, saved: []const MuteSave) void {
    for (saved) |s| {
        for (project.tracks.items) |*t| {
            if (t.id == s.id) t.mute = s.mute;
        }
    }
}

fn trackActiveNames(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    start: u64,
    len: u64,
    quiet: f32,
) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    for (project.tracks.items) |*t| {
        if (t.mute) continue;
        var saved: std.ArrayList(MuteSave) = .empty;
        defer saved.deinit(gpa);
        for (project.tracks.items) |*o| {
            try saved.append(gpa, .{ .id = o.id, .mute = o.mute });
            o.mute = (o.id != t.id);
        }
        const buf = master_qc.renderMasterRange(gpa, project, asset_cache, start, len) catch {
            restoreMutes(project, saved.items);
            continue;
        };
        defer gpa.free(buf);
        const db = rmsDbfsInterleaved(buf);
        restoreMutes(project, saved.items);
        if (db > quiet) try names.append(gpa, t.name);
    }
    return try names.toOwnedSlice(gpa);
}

fn pickSections(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    hops: []const Hop,
    opts: PreflightOpts,
) ![]Section {
    var out: std.ArrayList(Section) = .empty;
    errdefer {
        for (out.items) |*s| gpa.free(s.active_tracks);
        out.deinit(gpa);
    }
    if (hops.len == 0) return try out.toOwnedSlice(gpa);

    var next_id: u64 = 101;
    const win = opts.window_frames;
    const quiet = opts.quiet_rms_dbfs;
    const lead_thr = opts.lead_active_rms_dbfs;

    // Collect lead-active hop indices
    var lead_idxs: std.ArrayList(usize) = .empty;
    defer lead_idxs.deinit(gpa);
    var instr_idxs: std.ArrayList(usize) = .empty;
    defer instr_idxs.deinit(gpa);
    var best_lead_i: ?usize = null;
    var best_lead: f32 = -999;
    var best_master_i: usize = 0;
    var best_master: f32 = -999;

    for (hops, 0..) |h, i| {
        if (h.master_rms > best_master) {
            best_master = h.master_rms;
            best_master_i = i;
        }
        if (h.lead_rms > lead_thr) {
            try lead_idxs.append(gpa, i);
            if (h.lead_rms > best_lead) {
                best_lead = h.lead_rms;
                best_lead_i = i;
            }
        } else if (h.master_rms > quiet and h.lead_rms <= lead_thr) {
            try instr_idxs.append(gpa, i);
        }
    }

    const appendSection = struct {
        fn go(
            gpa2: std.mem.Allocator,
            project2: *model.Project,
            cache: *const mixer.AssetCache,
            list: *std.ArrayList(Section),
            id: *u64,
            kind: []const u8,
            hop: Hop,
            win2: u64,
            quiet2: f32,
            lead_thr2: f32,
            reason: []const u8,
            conf: f32,
        ) !void {
            // Do not count the same hop under multiple labels toward section diversity.
            for (list.items) |existing| {
                if (existing.start_frame == hop.start) return;
            }
            const active = try trackActiveNames(gpa2, project2, cache, hop.start, win2, quiet2);
            const lead_on = hop.lead_rms > lead_thr2;
            try list.append(gpa2, .{
                .id = id.*,
                .kind = kind,
                .start_frame = hop.start,
                .length_frames = win2,
                .active_tracks = active,
                .lead_active = lead_on,
                .lead_rms_dbfs = hop.lead_rms,
                .instrumental_rms_dbfs = hop.instrumental_rms,
                .master_rms_dbfs = hop.master_rms,
                .section_confidence = conf,
                .selection_reason = reason,
                .valid_for_vocal_balance = lead_on and hop.master_rms > quiet2,
            });
            id.* += 1;
        }
    }.go;

    if (lead_idxs.items.len > 0) {
        try appendSection(gpa, project, asset_cache, &out, &next_id, "vocal_section_1", hops[lead_idxs.items[0]], win, quiet, lead_thr, "earliest_lead_active_hop", 0.7);
    }
    if (lead_idxs.items.len > 1) {
        const mid = lead_idxs.items[lead_idxs.items.len / 2];
        if (mid != lead_idxs.items[0]) {
            try appendSection(gpa, project, asset_cache, &out, &next_id, "vocal_section_2", hops[mid], win, quiet, lead_thr, "mid_lead_active_hop", 0.65);
        }
    }
    if (best_lead_i) |bi| {
        try appendSection(gpa, project, asset_cache, &out, &next_id, "dense_vocal_section", hops[bi], win, quiet, lead_thr, "max_lead_rms_hop", 0.8);
    }
    if (instr_idxs.items.len > 0) {
        try appendSection(gpa, project, asset_cache, &out, &next_id, "instrumental_section", hops[instr_idxs.items[0]], win, quiet, lead_thr, "lead_quiet_master_active", 0.6);
    }
    // Transition: last lead-active before an instrumental hop if possible
    if (lead_idxs.items.len > 0 and instr_idxs.items.len > 0) {
        const li = lead_idxs.items[lead_idxs.items.len - 1];
        try appendSection(gpa, project, asset_cache, &out, &next_id, "transition_section", hops[li], win, quiet, lead_thr, "last_lead_before_or_near_instrumental", 0.55);
    }
    if (best_master > quiet) {
        try appendSection(gpa, project, asset_cache, &out, &next_id, "loudest_master_section", hops[best_master_i], win, quiet, lead_thr, "max_master_rms_hop", 0.75);
    }

    return try out.toOwnedSlice(gpa);
}

pub fn runPreflight(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    opts: PreflightOpts,
) !PreflightResult {
    var checks: std.ArrayList(Check) = .empty;
    errdefer checks.deinit(gpa);
    var blocking: std.ArrayList([]const u8) = .empty;
    errdefer blocking.deinit(gpa);
    var key_tracks: std.ArrayList(KeyTrackInfo) = .empty;
    errdefer key_tracks.deinit(gpa);

    // Project integrity
    if (project.sample_rate == 0) {
        try checks.append(gpa, .{ .name = "sample_rate_known", .status = .fail, .detail = "sample_rate is 0" });
        try blocking.append(gpa, "sample_rate_unknown");
    } else {
        try checks.append(gpa, .{ .name = "sample_rate_known", .status = .pass, .detail = "sample_rate set" });
    }

    var missing_asset = false;
    for (project.assets.items) |a| {
        const in_cache = asset_cache.get(a.id) != null;
        const on_disk = pathExists(a.relative_path);
        if (!in_cache and !on_disk) {
            missing_asset = true;
            break;
        }
    }
    if (project.assets.items.len == 0) {
        try checks.append(gpa, .{ .name = "assets_present", .status = .fail, .detail = "no assets" });
        try blocking.append(gpa, "no_assets");
    } else if (missing_asset) {
        try checks.append(gpa, .{ .name = "assets_available", .status = .fail, .detail = "missing source file or cache entry" });
        try blocking.append(gpa, "missing_source_files");
    } else {
        try checks.append(gpa, .{ .name = "assets_available", .status = .pass, .detail = "assets resolvable" });
    }

    if (hasNanInfClipState(project)) {
        try checks.append(gpa, .{ .name = "finite_item_state", .status = .fail, .detail = "NaN/Inf in track params" });
        try blocking.append(gpa, "nan_inf_item_state");
    } else {
        try checks.append(gpa, .{ .name = "finite_item_state", .status = .pass, .detail = "track params finite" });
    }

    // Stable IDs + revision consistency (machine evidence only).
    var id_dup = false;
    var i_id: usize = 0;
    while (i_id < project.tracks.items.len) : (i_id += 1) {
        var j_id: usize = i_id + 1;
        while (j_id < project.tracks.items.len) : (j_id += 1) {
            if (project.tracks.items[i_id].id == project.tracks.items[j_id].id) id_dup = true;
        }
    }
    if (id_dup) {
        try checks.append(gpa, .{ .name = "stable_ids_valid", .status = .fail, .detail = "duplicate track ids" });
        try blocking.append(gpa, "invalid_stable_ids");
    } else {
        try checks.append(gpa, .{ .name = "stable_ids_valid", .status = .pass, .detail = "track ids unique" });
    }
    try checks.append(gpa, .{ .name = "revision_consistent", .status = .pass, .detail = "project.revision readable" });

    // Key tracks
    for (REQUIRED_ROLES) |role| {
        var info: KeyTrackInfo = .{ .role = role };
        if (findTrackByRole(project, role)) |t| {
            info.present = true;
            info.track_id = t.id;
            info.name = t.name;
            info.muted = t.mute;
            info.volume = t.volume;
            info.pan = t.pan;
            info.active_region_count = countAudioClips(t);
            if (firstAudioClip(t)) |clip| {
                info.source_asset_id = clip.source_id;
                info.timeline_start_frame = clip.timeline_start_frame;
                info.source_offset_frames = clip.source_offset_frames;
                info.length_frames = clip.length_frames;
                if (assetFor(project, clip.source_id)) |a| {
                    info.source_path = a.relative_path;
                    info.asset_sample_rate = a.sample_rate;
                    info.asset_available = asset_cache.get(a.id) != null or pathExists(a.relative_path);
                }
            }
        }
        try key_tracks.append(gpa, info);
    }

    const lead = findLeadTrack(project);
    var lead_id: ?u64 = null;
    var lead_name: ?[]const u8 = null;
    var timing: TimingStatus = .unverified;
    var timing_info: TimingInfo = .{};

    if (lead) |t| {
        lead_id = t.id;
        lead_name = t.name;
        try checks.append(gpa, .{ .name = "lead_vocal_present", .status = .pass, .detail = "lead track found", .track_id = t.id });
        if (t.mute) {
            try checks.append(gpa, .{ .name = "lead_vocal_unmuted", .status = .fail, .detail = "lead muted", .track_id = t.id });
            try blocking.append(gpa, "lead_vocal_not_available");
        } else {
            try checks.append(gpa, .{ .name = "lead_vocal_unmuted", .status = .pass, .detail = "lead unmuted", .track_id = t.id });
        }
        if (countAudioClips(t) == 0) {
            try checks.append(gpa, .{ .name = "lead_active_regions", .status = .fail, .detail = "no active regions", .track_id = t.id });
            try blocking.append(gpa, "lead_vocal_not_available");
        } else {
            try checks.append(gpa, .{ .name = "lead_active_regions", .status = .pass, .detail = "active region present", .track_id = t.id });
        }
        if (firstAudioClip(t)) |clip| {
            if (assetFor(project, clip.source_id)) |a| {
                const ok = asset_cache.get(a.id) != null or pathExists(a.relative_path);
                if (!ok) {
                    try checks.append(gpa, .{ .name = "lead_source_available", .status = .fail, .detail = "lead source missing", .track_id = t.id });
                    try blocking.append(gpa, "missing_lead_source");
                }
            } else {
                try checks.append(gpa, .{ .name = "lead_source_available", .status = .fail, .detail = "lead source asset id not in project", .track_id = t.id });
                try blocking.append(gpa, "missing_lead_source");
            }
        }
        const ta = checkRelativeAlignment(project, t);
        timing = ta.status;
        timing_info = ta.info;
        if (timing == .relative_alignment_verified) {
            try checks.append(gpa, .{ .name = "lead_timing_integrity", .status = .pass, .detail = "relative stem alignment verified (shared offset OK)", .track_id = t.id });
        } else {
            try checks.append(gpa, .{ .name = "lead_timing_integrity", .status = .fail, .detail = "relative alignment broken (Lead outlier or inconsistent stem offsets)", .track_id = t.id });
            try blocking.append(gpa, "lead_timing_unverified");
        }
    } else {
        try checks.append(gpa, .{ .name = "lead_vocal_present", .status = .fail, .detail = "no lead/vocal track" });
        try blocking.append(gpa, "lead_vocal_not_available");
        try blocking.append(gpa, "lead_timing_unverified");
    }

    // Section scan when lead exists (even if already blocking — for silent-lead evidence).
    var sections: []Section = &[_]Section{};
    if (lead != null) {
        const hops = try scanHops(gpa, project, asset_cache, opts, lead_id);
        defer gpa.free(hops);

        var any_lead = false;
        for (hops) |h| {
            if (h.lead_rms > opts.lead_active_rms_dbfs) any_lead = true;
        }
        if (!any_lead and hops.len > 0) {
            try checks.append(gpa, .{ .name = "lead_not_silent", .status = .fail, .detail = "lead energy at noise floor across scan" });
            try blocking.append(gpa, "lead_vocal_not_available");
        } else if (hops.len > 0) {
            try checks.append(gpa, .{ .name = "lead_not_silent", .status = .pass, .detail = "lead energy found in scan" });
        }

        sections = try pickSections(gpa, project, asset_cache, hops, opts);
    }

    var vocal_ok: u32 = 0;
    for (sections) |s| {
        if (s.valid_for_vocal_balance) vocal_ok += 1;
    }
    if (vocal_ok < 3) {
        try checks.append(gpa, .{ .name = "representative_vocal_sections", .status = .fail, .detail = "fewer than three valid lead-active sections" });
        try blocking.append(gpa, "fewer_than_three_representative_vocal_sections");
    } else {
        try checks.append(gpa, .{ .name = "representative_vocal_sections", .status = .pass, .detail = ">=3 vocal-valid sections" });
    }

    // Deduplicate blocking reasons
    var uniq: std.ArrayList([]const u8) = .empty;
    errdefer uniq.deinit(gpa);
    for (blocking.items) |b| {
        var seen = false;
        for (uniq.items) |u| {
            if (std.mem.eql(u8, u, b)) seen = true;
        }
        if (!seen) try uniq.append(gpa, b);
    }
    blocking.deinit(gpa);

    const decision: Decision = if (uniq.items.len == 0) .passed else .abstained;

    return .{
        .decision = decision,
        .blocking_reasons = try uniq.toOwnedSlice(gpa),
        .revision = project.revision,
        .sample_rate = project.sample_rate,
        .timing_status = timing,
        .timing = timing_info,
        .lead_track_id = lead_id,
        .lead_track_name = lead_name,
        .key_tracks = try key_tracks.toOwnedSlice(gpa),
        .checks = try checks.toOwnedSlice(gpa),
        .sections = sections,
        .vocal_section_count = vocal_ok,
    };
}

pub fn freePreflightResult(gpa: std.mem.Allocator, r: *PreflightResult) void {
    for (r.sections) |*s| gpa.free(s.active_tracks);
    gpa.free(r.sections);
    gpa.free(r.checks);
    gpa.free(r.key_tracks);
    gpa.free(r.blocking_reasons);
    r.* = undefined;
}

pub fn cloneSections(gpa: std.mem.Allocator, src: []const Section) ![]Section {
    var out: std.ArrayList(Section) = .empty;
    errdefer {
        for (out.items) |*s| gpa.free(s.active_tracks);
        out.deinit(gpa);
    }
    for (src) |s| {
        const names = try gpa.alloc([]const u8, s.active_tracks.len);
        @memcpy(names, s.active_tracks);
        try out.append(gpa, .{
            .id = s.id,
            .kind = s.kind,
            .start_frame = s.start_frame,
            .length_frames = s.length_frames,
            .active_tracks = names,
            .lead_active = s.lead_active,
            .lead_rms_dbfs = s.lead_rms_dbfs,
            .instrumental_rms_dbfs = s.instrumental_rms_dbfs,
            .master_rms_dbfs = s.master_rms_dbfs,
            .section_confidence = s.section_confidence,
            .selection_reason = s.selection_reason,
            .valid_for_vocal_balance = s.valid_for_vocal_balance,
        });
    }
    return try out.toOwnedSlice(gpa);
}

pub fn freeSections(gpa: std.mem.Allocator, sections: []Section) void {
    for (sections) |*s| gpa.free(s.active_tracks);
    gpa.free(sections);
}

/// Session gate stored on the live DispatchCtx.
pub const MixSessionGate = struct {
    passed: bool = false,
    revision: u64 = 0,
    lead_track_id: ?u64 = null,
    sections: []Section = &.{},
    owned: bool = false,

    pub fn clear(self: *MixSessionGate, gpa: std.mem.Allocator) void {
        if (self.owned and self.sections.len > 0) freeSections(gpa, self.sections);
        self.* = .{};
    }

    pub fn storePassed(self: *MixSessionGate, gpa: std.mem.Allocator, result: *const PreflightResult) !void {
        self.clear(gpa);
        if (result.decision != .passed) return;
        self.passed = true;
        self.revision = result.revision;
        self.lead_track_id = result.lead_track_id;
        self.sections = try cloneSections(gpa, result.sections);
        self.owned = true;
    }

    pub fn requirePassed(self: *const MixSessionGate, project_revision: u64) ?[]const u8 {
        if (!self.passed) return "preflight_not_passed";
        if (self.revision != project_revision) return "stale_preflight";
        return null;
    }
};

test "findLeadTrack prefers Lead over Backing" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var p: model.Project = .{};
    defer p.deinit(gpa);
    _ = try p.addTrack(gpa, "1 Backing Vocals");
    _ = try p.addTrack(gpa, "0 Lead Vocals");
    const lead = findLeadTrack(&p).?;
    try std.testing.expect(nameContains(lead.name, "lead"));
}

test "relative alignment: shared non-zero offset ok; lead outlier fails" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var p: model.Project = .{ .sample_rate = 44100 };
    defer p.deinit(gpa);
    const lead = try p.addTrack(gpa, "0 Lead Vocals");
    try lead.clips.append(gpa, .{ .audio = .{ .id = 1, .source_id = 2, .timeline_start_frame = -3924, .source_offset_frames = 0 } });
    const drums = try p.addTrack(gpa, "2 Drums");
    try drums.clips.append(gpa, .{ .audio = .{ .id = 3, .source_id = 4, .timeline_start_frame = -3924, .source_offset_frames = 0 } });
    const ok = checkRelativeAlignment(&p, lead);
    try std.testing.expect(ok.status == .relative_alignment_verified);
    try std.testing.expect(ok.info.mode.len > 0);
    try std.testing.expectEqual(@as(i64, -3924), ok.info.global_offset_frames);
    drums.clips.items[0].audio.timeline_start_frame = 0;
    const bad = checkRelativeAlignment(&p, lead);
    try std.testing.expect(bad.status == .unverified);
    try std.testing.expect(bad.info.lead_outlier);
}
