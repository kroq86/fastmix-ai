const std = @import("std");

// Spike: roadmap §11.2 undo/redo via a "snapshot stack". The obvious naive
// implementation is `try stack.append(gpa, project)` (a plain struct copy)
// before every mutating command. This spike proves that's WRONG for a struct
// containing std.ArrayList fields (aliasing, not a deep copy), and confirms
// the DTO-based deep-clone pattern already used for Save/Load (spike_json.zig)
// is what undo snapshots must use too.

const Clip = struct { name: []const u8 };
const Track = struct { name: []const u8, clips: std.ArrayList(Clip) };
const Project = struct { tracks: std.ArrayList(Track) };

fn deinitProject(p: *Project, gpa: std.mem.Allocator) void {
    for (p.tracks.items) |*t| t.clips.deinit(gpa);
    p.tracks.deinit(gpa);
}

// The DTO/deep-clone approach: build an independent copy with its own
// allocations, same pattern as toFile()/fromFile() in spike_json.zig.
fn deepClone(gpa: std.mem.Allocator, p: *const Project) !Project {
    var out: Project = .{ .tracks = .empty };
    for (p.tracks.items) |t| {
        var clips: std.ArrayList(Clip) = .empty;
        for (t.clips.items) |cl| {
            try clips.append(gpa, .{ .name = cl.name });
        }
        try out.tracks.append(gpa, .{ .name = t.name, .clips = clips });
    }
    return out;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.debug.print("=== test 1: naive struct-copy snapshot (expected to be BROKEN) ===\n", .{});
    {
        var project: Project = .{ .tracks = .empty };
        var clips: std.ArrayList(Clip) = .empty;
        try clips.append(gpa, .{ .name = "clip-A" });
        try project.tracks.append(gpa, .{ .name = "bass", .clips = clips });

        // Naive "snapshot": just copy the struct by value.
        const naive_snapshot = project;

        std.debug.print("before mutation: snapshot.tracks.items[0].name={s}\n", .{naive_snapshot.tracks.items[0].name});

        // Now mutate the LIVE project the way a real "insert_effect"/"add_track"
        // command would -- append a new track, which may reallocate tracks.items.
        try project.tracks.append(gpa, .{ .name = "drums", .clips = .empty });
        project.tracks.items[0].name = "bass-RENAMED";

        std.debug.print("after mutation:  snapshot.tracks.items[0].name={s} (expected still \"bass\" if this were a real snapshot)\n", .{naive_snapshot.tracks.items[0].name});
        std.debug.print("after mutation:  snapshot.tracks.count={} (expected still 1 if this were a real snapshot)\n", .{naive_snapshot.tracks.items.len});

        const snapshot_is_broken = std.mem.eql(u8, naive_snapshot.tracks.items[0].name, "bass-RENAMED") or naive_snapshot.tracks.items.len != 1;
        if (!snapshot_is_broken) {
            std.debug.print("UNEXPECTED: naive snapshot somehow wasn't aliased -- re-check this test\n", .{});
            return error.TestAssumptionWrong;
        }
        std.debug.print("CONFIRMED BROKEN as expected: naive struct-copy snapshot sees the live mutation (aliased memory) -- unusable for undo.\n", .{});

        deinitProject(&project, gpa);
        // NOTE: do NOT also deinit naive_snapshot -- it shares the exact same
        // backing allocations as `project` (that's the whole problem), so
        // freeing both would be a double-free.
    }

    std.debug.print("\n=== test 2: DTO-based deep clone snapshot (expected to work correctly) ===\n", .{});
    {
        var project: Project = .{ .tracks = .empty };
        var clips: std.ArrayList(Clip) = .empty;
        try clips.append(gpa, .{ .name = "clip-A" });
        try project.tracks.append(gpa, .{ .name = "bass", .clips = clips });

        var good_snapshot = try deepClone(gpa, &project);
        defer deinitProject(&good_snapshot, gpa);

        std.debug.print("before mutation: snapshot.tracks.items[0].name={s}\n", .{good_snapshot.tracks.items[0].name});

        try project.tracks.append(gpa, .{ .name = "drums", .clips = .empty });
        project.tracks.items[0].name = "bass-RENAMED";
        defer deinitProject(&project, gpa);

        std.debug.print("after mutation:  snapshot.tracks.items[0].name={s} (must still be \"bass\")\n", .{good_snapshot.tracks.items[0].name});
        std.debug.print("after mutation:  snapshot.tracks.count={} (must still be 1)\n", .{good_snapshot.tracks.items.len});

        if (!std.mem.eql(u8, good_snapshot.tracks.items[0].name, "bass") or good_snapshot.tracks.items.len != 1) {
            std.debug.print("FAIL: deep-clone snapshot was affected by the later mutation -- clone is not actually independent\n", .{});
            return error.CloneNotIndependent;
        }
        std.debug.print("PASS: deep-clone snapshot is fully independent of subsequent mutations -- safe for an undo stack.\n", .{});
    }

    std.debug.print("\nCONCLUSION: undo (§11.2) MUST use the DTO/deep-clone pattern (same as Save/Load,\n", .{});
    std.debug.print("spike_json.zig), never a plain `= project` struct copy. A stack of N deep clones\n", .{});
    std.debug.print("also has a real memory cost (each clone allocates its own tracks/clips arrays) --\n", .{});
    std.debug.print("worth remembering when picking the snapshot-stack depth limit (roadmap said ~50).\n", .{});
}
