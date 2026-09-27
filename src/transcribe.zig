const std = @import("std");
const model = @import("model.zig");
const jobs = @import("jobs.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

// Automatic stem transcription (audio -> note events), offline.
//
// One Python worker (tools/transcribe/transcribe_stem.py: Basic Pitch + the
// octave/fifth ghost filter from spikes/transcribe_octave_filter.py) handles
// all pitched stems (drums via a band-onset heuristic) and writes <asset_id>.notes.json per stem. The main loop
// polls for those files and, per finished stem, inserts a muted
// "<stem> (MIDI)" track right under it holding a MidiClip, so the built-in
// synth can play it (solo the track) and it saves/loads like any MIDI clip.
//
// Notes are quantized to the project grid (bar_quant) because MidiClip is in
// musical time; the frame-accurate result stays in the .notes.json / .mid.

pub const WORKER_SCRIPT = "tools/transcribe/transcribe_stem.py";
pub const DEFAULT_PYTHON = ".venv-transcribe/bin/python";

pub const Kind = enum { melodic, drums };

/// Suno 8-stem naming: pitched parts -> Basic Pitch, drums -> band-onset
/// heuristic (GM kick/snare/hi-hat); backing vocals and "other" are skipped.
pub fn stemKind(track_name: []const u8) ?Kind {
    var buf: [256]u8 = undefined;
    const n = @min(track_name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], track_name[0..n]);
    const skip = [_][]const u8{ "backing", "other", "(midi)" };
    for (skip) |s| if (std.mem.indexOf(u8, lower, s) != null) return null;
    if (std.mem.indexOf(u8, lower, "drum") != null or std.mem.indexOf(u8, lower, "perc") != null) return .drums;
    const want = [_][]const u8{ "bass", "vocal", "guitar", "synth", "keys", "piano", "woodwind", "brass", "string" };
    for (want) |s| if (std.mem.indexOf(u8, lower, s) != null) return .melodic;
    return null;
}

pub const State = enum { idle, running, done, failed, no_worker };

const Item = struct {
    stem_track_id: model.TrackId,
    asset_id: model.AssetId,
    applied: bool = false,
};

