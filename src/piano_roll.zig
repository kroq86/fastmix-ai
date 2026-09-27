const std = @import("std");
const model = @import("model.zig");

// Piano-roll editing on MidiClip events (pure logic, no raylib).
//
// A clip stores note-on/note-off Events; the editor works on derived Notes
// (on/off paired per pitch) and writes every edit straight back as events,
// so playback, save/load, export and undo snapshots always see the edited
// clip. Selection is kept by NoteKey (start quant + pitch), which survives
// the rebuild and undo/redo.

pub const Note = struct {
    q0: i64,
    q1: i64,
    semitone: i32,
    vel: f32,

    pub fn key(self: Note) NoteKey {
        return .{ .q0 = self.q0, .semitone = self.semitone };
    }
};

pub const NoteKey = struct { q0: i64, semitone: i32 };

pub const MAX_SELECTION = 4096;

pub const DragMode = enum { none, move, resize, box };

pub const EditorState = struct {
    /// MIDI track being edited; null = editor closed (mixer shown instead).
    track_id: ?model.TrackId = null,
    /// Highest visible pitch row (semitone relative to A4, as in Event).
    top_semitone: i32 = 0,
    /// Notes with velocity (transcription amplitude) below this are "doubtful".
    threshold: f32 = 0.4,
    selection: [MAX_SELECTION]NoteKey = undefined,
    selection_len: usize = 0,
    drag: DragMode = .none,
    drag_start_x: f32 = 0,
    drag_start_y: f32 = 0,
    /// Selected notes as they were when the drag began (move/resize are
    /// recomputed from these every frame, so nothing accumulates rounding).
    drag_origin: [MAX_SELECTION]Note = undefined,
    drag_origin_len: usize = 0,
    /// Undo snapshot is taken on the first frame a drag actually changes notes.
    drag_changed: bool = false,
    /// Right-click menu inside the editor (screen position of its top-left).
    menu_open: bool = false,
    menu_x: f32 = 0,
    menu_y: f32 = 0,
    last_click_time: f64 = 0,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,

    pub fn isSelected(self: *const EditorState, k: NoteKey) bool {
        for (self.selection[0..self.selection_len]) |s| if (s.q0 == k.q0 and s.semitone == k.semitone) return true;
        return false;
    }

    pub fn select(self: *EditorState, k: NoteKey) void {
        if (self.isSelected(k) or self.selection_len >= MAX_SELECTION) return;
        self.selection[self.selection_len] = k;
        self.selection_len += 1;
    }

    pub fn deselect(self: *EditorState, k: NoteKey) void {
        var i: usize = 0;
        while (i < self.selection_len) : (i += 1) {
            if (self.selection[i].q0 == k.q0 and self.selection[i].semitone == k.semitone) {
                self.selection[i] = self.selection[self.selection_len - 1];
                self.selection_len -= 1;
                return;
            }
        }
    }

    pub fn clearSelection(self: *EditorState) void {
        self.selection_len = 0;
    }
};

/// Pairs note-on/off per pitch (first-in, first-out). An on without an off
/// lasts one quant. Result sorted by (q0, semitone).
pub fn notesFromEvents(gpa: std.mem.Allocator, events: []const model.Event) ![]Note {
    var notes: std.ArrayList(Note) = .empty;
    errdefer notes.deinit(gpa);
    var open: std.ArrayList(usize) = .empty; // indices into notes still waiting for an off
    defer open.deinit(gpa);
    for (events) |ev| {
        if (ev.start) {
            try notes.append(gpa, .{ .q0 = ev.quant, .q1 = ev.quant + 1, .semitone = ev.semitone, .vel = ev.velocity });
            try open.append(gpa, notes.items.len - 1);
        } else {
            for (open.items, 0..) |ni, oi| {
                if (notes.items[ni].semitone == ev.semitone) {
                    notes.items[ni].q1 = @max(notes.items[ni].q0 + 1, ev.quant);
                    _ = open.orderedRemove(oi);
                    break;
                }
            }
        }
    }
    std.mem.sort(Note, notes.items, {}, noteLess);
    return notes.toOwnedSlice(gpa);
}

