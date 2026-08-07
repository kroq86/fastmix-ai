const std = @import("std");
const model = @import("model.zig");
const mixer = @import("mixer.zig");
const persist = @import("persist.zig");

const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("dirent.h");
    @cInclude("unistd.h");
});

// Reaper-like chrome for phases UI 1–4 (SPEC_UI_REAPER.md). Layout/hit-test/
// TCP↔MCP/transport machines proven in spikes/spike_ui_*.zig.

pub const MENU_H: i32 = 22;
pub const TRANSPORT_H: i32 = 40;
pub const RULER_H: i32 = 22;
pub const TCP_W: i32 = 180;
pub const MCP_H: i32 = 180;
/// Bottom strip for [+ Add Track] under TCP (lanes use height − this).
pub const TCP_FOOTER_H: i32 = 22;
/// Fallback / reference only — live layout uses `laneHeight(chrome, N)` (fit-all, no scroll).
pub const LANE_H: i32 = 72;
const TCP_FADERS_MIN_H: f32 = 48;
pub const MASTER_W: i32 = 72;
const EDGE_PX: f32 = 6.0;

pub const Transport = enum { stop, play, count_in, record };

pub const Action = enum { space, record_key, stop_btn, play_btn, bar_crossed };

pub const MenuDropdown = enum { none, app, file, edit, track, options };

pub const PathModal = enum { none, open, save_as, render };

pub const PathFocus = enum { name, list };

pub const DirtyPending = enum { none, quit, open, new_project, close_project };

/// Right-click context menu target (arrange/TCP).
pub const CtxMenu = union(enum) {
    none,
    track: model.TrackId,
    item: struct { track_id: model.TrackId, clip_id: model.ClipId },
    empty,
};

pub const MenuAction = enum {
    none,
    save,
    save_as_confirm,
    open_confirm,
    quit,
    render_start,
    new_project,
    close_project,
    dirty_save,
    dirty_discard,
    analyze_master_program,
    validate_master_delivery,
    reset_master_peak,
    cycle_audio_block_size,
};

pub const FxTarget = union(enum) {
    none,
    track: model.TrackId,
    master,
};

pub fn stepTransport(state: Transport, action: Action) Transport {
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
            .record_key => .count_in,
            .bar_crossed => .play,
        },
        .count_in => switch (action) {
            .space, .stop_btn, .record_key => .stop,
            .play_btn => .play,
            .bar_crossed => .record,
        },
        .record => switch (action) {
            .space, .stop_btn, .record_key => .stop,
            .play_btn => .play,
            .bar_crossed => .record,
        },
    };
}

pub fn isRunning(t: Transport) bool {
    return t != .stop;
}

fn rgb(r: u8, g: u8, b: u8) c.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

const COL_BG = rgb(0x2b, 0x2b, 0x2b);
const COL_PANEL = rgb(0x3a, 0x3a, 0x3a);
const COL_ARRANGE = rgb(0x1e, 0x1e, 0x1e);
const COL_LANE_ALT = rgb(0x24, 0x24, 0x24);
const COL_ITEM = rgb(0x3d, 0x5a, 0x80);
const COL_TEXT = rgb(0xd8, 0xd8, 0xd8);
const COL_DIM = rgb(0x9a, 0x9a, 0x9a);
const COL_GRID = rgb(0x40, 0x40, 0x40);
const COL_BAR = rgb(0x60, 0x60, 0x60);
const COL_PLAYHEAD = rgb(0xff, 0xff, 0xff);
const COL_RECORD = rgb(0xc0, 0x39, 0x2b);
const COL_ARM = rgb(0xc0, 0x39, 0x2b);
const COL_MUTE = rgb(0xd4, 0xa0, 0x17);
const COL_SOLO = rgb(0x2e, 0xcc, 0x71);
const COL_METER = rgb(0x3c, 0xb3, 0x71);
const COL_METER_HOT = rgb(0xe7, 0x4c, 0x3c);
const COL_FADER = rgb(0x5b, 0x7f, 0xa6);
const COL_BTN = rgb(0x55, 0x55, 0x55);

pub const Chrome = struct {
    menu: c.Rectangle,
    transport: c.Rectangle,
    tcp_pad: c.Rectangle,
    tcp: c.Rectangle,
    ruler: c.Rectangle,
    arrange: c.Rectangle,
    mcp: c.Rectangle,
    master: c.Rectangle,
};