pub const Session = struct {
    items: std.ArrayList(Item) = .empty,
    registry: jobs.Registry = .{},
    job_id: ?jobs.JobId = null,
    out_dir: []const u8 = "",
    state: State = .idle,
    applied_count: usize = 0,

    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.registry.deinit(gpa);
        if (self.out_dir.len > 0) gpa.free(self.out_dir);
        self.* = .{};
    }

    /// Starts the worker for every transcribable stem in `project`. Non-blocking.
    /// `out_dir` must exist (the bootstrap cache dir).
    pub fn start(self: *Session, gpa: std.mem.Allocator, io: std.Io, project: *const model.Project, out_dir: []const u8) !void {
        self.deinit(gpa);
        self.out_dir = try gpa.dupe(u8, out_dir);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |s| gpa.free(s);
            owned.deinit(gpa);
        }

        const python: []const u8 = if (c.getenv("FASTMIX_TRANSCRIBE_PYTHON")) |p| std.mem.span(p) else DEFAULT_PYTHON;
        var py_buf: [1024]u8 = undefined;
        const py_z = try std.fmt.bufPrintZ(&py_buf, "{s}", .{python});
        if (c.access(py_z.ptr, c.X_OK) != 0) {
            std.debug.print("transcribe: no worker python at {s} -- run scripts/setup_transcribe.sh\n", .{python});
            self.state = .no_worker;
            return;
        }
        try argv.appendSlice(gpa, &.{ python, WORKER_SCRIPT, self.out_dir });

        for (project.tracks.items) |track| {
            const kind = stemKind(track.name) orelse continue;
            const asset_id = firstAudioAsset(track) orelse continue;
            const asset = findAsset(project, asset_id) orelse continue;
            const arg = try std.fmt.allocPrint(gpa, "{s}:{d}:{s}", .{ asset.relative_path, asset_id, @tagName(kind) });
            try owned.append(gpa, arg);
            try argv.append(gpa, arg);
            try self.items.append(gpa, .{ .stem_track_id = track.id, .asset_id = asset_id });
        }
        if (self.items.items.len == 0) {
            self.state = .done;
            return;
        }
        self.job_id = try self.registry.spawnLogged(gpa, io, argv.items);
        self.state = .running;
        std.debug.print("transcribe: started for {d} stems\n", .{self.items.items.len});
    }

    /// Call once per frame from the main loop. Returns true if tracks were
    /// inserted. `can_mutate` = false defers insertion (e.g. offline render
    /// thread currently reading the project).
    pub fn poll(self: *Session, gpa: std.mem.Allocator, project: *model.Project, can_mutate: bool) bool {
        if (self.state != .running) return false;
        self.registry.poll();
        const finished = if (self.job_id) |id| (self.registry.find(id).?.status != .running) else true;

        var changed = false;
        if (can_mutate) {
            for (self.items.items) |*item| {
                if (item.applied) continue;
                var path_buf: [1024]u8 = undefined;
                const path = std.fmt.bufPrintZ(&path_buf, "{s}/{d}.notes.json", .{ self.out_dir, item.asset_id }) catch continue;
                if (c.access(path.ptr, c.R_OK) != 0) continue;
                item.applied = true;
                insertMidiTrack(gpa, project, item.stem_track_id, path) catch |err| {
                    std.debug.print("transcribe: could not apply {s}: {}\n", .{ path, err });
                    continue;
                };
                self.applied_count += 1;
                changed = true;
            }
        }
        if (finished and can_mutate) {
            self.state = if (self.applied_count > 0) .done else .failed;
            std.debug.print("transcribe: finished, {d}/{d} stems\n", .{ self.applied_count, self.items.items.len });
        }
        return changed;
    }

    /// Short status for the transport clock line, or null when idle.
    pub fn statusText(self: *const Session, buf: []u8) ?[]const u8 {
        return switch (self.state) {
            .idle => null,
            .running => std.fmt.bufPrint(buf, "TRANSCRIBE {d}/{d}", .{ self.applied_count, self.items.items.len }) catch null,
            .done => std.fmt.bufPrint(buf, "MIDI {d}/{d}", .{ self.applied_count, self.items.items.len }) catch null,
            .failed => "TRANSCRIBE FAILED",
            .no_worker => "NO TRANSCRIBE WORKER",
        };
    }
};

fn firstAudioAsset(track: model.Track) ?model.AssetId {
    for (track.clips.items) |clip| switch (clip) {
        .audio => |a| return a.source_id,
        .midi => {},
    };
    return null;
}

fn findAsset(project: *const model.Project, id: model.AssetId) ?model.AudioSource {
    for (project.assets.items) |a| if (a.id == id) return a;
    return null;
}

const NotesFile = struct { notes: []const [4]f64 };

fn readFileAlloc(gpa: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const f = c.fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    _ = c.fseek(f, 0, c.SEEK_END);
    const size: usize = @intCast(c.ftell(f));
    _ = c.fseek(f, 0, c.SEEK_SET);
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    if (c.fread(buf.ptr, 1, size, f) != size) return error.ShortRead;
    return buf;
}

/// Note events (seconds, relative to the stem's source start) -> quantized
/// MidiClip events on the project timeline. Off-before-on at equal quant so a
/// repeated pitch retriggers instead of being cut by its predecessor's release.
pub fn notesToEvents(gpa: std.mem.Allocator, notes: []const [4]f64, offset_sec: f64, quant_sec: f64) !std.ArrayList(model.Event) {
    var events: std.ArrayList(model.Event) = .empty;
    errdefer events.deinit(gpa);
    for (notes) |n| {
        const q0: i64 = @intFromFloat(@round((n[0] + offset_sec) / quant_sec));
        if (q0 < 0) continue;
        const q1: i64 = @max(q0 + 1, @as(i64, @intFromFloat(@round((n[1] + offset_sec) / quant_sec))));
        const semitone: i32 = @as(i32, @intFromFloat(n[2])) - 69; // synth root = A4
        const vel: f32 = @floatCast(std.math.clamp(n[3], 0.0, 1.0));
        try events.append(gpa, .{ .quant = q0, .semitone = semitone, .start = true, .velocity = vel });
        try events.append(gpa, .{ .quant = q1, .semitone = semitone, .start = false, .velocity = vel });
    }
    std.mem.sort(model.Event, events.items, {}, struct {
        fn lessThan(_: void, a: model.Event, b: model.Event) bool {
            if (a.quant != b.quant) return a.quant < b.quant;
            return !a.start and b.start;
        }
    }.lessThan);
    return events;
}

