const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
});

// Spike: does LoadAudioStream(rate, 32, 2) + UpdateAudioStream actually treat
// the 3rd arg as FRAME count (one L+R pair) rather than total float count?
// raylib.h says `frameCount` "considering channels" -- this spike proves it
// empirically before Phase 3 (stereo mixer) relies on it.

const SAMPLE_RATE: u32 = 44100;
const FRAME_COUNT: usize = 1024; // frames per buffer (NOT floats)

pub fn main() !void {
    c.InitWindow(400, 200, "spike: stereo pan");
    defer c.CloseWindow();
    c.SetTargetFPS(60);
    c.SetExitKey(c.KEY_NULL);

    c.InitAudioDevice();
    defer c.CloseAudioDevice();

    c.SetAudioStreamBufferSizeDefault(@intCast(FRAME_COUNT));
    const stream = c.LoadAudioStream(SAMPLE_RATE, 32, 2);
    defer c.UnloadAudioStream(stream);
    c.PlayAudioStream(stream);

    var buffer: [FRAME_COUNT * 2]f32 = undefined; // interleaved L,R,L,R,...
    var frame_count: u64 = 0;
    var fills: u64 = 0;

    while (!c.WindowShouldClose()) {
        // Equal-power pan, slowly oscillating so a human can confirm by ear too.
        const pan_lfo: f32 = @floatCast(std.math.sin(c.GetTime() * 0.5));
        const angle: f32 = (pan_lfo + 1.0) * (std.math.pi / 4.0);
        const gain_l = @cos(angle);
        const gain_r = @sin(angle);

        if (c.IsAudioStreamProcessed(stream)) {
            for (0..FRAME_COUNT) |i| {
                const t: f32 = @as(f32, @floatFromInt(frame_count)) / @as(f32, @floatFromInt(SAMPLE_RATE));
                const s = @sin(2.0 * std.math.pi * t * 440.0) * 0.3;
                buffer[i * 2 + 0] = s * gain_l;
                buffer[i * 2 + 1] = s * gain_r;
                frame_count += 1;
            }
            // THE THING BEING SPIKED: pass FRAME_COUNT, not buffer.len.
            c.UpdateAudioStream(stream, &buffer, @intCast(FRAME_COUNT));
            fills += 1;
            if (fills % 20 == 0) {
                std.debug.print("fills={} frame_count={} pan={d:.2} gain_l={d:.2} gain_r={d:.2}\n", .{ fills, frame_count, pan_lfo, gain_l, gain_r });
            }
        }

        c.BeginDrawing();
        c.ClearBackground(c.Color{ .r = 30, .g = 30, .b = 30, .a = 255 });
        const cx: f32 = 200.0 + pan_lfo * 150.0;
        c.DrawCircleV(.{ .x = cx, .y = 100 }, 15, c.Color{ .r = 255, .g = 255, .b = 255, .a = 255 });
        c.DrawText("L", 20, 92, 20, c.Color{ .r = 200, .g = 200, .b = 200, .a = 255 });
        c.DrawText("R", 370, 92, 20, c.Color{ .r = 200, .g = 200, .b = 200, .a = 255 });
        c.EndDrawing();
    }

    std.debug.print("OK: {} buffer fills, no crash, frame_count/sample_rate = {d:.2}s of audio generated\n", .{ fills, @as(f32, @floatFromInt(frame_count)) / @as(f32, @floatFromInt(SAMPLE_RATE)) });
}
