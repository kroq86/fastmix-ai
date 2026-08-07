const std = @import("std");

// Spike: the actual core data model from roadmap §1/§14 has only ever existed
// as prose/code-blocks in the spec -- never compiled, never round-tripped.
// Two specific things were never verified:
//   1. std.json serialization of a *tagged union* (ClipContent, Effect) --
//      every previous JSON spike (spike_json.zig) only tested plain structs
//      with ArrayList fields. Unions are a different code path in std.json.
//   2. That ID-based lookup (TrackId -> *Track) is actually index-independent
//      -- the whole point of stable IDs (§1) is that a track's position in
//      the array can change without breaking references to it by ID.
// This is the last piece needed before the "stable core" the user is asking
// about can be considered proven, not just designed.

const TrackId = u64;
const ClipId = u64;
const EffectId = u64;

const EffectKind = enum { eq, compressor, sidechain_compressor };
const EqParams = struct { gain_db: f32 };
const CompressorParams = struct { threshold_db: f32, ratio: f32 };
const SidechainParams = struct { source_track_id: TrackId, threshold_db: f32, ratio: f32 };

const Effect = union(EffectKind) {
    eq: EqParams,
    compressor: CompressorParams,
    sidechain_compressor: SidechainParams,
};

const EventDto = struct { quant: i64, semitone: i32, start: bool };
const MidiClipDto = struct { start_bar: i64, bars: i64, events: []const EventDto };
const AudioClipDto = struct { source_asset: []const u8, timeline_start_frame: i64 };

const ClipContent = union(enum) {
    midi: MidiClipDto,
    audio: AudioClipDto,
};

const ClipDto = struct { id: ClipId, content: ClipContent };
const TrackDto = struct { id: TrackId, name: []const u8, clips: []const ClipDto, effects: []const Effect };
const ProjectDto = struct { tracks: []const TrackDto };

fn findTrackById(tracks: []const TrackDto, id: TrackId) ?*const TrackDto {
    for (tracks) |*t| {
        if (t.id == id) return t;
    }
    return null;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.debug.print("=== test 1: union(enum) round-trip through std.json ===\n", .{});

    const drums_clips = [_]ClipDto{
        .{ .id = 100, .content = .{ .midi = .{ .start_bar = 0, .bars = 1, .events = &[_]EventDto{
            .{ .quant = 0, .semitone = 3, .start = true },
        } } } },
    };
    const bass_clips = [_]ClipDto{
        .{ .id = 200, .content = .{ .audio = .{ .source_asset = "audio/bass.wav", .timeline_start_frame = 44100 } } },
    };
    const bass_effects = [_]Effect{
        .{ .sidechain_compressor = .{ .source_track_id = 1, .threshold_db = -18, .ratio = 8 } },
    };

    const project = ProjectDto{
        .tracks = &[_]TrackDto{
            .{ .id = 1, .name = "drums", .clips = &drums_clips, .effects = &[_]Effect{} },
            .{ .id = 2, .name = "bass", .clips = &bass_clips, .effects = &bass_effects },
        },
    };

    const text = try std.json.Stringify.valueAlloc(gpa, project, .{ .whitespace = .indent_2 });
    defer gpa.free(text);
    std.debug.print("serialized:\n{s}\n", .{text});

    const parsed = try std.json.parseFromSlice(ProjectDto, gpa, text, .{});
    defer parsed.deinit();
    const loaded = parsed.value;

    if (loaded.tracks.len != 2) {
        std.debug.print("FAIL: expected 2 tracks, got {}\n", .{loaded.tracks.len});
        return error.TrackCountMismatch;
    }

    // Verify the MIDI clip's union variant survived the round-trip correctly.
    const drums = findTrackById(loaded.tracks, 1) orelse return error.TrackNotFound;
    switch (drums.clips[0].content) {
        .midi => |m| {
            std.debug.print("drums clip 0 round-tripped as .midi: start_bar={} events[0].semitone={}\n", .{ m.start_bar, m.events[0].semitone });
            if (m.events[0].semitone != 3) return error.EventDataCorrupted;
        },
        .audio => {
            std.debug.print("FAIL: drums clip round-tripped as .audio instead of .midi -- union tag lost!\n", .{});
            return error.UnionTagLost;
        },
    }

    // Verify the audio clip's union variant AND the sidechain effect's
    // source_track_id (a stable ID, not an index) both survived.
    const bass = findTrackById(loaded.tracks, 2) orelse return error.TrackNotFound;
    switch (bass.clips[0].content) {
        .audio => |a| std.debug.print("bass clip 0 round-tripped as .audio: source_asset={s} frame={}\n", .{ a.source_asset, a.timeline_start_frame }),
        .midi => {
            std.debug.print("FAIL: bass clip round-tripped as .midi instead of .audio -- union tag lost!\n", .{});
            return error.UnionTagLost;
        },
    }
    switch (bass.effects[0]) {
        .sidechain_compressor => |sc| {
            std.debug.print("bass effect 0 round-tripped as .sidechain_compressor: source_track_id={}\n", .{sc.source_track_id});
            if (sc.source_track_id != 1) return error.EffectDataCorrupted;
        },
        else => {
            std.debug.print("FAIL: bass effect round-tripped as wrong union variant\n", .{});
            return error.UnionTagLost;
        },
    }
    std.debug.print("PASS: tagged unions (ClipContent, Effect) round-trip correctly through std.json.\n", .{});

    std.debug.print("\n=== test 2: ID-based lookup is index-independent ===\n", .{});
    {
        // Simulate what §1's stable-ID design is FOR: reorder tracks in the
        // array (as if a track got removed/reinserted) and confirm looking
        // up by ID still finds the right track, unlike a raw index would.
        const reordered = ProjectDto{
            .tracks = &[_]TrackDto{
                loaded.tracks[1], // "bass" (id=2) now at index 0
                loaded.tracks[0], // "drums" (id=1) now at index 1
            },
        };
        const found_by_id_1 = findTrackById(reordered.tracks, 1) orelse return error.TrackNotFound;
        const found_by_id_2 = findTrackById(reordered.tracks, 2) orelse return error.TrackNotFound;

        std.debug.print("after reordering: id=1 resolves to name={s} (index {})\n", .{ found_by_id_1.name, indexOf(reordered.tracks, found_by_id_1) });
        std.debug.print("after reordering: id=2 resolves to name={s} (index {})\n", .{ found_by_id_2.name, indexOf(reordered.tracks, found_by_id_2) });

        if (!std.mem.eql(u8, found_by_id_1.name, "drums") or !std.mem.eql(u8, found_by_id_2.name, "bass")) {
            std.debug.print("FAIL: ID lookup returned the wrong track after reordering\n", .{});
            return error.IdLookupBroken;
        }
        // The whole point: if sidechain_compressor's source_track_id had
        // instead been stored as a raw array INDEX (the old, rejected
        // design), this same reorder would have silently pointed the effect
        // at "bass" (itself) instead of "drums" -- exactly the bug class §1
        // was written to prevent. Confirmed the ID-based version survives it.
        std.debug.print("PASS: ID-based references survive array reordering; index-based ones would not have.\n", .{});
    }

    std.debug.print("\nPASS overall: the core data model (stable IDs + tagged-union clip/effect content)\n", .{});
    std.debug.print("compiles, round-trips through JSON correctly, and ID lookups are reorder-safe.\n", .{});
}

fn indexOf(tracks: []const TrackDto, target: *const TrackDto) usize {
    for (tracks, 0..) |*t, i| {
        if (t == target) return i;
    }
    return std.math.maxInt(usize);
}
