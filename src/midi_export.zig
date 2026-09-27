const std = @import("std");
const model = @import("model.zig");

// Standard MIDI File (format 0, one track) writer for MidiClip events, so an
// exported .mid reflects the clip as it is in the project (including edits),
// not the transcription worker's original output.

pub const PPQ: u16 = 480;

/// `drums` writes on channel 10 (GM percussion) instead of channel 1.
pub fn writeClip(gpa: std.mem.Allocator, clip: model.MidiClip, bpm: f64, bar_size: i64, bar_quant: i64, drums: bool) ![]u8 {
    const ticks_per_quant: i64 = @divTrunc(@as(i64, PPQ) * bar_size, bar_quant);
    const clip_start_quant = clip.start_bar * bar_quant;
    const channel: u8 = if (drums) 9 else 0;

    var trk: std.ArrayList(u8) = .empty;
    defer trk.deinit(gpa);
    // tempo meta event at t=0
    const us_per_beat: u32 = @intFromFloat(@round(60_000_000.0 / bpm));
    try trk.appendSlice(gpa, &.{ 0x00, 0xFF, 0x51, 0x03, @truncate(us_per_beat >> 16), @truncate(us_per_beat >> 8), @truncate(us_per_beat) });

    var last_tick: i64 = 0;
    for (clip.events.items) |ev| {
        const note = ev.semitone + 69; // synth root = A4 = MIDI 69
        if (note < 0 or note > 127) continue;
        const tick = @max(last_tick, (clip_start_quant + ev.quant) * ticks_per_quant);
        try writeVarLen(gpa, &trk, @intCast(tick - last_tick));
        last_tick = tick;
        const vel: u8 = if (ev.start) @max(1, @as(u8, @intFromFloat(@round(std.math.clamp(ev.velocity, 0.0, 1.0) * 127)))) else 0;
        try trk.appendSlice(gpa, &.{ (if (ev.start) @as(u8, 0x90) else 0x80) | channel, @intCast(note), vel });
    }
    try trk.appendSlice(gpa, &.{ 0x00, 0xFF, 0x2F, 0x00 }); // end of track

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "MThd");
    try appendU32(gpa, &out, 6);
    try out.appendSlice(gpa, &.{ 0, 0, 0, 1, @truncate(PPQ >> 8), @truncate(PPQ) });
    try out.appendSlice(gpa, "MTrk");
    try appendU32(gpa, &out, @intCast(trk.items.len));
    try out.appendSlice(gpa, trk.items);
    return out.toOwnedSlice(gpa);
}

fn appendU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(gpa, &.{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
}

fn writeVarLen(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var buf: [5]u8 = undefined;
    var n: usize = 0;
    var v = value;
    buf[4] = @truncate(v & 0x7F);
    n = 1;
    v >>= 7;
    while (v > 0) : (v >>= 7) {
        buf[4 - n] = @as(u8, @truncate(v & 0x7F)) | 0x80;
        n += 1;
    }
    try out.appendSlice(gpa, buf[5 - n ..]);
}

test "writeClip produces a valid SMF with tempo and notes" {
    const gpa = std.testing.allocator;
    var events: std.ArrayList(model.Event) = .empty;
    defer events.deinit(gpa);
    try events.append(gpa, .{ .quant = 0, .semitone = 40 - 69, .start = true, .velocity = 1.0 });
    try events.append(gpa, .{ .quant = 4, .semitone = 40 - 69, .start = false });
    const clip: model.MidiClip = .{ .id = 1, .start_bar = 0, .bars = 1, .events = events };
    const smf = try writeClip(gpa, clip, 120, 4, 16, false);
    defer gpa.free(smf);
    try std.testing.expectEqualSlices(u8, "MThd", smf[0..4]);
    try std.testing.expectEqualSlices(u8, "MTrk", smf[14..18]);
    // tempo 500000 us/beat at 120 BPM
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20 }, smf[23..29]);
    // note on E2 vel 127, then 4 quants * 120 ticks = 480 = varlen 0x83 0x60, note off
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x90, 40, 127, 0x83, 0x60, 0x80, 40, 0 }, smf[29..38]);
}
