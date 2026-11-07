//! The client side of the commands: attach, list, kill, send, history and labels.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ipc = @import("ipc.zig");
const socket = @import("socket.zig");
const Cfg = @import("cfg.zig");
const util = @import("util.zig");
const label = @import("label.zig");
const lib_posix = @import("posix.zig");
const cross = @import("cross");
const signal = @import("signal.zig");
const loop = @import("loop.zig");
const Daemon = loop.Daemon;

pub const HistoryFormat = util.HistoryFormat;
pub const SessionEntry = util.SessionEntry;

pub const AttachOptions = struct {
    command: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    /// Subscribe to foreground reports and write each one to stdout as an
    /// APC sequence (see foreground.zig).
    foreground_events: bool = false,
};

pub const KillOptions = struct {
    force: bool = false,
};

/// Attach the current process's stdin/stdout TTY to a session (creating if needed).
pub fn attach(alloc: Allocator, io: Io, name: []const u8, opts: AttachOptions) !void {
    signal.ignoreSigpipe();
    const cur_sesh = socket.getSeshNameFromEnv();
    if (cur_sesh.len > 0) {
        var cfg = try Cfg.init(alloc, io);
        defer cfg.deinit(alloc);
        const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, cur_sesh);
        defer alloc.free(socket_path);
        const fd = try socket.sessionConnect(socket_path);
        defer lib_posix.close(fd);
        const target_sesh = try socket.getSeshName(alloc, name);
        defer alloc.free(target_sesh);
        ipc.send(fd, .Switch, target_sesh) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => return,
            else => return err,
        };
        return;
    }

    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    {
        var daemon = Daemon.init(io, &cfg, sesh, socket_path);
        daemon.command = opts.command;
        if (opts.cwd) |cwd| daemon.setCwd(cwd);
        if (opts.shell) |sh| daemon.shell = sh;
        const is_daemon_proc = try daemon.ensureSession(io);
        if (is_daemon_proc) std.process.exit(0);
    }

    if (opts.labels) |kvs| {
        try set(alloc, io, sesh, kvs);
    }

    const client_sock = try socket.sessionConnect(socket_path);

    var orig_termios: cross.termios = undefined;
    const stdin_is_tty = cross.tcgetattr(lib_posix.STDIN_FILENO, &orig_termios) == 0;
    const restore_seq = "\x1bc\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\";

    defer {
        if (stdin_is_tty) {
            _ = cross.tcsetattr(lib_posix.STDIN_FILENO, cross.TCSAFLUSH, &orig_termios);
        }
        _ = lib_posix.write(lib_posix.STDOUT_FILENO, restore_seq) catch {};
    }

    if (stdin_is_tty) {
        var raw_termios = orig_termios;
        cross.cfmakeraw(&raw_termios);
        raw_termios.c_cc[cross.VLNEXT] = cross._POSIX_VDISABLE;
        raw_termios.c_cc[cross.VQUIT] = cross._POSIX_VDISABLE;
        raw_termios.c_cc[cross.VMIN] = 1;
        raw_termios.c_cc[cross.VTIME] = 0;
        _ = cross.tcsetattr(lib_posix.STDIN_FILENO, cross.TCSANOW, &raw_termios);
    }

    const clear_seq = "\x1b[0m\x1b[2J\x1b[H";
    _ = try lib_posix.write(lib_posix.STDOUT_FILENO, clear_seq);

    const looper = try loop.clientLoop(client_sock, opts.foreground_events);
    switch (looper.kind) {
        .detach => return,
        .switch_session => {
            if (looper.session_name) |target_name| {
                _ = lib_posix.write(lib_posix.STDOUT_FILENO, restore_seq) catch {};
                var new_opts = opts;
                if (looper.cwd) |new_cwd| new_opts.cwd = new_cwd;
                return attach(alloc, io, target_name, new_opts);
            }
        },
    }
}

/// List all active sessions. Caller owns the returned slice and entries.
pub fn list(alloc: Allocator, io: Io) ![]SessionEntry {
    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    var sessions = try util.get_session_entries(alloc, io, cfg.socket_dir);
    return sessions.toOwnedSlice(alloc);
}

pub const KillStatus = enum {
    killed,
    cleaned_stale,
};

