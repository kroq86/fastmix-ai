const std = @import("std");

// Spike: the control-API layer (roadmap §11) needs a Unix domain socket that
// the main render/audio loop can poll once per frame WITHOUT blocking. Zig
// 0.16's own std.Io networking (std.Io.net.Server/Socket) turned out to be a
// much bigger, still-settling surface tied to a whole new async-I/O redesign
// (every op needs an `Io` instance from std.Io.Threaded, itself a fairly deep
// rabbit hole -- see spike_ffmpeg_effects.zig for where that WAS worth using,
// for subprocess spawning). For a plain non-blocking accept/recv loop, raw
// libc socket calls via @cImport are simpler, stable across Zig versions, and
// match the same FFI philosophy already used for raylib.

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("string.h");
});

const SOCKET_PATH = "/tmp/fastmix-ai_spike.sock";

const Cmd = struct {
    id: i64 = 0,
    cmd: []const u8,
    bpm: ?f64 = null,
};

fn setNonBlocking(fd: c_int) void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    _ = c.unlink(SOCKET_PATH); // ignore ENOENT if it doesn't exist yet

    const listen_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = c.close(listen_fd);

    var addr: c.sockaddr_un = std.mem.zeroes(c.sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);

    const bind_res = c.bind(listen_fd, @ptrCast(&addr), @sizeOf(c.sockaddr_un));
    if (bind_res != 0) return error.BindFailed;

    if (c.listen(listen_fd, 8) != 0) return error.ListenFailed;
    setNonBlocking(listen_fd);

    std.debug.print("listening on {s}, polling non-blocking for ~8s (like one frame per ~16ms)...\n", .{SOCKET_PATH});

    var client_fd: c_int = -1;
    var line_buf: [1024]u8 = undefined;
    var line_len: usize = 0;

    var frame: u32 = 0;
    var handled: u32 = 0;
    while (frame < 500) : (frame += 1) { // ~500 * 16ms ~= 8s of simulated frames
        // Non-blocking accept: try to pick up a new client every frame.
        if (client_fd < 0) {
            const fd = c.accept(listen_fd, null, null);
            if (fd >= 0) {
                std.debug.print("frame {}: client connected (fd={})\n", .{ frame, fd });
                setNonBlocking(fd);
                client_fd = fd;
                line_len = 0;
            }
        }

        // Non-blocking recv: pull whatever bytes are available, split on '\n'.
        if (client_fd >= 0) {
            var chunk: [256]u8 = undefined;
            const n = c.recv(client_fd, &chunk, chunk.len, 0);
            if (n > 0) {
                const un: usize = @intCast(n);
                for (chunk[0..un]) |byte| {
                    if (byte == '\n') {
                        const line = line_buf[0..line_len];
                        handled += 1;
                        handleLine(gpa, client_fd, line);
                        line_len = 0;
                    } else if (line_len < line_buf.len) {
                        line_buf[line_len] = byte;
                        line_len += 1;
                    }
                }
            } else if (n == 0) {
                std.debug.print("frame {}: client disconnected\n", .{frame});
                _ = c.close(client_fd);
                client_fd = -1;
            }
            // n < 0: no data available right now (EAGAIN/EWOULDBLOCK) -- fine, try next frame.
        }

        _ = c.usleep(16000);
    }

    if (client_fd >= 0) _ = c.close(client_fd);
    _ = c.unlink(SOCKET_PATH);

    std.debug.print("done: {} commands handled over simulated frame loop\n", .{handled});
    if (handled == 0) {
        std.debug.print("FAIL: no client ever connected/sent a command within the run window\n", .{});
        return error.NoCommandsHandled;
    }
    std.debug.print("PASS\n", .{});
}

fn handleLine(gpa: std.mem.Allocator, client_fd: c_int, line: []const u8) void {
    const parsed = std.json.parseFromSlice(Cmd, gpa, line, .{}) catch |err| {
        std.debug.print("bad command json: {} ({s})\n", .{ err, line });
        return;
    };
    defer parsed.deinit();
    const cmd = parsed.value;

    std.debug.print("got command: id={} cmd={s} bpm={?d}\n", .{ cmd.id, cmd.cmd, cmd.bpm });

    var buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(&buf, "{{\"id\":{},\"ok\":true}}\n", .{cmd.id}) catch return;
    _ = c.send(client_fd, response.ptr, response.len, 0);
}
