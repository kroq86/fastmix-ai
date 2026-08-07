const std = @import("std");

const c = @cImport({
    @cInclude("raylib.h");
});

// Spike: SPEC_UI_REAPER.md §2/§8 — paint chrome in raylib for N frames
// (resize once mid-run). Catches DrawRectangle / screen-coord / DPI surprises
// that pure layout math misses. Auto-exits; prints PASS/FAIL.
//
// NOTE: raylib Rectangle fields are width/height (not w/h).

const TRANSPORT_H: i32 = 40;
const RULER_H: i32 = 22;
const TCP_W: i32 = 180;
const MCP_H: i32 = 180;
const LANE_H: i32 = 72;
const MASTER_W: i32 = 72;

fn rgb(r: u8, g: u8, b: u8) c.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

const Chrome = struct {
    transport: c.Rectangle,
    tcp_pad: c.Rectangle,
    tcp: c.Rectangle,
    ruler: c.Rectangle,
    arrange: c.Rectangle,
    mcp: c.Rectangle,
    master: c.Rectangle,
};

fn computeChrome(sw: i32, sh: i32) Chrome {
    const body_y: f32 = @floatFromInt(TRANSPORT_H);
    const body_h: f32 = @floatFromInt(sh - TRANSPORT_H - MCP_H);
    const track_y = body_y + @as(f32, @floatFromInt(RULER_H));
    const track_h = body_h - @as(f32, @floatFromInt(RULER_H));
    const swf: f32 = @floatFromInt(sw);
    const shf: f32 = @floatFromInt(sh);
    const tcpw: f32 = @floatFromInt(TCP_W);
    return .{
        .transport = .{ .x = 0, .y = 0, .width = swf, .height = @floatFromInt(TRANSPORT_H) },
        .tcp_pad = .{ .x = 0, .y = body_y, .width = tcpw, .height = @floatFromInt(RULER_H) },
        .tcp = .{ .x = 0, .y = track_y, .width = tcpw, .height = track_h },
        .ruler = .{ .x = tcpw, .y = body_y, .width = swf - tcpw, .height = @floatFromInt(RULER_H) },
        .arrange = .{ .x = tcpw, .y = track_y, .width = swf - tcpw, .height = track_h },
        .mcp = .{ .x = 0, .y = shf - @as(f32, @floatFromInt(MCP_H)), .width = swf, .height = @floatFromInt(MCP_H) },
        .master = .{
            .x = swf - @as(f32, @floatFromInt(MASTER_W)),
            .y = shf - @as(f32, @floatFromInt(MCP_H)),
            .width = @floatFromInt(MASTER_W),
            .height = @floatFromInt(MCP_H),
        },
    };
}

fn approxEq(a: f32, b: f32, eps: f32) bool {
    return @abs(a - b) <= eps;
}

