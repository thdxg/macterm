//! The v2 session process (design/001, design/003 §1 and §4, design/006 §1).
//!
//! One process for each pane. It is the shell's parent, reads the pty all
//! the time, and parses every byte into its terminal. Clients connect to its
//! socket in the runtime directory (`runtime.zig`) and speak frames: `hello`
//! on channel 0, then the pane on channel 1 (`bytes` in and out, and the
//! messages in `messages.zig`, "A session's pane channel").
//!
//! It runs beside v1's daemon (`loop.zig`): the same binary, another socket,
//! and no v1 IPC.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cross = @import("cross");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const util = @import("util.zig");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const socket = @import("socket.zig");
const daemonize = @import("daemonize.zig");
const runtime = @import("runtime.zig");
const terminal = @import("terminal.zig");
const events = @import("events.zig");
const foreground = @import("foreground.zig");
const protocol = @import("protocol/protocol.zig");
const ghostty_vt = terminal.ghostty_vt;
const frame = protocol.frame;
const msgpack = protocol.msgpack;
const ring = @import("ring.zig");
const m = protocol.messages;

/// The subcommand that the macOS session runs after its disclaiming re-exec.
pub const reexec_command = "__session";

/// The most output that waits for one client. Over it, the session drops
/// that client's queue and sends it a snapshot of the screen when the client
/// can take data again (design/001, Back-pressure). A starting value: issue
/// 0036's benchmark sets it.
pub const client_cap = 1024 * 1024;

/// The most that may wait for one client in all, messages and snapshots
/// included. Over it, the client is closed: it asks for more than it reads.
pub const client_hard_cap = 64 * 1024 * 1024;

/// The largest frame that a client may send. Input over `pty_in_max` is
/// dropped anyway, and no message needs more.
pub const client_frame_max = 1024 * 1024;

/// The most clients at one time. A connection over it is closed.
pub const max_clients = 64;

/// The largest pane size that a client may ask for, in cells. A larger one
/// is cut to it; a size of 0 is ignored.
pub const max_cells = 1000;

/// A snapshot goes out in `bytes` frames of at most this size.
const snapshot_chunk = 64 * 1024;

pub const Options = struct {
    name: []const u8,
    /// The command in place of a login shell.
    command: ?[]const []const u8 = null,
    shell: []const u8 = "/bin/sh",
    size: ipc.Resize = .{ .cols = 80, .rows = 24 },
    max_scrollback_lines: usize = 10_000,
};

/// A session name names a file in the runtime directory, so it may not hold
/// a slash or start with a dot (the directory's own files start with one).
/// It may not start with `-` either.
pub fn validName(name: []const u8) bool {
    // Not `-` first: the name is an argument of `session`, not an option.
    if (name.len == 0 or name[0] == '.' or name[0] == '-') return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

pub const StartError = error{
    InvalidName,
    NameTooLong,
    SessionExists,
    RuntimeDir,
};

/// The `session` command: checks the runtime directory, binds the socket,
/// and starts the session process. Returns in the caller once the socket
/// accepts connections; the session process itself never returns from here.
pub fn start(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, opts: Options) !void {
    if (!validName(opts.name)) return error.InvalidName;
    runtime.ensureDir(dir) catch return error.RuntimeDir;
    const path = try socket.getSocketPath(gpa, dir, opts.name);
    defer gpa.free(path);

    // From the check to the bind, so that two starts of one name cannot both
    // find the socket stale. The lock goes with the fd when the caller exits.
    const lock_fd = try lockDir(dir);
    defer lib_posix.close(lock_fd);

    if (ipc.connectSession(path)) |fd| {
        lib_posix.close(fd);
        return error.SessionExists;
    } else |err| switch (err) {
        // Nothing listens: a session that crashed left its socket.
        error.ConnectionRefused => {
            var dir_handle = try std.Io.Dir.openDirAbsolute(io, dir, .{});
            defer dir_handle.close(io);
            socket.cleanupStaleSocket(io, dir_handle, opts.name);
        },
        error.Unexpected => {},
    }

    const listen_fd = try bindSocket(path);
    const log_fd = if (log.log_system.file) |f| f.handle else -1;
    var keep = [_]i32{ listen_fd, log_fd };
    const cmd = try daemonize.createCmdZ(opts.shell, opts.command);

    const reexec: ?daemonize.Reexec = if (builtin.os.tag.isDarwin()) .{
        .session_name = opts.name,
        .shell = opts.shell,
        .command = opts.command,
        .cwd = "",
        .server_sock_fd = listen_fd,
        .subcommand = reexec_command,
    } else null;

    const pty = daemonize.daemonize(opts.name, cmd, &keep, reexec, .{
        .session_var = runtime.session_env,
        .size = opts.size,
    }) catch |err| {
        lib_posix.close(listen_fd);
        if (err == error.IsClientProc) return;
        _ = std.c.unlink(@ptrCast((try gpa.dupeSentinel(u8, path, 0)).ptr));
        return err;
    };
    // The forked session on Linux, or on macOS when the re-exec failed.
    serveAndExit(dir, opts, listen_fd, pty);
}

/// The `__session` entry on macOS, after the disclaiming re-exec.
pub fn resumeAfterReexec(dir: []const u8, opts: Options, listen_fd: i32) noreturn {
    // `daemonize.takeReexecState` already set CLOEXEC on `listen_fd` again.
    const cmd = daemonize.createCmdZ(opts.shell, opts.command) catch std.process.exit(1);
    const pty = daemonize.spawnPty(opts.name, cmd, opts.size, runtime.session_env) catch |err| {
        std.log.err("session {s}: pty failed: {s}", .{ opts.name, @errorName(err) });
        unlinkSocket(dir, opts.name);
        std.process.exit(1);
    };
    serveAndExit(dir, opts, listen_fd, pty);
}

pub fn lockDir(dir: []const u8) !i32 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/.lock", .{dir}, 0);
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.LockFailed;
    if (std.c.flock(fd, std.c.LOCK.EX) != 0) {
        lib_posix.close(fd);
        return error.LockFailed;
    }
    return fd;
}

pub fn bindSocket(path: []const u8) !i32 {
    // The socket file is 0600 from the moment it exists.
    const old_mask = std.c.umask(0o177);
    defer _ = std.c.umask(old_mask);
    return socket.createSocket(path);
}

pub fn unlinkSocket(dir: []const u8, name: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch return;
    _ = std.c.unlink(path.ptr);
}

