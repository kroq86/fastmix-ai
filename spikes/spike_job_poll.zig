const std = @import("std");

// Spike: roadmap §11.1 "Jobs" architecture assumes we can spawn a subprocess
// and check completion status once per frame WITHOUT blocking the render
// loop. Every spike so far used `std.process.run`, which BLOCKS until the
// child exits (proven fine for short ffmpeg calls, but wrong model for the
// actual Jobs mechanism). This spike proves the real non-blocking pattern:
// spawn via `std.process.spawn` (Zig handles the fork/exec dance correctly),
// then poll completion ourselves via raw libc `waitpid(pid, &status, WNOHANG)`
// -- same FFI-first philosophy already used for the control socket, and it
// sidesteps needing `child.wait(io)` (which would block) entirely.

const c = @cImport({
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

fn wifExited(status: c_int) bool {
    // Portable convention (avoids relying on translate-c parsing the
    // WIFEXITED/WEXITSTATUS bit-twiddling macros): low 7 bits are 0 if the
    // child exited normally.
    return (status & 0x7f) == 0;
}
fn wexitStatus(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("=== job 1: `sleep 2` -- pure mechanism test, decoupled from ffmpeg specifics ===\n", .{});
    {
        const child = try std.process.spawn(io, .{
            .argv = &.{ "/bin/sleep", "2" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        const pid = child.id.?;
        std.debug.print("spawned pid={}\n", .{pid});

        var frame: u32 = 0;
        var finished = false;
        while (frame < 300 and !finished) : (frame += 1) { // up to ~4.8s of simulated frames
            var status: c_int = 0;
            const ret = c.waitpid(pid, &status, c.WNOHANG);
            if (ret == pid) {
                const elapsed_ms = frame * 16;
                std.debug.print("frame {}: job finished after ~{}ms (16ms/frame estimate), exited={} code={}\n", .{ frame, elapsed_ms, wifExited(status), wexitStatus(status) });
                finished = true;
            } else if (ret == 0) {
                // still running -- this is the whole point: we do NOT block here.
            } else {
                std.debug.print("waitpid error: {}\n", .{ret});
                return error.WaitpidFailed;
            }
            _ = c.usleep(16000);
        }

        if (!finished) {
            std.debug.print("FAIL: job never finished within the polling window\n", .{});
            return error.JobNeverFinished;
        }
        // Sanity: a properly non-blocking loop should have needed on the
        // order of ~2000ms/16ms ~= 125 polls, not finish instantly (which
        // would suggest waitpid secretly blocked) nor take way longer.
        if (frame < 100 or frame > 200) {
            std.debug.print("SUSPICIOUS: expected ~125 polling frames for a 2s job, got {}\n", .{frame});
        }
    }

    std.debug.print("\n=== job 2: real ffmpeg, spawned non-blocking, polled to completion ===\n", .{});
    {
        const child = try std.process.spawn(io, .{
            .argv = &.{
                "/opt/homebrew/bin/ffmpeg", "-y",
                "-f",                       "lavfi",
                "-i",                       "sine=frequency=440:duration=1",
                "spikes/job_poll_test.wav",
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const pid = child.id.?;

        var frame: u32 = 0;
        var finished = false;
        while (frame < 300 and !finished) : (frame += 1) {
            var status: c_int = 0;
            const ret = c.waitpid(pid, &status, c.WNOHANG);
            if (ret == pid) {
                std.debug.print("frame {}: ffmpeg job finished, exited={} code={}\n", .{ frame, wifExited(status), wexitStatus(status) });
                finished = true;
            } else if (ret != 0) {
                std.debug.print("waitpid error: {}\n", .{ret});
                return error.WaitpidFailed;
            }
            _ = c.usleep(16000);
        }
        if (!finished) {
            std.debug.print("FAIL: ffmpeg job never finished within the polling window\n", .{});
            return error.JobNeverFinished;
        }
        if (c.access("spikes/job_poll_test.wav", c.F_OK) != 0) {
            std.debug.print("FAIL: ffmpeg reported done but output file missing\n", .{});
            return error.OutputMissing;
        }
    }

    std.debug.print("\nPASS: subprocess jobs can be spawned and polled to completion without blocking the caller\n", .{});
}
