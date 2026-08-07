const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
});

/// Persistent audio engine prefs (REAPER-like block size / buffer).
/// Device sample-rate forcing is intentionally NOT here — that path silenced BT.
pub const CONFIG_PATH = "fastmix_audio.json";

pub const MAX_BLOCK_SIZE: u32 = 4096;
pub const DEFAULT_BLOCK_SIZE: u32 = 2048;
pub const ALLOWED_BLOCK_SIZES = [_]u32{ 512, 1024, 2048, 4096 };

pub const AudioConfig = struct {
    /// raylib AudioStream buffer frames (per channel count handling is inside raylib).
    block_size: u32 = DEFAULT_BLOCK_SIZE,
};

const FileDto = struct {
    block_size: u32,
};

pub fn isAllowedBlockSize(n: u32) bool {
    for (ALLOWED_BLOCK_SIZES) |a| {
        if (a == n) return true;
    }
    return false;
}

pub fn sanitizeBlockSize(n: u32) u32 {
    if (isAllowedBlockSize(n)) return n;
    // Snap to nearest allowed.
    var best: u32 = DEFAULT_BLOCK_SIZE;
    var best_d: u32 = std.math.maxInt(u32);
    for (ALLOWED_BLOCK_SIZES) |a| {
        const d: u32 = if (a > n) a - n else n - a;
        if (d < best_d) {
            best_d = d;
            best = a;
        }
    }
    return best;
}

pub fn nextBlockSize(n: u32) u32 {
    const cur = sanitizeBlockSize(n);
    var i: usize = 0;
    while (i < ALLOWED_BLOCK_SIZES.len) : (i += 1) {
        if (ALLOWED_BLOCK_SIZES[i] == cur) {
            return ALLOWED_BLOCK_SIZES[(i + 1) % ALLOWED_BLOCK_SIZES.len];
        }
    }
    return DEFAULT_BLOCK_SIZE;
}

pub fn load(gpa: std.mem.Allocator, path: []const u8) ?AudioConfig {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    const f = c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);

    _ = c.fseek(f, 0, c.SEEK_END);
    const size: usize = @intCast(c.ftell(f));
    _ = c.fseek(f, 0, c.SEEK_SET);
    if (size == 0 or size > 4096) return null;

    const buf = gpa.alloc(u8, size) catch return null;
    defer gpa.free(buf);
    if (c.fread(buf.ptr, 1, size, f) != size) return null;

    const parsed = std.json.parseFromSlice(FileDto, gpa, buf, .{}) catch return null;
    defer parsed.deinit();
    return .{ .block_size = sanitizeBlockSize(parsed.value.block_size) };
}

pub fn save(gpa: std.mem.Allocator, path: []const u8, cfg: AudioConfig) !void {
    const dto = FileDto{ .block_size = sanitizeBlockSize(cfg.block_size) };
    const text = try std.json.Stringify.valueAlloc(gpa, dto, .{ .whitespace = .indent_2 });
    defer gpa.free(text);

    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const f = c.fopen(path_z.ptr, "wb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    if (c.fwrite(text.ptr, 1, text.len, f) != text.len) return error.ShortWrite;
    _ = c.fwrite("\n", 1, 1, f);
}

pub fn loadOrDefault(gpa: std.mem.Allocator, path: []const u8) AudioConfig {
    if (load(gpa, path)) |cfg| return cfg;
    const cfg = AudioConfig{};
    save(gpa, path, cfg) catch {};
    return cfg;
}

test "sanitize and cycle block sizes" {
    try std.testing.expectEqual(@as(u32, 2048), sanitizeBlockSize(2000));
    try std.testing.expectEqual(@as(u32, 512), sanitizeBlockSize(512));
    try std.testing.expectEqual(@as(u32, 1024), nextBlockSize(512));
    try std.testing.expectEqual(@as(u32, 512), nextBlockSize(4096));
}
