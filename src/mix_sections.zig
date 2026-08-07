//! Read-only multi-section mix analysis (Goertzel presence proxies — not perceived masking).
const std = @import("std");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const master_qc = @import("master_qc.zig");
const mix_preflight = @import("mix_preflight.zig");

pub const masking_status_label = "proxy_only";

const BAND_HZ = [_]f32{ 62.5, 125, 250, 500, 1000, 2000, 4000, 8000 };

pub const TrackMetrics = struct {
    peak_dbfs: f32,
    rms_dbfs: f32,
    crest_factor_db: f32,
    presence_250_500: f32,
    presence_500_1000: f32,
    presence_1k_2k: f32,
    presence_2k_4k: f32,
    presence_4k_8k: f32,
};

pub const SectionAnalysis = struct {
    section_id: u64,
    start_frame: u64,
    length_frames: u64,
    lead: TrackMetrics,
    guitar: ?TrackMetrics = null,
    synth: ?TrackMetrics = null,
    bass: ?TrackMetrics = null,
    drums: ?TrackMetrics = null,
    instrumental: TrackMetrics,
    master: TrackMetrics,
    lead_to_instrumental_rms_db: f32,
    lead_presence_energy_db: f32,
    instrumental_presence_energy_db: f32,
    presence_delta_db: f32,
    masking_status: []const u8 = masking_status_label,
};

pub const AnalysisResult = struct {
    revision: u64,
    masking_status: []const u8 = masking_status_label,
    sections: []SectionAnalysis,
    section_variance_db: f32,
    lead_to_instrumental_mean_db: f32,
};

const Goertzel = struct {
    coeff: f64,
    s1: f64 = 0,
    s2: f64 = 0,
    fn init(freq_hz: f32, sample_rate: u32) Goertzel {
        const w = 2.0 * std.math.pi * @as(f64, freq_hz) / @as(f64, @floatFromInt(sample_rate));
        return .{ .coeff = 2.0 * @cos(w) };
    }
    fn push(self: *Goertzel, x: f32) void {
        const s0 = @as(f64, x) + self.coeff * self.s1 - self.s2;
        self.s2 = self.s1;
        self.s1 = s0;
    }
    fn magDb(self: *const Goertzel) f32 {
        const m = self.s1 * self.s1 + self.s2 * self.s2 - self.coeff * self.s1 * self.s2;
        return 10.0 * std.math.log10(@max(@as(f32, @floatCast(m)), 1e-20));
    }
};

fn metricsFromBuf(buf: []const f32, sample_rate: u32) TrackMetrics {
    var peak: f32 = 0;
    var sum: f64 = 0;
    var gz: [BAND_HZ.len]Goertzel = undefined;
    for (&gz, BAND_HZ) |*g, hz| g.* = Goertzel.init(hz, sample_rate);
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) {
        const l = buf[i];
        const r = buf[i + 1];
        const m = @max(@abs(l), @abs(r));
        if (m > peak) peak = m;
        sum += @as(f64, l) * @as(f64, l) + @as(f64, r) * @as(f64, r);
        const mono = 0.5 * (l + r);
        for (&gz) |*g| g.push(mono);
    }
    const n = @as(f64, @floatFromInt(buf.len));
    const rms = @sqrt(sum / @max(n, 1));
    const peak_db = 20.0 * std.math.log10(@max(peak, 1e-10));
    const rms_db = 20.0 * std.math.log10(@max(@as(f32, @floatCast(rms)), 1e-10));
    return .{
        .peak_dbfs = peak_db,
        .rms_dbfs = rms_db,
        .crest_factor_db = peak_db - rms_db,
        .presence_250_500 = gz[2].magDb(),
        .presence_500_1000 = gz[3].magDb(),
        .presence_1k_2k = gz[4].magDb(),
        .presence_2k_4k = gz[5].magDb(),
        .presence_4k_8k = gz[6].magDb(),
    };
}

const MuteSave = struct { id: model.TrackId, mute: bool };

fn restoreMutes(project: *model.Project, saved: []const MuteSave) void {
    for (saved) |s| {
        for (project.tracks.items) |*t| {
            if (t.id == s.id) t.mute = s.mute;
        }
    }
}

fn renderSoloTrack(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    track_id: model.TrackId,
    start: u64,
    len: u64,
) ![]f32 {
    var saved: std.ArrayList(MuteSave) = .empty;
    defer saved.deinit(gpa);
    for (project.tracks.items) |*t| {
        try saved.append(gpa, .{ .id = t.id, .mute = t.mute });
        t.mute = (t.id != track_id);
    }
    defer restoreMutes(project, saved.items);
    return try master_qc.renderMasterRange(gpa, project, asset_cache, start, len);
}