fn noteLess(_: void, a: Note, b: Note) bool {
    if (a.q0 != b.q0) return a.q0 < b.q0;
    return a.semitone < b.semitone;
}

/// Notes -> events, off-before-on at equal quant (a repeated pitch retriggers).
pub fn eventsFromNotes(gpa: std.mem.Allocator, notes: []const Note) !std.ArrayList(model.Event) {
    var events: std.ArrayList(model.Event) = .empty;
    errdefer events.deinit(gpa);
    for (notes) |n| {
        if (n.q0 < 0) continue;
        try events.append(gpa, .{ .quant = n.q0, .semitone = n.semitone, .start = true, .velocity = n.vel });
        try events.append(gpa, .{ .quant = @max(n.q0 + 1, n.q1), .semitone = n.semitone, .start = false, .velocity = n.vel });
    }
    std.mem.sort(model.Event, events.items, {}, struct {
        fn lessThan(_: void, a: model.Event, b: model.Event) bool {
            if (a.quant != b.quant) return a.quant < b.quant;
            return !a.start and b.start;
        }
    }.lessThan);
    return events;
}

/// Replaces the clip's events with `notes` and grows the clip to fit.
pub fn writeBack(gpa: std.mem.Allocator, clip: *model.MidiClip, notes: []const Note, bar_quant: i64) !void {
    const events = try eventsFromNotes(gpa, notes);
    clip.events.deinit(gpa);
    clip.events = events;
    if (events.items.len > 0) {
        const last = events.items[events.items.len - 1].quant;
        clip.bars = @max(clip.bars, @divFloor(last, bar_quant) + 1);
    }
}

pub fn deleteSelected(gpa: std.mem.Allocator, clip: *model.MidiClip, st: *EditorState, bar_quant: i64) !usize {
    const notes = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(notes);
    var kept: std.ArrayList(Note) = .empty;
    defer kept.deinit(gpa);
    for (notes) |n| if (!st.isSelected(n.key())) try kept.append(gpa, n);
    const removed = notes.len - kept.items.len;
    try writeBack(gpa, clip, kept.items, bar_quant);
    st.clearSelection();
    return removed;
}

pub fn deleteBelow(gpa: std.mem.Allocator, clip: *model.MidiClip, threshold: f32, bar_quant: i64) !usize {
    const notes = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(notes);
    var kept: std.ArrayList(Note) = .empty;
    defer kept.deinit(gpa);
    for (notes) |n| if (n.vel >= threshold) try kept.append(gpa, n);
    const removed = notes.len - kept.items.len;
    try writeBack(gpa, clip, kept.items, bar_quant);
    return removed;
}

/// Joins selected notes of the same pitch into one note spanning from the
/// first start to the last end (gaps between them are filled); velocity is the
/// loudest piece's. Pitches with a single selected note are left alone.
/// Returns how many notes were removed by joining.
pub fn mergeSelected(gpa: std.mem.Allocator, clip: *model.MidiClip, st: *EditorState, bar_quant: i64) !usize {
    const notes = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(notes);
    var out: std.ArrayList(Note) = .empty;
    defer out.deinit(gpa);
    var merged: std.ArrayList(Note) = .empty; // one per selected pitch
    defer merged.deinit(gpa);
    for (notes) |n| {
        if (!st.isSelected(n.key())) {
            try out.append(gpa, n);
            continue;
        }
        for (merged.items) |*m| {
            if (m.semitone != n.semitone) continue;
            m.q0 = @min(m.q0, n.q0);
            m.q1 = @max(m.q1, n.q1);
            m.vel = @max(m.vel, n.vel);
            break;
        } else try merged.append(gpa, n);
    }
    const removed = notes.len - out.items.len - merged.items.len;
    st.clearSelection();
    for (merged.items) |m| {
        try out.append(gpa, m);
        st.select(m.key());
    }
    std.mem.sort(Note, out.items, {}, noteLess);
    try writeBack(gpa, clip, out.items, bar_quant);
    return removed;
}