fn serveAndExit(dir: []const u8, opts: Options, listen_fd: i32, pty: daemonize.PtyInfo) noreturn {
    // After a fork: no allocator or io of the parent (see `Daemon.run`).
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const gpa = std.heap.c_allocator;

    openLog(io, dir, opts.name);

    var session = Session.init(gpa, io, opts, listen_fd, pty) catch |err| {
        std.log.err("session {s}: start failed: {s}", .{ opts.name, @errorName(err) });
        unlinkSocket(dir, opts.name);
        std.process.exit(1);
    };
    session.run() catch |err| std.log.err("session {s}: loop failed: {s}", .{ opts.name, @errorName(err) });
    // Close and unlink first, so that a new session of this name can start
    // while the shell's process group gets its grace time.
    lib_posix.close(listen_fd);
    unlinkSocket(dir, opts.name);
    session.end();
    std.log.info("session {s} ended", .{opts.name});
    std.process.exit(0);
}

/// `<dir>/log/<name>.log`. A failure leaves the session with no log.
pub fn openLog(io: std.Io, dir: []const u8, name: []const u8) void {
    log.log_system.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = std.fmt.bufPrintSentinel(&buf, "{s}/log", .{dir}, 0) catch return;
    _ = std.c.mkdir(log_dir.ptr, 0o700);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ log_dir, name }) catch return;
    log.log_system.init(io, path, std.Io.File.Permissions.fromMode(0o600)) catch {};
}

/// The bytes that wait for one client, as whole frames. Pane output can be
/// dropped; messages and snapshots cannot.
pub const OutQueue = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Where the first whole frame starts. Above 0 when a write sent the
    /// first part of a frame: those bytes must follow, or the stream breaks.
    boundary: usize = 0,
    /// Where the last frame that must not be dropped ends.
    keep_end: usize = 0,

    pub fn deinit(q: *OutQueue, gpa: std.mem.Allocator) void {
        q.buf.deinit(gpa);
    }

    pub fn len(q: *const OutQueue) usize {
        return q.buf.items.len;
    }

    /// `droppable` is true for pane output only.
    pub fn append(q: *OutQueue, gpa: std.mem.Allocator, channel: u32, kind: frame.Kind, body: []const u8, droppable: bool) !void {
        var header: [frame.header_len]u8 = undefined;
        try frame.writeHeader(&header, channel, kind, body.len);
        try q.buf.ensureUnusedCapacity(gpa, header.len + body.len);
        q.buf.appendSliceAssumeCapacity(&header);
        q.buf.appendSliceAssumeCapacity(body);
        if (!droppable) q.keep_end = q.buf.items.len;
    }

    /// The output that a drop would remove.
    pub fn droppableLen(q: *const OutQueue) usize {
        return q.buf.items.len - q.dropPoint();
    }

    fn dropPoint(q: *const OutQueue) usize {
        return @max(q.boundary, q.keep_end);
    }

    /// Removes the first `n` bytes, which a write sent.
    pub fn consume(q: *OutQueue, n: usize) void {
        std.debug.assert(n <= q.buf.items.len);
        while (q.boundary < n) {
            const body_len = std.mem.readInt(u32, q.buf.items[q.boundary..][0..4], .little);
            q.boundary += frame.header_len + body_len;
        }
        q.boundary -= n;
        q.keep_end -|= n;
        q.buf.replaceRangeAssumeCapacity(0, n, &.{});
    }

    /// Drops the output after the last frame that must stay, and that has
    /// not started to go out. The rest of a frame that is half sent stays,
    /// so that the stream stays whole.
    pub fn drop(q: *OutQueue) void {
        q.buf.shrinkRetainingCapacity(q.dropPoint());
    }
};

const Client = struct {
    fd: i32,
    in: std.ArrayList(u8) = .empty,
    out: OutQueue = .{},
    /// Its `hello` came and was accepted.
    greeted: bool = false,
    /// It sent `attach`: it gets the pane's output.
    attached: bool = false,
    /// Its `attach` asked for `foreground` messages.
    wants_foreground: bool = false,
    /// Its `attach` asked for `tty_mode` messages.
    wants_tty: bool = false,
    /// Its output was dropped. It gets a snapshot when it can take data.
    behind: bool = false,
    /// Close it when its queue is empty (after a refusal).
    closing: bool = false,
    dead: bool = false,
    /// A bell rang since its queue was last empty. A bell is dropped with
    /// output, so a client that falls behind gets it again after its
    /// snapshot.
    rang: bool = false,

    fn deinit(c: *Client, gpa: std.mem.Allocator) void {
        lib_posix.close(c.fd);
        c.in.deinit(gpa);
        c.out.deinit(gpa);
    }
};

pub const ExitStatus = struct {
    code: ?u8 = null,
    signal: ?u8 = null,

    /// From a `waitpid` status (POSIX layout, the same on Linux and macOS).
    pub fn fromWait(status: u32) ExitStatus {
        const sig: u8 = @intCast(status & 0x7f);
        if (sig == 0) return .{ .code = @intCast((status >> 8) & 0xff) };
        return .{ .signal = sig };
    }
};

