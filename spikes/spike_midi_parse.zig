const std = @import("std");

// Spike: the platform-independent half of "real MIDI input" -- turning a raw
// byte stream (as read from an ALSA rawmidi fd on Linux) into note events.
// This does NOT touch ALSA at all (no alsa/asoundlib.h on this machine --
// it's macOS; ALSA is Linux-only). Opening the device and reading real bytes
// off it remains an untested risk until this runs on an actual Linux box.
// What CAN be de-risked here, with zero hardware: the running-status byte
// parser itself, fed synthetic byte sequences.

const MidiMsgKind = enum { note_on, note_off, other };

const ParsedMidi = struct {
    kind: MidiMsgKind,
    channel: u4,
    note: u7 = 0,
    velocity: u7 = 0,
};

fn dataBytesFor(status: u8) u2 {
    return switch (status & 0xF0) {
        0x80, 0x90, 0xA0, 0xB0, 0xE0 => 2,
        0xC0, 0xD0 => 1,
        else => 0,
    };
}

const MidiParser = struct {
    status: u8 = 0,
    data: [2]u8 = .{ 0, 0 },
    data_count: u2 = 0,
    data_needed: u2 = 0,
    in_sysex: bool = false,

    fn tryComplete(self: *MidiParser) ?ParsedMidi {
        const hi: u8 = self.status & 0xF0;
        const channel: u4 = @intCast(self.status & 0x0F);
        return switch (hi) {
            0x80 => .{ .kind = .note_off, .channel = channel, .note = @intCast(self.data[0]), .velocity = @intCast(self.data[1]) },
            0x90 => if (self.data[1] == 0)
                ParsedMidi{ .kind = .note_off, .channel = channel, .note = @intCast(self.data[0]), .velocity = 0 }
            else
                ParsedMidi{ .kind = .note_on, .channel = channel, .note = @intCast(self.data[0]), .velocity = @intCast(self.data[1]) },
            else => ParsedMidi{ .kind = .other, .channel = channel },
        };
    }

    // Feed one raw byte off the wire. Returns a completed message, if this
    // byte finished one, else null.
    fn feed(self: *MidiParser, byte: u8) ?ParsedMidi {
        if (byte >= 0xF8) return null; // realtime (clock/active-sense): single byte, doesn't touch running status
        if (byte == 0xF0) {
            self.in_sysex = true;
            self.status = 0; // sysex cancels running status per spec
            return null;
        }
        if (byte == 0xF7) {
            self.in_sysex = false;
            return null;
        }
        if (self.in_sysex) return null; // swallow sysex payload bytes

        if (byte >= 0x80) {
            self.status = byte;
            self.data_count = 0;
            self.data_needed = dataBytesFor(byte);
            if (self.data_needed == 0) return self.tryComplete();
            return null;
        }

        if (self.status == 0) return null; // orphan data byte, no running status to attach to
        self.data[self.data_count] = byte;
        self.data_count += 1;
        if (self.data_count >= self.data_needed) {
            const result = self.tryComplete();
            self.data_count = 0; // stay primed for the next message under running status
            return result;
        }
        return null;
    }
};

fn expectEvent(got: ?ParsedMidi, kind: MidiMsgKind, note: u7, velocity: u7) !void {
    if (got == null) {
        std.debug.print("FAIL: expected {} note={} vel={}, got null\n", .{ kind, note, velocity });
        return error.Mismatch;
    }
    const g = got.?;
    if (g.kind != kind or g.note != note or g.velocity != velocity) {
        std.debug.print("FAIL: expected {} note={} vel={}, got {} note={} vel={}\n", .{ kind, note, velocity, g.kind, g.note, g.velocity });
        return error.Mismatch;
    }
}

fn expectNull(got: ?ParsedMidi) !void {
    if (got != null) {
        std.debug.print("FAIL: expected null, got {}\n", .{got.?});
        return error.Mismatch;
    }
}

pub fn main() !void {
    var p = MidiParser{};

    std.debug.print("test 1: explicit status bytes\n", .{});
    try expectNull(p.feed(0x90));
    try expectNull(p.feed(60));
    try expectEvent(p.feed(100), .note_on, 60, 100);
    try expectNull(p.feed(0x80));
    try expectNull(p.feed(60));
    try expectEvent(p.feed(0), .note_off, 60, 0);

    std.debug.print("test 2: running status (no repeated status byte)\n", .{});
    p = MidiParser{};
    try expectNull(p.feed(0x90));
    try expectNull(p.feed(60));
    try expectEvent(p.feed(100), .note_on, 60, 100);
    try expectNull(p.feed(62)); // running status still 0x90
    try expectEvent(p.feed(90), .note_on, 62, 90);
    try expectNull(p.feed(0x80));
    try expectNull(p.feed(60));
    try expectEvent(p.feed(0), .note_off, 60, 0);
    try expectNull(p.feed(64)); // running status now 0x80
    try expectEvent(p.feed(0), .note_off, 64, 0);

    std.debug.print("test 3: velocity-0 note-on == note-off\n", .{});
    p = MidiParser{};
    try expectNull(p.feed(0x90));
    try expectNull(p.feed(60));
    try expectEvent(p.feed(0), .note_off, 60, 0);

    std.debug.print("test 4: sysex is swallowed and cancels running status\n", .{});
    p = MidiParser{};
    try expectNull(p.feed(0x90));
    try expectNull(p.feed(60));
    try expectEvent(p.feed(100), .note_on, 60, 100);
    try expectNull(p.feed(0xF0));
    try expectNull(p.feed(0x7E));
    try expectNull(p.feed(0x00));
    try expectNull(p.feed(0xF7));
    try expectNull(p.feed(62)); // orphan data byte, no running status survives sysex -> dropped
    try expectNull(p.feed(90));
    try expectNull(p.feed(0x90));
    try expectNull(p.feed(64));
    try expectEvent(p.feed(50), .note_on, 64, 50);

    std.debug.print("test 5: realtime bytes (clock) interleaved mid-message don't corrupt it\n", .{});
    p = MidiParser{};
    try expectNull(p.feed(0x90));
    try expectNull(p.feed(0xF8)); // clock tick, mid-message
    try expectNull(p.feed(60));
    try expectEvent(p.feed(100), .note_on, 60, 100);

    std.debug.print("PASS: all MIDI parser spike cases\n", .{});
}
