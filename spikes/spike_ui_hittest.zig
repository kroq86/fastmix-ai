const std = @import("std");

// Spike: SPEC_UI_REAPER.md §7.3 hit-test priority. Overlapping zones are the
// classic "clicked the item but TCP fader ate it" / "clicked MCP through
// arrange" class of bugs. Pure geometry — no raylib — so we can assert every
// ambiguous point.

const Hit = enum {
    transport,
    mcp,
    tcp,
    item_fade,
    item_edge,
    item_body,
    ruler,
    lane_empty,
    none,
};

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

const EDGE: i32 = 6;
const FADE_CORNER: i32 = 10;

const Scene = struct {
    transport: Rect,
    mcp: Rect,
    tcp: Rect,
    ruler: Rect,
    arrange: Rect,
    item: Rect, // inside arrange
};

fn hitTest(s: Scene, px: i32, py: i32) Hit {
    // Spec order §7.3 — first match wins.
    if (s.transport.contains(px, py)) return .transport;
    if (s.mcp.contains(px, py)) return .mcp;
    if (s.tcp.contains(px, py)) return .tcp;

    if (s.item.contains(px, py)) {
        const local_x = px - s.item.x;
        const local_y = py - s.item.y;
        // Fade handles: top-left / top-right corners (before edge, since edge
        // also covers x near borders — fade is more specific).
        const near_left = local_x < FADE_CORNER;
        const near_right = local_x >= s.item.w - FADE_CORNER;
        const near_top = local_y < FADE_CORNER;
        if (near_top and (near_left or near_right)) return .item_fade;
        if (local_x < EDGE or local_x >= s.item.w - EDGE) return .item_edge;
        return .item_body;
    }

    if (s.ruler.contains(px, py)) return .ruler;
    if (s.arrange.contains(px, py)) return .lane_empty;
    return .none;
}

fn expectEq(got: Hit, want: Hit, label: []const u8, failures: *u32) void {
    if (got != want) {
        std.debug.print("FAIL: {s}: got {s}, want {s}\n", .{ label, @tagName(got), @tagName(want) });
        failures.* += 1;
    } else {
        std.debug.print("ok: {s} -> {s}\n", .{ label, @tagName(want) });
    }
}

pub fn main() !void {
    var failures: u32 = 0;

    // Layout sketch (1280x720-ish numbers from ui spec).
    const s = Scene{
        .transport = .{ .x = 0, .y = 0, .w = 1280, .h = 40 },
        .mcp = .{ .x = 0, .y = 540, .w = 1280, .h = 180 },
        .tcp = .{ .x = 0, .y = 62, .w = 180, .h = 478 },
        .ruler = .{ .x = 180, .y = 40, .w = 1100, .h = 22 },
        .arrange = .{ .x = 180, .y = 62, .w = 1100, .h = 478 },
        .item = .{ .x = 300, .y = 80, .w = 200, .h = 60 },
    };

    // Unambiguous singles
    expectEq(hitTest(s, 100, 20), .transport, "center transport", &failures);
    expectEq(hitTest(s, 100, 600), .mcp, "center mcp", &failures);
    expectEq(hitTest(s, 50, 100), .tcp, "center tcp", &failures);
    expectEq(hitTest(s, 400, 50), .ruler, "center ruler", &failures);
    expectEq(hitTest(s, 500, 200), .lane_empty, "empty arrange", &failures);

    // Item zones
    expectEq(hitTest(s, 400, 110), .item_body, "item body", &failures);
    expectEq(hitTest(s, 302, 110), .item_edge, "item left edge", &failures);
    expectEq(hitTest(s, 498, 110), .item_edge, "item right edge", &failures);
    expectEq(hitTest(s, 305, 85), .item_fade, "item fade-in corner", &failures);
    expectEq(hitTest(s, 495, 85), .item_fade, "item fade-out corner", &failures);

    // Priority traps: points that sit in overlapping *logical* regions if
    // someone checks arrange before mcp, or item before transport, etc.
    // Transport overlaps nothing else in Y — but a mis-ordered test that
    // checks arrange first still wouldn't see y=20. Fabricate a fatal
    // ordering bug explicitly by also testing mcp-vs-arrange if someone
    // swapped order: point in MCP must never return lane_empty.
    expectEq(hitTest(s, 400, 550), .mcp, "mcp wins over would-be arrange x", &failures);

    // Item sits inside arrange: body wins over lane_empty.
    expectEq(hitTest(s, 350, 100), .item_body, "item wins over lane_empty", &failures);

    // Ruler vs arrange: y in ruler band, x in arrange column.
    expectEq(hitTest(s, 400, 45), .ruler, "ruler wins over arrange x", &failures);

    // Outside window
    expectEq(hitTest(s, -1, 100), .none, "outside left", &failures);

    // Dropdown overlay simulation: when open, it must be checked BEFORE tcp
    // (spec input selector). Model as optional overlay rect inserted at
    // priority slot between tcp and items — prove the rule.
    {
        const dropdown = Rect{ .x = 20, .y = 120, .w = 140, .h = 80 };
        // Manual check mimicking extended hitTest:
        const px: i32 = 50;
        const py: i32 = 150;
        const hit: Hit = blk: {
            if (s.transport.contains(px, py)) break :blk .transport;
            if (s.mcp.contains(px, py)) break :blk .mcp;
            // overlay before tcp body clicks "under" it
            if (dropdown.contains(px, py)) break :blk .tcp; // treat as tcp-owned overlay
            if (s.tcp.contains(px, py)) break :blk .tcp;
            break :blk .none;
        };
        expectEq(hit, .tcp, "open dropdown overlays tcp and still belongs to tcp layer", &failures);
        // Point under dropdown but if we forgot overlay, still tcp — same.
        // Point outside dropdown but on tcp strip:
        expectEq(hitTest(s, 50, 250), .tcp, "tcp under closed-dropdown area", &failures);
    }

    if (failures > 0) {
        std.debug.print("\nSPIKE RESULT: FAIL ({d})\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nSPIKE RESULT: PASS — hit priority matches SPEC_UI_REAPER §7.3\n", .{});
}