pub fn main() !void {
    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE);
    c.InitWindow(1280, 720, "spike: ui chrome");
    defer c.CloseWindow();
    c.SetTargetFPS(60);
    c.SetExitKey(c.KEY_NULL);

    var failures: u32 = 0;
    var frame: u32 = 0;
    const max_frames: u32 = 90;
    var resized = false;

    var track_scroll_y: i32 = 0;
    const pixels_per_bar: f32 = 70;
    const offset_bars: f32 = 2.0;
    var play_bar: f32 = 3.25;

    const volumes = [_]f32{ 0.8, 0.5, 0.3, 0.6 };
    const mutes = [_]bool{ false, true, false, false };
    const solos = [_]bool{ false, false, true, false };
    const armed = [_]bool{ true, false, false, false };

    while (!c.WindowShouldClose() and frame < max_frames) {
        if (frame == 40 and !resized) {
            c.SetWindowSize(1100, 640);
            resized = true;
            std.debug.print("resized to 1100x640 at frame 40\n", .{});
        }

        track_scroll_y = @intFromFloat(@sin(@as(f32, @floatFromInt(frame)) * 0.05) * 30.0 + 30.0);
        play_bar += 0.02;
        if (play_bar > 16) play_bar = 0;

        const sw = c.GetScreenWidth();
        const sh = c.GetScreenHeight();
        const ch = computeChrome(sw, sh);

        if (!approxEq(ch.tcp.y, ch.arrange.y, 0.1)) {
            std.debug.print("FAIL frame {d}: tcp.y != arrange.y\n", .{frame});
            failures += 1;
        }
        if (ch.mcp.y + ch.mcp.height > @as(f32, @floatFromInt(sh)) + 0.1) {
            std.debug.print("FAIL frame {d}: mcp past bottom\n", .{frame});
            failures += 1;
        }
        if (ch.ruler.x < @as(f32, @floatFromInt(TCP_W)) - 0.1) {
            std.debug.print("FAIL frame {d}: ruler overlaps tcp\n", .{frame});
            failures += 1;
        }

        c.BeginDrawing();
        c.ClearBackground(rgb(0x2b, 0x2b, 0x2b));

        c.DrawRectangleRec(ch.transport, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleRec(ch.tcp_pad, rgb(0x33, 0x33, 0x33));
        c.DrawRectangleRec(ch.tcp, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleRec(ch.ruler, rgb(0x30, 0x30, 0x30));
        c.DrawRectangleRec(ch.arrange, rgb(0x1e, 0x1e, 0x1e));
        c.DrawRectangleRec(ch.mcp, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleRec(ch.master, rgb(0x44, 0x44, 0x44));

        c.DrawRectangle(12, 8, 28, 24, rgb(0x55, 0x55, 0x55));
        c.DrawRectangle(44, 8, 28, 24, rgb(0x2e, 0xcc, 0x71));
        c.DrawCircle(100, 20, 10, rgb(0xc0, 0x39, 0x2b));
        c.DrawText("1.1.00  |  BPM 120  |  PLAY", 140, 12, 18, rgb(0xd8, 0xd8, 0xd8));

        var bar: i32 = 0;
        while (bar < 32) : (bar += 1) {
            const x = ch.ruler.x + (@as(f32, @floatFromInt(bar)) - offset_bars) * pixels_per_bar;
            if (x < ch.ruler.x or x > ch.ruler.x + ch.ruler.width) continue;
            c.DrawLine(@intFromFloat(x), @as(i32, @intFromFloat(ch.ruler.y)), @intFromFloat(x), @as(i32, @intFromFloat(ch.ruler.y + ch.ruler.height)), rgb(0x60, 0x60, 0x60));
        }

        const n_tracks = volumes.len;
        for (0..n_tracks) |ti| {
            const y = ch.arrange.y + @as(f32, @floatFromInt(ti)) * @as(f32, @floatFromInt(LANE_H)) - @as(f32, @floatFromInt(track_scroll_y));
            if (y + @as(f32, @floatFromInt(LANE_H)) < ch.arrange.y or y > ch.arrange.y + ch.arrange.height) continue;

            const lane_col = if (ti % 2 == 0) rgb(0x1e, 0x1e, 0x1e) else rgb(0x24, 0x24, 0x24);
            c.DrawRectangle(@intFromFloat(ch.arrange.x), @intFromFloat(y), @intFromFloat(ch.arrange.width), LANE_H, lane_col);

            c.DrawRectangle(@intFromFloat(ch.tcp.x), @intFromFloat(y), TCP_W, LANE_H, rgb(0x3a, 0x3a, 0x3a));
            c.DrawRectangleLines(@intFromFloat(ch.tcp.x), @intFromFloat(y), TCP_W, LANE_H, rgb(0x50, 0x50, 0x50));

            const yi: i32 = @intFromFloat(y);
            c.DrawRectangle(8, yi + 8, 22, 18, if (armed[ti]) rgb(0xc0, 0x39, 0x2b) else rgb(0x55, 0x55, 0x55));
            c.DrawRectangle(34, yi + 8, 22, 18, if (mutes[ti]) rgb(0xd4, 0xa0, 0x17) else rgb(0x55, 0x55, 0x55));
            c.DrawRectangle(60, yi + 8, 22, 18, if (solos[ti]) rgb(0x2e, 0xcc, 0x71) else rgb(0x55, 0x55, 0x55));
            c.DrawRectangle(8, yi + 40, 100, 8, rgb(0x22, 0x22, 0x22));
            c.DrawRectangle(8, yi + 40, @intFromFloat(100.0 * volumes[ti]), 8, rgb(0x5b, 0x7f, 0xa6));

            const item_x = ch.arrange.x + (4.0 + @as(f32, @floatFromInt(ti)) - offset_bars) * pixels_per_bar;
            const item_w = 2.0 * pixels_per_bar;
            if (item_x + item_w > ch.arrange.x and item_x < ch.arrange.x + ch.arrange.width) {
                c.DrawRectangle(@intFromFloat(item_x), yi + 8, @intFromFloat(item_w), LANE_H - 16, rgb(0x3d, 0x5a, 0x80));
            }

            const strip_w: i32 = 64;
            const mx: i32 = 12 + @as(i32, @intCast(ti)) * (strip_w + 8);
            const mcp_y: i32 = @intFromFloat(ch.mcp.y);
            c.DrawRectangle(mx, mcp_y + 8, strip_w, MCP_H - 16, rgb(0x32, 0x32, 0x32));
            const fh: i32 = @intFromFloat(@as(f32, @floatFromInt(MCP_H - 80)) * volumes[ti]);
            c.DrawRectangle(mx + 24, mcp_y + MCP_H - 40 - fh, 16, fh, rgb(0x5b, 0x7f, 0xa6));
        }

        const ph_x = ch.arrange.x + (play_bar - offset_bars) * pixels_per_bar;
        if (ph_x >= ch.arrange.x and ph_x <= ch.arrange.x + ch.arrange.width) {
            c.DrawLine(@intFromFloat(ph_x), @intFromFloat(ch.arrange.y), @intFromFloat(ph_x), @intFromFloat(ch.arrange.y + ch.arrange.height), rgb(0xff, 0xff, 0xff));
        }

        c.DrawText("MASTER", @intFromFloat(ch.master.x + 8), @intFromFloat(ch.master.y + 12), 14, rgb(0xd8, 0xd8, 0xd8));

        var hud: [64]u8 = undefined;
        const hud_z = std.fmt.bufPrintZ(&hud, "frame {d}/{d} {d}x{d}", .{ frame, max_frames, sw, sh }) catch "?";
        c.DrawText(hud_z.ptr, sw - 220, 12, 16, rgb(0x9a, 0x9a, 0x9a));

        c.EndDrawing();
        frame += 1;
    }

    if (failures > 0) {
        std.debug.print("\nSPIKE RESULT: FAIL ({d} invariant breaks over {d} frames)\n", .{ failures, frame });
        std.process.exit(1);
    }
    if (!resized) {
        std.debug.print("\nSPIKE RESULT: FAIL (resize did not happen)\n", .{});
        std.process.exit(1);
    }
    std.debug.print("\nSPIKE RESULT: PASS — chrome drew {d} frames incl. resize; tcp/arrange Y locked\n", .{frame});
}
