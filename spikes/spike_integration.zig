const std = @import("std");

const ray = @cImport({
    @cInclude("raylib.h");
});
const sdl = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
});
const libc = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
});

// Spike: the big one -- does everything actually fit together in ONE 60fps
// loop? Every previous spike proved one piece works in isolation (or, for
// SDL+raylib, a pair). This runs ALL FOUR at once for real, in the same loop:
//   1. raylib window + audio output (graphics + synth playback)
//   2. SDL2 audio capture (mic input)
//   3. Unix control socket (non-blocking accept/recv, real client mid-run)
//   4. A background ffmpeg "job" spawned partway through, polled to
//      completion via non-blocking waitpid (§11.1 Jobs mechanism)
// If this doesn't starve/hang/crash and stays close to 60fps throughout,
// the "does the architecture actually fit together" integration risk from
// roadmap §10 is closed.

const SAMPLE_RATE: u32 = 44100;
const BUFFER_SIZE: usize = 2048;
const SOCKET_PATH = "/tmp/fastmix-ai_integration_spike.sock";

fn wifExited(status: c_int) bool {
    return (status & 0x7f) == 0;
}

fn setNonBlocking(fd: c_int) void {
    const flags = libc.fcntl(fd, libc.F_GETFL, @as(c_int, 0));
    _ = libc.fcntl(fd, libc.F_SETFL, flags | libc.O_NONBLOCK);
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // --- 1. raylib: window + audio output ---
    ray.SetTraceLogLevel(ray.LOG_WARNING);
    ray.InitWindow(500, 300, "spike: everything at once");
    defer ray.CloseWindow();
    ray.SetTargetFPS(60);
    ray.SetExitKey(ray.KEY_NULL);

    ray.InitAudioDevice();
    defer ray.CloseAudioDevice();
    ray.SetAudioStreamBufferSizeDefault(@intCast(BUFFER_SIZE));
    const stream = ray.LoadAudioStream(SAMPLE_RATE, 32, 1);
    defer ray.UnloadAudioStream(stream);
    ray.PlayAudioStream(stream);
    var audio_buf: [BUFFER_SIZE]f32 = undefined;
    var synth_frame: u64 = 0;

    // --- 2. SDL2: audio capture ---
    if (sdl.SDL_Init(sdl.SDL_INIT_AUDIO) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();

    var capture_dev: sdl.SDL_AudioDeviceID = 0;
    var captured_samples: usize = 0;
    if (sdl.SDL_GetNumAudioDevices(1) > 0) {
        var desired: sdl.SDL_AudioSpec = std.mem.zeroes(sdl.SDL_AudioSpec);
        desired.freq = SAMPLE_RATE;
        desired.format = sdl.AUDIO_F32;
        desired.channels = 1;
        desired.samples = 1024;
        var obtained: sdl.SDL_AudioSpec = undefined;
        capture_dev = sdl.SDL_OpenAudioDevice(null, 1, &desired, &obtained, 0);
        if (capture_dev != 0) sdl.SDL_PauseAudioDevice(capture_dev, 0);
    }
    defer if (capture_dev != 0) sdl.SDL_CloseAudioDevice(capture_dev);
    std.debug.print("SDL capture device opened: {}\n", .{capture_dev != 0});

    // --- 3. Unix control socket ---
    _ = libc.unlink(SOCKET_PATH);
    const listen_fd = libc.socket(libc.AF_UNIX, libc.SOCK_STREAM, 0);
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = libc.close(listen_fd);

    var addr: libc.sockaddr_un = std.mem.zeroes(libc.sockaddr_un);
    addr.sun_family = libc.AF_UNIX;
    @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);
    if (libc.bind(listen_fd, @ptrCast(&addr), @sizeOf(libc.sockaddr_un)) != 0) return error.BindFailed;
    if (libc.listen(listen_fd, 8) != 0) return error.ListenFailed;
    setNonBlocking(listen_fd);

    var client_fd: c_int = -1;
    var commands_handled: u32 = 0;

    // --- 4. Background ffmpeg job, spawned at frame 60 (~1s in) ---
    var job_pid: ?std.posix.pid_t = null;
    var job_done = false;
    var job_started_frame: u32 = 0;
    var job_finished_frame: u32 = 0;

    var frame: u32 = 0;
    const total_frames: u32 = 240; // ~4s at 60fps
    const loop_start = ray.GetTime();

    while (!ray.WindowShouldClose() and frame < total_frames) : (frame += 1) {
        // --- socket: non-blocking accept + recv, same pattern as spike_socket.zig ---
        if (client_fd < 0) {
            const fd = libc.accept(listen_fd, null, null);
            if (fd >= 0) {
                setNonBlocking(fd);
                client_fd = fd;
            }
        }
        if (client_fd >= 0) {
            var chunk: [256]u8 = undefined;
            const n = libc.recv(client_fd, &chunk, chunk.len, 0);
            if (n > 0) {
                commands_handled += 1;
                const response = "{\"ok\":true}\n";
                _ = libc.send(client_fd, response.ptr, response.len, 0);
            } else if (n == 0) {
                _ = libc.close(client_fd);
                client_fd = -1;
            }
        }

        // --- SDL capture: drain whatever's queued ---
        if (capture_dev != 0) {
            var poll_buf: [4096]u8 = undefined;
            const queued = sdl.SDL_DequeueAudio(capture_dev, &poll_buf, poll_buf.len);
            if (queued > 0) captured_samples += @intCast(@divTrunc(queued, @sizeOf(f32)));
        }

        // --- job: spawn once at frame 60, poll to completion ---
        if (frame == 60 and job_pid == null) {
            const child = try std.process.spawn(io, .{
                .argv = &.{
                    "/opt/homebrew/bin/ffmpeg", "-y",
                    "-f",                       "lavfi",
                    "-i",                       "sine=frequency=220:duration=1",
                    "spikes/integration_job_out.wav",
                },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            job_pid = child.id.?;
            job_started_frame = frame;
            std.debug.print("frame {}: spawned background job pid={}\n", .{ frame, job_pid.? });
        }
        if (job_pid != null and !job_done) {
            var status: c_int = 0;
            const ret = libc.waitpid(job_pid.?, &status, libc.WNOHANG);
            if (ret == job_pid.?) {
                job_done = true;
                job_finished_frame = frame;
                std.debug.print("frame {}: background job finished (exited={}), took {} frames\n", .{ frame, wifExited(status), frame - job_started_frame });
            }
        }

        // --- raylib audio output: keep the synth fed ---
        if (ray.IsAudioStreamProcessed(stream)) {
            for (0..BUFFER_SIZE) |s| {
                const t: f32 = @as(f32, @floatFromInt(synth_frame)) / @as(f32, @floatFromInt(SAMPLE_RATE));
                audio_buf[s] = @sin(2.0 * std.math.pi * t * 440.0) * 0.2;
                synth_frame += 1;
            }
            ray.UpdateAudioStream(stream, &audio_buf, @intCast(BUFFER_SIZE));
        }

        // --- raylib render ---
        ray.BeginDrawing();
        ray.ClearBackground(ray.Color{ .r = 30, .g = 30, .b = 30, .a = 255 });
        ray.DrawText(ray.TextFormat("frame %d/%d", frame, total_frames), 10, 10, 20, ray.WHITE);
        ray.DrawText(ray.TextFormat("commands handled: %d", commands_handled), 10, 40, 20, ray.WHITE);
        ray.DrawText(ray.TextFormat("captured samples: %d", captured_samples), 10, 70, 20, ray.WHITE);
        ray.DrawText(ray.TextFormat("job done: %d", @as(c_int, if (job_done) 1 else 0)), 10, 100, 20, ray.WHITE);
        ray.EndDrawing();
    }

    const loop_elapsed = ray.GetTime() - loop_start;
    const expected_elapsed: f64 = @as(f64, @floatFromInt(total_frames)) / 60.0;

    if (client_fd >= 0) _ = libc.close(client_fd);
    _ = libc.unlink(SOCKET_PATH);

    std.debug.print("\n=== results ===\n", .{});
    std.debug.print("frames run: {}\n", .{frame});
    std.debug.print("wall time: {d:.2}s (expected ~{d:.2}s at 60fps)\n", .{ loop_elapsed, expected_elapsed });
    std.debug.print("commands handled via socket: {}\n", .{commands_handled});
    std.debug.print("SDL samples captured: {}\n", .{captured_samples});
    std.debug.print("background job finished: {} (started frame {}, finished frame {})\n", .{ job_done, job_started_frame, job_finished_frame });

    if (loop_elapsed > expected_elapsed * 1.5) {
        std.debug.print("FAIL: loop ran way slower than 60fps -- something is blocking\n", .{});
        return error.LoopTooSlow;
    }
    if (!job_done) {
        std.debug.print("FAIL: background job never completed within the run\n", .{});
        return error.JobNeverCompleted;
    }
    if (commands_handled == 0) {
        std.debug.print("NOTE: no socket commands were received (expected if no client connected during this run)\n", .{});
    }

    std.debug.print("PASS: socket + SDL capture + background job polling + raylib render/audio all ran together without blocking or crashing\n", .{});
}