fn insertMidiTrack(gpa: std.mem.Allocator, project: *model.Project, stem_track_id: model.TrackId, notes_path: [*:0]const u8) !void {
    const raw = try readFileAlloc(gpa, notes_path);
    defer gpa.free(raw);
    const parsed = try std.json.parseFromSlice(NotesFile, gpa, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.notes.len == 0) return error.NoNotes; // near-silent stem: no empty track

    var stem_index: ?usize = null;
    for (project.tracks.items, 0..) |t, i| if (t.id == stem_track_id) {
        stem_index = i;
    };
    const idx = stem_index orelse return error.StemTrackGone;

    // Follow the stem clip's placement (ALIGN may have moved it).
    var offset_sec: f64 = 0;
    for (project.tracks.items[idx].clips.items) |clip| switch (clip) {
        .audio => |a| {
            const off_frames = a.timeline_start_frame - @as(i64, @intCast(a.source_offset_frames));
            offset_sec = @as(f64, @floatFromInt(off_frames)) / @as(f64, @floatFromInt(project.sample_rate));
            break;
        },
        .midi => {},
    };

    const bar_sec = 60.0 / project.bpm * @as(f64, @floatFromInt(project.bar_size));
    const quant_sec = bar_sec / @as(f64, @floatFromInt(project.bar_quant));
    var events = try notesToEvents(gpa, parsed.value.notes, offset_sec, quant_sec);
    errdefer events.deinit(gpa);
    const last_quant: i64 = if (events.items.len > 0) events.items[events.items.len - 1].quant else 0;
    const bars = @max(project.length_bars, @divFloor(last_quant, project.bar_quant) + 1);

    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s} (MIDI)", .{project.tracks.items[idx].name}) catch "Transcription (MIDI)";
    const track = try project.addTrack(gpa, name);
    track.mute = true; // a sine synth over the real stems is noise; solo to listen
    try track.clips.append(gpa, .{ .midi = .{ .id = model.allocId(), .start_bar = 0, .bars = bars, .events = events } });

    // addTrack appended at the end; move it right under its stem.
    const new_track = project.tracks.pop().?;
    try project.tracks.insert(gpa, idx + 1, new_track);
}

test "stemKind follows Suno stem names" {
    try std.testing.expectEqual(Kind.melodic, stemKind("3 Bass").?);
    try std.testing.expectEqual(Kind.melodic, stemKind("0 Lead Vocals").?);
    try std.testing.expectEqual(Kind.melodic, stemKind("7 Woodwinds").?);
    try std.testing.expectEqual(Kind.drums, stemKind("2 Drums").?);
    try std.testing.expect(stemKind("1 Backing Vocals") == null);
    try std.testing.expect(stemKind("6 Other") == null);
    try std.testing.expect(stemKind("2 Drums (MIDI)") == null);
}

test "notesToEvents quantizes and orders off before on" {
    const gpa = std.testing.allocator;
    // 120 BPM, 4/4, 16 quants/bar -> 0.125 s per quant
    const notes = [_][4]f64{ .{ 0.0, 0.25, 40, 0.9 }, .{ 0.25, 0.5, 40, 0.5 } };
    var ev = try notesToEvents(gpa, &notes, 0, 0.125);
    defer ev.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), ev.items.len);
    try std.testing.expectEqual(@as(i64, 0), ev.items[0].quant);
    try std.testing.expectEqual(@as(i32, 40 - 69), ev.items[0].semitone);
    // at quant 2: first note's off must precede second note's on
    try std.testing.expect(!ev.items[1].start and ev.items[1].quant == 2);
    try std.testing.expect(ev.items[2].start and ev.items[2].quant == 2);
}
