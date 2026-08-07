const std = @import("std");

// Spike: SPEC_UI_REAPER.md §2 chrome layout — Transport / TCP / Ruler / Arrange /
// MCP under resize + vertical track scroll. Headless rect algebra only.
//
// Key finding to lock in: ruler sits ONLY over arrange (not over TCP), BUT
// track strips must still share one Y with arrange lanes. That means the TCP
// *track column* starts at body_y+RULER_H (same as arrange), with a pad/rect
// above it beside the ruler — not a TCP that fills the full body height from
// body_y (which would desync lane 0 by RULER_H pixels).

const TRANSPORT_H: i32 = 40;
const RULER_H: i32 = 22;
const TCP_W: i32 = 180;
const MCP_H: i32 = 180;
const LANE_H: i32 = 72;
const MASTER_W: i32 = 72;

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    fn right(self: Rect) i32 {
        return self.x + self.w;
    }
};

const Chrome = struct {
    transport: Rect,
    tcp_pad: Rect, // area beside ruler (no track controls)
    tcp: Rect, // track control strips — SAME y/h as arrange
    ruler: Rect,
    arrange: Rect,
    mcp: Rect,
    master: Rect,
};

fn computeChrome(screen_w: i32, screen_h: i32) Chrome {
    const transport = Rect{ .x = 0, .y = 0, .w = screen_w, .h = TRANSPORT_H };
    const body_y = TRANSPORT_H;
    const body_h = screen_h - TRANSPORT_H - MCP_H;
    const track_y = body_y + RULER_H;
    const track_h = body_h - RULER_H;

    return .{
        .transport = transport,
        .tcp_pad = .{ .x = 0, .y = body_y, .w = TCP_W, .h = RULER_H },
        .tcp = .{ .x = 0, .y = track_y, .w = TCP_W, .h = track_h },
        .ruler = .{ .x = TCP_W, .y = body_y, .w = screen_w - TCP_W, .h = RULER_H },
        .arrange = .{ .x = TCP_W, .y = track_y, .w = screen_w - TCP_W, .h = track_h },
        .mcp = .{ .x = 0, .y = screen_h - MCP_H, .w = screen_w, .h = MCP_H },
        .master = .{ .x = screen_w - MASTER_W, .y = screen_h - MCP_H, .w = MASTER_W, .h = MCP_H },
    };
}

fn laneY(track_area_y: i32, track_scroll_y: i32, ti: usize) i32 {
    return track_area_y + @as(i32, @intCast(ti)) * LANE_H - track_scroll_y;
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

    {
        const ch = computeChrome(1280, 720);
        expect(ch.transport.h == TRANSPORT_H, "transport height", &failures);
        expect(ch.mcp.bottom() == 720, "mcp flushes to bottom", &failures);
        expect(ch.tcp.bottom() == ch.mcp.y, "tcp bottom meets mcp", &failures);
        expect(ch.arrange.bottom() == ch.mcp.y, "arrange bottom meets mcp", &failures);
        expect(ch.tcp.y == ch.arrange.y, "tcp tracks share arrange Y origin", &failures);
        expect(ch.tcp.h == ch.arrange.h, "tcp tracks share arrange height", &failures);
        expect(ch.ruler.x == TCP_W, "ruler only over arrange (x)", &failures);
        expect(!ch.ruler.contains(TCP_W - 1, ch.ruler.y + 1), "ruler excludes tcp x", &failures);
        expect(ch.tcp_pad.contains(10, ch.ruler.y + 1), "tcp_pad sits beside ruler", &failures);
        expect(ch.master.right() == 1280, "master pinned right", &failures);
    }

    {
        const sizes = [_][2]i32{ .{ 800, 600 }, .{ 1920, 1080 }, .{ 1100, 500 } };
        for (sizes) |sz| {
            const ch = computeChrome(sz[0], sz[1]);
            expect(ch.arrange.h > 0 and ch.tcp.h > 0, "resize keeps positive track area", &failures);
            expect(ch.transport.h + RULER_H + ch.tcp.h + ch.mcp.h == sz[1], "vertical sum == screen_h", &failures);
            expect(ch.tcp.w + ch.arrange.w == sz[0], "horizontal sum == screen_w", &failures);
        }
    }

    {
        const ch = computeChrome(1280, 720);
        var mismatch: u32 = 0;
        for ([_]i32{ 0, 40, 72, 200 }) |scroll| {
            for (0..8) |ti| {
                const ty = laneY(ch.tcp.y, scroll, ti);
                const ay = laneY(ch.arrange.y, scroll, ti);
                if (ty != ay) mismatch += 1;
            }
        }
        expect(mismatch == 0, "tcp/arrange lane Y identical under all scrolls", &failures);

        // Clip awareness: after scroll, track 0 is above the track-area origin.
        const y0 = laneY(ch.arrange.y, 100, 0);
        expect(y0 < ch.arrange.y, "scrolled track 0 above clip origin", &failures);
        expect(ch.arrange.contains(ch.arrange.x + 1, ch.arrange.y + 1), "arrange contains its top-left+1", &failures);
    }

    // Naive-wrong chrome (TCP from body_y) must NOT be used — document the trap.
    {
        const body_y: i32 = TRANSPORT_H;
        const naive_tcp_y = body_y;
        const arrange_y = body_y + RULER_H;
        expect(naive_tcp_y != arrange_y, "trap: naive TCP-from-body_y desyncs lanes by RULER_H", &failures);
    }

    if (failures > 0) {
        std.debug.print("\nSPIKE RESULT: FAIL ({d})\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nSPIKE RESULT: PASS — chrome invariants hold; TCP track origin = arrange.y\n", .{});
}