/// Kill a session and wait for its socket to close.
pub fn kill(alloc: Allocator, io: Io, name: []const u8, opts: KillOptions) !KillStatus {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, sesh);
    if (!exists) return error.SessionNotFound;

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (opts.force or err == error.ConnectionRefused) {
            socket.cleanupStaleSocket(io, dir, sesh);
            return .cleaned_stale;
        }
        return error.SessionUnresponsive;
    };
    defer lib_posix.close(fd);

    ipc.send(fd, .Kill, "") catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return .killed,
        else => return err,
    };

    var drain: [256]u8 = undefined;
    while (true) {
        const n = lib_posix.read(fd, &drain) catch break;
        if (n == 0) break;
    }
    return .killed;
}

/// Send raw input bytes to a session's PTY (fire-and-forget, like `zmx send`).
pub fn send(alloc: Allocator, io: Io, name: []const u8, bytes: []const u8) !void {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const probe_result = ipc.probeSession(alloc, socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, sesh);
        return error.SessionUnresponsive;
    };
    defer probe_result.deinit();

    ipc.send(probe_result.fd, .Send, bytes) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => return err,
    };
}

/// Fetch session scrollback with optional row count.
pub fn historyRange(alloc: Allocator, io: Io, name: []const u8, format: HistoryFormat, scrollback_rows: ?u32) ![]u8 {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);

    const exists = try socket.sessionExists(io, dir, sesh);
    if (!exists) return error.SessionNotFound;

    const fd = ipc.connectSession(socket_path) catch |err| {
        if (err == error.ConnectionRefused) socket.cleanupStaleSocket(io, dir, sesh);
        return error.SessionUnresponsive;
    };
    defer lib_posix.close(fd);

    const reply_tag: ipc.Tag = if (scrollback_rows != null) .Capture else .History;
    if (scrollback_rows) |rows| {
        var request = std.mem.zeroes(ipc.Capture);
        request.format = @backingInt(format);
        request.rows = rows;
        try ipc.send(fd, .Capture, std.mem.asBytes(&request));
        try ipc.send(fd, .Info, "");
    } else {
        const format_byte = [_]u8{@backingInt(format)};
        try ipc.send(fd, .History, &format_byte);
    }

    var sb = try ipc.SocketBuffer.init(alloc);
    defer sb.deinit();

    while (true) {
        var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        const poll_result = lib_posix.poll(&poll_fds, 5000) catch return error.Timeout;
        if (poll_result == 0) return error.Timeout;

        const n = sb.read(fd) catch return error.ReadFailed;
        if (n == 0) return error.ConnectionClosed;

        while (sb.next()) |msg| {
            if (msg.header.tag == reply_tag) {
                return alloc.dupe(u8, msg.payload);
            }
            if (scrollback_rows != null and msg.header.tag == .Info) {
                return error.CaptureNotSupported;
            }
        }
    }
}

/// Get session labels (all `k=v` pairs if `key == null`, or single value). Caller owns slice.
pub fn get(alloc: Allocator, io: Io, name: []const u8, key: ?[]const u8) ![]u8 {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    const payload = try ipc.roundTripForTag(alloc, socket_path, .LabelGet, "", .LabelData);
    errdefer alloc.free(payload);

    if (key == null) return payload;

    const val = try label.getLabelValueFromPairs(key.?, payload);
    const result = try alloc.dupe(u8, val);
    alloc.free(payload);
    return result;
}

/// Set or unset (`k=`) space-separated session labels.
pub fn set(alloc: Allocator, io: Io, name: []const u8, kvs: []const u8) !void {
    signal.ignoreSigpipe();
    var it = label.LabelIterator.init(kvs);
    while (it.next()) |kv| {
        try label.assertLabel(kv.key, kv.value);
    }

    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    _ = try ipc.roundTripForTag(alloc, socket_path, .LabelSet, kvs, .Ack);
}

/// Clear all labels on a session.
pub fn clear(alloc: Allocator, io: Io, name: []const u8) !void {
    signal.ignoreSigpipe();
    const sesh = try socket.getSeshName(alloc, name);
    defer alloc.free(sesh);

    var cfg = try Cfg.init(alloc, io);
    defer cfg.deinit(alloc);

    const socket_path = try socket.getSocketPath(alloc, cfg.socket_dir, sesh);
    defer alloc.free(socket_path);

    _ = try ipc.roundTripForTag(alloc, socket_path, .LabelClear, "", .Ack);
}