const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    listen_fd: i32,
    pty_fd: i32,
    shell_pid: lib_posix.pid_t,
    pty_name: []const u8,
    pty_name_buf: [128]u8,
    epoch: u64,
    /// The last output bytes, and their count (design/003 §7).
    output: ring.Ring = .{},
    size: ipc.Resize,
    /// The terminal, and the events it gives (events.zig).
    watch: events.Watch,
    clients: std.ArrayList(*Client) = .empty,
    leader: ?*Client = null,
    pty_in: std.ArrayList(u8) = .empty,
    has_output: bool = false,
    had_attached: bool = false,
    /// The shell's status, once reaped.
    reaped: ?ExitStatus = null,
    /// The pty gave EOF: all its output is read.
    pty_closed: bool = false,
    /// The exit went to the clients.
    announced: bool = false,
    /// A client took the exit status.
    taken: bool = false,
    /// The pty's foreground process group at the last read, when that read
    /// was, and a hash of the last `foreground` message sent.
    foreground_pgid: ?lib_posix.pid_t = null,
    foreground_read_at: i64 = 0,
    foreground_hash: u64 = 0,
    /// The last tty mode sent (`ttyModeOf`), or null before the first read.
    tty_mode: ?m.TtyMode = null,
    etc_shells: ?[]const u8 = null,
    etc_shells_loaded: bool = false,
    etc_shells_buf: [4096]u8 = undefined,
    /// A client sent `end`.
    ending: bool = false,

    const pty_in_max = 256 * 1024;

    fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options, listen_fd: i32, pty: daemonize.PtyInfo) !Session {
        var epoch: u64 = undefined;
        io.random(std.mem.asBytes(&epoch));
        var s: Session = .{
            .gpa = gpa,
            .io = io,
            .name = opts.name,
            .listen_fd = listen_fd,
            .pty_fd = pty.master_fd,
            .shell_pid = pty.pid,
            .pty_name = "",
            .pty_name_buf = pty.name_buf,
            .epoch = epoch,
            .size = opts.size,
            .watch = .init(gpa, try ghostty_vt.Terminal.init(io, gpa, .{
                .cols = opts.size.cols,
                .rows = opts.size.rows,
                .max_scrollback_lines = opts.max_scrollback_lines,
                .max_scrollback_bytes = null,
            })),
        };
        s.pty_name = std.mem.sliceTo(&s.pty_name_buf, 0);
        return s;
    }

    fn exited(s: *const Session) ?ExitStatus {
        if (!s.pty_closed) return null;
        return s.reaped;
    }

    fn run(s: *Session) !void {
        // `init` copied the struct: the name slice must point into this copy.
        s.pty_name = std.mem.sliceTo(&s.pty_name_buf, 0);
        try signal.openSignalPipe();
        signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
        signal.installWakeHandler(@backingInt(lib_posix.SIG.CHLD));
        var stream = s.watch.term.vtStream();
        defer stream.deinit();
        s.watch.install(&stream.handler);
        var fds: std.ArrayList(lib_posix.pollfd) = .empty;
        defer fds.deinit(s.gpa);
        std.log.info("session {s} started pid={d} shell={d} pty={s}", .{ s.name, std.c.getpid(), s.shell_pid, s.pty_name });

        while (!s.taken and !s.ending) {
            s.updateFocus();
            fds.clearRetainingCapacity();
            try fds.append(s.gpa, .{ .fd = s.listen_fd, .events = lib_posix.POLL.IN, .revents = 0 });
            var pty_events: i16 = 0;
            if (!s.pty_closed) {
                pty_events = lib_posix.POLL.IN;
                if (s.pty_in.items.len > 0) pty_events |= lib_posix.POLL.OUT;
            }
            try fds.append(s.gpa, .{ .fd = if (s.pty_closed) -1 else s.pty_fd, .events = pty_events, .revents = 0 });
            try fds.append(s.gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });
            const polled = s.clients.items.len;
            for (s.clients.items) |c| {
                var poll_events: i16 = lib_posix.POLL.IN;
                if (c.out.len() > 0 or c.behind) poll_events |= lib_posix.POLL.OUT;
                try fds.append(s.gpa, .{ .fd = c.fd, .events = poll_events, .revents = 0 });
            }

            _ = try lib_posix.poll(fds.items, s.pollTimeout());

            // Held events whose window ended, and a foreground that changed
            // while the pty was quiet.
            s.watch.flush(s.nowMs());
            s.checkForeground(null);
            s.checkTty(null);
            s.sendEvents();

            if (fds.items[2].revents & lib_posix.POLL.IN != 0) {
                signal.drainSignalPipe() catch {
                    std.log.info("session {s}: SIGTERM", .{s.name});
                    return;
                };
                s.reap();
                s.announceExit();
            }

            if (fds.items[0].revents & lib_posix.POLL.IN != 0) s.accept();

            const pty_revents = fds.items[1].revents;
            if (pty_revents & (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR) != 0) s.readPty(&stream);
            if (pty_revents & lib_posix.POLL.OUT != 0) s.writePty();

            for (s.clients.items[0..polled], fds.items[3..][0..polled]) |c, pfd| {
                if (c.dead) continue;
                if (pfd.revents & lib_posix.POLL.IN != 0) s.readClient(c);
                if (!c.dead and pfd.revents & lib_posix.POLL.OUT != 0) s.writeClient(c);
                if (!c.dead and pfd.revents & lib_posix.POLL.IN == 0 and
                    pfd.revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) s.dropClient(c);
            }
            s.sweep();
        }
    }

    /// Ends the shell's process group if it still runs, as v1 does: SIGHUP
    /// (shells ignore SIGTERM), then SIGKILL after a grace time.
    fn end(s: *Session) void {
        for (s.clients.items) |c| {
            c.deinit(s.gpa);
            s.gpa.destroy(c);
        }
        s.clients.clearRetainingCapacity();
        if (s.reaped != null) return;
        lib_posix.kill(-s.shell_pid, lib_posix.SIG.HUP) catch {};
        std.Io.sleep(s.io, .fromMilliseconds(500), .real) catch {};
        lib_posix.kill(-s.shell_pid, lib_posix.SIG.KILL) catch {};
        _ = lib_posix.waitpid(s.shell_pid, 0);
    }

    fn reap(s: *Session) void {
        if (s.reaped != null) return;
        const res = lib_posix.waitpid(s.shell_pid, std.c.W.NOHANG);
        if (res.pid != s.shell_pid) return;
        s.reaped = ExitStatus.fromWait(res.status);
        std.log.info("session {s}: shell exited code={?d} signal={?d}", .{ s.name, s.reaped.?.code, s.reaped.?.signal });
    }

    /// Sends the exit to every client once both the shell is reaped and its
    /// output is all read, so the exit comes after the last output.
    fn announceExit(s: *Session) void {
        if (s.announced) return;
        const status = s.exited() orelse return;
        s.announced = true;
        s.watch.shellExited(s.nowMs());
        s.sendEvents();
        for (s.clients.items) |c| {
            if (c.greeted) s.sendExit(c, status);
        }
    }

    fn sendExit(s: *Session, c: *Client, status: ExitStatus) void {
        s.sendPane(c, m.Exit, .{ .code = status.code, .signal = status.signal });
    }

    fn accept(s: *Session) void {
        const fd = lib_posix.accept(s.listen_fd, null, null, lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC) catch return;
        if (!runtime.allowPeer(runtime.peerUid(fd), std.c.getuid())) {
            std.log.warn("session {s}: refused a peer of another user", .{s.name});
            lib_posix.close(fd);
            return;
        }
        if (s.clients.items.len >= max_clients) {
            std.log.warn("session {s}: {d} clients, a new one closed", .{ s.name, max_clients });
            lib_posix.close(fd);
            return;
        }
        const c = s.gpa.create(Client) catch {
            lib_posix.close(fd);
            return;
        };
        c.* = .{ .fd = fd };
        s.clients.append(s.gpa, c) catch {
            s.gpa.destroy(c);
            lib_posix.close(fd);
            return;
        };
        s.sendControl(c, s.hello());
    }

    fn hello(s: *const Session) m.Hello {
        return .{
            .level = m.level,
            .min_level = m.min_level,
            .build = build_options.version,
            .role = .session,
            .epoch = s.epoch,
            .caps = &.{},
        };
    }

    fn readPty(s: *Session, stream: anytype) void {
        var buf: [4096]u8 = undefined;
        const n = lib_posix.read(s.pty_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            // Linux gives EIO once the slave side is closed.
            else => 0,
        };
        if (n == 0) {
            s.pty_closed = true;
            lib_posix.close(s.pty_fd);
            // SIGCHLD can come before or after the EOF. The exit goes out
            // when both are in.
            s.reap();
            s.announceExit();
            return;
        }
        const data = buf[0..n];
        s.has_output = true;
        // With no client that shows the pane, answer the terminal queries
        // that a shell waits for (fish waits 10 s), as v1 does.
        if (!s.hasAttached() and s.pty_in.items.len < pty_in_max)
            util.respondToDeviceAttributes(s.gpa, &s.pty_in, data);

        // A foreground change goes before the output: a report that the
        // shell is back lands before the shell's prompt (zmx 0010).
        s.checkForeground(null);
        s.checkTty(null);
        // Each event goes between the output before the sequence that gave
        // it and the output after: a client that reads its screen at an end
        // mark has the command's last line. The terminal parses up to the
        // end of each sequence (BEL or ST), and the output is cut only where
        // an event came.
        const now = s.nowMs();
        var sent: usize = 0;
        var at: usize = 0;
        while (at < data.len) {
            const stop = sequenceEnd(data, at);
            s.watch.feed(stream, data[at..stop], now);
            at = stop;
            if (s.watch.reply.items.len > 0) {
                s.queueInput(s.watch.reply.items);
                s.watch.reply.clearRetainingCapacity();
            }
            if (s.watch.ready.items.len == 0) continue;
            s.forwardOutput(data[sent..at]);
            sent = at;
            s.sendEvents();
        }
        s.forwardOutput(data[sent..]);
    }

    /// Queues pane output for every client that shows the pane.
    fn forwardOutput(s: *Session, data: []const u8) void {
        if (data.len == 0) return;
        const out = util.rewritePromptRedraw(s.gpa, data) orelse data;
        defer if (out.ptr != data.ptr) s.gpa.free(out);
        // The offsets count what clients get, so the ring holds `out`.
        s.output.append(s.gpa, out);
        for (s.clients.items) |c| {
            if (!c.attached or c.behind or c.dead) continue;
            c.out.append(s.gpa, m.pane_channel, .bytes, out, true) catch {
                s.dropClient(c);
                continue;
            };
            if (c.out.droppableLen() > client_cap) {
                c.out.drop();
                c.behind = true;
                std.log.info("session {s}: client fd={d} fell behind, output dropped", .{ s.name, c.fd });
            }
        }
    }

    fn writePty(s: *Session) void {
        while (s.pty_in.items.len > 0) {
            const n = lib_posix.write(s.pty_fd, s.pty_in.items) catch |err| {
                if (err != error.WouldBlock) s.pty_in.clearRetainingCapacity();
                return;
            };
            if (n == 0) return;
            s.pty_in.replaceRangeAssumeCapacity(0, n, &.{});
        }
    }

    fn queueInput(s: *Session, data: []const u8) void {
        if (s.pty_closed or data.len == 0) return;
        // Drop new input, not old, so that no sequence is torn (v1's rule).
        if (s.pty_in.items.len + data.len > pty_in_max) {
            std.log.warn("session {s}: input dropped, shell not reading", .{s.name});
            return;
        }
        s.pty_in.appendSlice(s.gpa, data) catch {};
    }

    fn hasAttached(s: *const Session) bool {
        for (s.clients.items) |c| if (c.attached and !c.dead) return true;
        return false;
    }

    /// A program that asked for focus reports (DECSET 1004) gets focus-out
    /// when the last client that shows the pane leaves, and focus-in when one
    /// comes back, as v1 does.
    fn updateFocus(s: *Session) void {
        const now = s.hasAttached();
        if (now != s.had_attached and s.watch.term.modes.get(.focus_event))
            s.queueInput(if (now) "\x1b[I" else "\x1b[O");
        s.had_attached = now;
    }

    fn readClient(s: *Session, c: *Client) void {
        var buf: [16 * 1024]u8 = undefined;
        const n = lib_posix.read(c.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return s.dropClient(c),
        };
        if (n == 0) return s.dropClient(c);
        c.in.appendSlice(s.gpa, buf[0..n]) catch return s.dropClient(c);

        var used: usize = 0;
        defer c.in.replaceRangeAssumeCapacity(0, used, &.{});
        while (!c.dead and !c.closing) {
            // A frame larger than any that a client needs closes the client
            // before its body is read.
            const rest = c.in.items[used..];
            if (rest.len >= frame.header_len and std.mem.readInt(u32, rest[0..4], .little) > client_frame_max)
                return s.dropClient(c);
            const parsed = (frame.parse(c.in.items[used..]) catch return s.dropClient(c)) orelse break;
            used += parsed.len;
            s.handleFrame(c, parsed.frame);
        }
    }

    fn handleFrame(s: *Session, c: *Client, f: frame.Frame) void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (!c.greeted) {
            // The first frame must be the peer's hello.
            if (f.channel != frame.control_channel) return s.dropClient(c);
            const msg = m.decodeControl(arena, f.body) catch return s.dropClient(c);
            const theirs = switch (msg) {
                .hello => |h| h,
                else => return s.dropClient(c),
            };
            switch (m.negotiate(s.hello(), theirs)) {
                .refuse => |r| {
                    std.log.info("session {s}: refused a client at level {d}: {s}", .{ s.name, theirs.level, r.reason });
                    s.sendControl(c, r);
                    c.closing = true;
                },
                .speak => {
                    c.greeted = true;
                    s.sendPane(c, m.State, s.state());
                    s.sendCurrent(c);
                    if (s.exited()) |status| s.sendExit(c, status);
                },
            }
            return;
        }

        if (f.channel == frame.control_channel) {
            // The session has no methods. A request gets an error reply, so
            // that a peer of a later level does not wait for ever.
            const msg = m.decodeControl(arena, f.body) catch return s.dropClient(c);
            if (msg == .request) s.sendControl(c, m.Response{ .re = msg.request.id, .err = .{
                .code = "unknown_method",
                .message = "A session has no methods.",
            } });
            return;
        }
        if (f.channel != m.pane_channel) return;
        switch (f.kind) {
            .bytes => s.handleInput(c, f.body),
            .msg => {
                const msg = msgpack.decodeSlice(m.PaneMessage, arena, f.body) catch return s.dropClient(c);
                s.handlePane(c, arena, msg) catch return s.dropClient(c);
            },
            _ => {},
        }
    }

    fn handlePane(s: *Session, c: *Client, arena: std.mem.Allocator, msg: m.PaneMessage) !void {
        if (std.mem.eql(u8, msg.t, m.Attach.name)) {
            const a = try m.decodePane(m.Attach, arena, msg);
            const size = paneSize(a.cols, a.rows, a.xpixel, a.ypixel) orelse return;
            s.attach(c, size, resumeOf(a));
            if (a.foreground and !c.wants_foreground) {
                c.wants_foreground = true;
                s.checkForeground(c);
            }
            if (a.tty and !c.wants_tty) {
                c.wants_tty = true;
                s.checkTty(c);
            }
        } else if (std.mem.eql(u8, msg.t, m.Resize.name)) {
            // Only a client that shows the pane has a size that counts.
            if (!c.attached) return;
            const r = try m.decodePane(m.Resize, arena, msg);
            const size = paneSize(r.cols, r.rows, r.xpixel, r.ypixel) orelse return;
            if (s.leader == null) s.setLeader(c);
            if (s.leader == c) s.resize(size);
        } else if (std.mem.eql(u8, msg.t, m.Claim.name)) {
            if (c.attached and s.leader != c) s.setLeader(c);
        } else if (std.mem.eql(u8, msg.t, m.End.name)) {
            std.log.info("session {s}: end", .{s.name});
            s.ending = true;
        } else if (std.mem.eql(u8, msg.t, m.Refresh.name)) {
            s.refresh(c);
        } else if (std.mem.eql(u8, msg.t, m.Seen.name)) {
            s.watch.seen();
            s.sendEvents();
        } else if (std.mem.eql(u8, msg.t, m.Take.name)) {
            if (s.exited() != null) {
                std.log.info("session {s}: exit status taken", .{s.name});
                s.taken = true;
            }
        }
        // A message of a later level: ignored.
    }

    /// Input from the leader goes to the pty. Input from another client that
    /// shows the pane makes it the leader when it is a keystroke, and is
    /// dropped when it is a terminal's reply (v1's rule). A client that does
    /// not show the pane (a script) sends input with no effect on leadership.
    fn handleInput(s: *Session, c: *Client, data: []const u8) void {
        if (!c.attached or s.leader == c) return s.queueInput(data);
        if (util.isUserInput(data)) {
            s.setLeader(c);
            s.queueInput(data);
        }
    }

    fn attach(s: *Session, c: *Client, size: ipc.Resize, want: ?Resume) void {
        // Output that queued before the attach is not this client's: a client
        // gets output only after its snapshot.
        const was_attached = c.attached;
        c.attached = true;
        if (!was_attached) s.announceClients();
        if (s.leader == null) s.setLeader(c);
        const leads = s.leader == c;
        // The snapshot is laid out for the size the leader renders at.
        if (leads) resizeTerm(s.gpa, &s.watch.term, size) catch {};
        // A client that lost its link and has all of its output but the last
        // bytes gets those bytes, and nothing is drawn again.
        const resumed = if (!was_attached) if (want) |w| s.resumeOutput(c, w) else false else false;
        if (!resumed and s.has_output) _ = s.sendSnapshot(c, true);
        if (leads) {
            s.resize(size);
            // A repaint for incremental renderers: TIOCSWINSZ with the same
            // size sends no SIGWINCH, so send it (v1's reattach rule). Not
            // for a resume: the program has drawn what the client missed.
            if (!resumed and s.has_output and !s.pty_closed) {
                var pgrp: lib_posix.pid_t = 0;
                if (cross.ioctl(s.pty_fd, cross.TIOCGPGRP, &pgrp) == 0 and pgrp > 0)
                    lib_posix.kill(-pgrp, .WINCH) catch {};
            }
        }
    }

    /// Answers a resume: `Resumed` and the bytes after the client's offset.
    /// False when the session cannot (another epoch, bytes that the ring
    /// lost): nothing was sent, and the client gets a snapshot.
    fn resumeOutput(s: *Session, c: *Client, want: Resume) bool {
        if (want.epoch != s.epoch) return false;
        const missing = s.output.since(want.offset) orelse return false;
        s.sendPane(c, m.Resumed, .{ .offset = want.offset });
        var rest = missing;
        while (rest.len > 0 and !c.dead) {
            const n = @min(rest.len, snapshot_chunk);
            // Output, so a client that falls behind drops it as it drops any
            // output, and then gets a snapshot.
            c.out.append(s.gpa, m.pane_channel, .bytes, rest[0..n], true) catch {
                s.dropClient(c);
                return true;
            };
            rest = rest[n..];
        }
        if (c.out.droppableLen() > client_cap) {
            c.out.drop();
            c.behind = true;
        }
        return true;
    }

    /// `size` comes from `paneSize`: never 0.
    fn resize(s: *Session, size: ipc.Resize) void {
        s.size = size;
        if (!s.pty_closed) {
            var ws = size.winsize();
            _ = cross.ioctl(s.pty_fd, cross.TIOCSWINSZ, &ws);
        }
        resizeTerm(s.gpa, &s.watch.term, size) catch |err|
            std.log.warn("session {s}: resize failed: {s}", .{ s.name, @errorName(err) });
    }

    fn setLeader(s: *Session, c: *Client) void {
        if (s.leader) |old| if (old != c and !old.dead) s.sendPane(old, m.Lead, .{ .leader = false });
        s.leader = c;
        s.sendPane(c, m.Lead, .{ .leader = true });
    }

    fn state(s: *const Session) m.State {
        return .{
            .pid = std.c.getpid(),
            .shell_pid = s.shell_pid,
            .pty = .{ .bytes = s.pty_name },
            .cols = s.size.cols,
            .rows = s.size.rows,
            .clients = s.attachedCount(),
        };
    }

    fn attachedCount(s: *const Session) u16 {
        var n: u16 = 0;
        for (s.clients.items) |c| {
            if (c.attached and !c.dead) n +|= 1;
        }
        return n;
    }

    /// The count of attached clients changed: the connections that do not
    /// show the pane (the server's) get the new `state`.
    fn announceClients(s: *Session) void {
        const st = s.state();
        for (s.clients.items) |c| {
            if (c.greeted and !c.attached and !c.dead and !c.closing) s.sendPane(c, m.State, st);
        }
    }

    /// False when the terminal state could not be read: nothing was sent.
    fn sendSnapshot(s: *Session, c: *Client, scrollback: bool) bool {
        const raw = (if (scrollback) util.serializeTerminalState(s.gpa, &s.watch.term) else util.serializeScreenState(s.gpa, &s.watch.term)) orelse return false;
        defer s.gpa.free(raw);
        const data = util.rewritePromptRedraw(s.gpa, raw) orelse raw;
        defer if (data.ptr != raw.ptr) s.gpa.free(data);
        s.sendPane(c, m.SnapshotStart, .{ .scrollback = scrollback, .offset = s.output.end() });
        var rest = data;
        while (rest.len > 0 and !c.dead) {
            const n = @min(rest.len, snapshot_chunk);
            c.out.append(s.gpa, m.pane_channel, .bytes, rest[0..n], false) catch {
                s.dropClient(c);
                return true;
            };
            rest = rest[n..];
        }
        s.sendPane(c, m.SnapshotEnd, .{});
        s.checkHardCap(c);
        return true;
    }

    /// A client asks for the screen again (`m.Refresh`). A client that is
    /// behind gets its snapshot when it catches up.
    fn refresh(s: *Session, c: *Client) void {
        if (!c.attached or c.behind) return;
        c.out.drop();
        // Events went with the dropped output.
        defer s.sendCurrent(c);
        if (s.has_output and s.sendSnapshot(c, false)) return;
        // With no output, or no memory for the snapshot: an empty one, so
        // that a relay that waits for one stops waiting.
        s.sendPane(c, m.SnapshotStart, .{ .scrollback = false, .offset = s.output.end() });
        s.sendPane(c, m.SnapshotEnd, .{});
    }

    fn writeClient(s: *Session, c: *Client) void {
        if (c.out.len() > 0) {
            const n = lib_posix.write(c.fd, c.out.buf.items) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return s.dropClient(c),
            };
            c.out.consume(n);
        }
        if (c.out.len() > 0) return;
        if (c.closing) return s.dropClient(c);
        // The client takes data again: it gets the screen as it is now.
        if (c.behind) {
            c.behind = false;
            std.log.info("session {s}: client fd={d} caught up, snapshot sent", .{ s.name, c.fd });
            // A drop can take a `lead` that waited: say it again.
            s.sendPane(c, m.Lead, .{ .leader = s.leader == c });
            _ = s.sendSnapshot(c, false);
            // Events went with the dropped output.
            s.sendCurrent(c);
            if (c.rang) s.sendPane(c, m.Bell, .{});
        }
        c.rang = false;
    }

    fn dropClient(s: *Session, c: *Client) void {
        if (c.dead) return;
        c.dead = true;
        if (c.attached) s.announceClients();
        if (s.leader != c) return;
        s.leader = null;
        // The client that attached first of those left leads next. It sends
        // its size when it reads `lead`.
        for (s.clients.items) |next| {
            if (next.attached and !next.dead) return s.setLeader(next);
        }
    }

    fn sweep(s: *Session) void {
        var i: usize = 0;
        while (i < s.clients.items.len) {
            const c = s.clients.items[i];
            if (c.dead) {
                c.deinit(s.gpa);
                s.gpa.destroy(c);
                _ = s.clients.orderedRemove(i);
            } else i += 1;
        }
    }

    fn sendControl(s: *Session, c: *Client, value: anytype) void {
        const body = msgpack.encodeAlloc(s.gpa, value) catch return;
        defer s.gpa.free(body);
        c.out.append(s.gpa, frame.control_channel, .msg, body, false) catch return s.dropClient(c);
        s.checkHardCap(c);
    }

    fn sendPane(s: *Session, c: *Client, comptime M: type, value: M) void {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        m.encodePane(&out.writer, M, value) catch return;
        c.out.append(s.gpa, m.pane_channel, .msg, out.written(), false) catch return s.dropClient(c);
        s.checkHardCap(c);
    }

    fn nowMs(s: *const Session) i64 {
        return std.Io.Timestamp.now(s.io, .awake).toMilliseconds();
    }

    fn pollTimeout(s: *const Session) i32 {
        return pollTimeoutFor((foreground.supported and s.hasForegroundClient()) or s.hasTtyClient(), s.watch.deadline(), s.nowMs());
    }

    /// A live client asked for `foreground` messages. With none, the
    /// session reads no foreground and an idle session never wakes.
    fn hasForegroundClient(s: *const Session) bool {
        for (s.clients.items) |c| if (c.wants_foreground and !c.dead) return true;
        return false;
    }

    /// A live client asked for `tty_mode` messages.
    fn hasTtyClient(s: *const Session) bool {
        for (s.clients.items) |c| if (c.wants_tty and !c.dead) return true;
        return false;
    }

    /// Reads the pty's line modes and sends `tty_mode` to the clients that
    /// asked for it when they changed. A program that reads a password puts
    /// the tty in canonical mode with echo off, and the GUI cannot read this
    /// tty when the session is on another machine. With `new_client`, that
    /// client alone gets the current mode. Nothing is read with no such
    /// client. The message carries two flags, never any input.
    fn checkTty(s: *Session, new_client: ?*Client) void {
        if (s.pty_closed or !s.hasTtyClient()) return;
        var t: cross.termios = undefined;
        if (cross.tcgetattr(s.pty_fd, &t) != 0) return;
        const now = ttyModeOf(t.c_lflag);
        if (s.tty_mode) |last| if (last.canonical == now.canonical and last.echo == now.echo) {
            if (new_client) |c| s.sendPane(c, m.TtyMode, now);
            return;
        };
        s.tty_mode = now;
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        m.encodePane(&out.writer, m.TtyMode, now) catch return;
        for (s.clients.items) |c| {
            if (!c.wants_tty or c.dead or c.behind) continue;
            c.out.append(s.gpa, m.pane_channel, .msg, out.written(), true) catch {
                s.dropClient(c);
                continue;
            };
            s.checkHardCap(c);
        }
    }

    /// Reads the pty's foreground process group and, when it changed, sends
    /// `foreground` to every client that asked for it. One ioctl when nothing
    /// changed. With no such client, nothing is read: a client that asks
    /// reads it then.
    ///
    /// The leader is also read again once in `poll_interval_ms` with no
    /// change of group: the group changes before its child `exec`s the
    /// program, and a leader can `exec` in place (`exec zsh`). A message that
    /// differs from the last one goes to every client.
    ///
    /// With `new_client`, the process is read at once, and that client alone
    /// gets it when nothing changed. No message is kept to send later, so a
    /// client never gets a name that went stale.
    fn checkForeground(s: *Session, new_client: ?*Client) void {
        if (!foreground.supported or s.pty_closed or !s.hasForegroundClient()) return;
        var pgrp: lib_posix.pid_t = 0;
        if (cross.ioctl(s.pty_fd, cross.TIOCGPGRP, &pgrp) != 0 or pgrp <= 0) return;
        const now = s.nowMs();
        const due = now - s.foreground_read_at >= foreground.poll_interval_ms;
        if (s.foreground_pgid == pgrp and new_client == null and !due) return;
        s.foreground_pgid = pgrp;
        s.foreground_read_at = now;
        if (!s.etc_shells_loaded) {
            s.etc_shells_loaded = true;
            s.etc_shells = foreground.readEtcShells(&s.etc_shells_buf);
        }
        // The group leader can be gone while the group lives on (the first
        // process of a pipeline exited). Then there is no name to send; the
        // next change sends again.
        var comm_buf: [std.fs.max_path_bytes]u8 = undefined;
        var args_buf: [foreground.args_max]u8 = undefined;
        var scratch: [8192]u8 = undefined;
        const process = foreground.readProcess(s.gpa, pgrp, &comm_buf, &args_buf, &scratch) orelse {
            std.log.info("session {s}: foreground pgid={d} has no readable leader", .{ s.name, pgrp });
            return;
        };
        const msg: m.Foreground = .{
            .idle = pgrp == s.shell_pid,
            .shell = if (s.etc_shells) |shells| foreground.isListedShell(shells, process.comm) else null,
            .comm = .{ .bytes = process.comm },
            .args = .{ .bytes = process.args },
        };
        var hasher: std.hash.Wyhash = .init(0);
        std.hash.autoHashStrat(&hasher, msg, .Deep);
        const hash = hasher.final();
        if (hash != s.foreground_hash) {
            s.foreground_hash = hash;
            s.broadcastForeground(msg);
        } else if (new_client) |c| s.sendPane(c, m.Foreground, msg);
    }

    /// Sends the events that the terminal gave, in order, to every client.
    fn sendEvents(s: *Session) void {
        defer s.watch.clearReady();
        for (s.watch.ready.items) |e| s.broadcastEvent(e);
    }

    /// Every event but a mark can be dropped with the output of a client
    /// that falls behind: the client gets the current state again after its
    /// snapshot. A kept frame stops a drop of the output before it, and the
    /// heartbeat alone comes every `activity_ms`.
    fn broadcastEvent(s: *Session, e: events.Event) void {
        switch (e) {
            .title => |t| s.broadcastPane(m.Title, .{ .title = .{ .bytes = t } }, true),
            .cwd => |u| s.broadcastPane(m.Cwd, .{ .url = .{ .bytes = u } }, true),
            .mark => |mk| s.broadcastPane(m.Mark, .{
                .kind = mk.kind,
                .command = if (mk.command) |c| .{ .bytes = c } else null,
                .exit_code = mk.exit_code,
            }, false),
            .progress => |p| s.broadcastPane(m.Progress, p, true),
            .bell => {
                for (s.clients.items) |c| c.rang = true;
                s.broadcastPane(m.Bell, .{}, true);
            },
            .activity => s.broadcastPane(m.Activity, .{}, true),
            .status => |st| s.broadcastPane(m.Status, st, true),
            .attention => |a| s.broadcastPane(m.Attention, a, false),
            .program => |records| s.broadcastPane(m.ProgramStatus, .{ .records = records }, true),
        }
    }

    /// The current title, cwd, progress, status and program status, for a
    /// client that just greeted or lost its queue. The foreground goes only
    /// to a client that asked for it at its `attach`.
    fn sendCurrent(s: *Session, c: *Client) void {
        if (c.wants_foreground) s.checkForeground(c);
        if (c.wants_tty) s.checkTty(c);

        var list: std.ArrayList(events.Event) = .empty;
        defer list.deinit(s.gpa);
        defer for (list.items) |e| if (e == .program) events.freeProgram(s.gpa, e.program);
        s.watch.current(&list) catch return;
        for (list.items) |e| switch (e) {
            .title => |t| s.sendPane(c, m.Title, .{ .title = .{ .bytes = t } }),
            .cwd => |u| s.sendPane(c, m.Cwd, .{ .url = .{ .bytes = u } }),
            .progress => |p| s.sendPane(c, m.Progress, p),
            .status => |st| s.sendPane(c, m.Status, st),
            .attention => |a| s.sendPane(c, m.Attention, a),
            .program => |records| s.sendPane(c, m.ProgramStatus, .{ .records = records }),
            else => {},
        };
    }

    /// Encodes `value` once and queues it for every client that greeted. A
    /// `droppable` message skips a client that is behind, as output does.
    fn broadcastPane(s: *Session, comptime M: type, value: M, droppable: bool) void {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        m.encodePane(&out.writer, M, value) catch return;
        for (s.clients.items) |c| {
            if (!c.greeted or c.dead or (droppable and c.behind)) continue;
            c.out.append(s.gpa, m.pane_channel, .msg, out.written(), droppable) catch {
                s.dropClient(c);
                continue;
            };
            s.checkHardCap(c);
        }
    }

    /// As `broadcastPane`, to the clients that asked for `foreground`.
    fn broadcastForeground(s: *Session, msg: m.Foreground) void {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        m.encodePane(&out.writer, m.Foreground, msg) catch return;
        for (s.clients.items) |c| {
            if (!c.wants_foreground or c.dead or c.behind) continue;
            c.out.append(s.gpa, m.pane_channel, .msg, out.written(), true) catch {
                s.dropClient(c);
                continue;
            };
            s.checkHardCap(c);
        }
    }

    fn checkHardCap(s: *Session, c: *Client) void {
        if (c.out.len() <= client_hard_cap) return;
        std.log.warn("session {s}: client fd={d} does not read, closed", .{ s.name, c.fd });
        s.dropClient(c);
    }
};

