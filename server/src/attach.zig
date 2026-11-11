//! The attach client of a v2 session (`zmx connect`, later `macterm attach`;
//! design/007 §6). It joins the terminal on its stdin and stdout to one
//! session socket in the runtime directory (`runtime.zig`): keys go in as
//! `bytes` on the pane channel, output comes back the same way.
//!
//! A libghostty surface runs it as its command, as it runs `zmx attach` for
//! v1. Until the GUI feeds a surface from a channel itself (m3), v1's claim
//! APC on stdin becomes the `claim` message (design/004 §5), and with
//! `ZMX_FOREGROUND_EVENTS` in its environment the session's `foreground`
//! message becomes v1's foreground APC on stdout (`foregroundApc`), so the
//! app's `ZmxForegroundEvents` reads it as before. Ctrl-\ detaches, as in
//! v1. When no session has the name and a command is given, it asks the
//! server to make one (starting the server when nothing answers), with this
//! process's folder, environment and terminal size, as `zmx attach` makes a
//! missing session in v1.

const std = @import("std");
const cross = @import("cross");
const build_options = @import("build_options");
const ipc = @import("ipc.zig");
const util = @import("util.zig");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const socket = @import("socket.zig");
const runtime = @import("runtime.zig");
const session = @import("session.zig");
const server = @import("server.zig");
const foreground = @import("foreground.zig");
const protocol = @import("protocol/protocol.zig");
const frame = protocol.frame;
const msgpack = protocol.msgpack;
const m = protocol.messages;

pub const protocol_level = m.level;

/// How often, and how long between tries, a client connects again after a
/// lost link before it gives up.
const reconnect_tries = 5;
const reconnect_wait_ms = 100;

/// What the first attach writes before the session's snapshot: it clears the
/// screen and puts the cursor home.
const reset_screen = "\x1b[0m\x1b[2J\x1b[H";

/// How long the session may take to answer the handshake.
const handshake_timeout_ms = 5000;

/// How long the server may take to answer `session.create`: its own limit
/// for a session to start, and the handshake.
const create_timeout_ms = server.spawn_ms + handshake_timeout_ms;

/// What `run` makes when no session has the name.
pub const Create = struct {
    /// The session's command (argv). Null: the session's login shell.
    command: ?[]const []const u8 = null,
};

pub const Outcome = union(enum) {
    /// The user pressed Ctrl-\.
    detached,
    /// The shell exited.
    exited: session.ExitStatus,
    /// The session closed the connection with no exit status: it crashed or
    /// was killed.
    closed,
    /// The session speaks a level under ours: `min_level` is what we need.
    session_too_old: struct { level: u32, min_level: u32 },
    /// The session refused our level.
    refused: m.Refuse,
    /// The server did not make the session: its message.
    not_created: []const u8,
};

pub const Error = error{
    InvalidName,
    /// The runtime directory failed `runtime.checkDir`.
    RuntimeDir,
    NoSession,
    /// The socket's peer is another user.
    WrongPeer,
    /// The session did not finish the handshake in time.
    NoAnswer,
    /// The session broke the protocol, or the connection failed.
    Protocol,
};

/// The exit code of the process for an outcome: the shell's code, or 128
/// plus the signal, as a shell reports it.
pub fn exitCode(outcome: Outcome) u8 {
    return switch (outcome) {
        .detached => 0,
        .closed => 1,
        .exited => |s| if (s.code) |c| c else 128 +| (s.signal orelse 0),
        .session_too_old, .refused, .not_created => 1,
    };
}