pub fn computeChrome(sw: i32, sh: i32) Chrome {
    const menu_h: f32 = @floatFromInt(MENU_H);
    const transport_h: f32 = @floatFromInt(TRANSPORT_H);
    const top = menu_h;
    const body_y = top + transport_h;
    const body_h: f32 = @floatFromInt(sh - MENU_H - TRANSPORT_H - MCP_H);
    const track_y = body_y + @as(f32, @floatFromInt(RULER_H));
    const track_h = @max(1.0, body_h - @as(f32, @floatFromInt(RULER_H)));
    const swf: f32 = @floatFromInt(sw);
    const shf: f32 = @floatFromInt(sh);
    const tcpw: f32 = @floatFromInt(TCP_W);
    return .{
        .menu = .{ .x = 0, .y = 0, .width = swf, .height = menu_h },
        .transport = .{ .x = 0, .y = top, .width = swf, .height = transport_h },
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

fn rect(x: f32, y: f32, w: f32, h: f32) c.Rectangle {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

/// Menu bar labels — positions from measured text, not fixed screen px.
pub const MenuLayout = struct {
    app: c.Rectangle,
    file: c.Rectangle,
    edit: c.Rectangle,
    track: c.Rectangle,
    options: c.Rectangle,
};

pub fn computeMenuLayout(chrome: Chrome) MenuLayout {
    const y = chrome.menu.y;
    const h = chrome.menu.height;
    const gap: f32 = 12;
    var x: f32 = 8;
    const mk = struct {
        fn item(xx: *f32, label: [*:0]const u8, yy: f32, hh: f32, g: f32) c.Rectangle {
            const tw: f32 = @floatFromInt(c.MeasureText(label, 14));
            const w = tw + 16;
            const r = rect(xx.*, yy, w, hh);
            xx.* += w + g;
            return r;
        }
    }.item;
    const app = mk(&x, "FastMix", y, h, gap);
    const file = mk(&x, "File", y, h, gap);
    const edit = mk(&x, "Edit", y, h, gap);
    const track = mk(&x, "Track", y, h, gap);
    const options = mk(&x, "Options", y, h, gap);
    return .{ .app = app, .file = file, .edit = edit, .track = track, .options = options };
}

/// Transport controls laid out L→R; clock fills remaining width.
pub const TransportLayout = struct {
    stop: c.Rectangle,
    play: c.Rectangle,
    record: c.Rectangle,
    metro: c.Rectangle,
    align_btn: c.Rectangle,
    snap: c.Rectangle,
    grid: c.Rectangle,
    dry: c.Rectangle,
    clock: c.Rectangle,
};

pub fn computeTransportLayout(chrome: Chrome) TransportLayout {
    const y = chrome.transport.y + 8;
    const bh: f32 = 24;
    const gap: f32 = 6;
    var x: f32 = chrome.transport.x + 12;
    const stop = rect(x, y, 28, bh);
    x += 28 + gap;
    const play = rect(x, y, 28, bh);
    x += 28 + gap + 10;
    const record = rect(x, y, 24, bh);
    x += 24 + gap;
    const metro = rect(x, y, 28, bh);
    x += 28 + gap;
    const align_btn = rect(x, y, 62, bh);
    x += 62 + gap;
    const snap = rect(x, y, 46, bh);
    x += 46 + gap;
    const grid = rect(x, y, 82, bh);
    x += 82 + gap;
    const dry = rect(x, y, 40, bh);
    x += 40 + gap;
    const clock_w = @max(100.0, chrome.transport.x + chrome.transport.width - x - 12);
    const clock = rect(x, y, clock_w, bh);
    return .{
        .stop = stop,
        .play = play,
        .record = record,
        .metro = metro,
        .align_btn = align_btn,
        .snap = snap,
        .grid = grid,
        .dry = dry,
        .clock = clock,
    };
}

/// Per-lane TCP controls — all relative to `chrome.tcp`, not screen origin.
pub const TcpLaneLayout = struct {
    lane: c.Rectangle,
    arm: c.Rectangle,
    mute: c.Rectangle,
    solo: c.Rectangle,
    name: c.Rectangle,
    route: c.Rectangle,
    fx: c.Rectangle,
    vol: c.Rectangle,
    pan: c.Rectangle,
    meter: c.Rectangle,
};

pub fn computeTcpLane(chrome: Chrome, lane_h: f32, ti: usize) TcpLaneLayout {
    const x = chrome.tcp.x;
    const y = laneY(chrome.tcp.y, lane_h, ti);
    const w = chrome.tcp.width;
    const btn_y = y + 8;
    const arm = rect(x + 8, btn_y, 22, 18);
    const mute = rect(x + 34, btn_y, 22, 18);
    const solo = rect(x + 60, btn_y, 22, 18);
    const fx = rect(x + w - 32, btn_y, 26, 18);
    const route = rect(x + w - 68, btn_y, 34, 18);
    const name_x = x + 88;
    const name_w = @max(24.0, route.x - name_x - 4);
    const name = rect(name_x, btn_y, name_w, 18);
    const fader_w = @max(40.0, @min(100.0, w - 40));
    const vol = rect(x + 8, y + 40, fader_w, 8);
    const pan = rect(x + 8, y + 54, fader_w, 10);
    const meter = rect(x + w - 12, y + 30, 8, 22);
    return .{
        .lane = rect(x, y, w, lane_h),
        .arm = arm,
        .mute = mute,
        .solo = solo,
        .name = name,
        .route = route,
        .fx = fx,
        .vol = vol,
        .pan = pan,
        .meter = meter,
    };
}

pub fn computeTcpFooter(chrome: Chrome) c.Rectangle {
    const foot_y = chrome.tcp.y + tracksAreaH(chrome);
    return rect(chrome.tcp.x, foot_y, chrome.tcp.width, @floatFromInt(TCP_FOOTER_H));
}

/// MCP strip layout; null if strip would collide with master.
pub const McpStripLayout = struct {
    strip: c.Rectangle,
    arm: c.Rectangle,
    mute: c.Rectangle,
    solo: c.Rectangle,
    meter: c.Rectangle,
    fader: c.Rectangle,
    pan: c.Rectangle,
    label: c.Rectangle,
};

pub const MCP_STRIP_W: f32 = 64;
pub const MCP_STRIP_GAP: f32 = 8;

pub fn computeMcpStrip(chrome: Chrome, ti: usize) ?McpStripLayout {
    const sx = chrome.mcp.x + 12 + @as(f32, @floatFromInt(ti)) * (MCP_STRIP_W + MCP_STRIP_GAP);
    if (sx + MCP_STRIP_W >= chrome.master.x) return null;
    const my = chrome.mcp.y;
    const mh: f32 = @floatFromInt(MCP_H);
    const strip = rect(sx, my + 8, MCP_STRIP_W, mh - 16);
    const arm = rect(sx + 4, my + 10, 16, 16);
    const mute = rect(sx + 22, my + 10, 16, 16);
    const solo = rect(sx + 40, my + 10, 16, 16);
    const meter = rect(sx + 4, my + 40, 8, mh - 100);
    const fader = rect(sx + 28, my + 40, 12, mh - 100);
    const pan = rect(sx + 4, my + mh - 36, MCP_STRIP_W - 8, 10);
    const label = rect(sx, my + mh - 22, MCP_STRIP_W, 14);
    return .{
        .strip = strip,
        .arm = arm,
        .mute = mute,
        .solo = solo,
        .meter = meter,
        .fader = fader,
        .pan = pan,
        .label = label,
    };
}

pub fn computeMcpAddButton(chrome: Chrome, track_count: usize) ?c.Rectangle {
    const sx = chrome.mcp.x + 12 + @as(f32, @floatFromInt(track_count)) * (MCP_STRIP_W + MCP_STRIP_GAP);
    if (sx + 36 >= chrome.master.x) return null;
    return rect(sx, chrome.mcp.y + 10, 28, 24);
}

fn rectContains(r: c.Rectangle, x: f32, y: f32) bool {
    return x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height;
}

pub const DragKind = enum { none, tcp_vol, tcp_pan, mcp_vol, mcp_pan, mcp_bus_vol, mcp_bus_pan, mcp_master_vol, bpm, fx_thresh, fx_ratio, fx_lim_thresh, fx_lim_ceiling, fx_eq_freq, fx_eq_gain, fx_eq_q };

pub const Drag = struct {
    kind: DragKind = .none,
    track_index: usize = 0,
    /// Bus index into project.buses when kind is mcp_bus_*.
    bus_index: usize = 0,
    effect_index: usize = 0,
};

pub const View = struct {
    /// Session DRY: bypass all track/bus/master inserts (not persisted).
    fx_bypass_all: bool = false,
    transport: Transport = .stop,
    metronome: bool = false,
    /// Set by UI; main clears after running align-to-grid.
    align_requested: bool = false,
    timeline_offset_bars: f32 = 0,
    pixels_per_bar: f32 = 70,
    /// Visual + snap grid: subdivisions per bar (0=Off, 12=1/8T, 24=1/16T).
    grid_div: i32 = 4,
    snap_enabled: bool = true,
    grid_menu_open: bool = false,
    track_scroll_y: i32 = 0,
    selected_track: ?model.TrackId = null,
    drag: Drag = .{},
    peaks_l: [64]f32 = [_]f32{0} ** 64,
    peaks_r: [64]f32 = [_]f32{0} ** 64,
    bus_peaks: [32]f32 = [_]f32{0} ** 32,
    master_peak: f32 = 0,
    /// Hold peak for master strip (lin 0..1); reset via GUI / menu_action.
    master_peak_hold: f32 = 0,
    master_clip_flag: bool = false,
    /// Last completed program analysis (not a live instantaneous meter).
    master_qc_sample_peak_dbfs: f32 = -120,
    master_qc_true_peak_dbtp: f32 = -120,
    master_qc_short_lufs: f32 = -120,
    master_qc_integrated_lufs: f32 = -120,
    master_qc_has_integrated: bool = false,
    master_qc_lra_lu: f32 = 0,
    master_qc_has_lra: bool = false,
    master_qc_limiter_gr_db: f32 = 0,
    master_qc_status: [48]u8 = [_]u8{0} ** 48,
    master_qc_status_len: usize = 0,

    menu_open: MenuDropdown = .none,
    show_about: bool = false,
    /// Live audio block size (frames); main applies + persists on cycle/set.
    audio_block_size: u32 = 2048,
    path_modal: PathModal = .none,
    path_focus: PathFocus = .name,
    path_dir_buf: [768]u8 = [_]u8{0} ** 768,
    path_dir_len: usize = 0,
    path_name_buf: [256]u8 = [_]u8{0} ** 256,
    path_name_len: usize = 0,
    path_caret: usize = 0,
    path_list_names: [48][96]u8 = [_][96]u8{[_]u8{0} ** 96} ** 48,
    path_list_is_dir: [48]bool = [_]bool{false} ** 48,
    path_list_len: usize = 0,
    path_list_scroll: usize = 0,
    show_dirty_confirm: bool = false,
    dirty_pending: DirtyPending = .none,
    project_dirty: bool = false,
    open_path_buf: [1024]u8 = [_]u8{0} ** 1024,
    open_path_len: usize = 0,
    render_path_buf: [512]u8 = [_]u8{0} ** 512,
    render_path_len: usize = 0,
    menu_action: MenuAction = .none,
    /// Short status line (e.g. "Rendering…" / "Rendered master.wav").
    status_msg: [96]u8 = [_]u8{0} ** 96,
    status_msg_len: usize = 0,

    fx_target: FxTarget = .none,
    /// Route inspector for a track (Master Send + sends list).
    route_track: ?model.TrackId = null,
    /// When set, main applies sidechain dry/wet (+ bake if needed), then clears.
    fx_apply_track: ?model.TrackId = null,

    /// Inline rename (dbl-click track name / Track → Rename).
    rename_track: ?model.TrackId = null,
    rename_buf: [64]u8 = [_]u8{0} ** 64,
    rename_len: usize = 0,
    rename_caret: usize = 0,
    /// Double-click detection on TCP name.
    name_click_track: ?model.TrackId = null,
    name_click_time: f64 = -1,

    ctx_menu: CtxMenu = .none,
    ctx_x: f32 = 0,
    ctx_y: f32 = 0,
    /// Timeline frame under mouse when context menu opened (item split).
    ctx_at_frame: i64 = 0,
};

pub fn blocksGlobalHotkeys(view: *const View) bool {
    return view.path_modal != .none or view.show_dirty_confirm or view.show_about or view.fx_target != .none or view.route_track != null or view.rename_track != null or view.ctx_menu != .none;
}

pub fn markDirty(view: *View) void {
    view.project_dirty = true;
}

pub fn clearDirty(view: *View) void {
    view.project_dirty = false;
}

fn setBuf(buf: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, buf.len - 1);
    @memcpy(buf[0..n], src[0..n]);
    len.* = n;
    buf[n] = 0;
}

fn joinDirFile(view: *View) void {
    var out: [1024]u8 = undefined;
    const dir = view.path_dir_buf[0..view.path_dir_len];
    const name = view.path_name_buf[0..view.path_name_len];
    const joined = if (dir.len == 0)
        name
    else if (dir[dir.len - 1] == '/')
        (std.fmt.bufPrint(&out, "{s}{s}", .{ dir, name }) catch name)
    else
        (std.fmt.bufPrint(&out, "{s}/{s}", .{ dir, name }) catch name);
    setBuf(&view.open_path_buf, &view.open_path_len, joined);
}

fn reloadPathListing(view: *View) void {
    view.path_list_len = 0;
    view.path_list_scroll = 0;
    const dir_path = if (view.path_dir_len == 0) "." else view.path_dir_buf[0..view.path_dir_len];
    var path_z: [769]u8 = undefined;
    const plen = @min(dir_path.len, path_z.len - 1);
    @memcpy(path_z[0..plen], dir_path[0..plen]);
    path_z[plen] = 0;

    const dirp = c.opendir(&path_z) orelse return;
    defer _ = c.closedir(dirp);

    const addEntry = struct {
        fn go(v: *View, name: []const u8, is_dir: bool) void {
            if (v.path_list_len >= v.path_list_names.len) return;
            if (name.len == 0 or std.mem.eql(u8, name, ".")) return;
            const i = v.path_list_len;
            const n = @min(name.len, v.path_list_names[i].len - 1);
            @memcpy(v.path_list_names[i][0..n], name[0..n]);
            v.path_list_names[i][n] = 0;
            v.path_list_is_dir[i] = is_dir;
            v.path_list_len += 1;
        }
    }.go;

    addEntry(view, "..", true);

    while (c.readdir(dirp)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const is_dir = ent.*.d_type == c.DT_DIR;
        if (is_dir) {
            addEntry(view, name, true);
        } else {
            const show = switch (view.path_modal) {
                .open => std.mem.endsWith(u8, name, ".json"),
                .save_as => true, // existing projects + type a new name
                .render => std.mem.endsWith(u8, name, ".wav") or std.mem.endsWith(u8, name, ".WAV"),
                .none => false,
            };
            if (show) addEntry(view, name, false);
        }
    }
}

fn enterPathChild(view: *View, name: []const u8) void {
    if (std.mem.eql(u8, name, "..")) {
        const dir = view.path_dir_buf[0..view.path_dir_len];
        if (std.fs.path.dirname(dir)) |parent| {
            setBuf(&view.path_dir_buf, &view.path_dir_len, parent);
        }
    } else {
        var out: [768]u8 = undefined;
        const dir = view.path_dir_buf[0..view.path_dir_len];
        const joined = if (dir.len == 0)
            name
        else if (dir[dir.len - 1] == '/')
            (std.fmt.bufPrint(&out, "{s}{s}", .{ dir, name }) catch return)
        else
            (std.fmt.bufPrint(&out, "{s}/{s}", .{ dir, name }) catch return);
        setBuf(&view.path_dir_buf, &view.path_dir_len, joined);
    }
    reloadPathListing(view);
    joinDirFile(view);
}

fn confirmPathModal(view: *View) void {
    joinDirFile(view);
    switch (view.path_modal) {
        .none => {},
        .open => view.menu_action = .open_confirm,
        .save_as => view.menu_action = .save_as_confirm,
        .render => {
            setBuf(&view.render_path_buf, &view.render_path_len, view.open_path_buf[0..view.open_path_len]);
            view.menu_action = .render_start;
        },
    }
    view.path_modal = .none;
}

/// Open raylib path browser (cwd + name). `default_name` is the filename seed.
pub fn openPathModal(view: *View, mode: PathModal, default_name: []const u8) void {
    view.path_modal = mode;
    view.path_focus = .name;
    view.menu_open = .none;

    if (c.getcwd(&view.path_dir_buf, view.path_dir_buf.len)) |_| {
        view.path_dir_len = std.mem.len(@as([*:0]const u8, @ptrCast(&view.path_dir_buf)));
    } else {
        setBuf(&view.path_dir_buf, &view.path_dir_len, ".");
    }
    setBuf(&view.path_name_buf, &view.path_name_len, default_name);
    view.path_caret = view.path_name_len;
    reloadPathListing(view);
    joinDirFile(view);
}

/// Request quit/open/new/close; if dirty, shows confirm first.
pub fn requestDestructive(view: *View, pending: DirtyPending) void {
    if (pending == .none) return;
    if (view.project_dirty) {
        view.dirty_pending = pending;
        view.show_dirty_confirm = true;
        return;
    }
    emitPendingAction(view, pending);
}

fn emitPendingAction(view: *View, pending: DirtyPending) void {
    switch (pending) {
        .none => {},
        .quit => view.menu_action = .quit,
        .open => openPathModal(view, .open, "999.fastmix.json"),
        .new_project => view.menu_action = .new_project,
        .close_project => view.menu_action = .close_project,
    }
}

pub fn resolveDirtyContinue(view: *View) void {
    const pending = view.dirty_pending;
    view.dirty_pending = .none;
    view.show_dirty_confirm = false;
    emitPendingAction(view, pending);
}

pub fn updatePeaks(view: *View, track_count: usize, block_peaks_l: []const f32, block_peaks_r: []const f32, master: f32) void {
    const decay: f32 = 0.95;
    const n = @min(track_count, view.peaks_l.len);
    for (0..n) |i| {
        const bl = if (i < block_peaks_l.len) block_peaks_l[i] else 0;
        const br = if (i < block_peaks_r.len) block_peaks_r[i] else 0;
        view.peaks_l[i] = @max(bl, view.peaks_l[i] * decay);
        view.peaks_r[i] = @max(br, view.peaks_r[i] * decay);
    }
    view.master_peak = @max(master, view.master_peak * decay);
    view.master_peak_hold = @max(view.master_peak_hold, master);
    if (master >= 0.999) view.master_clip_flag = true;
}

pub fn updateBusPeaks(view: *View, bus_count: usize, block_bus_out: []const f32) void {
    const decay: f32 = 0.95;
    const n = @min(bus_count, view.bus_peaks.len);
    for (0..n) |i| {
        const p = if (i < block_bus_out.len) block_bus_out[i] else 0;
        view.bus_peaks[i] = @max(p, view.bus_peaks[i] * decay);
    }
}

/// Equal-height lanes so all tracks fit TCP+arrange without vertical scroll.
fn laneHeight(area_h: f32, track_count: usize) f32 {
    if (track_count == 0) return @floatFromInt(LANE_H);
    return area_h / @as(f32, @floatFromInt(track_count));
}

fn laneY(area_y: f32, lane_h: f32, ti: usize) f32 {
    return area_y + @as(f32, @floatFromInt(ti)) * lane_h;
}

fn tracksAreaH(chrome: Chrome) f32 {
    return @max(1.0, chrome.tcp.height - @as(f32, @floatFromInt(TCP_FOOTER_H)));
}

fn closeCtxMenu(view: *View) void {
    view.ctx_menu = .none;
}

fn ctxMenuRowCount(kind: CtxMenu) usize {
    return switch (kind) {
        .none => 0,
        .track => 7,
        .item => 4,
        .empty => 3,
    };
}

fn ctxMenuWidth() f32 {
    return 180;
}

fn ctxMenuHeight(kind: CtxMenu) f32 {
    return @as(f32, @floatFromInt(ctxMenuRowCount(kind))) * 28.0;
}

fn openCtxMenu(view: *View, kind: CtxMenu, x: f32, y: f32, at_frame: i64) void {
    view.ctx_menu = kind;
    view.ctx_x = x;
    view.ctx_y = y;
    view.ctx_at_frame = at_frame;
    view.menu_open = .none;
}

fn barToFrame(project: *const model.Project, bar: f64) i64 {
    const beat_sec = 60.0 / project.bpm;
    const bar_sec = @as(f64, @floatFromInt(project.bar_size)) * beat_sec;
    return @intFromFloat(bar * bar_sec * @as(f64, @floatFromInt(project.sample_rate)));
}

fn hitTestAudioClip(
    project: *const model.Project,
    view: *const View,
    chrome: Chrome,
    mx: f32,
    my: f32,
    lane_h: f32,
) ?struct { track_id: model.TrackId, clip_id: model.ClipId } {
    if (!rectContains(chrome.arrange, mx, my)) return null;
    if (my >= chrome.arrange.y + tracksAreaH(chrome)) return null;
    for (project.tracks.items, 0..) |track, ti| {
        const y = laneY(chrome.arrange.y, lane_h, ti);
        if (my < y or my >= y + lane_h) continue;
        for (track.clips.items) |clip| {
            if (clip != .audio) continue;
            const ac = clip.audio;
            const playable = project.audioPlayableFrames(ac);
            if (playable == 0) continue;
            const beat_sec = 60.0 / project.bpm;
            const bar_sec = @as(f64, @floatFromInt(project.bar_size)) * beat_sec;
            const start_bar = @as(f64, @floatFromInt(ac.timeline_start_frame)) / (@as(f64, @floatFromInt(project.sample_rate)) * bar_sec);
            const dur_bar = @as(f64, @floatFromInt(playable)) / (@as(f64, @floatFromInt(project.sample_rate)) * bar_sec);
            const x0 = barToX(view, chrome.arrange.x, @floatCast(start_bar));
            const x1 = barToX(view, chrome.arrange.x, @floatCast(start_bar + dur_bar));
            if (mx >= x0 and mx < x1) return .{ .track_id = track.id, .clip_id = ac.id };
        }
    }
    return null;
}

fn pushUndo(history: *persist.History, gpa: std.mem.Allocator, project: *const model.Project) void {
    history.recordBeforeMutation(gpa, project) catch {};
}

fn beginDrag(history: *persist.History, gpa: std.mem.Allocator, project: *const model.Project, view: *View, drag: Drag) void {
    if (view.drag.kind == .none) pushUndo(history, gpa, project);
    view.drag = drag;
}

fn doUndo(history: *persist.History, gpa: std.mem.Allocator, project: *model.Project, view: *View) void {
    closeCtxMenu(view);
    cancelRename(view);
    view.fx_target = .none;
    const did = history.undo(gpa, project) catch {
        setStatusMsg(view, "Undo failed");
        return;
    };
    if (!did) {
        setStatusMsg(view, "Nothing to undo");
        return;
    }
    if (view.selected_track) |id| {
        if (project.findTrack(id) == null) {
            view.selected_track = if (project.tracks.items.len > 0) project.tracks.items[0].id else null;
        }
    }
    markDirty(view);
    setStatusMsg(view, "Undo");
}

fn doRedo(history: *persist.History, gpa: std.mem.Allocator, project: *model.Project, view: *View) void {
    closeCtxMenu(view);
    cancelRename(view);
    view.fx_target = .none;
    const did = history.redo(gpa, project) catch {
        setStatusMsg(view, "Redo failed");
        return;
    };
    if (!did) {
        setStatusMsg(view, "Nothing to redo");
        return;
    }
    if (view.selected_track) |id| {
        if (project.findTrack(id) == null) {
            view.selected_track = if (project.tracks.items.len > 0) project.tracks.items[0].id else null;
        }
    }
    markDirty(view);
    setStatusMsg(view, "Redo");
}

fn beginRename(view: *View, track: *const model.Track) void {
    view.rename_track = track.id;
    setBuf(&view.rename_buf, &view.rename_len, track.name);
    view.rename_caret = view.rename_len;
    view.menu_open = .none;
}

fn cancelRename(view: *View) void {
    view.rename_track = null;
}

fn commitRename(history: *persist.History, gpa: std.mem.Allocator, project: *model.Project, view: *View) void {
    const id = view.rename_track orelse return;
    const name = std.mem.trim(u8, view.rename_buf[0..view.rename_len], " \t");
    if (name.len > 0) {
        pushUndo(history, gpa, project);
        project.renameTrack(gpa, id, name) catch {};
        markDirty(view);
        setStatusMsg(view, "Renamed");
    }
    view.rename_track = null;
}

fn addAudioTrack(history: *persist.History, gpa: std.mem.Allocator, project: *model.Project, view: *View) void {
    pushUndo(history, gpa, project);
    const n = project.tracks.items.len + 1;
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "Track {d}", .{n}) catch "Track";
    if (project.addTrack(gpa, name)) |t| {
        view.selected_track = t.id;
        markDirty(view);
        setStatusMsg(view, "Track added");
    } else |_| {}
}

fn duplicateSelected(history: *persist.History, gpa: std.mem.Allocator, project: *model.Project, view: *View) void {
    const id = view.selected_track orelse {
        setStatusMsg(view, "No track selected");
        return;
    };
    pushUndo(history, gpa, project);
    if (project.duplicateTrack(gpa, id)) |t| {
        view.selected_track = t.id;
        markDirty(view);
        setStatusMsg(view, "Track duplicated");
    } else |_| {
        setStatusMsg(view, "Duplicate failed");
    }
}

fn removeSelected(history: *persist.History, gpa: std.mem.Allocator, project: *model.Project, view: *View) void {
    const id = view.selected_track orelse {
        setStatusMsg(view, "No track selected");
        return;
    };
    if (project.tracks.items.len <= 1) {
        setStatusMsg(view, "Cannot remove last track");
        return;
    }
    pushUndo(history, gpa, project);
    if (view.rename_track) |rid| if (rid == id) cancelRename(view);
    if (view.fx_target == .track and view.fx_target.track == id) view.fx_target = .none;
    if (!project.removeTrack(gpa, id)) {
        setStatusMsg(view, "Remove failed");
        return;
    }
    view.selected_track = if (project.tracks.items.len > 0) project.tracks.items[0].id else null;
    markDirty(view);
    setStatusMsg(view, "Track removed");
}

fn renameSelected(view: *View, project: *model.Project) void {
    const id = view.selected_track orelse {
        setStatusMsg(view, "No track selected");
        return;
    };
    const track = project.findTrack(id) orelse return;
    beginRename(view, track);
}

fn barToX(view: *const View, arrange_x: f32, bar: f32) f32 {
    return arrange_x + (bar - view.timeline_offset_bars) * view.pixels_per_bar;
}

fn xToBar(view: *const View, arrange_x: f32, x: f32) f32 {
    return view.timeline_offset_bars + (x - arrange_x) / view.pixels_per_bar;
}

fn setStatus(view: *View, msg: []const u8) void {
    const n = @min(msg.len, view.status_msg.len - 1);
    @memcpy(view.status_msg[0..n], msg[0..n]);
    view.status_msg_len = n;
    view.status_msg[n] = 0;
}

pub fn setStatusMsg(view: *View, msg: []const u8) void {
    setStatus(view, msg);
}

fn armOnly(project: *model.Project, track_id: model.TrackId) void {
    for (project.tracks.items) |*t| t.armed = (t.id == track_id);
}

fn eqBandTypeLabel(t: model.EqBandType) []const u8 {
    return switch (t) {
        .peak => "Peak",
        .low_shelf => "Low Shelf",
        .high_shelf => "High Shelf",
        .highpass => "HPF",
    };
}

fn cycleEqBandType(t: model.EqBandType) model.EqBandType {
    return switch (t) {
        .peak => .low_shelf,
        .low_shelf => .high_shelf,
        .high_shelf => .highpass,
        .highpass => .peak,
    };
}

fn eqRowHeight(eff: model.Effect) f32 {
    if (eff.params == .limiter) return 78;
    if (eff.params == .eq and eff.params.eq.bands.items.len > 0) return 118;
    if (eff.params == .sidechain_compressor) return 68;
    return 28;
}

fn effectKindName(eff: model.Effect) [*:0]const u8 {
    return switch (eff.params) {
        .eq => "EQ",
        .compressor => "Compressor",
        .limiter => "Limiter",
        .sidechain_compressor => "Sidechain",
        .delay => "Delay",
        .stereo_width => "Stereo Width",
    };
}

fn fxPanelRect(chrome: Chrome) c.Rectangle {
    const w: f32 = 420;
    const h: f32 = 300;
    return .{
        .x = chrome.arrange.x + 24,
        .y = chrome.arrange.y + 24,
        .width = w,
        .height = h,
    };
}

/// Keep playhead in view while transport runs (Reaper-style soft follow).
pub fn followPlayhead(view: *View, chrome: Chrome, bar_pos: f64, length_bars: i64) void {
    if (!isRunning(view.transport)) return;
    const margin: f32 = 56;
    const ph_x = barToX(view, chrome.arrange.x, @floatCast(bar_pos));
    const left = chrome.arrange.x + margin;
    const right = chrome.arrange.x + chrome.arrange.width - margin;
    if (ph_x <= right and ph_x >= left) return;
    const visible = chrome.arrange.width / view.pixels_per_bar;
    const target = @as(f32, @floatCast(bar_pos)) - visible * 0.25;
    const max_off = @max(0.0, @as(f32, @floatFromInt(length_bars)) - visible * 0.4);
    view.timeline_offset_bars = std.math.clamp(target, 0.0, max_off);
}

fn invalidateSidechainWet(eff: *model.Effect) void {
    if (eff.params == .sidechain_compressor) {
        eff.params.sidechain_compressor.wet_asset_id = null;
    }
}

fn trackFxLit(track: *const model.Track) bool {
    return track.fx_enabled and track.effects.items.len > 0;
}

fn cycleGridDiv(cur: i32, dir: i32) i32 {
    const steps = [_]i32{ 0, 1, 2, 4, 8, 16, 12, 24 };
    var idx: usize = 0;
    for (steps, 0..) |s, i| {
        if (s == cur) {
            idx = i;
            break;
        }
    }
    if (dir > 0) {
        if (idx + 1 < steps.len) return steps[idx + 1];
        return steps[steps.len - 1];
    }
    if (idx > 0) return steps[idx - 1];
    return steps[0];
}

fn gridDivLabel(div: i32) [*:0]const u8 {
    return switch (div) {
        0 => "Off",
        1 => "1 bar",
        2 => "1/2",
        4 => "1/4",
        8 => "1/8",
        16 => "1/16",
        12 => "1/8T",
        24 => "1/16T",
        else => "1/4",
    };
}

const GRID_MENU_OPTIONS = [_]i32{ 0, 1, 2, 4, 8, 16, 12, 24 };

fn gridMenuOptions() []const i32 {
    return &GRID_MENU_OPTIONS;
}

fn snapTempOff() bool {
    return c.IsKeyDown(c.KEY_LEFT_SHIFT) or c.IsKeyDown(c.KEY_RIGHT_SHIFT);
}

fn snapActive(view: *const View) bool {
    return view.snap_enabled and !snapTempOff();
}

/// Snap musical bar position to grid (Shift = temporary bypass).
pub fn snapBar(view: *const View, bar: f64) f64 {
    if (!snapActive(view)) return bar;
    const div = view.grid_div;
    const step: f64 = if (div <= 0) 1.0 else 1.0 / @as(f64, @floatFromInt(div));
    return @round(bar / step) * step;
}

fn effectsForTarget(project: *model.Project, target: FxTarget) ?[]model.Effect {
    return switch (target) {
        .none => null,
        .track => |tid| if (project.findTrack(tid)) |t| t.effects.items else null,
        .master => project.master_effects.items,
    };
}

/// Mouse/keyboard chrome interactions. Returns true if a transport action was
/// requested via UI buttons (caller also handles Space/R keys).
pub fn handleInput(gpa: std.mem.Allocator, history: *persist.History, project: *model.Project, view: *View, chrome: Chrome) void {
    view.track_scroll_y = 0; // fit-all lanes; field kept for View ABI / future opt-in
    const mouse = c.GetMousePosition();
    const mx = mouse.x;
    const my = mouse.y;
    const wheel = c.GetMouseWheelMove();
    const ml = computeMenuLayout(chrome);
    const tl = computeTransportLayout(chrome);
    const lane_h = laneHeight(tracksAreaH(chrome), project.tracks.items.len);

    // Modal: dirty confirm
    if (view.show_dirty_confirm) {
        if (c.IsKeyPressed(c.KEY_ESCAPE)) {
            view.show_dirty_confirm = false;
            view.dirty_pending = .none;
            return;
        }
        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            const dlg_x: f32 = chrome.transport.width * 0.5 - 180;
            const dlg_y: f32 = 140;
            // Save
            if (mx >= dlg_x + 20 and mx < dlg_x + 110 and my >= dlg_y + 70 and my < dlg_y + 98) {
                view.menu_action = .dirty_save;
                return;
            }
            // Discard
            if (mx >= dlg_x + 120 and mx < dlg_x + 230 and my >= dlg_y + 70 and my < dlg_y + 98) {
                view.menu_action = .dirty_discard;
                return;
            }
            // Cancel
            if (mx >= dlg_x + 240 and mx < dlg_x + 340 and my >= dlg_y + 70 and my < dlg_y + 98) {
                view.show_dirty_confirm = false;
                view.dirty_pending = .none;
                return;
            }
        }
        return;
    }

    // Modal: About
    if (view.show_about) {
        if (c.IsKeyPressed(c.KEY_ESCAPE) or (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT))) {
            view.show_about = false;
        }
        return;
    }

    // Context menu (RMB)
    if (view.ctx_menu != .none) {
        const mw = ctxMenuWidth();
        const mh = ctxMenuHeight(view.ctx_menu);
        if (c.IsKeyPressed(c.KEY_ESCAPE)) {
            closeCtxMenu(view);
            return;
        }
        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT) or c.IsMouseButtonPressed(c.MOUSE_BUTTON_RIGHT)) {
            const inside = mx >= view.ctx_x and mx < view.ctx_x + mw and my >= view.ctx_y and my < view.ctx_y + mh;
            if (!inside) {
                closeCtxMenu(view);
                // fall through so a new RMB can open another menu / LMB hits chrome
            } else if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
                const row: i32 = @intFromFloat((my - view.ctx_y) / 28.0);
                const kind = view.ctx_menu;
                closeCtxMenu(view);
                switch (kind) {
                    .none => {},
                    .track => |tid| {
                        view.selected_track = tid;
                        const track = project.findTrack(tid) orelse return;
                        switch (row) {
                            0 => beginRename(view, track),
                            1 => {
                                view.selected_track = tid;
                                duplicateSelected(history, gpa, project, view);
                            },
                            2 => {
                                view.selected_track = tid;
                                removeSelected(history, gpa, project, view);
                            },
                            3 => {
                                pushUndo(history, gpa, project);
                                if (!track.armed) armOnly(project, tid) else track.armed = false;
                                markDirty(view);
                            },
                            4 => {
                                pushUndo(history, gpa, project);
                                track.mute = !track.mute;
                                markDirty(view);
                            },
                            5 => {
                                pushUndo(history, gpa, project);
                                track.solo = !track.solo;
                                markDirty(view);
                            },
                            6 => view.fx_target = .{ .track = tid },
                            else => {},
                        }
                    },
                    .item => |it| {
                        view.selected_track = it.track_id;
                        switch (row) {
                            0 => {
                                pushUndo(history, gpa, project);
                                project.splitAudioAtFrame(gpa, it.track_id, it.clip_id, view.ctx_at_frame) catch {
                                    setStatusMsg(view, "Split: put RMB inside clip");
                                    return;
                                };
                                markDirty(view);
                                setStatusMsg(view, "Split");
                            },
                            1 => {
                                pushUndo(history, gpa, project);
                                if (project.removeClip(gpa, it.track_id, it.clip_id)) {
                                    markDirty(view);
                                    setStatusMsg(view, "Item deleted");
                                }
                            },
                            2 => {
                                pushUndo(history, gpa, project);
                                _ = project.duplicateClip(gpa, it.track_id, it.clip_id) catch {
                                    setStatusMsg(view, "Duplicate item failed");
                                    return;
                                };
                                markDirty(view);
                                setStatusMsg(view, "Item duplicated");
                            },
                            3 => {
                                pushUndo(history, gpa, project);
                                if (project.findClip(it.track_id, it.clip_id)) |cl| {
                                    if (cl.* == .audio) {
                                        cl.audio.muted = !cl.audio.muted;
                                        markDirty(view);
                                        setStatusMsg(view, if (cl.audio.muted) "Item muted" else "Item unmuted");
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    .empty => switch (row) {
                        0 => addAudioTrack(history, gpa, project, view),
                        1 => setStatusMsg(view, "Import audio: use AI import_audio for now"),
                        2 => setStatusMsg(view, "Paste: not yet"),
                        else => {},
                    },
                }
                return;
            } else {
                return;
            }
        } else {
            return;
        }
    }

    // Inline track rename
    if (view.rename_track != null) {
        while (true) {
            const key = c.GetCharPressed();
            if (key == 0) break;
            if (key >= 32 and key < 127 and view.rename_len + 1 < view.rename_buf.len) {
                const ch: u8 = @intCast(key);
                if (view.rename_caret > view.rename_len) view.rename_caret = view.rename_len;
                var i = view.rename_len;
                while (i > view.rename_caret) : (i -= 1) {
                    view.rename_buf[i] = view.rename_buf[i - 1];
                }
                view.rename_buf[view.rename_caret] = ch;
                view.rename_len += 1;
                view.rename_caret += 1;
                view.rename_buf[view.rename_len] = 0;
            }
        }
        if (c.IsKeyPressed(c.KEY_BACKSPACE) and view.rename_caret > 0) {
            view.rename_caret -= 1;
            var i = view.rename_caret;
            while (i + 1 < view.rename_len) : (i += 1) {
                view.rename_buf[i] = view.rename_buf[i + 1];
            }
            view.rename_len -= 1;
            view.rename_buf[view.rename_len] = 0;
        }
        if (c.IsKeyPressed(c.KEY_LEFT) and view.rename_caret > 0) view.rename_caret -= 1;
        if (c.IsKeyPressed(c.KEY_RIGHT) and view.rename_caret < view.rename_len) view.rename_caret += 1;
        if (c.IsKeyPressed(c.KEY_HOME)) view.rename_caret = 0;
        if (c.IsKeyPressed(c.KEY_END)) view.rename_caret = view.rename_len;
        if (c.IsKeyPressed(c.KEY_ENTER) or c.IsKeyPressed(c.KEY_KP_ENTER)) {
            commitRename(history, gpa, project, view);
            return;
        }
        if (c.IsKeyPressed(c.KEY_ESCAPE)) {
            cancelRename(view);
            return;
        }
        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            commitRename(history, gpa, project, view);
            // fall through so click can still hit other UI
        } else {
            return;
        }
    }

    // Modal: Open / Save As — folder list + editable filename
    if (view.path_modal != .none) {
        const dlg_w: f32 = 560;
        const dlg_h: f32 = 420;
        const dlg_x: f32 = chrome.transport.width * 0.5 - dlg_w * 0.5;
        const dlg_y: f32 = 70;
        const list_x = dlg_x + 12;
        const list_y = dlg_y + 56;
        const list_w = dlg_w - 24;
        const list_h: f32 = 240;
        const row_h: f32 = 22;
        const visible_rows: usize = @intFromFloat(list_h / row_h);
        const name_y = dlg_y + 310;
        const ok_x = dlg_x + dlg_w - 160;
        const cancel_x = dlg_x + dlg_w - 80;
        const btn_y = dlg_y + dlg_h - 40;

        // Text into filename when focused
        if (view.path_focus == .name) {
            while (true) {
                const key = c.GetCharPressed();
                if (key == 0) break;
                if (key >= 32 and key < 127 and view.path_name_len + 1 < view.path_name_buf.len) {
                    const ch: u8 = @intCast(key);
                    // Insert at caret
                    if (view.path_caret > view.path_name_len) view.path_caret = view.path_name_len;
                    var i = view.path_name_len;
                    while (i > view.path_caret) : (i -= 1) {
                        view.path_name_buf[i] = view.path_name_buf[i - 1];
                    }
                    view.path_name_buf[view.path_caret] = ch;
                    view.path_name_len += 1;
                    view.path_caret += 1;
                    view.path_name_buf[view.path_name_len] = 0;
                    joinDirFile(view);
                }
            }
            if (c.IsKeyPressed(c.KEY_BACKSPACE) and view.path_caret > 0) {
                view.path_caret -= 1;
                var i = view.path_caret;
                while (i + 1 < view.path_name_len) : (i += 1) {
                    view.path_name_buf[i] = view.path_name_buf[i + 1];
                }
                view.path_name_len -= 1;
                view.path_name_buf[view.path_name_len] = 0;
                joinDirFile(view);
            }
            if (c.IsKeyPressed(c.KEY_LEFT) and view.path_caret > 0) view.path_caret -= 1;
            if (c.IsKeyPressed(c.KEY_RIGHT) and view.path_caret < view.path_name_len) view.path_caret += 1;
            if (c.IsKeyPressed(c.KEY_HOME)) view.path_caret = 0;
            if (c.IsKeyPressed(c.KEY_END)) view.path_caret = view.path_name_len;
        }

        if (c.IsKeyPressed(c.KEY_ENTER) or c.IsKeyPressed(c.KEY_KP_ENTER)) {
            confirmPathModal(view);
            return;
        }
        if (c.IsKeyPressed(c.KEY_ESCAPE)) {
            view.path_modal = .none;
            return;
        }

        if (wheel != 0 and mx >= list_x and mx < list_x + list_w and my >= list_y and my < list_y + list_h) {
            const max_scroll = if (view.path_list_len > visible_rows) view.path_list_len - visible_rows else 0;
            if (wheel > 0 and view.path_list_scroll > 0) view.path_list_scroll -= 1;
            if (wheel < 0 and view.path_list_scroll < max_scroll) view.path_list_scroll += 1;
        }

        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            // Name field
            if (mx >= list_x and mx < list_x + list_w and my >= name_y and my < name_y + 28) {
                view.path_focus = .name;
                return;
            }
            // List rows
            if (mx >= list_x and mx < list_x + list_w and my >= list_y and my < list_y + list_h) {
                view.path_focus = .list;
                const rel = my - list_y;
                const row: usize = @intFromFloat(rel / row_h);
                const idx = view.path_list_scroll + row;
                if (idx < view.path_list_len) {
                    const nm = std.mem.sliceTo(&view.path_list_names[idx], 0);
                    if (view.path_list_is_dir[idx]) {
                        enterPathChild(view, nm);
                    } else {
                        setBuf(&view.path_name_buf, &view.path_name_len, nm);
                        view.path_caret = view.path_name_len;
                        view.path_focus = .name;
                        joinDirFile(view);
                    }
                }
                return;
            }
            if (mx >= ok_x and mx < ok_x + 70 and my >= btn_y and my < btn_y + 28) {
                confirmPathModal(view);
                return;
            }
            if (mx >= cancel_x and mx < cancel_x + 70 and my >= btn_y and my < btn_y + 28) {
                view.path_modal = .none;
                return;
            }
        }
        return;
    }

    // FX panel (modal)
    if (view.fx_target != .none) {
        const panel = fxPanelRect(chrome);
        if (c.IsKeyPressed(c.KEY_ESCAPE)) {
            view.fx_target = .none;
            view.drag = .{};
            return;
        }
        // Param drag while panel open
        if (view.drag.kind == .fx_thresh or view.drag.kind == .fx_ratio or view.drag.kind == .fx_lim_thresh or view.drag.kind == .fx_lim_ceiling or view.drag.kind == .fx_eq_freq or view.drag.kind == .fx_eq_gain or view.drag.kind == .fx_eq_q) {
            if (!c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT)) {
                if (view.fx_target == .track) view.fx_apply_track = view.fx_target.track;
                view.drag = .{};
            } else {
                applyDrag(project, view, chrome, mx, my);
            }
            return;
        }
        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            if (!rectContains(panel, mx, my)) {
                // Close and fall through so a click on TCP still hits R/M/S/FX.
                view.fx_target = .none;
                view.drag = .{};
            } else {
            // Chain enable (track only)
            if (view.fx_target == .track) {
                const tid = view.fx_target.track;
                if (project.findTrack(tid)) |track| {
                    if (my >= panel.y + 36 and my < panel.y + 60 and mx >= panel.x + 12 and mx < panel.x + 120) {
                        pushUndo(history, gpa, project);
                        track.fx_enabled = !track.fx_enabled;
                        view.fx_apply_track = tid;
                        markDirty(view);
                        return;
                    }
                    if (effectsForTarget(project, view.fx_target)) |effects| {
                        const list_y = panel.y + 72;
                        var row_y = list_y;
                        for (effects, 0..) |*eff, i| {
                            const row_h = eqRowHeight(eff.*);
                            // bypass effect
                            if (my >= row_y and my < row_y + 24 and mx >= panel.x + 300 and mx < panel.x + 400) {
                                pushUndo(history, gpa, project);
                                eff.bypassed = !eff.bypassed;
                                view.fx_apply_track = tid;
                                markDirty(view);
                                return;
                            }
                            if (eff.params == .sidechain_compressor) {
                                if (my >= row_y + 28 and my < row_y + 44 and mx >= panel.x + 140 and mx < panel.x + 380) {
                                    beginDrag(history, gpa, project, view, .{ .kind = .fx_thresh, .effect_index = i });
                                    applyDrag(project, view, chrome, mx, my);
                                    return;
                                }
                                if (my >= row_y + 48 and my < row_y + 64 and mx >= panel.x + 140 and mx < panel.x + 380) {
                                    beginDrag(history, gpa, project, view, .{ .kind = .fx_ratio, .effect_index = i });
                                    applyDrag(project, view, chrome, mx, my);
                                    return;
                                }
                            } else if (eff.params == .eq and eff.params.eq.bands.items.len > 0) {
                                // Type cycle
                                if (my >= row_y + 26 and my < row_y + 46 and mx >= panel.x + 12 and mx < panel.x + 130) {
                                    pushUndo(history, gpa, project);
                                    const b = &eff.params.eq.bands.items[0];
                                    const nt = cycleEqBandType(b.band_type);
                                    if (nt == .highpass and b.gain_db != 0.0) {
                                        // refuse silent double-mutation; force gain to 0 first via UI
                                        b.gain_db = 0.0;
                                    }
                                    b.band_type = nt;
                                    if (nt == .highpass) b.gain_db = 0.0;
                                    view.fx_apply_track = tid;
                                    markDirty(view);
                                    return;
                                }
                                // band bypass
                                if (my >= row_y + 26 and my < row_y + 46 and mx >= panel.x + 300 and mx < panel.x + 400) {
                                    pushUndo(history, gpa, project);
                                    eff.params.eq.bands.items[0].bypass = !eff.params.eq.bands.items[0].bypass;
                                    view.fx_apply_track = tid;
                                    markDirty(view);
                                    return;
                                }
                                if (my >= row_y + 50 and my < row_y + 66 and mx >= panel.x + 140 and mx < panel.x + 380) {
                                    beginDrag(history, gpa, project, view, .{ .kind = .fx_eq_freq, .effect_index = i });
                                    applyDrag(project, view, chrome, mx, my);
                                    return;
                                }
                                if (eff.params.eq.bands.items[0].band_type != .highpass) {
                                    if (my >= row_y + 70 and my < row_y + 86 and mx >= panel.x + 140 and mx < panel.x + 380) {
                                        beginDrag(history, gpa, project, view, .{ .kind = .fx_eq_gain, .effect_index = i });
                                        applyDrag(project, view, chrome, mx, my);
                                        return;
                                    }
                                }
                                if (my >= row_y + 90 and my < row_y + 106 and mx >= panel.x + 140 and mx < panel.x + 380) {
                                    beginDrag(history, gpa, project, view, .{ .kind = .fx_eq_q, .effect_index = i });
                                    applyDrag(project, view, chrome, mx, my);
                                    return;
                                }
                            }
                            row_y += row_h + 4;
                        }
                    }
                }
            } else if (view.fx_target == .master) {
                const en = project.master_fx_enabled;
                if (my >= panel.y + 36 and my < panel.y + 58 and mx >= panel.x + 12 and mx < panel.x + 122) {
                    pushUndo(history, gpa, project);
                    project.master_fx_enabled = !project.master_fx_enabled;
                    markDirty(view);
                    return;
                }
                _ = en;
                // Analyze / Validate / Reset peak
                if (my >= panel.y + 36 and my < panel.y + 58) {
                    if (mx >= panel.x + 130 and mx < panel.x + 250) {
                        view.menu_action = .analyze_master_program;
                        return;
                    }
                    if (mx >= panel.x + 260 and mx < panel.x + 390) {
                        view.menu_action = .validate_master_delivery;
                        return;
                    }
                    if (mx >= panel.x + 400 and mx < panel.x + 500) {
                        view.menu_action = .reset_master_peak;
                        return;
                    }
                }
                if (effectsForTarget(project, view.fx_target)) |effects| {
                    const list_y = panel.y + 160;
                    for (effects, 0..) |*eff, i| {
                        const row_h: f32 = if (eff.params == .limiter) 78 else 28;
                        const row_y = list_y + @as(f32, @floatFromInt(i)) * 82;
                        if (my >= row_y and my < row_y + 24 and mx >= panel.x + 300 and mx < panel.x + 400) {
                            pushUndo(history, gpa, project);
                            eff.bypassed = !eff.bypassed;
                            markDirty(view);
                            return;
                        }
                        if (eff.params == .limiter) {
                            if (my >= row_y + 28 and my < row_y + 44 and mx >= panel.x + 140 and mx < panel.x + 380) {
                                beginDrag(history, gpa, project, view, .{ .kind = .fx_lim_thresh, .effect_index = i });
                                applyDrag(project, view, chrome, mx, my);
                                return;
                            }
                            if (my >= row_y + 48 and my < row_y + 64 and mx >= panel.x + 140 and mx < panel.x + 380) {
                                beginDrag(history, gpa, project, view, .{ .kind = .fx_lim_ceiling, .effect_index = i });
                                applyDrag(project, view, chrome, mx, my);
                                return;
                            }
                        }
                        _ = row_h;
                    }
                }
            }
            return;
            }
        }
        if (view.fx_target != .none) return;
    }

    // Route inspector (modal)
    if (view.route_track) |rid| {
        const panel = fxPanelRect(chrome);
        if (c.IsKeyPressed(c.KEY_ESCAPE)) {
            view.route_track = null;
            return;
        }
        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            if (!rectContains(panel, mx, my)) {
                view.route_track = null;
            } else if (project.findTrack(rid)) |track| {
                if (my >= panel.y + 36 and my < panel.y + 58 and mx >= panel.x + 12 and mx < panel.x + 280) {
                    pushUndo(history, gpa, project);
                    track.master_send_enabled = !track.master_send_enabled;
                    if (track.master_send_enabled) track.post_master_enabled = false;
                    markDirty(view);
                    return;
                }
                if (my >= panel.y + 58 and my < panel.y + 80 and mx >= panel.x + 12 and mx < panel.x + 280) {
                    pushUndo(history, gpa, project);
                    track.post_master_enabled = !track.post_master_enabled;
                    if (track.post_master_enabled) track.master_send_enabled = false;
                    markDirty(view);
                    return;
                }
                const add_y = panel.y + panel.height - 48;
                if (my >= add_y and my < add_y + 22 and mx >= panel.x + 12 and mx < panel.x + 140) {
                    if (project.buses.items.len > 0) {
                        pushUndo(history, gpa, project);
                        _ = project.addSend(gpa, rid, project.buses.items[0].id, 0.0, .post_fader) catch {};
                        markDirty(view);
                    }
                    return;
                }
            }
            if (view.route_track != null) return;
        } else {
            return;
        }
    }

    // Menu bar clicks / dropdown
    if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT) and rectContains(chrome.menu, mx, my)) {
        view.grid_menu_open = false;
        if (rectContains(ml.app, mx, my)) {
            view.menu_open = if (view.menu_open == .app) .none else .app;
        } else if (rectContains(ml.file, mx, my)) {
            view.menu_open = if (view.menu_open == .file) .none else .file;
        } else if (rectContains(ml.edit, mx, my)) {
            view.menu_open = if (view.menu_open == .edit) .none else .edit;
        } else if (rectContains(ml.track, mx, my)) {
            view.menu_open = if (view.menu_open == .track) .none else .track;
        } else if (rectContains(ml.options, mx, my)) {
            view.menu_open = if (view.menu_open == .options) .none else .options;
        } else {
            view.menu_open = .none;
        }
        return;
    }
    if (view.menu_open != .none and c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
        const drop_y = chrome.menu.height;
        const row_h: f32 = 28;
        if (view.menu_open == .app) {
            const panel = rect(ml.app.x, drop_y, 130, 56);
            if (rectContains(panel, mx, my)) {
                const row: i32 = @intFromFloat((my - drop_y) / row_h);
                view.menu_open = .none;
                if (row == 0) {
                    view.show_about = true;
                } else if (row == 1) {
                    requestDestructive(view, .quit);
                }
                return;
            }
        }
        if (view.menu_open == .file) {
            const panel = rect(ml.file.x, drop_y, 170, 196);
            if (rectContains(panel, mx, my)) {
                const row: i32 = @intFromFloat((my - drop_y) / row_h);
                view.menu_open = .none;
                switch (row) {
                    0 => requestDestructive(view, .new_project),
                    1 => requestDestructive(view, .open),
                    2 => requestDestructive(view, .close_project),
                    3 => {
                        view.menu_action = .save;
                    },
                    4 => openPathModal(view, .save_as, "project.fastmix.json"),
                    5 => openPathModal(view, .render, "master.wav"),
                    6 => requestDestructive(view, .quit),
                    else => {},
                }
                return;
            }
        }
        if (view.menu_open == .edit) {
            const panel = rect(ml.edit.x, drop_y, 140, 56);
            if (rectContains(panel, mx, my)) {
                const row: i32 = @intFromFloat((my - drop_y) / row_h);
                view.menu_open = .none;
                switch (row) {
                    0 => doUndo(history, gpa, project, view),
                    1 => doRedo(history, gpa, project, view),
                    else => {},
                }
                return;
            }
        }
        if (view.menu_open == .track) {
            const panel = rect(ml.track.x, drop_y, 170, 112);
            if (rectContains(panel, mx, my)) {
                const row: i32 = @intFromFloat((my - drop_y) / row_h);
                view.menu_open = .none;
                switch (row) {
                    0 => addAudioTrack(history, gpa, project, view),
                    1 => duplicateSelected(history, gpa, project, view),
                    2 => removeSelected(history, gpa, project, view),
                    3 => renameSelected(view, project),
                    else => {},
                }
                return;
            }
        }
        if (view.menu_open == .options) {
            const panel = rect(ml.options.x, drop_y, 220, 28);
            if (rectContains(panel, mx, my)) {
                view.menu_open = .none;
                view.menu_action = .cycle_audio_block_size;
                return;
            }
        }
        view.menu_open = .none;
        return;
    }

    // Undo / Redo hotkeys (⌘/Ctrl+Z, Shift+Z / Y)
    if (!blocksGlobalHotkeys(view)) {
        const ctrl = c.IsKeyDown(c.KEY_LEFT_CONTROL) or c.IsKeyDown(c.KEY_RIGHT_CONTROL) or c.IsKeyDown(c.KEY_LEFT_SUPER) or c.IsKeyDown(c.KEY_RIGHT_SUPER);
        const shift = c.IsKeyDown(c.KEY_LEFT_SHIFT) or c.IsKeyDown(c.KEY_RIGHT_SHIFT);
        if (ctrl and c.IsKeyPressed(c.KEY_Z)) {
            if (shift) doRedo(history, gpa, project, view) else doUndo(history, gpa, project, view);
            return;
        }
        if (ctrl and c.IsKeyPressed(c.KEY_Y)) {
            doRedo(history, gpa, project, view);
            return;
        }
    }

    // Grid ▾ dropdown
    if (view.grid_menu_open) {
        const opts = gridMenuOptions();
        const menu_x = tl.grid.x;
        const menu_y = tl.grid.y + tl.grid.height + 2;
        const mw: f32 = @max(110.0, tl.grid.width);
        const row_h: f32 = 24;
        const mh = @as(f32, @floatFromInt(opts.len)) * row_h;
        if (c.IsKeyPressed(c.KEY_ESCAPE)) {
            view.grid_menu_open = false;
            return;
        }
        if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) {
            if (mx >= menu_x and mx < menu_x + mw and my >= menu_y and my < menu_y + mh) {
                const row: usize = @intFromFloat((my - menu_y) / row_h);
                if (row < opts.len) view.grid_div = opts[row];
                view.grid_menu_open = false;
                return;
            }
            if (!rectContains(tl.snap, mx, my) and !rectContains(tl.grid, mx, my)) {
                view.grid_menu_open = false;
            }
        }
    }

    if (!blocksGlobalHotkeys(view) and (rectContains(chrome.arrange, mx, my) or rectContains(chrome.ruler, mx, my) or rectContains(chrome.tcp, mx, my)) and wheel != 0) {
        // No vertical track scroll — wheel always zooms timeline (incl. over TCP).
        view.pixels_per_bar = std.math.clamp(view.pixels_per_bar * (1.0 + wheel * 0.1), 20.0, 400.0);
    }

    // Middle-drag / shift+wheel pan timeline
    if (c.IsMouseButtonDown(c.MOUSE_BUTTON_MIDDLE) and (rectContains(chrome.arrange, mx, my) or rectContains(chrome.ruler, mx, my))) {
        const dx = c.GetMouseDelta().x;
        view.timeline_offset_bars -= dx / view.pixels_per_bar;
        view.timeline_offset_bars = std.math.clamp(view.timeline_offset_bars, 0.0, @as(f32, @floatFromInt(project.length_bars)));
    }
    if (c.IsKeyDown(c.KEY_LEFT_SHIFT) and wheel != 0 and rectContains(chrome.arrange, mx, my)) {
        view.timeline_offset_bars = std.math.clamp(view.timeline_offset_bars - wheel * 0.5, 0.0, @as(f32, @floatFromInt(project.length_bars)));
    }
    if (c.IsKeyDown(c.KEY_LEFT)) view.timeline_offset_bars = @max(0, view.timeline_offset_bars - 0.15);
    if (c.IsKeyDown(c.KEY_RIGHT)) view.timeline_offset_bars = @min(@as(f32, @floatFromInt(project.length_bars)), view.timeline_offset_bars + 0.15);

    // Active drag
    if (view.drag.kind != .none) {
        if (!c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT)) {
            if (view.drag.kind == .fx_thresh or view.drag.kind == .fx_ratio or view.drag.kind == .fx_lim_thresh or view.drag.kind == .fx_lim_ceiling or view.drag.kind == .fx_eq_freq or view.drag.kind == .fx_eq_gain or view.drag.kind == .fx_eq_q) {
                if (view.fx_target == .track) view.fx_apply_track = view.fx_target.track;
            }
            view.drag = .{};
        } else {
            applyDrag(project, view, chrome, mx, my);
            return;
        }
    }

    // Right-click: FX power on FX btn; otherwise context menu (track / item / empty)
    if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_RIGHT)) {
        if (rectContains(chrome.tcp, mx, my) and my < chrome.tcp.y + tracksAreaH(chrome)) {
            for (project.tracks.items, 0..) |*track, ti| {
                const lane = computeTcpLane(chrome, lane_h, ti);
                if (!rectContains(lane.lane, mx, my)) continue;
                if (rectContains(lane.fx, mx, my)) {
                    pushUndo(history, gpa, project);
                    track.fx_enabled = !track.fx_enabled;
                    view.fx_apply_track = track.id;
                    markDirty(view);
                    return;
                }
                view.selected_track = track.id;
                openCtxMenu(view, .{ .track = track.id }, mx, my, 0);
                return;
            }
        }
        if (rectContains(chrome.arrange, mx, my) and my < chrome.arrange.y + tracksAreaH(chrome)) {
            const at_bar = snapBar(view, @floatCast(xToBar(view, chrome.arrange.x, mx)));
            const at_frame = barToFrame(project, at_bar);
            if (hitTestAudioClip(project, view, chrome, mx, my, lane_h)) |hit| {
                view.selected_track = hit.track_id;
                openCtxMenu(view, .{ .item = .{ .track_id = hit.track_id, .clip_id = hit.clip_id } }, mx, my, at_frame);
                return;
            }
            for (project.tracks.items, 0..) |track, ti| {
                const y = laneY(chrome.arrange.y, lane_h, ti);
                if (my >= y and my < y + lane_h) {
                    view.selected_track = track.id;
                    openCtxMenu(view, .{ .track = track.id }, mx, my, at_frame);
                    return;
                }
            }
            openCtxMenu(view, .empty, mx, my, at_frame);
            return;
        }
    }

    if (c.IsKeyPressed(c.KEY_LEFT_BRACKET)) {
        view.grid_div = cycleGridDiv(view.grid_div, -1);
    }
    if (c.IsKeyPressed(c.KEY_RIGHT_BRACKET)) {
        view.grid_div = cycleGridDiv(view.grid_div, 1);
    }
    if (!blocksGlobalHotkeys(view) and c.IsKeyPressed(c.KEY_SLASH)) {
        view.fx_bypass_all = !view.fx_bypass_all;
        return;
    }

    if (!c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT)) return;

    // Transport: stop / play / rec / metro / ALIGN / SNAP / Grid / BPM(clock)
    if (rectContains(chrome.transport, mx, my)) {
        if (rectContains(tl.stop, mx, my)) {
            view.transport = stepTransport(view.transport, .stop_btn);
            return;
        }
        if (rectContains(tl.play, mx, my)) {
            view.transport = stepTransport(view.transport, .play_btn);
            return;
        }
        if (rectContains(tl.record, mx, my)) {
            view.transport = stepTransport(view.transport, .record_key);
            return;
        }
        if (rectContains(tl.metro, mx, my)) {
            view.metronome = !view.metronome;
            return;
        }
        if (rectContains(tl.align_btn, mx, my)) {
            pushUndo(history, gpa, project);
            view.align_requested = true;
            markDirty(view);
            return;
        }
        if (rectContains(tl.snap, mx, my)) {
            view.snap_enabled = !view.snap_enabled;
            view.grid_menu_open = false;
            return;
        }
        if (rectContains(tl.grid, mx, my)) {
            view.grid_menu_open = !view.grid_menu_open;
            return;
        }
        if (rectContains(tl.dry, mx, my)) {
            view.fx_bypass_all = !view.fx_bypass_all;
            return;
        }
        if (rectContains(tl.clock, mx, my)) {
            beginDrag(history, gpa, project, view, .{ .kind = .bpm });
            return;
        }
    }

    // Master FX + volume fader
    if (rectContains(chrome.master, mx, my)) {
        if (my >= chrome.master.y + 36 and my < chrome.master.y + 58 and mx >= chrome.master.x + 8 and mx < chrome.master.x + MASTER_W - 8) {
            view.fx_target = .master;
            return;
        }
        const fader_top = chrome.master.y + 70;
        const fader_bot = chrome.master.y + @as(f32, @floatFromInt(MCP_H)) - 40;
        if (my >= fader_top and my < fader_bot and mx >= chrome.master.x + 20 and mx < chrome.master.x + MASTER_W - 20) {
            beginDrag(history, gpa, project, view, .{ .kind = .mcp_master_vol });
            applyDrag(project, view, chrome, mx, my);
            return;
        }
    }

    // MCP strips + [+]
    if (rectContains(chrome.mcp, mx, my) and mx < chrome.master.x) {
        const mcp_slots = project.tracks.items.len + project.buses.items.len;
        if (computeMcpAddButton(chrome, mcp_slots)) |add_btn| {
            if (rectContains(add_btn, mx, my)) {
                addAudioTrack(history, gpa, project, view);
                return;
            }
        }
        for (project.tracks.items, 0..) |*track, ti| {
            const strip = computeMcpStrip(chrome, ti) orelse break;
            if (mx < strip.strip.x or mx >= strip.strip.x + strip.strip.width) continue;
            view.selected_track = track.id;
            if (rectContains(strip.arm, mx, my) or rectContains(strip.mute, mx, my) or rectContains(strip.solo, mx, my)) {
                pushUndo(history, gpa, project);
                if (rectContains(strip.arm, mx, my)) {
                    if (!track.armed) armOnly(project, track.id) else track.armed = false;
                } else if (rectContains(strip.mute, mx, my)) track.mute = !track.mute else track.solo = !track.solo;
                markDirty(view);
                return;
            }
            if (my >= strip.fader.y and my < strip.fader.y + strip.fader.height) {
                beginDrag(history, gpa, project, view, .{ .kind = .mcp_vol, .track_index = ti });
                applyDrag(project, view, chrome, mx, my);
                return;
            }
            if (rectContains(strip.pan, mx, my)) {
                beginDrag(history, gpa, project, view, .{ .kind = .mcp_pan, .track_index = ti });
                applyDrag(project, view, chrome, mx, my);
                return;
            }
        }
        const base_ti = project.tracks.items.len;
        for (project.buses.items, 0..) |*bus, bi| {
            const strip = computeMcpStrip(chrome, base_ti + bi) orelse break;
            if (mx < strip.strip.x or mx >= strip.strip.x + strip.strip.width) continue;
            if (rectContains(strip.mute, mx, my) or rectContains(strip.solo, mx, my)) {
                pushUndo(history, gpa, project);
                if (rectContains(strip.mute, mx, my)) bus.mute = !bus.mute else bus.solo = !bus.solo;
                markDirty(view);
                return;
            }
            if (my >= strip.fader.y and my < strip.fader.y + strip.fader.height) {
                beginDrag(history, gpa, project, view, .{ .kind = .mcp_bus_vol, .bus_index = bi });
                applyDrag(project, view, chrome, mx, my);
                return;
            }
            if (rectContains(strip.pan, mx, my)) {
                beginDrag(history, gpa, project, view, .{ .kind = .mcp_bus_pan, .bus_index = bi });
                applyDrag(project, view, chrome, mx, my);
                return;
            }
        }
    }

    // TCP footer [+]
    if (rectContains(computeTcpFooter(chrome), mx, my)) {
        addAudioTrack(history, gpa, project, view);
        return;
    }

    // TCP strips
    if (rectContains(chrome.tcp, mx, my) and my < chrome.tcp.y + tracksAreaH(chrome)) {
        for (project.tracks.items, 0..) |*track, ti| {
            const lane = computeTcpLane(chrome, lane_h, ti);
            if (!rectContains(lane.lane, mx, my)) continue;
            view.selected_track = track.id;
            if (rectContains(lane.fx, mx, my)) {
                if (c.IsKeyDown(c.KEY_LEFT_SHIFT) or c.IsKeyDown(c.KEY_RIGHT_SHIFT)) {
                    pushUndo(history, gpa, project);
                    track.fx_enabled = !track.fx_enabled;
                    view.fx_apply_track = track.id;
                    markDirty(view);
                } else {
                    view.fx_target = .{ .track = track.id };
                    view.route_track = null;
                }
                return;
            }
            if (rectContains(lane.route, mx, my)) {
                view.route_track = track.id;
                view.fx_target = .none;
                return;
            }
            if (rectContains(lane.arm, mx, my) or rectContains(lane.mute, mx, my) or rectContains(lane.solo, mx, my)) {
                pushUndo(history, gpa, project);
                if (rectContains(lane.arm, mx, my)) {
                    if (!track.armed) armOnly(project, track.id) else track.armed = false;
                } else if (rectContains(lane.mute, mx, my)) track.mute = !track.mute else track.solo = !track.solo;
                markDirty(view);
                return;
            }
            if (rectContains(lane.name, mx, my)) {
                const now = c.GetTime();
                if (view.name_click_track) |prev| {
                    if (prev == track.id and (now - view.name_click_time) < 0.4) {
                        beginRename(view, track);
                        view.name_click_track = null;
                        return;
                    }
                }
                view.name_click_track = track.id;
                view.name_click_time = now;
                return;
            }
            if (lane_h >= TCP_FADERS_MIN_H) {
                if (rectContains(lane.vol, mx, my)) {
                    beginDrag(history, gpa, project, view, .{ .kind = .tcp_vol, .track_index = ti });
                    applyDrag(project, view, chrome, mx, my);
                    return;
                }
                if (rectContains(lane.pan, mx, my)) {
                    beginDrag(history, gpa, project, view, .{ .kind = .tcp_pan, .track_index = ti });
                    applyDrag(project, view, chrome, mx, my);
                    return;
                }
            }
            return;
        }
    }

    // Empty lane select
    if (rectContains(chrome.arrange, mx, my) and my < chrome.arrange.y + tracksAreaH(chrome)) {
        for (project.tracks.items, 0..) |track, ti| {
            const y = laneY(chrome.arrange.y, lane_h, ti);
            if (my >= y and my < y + lane_h) {
                view.selected_track = track.id;
                return;
            }
        }
    }
}

