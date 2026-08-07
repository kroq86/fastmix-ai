const std = @import("std");

// Spike: does a Project{ tracks: std.ArrayList(Track) } struct roundtrip
// cleanly through std.json, or does ArrayList's internal shape (`items` +
// `capacity`, no custom jsonStringify hook) leak into the file format?
// Verified by grep: std/array_list.zig defines no jsonStringify/jsonParse,
// so std.json will just walk its fields reflectively.

const Event = struct {
    quant: i64,
    semitone: i32,
    start: bool,
    velocity: f32 = 1.0,
};

// --- Attempt A: naive, ArrayList directly in the struct ---
const ClipNaive = struct {
    start_bar: i64,
    bars: i64,
    events: std.ArrayList(Event),
};
const TrackNaive = struct {
    name: []const u8,
    volume: f32,
    clips: std.ArrayList(ClipNaive),
};
const ProjectNaive = struct {
    bpm: f64,
    tracks: std.ArrayList(TrackNaive),
};

// --- Attempt B: plain-slice DTO for serialization, ArrayList for runtime ---
const ClipFile = struct {
    start_bar: i64,
    bars: i64,
    events: []const Event,
};
const TrackFile = struct {
    name: []const u8,
    volume: f32,
    clips: []const ClipFile,
};
const ProjectFile = struct {
    bpm: f64,
    tracks: []const TrackFile,
};

const Clip = struct {
    start_bar: i64,
    bars: i64,
    events: std.ArrayList(Event),
};
const Track = struct {
    name: []const u8,
    volume: f32,
    clips: std.ArrayList(Clip),
};
const Project = struct {
    bpm: f64,
    tracks: std.ArrayList(Track),

    fn toFile(self: *const Project, gpa: std.mem.Allocator) !ProjectFile {
        var tracks = try gpa.alloc(TrackFile, self.tracks.items.len);
        for (self.tracks.items, 0..) |*t, ti| {
            var clips = try gpa.alloc(ClipFile, t.clips.items.len);
            for (t.clips.items, 0..) |*cl, ci| {
                clips[ci] = .{ .start_bar = cl.start_bar, .bars = cl.bars, .events = cl.events.items };
            }
            tracks[ti] = .{ .name = t.name, .volume = t.volume, .clips = clips };
        }
        return .{ .bpm = self.bpm, .tracks = tracks };
    }

    fn fromFile(pf: ProjectFile, gpa: std.mem.Allocator) !Project {
        var tracks: std.ArrayList(Track) = .empty;
        for (pf.tracks) |tf| {
            var clips: std.ArrayList(Clip) = .empty;
            for (tf.clips) |cf| {
                var events: std.ArrayList(Event) = .empty;
                try events.appendSlice(gpa, cf.events);
                try clips.append(gpa, .{ .start_bar = cf.start_bar, .bars = cf.bars, .events = events });
            }
            try tracks.append(gpa, .{ .name = tf.name, .volume = tf.volume, .clips = clips });
        }
        return .{ .bpm = pf.bpm, .tracks = tracks };
    }
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.debug.print("=== Attempt A: naive ArrayList-in-struct ===\n", .{});
    {
        var project: ProjectNaive = .{ .bpm = 120.0, .tracks = .empty };
        var clips: std.ArrayList(ClipNaive) = .empty;
        var events: std.ArrayList(Event) = .empty;
        try events.append(gpa, .{ .quant = 0, .semitone = 3, .start = true });
        try clips.append(gpa, .{ .start_bar = 0, .bars = 1, .events = events });
        try project.tracks.append(gpa, .{ .name = "lead", .volume = 1.0, .clips = clips });

        const text = try std.json.Stringify.valueAlloc(gpa, project, .{});
        defer gpa.free(text);
        std.debug.print("naive JSON: {s}\n", .{text});
        std.debug.print("(note whether \"capacity\" leaked into the output above)\n", .{});

        // cleanup
        for (project.tracks.items) |*t| {
            for (t.clips.items) |*cl| cl.events.deinit(gpa);
            t.clips.deinit(gpa);
        }
        project.tracks.deinit(gpa);
    }

    std.debug.print("\n=== Attempt B: ArrayList <-> plain-slice DTO ===\n", .{});
    {
        var project: Project = .{ .bpm = 140.0, .tracks = .empty };
        var clips: std.ArrayList(Clip) = .empty;
        var events: std.ArrayList(Event) = .empty;
        try events.append(gpa, .{ .quant = 0, .semitone = 3, .start = true });
        try events.append(gpa, .{ .quant = 4, .semitone = 3, .start = false, .velocity = 0.8 });
        try clips.append(gpa, .{ .start_bar = 2, .bars = 1, .events = events });
        try project.tracks.append(gpa, .{ .name = "bass", .volume = 0.9, .clips = clips });

        const file_view = try project.toFile(gpa);
        defer {
            for (file_view.tracks) |tf| gpa.free(tf.clips);
            gpa.free(file_view.tracks);
        }

        const text = try std.json.Stringify.valueAlloc(gpa, file_view, .{ .whitespace = .indent_2 });
        defer gpa.free(text);
        std.debug.print("DTO JSON:\n{s}\n", .{text});

        // cleanup original
        for (project.tracks.items) |*t| {
            for (t.clips.items) |*cl| cl.events.deinit(gpa);
            t.clips.deinit(gpa);
        }
        project.tracks.deinit(gpa);

        // roundtrip: parse the text back into ProjectFile, then rebuild a live Project
        const parsed = try std.json.parseFromSlice(ProjectFile, gpa, text, .{});
        defer parsed.deinit();
        var loaded = try Project.fromFile(parsed.value, gpa);
        defer {
            for (loaded.tracks.items) |*t| {
                for (t.clips.items) |*cl| cl.events.deinit(gpa);
                t.clips.deinit(gpa);
            }
            loaded.tracks.deinit(gpa);
        }

        std.debug.print("roundtrip: bpm={d} tracks={} track0.name={s} track0.clip0.events.len={}\n", .{
            loaded.bpm,
            loaded.tracks.items.len,
            loaded.tracks.items[0].name,
            loaded.tracks.items[0].clips.items[0].events.items.len,
        });

        if (loaded.bpm != 140.0) return error.BpmMismatch;
        if (loaded.tracks.items[0].clips.items[0].events.items.len != 2) return error.EventCountMismatch;
        if (loaded.tracks.items[0].clips.items[0].events.items[1].semitone != 3) return error.SemitoneMismatch;
        std.debug.print("PASS: DTO roundtrip preserves data\n", .{});
    }
}