/// The line modes of a pty from its `c_lflag`.
fn ttyModeOf(lflag: anytype) m.TtyMode {
    return .{
        .canonical = lflag & cross.ICANON != 0,
        .echo = lflag & cross.ECHO != 0,
    };
}

/// The index after the next string terminator (BEL, or ESC \) at or after
/// `from`, or the end of `data`.
fn sequenceEnd(data: []const u8, from: usize) usize {
    var i = from;
    while (std.mem.indexOfAnyPos(u8, data, i, "\x07\\")) |j| {
        if (data[j] == 0x07) return j + 1;
        if (j > 0 and data[j - 1] == 0x1b) return j + 1;
        i = j + 1;
    }
    return data.len;
}

/// Until the next held event is due, and at most the foreground poll
/// interval while a client wants foreground reports: a program that takes
/// the pty and prints nothing is still reported (zmx 0010). With neither,
/// -1: the session sleeps until a fd is ready.
fn pollTimeoutFor(foreground_client: bool, deadline: ?i64, now: i64) i32 {
    var timeout: i32 = if (foreground_client) foreground.poll_interval_ms else -1;
    if (deadline) |due| {
        const wait: i32 = @intCast(std.math.clamp(due - now, 0, std.math.maxInt(i32)));
        timeout = if (timeout < 0) wait else @min(timeout, wait);
    }
    return timeout;
}