/// Attaches to session `name`. With `create`, a missing session is made
/// first through the server.
pub fn run(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, create: ?Create) (Error || error{ OutOfMemory, Sighup, Sigint, Sigterm })!Outcome {
    if (!session.validName(name)) return error.InvalidName;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{dir}, 0) catch return error.RuntimeDir;
    var have_dir = true;
    runtime.checkDir(dir_z, std.c.getuid()) catch |err| switch (err) {
        // No session has made it yet. The server makes it.
        error.Unreadable => have_dir = false,
        else => return error.RuntimeDir,
    };
    const path = socket.getSocketPath(gpa, dir, name) catch return error.InvalidName;
    defer gpa.free(path);

    signal.ignoreSigpipe();
    // With `create`, the server is asked first, also when a socket answers:
    // it knows when that session's shell already exited.
    if (create) |spec| {
        if (try createSession(gpa, dir, name, spec)) |outcome| return outcome;
    } else if (!have_dir) return error.NoSession;
    const fd = ipc.connectSession(path) catch return error.NoSession;
    var c: Client = .{ .gpa = gpa, .fd = fd, .path = path, .foreground_events = lib_posix.getenv(foreground.env_var) != null };
    // `reconnect` changes the fd.
    defer lib_posix.close(c.fd);
    if (!runtime.allowPeer(runtime.peerUid(fd), std.c.getuid())) return error.WrongPeer;

    defer c.in.deinit(gpa);
    if (try c.handshake()) |outcome| return outcome;
    return c.loop();
}

/// Asks the server to make session `name`, or to give the one that runs,
/// and starts the server when its socket does not answer. Null when the
/// session listens; an outcome when the server or its level refused.
///
/// A connection that ends before the reply is a server that exits (a newer
/// app replaced it, or it was idle): one more try starts or finds the next.
fn createSession(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, spec: Create) (Error || error{OutOfMemory})!?Outcome {
    if (createOnce(gpa, dir, name, spec)) |outcome| {
        return outcome;
    } else |err| {
        if (err != error.NoAnswer) return err;
    }
    return createOnce(gpa, dir, name, spec);
}

fn createOnce(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, spec: Create) (Error || error{OutOfMemory})!?Outcome {
    const server_path = socket.getSocketPath(gpa, dir, server.socket_name) catch return error.RuntimeDir;
    defer gpa.free(server_path);
    const fd = ipc.connectSession(server_path) catch fd: {
        server.start(gpa, dir) catch |err| switch (err) {
            error.AlreadyRunning => {},
            error.RuntimeDir => return error.RuntimeDir,
            else => return .{ .not_created = "the server did not start" },
        };
        break :fd ipc.connectSession(server_path) catch return error.NoAnswer;
    };
    defer lib_posix.close(fd);
    if (!runtime.allowPeer(runtime.peerUid(fd), std.c.getuid())) return error.WrongPeer;

    var c: Client = .{ .gpa = gpa, .fd = fd };
    defer c.in.deinit(gpa);
    const mine = helloMessage();
    try c.sendControl(mine);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.ArrayList(msgpack.Bin) = .empty;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) try env.append(arena, .{ .bytes = std.mem.span(entry) });
    var command: ?[]const msgpack.Bin = null;
    if (spec.command) |argv| {
        const list = try arena.alloc(msgpack.Bin, argv.len);
        for (argv, list) |arg, *bin| bin.* = .{ .bytes = arg };
        command = list;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd: ?msgpack.Bin = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |p| .{ .bytes = std.mem.sliceTo(@as([*:0]u8, @ptrCast(p)), 0) } else null;
    const size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
    const args: m.SessionCreate.Args = .{
        .id = name,
        .cwd = cwd,
        .command = command,
        .cols = size.cols,
        .rows = size.rows,
        .env = env.items,
    };
    // 1: the create. 2: the kill of an exited session. 3: the create again.
    var request_id: u64 = 1;

    var greeted = false;
    while (true) {
        const f = try c.nextFrame(create_timeout_ms) orelse return error.NoAnswer;
        if (f.channel != frame.control_channel) continue;
        switch (m.decodeControl(arena, f.body) catch return error.Protocol) {
            .hello => |theirs| {
                if (greeted) return error.Protocol;
                greeted = true;
                switch (m.negotiate(mine, theirs)) {
                    .refuse => |r| {
                        c.sendControl(r) catch {};
                        return .{ .session_too_old = .{ .level = theirs.level, .min_level = r.needs_level } };
                    },
                    .speak => {},
                }
                try sendRequest(&c, arena, request_id, m.SessionCreate, args);
            },
            .refuse => |r| return .{ .refused = .{
                .reason = try gpa.dupe(u8, r.reason),
                .needs_level = r.needs_level,
            } },
            .response => |res| {
                if (res.re != request_id) continue;
                switch (request_id) {
                    1 => {
                        const err = res.err orelse return null;
                        if (!std.mem.eql(u8, err.code, "exited"))
                            return .{ .not_created = try gpa.dupe(u8, err.message) };
                        // The shell of a session of this name exited (while
                        // no app was there to end it): end it, and make a
                        // new one, as v1's `zmx attach` made a new session.
                        request_id = 2;
                        try sendRequest(&c, arena, request_id, m.SessionKill, .{ .id = name });
                    },
                    2 => {
                        request_id = 3;
                        try sendRequest(&c, arena, request_id, m.SessionCreate, args);
                    },
                    else => {
                        const err = res.err orelse return null;
                        return .{ .not_created = try gpa.dupe(u8, err.message) };
                    },
                }
            },
            else => {},
        }
    }
}

