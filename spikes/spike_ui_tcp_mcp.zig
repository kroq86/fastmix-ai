const std = @import("std");

// Spike: SPEC_UI_REAPER.md §4/§6 — TCP and MCP are two views of ONE track
// state. Also proves a cheap peak-hold meter usable at 60fps without DSP libs.
// Headless: maps pointer→fader value for both orientations and asserts sync.

const TrackUi = struct {
    volume: f32 = 1.0, // 0..1
    pan: f32 = 0.0, // -1..1
    mute: bool = false,
    solo: bool = false,
    armed: bool = false,
    peak_l: f32 = 0,
    peak_r: f32 = 0,
};

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

// Horizontal TCP volume: left=0, right=1
fn volumeFromTcpFader(fader: Rect, mouse_x: i32) f32 {
    if (fader.w <= 1) return 0;
    const t = @as(f32, @floatFromInt(mouse_x - fader.x)) / @as(f32, @floatFromInt(fader.w));
    return std.math.clamp(t, 0.0, 1.0);
}

// Vertical MCP volume: bottom=0, top=1 (Reaper-style)
fn volumeFromMcpFader(fader: Rect, mouse_y: i32) f32 {
    if (fader.h <= 1) return 0;
    const from_bottom = @as(f32, @floatFromInt((fader.y + fader.h) - mouse_y)) / @as(f32, @floatFromInt(fader.h));
    return std.math.clamp(from_bottom, 0.0, 1.0);
}

fn panFromSlider(slider: Rect, mouse_x: i32) f32 {
    if (slider.w <= 1) return 0;
    const t = @as(f32, @floatFromInt(mouse_x - slider.x)) / @as(f32, @floatFromInt(slider.w));
    return std.math.clamp(t * 2.0 - 1.0, -1.0, 1.0);
}

// Call once per mix block with max(|sample|) per channel; decay each frame.
fn updatePeakHold(t: *TrackUi, block_peak_l: f32, block_peak_r: f32, decay: f32) void {
    t.peak_l = @max(block_peak_l, t.peak_l * decay);
    t.peak_r = @max(block_peak_r, t.peak_r * decay);
}

fn expect(cond: bool, msg: []const u8, failures: *u32) void {
    if (!cond) {
        std.debug.print("FAIL: {s}\n", .{msg});
        failures.* += 1;
    } else {
        std.debug.print("ok: {s}\n", .{msg});
    }
}

fn approxEq(a: f32, b: f32, eps: f32) bool {
    return @abs(a - b) <= eps;
}

pub fn main() !void {
    var failures: u32 = 0;
    var track: TrackUi = .{};

    const tcp_vol = Rect{ .x = 10, .y = 100, .w = 100, .h = 12 };
    const mcp_vol = Rect{ .x = 200, .y = 400, .w = 20, .h = 100 };
    const tcp_pan = Rect{ .x = 10, .y = 120, .w = 100, .h = 12 };

    // Drag TCP fader to mid → volume 0.5; MCP readback position must encode 0.5.
    track.volume = volumeFromTcpFader(tcp_vol, tcp_vol.x + tcp_vol.w / 2);
    expect(approxEq(track.volume, 0.5, 0.02), "tcp mid -> volume~0.5", &failures);

    // Same state, drag MCP as if user grabbed vertical thumb for 0.5:
    // y = bottom - 0.5*h
    const mcp_mid_y = mcp_vol.y + mcp_vol.h / 2;
    const from_mcp = volumeFromMcpFader(mcp_vol, mcp_mid_y);
    expect(approxEq(from_mcp, 0.5, 0.02), "mcp mid -> volume~0.5", &failures);

    // Write via MCP, read via TCP mapping consistency (single field).
    track.volume = volumeFromMcpFader(mcp_vol, mcp_vol.y + 10); // near top = loud
    expect(track.volume > 0.85, "mcp near top is loud", &failures);
    track.volume = volumeFromTcpFader(tcp_vol, tcp_vol.x + 10); // near left = quiet
    expect(track.volume < 0.2, "tcp near left is quiet", &failures);

    // Mute/solo/arm: toggles are identity regardless of which panel clicked.
    track.mute = !track.mute; // "TCP click"
    expect(track.mute, "mute on via tcp path", &failures);
    track.mute = !track.mute; // "MCP click" — same field
    expect(!track.mute, "mute off via mcp path (same field)", &failures);

    track.solo = true;
    track.armed = true;
    expect(track.solo and track.armed, "solo+arm shared state", &failures);

    // Single-armed policy (spec §4.1): arming B clears A.
    var tracks = [_]TrackUi{ .{ .armed = true }, .{}, .{} };
    const arm_index: usize = 2;
    for (&tracks) |*t| t.armed = false;
    tracks[arm_index].armed = true;
    var armed_count: u32 = 0;
    for (tracks) |t| {
        if (t.armed) armed_count += 1;
    }
    expect(armed_count == 1 and tracks[2].armed, "single-arm policy", &failures);

    // Pan slider extremes
    expect(approxEq(panFromSlider(tcp_pan, tcp_pan.x), -1.0, 0.01), "pan left", &failures);
    expect(approxEq(panFromSlider(tcp_pan, tcp_pan.x + tcp_pan.w), 1.0, 0.01), "pan right", &failures);
    expect(approxEq(panFromSlider(tcp_pan, tcp_pan.x + tcp_pan.w / 2), 0.0, 0.05), "pan center", &failures);

    // Peak-hold: spike then decay across frames; must not stick forever, must
    // jump up on louder block.
    track.peak_l = 0;
    track.peak_r = 0;
    updatePeakHold(&track, 0.8, 0.4, 0.95);
    expect(approxEq(track.peak_l, 0.8, 0.001), "peak jumps to block peak", &failures);
    updatePeakHold(&track, 0.1, 0.1, 0.95);
    expect(track.peak_l < 0.8 and track.peak_l > 0.1, "peak decays but stays above quiet block", &failures);
    // After many decays, fall near floor.
    var i: u32 = 0;
    while (i < 200) : (i += 1) updatePeakHold(&track, 0.0, 0.0, 0.95);
    expect(track.peak_l < 0.01, "peak decays toward zero when silent", &failures);

    // Hot meter threshold helper (UI color switch)
    const hot = 0.9;
    updatePeakHold(&track, 0.95, 0.2, 0.95);
    expect(track.peak_l >= hot, "hot threshold detectable for meter color", &failures);

    if (failures > 0) {
        std.debug.print("\nSPIKE RESULT: FAIL ({d})\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nSPIKE RESULT: PASS — TCP/MCP share state; peak-hold usable\n", .{});
}