/// What an `Attach` asks to resume from.
const Resume = struct { epoch: u64, offset: u64 };

fn resumeOf(a: m.Attach) ?Resume {
    return .{ .epoch = a.resume_epoch orelse return null, .offset = a.resume_offset orelse return null };
}

/// A size from a client, cut to `max_cells`. Null for a size of 0.
fn paneSize(cols: u16, rows: u16, xpixel: u16, ypixel: u16) ?ipc.Resize {
    if (cols == 0 or rows == 0) return null;
    return .{ .cols = @min(cols, max_cells), .rows = @min(rows, max_cells), .xpixel = xpixel, .ypixel = ypixel };
}

/// Resizes the terminal with the prompt redraw off (see `Daemon.resizeTerm`):
/// the shell's redraw goes to the pty, not to this terminal.
fn resizeTerm(gpa: std.mem.Allocator, term: *ghostty_vt.Terminal, size: ipc.Resize) !void {
    if (size.cols == 0 or size.rows == 0) return;
    const saved = term.flags.shell_redraws_prompt;
    term.flags.shell_redraws_prompt = .false;
    defer term.flags.shell_redraws_prompt = saved;
    try term.resize(gpa, .{ .cols = size.cols, .rows = size.rows });
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a session name is one plain file name" {
    try testing.expect(validName("macterm-0b6c5e9a-1f2d-4c3b-9a8e-7d6f5e4c3b2a"));
    try testing.expect(validName("a.b_c"));
    try testing.expect(!validName(""));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("--cwd"));
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName("a b"));
}