fn sendRequest(c: *Client, arena: std.mem.Allocator, id: u64, comptime M: type, args: M.Args) (Error || error{OutOfMemory})!void {
    var out: std.Io.Writer.Allocating = .init(arena);
    m.encodeRequest(&out.writer, id, M, args) catch return error.OutOfMemory;
    try c.sendFrame(frame.control_channel, .msg, out.written());
}

fn helloMessage() m.Hello {
    return .{
        .level = m.level,
        .min_level = m.min_level,
        .build = build_options.version,
        // The pane's client acts for the GUI. Not `cli`: a session of an
        // older build must still attach.
        .role = .gui,
        .epoch = 0,
        .caps = &.{},
    };
}

const Client = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    in: std.ArrayList(u8) = .empty,
    /// The bytes at the start of `in` that `nextFrame` returned last.
    consumed: usize = 0,
    /// Write the session's foreground as v1's APC (interim, until m3).
    foreground_events: bool = false,
    /// The session's socket, to connect again after a lost link.
    path: []const u8 = "",
    /// The `epoch` of the session's `hello`.
    epoch: u64 = 0,
    /// The offset after the last output byte that the terminal got
    /// (design/003 §7). 0 at the start: a session with no output sends no
    /// snapshot, and its first byte is at 0. Null when it is not known: a
    /// session of level 1 sent a snapshot with no offset.
    offset: ?u64 = 0,
    /// The frames are a snapshot's: they are not output.
    in_snapshot: bool = false,
    /// The link was lost and made again: a snapshot that comes shows the
    /// whole pane, over a screen that holds the old one.
    reconnected: bool = false,

    /// Hello in each direction, then the session's `state`. Null when the
    /// pane may start; an outcome when the two levels refuse each other.
    fn handshake(c: *Client) (Error || error{OutOfMemory})!?Outcome {
        const mine = helloMessage();
        try c.sendControl(mine);

        var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var greeted = false;
        while (true) {
            const f = try c.nextFrame(handshake_timeout_ms) orelse return error.NoAnswer;
            if (f.channel == frame.control_channel) {
                const msg = m.decodeControl(arena, f.body) catch return error.Protocol;
                switch (msg) {
                    .hello => |theirs| {
                        if (greeted) return error.Protocol;
                        greeted = true;
                        c.epoch = theirs.epoch;
                        switch (m.negotiate(mine, theirs)) {
                            .refuse => |r| {
                                c.sendControl(r) catch {};
                                return .{ .session_too_old = .{ .level = theirs.level, .min_level = r.needs_level } };
                            },
                            .speak => {},
                        }
                    },
                    .refuse => |r| return .{ .refused = .{
                        .reason = try c.gpa.dupe(u8, r.reason),
                        .needs_level = r.needs_level,
                    } },
                    else => {},
                }
            } else if (greeted and f.channel == m.pane_channel and f.kind == .msg) {
                const msg = msgpack.decodeSlice(m.PaneMessage, arena, f.body) catch return error.Protocol;
                if (std.mem.eql(u8, msg.t, m.State.name)) return null;
            }
        }
    }

    fn loop(c: *Client) (Error || error{ OutOfMemory, Sighup, Sigint, Sigterm })!Outcome {
        const stdin = lib_posix.STDIN_FILENO;
        const stdout = lib_posix.STDOUT_FILENO;

        signal.openSignalPipe() catch return error.Protocol;
        defer signal.closeSignalPipe();
        signal.installWakeHandler(@backingInt(lib_posix.SIG.WINCH));
        signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
        signal.installWakeHandler(@backingInt(lib_posix.SIG.HUP));
        signal.installWakeHandler(@backingInt(lib_posix.SIG.INT));

        var orig: cross.termios = undefined;
        const is_tty = cross.tcgetattr(stdin, &orig) == 0;
        if (is_tty) {
            var raw = orig;
            cross.cfmakeraw(&raw);
            raw.c_cc[cross.VLNEXT] = cross._POSIX_VDISABLE;
            raw.c_cc[cross.VQUIT] = cross._POSIX_VDISABLE;
            raw.c_cc[cross.VMIN] = 1;
            raw.c_cc[cross.VTIME] = 0;
            _ = cross.tcsetattr(stdin, cross.TCSANOW, &raw);
        }
        defer {
            if (is_tty) _ = cross.tcsetattr(stdin, cross.TCSAFLUSH, &orig);
            // Reset the terminal and its colors, as v1's attach does.
            writeAll(stdout, "\x1bc\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\") catch {};
        }
        writeAll(stdout, "\x1b[0m\x1b[2J\x1b[H") catch {};

        try c.sendAttach(stdout);

        const detach_disabled = util.isDetachKeyDisabled();
        var claims: util.ClaimFilter = .{};
        // The handshake may have read more than it used: an exit, at least.
        if (try c.drain(stdout)) |outcome| return outcome;

        while (true) {
            var fds = [_]lib_posix.pollfd{
                .{ .fd = stdin, .events = lib_posix.POLL.IN, .revents = 0 },
                .{ .fd = c.fd, .events = lib_posix.POLL.IN, .revents = 0 },
                .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 },
            };
            _ = lib_posix.poll(&fds, -1) catch return error.Protocol;

            if (fds[2].revents & lib_posix.POLL.IN != 0) {
                try signal.drainSignalPipe();
                try c.sendPane(m.Resize, resizeOf(ipc.getTerminalSize(stdout)));
            }

            if (fds[0].revents & (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR) != 0) {
                var buf: [4096]u8 = undefined;
                const n = lib_posix.read(stdin, &buf) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return .detached,
                };
                if (n == 0) return .detached;
                const data = buf[0..n];
                if (!detach_disabled and util.isCtrlBackslash(data)) return .detached;
                const filtered = claims.feed(data);
                for (0..filtered.claims) |_| try c.sendPane(m.Claim, .{});
                if (filtered.forward.len > 0) try c.sendFrame(m.pane_channel, .bytes, filtered.forward);
            }

            if (fds[1].revents & (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR) != 0) {
                if (!try c.fill()) {
                    // The link is lost, with no exit: try to resume.
                    if (!try c.reconnect(stdout)) return .closed;
                }
                if (try c.drain(stdout)) |outcome| return outcome;
            }
        }
    }

    /// Handles every whole frame in `in`. An outcome ends the pane.
    fn drain(c: *Client, stdout: i32) (Error || error{OutOfMemory})!?Outcome {
        // Only what `fill` read: a socket that is always full must not keep
        // the loop from stdin.
        while (try c.bufferedFrame()) |f| {
            if (f.channel != m.pane_channel) continue;
            switch (f.kind) {
                // The terminal is gone: nothing can show the pane.
                .bytes => {
                    if (!c.in_snapshot) if (c.offset) |o| {
                        c.offset = o + f.body.len;
                    };
                    writeAll(stdout, f.body) catch return .detached;
                },
                .msg => {
                    var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
                    defer arena_state.deinit();
                    const arena = arena_state.allocator();
                    const msg = msgpack.decodeSlice(m.PaneMessage, arena, f.body) catch return error.Protocol;
                    if (std.mem.eql(u8, msg.t, m.Lead.name)) {
                        const lead = m.decodePane(m.Lead, arena, msg) catch return error.Protocol;
                        // A client that starts to lead sends its size.
                        if (lead.leader) try c.sendPane(m.Resize, resizeOf(ipc.getTerminalSize(stdout)));
                    } else if (c.foreground_events and std.mem.eql(u8, msg.t, m.Foreground.name)) {
                        const fg = m.decodePane(m.Foreground, arena, msg) catch return error.Protocol;
                        var buf: [apc_max]u8 = undefined;
                        // In the output stream, so it lands in front of the
                        // output that the session sent after it.
                        writeAll(stdout, foregroundApc(&buf, fg)) catch return .detached;
                    } else if (std.mem.eql(u8, msg.t, m.SnapshotStart.name)) {
                        const start = m.decodePane(m.SnapshotStart, arena, msg) catch return error.Protocol;
                        c.in_snapshot = true;
                        c.offset = start.offset;
                        if (c.reconnected) {
                            // The session could not resume: draw the pane
                            // again, as the first attach does.
                            c.reconnected = false;
                            writeAll(stdout, reset_screen) catch return .detached;
                        }
                        // Around the snapshot, so the app can tell the
                        // replay from new output: a title in the replay is
                        // old, and nothing says who set it.
                        if (c.foreground_events) writeAll(stdout, snapshot_start_apc) catch return .detached;
                    } else if (std.mem.eql(u8, msg.t, m.SnapshotEnd.name)) {
                        c.in_snapshot = false;
                        if (c.foreground_events) writeAll(stdout, snapshot_end_apc) catch return .detached;
                    } else if (std.mem.eql(u8, msg.t, m.Resumed.name)) {
                        // The bytes after our offset follow, and nothing is
                        // drawn again.
                        const r = m.decodePane(m.Resumed, arena, msg) catch return error.Protocol;
                        c.offset = r.offset;
                        c.reconnected = false;
                    } else if (std.mem.eql(u8, msg.t, m.Exit.name)) {
                        const e = m.decodePane(m.Exit, arena, msg) catch return error.Protocol;
                        // The server takes the status (`take`), not the pane.
                        return .{ .exited = .{ .code = e.code, .signal = e.signal } };
                    }
                },
                _ => {},
            }
        }
        return null;
    }

    /// Sends `attach`: with the offset that the terminal has, when the
    /// session may still hold the bytes after it.
    fn sendAttach(c: *Client, stdout: i32) (Error || error{OutOfMemory})!void {
        var a = attachMessage(ipc.getTerminalSize(stdout), c.foreground_events);
        if (c.reconnected) if (c.offset) |o| {
            a.resume_epoch = c.epoch;
            a.resume_offset = o;
        };
        try c.sendPane(m.Attach, a);
    }

    /// The link to the session ended with no exit. Connects again a few
    /// times, and attaches asking to resume from the offset that the
    /// terminal has (design/003 §7). False when the session does not answer:
    /// it ended, or crashed.
    fn reconnect(c: *Client, stdout: i32) (Error || error{OutOfMemory})!bool {
        var tries: u32 = 0;
        const fd = while (true) : (tries += 1) {
            if (ipc.connectSession(c.path)) |fd| break fd else |_| {}
            if (tries >= reconnect_tries) return false;
            var ts: std.c.timespec = .{ .sec = 0, .nsec = reconnect_wait_ms * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        };
        lib_posix.close(c.fd);
        c.fd = fd;
        c.in.clearRetainingCapacity();
        c.consumed = 0;
        c.in_snapshot = false;
        const before = c.epoch;
        const hs = c.handshake() catch return false;
        if (hs != null) return false;
        // A session that is not the one that we left has other offsets.
        if (c.epoch != before) c.offset = null;
        c.reconnected = true;
        try c.sendAttach(stdout);
        return true;
    }

    /// Reads what the socket has. False at the end of the stream.
    fn fill(c: *Client) (Error || error{OutOfMemory})!bool {
        var buf: [64 * 1024]u8 = undefined;
        const n = lib_posix.read(c.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return true,
            else => return false,
        };
        if (n == 0) return false;
        try c.in.appendSlice(c.gpa, buf[0..n]);
        return true;
    }

    /// The next whole frame in `in`, or null. The body stays valid until
    /// the next call.
    fn bufferedFrame(c: *Client) Error!?frame.Frame {
        c.consume();
        const p = (frame.parse(c.in.items) catch return error.Protocol) orelse return null;
        c.consumed = p.len;
        return p.frame;
    }

    /// The next whole frame, waiting at most `timeout_ms` for it. Null on a
    /// timeout or at the end of the stream. The body stays valid until the
    /// next call.
    fn nextFrame(c: *Client, timeout_ms: i32) (Error || error{OutOfMemory})!?frame.Frame {
        while (true) {
            if (try c.bufferedFrame()) |f| return f;
            var fds = [_]lib_posix.pollfd{.{ .fd = c.fd, .events = lib_posix.POLL.IN, .revents = 0 }};
            const ready = lib_posix.poll(&fds, timeout_ms) catch return error.Protocol;
            if (ready == 0) return null;
            if (!try c.fill()) return null;
        }
    }

    fn consume(c: *Client) void {
        c.in.replaceRangeAssumeCapacity(0, c.consumed, &.{});
        c.consumed = 0;
    }

    fn sendFrame(c: *Client, channel: u32, kind: frame.Kind, body: []const u8) (Error || error{OutOfMemory})!void {
        var header: [frame.header_len]u8 = undefined;
        frame.writeHeader(&header, channel, kind, body.len) catch return error.Protocol;
        writeAll(c.fd, &header) catch return error.Protocol;
        writeAll(c.fd, body) catch return error.Protocol;
    }

    fn sendControl(c: *Client, value: anytype) (Error || error{OutOfMemory})!void {
        const body = try msgpack.encodeAlloc(c.gpa, value);
        defer c.gpa.free(body);
        try c.sendFrame(frame.control_channel, .msg, body);
    }

    fn sendPane(c: *Client, comptime M: type, value: M) (Error || error{OutOfMemory})!void {
        var out: std.Io.Writer.Allocating = .init(c.gpa);
        defer out.deinit();
        m.encodePane(&out.writer, M, value) catch return error.OutOfMemory;
        try c.sendFrame(m.pane_channel, .msg, out.written());
    }
};

