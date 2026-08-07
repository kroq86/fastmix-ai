const std = @import("std");

// Spike: SPEC_UI_REAPER.md §3 / §7.1 transport state machine.
// Today Space drives record count-in; target is Space=Play/Stop, Record separate.
// Prove the new machine (and that old Space-as-record is intentionally gone).

const Transport = enum { stop, play, count_in, record };

const Action = enum { space, record_key, stop_btn, play_btn, bar_crossed };

// Clear explicit machine — what the UI must implement.
fn step(state: Transport, action: Action) Transport {
    return switch (state) {
        .stop => switch (action) {
            .space, .play_btn => .play,
            .record_key => .count_in,
            .stop_btn => .stop,
            .bar_crossed => .stop,
        },
        .play => switch (action) {
            .space, .stop_btn => .stop,
            .play_btn => .play,
            .record_key => .count_in, // punch? for v1: enter count-in while playing
            .bar_crossed => .play,
        },
        .count_in => switch (action) {
            .space, .stop_btn => .stop, // cancel count-in
            .record_key => .stop, // second hit cancels
            .play_btn => .play, // abandon record arming
            .bar_crossed => .record,
        },
        .record => switch (action) {
            .space, .stop_btn => .stop,
            .record_key => .stop, // toggle record off
            .play_btn => .play, // stop recording, keep playing (Reaper-ish optional)
            .bar_crossed => .record,
        },
    };
}

fn expect(cond: bool, msg: []const u8, failures: *u32) void {
    if (!cond) {
        std.debug.print("FAIL: {s}\n", .{msg});
        failures.* += 1;
    } else {
        std.debug.print("ok: {s}\n", .{msg});
    }
}

pub fn main() !void {
    var failures: u32 = 0;

    // Space toggles play/stop — NOT record
    expect(step(.stop, .space) == .play, "Space from stop -> play", &failures);
    expect(step(.play, .space) == .stop, "Space from play -> stop", &failures);
    expect(step(.stop, .space) != .count_in, "Space does NOT start count-in", &failures);

    // Record key drives count-in -> record on bar
    expect(step(.stop, .record_key) == .count_in, "R from stop -> count_in", &failures);
    expect(step(.count_in, .bar_crossed) == .record, "bar during count_in -> record", &failures);
    expect(step(.record, .record_key) == .stop, "R during record -> stop", &failures);

    // Cancel count-in with Space/Stop
    expect(step(.count_in, .space) == .stop, "Space cancels count_in", &failures);
    expect(step(.count_in, .stop_btn) == .stop, "Stop cancels count_in", &failures);

    // Old behavior must NOT hold: Space from replay/stop must not be count_in
    var legacy_wrong = false;
    // Simulate OLD machine briefly:
    const Old = enum { replay, wait, record };
    var old: Old = .replay;
    // old Space:
    old = switch (old) {
        .replay => .wait,
        .record => .replay,
        .wait => .wait,
    };
    if (old == .wait) legacy_wrong = true;
    expect(legacy_wrong, "documented: OLD Space entered wait/count-in (must migrate)", &failures);
    expect(step(.stop, .space) == .play, "NEW Space enters play instead", &failures);

    // Sequence: Stop -R-> CountIn -bar-> Record -Space-> Stop
    var s: Transport = .stop;
    s = step(s, .record_key);
    s = step(s, .bar_crossed);
    s = step(s, .space);
    expect(s == .stop, "full record sequence ends stop on Space", &failures);

    if (failures > 0) {
        std.debug.print("\nSPIKE RESULT: FAIL ({d})\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nSPIKE RESULT: PASS — transport machine: Space=Play/Stop, R=Record/count-in\n", .{});
}
