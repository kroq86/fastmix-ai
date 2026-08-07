const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
});

// First-launch window size: detect monitor resolution once, persist to JSON.
// Subsequent launches reuse the file; main still MaximizeWindow() so the
// frame fills the display. File I/O via libc fopen — same style as persist.zig
// (Zig 0.16 std.fs.cwd() is gone / reshaped).

pub const CONFIG_PATH = "fastmix_window.json";

pub const WindowConfig = struct {
    width: i32 = 1280,
    height: i32 = 720,
};

const FileDto = struct {
    width: i32,
    height: i32,
};

pub fn load(gpa: std.mem.Allocator, path: []const u8) ?WindowConfig {
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
    if (parsed.value.width < 320 or parsed.value.height < 240) return null;
    return .{ .width = parsed.value.width, .height = parsed.value.height };
}

pub fn save(gpa: std.mem.Allocator, path: []const u8, cfg: WindowConfig) !void {
    const dto = FileDto{ .width = cfg.width, .height = cfg.height };
    const text = try std.json.Stringify.valueAlloc(gpa, dto, .{ .whitespace = .indent_2 });
    defer gpa.free(text);

    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const f = c.fopen(path_z.ptr, "wb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    if (c.fwrite(text.ptr, 1, text.len, f) != text.len) return error.ShortWrite;
    _ = c.fwrite("\n", 1, 1, f);
}

/// If config exists, return it. Otherwise create from detected monitor size.
pub fn loadOrCreate(gpa: std.mem.Allocator, path: []const u8, detect_w: i32, detect_h: i32) !WindowConfig {
    if (load(gpa, path)) |cfg| return cfg;
    const cfg = WindowConfig{
        .width = @max(320, detect_w),
        .height = @max(240, detect_h),
    };
    try save(gpa, path, cfg);
    std.debug.print("window config: first launch, wrote {s} ({d}x{d})\n", .{ path, cfg.width, cfg.height });
    return cfg;
}
