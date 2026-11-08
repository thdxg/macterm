//! `macterm proxy` (design/005, step 3): joins its stdin and stdout to the
//! server's socket. The app runs it on a host through ssh. It reads no frame:
//! the app says `hello` to the server through it, so the version check is
//! the handshake itself.

const std = @import("std");
const lib_posix = @import("posix.zig");
const ipc = @import("ipc.zig");
const runtime = @import("runtime.zig");
const socket = @import("socket.zig");
const server = @import("server.zig");

/// A connection to the server. When its socket does not answer, starts the
/// server and connects again.
pub fn connect(gpa: std.mem.Allocator, dir: []const u8) !i32 {
    runtime.ensureDir(dir) catch return error.RuntimeDir;
    const path = try socket.getSocketPath(gpa, dir, server.socket_name);
    defer gpa.free(path);
    if (ipc.connectSession(path)) |fd| return fd else |_| {}
    // A server that exits as idle can go between its start and the
    // connect: try again a few times.
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        server.start(gpa, dir) catch |err| switch (err) {
            error.AlreadyRunning => {},
            else => return err,
        };
        if (ipc.connectSession(path)) |fd| return fd else |err| if (tries >= 3) return err;
    }
}

/// Copies `in` to `sock` and `sock` to `out` until the server closes the
/// connection. At the end of `in`, the server gets the end of the stream,
/// and the proxy waits for it to close.
pub fn pump(sock: i32, in: i32, out: i32) void {
    // Small, as the server's send buffer: what waits here goes before
    // channel 0 (relay.zig).
    var buf: [16 * 1024]u8 = undefined;
    var in_open = true;
    while (true) {
        var fds = [_]lib_posix.pollfd{
            .{ .fd = sock, .events = lib_posix.POLL.IN, .revents = 0 },
            .{ .fd = if (in_open) in else -1, .events = lib_posix.POLL.IN, .revents = 0 },
        };
        _ = lib_posix.poll(&fds, -1) catch return;
        if (fds[0].revents != 0) {
            if (read(sock, &buf)) |n| {
                if (n == 0) return;
                writeAll(out, buf[0..n]) catch return;
            } else |err| if (err == error.Failed) return;
        }
        if (in_open and fds[1].revents != 0) {
            const got: ?usize = read(in, &buf) catch |err| switch (err) {
                error.Again => null,
                error.Failed => 0,
            };
            if (got) |n| {
                if (n == 0) {
                    in_open = false;
                    _ = std.c.shutdown(sock, std.c.SHUT.WR);
                } else writeAll(sock, buf[0..n]) catch return;
            }
        }
    }
}

/// `error.Again` when the descriptor has nothing yet.
fn read(fd: i32, buf: []u8) error{ Again, Failed }!usize {
    return lib_posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => error.Again,
        else => error.Failed,
    };
}

fn writeAll(fd: i32, data: []const u8) !void {
    var rest = data;
    while (rest.len > 0) {
        const n = lib_posix.write(fd, rest) catch |err| switch (err) {
            error.WouldBlock => {
                var pfd = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.OUT, .revents = 0 }};
                _ = try lib_posix.poll(&pfd, -1);
                continue;
            },
            else => return err,
        };
        rest = rest[n..];
    }
}