test "the exit status reads a code or a signal" {
    try testing.expectEqual(ExitStatus{ .code = 7 }, ExitStatus.fromWait(7 << 8));
    try testing.expectEqual(ExitStatus{ .code = 0 }, ExitStatus.fromWait(0));
    try testing.expectEqual(ExitStatus{ .signal = 9 }, ExitStatus.fromWait(9));
    try testing.expectEqual(ExitStatus{ .signal = 1 }, ExitStatus.fromWait(1 | 0x80));
}

test "the out queue drops whole frames and keeps a frame that is half sent" {
    const gpa = testing.allocator;
    var q: OutQueue = .{};
    defer q.deinit(gpa);
    try q.append(gpa, 1, .bytes, "abcdef", true);
    try q.append(gpa, 1, .bytes, "gh", true);
    try testing.expectEqual(2 * frame.header_len + 8, q.len());

    // A write sent the first header and two bytes of the first body.
    q.consume(frame.header_len + 2);
    try testing.expectEqual(4, q.boundary);
    try q.append(gpa, 1, .bytes, "x", true);
    q.drop();
    // What is left is the rest of the first frame: "cdef".
    try testing.expectEqualStrings("cdef", q.buf.items);
    q.consume(4);
    try testing.expectEqual(0, q.len());
    try testing.expectEqual(0, q.boundary);

    // At a boundary, a drop leaves nothing.
    try q.append(gpa, 1, .bytes, "abc", true);
    q.drop();
    try testing.expectEqual(0, q.len());

    // A write that ends inside a later frame.
    try q.append(gpa, 1, .bytes, "ab", true);
    try q.append(gpa, 1, .bytes, "cd", true);
    q.consume(frame.header_len + 2 + 3);
    try testing.expectEqual(frame.header_len - 3 + 2, q.boundary);
    q.drop();
    try testing.expectEqual(frame.header_len - 3 + 2, q.len());
    try testing.expectEqualStrings("cd", q.buf.items[q.len() - 2 ..]);
}