/// The APCs that a client with `ZMX_FOREGROUND_EVENTS` writes at the start
/// and the end of a snapshot (`ZmxForegroundEvents.snapshotStart` and
/// `snapshotEnd` in the app).
pub const snapshot_start_apc = "\x1b_zmx;snapshot;start\x1b\\";
pub const snapshot_end_apc = "\x1b_zmx;snapshot;end\x1b\\";

/// A buffer this long holds any APC that `foregroundApc` writes.
pub const apc_max = foreground.report_max + 4;

/// v1's foreground report as an APC, `ESC _ zmx;foreground;… ESC \`
/// (foreground.zig), from the session's `foreground` message.
pub fn foregroundApc(buf: []u8, f: m.Foreground) []const u8 {
    std.debug.assert(buf.len >= apc_max);
    buf[0..2].* = "\x1b_".*;
    const report = foreground.write(buf[2..], .{
        .idle = f.idle,
        .shell = f.shell,
        .comm = f.comm.bytes,
        .args = f.args.bytes,
    });
    buf[2 + report.len ..][0..2].* = "\x1b\\".*;
    return buf[0 .. report.len + 4];
}

/// The APCs that the app's tests parse with `ZmxForegroundEvents.parse`
/// (`server/schema/foreground.json`, `__schema foreground`): each case's
/// message, and the APC that this client writes for it, in hex.
pub fn writeForegroundFixtures(w: *std.Io.Writer) !void {
    const cases = [_]struct { name: []const u8, msg: m.Foreground }{
        .{ .name = "program", .msg = .{ .idle = false, .shell = false, .comm = .{ .bytes = "/usr/bin/hx" }, .args = .{ .bytes = "hx a;b.md" } } },
        .{ .name = "idle shell", .msg = .{ .idle = true, .shell = true, .comm = .{ .bytes = "-zsh" }, .args = .{ .bytes = "" } } },
        .{ .name = "no /etc/shells", .msg = .{ .idle = false, .shell = null, .comm = .{ .bytes = "claude" }, .args = .{ .bytes = "claude --resume" } } },
        .{ .name = "control bytes", .msg = .{ .idle = false, .shell = false, .comm = .{ .bytes = "ev;il\x1b" }, .args = .{ .bytes = "printf '\x1b\\'" } } },
    };
    try w.writeAll("[\n");
    for (cases, 0..) |case, i| {
        var buf: [apc_max]u8 = undefined;
        const apc = foregroundApc(&buf, case.msg);
        try w.print("  {{\"name\": \"{s}\", \"apc\": \"{x}\"}}{s}\n", .{ case.name, apc, if (i + 1 < cases.len) "," else "" });
    }
    try w.writeAll("]\n");
}