pub fn handleInputAlloc(gpa: std.mem.Allocator, history: *persist.History, project: *model.Project, view: *View, chrome: Chrome, seek_bar_out: *?f64) void {
    seek_bar_out.* = null;
    const mouse = c.GetMousePosition();
    const mx = mouse.x;
    const my = mouse.y;

    if (c.IsMouseButtonPressed(c.MOUSE_BUTTON_LEFT) and rectContains(chrome.ruler, mx, my)) {
        const raw = xToBar(view, chrome.arrange.x, mx);
        seek_bar_out.* = @floatCast(snapBar(view, @floatCast(raw)));
        return;
    }

    handleInput(gpa, history, project, view, chrome);
}

fn applyDrag(project: *model.Project, view: *View, chrome: Chrome, mx: f32, my: f32) void {
    switch (view.drag.kind) {
        .none => {},
        .bpm => {
            const dy = c.GetMouseDelta().y;
            project.bpm = std.math.clamp(project.bpm - @as(f64, @floatCast(dy)) * 0.2, 20.0, 400.0);
            markDirty(view);
        },
        .tcp_vol => {
            if (view.drag.track_index >= project.tracks.items.len) return;
            const lane = computeTcpLane(chrome, laneHeight(tracksAreaH(chrome), project.tracks.items.len), view.drag.track_index);
            const t = (mx - lane.vol.x) / @max(1.0, lane.vol.width);
            project.tracks.items[view.drag.track_index].volume = std.math.clamp(t, 0.0, 1.0);
            markDirty(view);
        },
        .tcp_pan => {
            if (view.drag.track_index >= project.tracks.items.len) return;
            const lane = computeTcpLane(chrome, laneHeight(tracksAreaH(chrome), project.tracks.items.len), view.drag.track_index);
            const t = (mx - lane.pan.x) / @max(1.0, lane.pan.width);
            project.tracks.items[view.drag.track_index].pan = std.math.clamp(t * 2.0 - 1.0, -1.0, 1.0);
            markDirty(view);
        },
        .mcp_vol => {
            if (view.drag.track_index >= project.tracks.items.len) return;
            const strip = computeMcpStrip(chrome, view.drag.track_index) orelse return;
            const top = strip.fader.y;
            const bot = strip.fader.y + strip.fader.height;
            const h = bot - top;
            if (h <= 1) return;
            const from_bottom = (bot - my) / h;
            project.tracks.items[view.drag.track_index].volume = std.math.clamp(from_bottom, 0.0, 1.0);
            markDirty(view);
        },
        .mcp_pan => {
            if (view.drag.track_index >= project.tracks.items.len) return;
            const strip = computeMcpStrip(chrome, view.drag.track_index) orelse return;
            const t = (mx - strip.pan.x) / @max(1.0, strip.pan.width);
            project.tracks.items[view.drag.track_index].pan = std.math.clamp(t * 2.0 - 1.0, -1.0, 1.0);
            markDirty(view);
        },
        .mcp_bus_vol => {
            if (view.drag.bus_index >= project.buses.items.len) return;
            const strip = computeMcpStrip(chrome, project.tracks.items.len + view.drag.bus_index) orelse return;
            const top = strip.fader.y;
            const bot = strip.fader.y + strip.fader.height;
            const h = bot - top;
            if (h <= 1) return;
            const from_bottom = (bot - my) / h;
            project.buses.items[view.drag.bus_index].volume = std.math.clamp(from_bottom, 0.0, 1.0);
            markDirty(view);
        },
        .mcp_bus_pan => {
            if (view.drag.bus_index >= project.buses.items.len) return;
            const strip = computeMcpStrip(chrome, project.tracks.items.len + view.drag.bus_index) orelse return;
            const t = (mx - strip.pan.x) / @max(1.0, strip.pan.width);
            project.buses.items[view.drag.bus_index].pan = std.math.clamp(t * 2.0 - 1.0, -1.0, 1.0);
            markDirty(view);
        },
        .mcp_master_vol => {
            const fader_top = chrome.master.y + 70;
            const fader_bot = chrome.master.y + @as(f32, @floatFromInt(MCP_H)) - 40;
            const h = fader_bot - fader_top;
            if (h <= 1) return;
            const from_bottom = (fader_bot - my) / h;
            project.master_volume = std.math.clamp(from_bottom, 0.0, 1.0);
            markDirty(view);
        },
        // Hit zones for sliders align with drawn bars at panel.x+140
        .fx_thresh, .fx_ratio => {
            const panel = fxPanelRect(chrome);
            const t = std.math.clamp((mx - (panel.x + 140)) / 240.0, 0.0, 1.0);
            const effects = effectsForTarget(project, view.fx_target) orelse return;
            if (view.drag.effect_index >= effects.len) return;
            const eff = &effects[view.drag.effect_index];
            if (eff.params != .sidechain_compressor) return;
            invalidateSidechainWet(eff);
            if (view.drag.kind == .fx_thresh) {
                eff.params.sidechain_compressor.threshold_db = -60.0 + t * 60.0;
            } else {
                eff.params.sidechain_compressor.ratio = 1.0 + t * 19.0;
            }
            markDirty(view);
        },
        .fx_lim_thresh, .fx_lim_ceiling => {
            const panel = fxPanelRect(chrome);
            const t = std.math.clamp((mx - (panel.x + 140)) / 240.0, 0.0, 1.0);
            const effects = effectsForTarget(project, view.fx_target) orelse return;
            if (view.drag.effect_index >= effects.len) return;
            const eff = &effects[view.drag.effect_index];
            if (eff.params != .limiter) return;
            if (view.drag.kind == .fx_lim_thresh) {
                eff.params.limiter.threshold_db = -24.0 + t * 24.0;
            } else {
                eff.params.limiter.ceiling_dbfs = -12.0 + t * 12.0;
            }
            markDirty(view);
        },
        .fx_eq_freq, .fx_eq_gain, .fx_eq_q => {
            const panel = fxPanelRect(chrome);
            const t = std.math.clamp((mx - (panel.x + 140)) / 240.0, 0.0, 1.0);
            const effects = effectsForTarget(project, view.fx_target) orelse return;
            if (view.drag.effect_index >= effects.len) return;
            const eff = &effects[view.drag.effect_index];
            if (eff.params != .eq or eff.params.eq.bands.items.len == 0) return;
            const b = &eff.params.eq.bands.items[0];
            if (view.drag.kind == .fx_eq_freq) {
                // log-ish map 20..12000
                const min_f: f32 = 20.0;
                const max_f: f32 = 12000.0;
                b.frequency_hz = min_f * std.math.pow(f32, max_f / min_f, t);
            } else if (view.drag.kind == .fx_eq_gain) {
                if (b.band_type == .highpass) return;
                b.gain_db = -24.0 + t * 48.0;
            } else {
                b.q = 0.1 + t * (18.0 - 0.1);
            }
            markDirty(view);
        },
    }
}