test "the out queue never drops a message or a snapshot" {
    const gpa = testing.allocator;
    var q: OutQueue = .{};
    defer q.deinit(gpa);
    try q.append(gpa, 1, .bytes, "out1", true);
    try q.append(gpa, 1, .msg, "lead", false);
    try q.append(gpa, 1, .bytes, "snap", false);
    try q.append(gpa, 1, .bytes, "out2", true);
    try testing.expectEqual(frame.header_len + 4, q.droppableLen());
    q.drop();
    // Output before the last kept frame stays: it comes first on the wire.
    try testing.expectEqual(3 * (frame.header_len + 4), q.len());
    try testing.expectEqualStrings("snap", q.buf.items[q.len() - 4 ..]);
    try testing.expectEqual(0, q.droppableLen());

    // Sent bytes move the kept end with them.
    q.consume(frame.header_len + 4);
    try testing.expectEqual(2 * (frame.header_len + 4), q.keep_end);
    try q.append(gpa, 1, .bytes, "out3", true);
    q.drop();
    try testing.expectEqual(2 * (frame.header_len + 4), q.len());
}

test "the output is cut after each BEL and ST" {
    const data = "a\x1b]2;t\x07b\\c\x1b]7;u\x1b\\d";
    try testing.expectEqual(7, sequenceEnd(data, 0));
    try testing.expectEqual(17, sequenceEnd(data, 7));
    try testing.expectEqual(data.len, sequenceEnd(data, 17));
}

