const std = @import("std");

// Spike: SPEC_UI_REAPER.md §5 — item select/move/trim/fade under zoom +
// horizontal scroll. Proves bars↔pixels roundtrips and that edge hit zones
// still map to the correct trim primitive after view changes. Headless.

const EDGE_PX: f32 = 6.0;

const Item = struct {
    start_bar: f32,
    bars: f32,
    fade_in_bars: f32 = 0,
    fade_out_bars: f32 = 0,

    fn endBar(self: Item) f32 {
        return self.start_bar + self.bars;
    }
};

const View = struct {
    offset_bars: f32,
    pixels_per_bar: f32,

    fn barToX(self: View, bar: f32) f32 {
        return (bar - self.offset_bars) * self.pixels_per_bar;
    }
    fn xToBar(self: View, x: f32) f32 {
        return self.offset_bars + x / self.pixels_per_bar;
    }
};

const HitPart = enum { none, body, edge_left, edge_right, fade_in, fade_out };

fn hitItem(view: View, item: Item, x: f32, item_y: f32, item_h: f32, y: f32) HitPart {
    _ = item_y;
    _ = item_h;
    _ = y; // y assumed inside lane for this spike
    const x0 = view.barToX(item.start_bar);
    const x1 = view.barToX(item.endBar());
    if (x < x0 or x >= x1) return .none;

    const fade_in_px = item.fade_in_bars * view.pixels_per_bar;
    const fade_out_px = item.fade_out_bars * view.pixels_per_bar;
    // Fade corners win over edges (same as hittest spike).
    if (item.fade_in_bars > 0 and x - x0 <= @max(EDGE_PX, fade_in_px) and x - x0 <= 10) return .fade_in;
    if (item.fade_out_bars > 0 and x1 - x <= @max(EDGE_PX, fade_out_px) and x1 - x <= 10) return .fade_out;

    if (x - x0 < EDGE_PX) return .edge_left;
    if (x1 - x < EDGE_PX) return .edge_right;
    return .body;
}

fn moveItem(item: *Item, delta_bars: f32) void {
    item.start_bar = @max(0, item.start_bar + delta_bars);
}

fn trimLeft(item: *Item, new_start_bar: f32) void {
    const end = item.endBar();
    const clamped = std.math.clamp(new_start_bar, 0.0, end - 0.01);
    item.bars = end - clamped;
    item.start_bar = clamped;
}

fn trimRight(item: *Item, new_end_bar: f32) void {
    const clamped = @max(item.start_bar + 0.01, new_end_bar);
    item.bars = clamped - item.start_bar;
}

fn setFadeIn(item: *Item, bars: f32) void {
    item.fade_in_bars = std.math.clamp(bars, 0.0, item.bars * 0.5);
}
fn setFadeOut(item: *Item, bars: f32) void {
    item.fade_out_bars = std.math.clamp(bars, 0.0, item.bars * 0.5);
}

