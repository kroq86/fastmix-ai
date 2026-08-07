const std = @import("std");

// Core data model (roadmap SPEC_DAW_ROADMAP.md §1/§12/§14), proven by
// spikes/spike_core_model.zig: stable IDs survive array reordering (unlike
// indices), and std.json round-trips the tagged unions (Clip, Effect)
// correctly. This module is the "stable core" -- extend it, don't reshape it.

pub const TrackId = u64;
pub const ClipId = u64;
pub const EffectId = u64;
pub const AssetId = u64;
pub const BusId = u64;
pub const SendId = u64;

var next_id: u64 = 1;
pub fn allocId() u64 {
    defer next_id += 1;
    return next_id;
}

pub const Event = struct {
    quant: i64, // quantized position, relative to the clip's own start (musical time)
    semitone: i32,
    start: bool,
    velocity: f32 = 1.0,
};

pub const MidiClip = struct {
    id: ClipId,
    start_bar: i64, // position on the project timeline, in bars (musical time)
    bars: i64,
    events: std.ArrayList(Event),

    pub fn deinit(self: *MidiClip, gpa: std.mem.Allocator) void {
        self.events.deinit(gpa);
    }
};

// Audio clips reference an asset by ID (see AudioSource) instead of holding
// samples themselves -- a single real stem is ~100MB, storing it inline in
// Project was rejected after the spike measured that (see §12).
pub const AudioClip = struct {
    id: ClipId,
    source_id: AssetId,
    timeline_start_frame: i64, // position in frames (audio time, not musical time -- see §1)
    // Real stems often have a bit of leading silence/pickup before the true
    // downbeat -- this trims which frame of the SOURCE playback starts from,
    // without touching the source file (non-destructive). A minimal stand-in
    // for the full AudioRegion model (§15) until that's built: manual only,
    // no auto transient-alignment yet.
    source_offset_frames: u64 = 0,
    /// How many source frames to play from `source_offset_frames`. null = to asset end.
    length_frames: ?u64 = null,
    /// Item mute (independent of track mute).
    muted: bool = false,
};

pub const Clip = union(enum) {
    midi: MidiClip,
    audio: AudioClip,

    pub fn id(self: Clip) ClipId {
        return switch (self) {
            .midi => |m| m.id,
            .audio => |a| a.id,
        };
    }

    pub fn deinit(self: *Clip, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .midi => |*m| m.deinit(gpa),
            .audio => {},
        }
    }
};

pub const Waveform = enum { sine, square, saw, triangle };

pub const Adsr = struct {
    attack_sec: f32 = 0.01,
    decay_sec: f32 = 0.08,
    sustain_level: f32 = 0.6,
    release_sec: f32 = 0.15,
};

pub const Instrument = struct {
    waveform: Waveform = .sine,
    adsr: Adsr = .{},
    octave_offset: i32 = 0,
};

pub const EffectKind = enum { eq, compressor, limiter, sidechain_compressor, delay, stereo_width };

pub const StereoWidthMode = enum { fullband, crossover };

/// Mid/Side width. `width` used when mode=fullband; crossover splits at `crossover_hz`.
/// No hidden makeup gain — contract is pure S' = S * width (per band).
pub const StereoWidthParams = struct {
    mode: StereoWidthMode = .crossover,
    /// Fullband width (also accepted as alias when setting mode=fullband).
    width: f32 = 1.0,
    crossover_hz: f32 = 150.0,
    low_width: f32 = 1.0,
    high_width: f32 = 1.0,
};

pub const SendTap = enum { pre_fader, post_fader };

pub const DelayParams = struct {
    time_ms: f32 = 250,
    feedback: f32 = 0.35,
    /// One-pole high-damping on the feedback path (0 = dark, 1 = bright).
    damping: f32 = 0.5,
    /// Wet/dry: return buses should use mix=1 (100% wet).
    mix: f32 = 1.0,
};

pub const EqBandType = enum { peak, low_shelf, high_shelf, highpass };

/// Parametric EQ band. Legacy JSON used `freq`; load accepts `freq` or `frequency_hz`.
pub const EqBand = struct {
    band_type: EqBandType = .peak,
    frequency_hz: f32,
    gain_db: f32 = 0.0,
    q: f32 = 0.707,
    bypass: bool = false,
};
pub const EqParams = struct { bands: std.ArrayList(EqBand) };

