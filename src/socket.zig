const std = @import("std");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

// Non-blocking Unix control socket (roadmap §11), proven in
// spikes/spike_socket.zig and spikes/spike_integration.zig: raw libc FFI
// instead of Zig 0.16's std.Io.net (a much bigger, still-settling API tied to
// std.Io.Threaded). Poll once per frame from the main loop -- never blocks.

fn setNonBlocking(fd: c_int) void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

pub const Server = struct {
    listen_fd: c_int,
    client_fd: c_int = -1,
    line_buf: [4096]u8 = undefined,
    line_len: usize = 0,
    path: [:0]const u8,

    pub fn init(path: [:0]const u8) !Server {
        _ = c.unlink(path.ptr);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);

        var addr: c.sockaddr_un = std.mem.zeroes(c.sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..path.len], path);

        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) != 0) return error.BindFailed;
        if (c.listen(fd, 8) != 0) return error.ListenFailed;
        setNonBlocking(fd);

        return .{ .listen_fd = fd, .path = path };
    }

    pub fn deinit(self: *Server) void {
        if (self.client_fd >= 0) _ = c.close(self.client_fd);
        _ = c.close(self.listen_fd);
        _ = c.unlink(self.path.ptr);
    }

    /// Call once per frame. Invokes `handler(ctx, line)` for each complete
    /// newline-delimited command received; `handler` returns the response
    /// bytes to send back (without a trailing newline -- this appends one).
    pub fn poll(self: *Server, comptime Ctx: type, ctx: Ctx, handler: fn (Ctx, []const u8, []u8) []const u8) void {
        if (self.client_fd < 0) {
            const fd = c.accept(self.listen_fd, null, null);
            if (fd >= 0) {
                setNonBlocking(fd);
                self.client_fd = fd;
                self.line_len = 0;
            }
        }
        if (self.client_fd < 0) return;

        var chunk: [1024]u8 = undefined;
        const n = c.recv(self.client_fd, &chunk, chunk.len, 0);
        if (n > 0) {
            const un: usize = @intCast(n);
            for (chunk[0..un]) |byte| {
                if (byte == '\n') {
                    var response_buf: [32768]u8 = undefined;
                    const response = handler(ctx, self.line_buf[0..self.line_len], &response_buf);
                    _ = c.send(self.client_fd, response.ptr, response.len, 0);
                    _ = c.send(self.client_fd, "\n", 1, 0);
                    self.line_len = 0;
                } else if (self.line_len < self.line_buf.len) {
                    self.line_buf[self.line_len] = byte;
                    self.line_len += 1;
                }
            }
        } else if (n == 0) {
            _ = c.close(self.client_fd);
            self.client_fd = -1;
        }
        // n < 0 (EAGAIN/EWOULDBLOCK): nothing available this frame, fine.
    }
};