fn attachMessage(size: ipc.Resize, foreground_events: bool) m.Attach {
    return .{ .cols = size.cols, .rows = size.rows, .xpixel = size.xpixel, .ypixel = size.ypixel, .foreground = foreground_events };
}

fn resizeOf(size: ipc.Resize) m.Resize {
    return .{ .cols = size.cols, .rows = size.rows, .xpixel = size.xpixel, .ypixel = size.ypixel };
}

/// Writes all of `bytes`, and waits when the fd is full.
fn writeAll(fd: i32, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = lib_posix.write(fd, rest) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.OUT, .revents = 0 }};
                _ = try lib_posix.poll(&fds, -1);
                continue;
            },
            else => return err,
        };
        rest = rest[n..];
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the foreground APC is v1's report between ESC _ and ESC \\" {
    var buf: [apc_max]u8 = undefined;
    const apc = foregroundApc(&buf, .{ .idle = false, .shell = null, .comm = .{ .bytes = "/usr/bin/hx" }, .args = .{ .bytes = "hx a;b" } });
    try testing.expectEqualStrings("\x1b_zmx;foreground;0;;/usr/bin/hx;hx a;b\x1b\\", apc);
}

test "the exit code is the shell's, or 128 plus its signal" {
    try testing.expectEqual(0, exitCode(.detached));
    try testing.expectEqual(1, exitCode(.closed));
    try testing.expectEqual(3, exitCode(.{ .exited = .{ .code = 3 } }));
    try testing.expectEqual(137, exitCode(.{ .exited = .{ .signal = 9 } }));
    try testing.expectEqual(1, exitCode(.{ .refused = .{ .reason = "level_too_low", .needs_level = 9 } }));
}