pub fn addNote(gpa: std.mem.Allocator, clip: *model.MidiClip, q0: i64, semitone: i32, bar_quant: i64) !void {
    const notes = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(notes);
    var all: std.ArrayList(Note) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, notes);
    try all.append(gpa, .{ .q0 = q0, .q1 = q0 + 1, .semitone = semitone, .vel = 1.0 });
    try writeBack(gpa, clip, all.items, bar_quant);
}

/// Remembers the selected notes as drag origin.
pub fn beginDrag(gpa: std.mem.Allocator, clip: *const model.MidiClip, st: *EditorState, mode: DragMode, x: f32, y: f32) !void {
    const notes = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(notes);
    st.drag_origin_len = 0;
    for (notes) |n| {
        if (!st.isSelected(n.key()) or st.drag_origin_len >= MAX_SELECTION) continue;
        st.drag_origin[st.drag_origin_len] = n;
        st.drag_origin_len += 1;
    }
    st.drag = mode;
    st.drag_changed = false;
    st.drag_start_x = x;
    st.drag_start_y = y;
}

/// Applies move (dq quants, dsemi semitones) or resize (dq on the end) to the
/// drag origin notes; everything else in the clip is left untouched.
pub fn applyDrag(gpa: std.mem.Allocator, clip: *model.MidiClip, st: *EditorState, dq: i64, dsemi: i32, bar_quant: i64) !void {
    const notes = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(notes);
    var out: std.ArrayList(Note) = .empty;
    defer out.deinit(gpa);
    // current positions of the dragged notes = selection keys
    for (notes) |n| if (!st.isSelected(n.key())) try out.append(gpa, n);
    st.clearSelection();
    for (st.drag_origin[0..st.drag_origin_len]) |o| {
        var n = o;
        switch (st.drag) {
            .move => {
                n.q0 = @max(0, o.q0 + dq);
                n.q1 = n.q0 + (o.q1 - o.q0);
                n.semitone = std.math.clamp(o.semitone + dsemi, -69, 127 - 69);
            },
            .resize => n.q1 = @max(o.q0 + 1, o.q1 + dq),
            else => {},
        }
        try out.append(gpa, n);
        st.select(n.key());
    }
    std.mem.sort(Note, out.items, {}, noteLess);
    try writeBack(gpa, clip, out.items, bar_quant);
}

/// Standard note name for a semitone relative to A4 (e.g. -29 -> "E2").
pub fn noteName(buf: []u8, semitone: i32) []const u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const midi = semitone + 69;
    const octave = @divFloor(midi, 12) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[@intCast(@mod(midi, 12))], octave }) catch "?";
}

pub fn isBlackKey(semitone: i32) bool {
    return switch (@mod(semitone + 69, 12)) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

fn testClip(gpa: std.mem.Allocator, notes: []const Note) !model.MidiClip {
    return .{ .id = 1, .start_bar = 0, .bars = 1, .events = try eventsFromNotes(gpa, notes) };
}

test "events <-> notes roundtrip, repeated pitch retriggers" {
    const gpa = std.testing.allocator;
    const src = [_]Note{ .{ .q0 = 0, .q1 = 2, .semitone = -29, .vel = 0.9 }, .{ .q0 = 2, .q1 = 4, .semitone = -29, .vel = 0.3 } };
    var clip = try testClip(gpa, &src);
    defer clip.events.deinit(gpa);
    const back = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(Note, &src, back);
}

test "delete selected and below threshold" {
    const gpa = std.testing.allocator;
    const src = [_]Note{
        .{ .q0 = 0, .q1 = 1, .semitone = 0, .vel = 0.9 },
        .{ .q0 = 1, .q1 = 2, .semitone = 3, .vel = 0.2 },
        .{ .q0 = 2, .q1 = 3, .semitone = 5, .vel = 0.8 },
    };
    var clip = try testClip(gpa, &src);
    defer clip.events.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), try deleteBelow(gpa, &clip, 0.5, 16));
    var st: EditorState = .{};
    st.select(.{ .q0 = 2, .semitone = 5 });
    try std.testing.expectEqual(@as(usize, 1), try deleteSelected(gpa, &clip, &st, 16));
    const left = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(left);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqual(@as(i32, 0), left[0].semitone);
}