fn drawWaveform(loaded: mixer.LoadedAsset, source_offset: u64, length_frames: ?u64, x0: f32, y0: f32, w: f32, h: f32, clip_left: f32, clip_right: f32) void {
    if (w <= 0 or loaded.frame_count == 0) return;
    if (x0 + w < clip_left or x0 > clip_right) return;

    const rem = if (source_offset >= loaded.frame_count) 0 else loaded.frame_count - source_offset;
    const visible_frames = if (length_frames) |l| @min(l, rem) else rem;
    if (visible_frames == 0) return;

    const num_cols: usize = @intFromFloat(@max(1.0, w));
    const mid_y = y0 + h / 2.0;
    const half_h = h / 2.0 * 0.9;
    const frames_per_col = @as(f64, @floatFromInt(visible_frames)) / @as(f64, @floatFromInt(num_cols));

    var col: usize = 0;
    while (col < num_cols) : (col += 1) {
        const x = x0 + @as(f32, @floatFromInt(col));
        if (x < clip_left - 1 or x > clip_right + 1) continue;

        const start_rel: u64 = @intFromFloat(@as(f64, @floatFromInt(col)) * frames_per_col);
        var end_rel: u64 = @intFromFloat(@as(f64, @floatFromInt(col + 1)) * frames_per_col);
        if (end_rel > visible_frames) end_rel = visible_frames;
        if (end_rel <= start_rel) continue;

        const start_frame = source_offset + start_rel;
        var end_frame = source_offset + end_rel;
        if (end_frame > loaded.frame_count) end_frame = loaded.frame_count;

        const span = end_frame - start_frame;
        const step: u64 = @max(1, span / 32);
        var min_v: f32 = 0;
        var max_v: f32 = 0;
        var f = start_frame;
        while (f < end_frame) : (f += step) {
            const sample = if (loaded.channels >= 2) loaded.samples[f * 2] else loaded.samples[f];
            if (sample < min_v) min_v = sample;
            if (sample > max_v) max_v = sample;
        }
        c.DrawLine(@intFromFloat(x), @intFromFloat(mid_y - max_v * half_h), @intFromFloat(x), @intFromFloat(mid_y - min_v * half_h), COL_TEXT);
    }
}