/// Wire/DTO form: dual-read legacy `freq`, write `frequency_hz` (freq left null).
pub const EqBandDto = struct {
    band_type: EqBandType = .peak,
    frequency_hz: ?f32 = null,
    /// Legacy project JSON key.
    freq: ?f32 = null,
    gain_db: f32 = 0.0,
    q: f32 = 0.707,
    bypass: bool = false,

    pub fn toBand(self: EqBandDto) error{MissingBandFreq}!EqBand {
        const f = self.frequency_hz orelse self.freq orelse return error.MissingBandFreq;
        return .{
            .band_type = self.band_type,
            .frequency_hz = f,
            .gain_db = self.gain_db,
            .q = self.q,
            .bypass = self.bypass,
        };
    }

    pub fn fromBand(b: EqBand) EqBandDto {
        return .{
            .band_type = b.band_type,
            .frequency_hz = b.frequency_hz,
            .freq = null,
            .gain_db = b.gain_db,
            .q = b.q,
            .bypass = b.bypass,
        };
    }
};
pub const CompressorParams = struct {
    threshold_db: f32 = -18,
    ratio: f32 = 4.0,
    attack_ms: f32 = 10,
    release_ms: f32 = 100,
    knee_db: f32 = 6.0,
    makeup_db: f32 = 0,
    /// Wet/dry mix: 0 = dry, 1 = fully compressed (+ makeup on wet).
    mix: f32 = 1.0,
};
pub const LimiterParams = struct {
    /// Sample-peak ceiling (dBFS).
    ceiling_dbfs: f32 = -1.0,
    /// Soft threshold where gain reduction begins.
    threshold_db: f32 = -1.0,
    release_ms: f32 = 50.0,
    /// Delay before gain application (ms). 0 = no lookahead.
    lookahead_ms: f32 = 1.0,
    /// When true, stereo linked (max abs across L/R drives GR).
    link_channels: bool = true,
    /// Legacy deserialize alias — remapped to ceiling_dbfs when present.
    limit_db: ?f32 = null,
};

pub fn normalizeLimiterParams(p: *LimiterParams) void {
    if (p.limit_db) |legacy| {
        p.ceiling_dbfs = legacy;
        if (p.threshold_db == -1.0) p.threshold_db = legacy;
        p.limit_db = null;
    }
}
pub const SidechainParams = struct {
    source_track_id: TrackId, // stable ID, not an index -- see spike_core_model.zig
    threshold_db: f32 = -18,
    ratio: f32 = 8.0,
    attack_ms: f32 = 5,
    release_ms: f32 = 100,
    /// Dry (pre-bake) asset; playback when bypassed / before wet exists.
    dry_asset_id: ?AssetId = null,
    /// Offline ffmpeg wet bake; set on first enable.
    wet_asset_id: ?AssetId = null,
};

pub const Effect = struct {
    id: EffectId,
    bypassed: bool = false,
    params: union(EffectKind) {
        eq: EqParams,
        compressor: CompressorParams,
        limiter: LimiterParams,
        sidechain_compressor: SidechainParams,
        delay: DelayParams,
        stereo_width: StereoWidthParams,
    },

    pub fn deinit(self: *Effect, gpa: std.mem.Allocator) void {
        switch (self.params) {
            .eq => |*e| e.bands.deinit(gpa),
            else => {},
        }
    }
};

pub const Track = struct {
    id: TrackId,
    name: []const u8, // owned
    instrument: Instrument = .{},
    clips: std.ArrayList(Clip),
    effects: std.ArrayList(Effect),
    volume: f32 = 1.0, // 0..1
    pan: f32 = 0.0, // -1..1
    mute: bool = false,
    solo: bool = false,
    armed: bool = false,
    /// Master switch for the track FX chain (Reaper-style FX button power).
    fx_enabled: bool = true,
    /// When true, post-FX/fader track audio sums directly into master (pre master FX).
    master_send_enabled: bool = true,
    /// When true, post-FX/fader audio is mixed AFTER master FX + master volume
    /// (reference / dry monitor path — does not eat master glue/limiter).
    post_master_enabled: bool = false,
    input_device: ?[]const u8 = null, // owned, if set -- §13 live input

    pub fn deinit(self: *Track, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.input_device) |d| gpa.free(d);
        for (self.clips.items) |*c| c.deinit(gpa);
        self.clips.deinit(gpa);
        for (self.effects.items) |*e| e.deinit(gpa);
        self.effects.deinit(gpa);
    }
};

pub const AudioSource = struct {
    id: AssetId,
    relative_path: []const u8, // owned, relative to the project directory
    sample_rate: u32,
    channels: u8,
    frame_count: u64,
    source_bpm: ?f64 = null,

    pub fn deinit(self: *AudioSource, gpa: std.mem.Allocator) void {
        gpa.free(self.relative_path);
    }
};