test "a pane size is cut to the limit, and 0 is ignored" {
    try testing.expectEqual(null, paneSize(0, 24, 0, 0));
    try testing.expectEqual(null, paneSize(80, 0, 0, 0));
    const big = paneSize(65535, 65535, 1, 2).?;
    try testing.expectEqual(max_cells, big.cols);
    try testing.expectEqual(max_cells, big.rows);
    try testing.expectEqual(80, paneSize(80, 24, 0, 0).?.cols);
}

test "a session polls the foreground only for a client that wants it" {
    // Only clients that did not ask, and no held event: no timeout.
    try std.testing.expectEqual(@as(i32, -1), pollTimeoutFor(false, null, 1000));
    try std.testing.expectEqual(@as(i32, foreground.poll_interval_ms), pollTimeoutFor(true, null, 1000));
    // A held event is due first, or after the poll interval.
    try std.testing.expectEqual(@as(i32, 16), pollTimeoutFor(false, 1016, 1000));
    try std.testing.expectEqual(@as(i32, 16), pollTimeoutFor(true, 1016, 1000));
    try std.testing.expectEqual(@as(i32, foreground.poll_interval_ms), pollTimeoutFor(true, 1000 + 10_000, 1000));
    try std.testing.expectEqual(@as(i32, 0), pollTimeoutFor(false, 900, 1000));
}
