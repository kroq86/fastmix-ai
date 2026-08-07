const std = @import("std");
const model = @import("model.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});

// Save/Load (roadmap §5) + Undo/Redo (§11.2). Both proven mechanisms:
//   - atomic tmp+fsync+rename genuinely prevents torn reads under a
//     concurrent reader (spikes/spike_save_cache.zig: naive truncate-write
//     was actually caught corrupted, atomic write never was).
//   - undo MUST snapshot via deep-clone (toDto), never a plain struct copy
//     (spikes/spike_undo.zig: struct-copy aliases ArrayList memory and
//     silently "sees" later mutations).

pub fn saveAtomic(gpa: std.mem.Allocator, project: *const model.Project, path: []const u8) !void {
    const dto = try model.toDto(gpa, project);
    defer model.freeProjectDto(gpa, &dto);

    const file: model.ProjectFile = .{ .project = dto };
    const text = try std.json.Stringify.valueAlloc(gpa, file, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer gpa.free(text);

    var tmp_buf: [4096]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{path});
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});

    const f = c.fopen(tmp_path.ptr, "wb") orelse return error.OpenFailed;
    const written = c.fwrite(text.ptr, 1, text.len, f);
    if (written != text.len) {
        _ = c.fclose(f);
        return error.ShortWrite;
    }
    _ = c.fflush(f);
    _ = c.fsync(c.fileno(f));
    _ = c.fclose(f);

    if (c.rename(tmp_path.ptr, path_z.ptr) != 0) return error.RenameFailed;
}

pub fn load(gpa: std.mem.Allocator, path: []const u8) !model.Project {
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});

    const f = c.fopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);

    _ = c.fseek(f, 0, c.SEEK_END);
    const size: usize = @intCast(c.ftell(f));
    _ = c.fseek(f, 0, c.SEEK_SET);

    const buf = try gpa.alloc(u8, size);
    defer gpa.free(buf);
    const read_n = c.fread(buf.ptr, 1, size, f);
    if (read_n != size) return error.ShortRead;

    const parsed = try std.json.parseFromSlice(model.ProjectFile, gpa, buf, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const fmt = parsed.value.format;
    if (!std.mem.eql(u8, fmt, "fastmix-ai-project")) return error.WrongFormat;
    if (parsed.value.version != 1) return error.UnsupportedVersion;

    return model.fromDto(gpa, parsed.value.project);
}

pub const History = struct {
    undo_stack: std.ArrayList(model.ProjectDto) = .empty,
    redo_stack: std.ArrayList(model.ProjectDto) = .empty,
    max_depth: usize = 50,

    pub fn deinit(self: *History, gpa: std.mem.Allocator) void {
        for (self.undo_stack.items) |*s| model.freeProjectDto(gpa, s);
        self.undo_stack.deinit(gpa);
        for (self.redo_stack.items) |*s| model.freeProjectDto(gpa, s);
        self.redo_stack.deinit(gpa);
    }

    /// Call BEFORE applying any mutating command. Snapshots current state
    /// for undo and invalidates the redo history (standard undo/redo rule:
    /// a new action after an undo discards the old redo branch).
    pub fn recordBeforeMutation(self: *History, gpa: std.mem.Allocator, project: *const model.Project) !void {
        const dto = try model.toDto(gpa, project);
        try self.undo_stack.append(gpa, dto);
        if (self.undo_stack.items.len > self.max_depth) {
            var oldest = self.undo_stack.orderedRemove(0);
            model.freeProjectDto(gpa, &oldest);
        }
        for (self.redo_stack.items) |*s| model.freeProjectDto(gpa, s);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Replaces `project.*` with the previous snapshot, if any. Returns
    /// false (no-op) if there's nothing to undo.
    pub fn undo(self: *History, gpa: std.mem.Allocator, project: *model.Project) !bool {
        if (self.undo_stack.items.len == 0) return false;
        const current_dto = try model.toDto(gpa, project);
        try self.redo_stack.append(gpa, current_dto);

        const prev_dto = self.undo_stack.pop().?;
        defer model.freeProjectDto(gpa, &prev_dto);
        project.deinit(gpa);
        project.* = try model.fromDto(gpa, prev_dto);
        return true;
    }

    pub fn redo(self: *History, gpa: std.mem.Allocator, project: *model.Project) !bool {
        if (self.redo_stack.items.len == 0) return false;
        const current_dto = try model.toDto(gpa, project);
        try self.undo_stack.append(gpa, current_dto);

        const next_dto = self.redo_stack.pop().?;
        defer model.freeProjectDto(gpa, &next_dto);
        project.deinit(gpa);
        project.* = try model.fromDto(gpa, next_dto);
        return true;
    }
};