fn renderInstrumental(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    lead_id: model.TrackId,
    start: u64,
    len: u64,
) ![]f32 {
    var saved_mute: bool = false;
    var lead_ptr: ?*model.Track = null;
    for (project.tracks.items) |*t| {
        if (t.id == lead_id) {
            lead_ptr = t;
            saved_mute = t.mute;
            t.mute = true;
            break;
        }
    }
    defer if (lead_ptr) |t| {
        t.mute = saved_mute;
    };
    return try master_qc.renderMasterRange(gpa, project, asset_cache, start, len);
}

fn roleId(project: *model.Project, token: []const u8) ?model.TrackId {
    for (project.tracks.items) |*t| {
        if (mix_preflight.nameContains(t.name, token)) return t.id;
    }
    return null;
}

pub fn analyzeSections(
    gpa: std.mem.Allocator,
    project: *model.Project,
    asset_cache: *const mixer.AssetCache,
    lead_id: model.TrackId,
    sections: []const mix_preflight.Section,
) !AnalysisResult {
    var out: std.ArrayList(SectionAnalysis) = .empty;
    errdefer out.deinit(gpa);

    const guitar_id = roleId(project, "guit");
    const synth_id = roleId(project, "synth");
    const bass_id = roleId(project, "bass");
    const drums_id = roleId(project, "drum");
    const sr = project.sample_rate;

    var deltas: std.ArrayList(f32) = .empty;
    defer deltas.deinit(gpa);

    for (sections) |sec| {
        const lead_buf = try renderSoloTrack(gpa, project, asset_cache, lead_id, sec.start_frame, sec.length_frames);
        defer gpa.free(lead_buf);
        const instr_buf = try renderInstrumental(gpa, project, asset_cache, lead_id, sec.start_frame, sec.length_frames);
        defer gpa.free(instr_buf);
        const master_buf = try master_qc.renderMasterRange(gpa, project, asset_cache, sec.start_frame, sec.length_frames);
        defer gpa.free(master_buf);

        const lead_m = metricsFromBuf(lead_buf, sr);
        const instr_m = metricsFromBuf(instr_buf, sr);
        const master_m = metricsFromBuf(master_buf, sr);
        const lead_pres = (lead_m.presence_500_1000 + lead_m.presence_1k_2k + lead_m.presence_2k_4k) / 3.0;
        const instr_pres = (instr_m.presence_500_1000 + instr_m.presence_1k_2k + instr_m.presence_2k_4k) / 3.0;
        const delta = lead_m.rms_dbfs - instr_m.rms_dbfs;
        try deltas.append(gpa, delta);

        var guitar_m: ?TrackMetrics = null;
        if (guitar_id) |gid| {
            const b = try renderSoloTrack(gpa, project, asset_cache, gid, sec.start_frame, sec.length_frames);
            defer gpa.free(b);
            guitar_m = metricsFromBuf(b, sr);
        }
        var synth_m: ?TrackMetrics = null;
        if (synth_id) |sid| {
            const b = try renderSoloTrack(gpa, project, asset_cache, sid, sec.start_frame, sec.length_frames);
            defer gpa.free(b);
            synth_m = metricsFromBuf(b, sr);
        }
        var bass_m: ?TrackMetrics = null;
        if (bass_id) |bid| {
            const b = try renderSoloTrack(gpa, project, asset_cache, bid, sec.start_frame, sec.length_frames);
            defer gpa.free(b);
            bass_m = metricsFromBuf(b, sr);
        }
        var drums_m: ?TrackMetrics = null;
        if (drums_id) |did| {
            const b = try renderSoloTrack(gpa, project, asset_cache, did, sec.start_frame, sec.length_frames);
            defer gpa.free(b);
            drums_m = metricsFromBuf(b, sr);
        }

        try out.append(gpa, .{
            .section_id = sec.id,
            .start_frame = sec.start_frame,
            .length_frames = sec.length_frames,
            .lead = lead_m,
            .guitar = guitar_m,
            .synth = synth_m,
            .bass = bass_m,
            .drums = drums_m,
            .instrumental = instr_m,
            .master = master_m,
            .lead_to_instrumental_rms_db = delta,
            .lead_presence_energy_db = lead_pres,
            .instrumental_presence_energy_db = instr_pres,
            .presence_delta_db = lead_pres - instr_pres,
        });
    }

    var mean: f32 = 0;
    var vmin: f32 = 999;
    var vmax: f32 = -999;
    for (deltas.items) |d| {
        mean += d;
        if (d < vmin) vmin = d;
        if (d > vmax) vmax = d;
    }
    if (deltas.items.len > 0) mean /= @floatFromInt(deltas.items.len);
    const variance = if (deltas.items.len > 0) vmax - vmin else 0;

    return .{
        .revision = project.revision,
        .sections = try out.toOwnedSlice(gpa),
        .section_variance_db = variance,
        .lead_to_instrumental_mean_db = mean,
    };
}

pub fn freeAnalysis(gpa: std.mem.Allocator, r: *AnalysisResult) void {
    gpa.free(r.sections);
    r.* = undefined;
}