pub const Bus = struct {
    id: BusId,
    name: []const u8, // owned
    volume: f32 = 1.0,
    pan: f32 = 0.0,
    mute: bool = false,
    solo: bool = false,
    fx_enabled: bool = true,
    effects: std.ArrayList(Effect) = .empty,

    pub fn deinit(self: *Bus, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        for (self.effects.items) |*e| e.deinit(gpa);
        self.effects.deinit(gpa);
    }
};

pub const Send = struct {
    id: SendId,
    source_track_id: TrackId,
    destination_bus_id: BusId,
    gain_db: f32 = 0,
    tap: SendTap = .post_fader,
    enabled: bool = true,
};

pub const Project = struct {
    bpm: f64 = 120.0,
    bar_size: i64 = 4,
    bar_quant: i64 = 16,
    length_bars: i64 = 16,
    sample_rate: u32 = 44100,
    revision: u64 = 0,
    tracks: std.ArrayList(Track) = .empty,
    assets: std.ArrayList(AudioSource) = .empty,
    master_effects: std.ArrayList(Effect) = .empty,
    master_volume: f32 = 1.0,
    master_fx_enabled: bool = true,
    buses: std.ArrayList(Bus) = .empty,
    sends: std.ArrayList(Send) = .empty,

    pub fn deinit(self: *Project, gpa: std.mem.Allocator) void {
        for (self.tracks.items) |*t| t.deinit(gpa);
        self.tracks.deinit(gpa);
        for (self.assets.items) |*a| a.deinit(gpa);
        self.assets.deinit(gpa);
        for (self.master_effects.items) |*e| e.deinit(gpa);
        self.master_effects.deinit(gpa);
        for (self.buses.items) |*b| b.deinit(gpa);
        self.buses.deinit(gpa);
        self.sends.deinit(gpa);
    }

    pub fn findTrack(self: *Project, id: TrackId) ?*Track {
        for (self.tracks.items) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    pub fn findBus(self: *Project, id: BusId) ?*Bus {
        for (self.buses.items) |*b| {
            if (b.id == id) return b;
        }
        return null;
    }

    pub fn findSend(self: *Project, id: SendId) ?*Send {
        for (self.sends.items) |*s| {
            if (s.id == id) return s;
        }
        return null;
    }

    pub fn addBus(self: *Project, gpa: std.mem.Allocator, name: []const u8) !*Bus {
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try self.buses.append(gpa, .{
            .id = allocId(),
            .name = owned,
            .effects = .empty,
        });
        self.revision += 1;
        return &self.buses.items[self.buses.items.len - 1];
    }

    pub fn removeBus(self: *Project, gpa: std.mem.Allocator, id: BusId) bool {
        const bi = for (self.buses.items, 0..) |b, i| {
            if (b.id == id) break i;
        } else return false;
        // Cascade: drop sends targeting this bus.
        var si: usize = 0;
        while (si < self.sends.items.len) {
            if (self.sends.items[si].destination_bus_id == id) {
                _ = self.sends.orderedRemove(si);
            } else si += 1;
        }
        self.buses.items[bi].deinit(gpa);
        _ = self.buses.orderedRemove(bi);
        self.revision += 1;
        return true;
    }

    pub fn addSend(self: *Project, gpa: std.mem.Allocator, source_track_id: TrackId, destination_bus_id: BusId, gain_db: f32, tap: SendTap) !SendId {
        if (self.findTrack(source_track_id) == null) return error.TrackNotFound;
        if (self.findBus(destination_bus_id) == null) return error.BusNotFound;
        const sid = allocId();
        try self.sends.append(gpa, .{
            .id = sid,
            .source_track_id = source_track_id,
            .destination_bus_id = destination_bus_id,
            .gain_db = gain_db,
            .tap = tap,
            .enabled = true,
        });
        self.revision += 1;
        return sid;
    }

    pub fn removeSend(self: *Project, id: SendId) bool {
        for (self.sends.items, 0..) |s, i| {
            if (s.id == id) {
                _ = self.sends.orderedRemove(i);
                self.revision += 1;
                return true;
            }
        }
        return false;
    }

    pub fn addTrack(self: *Project, gpa: std.mem.Allocator, name: []const u8) !*Track {
        const owned_name = try gpa.dupe(u8, name);
        try self.tracks.append(gpa, .{
            .id = allocId(),
            .name = owned_name,
            .clips = .empty,
            .effects = .empty,
        });
        self.revision += 1;
        return &self.tracks.items[self.tracks.items.len - 1];
    }

    pub fn removeTrack(self: *Project, gpa: std.mem.Allocator, id: TrackId) bool {
        for (self.tracks.items, 0..) |*t, i| {
            if (t.id == id) {
                // Cascade: drop sends from this track.
                var si: usize = 0;
                while (si < self.sends.items.len) {
                    if (self.sends.items[si].source_track_id == id) {
                        _ = self.sends.orderedRemove(si);
                    } else si += 1;
                }
                t.deinit(gpa);
                _ = self.tracks.orderedRemove(i);
                self.revision += 1;
                return true;
            }
        }
        return false;
    }

    pub fn renameTrack(self: *Project, gpa: std.mem.Allocator, id: TrackId, new_name: []const u8) !void {
        const t = self.findTrack(id) orelse return error.TrackNotFound;
        if (new_name.len == 0) return error.EmptyName;
        const owned = try gpa.dupe(u8, new_name);
        gpa.free(t.name);
        t.name = owned;
        self.revision += 1;
    }

    /// Deep-copies clips/effects (new ids); audio clips keep the same `source_id`.
    pub fn duplicateTrack(self: *Project, gpa: std.mem.Allocator, id: TrackId) !*Track {
        const src = self.findTrack(id) orelse return error.TrackNotFound;
        const src_index = for (self.tracks.items, 0..) |t, i| {
            if (t.id == id) break i;
        } else return error.TrackNotFound;

        const owned_name = try std.fmt.allocPrint(gpa, "{s} copy", .{src.name});
        errdefer gpa.free(owned_name);

        var clips: std.ArrayList(Clip) = .empty;
        errdefer {
            for (clips.items) |*cl| cl.deinit(gpa);
            clips.deinit(gpa);
        }
        for (src.clips.items) |clip| {
            switch (clip) {
                .audio => |a| try clips.append(gpa, .{ .audio = .{
                    .id = allocId(),
                    .source_id = a.source_id,
                    .timeline_start_frame = a.timeline_start_frame,
                    .source_offset_frames = a.source_offset_frames,
                    .length_frames = a.length_frames,
                    .muted = a.muted,
                } }),
                .midi => |m| {
                    var events: std.ArrayList(Event) = .empty;
                    errdefer events.deinit(gpa);
                    try events.appendSlice(gpa, m.events.items);
                    try clips.append(gpa, .{ .midi = .{
                        .id = allocId(),
                        .start_bar = m.start_bar,
                        .bars = m.bars,
                        .events = events,
                    } });
                },
            }
        }

        var effects: std.ArrayList(Effect) = .empty;
        errdefer {
            for (effects.items) |*e| e.deinit(gpa);
            effects.deinit(gpa);
        }
        for (src.effects.items) |eff| {
            const params: @TypeOf(eff.params) = switch (eff.params) {
                .eq => |e| blk: {
                    var bands: std.ArrayList(EqBand) = .empty;
                    errdefer bands.deinit(gpa);
                    try bands.appendSlice(gpa, e.bands.items);
                    break :blk .{ .eq = .{ .bands = bands } };
                },
                .compressor => |p| .{ .compressor = p },
                .limiter => |p| .{ .limiter = p },
                .sidechain_compressor => |p| .{ .sidechain_compressor = p },
                .delay => |p| .{ .delay = p },
                .stereo_width => |p| .{ .stereo_width = p },
            };
            try effects.append(gpa, .{
                .id = allocId(),
                .bypassed = eff.bypassed,
                .params = params,
            });
        }

        const input_owned: ?[]const u8 = if (src.input_device) |d| try gpa.dupe(u8, d) else null;
        errdefer if (input_owned) |d| gpa.free(d);

        const copy: Track = .{
            .id = allocId(),
            .name = owned_name,
            .instrument = src.instrument,
            .clips = clips,
            .effects = effects,
            .volume = src.volume,
            .pan = src.pan,
            .mute = src.mute,
            .solo = src.solo,
            .armed = false,
            .fx_enabled = src.fx_enabled,
            .master_send_enabled = src.master_send_enabled,
            .post_master_enabled = src.post_master_enabled,
            .input_device = input_owned,
        };

        const insert_at = src_index + 1;
        try self.tracks.insert(gpa, insert_at, copy);
        self.revision += 1;
        return &self.tracks.items[insert_at];
    }

    pub fn findAsset(self: *const Project, id: AssetId) ?*const AudioSource {
        for (self.assets.items) |*a| {
            if (a.id == id) return a;
        }
        return null;
    }

    pub fn audioPlayableFrames(self: *const Project, ac: AudioClip) u64 {
        const asset = self.findAsset(ac.source_id) orelse return 0;
        if (ac.source_offset_frames >= asset.frame_count) return 0;
        const rem = asset.frame_count - ac.source_offset_frames;
        if (ac.length_frames) |l| return @min(l, rem);
        return rem;
    }

    pub fn findClip(self: *Project, track_id: TrackId, clip_id: ClipId) ?*Clip {
        const track = self.findTrack(track_id) orelse return null;
        for (track.clips.items) |*cl| {
            if (cl.id() == clip_id) return cl;
        }
        return null;
    }

    pub fn removeClip(self: *Project, gpa: std.mem.Allocator, track_id: TrackId, clip_id: ClipId) bool {
        const track = self.findTrack(track_id) orelse return false;
        for (track.clips.items, 0..) |*cl, i| {
            if (cl.id() == clip_id) {
                cl.deinit(gpa);
                _ = track.clips.orderedRemove(i);
                self.revision += 1;
                return true;
            }
        }
        return false;
    }

    pub fn duplicateClip(self: *Project, gpa: std.mem.Allocator, track_id: TrackId, clip_id: ClipId) !ClipId {
        const track = self.findTrack(track_id) orelse return error.TrackNotFound;
        const src_i = for (track.clips.items, 0..) |cl, i| {
            if (cl.id() == clip_id) break i;
        } else return error.ClipNotFound;
        const src = track.clips.items[src_i];
        const copy: Clip = switch (src) {
            .audio => |a| .{ .audio = .{
                .id = allocId(),
                .source_id = a.source_id,
                .timeline_start_frame = a.timeline_start_frame,
                .source_offset_frames = a.source_offset_frames,
                .length_frames = a.length_frames,
                .muted = a.muted,
            } },
            .midi => |m| blk: {
                var events: std.ArrayList(Event) = .empty;
                errdefer events.deinit(gpa);
                try events.appendSlice(gpa, m.events.items);
                break :blk .{ .midi = .{
                    .id = allocId(),
                    .start_bar = m.start_bar,
                    .bars = m.bars,
                    .events = events,
                } };
            },
        };
        const new_id = copy.id();
        try track.clips.insert(gpa, src_i + 1, copy);
        self.revision += 1;
        return new_id;
    }

    /// Split audio clip at absolute timeline frame. Left keeps start; right starts at `at_frame`.
    pub fn splitAudioAtFrame(self: *Project, gpa: std.mem.Allocator, track_id: TrackId, clip_id: ClipId, at_frame: i64) !void {
        const track = self.findTrack(track_id) orelse return error.TrackNotFound;
        const idx = for (track.clips.items, 0..) |cl, i| {
            if (cl.id() == clip_id) break i;
        } else return error.ClipNotFound;
        if (track.clips.items[idx] != .audio) return error.NotAudio;
        const ac = track.clips.items[idx].audio;
        const playable = self.audioPlayableFrames(ac);
        if (playable == 0) return error.EmptyClip;
        if (at_frame <= ac.timeline_start_frame) return error.BeforeClip;
        const rel: i64 = at_frame - ac.timeline_start_frame;
        if (rel <= 0 or @as(u64, @intCast(rel)) >= playable) return error.OutsideClip;
        const left_len: u64 = @intCast(rel);
        const right_len = playable - left_len;

        track.clips.items[idx].audio.length_frames = left_len;
        try track.clips.insert(gpa, idx + 1, .{ .audio = .{
            .id = allocId(),
            .source_id = ac.source_id,
            .timeline_start_frame = at_frame,
            .source_offset_frames = ac.source_offset_frames + left_len,
            .length_frames = right_len,
            .muted = ac.muted,
        } });
        self.revision += 1;
    }
};

// --- DTO layer: plain slices instead of ArrayList, for JSON (std.ArrayList has
// no jsonStringify/jsonParse hooks -- see spikes/spike_json.zig) and for undo
// snapshots (a naive `= project` struct copy aliases ArrayList memory instead
// of cloning it -- see spikes/spike_undo.zig, which found this breaks undo). ---

pub const EventDto = Event; // no nested allocations, safe to reuse directly

pub const MidiClipDto = struct { id: ClipId, start_bar: i64, bars: i64, events: []const EventDto };
pub const AudioClipDto = struct {
    id: ClipId,
    source_id: AssetId,
    timeline_start_frame: i64,
    source_offset_frames: u64 = 0,
    length_frames: ?u64 = null,
    muted: bool = false,
};
pub const ClipDto = union(enum) { midi: MidiClipDto, audio: AudioClipDto };

pub const EqParamsDto = struct { bands: []const EqBandDto };
pub const EffectDto = struct {
    id: EffectId,
    bypassed: bool = false,
    params: union(EffectKind) {
        eq: EqParamsDto,
        compressor: CompressorParams,
        limiter: LimiterParams,
        sidechain_compressor: SidechainParams,
        delay: DelayParams,
        stereo_width: StereoWidthParams,
    },
};

pub const BusDto = struct {
    id: BusId,
    name: []const u8,
    volume: f32 = 1.0,
    pan: f32 = 0.0,
    mute: bool = false,
    solo: bool = false,
    fx_enabled: bool = true,
    effects: []const EffectDto = &.{},
};

pub const SendDto = struct {
    id: SendId,
    source_track_id: TrackId,
    destination_bus_id: BusId,
    gain_db: f32 = 0,
    tap: SendTap = .post_fader,
    enabled: bool = true,
};

pub const TrackDto = struct {
    id: TrackId,
    name: []const u8,
    instrument: Instrument = .{},
    volume: f32 = 1.0,
    pan: f32 = 0.0,
    mute: bool = false,
    solo: bool = false,
    armed: bool = false,
    fx_enabled: bool = true,
    master_send_enabled: bool = true,
    post_master_enabled: bool = false,
    input_device: ?[]const u8 = null,
    clips: []const ClipDto,
    effects: []const EffectDto,
};

pub const AudioSourceDto = AudioSource;

pub const ProjectDto = struct {
    bpm: f64 = 120.0,
    bar_size: i64 = 4,
    bar_quant: i64 = 16,
    length_bars: i64 = 16,
    sample_rate: u32 = 44100,
    revision: u64 = 0,
    tracks: []const TrackDto,
    assets: []const AudioSourceDto,
    master_effects: []const EffectDto = &.{},
    master_volume: f32 = 1.0,
    master_fx_enabled: bool = true,
    buses: []const BusDto = &.{},
    sends: []const SendDto = &.{},
};

pub const ProjectFile = struct {
    format: []const u8 = "fastmix-ai-project",
    version: u32 = 1,
    project: ProjectDto,
};

/// Deep-clones `project` into a DTO tree, allocated fresh from `gpa`. Caller
/// owns the result and must free it with `freeProjectDto`.
pub fn toDto(gpa: std.mem.Allocator, project: *const Project) !ProjectDto {
    const tracks = try gpa.alloc(TrackDto, project.tracks.items.len);
    errdefer gpa.free(tracks);
    for (project.tracks.items, 0..) |t, ti| {
        const clips = try gpa.alloc(ClipDto, t.clips.items.len);
        for (t.clips.items, 0..) |c, ci| {
            clips[ci] = switch (c) {
                .midi => |m| .{ .midi = .{ .id = m.id, .start_bar = m.start_bar, .bars = m.bars, .events = try gpa.dupe(Event, m.events.items) } },
                .audio => |a| .{ .audio = .{
                    .id = a.id,
                    .source_id = a.source_id,
                    .timeline_start_frame = a.timeline_start_frame,
                    .source_offset_frames = a.source_offset_frames,
                    .length_frames = a.length_frames,
                    .muted = a.muted,
                } },
            };
        }
        const effects = try gpa.alloc(EffectDto, t.effects.items.len);
        for (t.effects.items, 0..) |e, ei| {
            effects[ei] = try effectToDto(gpa, e);
        }
        tracks[ti] = .{
            .id = t.id,
            .name = try gpa.dupe(u8, t.name),
            .instrument = t.instrument,
            .volume = t.volume,
            .pan = t.pan,
            .mute = t.mute,
            .solo = t.solo,
            .armed = t.armed,
            .fx_enabled = t.fx_enabled,
            .master_send_enabled = t.master_send_enabled,
            .post_master_enabled = t.post_master_enabled,
            .input_device = if (t.input_device) |d| try gpa.dupe(u8, d) else null,
            .clips = clips,
            .effects = effects,
        };
    }
    const assets = try gpa.alloc(AudioSourceDto, project.assets.items.len);
    for (project.assets.items, 0..) |a, ai| {
        assets[ai] = .{
            .id = a.id,
            .relative_path = try gpa.dupe(u8, a.relative_path),
            .sample_rate = a.sample_rate,
            .channels = a.channels,
            .frame_count = a.frame_count,
            .source_bpm = a.source_bpm,
        };
    }
    const master_effects = try gpa.alloc(EffectDto, project.master_effects.items.len);
    for (project.master_effects.items, 0..) |e, ei| {
        master_effects[ei] = try effectToDto(gpa, e);
    }
    const buses = try gpa.alloc(BusDto, project.buses.items.len);
    for (project.buses.items, 0..) |b, bi| {
        const beffects = try gpa.alloc(EffectDto, b.effects.items.len);
        for (b.effects.items, 0..) |e, ei| {
            beffects[ei] = try effectToDto(gpa, e);
        }
        buses[bi] = .{
            .id = b.id,
            .name = try gpa.dupe(u8, b.name),
            .volume = b.volume,
            .pan = b.pan,
            .mute = b.mute,
            .solo = b.solo,
            .fx_enabled = b.fx_enabled,
            .effects = beffects,
        };
    }
    const sends = try gpa.alloc(SendDto, project.sends.items.len);
    for (project.sends.items, 0..) |s, si| {
        sends[si] = .{
            .id = s.id,
            .source_track_id = s.source_track_id,
            .destination_bus_id = s.destination_bus_id,
            .gain_db = s.gain_db,
            .tap = s.tap,
            .enabled = s.enabled,
        };
    }
    return .{
        .bpm = project.bpm,
        .bar_size = project.bar_size,
        .bar_quant = project.bar_quant,
        .length_bars = project.length_bars,
        .sample_rate = project.sample_rate,
        .revision = project.revision,
        .tracks = tracks,
        .assets = assets,
        .master_effects = master_effects,
        .master_volume = project.master_volume,
        .master_fx_enabled = project.master_fx_enabled,
        .buses = buses,
        .sends = sends,
    };
}

fn effectToDto(gpa: std.mem.Allocator, e: Effect) !EffectDto {
    return .{
        .id = e.id,
        .bypassed = e.bypassed,
        .params = switch (e.params) {
            .eq => |eq| blk: {
                const bands = try gpa.alloc(EqBandDto, eq.bands.items.len);
                for (eq.bands.items, 0..) |b, i| bands[i] = EqBandDto.fromBand(b);
                break :blk .{ .eq = .{ .bands = bands } };
            },
            .compressor => |p| .{ .compressor = p },
            .limiter => |p| .{ .limiter = p },
            .sidechain_compressor => |p| .{ .sidechain_compressor = p },
            .delay => |p| .{ .delay = p },
            .stereo_width => |p| .{ .stereo_width = p },
        },
    };
}

fn effectFromDto(gpa: std.mem.Allocator, e: EffectDto) !Effect {
    return .{
        .id = e.id,
        .bypassed = e.bypassed,
        .params = switch (e.params) {
            .eq => |eq| blk: {
                var bands: std.ArrayList(EqBand) = .empty;
                errdefer bands.deinit(gpa);
                for (eq.bands) |bd| {
                    const band = bd.toBand() catch return error.MissingBandFreq;
                    try bands.append(gpa, band);
                }
                break :blk .{ .eq = .{ .bands = bands } };
            },
            .compressor => |p| .{ .compressor = p },
            .limiter => |p| blk: {
                var lp = p;
                normalizeLimiterParams(&lp);
                break :blk .{ .limiter = lp };
            },
            .sidechain_compressor => |p| .{ .sidechain_compressor = p },
            .delay => |p| .{ .delay = p },
            .stereo_width => |p| .{ .stereo_width = p },
        },
    };
}

pub fn freeProjectDto(gpa: std.mem.Allocator, dto: *const ProjectDto) void {
    for (dto.tracks) |t| {
        gpa.free(t.name);
        if (t.input_device) |d| gpa.free(d);
        for (t.clips) |c| switch (c) {
            .midi => |m| gpa.free(m.events),
            .audio => {},
        };
        gpa.free(t.clips);
        for (t.effects) |e| switch (e.params) {
            .eq => |eq| gpa.free(eq.bands),
            else => {},
        };
        gpa.free(t.effects);
    }
    gpa.free(dto.tracks);
    for (dto.assets) |a| gpa.free(a.relative_path);
    gpa.free(dto.assets);
    for (dto.master_effects) |e| switch (e.params) {
        .eq => |eq| gpa.free(eq.bands),
        else => {},
    };
    gpa.free(dto.master_effects);
    for (dto.buses) |b| {
        gpa.free(b.name);
        for (b.effects) |e| switch (e.params) {
            .eq => |eq| gpa.free(eq.bands),
            else => {},
        };
        gpa.free(b.effects);
    }
    gpa.free(dto.buses);
    gpa.free(dto.sends);
}

/// Deep-clones a DTO tree back into a live `Project` (owning ArrayLists).
/// Used by both Load and Undo/Redo (see spikes/spike_undo.zig).
pub fn fromDto(gpa: std.mem.Allocator, dto: ProjectDto) !Project {
    var project: Project = .{
        .bpm = dto.bpm,
        .bar_size = dto.bar_size,
        .bar_quant = dto.bar_quant,
        .length_bars = dto.length_bars,
        .sample_rate = dto.sample_rate,
        .revision = dto.revision,
        .master_volume = dto.master_volume,
        .master_fx_enabled = dto.master_fx_enabled,
    };
    for (dto.tracks) |t| {
        var clips: std.ArrayList(Clip) = .empty;
        for (t.clips) |c| {
            const clip: Clip = switch (c) {
                .midi => |m| .{ .midi = .{ .id = m.id, .start_bar = m.start_bar, .bars = m.bars, .events = blk: {
                    var events: std.ArrayList(Event) = .empty;
                    try events.appendSlice(gpa, m.events);
                    break :blk events;
                } } },
                .audio => |a| .{ .audio = .{
                    .id = a.id,
                    .source_id = a.source_id,
                    .timeline_start_frame = a.timeline_start_frame,
                    .source_offset_frames = a.source_offset_frames,
                    .length_frames = a.length_frames,
                    .muted = a.muted,
                } },
            };
            try clips.append(gpa, clip);
        }
        var effects: std.ArrayList(Effect) = .empty;
        for (t.effects) |e| {
            try effects.append(gpa, try effectFromDto(gpa, e));
        }
        try project.tracks.append(gpa, .{
            .id = t.id,
            .name = try gpa.dupe(u8, t.name),
            .instrument = t.instrument,
            .volume = t.volume,
            .pan = t.pan,
            .mute = t.mute,
            .solo = t.solo,
            .armed = t.armed,
            .fx_enabled = t.fx_enabled,
            .master_send_enabled = t.master_send_enabled,
            .post_master_enabled = t.post_master_enabled,
            .input_device = if (t.input_device) |d| try gpa.dupe(u8, d) else null,
            .clips = clips,
            .effects = effects,
        });
    }
    for (dto.assets) |a| {
        try project.assets.append(gpa, .{
            .id = a.id,
            .relative_path = try gpa.dupe(u8, a.relative_path),
            .sample_rate = a.sample_rate,
            .channels = a.channels,
            .frame_count = a.frame_count,
            .source_bpm = a.source_bpm,
        });
    }
    for (dto.master_effects) |e| {
        try project.master_effects.append(gpa, try effectFromDto(gpa, e));
    }
    for (dto.buses) |b| {
        var effects: std.ArrayList(Effect) = .empty;
        for (b.effects) |e| {
            try effects.append(gpa, try effectFromDto(gpa, e));
        }
        try project.buses.append(gpa, .{
            .id = b.id,
            .name = try gpa.dupe(u8, b.name),
            .volume = b.volume,
            .pan = b.pan,
            .mute = b.mute,
            .solo = b.solo,
            .fx_enabled = b.fx_enabled,
            .effects = effects,
        });
    }
    for (dto.sends) |s| {
        try project.sends.append(gpa, .{
            .id = s.id,
            .source_track_id = s.source_track_id,
            .destination_bus_id = s.destination_bus_id,
            .gain_db = s.gain_db,
            .tap = s.tap,
            .enabled = s.enabled,
        });
    }
    syncIdCounter(&project);
    return project;
}

/// After load/undo, bump the global id allocator past any ID already in use.
pub fn syncIdCounter(project: *const Project) void {
    var max_id: u64 = 0;
    for (project.tracks.items) |t| {
        if (t.id > max_id) max_id = t.id;
        for (t.clips.items) |c| {
            const cid = c.id();
            if (cid > max_id) max_id = cid;
        }
        for (t.effects.items) |e| {
            if (e.id > max_id) max_id = e.id;
        }
    }
    for (project.master_effects.items) |e| {
        if (e.id > max_id) max_id = e.id;
    }
    for (project.buses.items) |b| {
        if (b.id > max_id) max_id = b.id;
        for (b.effects.items) |e| {
            if (e.id > max_id) max_id = e.id;
        }
    }
    for (project.sends.items) |s| {
        if (s.id > max_id) max_id = s.id;
    }
    for (project.assets.items) |a| {
        if (a.id > max_id) max_id = a.id;
    }
    if (max_id + 1 > next_id) next_id = max_id + 1;
}