pub fn draw(
    project: *const model.Project,
    view: *const View,
    chrome: Chrome,
    asset_cache: *const mixer.AssetCache,
    beat_time: f64,
    bar_sec: f64,
) void {
    c.ClearBackground(COL_BG);

    c.DrawRectangleRec(chrome.menu, rgb(0x28, 0x28, 0x28));
    c.DrawRectangleRec(chrome.transport, COL_PANEL);
    c.DrawRectangleRec(chrome.tcp_pad, rgb(0x33, 0x33, 0x33));
    c.DrawRectangleRec(chrome.tcp, COL_PANEL);
    c.DrawRectangleRec(chrome.ruler, rgb(0x30, 0x30, 0x30));
    c.DrawRectangleRec(chrome.arrange, COL_ARRANGE);
    c.DrawRectangleRec(chrome.mcp, COL_PANEL);
    c.DrawRectangleRec(chrome.master, rgb(0x44, 0x44, 0x44));

    const menu_l = computeMenuLayout(chrome);
    const transport_l = computeTransportLayout(chrome);

    // Menu bar
    c.DrawText("FastMix", @intFromFloat(menu_l.app.x + 8), 4, 14, COL_TEXT);
    c.DrawText("File", @intFromFloat(menu_l.file.x + 8), 4, 14, COL_TEXT);
    c.DrawText("Edit", @intFromFloat(menu_l.edit.x + 8), 4, 14, COL_TEXT);
    c.DrawText("Track", @intFromFloat(menu_l.track.x + 8), 4, 14, COL_TEXT);
    c.DrawText("Options", @intFromFloat(menu_l.options.x + 8), 4, 14, COL_TEXT);

    // Transport controls
    c.DrawRectangleRec(transport_l.stop, COL_BTN);
    c.DrawRectangle(@intFromFloat(transport_l.stop.x + 6), @intFromFloat(transport_l.stop.y + 6), 16, 12, COL_TEXT);
    const play_col = if (view.transport == .play or view.transport == .count_in) COL_SOLO else COL_BTN;
    c.DrawRectangleRec(transport_l.play, play_col);
    c.DrawTriangle(
        .{ .x = transport_l.play.x + 8, .y = transport_l.play.y + 4 },
        .{ .x = transport_l.play.x + 8, .y = transport_l.play.y + 20 },
        .{ .x = transport_l.play.x + 22, .y = transport_l.play.y + 12 },
        COL_TEXT,
    );
    const rec_col = if (view.transport == .record or view.transport == .count_in) COL_RECORD else COL_BTN;
    c.DrawCircle(@intFromFloat(transport_l.record.x + transport_l.record.width * 0.5), @intFromFloat(transport_l.record.y + transport_l.record.height * 0.5), 11, rec_col);

    const metro_col = if (view.metronome) COL_MUTE else COL_BTN;
    c.DrawRectangleRec(transport_l.metro, metro_col);
    c.DrawText("M", @intFromFloat(transport_l.metro.x + 8), @intFromFloat(transport_l.metro.y + 4), 16, COL_TEXT);

    c.DrawRectangleRec(transport_l.align_btn, COL_BTN);
    c.DrawText("ALIGN", @intFromFloat(transport_l.align_btn.x + 6), @intFromFloat(transport_l.align_btn.y + 4), 14, COL_TEXT);

    const snap_col = if (view.snap_enabled) (if (snapTempOff()) COL_MUTE else COL_SOLO) else COL_BTN;
    c.DrawRectangleRec(transport_l.snap, snap_col);
    c.DrawText("SNAP", @intFromFloat(transport_l.snap.x + 6), @intFromFloat(transport_l.snap.y + 4), 14, COL_TEXT);
    c.DrawRectangleRec(transport_l.grid, if (view.grid_menu_open) COL_FADER else COL_BTN);
    c.DrawText(gridDivLabel(view.grid_div), @intFromFloat(transport_l.grid.x + 6), @intFromFloat(transport_l.grid.y + 4), 14, COL_TEXT);
    c.DrawText("▾", @intFromFloat(transport_l.grid.x + transport_l.grid.width - 16), @intFromFloat(transport_l.grid.y + 2), 14, COL_DIM);

    const dry_col = if (view.fx_bypass_all) COL_MUTE else COL_BTN;
    c.DrawRectangleRec(transport_l.dry, dry_col);
    c.DrawText("DRY", @intFromFloat(transport_l.dry.x + 6), @intFromFloat(transport_l.dry.y + 4), 14, COL_TEXT);

    const bar_pos = beat_time / bar_sec;
    const bar_i: i64 = @intFromFloat(@floor(bar_pos));
    const beat_in_bar = (bar_pos - @floor(bar_pos)) * @as(f64, @floatFromInt(project.bar_size));
    var clock_buf: [112]u8 = undefined;
    const status = switch (view.transport) {
        .stop => if (beat_time > 0.001) "PAUSE" else "STOP",
        .play => "PLAY",
        .count_in => "COUNT-IN",
        .record => "RECORD",
    };
    const metro_s: []const u8 = if (view.metronome) "METRO" else "metro";
    const clock = std.fmt.bufPrintZ(&clock_buf, "{d}.{d:.2}  |  BPM {d:.1}  |  {s}  |  {s}", .{ bar_i + 1, beat_in_bar + 1.0, project.bpm, status, metro_s }) catch "?";
    c.DrawText(clock.ptr, @intFromFloat(transport_l.clock.x), @intFromFloat(transport_l.clock.y + 4), 16, COL_TEXT);

    // Ruler
    const first_bar: i64 = @intFromFloat(@floor(view.timeline_offset_bars));
    const last_bar: i64 = @intFromFloat(@ceil(view.timeline_offset_bars + chrome.arrange.width / view.pixels_per_bar));
    var b: i64 = first_bar;
    while (b <= last_bar) : (b += 1) {
        const x = barToX(view, chrome.arrange.x, @floatFromInt(b));
        if (x < chrome.ruler.x or x > chrome.ruler.x + chrome.ruler.width) continue;
        c.DrawLine(@intFromFloat(x), @as(i32, @intFromFloat(chrome.ruler.y)), @intFromFloat(x), @as(i32, @intFromFloat(chrome.ruler.y + chrome.ruler.height)), COL_BAR);
        // beat lines
        var beat: i64 = 1;
        while (beat < project.bar_size) : (beat += 1) {
            const bx = barToX(view, chrome.arrange.x, @as(f32, @floatFromInt(b)) + @as(f32, @floatFromInt(beat)) / @as(f32, @floatFromInt(project.bar_size)));
            if (bx < chrome.ruler.x or bx > chrome.ruler.x + chrome.ruler.width) continue;
            c.DrawLine(@intFromFloat(bx), @as(i32, @intFromFloat(chrome.ruler.y + chrome.ruler.height / 2)), @intFromFloat(bx), @as(i32, @intFromFloat(chrome.ruler.y + chrome.ruler.height)), COL_GRID);
        }
        var lbuf: [16]u8 = undefined;
        const lab = std.fmt.bufPrintZ(&lbuf, "{d}", .{b + 1}) catch "?";
        c.DrawText(lab.ptr, @intFromFloat(x + 2), @as(i32, @intFromFloat(chrome.ruler.y + 2)), 14, COL_DIM);
    }

    // Tracks — fit-all equal height (TCP + arrange synced); leave TCP footer for [+]
    const lane_h_f = laneHeight(tracksAreaH(chrome), project.tracks.items.len);
    const lane_h_i: i32 = @intFromFloat(@ceil(lane_h_f));
    const clip_inner_h: i32 = @max(4, lane_h_i - 8);

    // Arrange lane backgrounds + clips only (TCP drawn later, above FX dim).
    c.BeginScissorMode(
        @intFromFloat(chrome.arrange.x),
        @intFromFloat(chrome.arrange.y),
        @intFromFloat(chrome.arrange.width),
        @intFromFloat(chrome.arrange.height),
    );
    for (project.tracks.items, 0..) |track, ti| {
        const y = laneY(chrome.arrange.y, lane_h_f, ti);

        const selected = if (view.selected_track) |id| id == track.id else false;
        const lane_col = if (ti % 2 == 0) COL_ARRANGE else COL_LANE_ALT;
        c.DrawRectangle(@intFromFloat(chrome.arrange.x), @intFromFloat(y), @intFromFloat(chrome.arrange.width), lane_h_i, lane_col);
        if (selected) c.DrawRectangleLines(@intFromFloat(chrome.arrange.x), @intFromFloat(y), @intFromFloat(chrome.arrange.width), lane_h_i, COL_FADER);

        // Clips
        const semitone_height = lane_h_f / 13.0;
        for (track.clips.items) |clip_u| {
            switch (clip_u) {
                .midi => |clip| {
                    const x0 = barToX(view, chrome.arrange.x, @floatFromInt(clip.start_bar));
                    const w = @as(f32, @floatFromInt(clip.bars)) * view.pixels_per_bar;
                    if (x0 + w < chrome.arrange.x or x0 > chrome.arrange.x + chrome.arrange.width) continue;
                    c.DrawRectangle(@intFromFloat(x0), @intFromFloat(y + 4), @intFromFloat(w), clip_inner_h, COL_ITEM);
                    c.DrawRectangleLines(@intFromFloat(x0), @intFromFloat(y + 4), @intFromFloat(w), clip_inner_h, COL_TEXT);
                    const quant_w = view.pixels_per_bar / @as(f32, @floatFromInt(project.bar_quant));
                    for (clip.events.items) |ev| {
                        const ex = x0 + @as(f32, @floatFromInt(ev.quant)) * quant_w;
                        const ey = y + 4 + @as(f32, @floatFromInt(ev.semitone)) * semitone_height;
                        c.DrawCircleV(.{ .x = ex, .y = ey }, 3, if (ev.start) COL_RECORD else rgb(0x34, 0x98, 0xdb));
                    }
                },
                .audio => |ac| {
                    const loaded = asset_cache.get(ac.source_id) orelse continue;
                    if (loaded.frame_count == 0) continue;
                    const start_bar_f = @as(f64, @floatFromInt(ac.timeline_start_frame)) / @as(f64, @floatFromInt(project.sample_rate)) / bar_sec;
                    const visible = project.audioPlayableFrames(ac);
                    if (visible == 0) continue;
                    const bars_len_f = @as(f64, @floatFromInt(visible)) / @as(f64, @floatFromInt(project.sample_rate)) / bar_sec;
                    const x0 = barToX(view, chrome.arrange.x, @floatCast(start_bar_f));
                    const w = @as(f32, @floatCast(bars_len_f)) * view.pixels_per_bar;
                    if (x0 + w < chrome.arrange.x or x0 > chrome.arrange.x + chrome.arrange.width) continue;
                    const item_col = if (ac.muted) COL_MUTE else COL_ITEM;
                    c.DrawRectangle(@intFromFloat(x0), @intFromFloat(y + 4), @intFromFloat(w), clip_inner_h, item_col);
                    c.DrawRectangleLines(@intFromFloat(x0), @intFromFloat(y + 4), @intFromFloat(w), clip_inner_h, COL_TEXT);
                    drawWaveform(loaded, ac.source_offset_frames, ac.length_frames, x0, y + 4, w, lane_h_f - 8, chrome.arrange.x, chrome.arrange.x + chrome.arrange.width);
                },
            }
        }
    }
    c.EndScissorMode();

    // MCP: ALWAYS all tracks (independent of arrange vertical scroll).
    {
        for (project.tracks.items, 0..) |track, ti| {
            const strip = computeMcpStrip(chrome, ti) orelse break;
            c.DrawRectangleRec(strip.strip, rgb(0x32, 0x32, 0x32));
            c.DrawRectangleRec(strip.arm, if (track.armed) COL_ARM else COL_BTN);
            c.DrawText("R", @intFromFloat(strip.arm.x + 3), @intFromFloat(strip.arm.y + 1), 12, COL_TEXT);
            c.DrawRectangleRec(strip.mute, if (track.mute) COL_MUTE else COL_BTN);
            c.DrawText("M", @intFromFloat(strip.mute.x + 3), @intFromFloat(strip.mute.y + 1), 12, COL_TEXT);
            c.DrawRectangleRec(strip.solo, if (track.solo) COL_SOLO else COL_BTN);
            c.DrawText("S", @intFromFloat(strip.solo.x + 3), @intFromFloat(strip.solo.y + 1), 12, COL_TEXT);
            const mp = if (ti < view.peaks_l.len) @max(view.peaks_l[ti], view.peaks_r[ti]) else 0;
            const meter_h: f32 = mp * strip.meter.height;
            c.DrawRectangle(
                @intFromFloat(strip.meter.x),
                @intFromFloat(strip.meter.y + strip.meter.height - meter_h),
                @intFromFloat(strip.meter.width),
                @intFromFloat(meter_h),
                if (mp > 0.9) COL_METER_HOT else COL_METER,
            );
            const fh: f32 = strip.fader.height * track.volume;
            c.DrawRectangle(
                @intFromFloat(strip.fader.x),
                @intFromFloat(strip.fader.y + strip.fader.height - fh),
                @intFromFloat(strip.fader.width),
                @intFromFloat(fh),
                COL_FADER,
            );
            c.DrawRectangleRec(strip.pan, rgb(0x22, 0x22, 0x22));
            const pan_x = strip.pan.x + (track.pan + 1.0) * 0.5 * strip.pan.width;
            c.DrawRectangle(@intFromFloat(pan_x - 2), @intFromFloat(strip.pan.y - 2), 5, 10, COL_TEXT);
            var tbuf: [16]u8 = undefined;
            const tlab = std.fmt.bufPrintZ(&tbuf, "T{d}", .{ti + 1}) catch "?";
            c.DrawText(tlab.ptr, @intFromFloat(strip.label.x + 20), @intFromFloat(strip.label.y), 12, COL_DIM);
        }
        // Bus strips after tracks (same MCP model).
        const base_ti = project.tracks.items.len;
        for (project.buses.items, 0..) |bus, bi| {
            const strip = computeMcpStrip(chrome, base_ti + bi) orelse break;
            c.DrawRectangleRec(strip.strip, rgb(0x28, 0x2e, 0x36));
            c.DrawRectangleRec(strip.mute, if (bus.mute) COL_MUTE else COL_BTN);
            c.DrawText("M", @intFromFloat(strip.mute.x + 3), @intFromFloat(strip.mute.y + 1), 12, COL_TEXT);
            c.DrawRectangleRec(strip.solo, if (bus.solo) COL_SOLO else COL_BTN);
            c.DrawText("S", @intFromFloat(strip.solo.x + 3), @intFromFloat(strip.solo.y + 1), 12, COL_TEXT);
            const bp = if (bi < view.bus_peaks.len) view.bus_peaks[bi] else 0;
            const meter_h: f32 = bp * strip.meter.height;
            c.DrawRectangle(
                @intFromFloat(strip.meter.x),
                @intFromFloat(strip.meter.y + strip.meter.height - meter_h),
                @intFromFloat(strip.meter.width),
                @intFromFloat(meter_h),
                if (bp > 0.9) COL_METER_HOT else COL_METER,
            );
            const fh: f32 = strip.fader.height * bus.volume;
            c.DrawRectangle(
                @intFromFloat(strip.fader.x),
                @intFromFloat(strip.fader.y + strip.fader.height - fh),
                @intFromFloat(strip.fader.width),
                @intFromFloat(fh),
                COL_FADER,
            );
            c.DrawRectangleRec(strip.pan, rgb(0x22, 0x22, 0x22));
            const pan_x = strip.pan.x + (bus.pan + 1.0) * 0.5 * strip.pan.width;
            c.DrawRectangle(@intFromFloat(pan_x - 2), @intFromFloat(strip.pan.y - 2), 5, 10, COL_TEXT);
            var bbuf: [16]u8 = undefined;
            const short = if (bus.name.len > 6) bus.name[0..6] else bus.name;
            const blab = std.fmt.bufPrintZ(&bbuf, "{s}", .{short}) catch "BUS";
            c.DrawText(blab.ptr, @intFromFloat(strip.label.x + 4), @intFromFloat(strip.label.y), 11, COL_DIM);
        }
        const mcp_slots = project.tracks.items.len + project.buses.items.len;
        if (computeMcpAddButton(chrome, mcp_slots)) |add_btn| {
            c.DrawRectangleRec(add_btn, COL_BTN);
            c.DrawText("+", @intFromFloat(add_btn.x + 8), @intFromFloat(add_btn.y + 2), 18, COL_TEXT);
        }
    }

    // Arrange grid (over items — like Reaper). Bar lines strongest; then grid_div subdivs.
    {
        const ay0: i32 = @intFromFloat(chrome.arrange.y);
        const ay1: i32 = @intFromFloat(chrome.arrange.y + chrome.arrange.height);
        const first_bar_g: i64 = @intFromFloat(@floor(view.timeline_offset_bars));
        const last_bar_g: i64 = @as(i64, @intFromFloat(@ceil(view.timeline_offset_bars + chrome.arrange.width / view.pixels_per_bar))) + 1;
        const div: i32 = view.grid_div;
        if (div > 0) {
        const min_px: f32 = 6.0; // LOD: skip lines closer than this
        var bg: i64 = first_bar_g;
        while (bg <= last_bar_g) : (bg += 1) {
            const x_bar = barToX(view, chrome.arrange.x, @floatFromInt(bg));
            if (x_bar >= chrome.arrange.x and x_bar <= chrome.arrange.x + chrome.arrange.width) {
                c.DrawLine(@intFromFloat(x_bar), ay0, @intFromFloat(x_bar), ay1, COL_BAR);
            }
            var s: i32 = 1;
            while (s < div) : (s += 1) {
                const frac = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(div));
                // Emphasize beat lines when grid is finer than bar_size
                const is_beat = (@rem(@as(i64, s) * project.bar_size, @as(i64, div)) == 0);
                const x = barToX(view, chrome.arrange.x, @as(f32, @floatFromInt(bg)) + frac);
                if (x < chrome.arrange.x or x > chrome.arrange.x + chrome.arrange.width) continue;
                if (view.pixels_per_bar / @as(f32, @floatFromInt(div)) < min_px and !is_beat) continue;
                const col = if (is_beat) COL_GRID else rgb(0x35, 0x35, 0x35);
                c.DrawLine(@intFromFloat(x), ay0, @intFromFloat(x), ay1, col);
            }
        }
        } else {
        var bg: i64 = first_bar_g;
        while (bg <= last_bar_g) : (bg += 1) {
            const x_bar = barToX(view, chrome.arrange.x, @floatFromInt(bg));
            if (x_bar >= chrome.arrange.x and x_bar <= chrome.arrange.x + chrome.arrange.width) {
                c.DrawLine(@intFromFloat(x_bar), ay0, @intFromFloat(x_bar), ay1, COL_BAR);
            }
        }
        }
    }

    // Playhead
    const ph_x = barToX(view, chrome.arrange.x, @floatCast(bar_pos));
    if (ph_x >= chrome.arrange.x and ph_x <= chrome.arrange.x + chrome.arrange.width) {
        c.DrawLine(@intFromFloat(ph_x), @intFromFloat(chrome.arrange.y), @intFromFloat(ph_x), @intFromFloat(chrome.arrange.y + chrome.arrange.height), COL_PLAYHEAD);
        c.DrawLine(@intFromFloat(ph_x), @intFromFloat(chrome.ruler.y), @intFromFloat(ph_x), @intFromFloat(chrome.ruler.y + chrome.ruler.height), COL_PLAYHEAD);
    }

    // Master meter + FX + volume fader (meter = post master_volume / output)
    const fader_top = chrome.master.y + 70;
    const fader_bot = chrome.master.y + @as(f32, @floatFromInt(MCP_H)) - 40;
    const fader_h = fader_bot - fader_top;
    const mmh: i32 = @intFromFloat(view.master_peak * @max(1.0, fader_h - 8));
    c.DrawText("MST", @intFromFloat(chrome.master.x + 16), @intFromFloat(chrome.master.y + 12), 14, COL_TEXT);
    c.DrawRectangle(@intFromFloat(chrome.master.x + 12), @intFromFloat(chrome.master.y + 36), 48, 20, if (project.master_effects.items.len > 0) COL_FADER else COL_BTN);
    c.DrawText("FX", @intFromFloat(chrome.master.x + 26), @intFromFloat(chrome.master.y + 38), 14, COL_TEXT);
    const fh: f32 = fader_h * project.master_volume;
    c.DrawRectangle(@intFromFloat(chrome.master.x + 24), @intFromFloat(fader_bot - fh), 10, @intFromFloat(fh), COL_FADER);
    c.DrawRectangle(@intFromFloat(chrome.master.x + 40), @as(i32, @intFromFloat(fader_bot)) - mmh, 12, mmh, if (view.master_peak > 0.9) COL_METER_HOT else COL_METER);

    // FX panel — dim arrange/ruler only (never TCP). TCP strip redrawn after so left
    // controls cannot vanish under the alpha overlay / clip bleed.
    if (view.fx_target != .none) {
        const panel = fxPanelRect(chrome);
        c.DrawRectangle(
            @intFromFloat(chrome.arrange.x),
            @intFromFloat(chrome.ruler.y),
            @intFromFloat(chrome.arrange.width),
            @intFromFloat(chrome.mcp.y - chrome.ruler.y),
            .{ .r = 0, .g = 0, .b = 0, .a = 120 },
        );
        c.DrawRectangleRec(panel, rgb(0x2a, 0x2a, 0x2a));
        c.DrawRectangleLines(@intFromFloat(panel.x), @intFromFloat(panel.y), @intFromFloat(panel.width), @intFromFloat(panel.height), COL_TEXT);

        var title_buf: [64]u8 = undefined;
        const title: [:0]const u8 = switch (view.fx_target) {
            .master => "Master FX",
            .track => |tid| blk: {
                for (project.tracks.items) |t| {
                    if (t.id == tid) {
                        break :blk (std.fmt.bufPrintZ(&title_buf, "FX: {s}", .{t.name}) catch "Track FX");
                    }
                }
                break :blk "Track FX";
            },
            .none => "FX",
        };
        c.DrawText(title.ptr, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 10), 16, COL_TEXT);

        if (view.fx_target == .track) {
            const tid = view.fx_target.track;
            var fx_on = true;
            for (project.tracks.items) |t| {
                if (t.id == tid) fx_on = t.fx_enabled;
            }
            const en_col = if (fx_on) COL_SOLO else COL_MUTE;
            c.DrawRectangle(@intFromFloat(panel.x + 12), @intFromFloat(panel.y + 36), 110, 22, en_col);
            c.DrawText(if (fx_on) "FX ON" else "FX OFF", @intFromFloat(panel.x + 28), @intFromFloat(panel.y + 40), 14, COL_TEXT);
            c.DrawText("Shift/RMB on FX btn = power", @intFromFloat(panel.x + 140), @intFromFloat(panel.y + 40), 12, COL_DIM);
        } else if (view.fx_target == .master) {
            const fx_on = project.master_fx_enabled;
            const en_col = if (fx_on) COL_SOLO else COL_MUTE;
            c.DrawRectangle(@intFromFloat(panel.x + 12), @intFromFloat(panel.y + 36), 110, 22, en_col);
            c.DrawText(if (fx_on) "FX ON" else "FX OFF", @intFromFloat(panel.x + 28), @intFromFloat(panel.y + 40), 14, COL_TEXT);
            c.DrawRectangle(@intFromFloat(panel.x + 130), @intFromFloat(panel.y + 36), 118, 22, COL_BTN);
            c.DrawText("Analyze", @intFromFloat(panel.x + 155), @intFromFloat(panel.y + 40), 14, COL_TEXT);
            c.DrawRectangle(@intFromFloat(panel.x + 260), @intFromFloat(panel.y + 36), 128, 22, COL_BTN);
            c.DrawText("Validate", @intFromFloat(panel.x + 285), @intFromFloat(panel.y + 40), 14, COL_TEXT);
            c.DrawRectangle(@intFromFloat(panel.x + 400), @intFromFloat(panel.y + 36), 96, 22, COL_BTN);
            c.DrawText("ResetPk", @intFromFloat(panel.x + 415), @intFromFloat(panel.y + 40), 14, COL_TEXT);

            var line_buf: [96]u8 = undefined;
            const peak_lab = std.fmt.bufPrintZ(&line_buf, "Peak {d:.1} dBFS  TP {d:.1} dBTP", .{ view.master_qc_sample_peak_dbfs, view.master_qc_true_peak_dbtp }) catch "Peak/TP";
            c.DrawText(peak_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 66), 12, COL_DIM);
            var short_buf: [80]u8 = undefined;
            const short_lab = std.fmt.bufPrintZ(&short_buf, "Short {d:.1} LUFS", .{view.master_qc_short_lufs}) catch "Short";
            c.DrawText(short_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 84), 12, COL_DIM);
            var integ_buf: [96]u8 = undefined;
            const integ_lab: [:0]const u8 = if (view.master_qc_has_integrated)
                (std.fmt.bufPrintZ(&integ_buf, "Integrated {d:.1} LUFS (job)", .{view.master_qc_integrated_lufs}) catch "Integrated")
            else
                "Integrated — run Analyze";
            c.DrawText(integ_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 102), 12, COL_DIM);
            var gr_buf: [64]u8 = undefined;
            const gr_lab = std.fmt.bufPrintZ(&gr_buf, "Limiter GR {d:.1} dB{s}", .{ view.master_qc_limiter_gr_db, if (view.master_clip_flag) " CLIP" else "" }) catch "GR";
            c.DrawText(gr_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 120), 12, if (view.master_clip_flag) COL_METER_HOT else COL_DIM);
            if (view.master_qc_status_len > 0) {
                var st_buf: [49]u8 = undefined;
                const n = @min(view.master_qc_status_len, 48);
                @memcpy(st_buf[0..n], view.master_qc_status[0..n]);
                st_buf[n] = 0;
                c.DrawText(&st_buf, @intFromFloat(panel.x + 260), @intFromFloat(panel.y + 84), 12, COL_TEXT);
            }
        }

        const effects: []const model.Effect = switch (view.fx_target) {
            .none => &.{},
            .track => |tid| blk: {
                for (project.tracks.items) |t| {
                    if (t.id == tid) break :blk t.effects.items;
                }
                break :blk &.{};
            },
            .master => project.master_effects.items,
        };
        if (effects.len == 0) {
            const empty_y: f32 = if (view.fx_target == .master) panel.y + 160 else panel.y + 80;
            c.DrawText("(empty chain — no plugins on this track)", @intFromFloat(panel.x + 12), @intFromFloat(empty_y), 14, COL_DIM);
        } else {
            const list_y: f32 = if (view.fx_target == .track) panel.y + 72 else if (view.fx_target == .master) panel.y + 150 else panel.y + 48;
            var row_y = list_y;
            for (effects) |eff| {
                const row_h = eqRowHeight(eff);
                c.DrawRectangle(@intFromFloat(panel.x + 8), @intFromFloat(row_y - 4), @intFromFloat(panel.width - 16), @intFromFloat(row_h), rgb(0x33, 0x33, 0x33));
                c.DrawText(effectKindName(eff), @intFromFloat(panel.x + 12), @intFromFloat(row_y + 4), 14, COL_TEXT);
                const by_col = if (eff.bypassed) COL_MUTE else COL_SOLO;
                c.DrawRectangle(@intFromFloat(panel.x + 300), @intFromFloat(row_y), 90, 22, by_col);
                c.DrawText(if (eff.bypassed) "bypass" else "active", @intFromFloat(panel.x + 310), @intFromFloat(row_y + 4), 12, COL_TEXT);

                if (eff.params == .sidechain_compressor) {
                    const p = eff.params.sidechain_compressor;
                    var thr_buf: [48]u8 = undefined;
                    const thr_lab = std.fmt.bufPrintZ(&thr_buf, "Thresh {d:.1} dB", .{p.threshold_db}) catch "?";
                    c.DrawText(thr_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(row_y + 28), 12, COL_DIM);
                    const thr_t = (p.threshold_db + 60.0) / 60.0;
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 30), 240, 8, rgb(0x22, 0x22, 0x22));
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 30), @intFromFloat(240.0 * thr_t), 8, COL_FADER);

                    var ratio_buf: [40]u8 = undefined;
                    const ratio_lab = std.fmt.bufPrintZ(&ratio_buf, "Ratio {d:.1}:1", .{p.ratio}) catch "?";
                    c.DrawText(ratio_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(row_y + 48), 12, COL_DIM);
                    const ratio_t = (p.ratio - 1.0) / 19.0;
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 50), 240, 8, rgb(0x22, 0x22, 0x22));
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 50), @intFromFloat(240.0 * ratio_t), 8, COL_FADER);
                } else if (eff.params == .limiter) {
                    const p = eff.params.limiter;
                    var thr_buf: [48]u8 = undefined;
                    const thr_lab = std.fmt.bufPrintZ(&thr_buf, "Thresh {d:.1} dB", .{p.threshold_db}) catch "?";
                    c.DrawText(thr_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(row_y + 28), 12, COL_DIM);
                    const thr_t = (p.threshold_db + 24.0) / 24.0;
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 30), 240, 8, rgb(0x22, 0x22, 0x22));
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 30), @intFromFloat(240.0 * std.math.clamp(thr_t, 0, 1)), 8, COL_FADER);
                    var ceil_buf: [48]u8 = undefined;
                    const ceil_lab = std.fmt.bufPrintZ(&ceil_buf, "Ceil {d:.1} dBFS", .{p.ceiling_dbfs}) catch "?";
                    c.DrawText(ceil_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(row_y + 48), 12, COL_DIM);
                    const ceil_t = (p.ceiling_dbfs + 12.0) / 12.0;
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 50), 240, 8, rgb(0x22, 0x22, 0x22));
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 50), @intFromFloat(240.0 * std.math.clamp(ceil_t, 0, 1)), 8, COL_FADER);
                } else if (eff.params == .eq and eff.params.eq.bands.items.len > 0) {
                    const eqb = eff.params.eq.bands.items[0];
                    var type_buf: [64]u8 = undefined;
                    const type_lab = std.fmt.bufPrintZ(&type_buf, "Type: {s}", .{eqBandTypeLabel(eqb.band_type)}) catch "Type";
                    c.DrawRectangle(@intFromFloat(panel.x + 12), @intFromFloat(row_y + 26), 118, 20, rgb(0x44, 0x44, 0x55));
                    c.DrawText(type_lab.ptr, @intFromFloat(panel.x + 16), @intFromFloat(row_y + 28), 12, COL_TEXT);
                    const bb_col = if (eqb.bypass) COL_MUTE else COL_SOLO;
                    c.DrawRectangle(@intFromFloat(panel.x + 300), @intFromFloat(row_y + 26), 90, 20, bb_col);
                    c.DrawText(if (eqb.bypass) "band off" else "band on", @intFromFloat(panel.x + 308), @intFromFloat(row_y + 28), 11, COL_TEXT);

                    var freq_buf: [48]u8 = undefined;
                    const freq_lab = std.fmt.bufPrintZ(&freq_buf, "Freq {d:.0} Hz", .{eqb.frequency_hz}) catch "?";
                    c.DrawText(freq_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(row_y + 50), 12, COL_DIM);
                    const freq_t = @log(eqb.frequency_hz / 20.0) / @log(12000.0 / 20.0);
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 52), 240, 8, rgb(0x22, 0x22, 0x22));
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 52), @intFromFloat(240.0 * std.math.clamp(freq_t, 0, 1)), 8, COL_FADER);

                    if (eqb.band_type == .highpass) {
                        c.DrawText("Gain (n/a HPF)", @intFromFloat(panel.x + 12), @intFromFloat(row_y + 70), 12, COL_DIM);
                    } else {
                        var gain_buf: [48]u8 = undefined;
                        const gain_lab = std.fmt.bufPrintZ(&gain_buf, "Gain {d:.1} dB", .{eqb.gain_db}) catch "?";
                        c.DrawText(gain_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(row_y + 70), 12, COL_DIM);
                        const gain_t = (eqb.gain_db + 24.0) / 48.0;
                        c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 72), 240, 8, rgb(0x22, 0x22, 0x22));
                        c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 72), @intFromFloat(240.0 * std.math.clamp(gain_t, 0, 1)), 8, COL_FADER);
                    }

                    var q_buf: [40]u8 = undefined;
                    const q_lab = std.fmt.bufPrintZ(&q_buf, "Q {d:.2}", .{eqb.q}) catch "?";
                    c.DrawText(q_lab.ptr, @intFromFloat(panel.x + 12), @intFromFloat(row_y + 90), 12, COL_DIM);
                    const q_t = (eqb.q - 0.1) / (18.0 - 0.1);
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 92), 240, 8, rgb(0x22, 0x22, 0x22));
                    c.DrawRectangle(@intFromFloat(panel.x + 140), @intFromFloat(row_y + 92), @intFromFloat(240.0 * std.math.clamp(q_t, 0, 1)), 8, COL_FADER);
                }
                row_y += row_h + 4;
            }
        }
        c.DrawText("Esc / click outside to close", @intFromFloat(panel.x + 12), @intFromFloat(panel.y + panel.height - 22), 12, COL_DIM);
    }

    // Route inspector (Master Send + sends) — same model as socket API.
    if (view.route_track) |rid| {
        const panel = fxPanelRect(chrome);
        c.DrawRectangleRec(panel, COL_PANEL);
        c.DrawRectangleLines(@intFromFloat(panel.x), @intFromFloat(panel.y), @intFromFloat(panel.width), @intFromFloat(panel.height), COL_GRID);
        var tr_opt: ?*const model.Track = null;
        for (project.tracks.items) |*t| {
            if (t.id == rid) {
                tr_opt = t;
                break;
            }
        }
        if (tr_opt) |tr| {
            var title_buf: [96]u8 = undefined;
            const title = std.fmt.bufPrintZ(&title_buf, "[ROUTE] {s}", .{tr.name}) catch "[ROUTE]";
            c.DrawText(title.ptr, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 10), 18, COL_TEXT);
            const ms: [:0]const u8 = if (tr.master_send_enabled) "Master Send       ON" else "Master Send       OFF";
            c.DrawText(ms.ptr, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 40), 14, COL_TEXT);
            const pm: [:0]const u8 = if (tr.post_master_enabled) "Post-Master (REF) ON" else "Post-Master (REF) OFF";
            c.DrawText(pm.ptr, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 62), 14, COL_TEXT);
            c.DrawText("Sends", @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 88), 14, COL_DIM);
            var row: f32 = panel.y + 110;
            var any = false;
            for (project.sends.items) |s| {
                if (s.source_track_id != rid) continue;
                any = true;
                var bname: []const u8 = "?";
                for (project.buses.items) |bus| {
                    if (bus.id == s.destination_bus_id) {
                        bname = bus.name;
                        break;
                    }
                }
                const tap_s: []const u8 = switch (s.tap) {
                    .pre_fader => "pre-fader",
                    .post_fader => "post-fader",
                };
                const en: []const u8 = if (s.enabled) "enabled" else "disabled";
                var line_buf: [160]u8 = undefined;
                const line = std.fmt.bufPrintZ(&line_buf, "-> {s}  {d:.1} dB  {s}  [{s}]", .{ bname, s.gain_db, tap_s, en }) catch "?";
                c.DrawText(line.ptr, @intFromFloat(panel.x + 12), @intFromFloat(row), 13, COL_TEXT);
                row += 20;
                if (row > panel.y + panel.height - 40) break;
            }
            if (!any) c.DrawText("(no sends)", @intFromFloat(panel.x + 12), @intFromFloat(row), 13, COL_DIM);
            c.DrawRectangle(@intFromFloat(panel.x + 12), @intFromFloat(panel.y + panel.height - 48), 128, 22, COL_BTN);
            c.DrawText("+ Add Send", @intFromFloat(panel.x + 24), @intFromFloat(panel.y + panel.height - 44), 13, COL_TEXT);
            c.DrawText("Esc / click outside to close", @intFromFloat(panel.x + 12), @intFromFloat(panel.y + panel.height - 22), 12, COL_DIM);
        }
    }

    // TCP always above arrange dim / clips (must survive FX open/close).
    {
        c.DrawRectangleRec(chrome.tcp, COL_PANEL);
        for (project.tracks.items, 0..) |track, ti| {
            const lane = computeTcpLane(chrome, lane_h_f, ti);
            c.DrawRectangleRec(lane.lane, COL_PANEL);
            c.DrawRectangleLines(@intFromFloat(lane.lane.x), @intFromFloat(lane.lane.y), @intFromFloat(lane.lane.width), @intFromFloat(lane.lane.height), COL_GRID);

            c.DrawRectangleRec(lane.arm, if (track.armed) COL_ARM else COL_BTN);
            c.DrawText("R", @intFromFloat(lane.arm.x + 5), @intFromFloat(lane.arm.y + 2), 14, COL_TEXT);
            c.DrawRectangleRec(lane.mute, if (track.mute) COL_MUTE else COL_BTN);
            c.DrawText("M", @intFromFloat(lane.mute.x + 5), @intFromFloat(lane.mute.y + 2), 14, COL_TEXT);
            c.DrawRectangleRec(lane.solo, if (track.solo) COL_SOLO else COL_BTN);
            c.DrawText("S", @intFromFloat(lane.solo.x + 6), @intFromFloat(lane.solo.y + 2), 14, COL_TEXT);

            var name_buf: [24]u8 = undefined;
            const short = if (track.name.len > 8) track.name[0..8] else track.name;
            const nm = std.fmt.bufPrintZ(&name_buf, "{d} {s}", .{ ti + 1, short }) catch "?";
            const name_col = if (view.selected_track) |sid| (if (sid == track.id) COL_SOLO else if (track.armed) COL_ARM else COL_TEXT) else if (track.armed) COL_ARM else COL_TEXT;
            if (view.rename_track) |rid| {
                if (rid == track.id) {
                    c.DrawRectangleRec(lane.name, rgb(0x11, 0x11, 0x11));
                    c.DrawRectangleLines(@intFromFloat(lane.name.x), @intFromFloat(lane.name.y), @intFromFloat(lane.name.width), @intFromFloat(lane.name.height), COL_SOLO);
                    var rbuf: [65]u8 = undefined;
                    const rlen = @min(view.rename_len, 64);
                    @memcpy(rbuf[0..rlen], view.rename_buf[0..rlen]);
                    rbuf[rlen] = 0;
                    c.DrawText(&rbuf, @intFromFloat(lane.name.x + 2), @intFromFloat(lane.name.y + 2), 12, COL_TEXT);
                    if (@mod(@as(i32, @intFromFloat(c.GetTime() * 2.0)), 2) == 0) {
                        var pre: [65]u8 = undefined;
                        const plen = @min(view.rename_caret, rlen);
                        @memcpy(pre[0..plen], view.rename_buf[0..plen]);
                        pre[plen] = 0;
                        const cx = @as(i32, @intFromFloat(lane.name.x + 2)) + c.MeasureText(&pre, 12);
                        c.DrawRectangle(cx, @intFromFloat(lane.name.y + 2), 1, 14, COL_TEXT);
                    }
                } else {
                    c.DrawText(nm.ptr, @intFromFloat(lane.name.x), @intFromFloat(lane.name.y + 2), 12, name_col);
                }
            } else {
                c.DrawText(nm.ptr, @intFromFloat(lane.name.x), @intFromFloat(lane.name.y + 2), 12, name_col);
            }

            const has_fx = track.effects.items.len > 0;
            const fx_col = if (!has_fx) COL_BTN else if (trackFxLit(&track)) COL_SOLO else COL_MUTE;
            c.DrawRectangleRec(lane.fx, fx_col);
            c.DrawText("FX", @intFromFloat(lane.fx.x + 3), @intFromFloat(lane.fx.y + 2), 12, COL_TEXT);
            const route_on = if (view.route_track) |rid| rid == track.id else false;
            c.DrawRectangleRec(lane.route, if (route_on) COL_SOLO else COL_BTN);
            c.DrawText("RT", @intFromFloat(lane.route.x + 6), @intFromFloat(lane.route.y + 2), 12, COL_TEXT);

            if (lane_h_f >= TCP_FADERS_MIN_H) {
                c.DrawRectangleRec(lane.vol, rgb(0x22, 0x22, 0x22));
                c.DrawRectangle(@intFromFloat(lane.vol.x), @intFromFloat(lane.vol.y), @intFromFloat(lane.vol.width * track.volume), @intFromFloat(lane.vol.height), COL_FADER);
                c.DrawRectangleRec(lane.pan, rgb(0x22, 0x22, 0x22));
                const pan_cx = lane.pan.x + (track.pan + 1.0) * 0.5 * lane.pan.width;
                c.DrawRectangle(@intFromFloat(pan_cx - 3), @intFromFloat(lane.pan.y - 2), 6, 10, COL_TEXT);

                const peak = if (ti < view.peaks_l.len) @max(view.peaks_l[ti], view.peaks_r[ti]) else 0;
                const mh: f32 = peak * lane.meter.height;
                c.DrawRectangle(
                    @intFromFloat(lane.meter.x),
                    @intFromFloat(lane.meter.y + lane.meter.height - mh),
                    @intFromFloat(lane.meter.width),
                    @intFromFloat(mh),
                    if (peak > 0.9) COL_METER_HOT else COL_METER,
                );
            }
        }
        const footer = computeTcpFooter(chrome);
        c.DrawRectangleRec(footer, rgb(0x33, 0x33, 0x33));
        const add_r = rect(footer.x + 8, footer.y + 2, footer.width - 16, footer.height - 4);
        c.DrawRectangleRec(add_r, COL_BTN);
        c.DrawText("+ Add Track", @intFromFloat(footer.x + 40), @intFromFloat(footer.y + 4), 12, COL_TEXT);
    }

    // Menu dropdowns AFTER TCP — TCP redraw was covering Close/Save/Save As/Render.
    if (view.menu_open == .app) {
        const px: i32 = @intFromFloat(menu_l.app.x);
        c.DrawRectangle(px, MENU_H, 130, 56, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleLines(px, MENU_H, 130, 56, COL_GRID);
        c.DrawText("About FastMix", px + 8, MENU_H + 6, 14, COL_TEXT);
        c.DrawText("Quit", px + 8, MENU_H + 34, 14, COL_TEXT);
    } else if (view.menu_open == .file) {
        const px: i32 = @intFromFloat(menu_l.file.x);
        c.DrawRectangle(px, MENU_H, 170, 196, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleLines(px, MENU_H, 170, 196, COL_GRID);
        c.DrawText("New Project", px + 10, MENU_H + 6, 14, COL_TEXT);
        c.DrawText("Open...", px + 10, MENU_H + 34, 14, COL_TEXT);
        c.DrawText("Close Project", px + 10, MENU_H + 62, 14, COL_TEXT);
        c.DrawText("Save", px + 10, MENU_H + 90, 14, COL_TEXT);
        c.DrawText("Save As...", px + 10, MENU_H + 118, 14, COL_TEXT);
        c.DrawText("Render...", px + 10, MENU_H + 146, 14, COL_TEXT);
        c.DrawText("Quit", px + 10, MENU_H + 174, 14, COL_TEXT);
    } else if (view.menu_open == .edit) {
        const px: i32 = @intFromFloat(menu_l.edit.x);
        c.DrawRectangle(px, MENU_H, 140, 56, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleLines(px, MENU_H, 140, 56, COL_GRID);
        c.DrawText("Undo", px + 10, MENU_H + 6, 14, COL_TEXT);
        c.DrawText("Redo", px + 10, MENU_H + 34, 14, COL_TEXT);
    } else if (view.menu_open == .track) {
        const px: i32 = @intFromFloat(menu_l.track.x);
        c.DrawRectangle(px, MENU_H, 170, 112, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleLines(px, MENU_H, 170, 112, COL_GRID);
        c.DrawText("Add Audio Track", px + 10, MENU_H + 6, 14, COL_TEXT);
        c.DrawText("Duplicate Track", px + 10, MENU_H + 34, 14, COL_TEXT);
        c.DrawText("Remove Track", px + 10, MENU_H + 62, 14, COL_TEXT);
        c.DrawText("Rename Track...", px + 10, MENU_H + 90, 14, COL_TEXT);
    } else if (view.menu_open == .options) {
        const px: i32 = @intFromFloat(menu_l.options.x);
        c.DrawRectangle(px, MENU_H, 220, 28, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleLines(px, MENU_H, 220, 28, COL_GRID);
        var line: [64]u8 = undefined;
        const labeled = std.fmt.bufPrintZ(&line, "Block size: {d}  (click)", .{view.audio_block_size}) catch "Block size";
        c.DrawText(labeled.ptr, px + 10, MENU_H + 6, 14, COL_TEXT);
    }

    // About modal
    if (view.show_about) {
        const dlg_x: i32 = @intFromFloat(chrome.transport.width * 0.5 - 180);
        c.DrawRectangle(0, 0, @intFromFloat(chrome.transport.width), @intFromFloat(chrome.mcp.y + chrome.mcp.height), .{ .r = 0, .g = 0, .b = 0, .a = 140 });
        c.DrawRectangle(dlg_x, 100, 360, 120, COL_PANEL);
        c.DrawRectangleLines(dlg_x, 100, 360, 120, COL_TEXT);
        c.DrawText("FastMix AI", dlg_x + 16, 116, 22, COL_TEXT);
        c.DrawText("AI-first DAW: real-time mixer + AI control.", dlg_x + 16, 150, 14, COL_DIM);
        c.DrawText("Click anywhere to close.", dlg_x + 16, 180, 12, COL_DIM);
    }

    // Dirty confirm
    if (view.show_dirty_confirm) {
        const dlg_x: i32 = @intFromFloat(chrome.transport.width * 0.5 - 180);
        const dlg_y: i32 = 140;
        c.DrawRectangle(0, 0, @intFromFloat(chrome.transport.width), @intFromFloat(chrome.mcp.y + chrome.mcp.height), .{ .r = 0, .g = 0, .b = 0, .a = 160 });
        c.DrawRectangle(dlg_x, dlg_y, 360, 110, COL_PANEL);
        c.DrawRectangleLines(dlg_x, dlg_y, 360, 110, COL_TEXT);
        c.DrawText("Project has unsaved changes.", dlg_x + 16, dlg_y + 16, 16, COL_TEXT);
        c.DrawText("Save before continuing?", dlg_x + 16, dlg_y + 40, 14, COL_DIM);
        c.DrawRectangle(dlg_x + 20, dlg_y + 70, 90, 28, COL_SOLO);
        c.DrawText("Save", dlg_x + 44, dlg_y + 76, 14, COL_TEXT);
        c.DrawRectangle(dlg_x + 120, dlg_y + 70, 110, 28, COL_MUTE);
        c.DrawText("Discard", dlg_x + 140, dlg_y + 76, 14, COL_TEXT);
        c.DrawRectangle(dlg_x + 240, dlg_y + 70, 100, 28, COL_BTN);
        c.DrawText("Cancel", dlg_x + 262, dlg_y + 76, 14, COL_TEXT);
    }

    // Open / Save As browser
    if (view.path_modal != .none) {
        const dlg_w: i32 = 560;
        const dlg_h: i32 = 420;
        const dlg_x: i32 = @intFromFloat(chrome.transport.width * 0.5 - @as(f32, @floatFromInt(dlg_w)) * 0.5);
        const dlg_y: i32 = 70;
        c.DrawRectangle(0, 0, @intFromFloat(chrome.transport.width), @intFromFloat(chrome.mcp.y + chrome.mcp.height), .{ .r = 0, .g = 0, .b = 0, .a = 160 });
        c.DrawRectangle(dlg_x, dlg_y, dlg_w, dlg_h, COL_PANEL);
        c.DrawRectangleLines(dlg_x, dlg_y, dlg_w, dlg_h, COL_TEXT);

        const title: [*:0]const u8 = switch (view.path_modal) {
            .save_as => "Save project as",
            .open => "Open project",
            .render => "Render master WAV",
            .none => "Path",
        };
        c.DrawText(title, dlg_x + 12, dlg_y + 10, 18, COL_TEXT);

        // Current folder
        c.DrawText("Folder:", dlg_x + 12, dlg_y + 36, 12, COL_DIM);
        var dir_z: [769]u8 = undefined;
        const dlen = @min(view.path_dir_len, 768);
        @memcpy(dir_z[0..dlen], view.path_dir_buf[0..dlen]);
        dir_z[dlen] = 0;
        c.DrawText(&dir_z, dlg_x + 70, dlg_y + 36, 12, COL_TEXT);

        // Listing
        c.DrawRectangle(dlg_x + 12, dlg_y + 56, dlg_w - 24, 240, rgb(0x22, 0x22, 0x22));
        const row_h: i32 = 22;
        const visible: usize = 10;
        var row: usize = 0;
        while (row < visible) : (row += 1) {
            const idx = view.path_list_scroll + row;
            if (idx >= view.path_list_len) break;
            const y = dlg_y + 56 + @as(i32, @intCast(row)) * row_h;
            const nm = std.mem.sliceTo(&view.path_list_names[idx], 0);
            const col = if (view.path_list_is_dir[idx]) COL_MUTE else COL_TEXT;
            var line_buf: [120]u8 = undefined;
            const line = if (view.path_list_is_dir[idx])
                (std.fmt.bufPrintZ(&line_buf, "[dir]  {s}", .{nm}) catch nm)
            else
                (std.fmt.bufPrintZ(&line_buf, "      {s}", .{nm}) catch nm);
            c.DrawText(line.ptr, dlg_x + 18, y + 4, 14, col);
        }
        c.DrawText("Click folder to enter · click file to select · wheel to scroll", dlg_x + 12, dlg_y + 300, 12, COL_DIM);

        // Filename field + caret
        c.DrawText("Name:", dlg_x + 12, dlg_y + 318, 14, COL_TEXT);
        c.DrawRectangle(dlg_x + 70, dlg_y + 310, dlg_w - 94, 28, rgb(0x11, 0x11, 0x11));
        if (view.path_focus == .name) {
            c.DrawRectangleLines(dlg_x + 70, dlg_y + 310, dlg_w - 94, 28, COL_SOLO);
        } else {
            c.DrawRectangleLines(dlg_x + 70, dlg_y + 310, dlg_w - 94, 28, COL_GRID);
        }
        var name_z: [257]u8 = undefined;
        const nlen = @min(view.path_name_len, 256);
        @memcpy(name_z[0..nlen], view.path_name_buf[0..nlen]);
        name_z[nlen] = 0;
        c.DrawText(&name_z, dlg_x + 78, dlg_y + 316, 14, COL_TEXT);
        // Blink caret
        if (view.path_focus == .name and @mod(@as(i32, @intFromFloat(c.GetTime() * 2.0)), 2) == 0) {
            var prefix_buf: [257]u8 = undefined;
            const plen = @min(view.path_caret, nlen);
            @memcpy(prefix_buf[0..plen], view.path_name_buf[0..plen]);
            prefix_buf[plen] = 0;
            const caret_x = dlg_x + 78 + c.MeasureText(&prefix_buf, 14);
            c.DrawRectangle(caret_x, dlg_y + 314, 2, 20, COL_TEXT);
        }

        // Full path preview
        c.DrawText("Path:", dlg_x + 12, dlg_y + 348, 12, COL_DIM);
        var full_z: [1025]u8 = undefined;
        const flen = @min(view.open_path_len, 1024);
        @memcpy(full_z[0..flen], view.open_path_buf[0..flen]);
        full_z[flen] = 0;
        c.DrawText(&full_z, dlg_x + 56, dlg_y + 348, 12, COL_DIM);

        c.DrawRectangle(dlg_x + dlg_w - 160, dlg_y + dlg_h - 40, 70, 28, COL_SOLO);
        c.DrawText("OK", dlg_x + dlg_w - 138, dlg_y + dlg_h - 34, 14, COL_TEXT);
        c.DrawRectangle(dlg_x + dlg_w - 80, dlg_y + dlg_h - 40, 70, 28, COL_BTN);
        c.DrawText("Cancel", dlg_x + dlg_w - 68, dlg_y + dlg_h - 34, 14, COL_TEXT);
    }

    if (view.status_msg_len > 0) {
        // Was anchored at chrome.mcp.y - 18, which sits inside the TCP
        // footer's 22px band (TCP_FOOTER_H) and visually collided with the
        // "+ Add Track" label there (both drawn most frames while a status
        // message is showing). Right-align inside the transport bar instead
        // -- a dedicated status row, no other widget draws that far right.
        const msg_z: [*:0]const u8 = @ptrCast(&view.status_msg);
        const tw = c.MeasureText(msg_z, 14);
        const x = @as(i32, @intFromFloat(chrome.transport.x + chrome.transport.width)) - tw - 12;
        const y = @as(i32, @intFromFloat(chrome.transport.y)) + 12;
        c.DrawText(msg_z, x, y, 14, COL_MUTE);
    }

    // Context menu on top
    if (view.ctx_menu != .none) {
        const mw: i32 = @intFromFloat(ctxMenuWidth());
        const mh: i32 = @intFromFloat(ctxMenuHeight(view.ctx_menu));
        const mx: i32 = @intFromFloat(view.ctx_x);
        const my: i32 = @intFromFloat(view.ctx_y);
        c.DrawRectangle(mx, my, mw, mh, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleLines(mx, my, mw, mh, COL_TEXT);
        const labels: []const [*:0]const u8 = switch (view.ctx_menu) {
            .none => &.{},
            .track => &.{ "Rename", "Duplicate", "Remove", "Arm", "Mute", "Solo", "Open FX" },
            .item => &.{ "Split here", "Delete", "Duplicate", "Mute item" },
            .empty => &.{ "Insert audio track", "Import audio…", "Paste" },
        };
        for (labels, 0..) |lab, i| {
            c.DrawText(lab, mx + 10, my + 6 + @as(i32, @intCast(i)) * 28, 14, COL_TEXT);
        }
    }

    // Grid ▾ menu
    if (view.grid_menu_open) {
        const opts = gridMenuOptions();
        const mx: i32 = @intFromFloat(transport_l.grid.x);
        const my: i32 = @intFromFloat(transport_l.grid.y + transport_l.grid.height + 2);
        const mw: i32 = @intFromFloat(@max(110.0, transport_l.grid.width));
        const row_h: i32 = 24;
        c.DrawRectangle(mx, my, mw, @as(i32, @intCast(opts.len)) * row_h, rgb(0x3a, 0x3a, 0x3a));
        c.DrawRectangleLines(mx, my, mw, @as(i32, @intCast(opts.len)) * row_h, COL_TEXT);
        for (opts, 0..) |opt, i| {
            const y = my + @as(i32, @intCast(i)) * row_h;
            if (opt == view.grid_div) c.DrawRectangle(mx + 1, y + 1, mw - 2, row_h - 2, COL_FADER);
            c.DrawText(gridDivLabel(opt), mx + 10, y + 4, 14, COL_TEXT);
        }
    }

    _ = EDGE_PX;
}
