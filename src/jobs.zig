const std = @import("std");

const c = @cImport({
    @cInclude("sys/wait.h");
});

// Non-blocking subprocess job registry (roadmap §11.1), proven in
// spikes/spike_job_poll.zig and spikes/spike_integration.zig: spawn via
// std.process.spawn (Zig handles fork/exec correctly), then poll completion
// via raw libc waitpid(pid, WNOHANG) -- NOT child.wait(io), which blocks.
// Not yet wired to any real command (no ffmpeg-backed feature exists yet in
// the core); this is the reusable mechanism future phases (§14 effects,
// §12 import_audio, §16 analysis) will spawn onto.

fn wifExited(status: c_int) bool {
    return (status & 0x7f) == 0;
}
fn wexitStatus(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

pub const JobId = u64;

pub const JobStatus = enum { running, succeeded, failed };

pub const Job = struct {
    id: JobId,
    pid: std.posix.pid_t,
    status: JobStatus = .running,
    exit_code: u8 = 0,
};

pub const Registry = struct {
    jobs: std.ArrayList(Job) = .empty,
    next_id: JobId = 1,

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.jobs.deinit(gpa);
    }

    /// Spawns argv as a background job. Does not block. Caller keeps stdio
    /// redirected to .ignore or .pipe as needed by the specific job later;
    /// for now the core just proves the spawn+poll mechanism.
    pub fn spawn(self: *Registry, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !JobId {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const id = self.next_id;
        self.next_id += 1;
        try self.jobs.append(gpa, .{ .id = id, .pid = child.id.? });
        return id;
    }

    /// Same as spawn, but the child's stdout/stderr go to the app's terminal
    /// (long-running workers whose progress/errors a human should see).
    pub fn spawnLogged(self: *Registry, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !JobId {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const id = self.next_id;
        self.next_id += 1;
        try self.jobs.append(gpa, .{ .id = id, .pid = child.id.? });
        return id;
    }

    /// Call once per frame. Non-blocking: checks every running job's status
    /// via waitpid(WNOHANG) and updates it in place.
    pub fn poll(self: *Registry) void {
        for (self.jobs.items) |*job| {
            if (job.status != .running) continue;
            var status: c_int = 0;
            const ret = c.waitpid(job.pid, &status, c.WNOHANG);
            if (ret == job.pid) {
                job.exit_code = wexitStatus(status);
                job.status = if (wifExited(status) and job.exit_code == 0) .succeeded else .failed;
            }
        }
    }

    pub fn find(self: *Registry, id: JobId) ?*Job {
        for (self.jobs.items) |*j| {
            if (j.id == id) return j;
        }
        return null;
    }
};