test "move and resize keep selection on the moved notes" {
    const gpa = std.testing.allocator;
    const src = [_]Note{ .{ .q0 = 4, .q1 = 6, .semitone = 0, .vel = 1 }, .{ .q0 = 8, .q1 = 9, .semitone = 2, .vel = 1 } };
    var clip = try testClip(gpa, &src);
    defer clip.events.deinit(gpa);
    var st: EditorState = .{};
    st.select(.{ .q0 = 4, .semitone = 0 });
    try beginDrag(gpa, &clip, &st, .move, 0, 0);
    try applyDrag(gpa, &clip, &st, 2, 1, 16); // intermediate frame
    try applyDrag(gpa, &clip, &st, 3, -2, 16); // final: from origin, not cumulative
    try std.testing.expect(st.isSelected(.{ .q0 = 7, .semitone = -2 }));
    try beginDrag(gpa, &clip, &st, .resize, 0, 0);
    try applyDrag(gpa, &clip, &st, 4, 0, 16);
    const out = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(Note{ .q0 = 7, .q1 = 13, .semitone = -2, .vel = 1 }, out[0]);
    try std.testing.expectEqual(Note{ .q0 = 8, .q1 = 9, .semitone = 2, .vel = 1 }, out[1]);
}

test "mergeSelected joins same-pitch pieces, per pitch, gaps filled" {
    const gpa = std.testing.allocator;
    const src = [_]Note{
        .{ .q0 = 0, .q1 = 1, .semitone = -29, .vel = 0.5 },
        .{ .q0 = 1, .q1 = 3, .semitone = -29, .vel = 0.9 },
        .{ .q0 = 4, .q1 = 5, .semitone = -29, .vel = 0.4 }, // gap at 3..4
        .{ .q0 = 2, .q1 = 3, .semitone = -17, .vel = 0.7 }, // other pitch, alone
        .{ .q0 = 6, .q1 = 7, .semitone = -29, .vel = 1.0 }, // not selected
    };
    var clip = try testClip(gpa, &src);
    defer clip.events.deinit(gpa);
    var st: EditorState = .{};
    for (src[0..4]) |n| st.select(n.key());
    try std.testing.expectEqual(@as(usize, 2), try mergeSelected(gpa, &clip, &st, 16));
    const out = try notesFromEvents(gpa, clip.events.items);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqual(Note{ .q0 = 0, .q1 = 5, .semitone = -29, .vel = 0.9 }, out[0]);
    try std.testing.expectEqual(Note{ .q0 = 2, .q1 = 3, .semitone = -17, .vel = 0.7 }, out[1]);
    try std.testing.expectEqual(Note{ .q0 = 6, .q1 = 7, .semitone = -29, .vel = 1.0 }, out[2]);
    try std.testing.expect(st.isSelected(.{ .q0 = 0, .semitone = -29 }));
}

test "addNote and noteName" {
    const gpa = std.testing.allocator;
    var clip = try testClip(gpa, &.{});
    defer clip.events.deinit(gpa);
    try addNote(gpa, &clip, 32, -29, 16);
    try std.testing.expectEqual(@as(i64, 3), clip.bars); // quant 33 off -> bar 2 -> 3 bars
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("E2", noteName(&buf, -29));
    try std.testing.expectEqualStrings("A4", noteName(&buf, 0));
    try std.testing.expect(isBlackKey(1));
}