// Split at absolute bar → left keeps start, right starts at split.
fn splitAt(item: Item, bar: f32) ?struct { Item, Item } {
    if (bar <= item.start_bar or bar >= item.endBar()) return null;
    const left = Item{ .start_bar = item.start_bar, .bars = bar - item.start_bar };
    const right = Item{ .start_bar = bar, .bars = item.endBar() - bar };
    return .{ left, right };
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

    // --- Roundtrip bars ↔ pixels under zoom+scroll ---
    {
        var rt_fail: u32 = 0;
        const views = [_]View{
            .{ .offset_bars = 0, .pixels_per_bar = 70 },
            .{ .offset_bars = 3.5, .pixels_per_bar = 200 },
            .{ .offset_bars = 10, .pixels_per_bar = 20 },
        };
        for (views) |v| {
            const bars = [_]f32{ 0, 1.25, 8.0, 15.75 };
            for (bars) |b| {
                const x = v.barToX(b);
                const back = v.xToBar(x);
                if (!approxEq(back, b, 0.0001)) {
                    std.debug.print("FAIL: roundtrip bar={d} zoom={d} off={d} -> {d}\n", .{ b, v.pixels_per_bar, v.offset_bars, back });
                    rt_fail += 1;
                }
            }
        }
        expect(rt_fail == 0, "bars↔pixels roundtrip (all views)", &failures);
    }

    // --- Move ---
    {
        var item = Item{ .start_bar = 2, .bars = 4 };
        const view = View{ .offset_bars = 1, .pixels_per_bar = 100 };
        // Drag body 50px right → +0.5 bar
        const delta = view.xToBar(50) - view.xToBar(0);
        moveItem(&item, delta);
        expect(approxEq(item.start_bar, 2.5, 0.001) and approxEq(item.bars, 4, 0.001), "move keeps length", &failures);
    }

    // --- Trim edges ---
    {
        var item = Item{ .start_bar = 2, .bars = 4 };
        trimLeft(&item, 3);
        expect(approxEq(item.start_bar, 3, 0.001) and approxEq(item.bars, 3, 0.001), "trim left", &failures);
        trimRight(&item, 5);
        expect(approxEq(item.endBar(), 5, 0.001), "trim right", &failures);
    }

    // --- Hit zones survive zoom ---
    {
        var item = Item{ .start_bar = 4, .bars = 2, .fade_in_bars = 0.1, .fade_out_bars = 0.1 };
        const view = View{ .offset_bars = 3, .pixels_per_bar = 150 };
        const x0 = view.barToX(item.start_bar);
        const x1 = view.barToX(item.endBar());
        expect(hitItem(view, item, x0 + 2, 0, 60, 10) == .fade_in or hitItem(view, item, x0 + 2, 0, 60, 10) == .edge_left, "near left is edge/fade", &failures);
        expect(hitItem(view, item, (x0 + x1) / 2, 0, 60, 30) == .body, "center is body", &failures);
        expect(hitItem(view, item, x1 - 2, 0, 60, 10) == .fade_out or hitItem(view, item, x1 - 2, 0, 60, 10) == .edge_right, "near right is edge/fade", &failures);
        // Off item after scroll-away
        const view2 = View{ .offset_bars = 20, .pixels_per_bar = 150 };
        expect(hitItem(view2, item, 100, 0, 60, 30) == .none, "scrolled-away item not hit", &failures);
    }

    // --- Fades clamp ---
    {
        var item = Item{ .start_bar = 0, .bars = 2 };
        setFadeIn(&item, 5);
        expect(item.fade_in_bars <= 1.0, "fade in clamped to half length", &failures);
        setFadeOut(&item, 5);
        expect(item.fade_out_bars <= 1.0, "fade out clamped", &failures);
    }

    // --- Split ---
    {
        const item = Item{ .start_bar = 2, .bars = 4 };
        const parts = splitAt(item, 3.5).?;
        expect(approxEq(parts[0].bars, 1.5, 0.001), "split left length", &failures);
        expect(approxEq(parts[1].start_bar, 3.5, 0.001) and approxEq(parts[1].bars, 2.5, 0.001), "split right", &failures);
        expect(splitAt(item, 1.0) == null, "split outside rejected", &failures);
    }

    // --- Pixel drag trim under zoom: 6px edge at high zoom is tiny in bars ---
    {
        const view = View{ .offset_bars = 0, .pixels_per_bar = 400 };
        const edge_bars = EDGE_PX / view.pixels_per_bar;
        expect(edge_bars < 0.02, "edge hit zone shrinks in musical time when zoomed in", &failures);
        // Still hit-able in pixels:
        const item = Item{ .start_bar = 1, .bars = 1 };
        const x0 = view.barToX(item.start_bar);
        expect(hitItem(view, item, x0 + 3, 0, 60, 30) == .edge_left, "6px edge still hittable when zoomed", &failures);
    }

    if (failures > 0) {
        std.debug.print("\nSPIKE RESULT: FAIL ({d})\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nSPIKE RESULT: PASS — move/trim/fade/split survive zoom+scroll\n", .{});
}
