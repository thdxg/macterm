//! `macterm server` (design/001, design/002, design/003 §4, design/006 §1).
//!
//! One for each user and machine. It holds the registry of sessions and
//! serves channel 0 to the GUI and the CLI: `session.create`, `list`,
//! `info`, `kill`, `server.exit`, `ping`, `command.run` (a command run to
//! its end, for the app's background reads of a host, 0058), and the
//! `session.exit` event. It holds no pty. On the Mac it is not on the byte
//! path: a client attaches to a session's own socket. On a host, the app reaches every pane through one
//! stream (`macterm proxy`), and the server relays each pane on a channel of
//! that stream (`channel.open`, `close`, `pause`, `resume`; `relay.zig`).
//!
//! It stores nothing. Each session process holds its state and its exit
//! status, and keeps the status until a client sends `session.kill`. So a
//! new server, after a crash or an update, reads every session again from
//! its socket and loses nothing.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const log = @import("log.zig");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const socket = @import("socket.zig");
const ipc = @import("ipc.zig");
const runtime = @import("runtime.zig");
const session = @import("session.zig");
const relay = @import("relay.zig");
const protocol = @import("protocol/protocol.zig");
const frame = protocol.frame;
const msgpack = protocol.msgpack;
const m = protocol.messages;

/// The server's socket in the runtime directory. A session name cannot start
/// with a dot, so no session can take it.
pub const socket_name = ".server";

/// With no session and no client for this long, the server exits. The app or
/// the CLI starts it again when its socket does not answer (design/001, A).
pub const idle_exit_ms = 5000;

/// A session process that does not end this long after `session.kill` gets
/// SIGKILL. The session itself gives its shell 0.5 s after SIGHUP.
pub const kill_grace_ms = 3000;

/// A `session` child that does not exit this long after it started gets
/// SIGKILL, and the create fails.
pub const spawn_ms = 10_000;

/// A session that does not send its state this long after the connect is
/// left out of the lists that wait for it. It is listed when it answers.
pub const settle_ms = 2000;

const max_clients = 64;

/// The send buffer of a client's socket (`SO_SNDBUF`).
const peer_sndbuf = 32 * 1024;

/// A server file of another build younger than this stays (`pruneBuilds`).
const fresh_build_ms = 60_000;

/// The most channels that one client can have open.
const max_channels = 256;

/// A client that sends no `hello` this long after it connects is closed, so
/// that idle connections cannot take every place.
const hello_ms = 5000;
const frame_max = 1024 * 1024;

/// The most stdout that `command.run` returns. The rest is read and dropped,
/// so that the command does not stop on a full pipe.
const run_output_max = 512 * 1024;
/// The longest `command.run` that a client can ask for.
const run_timeout_max_ms = 60_000;
/// The most commands that run at one time.
const max_runs = 16;

/// The `server` command. Starts the server and returns once its socket
/// accepts connections. `error.AlreadyRunning` when a server answers.
///
/// The forked server binds and listens itself, so that a peer's credentials
/// (`SO_PEERCRED`, `LOCAL_PEERPID`) name the server and not this caller. It
/// reports the result on a pipe.
pub fn start(gpa: std.mem.Allocator, dir: []const u8) !void {
    runtime.ensureDir(dir) catch return error.RuntimeDir;
    const path = try socket.getSocketPath(gpa, dir, socket_name);
    defer gpa.free(path);

    const pipe = try lib_posix.pipe2(.{ .CLOEXEC = true });
    const pid = lib_posix.fork() catch |err| {
        lib_posix.close(pipe[0]);
        lib_posix.close(pipe[1]);
        return err;
    };
    if (pid > 0) {
        lib_posix.close(pipe[1]);
        defer lib_posix.close(pipe[0]);
        var result: [1]u8 = .{@backingInt(Started.failed)};
        _ = lib_posix.read(pipe[0], &result) catch 0;
        return switch (@as(Started, @fromBackingInt(@intCast(result[0])))) {
            .listening => {},
            .already_running => error.AlreadyRunning,
            .failed => error.StartFailed,
        };
    }
    lib_posix.close(pipe[0]);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bound = if (selfExe(&exe_buf)) |_| bindOnce(dir, path) else |err| err;
    const fds = bound catch |err| {
        const result: Started = if (err == error.AlreadyRunning) .already_running else .failed;
        if (result == .failed) std.log.err("server: cannot start on {s}: {s}", .{ path, @errorName(err) });
        _ = lib_posix.write(pipe[1], &.{@backingInt(result)}) catch {};
        std.c._exit(0);
    };
    _ = lib_posix.write(pipe[1], &.{@backingInt(Started.listening)}) catch {};
    // The server: no terminal, no stdio, and no fd of the caller.
    _ = lib_posix.setsid() catch {};
    detachStdio();
    var fd: i32 = 3;
    while (fd < 256) : (fd += 1) {
        if (fd != fds.listen and fd != fds.lock) _ = std.c.close(fd);
    }
    serveAndExit(dir, fds);
}

const Started = enum(u8) { listening, already_running, failed };

/// The file that a server holds locked for its whole life. Only the holder
/// binds or unlinks the socket, so a start never takes the socket of a live
/// server, also when that server's backlog is full and a connect is refused.
pub const lock_name = ".server.lock";

const Bound = struct { listen: i32, lock: i32 };

fn bindOnce(dir: []const u8, path: []const u8) !Bound {
    const lock_fd = try takeServerLock(dir, path);
    errdefer lib_posix.close(lock_fd);
    // No server runs: a socket here is a crashed server's.
    session.unlinkSocket(dir, socket_name);
    return .{ .listen = try session.bindSocket(path), .lock = lock_fd };
}

/// `error.AlreadyRunning` when a server holds the lock. A server that exits
/// unlinks its socket and then lets the lock go, so while the socket does
/// not answer, the start waits up to 1 s for the lock.
fn takeServerLock(dir: []const u8, path: []const u8) !i32 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, lock_name }, 0);
    const fd = std.c.open(lock_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.LockFailed;
    errdefer lib_posix.close(fd);
    var tries: u32 = 0;
    while (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) : (tries += 1) {
        if (std.c._errno().* != @intFromEnum(std.c.E.AGAIN)) return error.LockFailed;
        if (tries >= 100) return error.AlreadyRunning;
        if (ipc.connectSession(path)) |conn| {
            lib_posix.close(conn);
            return error.AlreadyRunning;
        } else |_| {}
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return fd;
}

fn detachStdio() void {
    const devnull = lib_posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch return;
    inline for (.{ lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO, lib_posix.STDERR_FILENO }) |n|
        lib_posix.dup2(devnull, n) catch {};
    if (devnull > 2) lib_posix.close(devnull);
}

fn serveAndExit(dir: []const u8, fds: Bound) noreturn {
    // After a fork: no allocator or io of the parent.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const gpa = std.heap.c_allocator;
    session.openLog(io, dir, socket_name);
    var server = Server.init(gpa, io, dir, fds) catch |err| {
        std.log.err("server: start failed: {s}", .{@errorName(err)});
        session.unlinkSocket(dir, socket_name);
        std.process.exit(1);
    };
    // After `init` read the path of this binary, which can be relative.
    // The server lock is held: the unlink at a failed `init` above is safe.
    // Not the folder of the process that started the server: a session with
    // no folder starts in the home folder, and no volume stays busy.
    const home = lib_posix.getenv("HOME") orelse "/";
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&home_buf, "{s}", .{home}, 0)) |h| {
        if (std.c.chdir(h.ptr) != 0) _ = std.c.chdir("/");
    } else |_| _ = std.c.chdir("/");
    server.run() catch |err| std.log.err("server: loop failed: {s}", .{@errorName(err)});
    server.shutdown();
    std.log.info("server ended", .{});
    std.process.exit(0);
}

/// How many event batches the server keeps for `control.resume`.
pub const batch_ring = 256;

/// One sent event batch.
const Batch = struct {
    seq: u64,
    /// The encoded message, as it went on channel 0.
    body: []u8,
};

/// A GUI or a CLI on the server's socket.
const Peer = struct {
    id: u64,
    fd: i32,
    connected_at: i64,
    in: std.ArrayList(u8) = .empty,
    /// The frames that `write` sends now. `relay.fill` moves them in from
    /// `control` and the channels.
    out: session.OutQueue = .{},
    /// Channel 0's frames that wait.
    control: relay.Queue = .{},
    channels: std.ArrayList(*Channel) = .empty,
    next_channel: u32 = 1,
    /// The channel that goes first in the next fill (`relay.fill`).
    turn: usize = 0,
    greeted: bool = false,
    /// Close it when its queue is empty (after a refusal).
    closing: bool = false,
    dead: bool = false,

    fn findChannel(p: *Peer, id: u32) ?*Channel {
        for (p.channels.items) |ch| if (ch.id == id and !ch.closed) return ch;
        return null;
    }

    /// Everything that waits for this client.
    fn pending(p: *const Peer) usize {
        var n = p.out.len() + p.control.bytes;
        for (p.channels.items) |ch| n += ch.q.bytes;
        return n;
    }

    /// What waits for this client and that no skip can drop. The rest has a
    /// cap for each channel (`relay.skip_bytes`).
    fn kept(p: *const Peer) usize {
        var n = p.out.len() + p.control.bytes;
        for (p.channels.items) |ch| n += ch.q.bytes - ch.q.stale().bytes;
        return n;
    }
};

/// A pane that the server relays to a client: the server's own connection to
/// the session, and the frames that wait for the client.
const Channel = struct {
    /// The channel number on the client's stream.
    id: u32,
    session: []u8,
    /// The connection to the session. -1 when the session closed it: the
    /// channel goes when its last frames went to the client.
    fd: i32,
    in: std.ArrayList(u8) = .empty,
    /// The client's frames to the session, on the session's pane channel.
    to_session: session.OutQueue = .{},
    q: relay.Queue = .{},
    flow: relay.Flow = .{},
    greeted: bool = false,
    /// The `channel.open` request that waits for the session's `hello`.
    open_re: ?u64 = null,
    /// The client closed it. Its input that waits still goes to the session,
    /// then the channel goes.
    closed: bool = false,

    fn deinit(ch: *Channel, gpa: std.mem.Allocator) void {
        if (ch.fd >= 0) lib_posix.close(ch.fd);
        ch.in.deinit(gpa);
        ch.to_session.deinit(gpa);
        ch.q.deinit(gpa);
        gpa.free(ch.session);
        gpa.destroy(ch);
    }
};

/// A request that waits for a session: a create, a kill, or an info or a list
/// before the state came.
const Waiter = struct {
    peer: u64,
    re: u64,
    kind: enum { create, info, kill, list },
};

/// The server's connection to one session process.
const Entry = struct {
    id: []u8,
    /// -1 after a refusal: the session and the server have no common level.
    fd: i32,
    in: std.ArrayList(u8) = .empty,
    out: session.OutQueue = .{},
    connected_at: i64,
    build: []u8 = &.{},
    level: u32 = 0,
    /// Both hellos are in and the levels meet.
    greeted: bool = false,
    refused: bool = false,
    state: ?State = null,
    exit: ?session.ExitStatus = null,
    /// The `session.exit` event went out.
    announced: bool = false,
    /// The server sent `take`.
    taken: bool = false,
    /// A client sent `session.kill`: the server takes the exit status.
    killing: bool = false,
    /// When SIGKILL goes, if the session has not ended.
    kill_deadline: ?i64 = null,
    waiters: std.ArrayList(Waiter) = .empty,
    dead: bool = false,

    const State = struct {
        pid: i64,
        shell_pid: i64,
        pty_buf: [128]u8 = @splat(0),
        pty_len: usize = 0,
        cols: u16,
        rows: u16,
        clients: ?u16 = null,
    };

    /// Its state or its refusal is in, or it was silent too long.
    fn settled(e: *const Entry, now: i64) bool {
        return e.state != null or e.refused or now - e.connected_at >= settle_ms;
    }

    /// The server can say something true about it.
    fn listed(e: *const Entry) bool {
        return !e.dead and (e.state != null or e.refused);
    }

    fn info(e: *const Entry) m.Session {
        var out: m.Session = .{
            .id = e.id,
            .state = if (e.refused) .refused else if (e.exit != null) .exited else .running,
            .build = e.build,
            .level = e.level,
        };
        if (e.state) |*st| {
            out.pid = st.pid;
            out.shell_pid = st.shell_pid;
            out.pty = .{ .bytes = st.pty_buf[0..st.pty_len] };
            out.cols = st.cols;
            out.rows = st.rows;
            out.clients = st.clients;
        }
        if (e.exit) |x| {
            out.code = x.code;
            out.signal = x.signal;
        }
        return out;
    }
};

/// A `session create` child that has not exited yet. It exits when the
/// session's socket accepts connections.
const Spawn = struct {
    pid: lib_posix.pid_t,
    id: []u8,
    /// The read end of the child's stderr, for the error text.
    err_fd: i32,
    started_at: i64,
    waiters: std.ArrayList(Waiter) = .empty,
};

/// A `command.run` child. The reply goes when its stdout gave EOF and the
/// child was reaped.
const Run = struct {
    pid: lib_posix.pid_t,
    peer: u64,
    re: u64,
    /// The read end of the child's stdout. -1 after EOF.
    out_fd: i32,
    output: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    deadline: i64,
    timed_out: bool = false,
    status: ?session.ExitStatus = null,

    fn done(r: *const Run) bool {
        return r.out_fd < 0 and r.status != null;
    }
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    listen_fd: i32,
    /// The server lock (`lock_name`), held until the socket is unlinked.
    lock_fd: i32,
    epoch: u64,
    /// Counts event batches in this epoch.
    seq: u64 = 0,
    /// The last `batch_ring` batches, encoded, oldest first: what a client
    /// that lost its link gets again (`control.resume`, design/003 §7).
    batches: std.ArrayList(Batch) = .empty,
    next_peer: u64 = 1,
    peers: std.ArrayList(*Peer) = .empty,
    entries: std.ArrayList(*Entry) = .empty,
    spawns: std.ArrayList(*Spawn) = .empty,
    runs: std.ArrayList(*Run) = .empty,
    /// `session.list` requests that wait until every session settled.
    list_waiters: std.ArrayList(Waiter) = .empty,
    exe_buf: [std.fs.max_path_bytes]u8 = undefined,
    exe: [:0]const u8 = "",
    /// The client that sent `server.exit`.
    exit_peer: ?u64 = null,
    exiting: bool = false,
    idle_since: ?i64 = null,
    /// A session ended or the server started: look for server files that
    /// no session runs, once every session settled (`pruneBuilds`).
    prune_due: bool = true,

    fn init(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, fds: Bound) !Server {
        var epoch: u64 = undefined;
        io.random(std.mem.asBytes(&epoch));
        var s: Server = .{ .gpa = gpa, .io = io, .dir = dir, .listen_fd = fds.listen, .lock_fd = fds.lock, .epoch = epoch };
        _ = try selfExe(&s.exe_buf);
        return s;
    }

    fn now(s: *const Server) i64 {
        return std.Io.Timestamp.now(s.io, .awake).toMilliseconds();
    }

    fn hello(s: *const Server) m.Hello {
        return .{
            .level = m.level,
            .min_level = m.min_level,
            .build = build_options.version,
            .role = .server,
            .epoch = s.epoch,
            .caps = &.{},
        };
    }

    fn run(s: *Server) !void {
        // `init` copied the struct: the slice must point into this copy.
        const exe_len = std.mem.findScalar(u8, &s.exe_buf, 0) orelse return error.ExecutablePathUnknown;
        s.exe = s.exe_buf[0..exe_len :0];
        try signal.openSignalPipe();
        signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
        signal.installWakeHandler(@backingInt(lib_posix.SIG.CHLD));
        std.log.info("server started pid={d} epoch={x}", .{ std.c.getpid(), s.epoch });
        s.discover();

        var fds: std.ArrayList(lib_posix.pollfd) = .empty;
        defer fds.deinit(s.gpa);
        var chans: std.ArrayList(struct { peer: *Peer, ch: *Channel }) = .empty;
        defer chans.deinit(s.gpa);
        while (!s.exiting) {
            if (s.idleExpired()) return;
            fds.clearRetainingCapacity();
            try fds.append(s.gpa, .{ .fd = s.listen_fd, .events = lib_posix.POLL.IN, .revents = 0 });
            try fds.append(s.gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });
            const npeers = s.peers.items.len;
            for (s.peers.items) |p| try fds.append(s.gpa, .{ .fd = p.fd, .events = peerEvents(p), .revents = 0 });
            const nentries = s.entries.items.len;
            for (s.entries.items) |e| try fds.append(s.gpa, .{ .fd = e.fd, .events = pollEvents(&e.out), .revents = 0 });
            chans.clearRetainingCapacity();
            for (s.peers.items) |p| for (p.channels.items) |ch| if (ch.fd >= 0) {
                // A closed channel reads nothing more: it only sends its input.
                const events: i16 = if (!ch.closed) pollEvents(&ch.to_session) else if (ch.to_session.len() > 0) lib_posix.POLL.OUT else 0;
                try chans.append(s.gpa, .{ .peer = p, .ch = ch });
                try fds.append(s.gpa, .{ .fd = ch.fd, .events = events, .revents = 0 });
            };
            const nruns = s.runs.items.len;
            for (s.runs.items) |r| try fds.append(s.gpa, .{ .fd = r.out_fd, .events = lib_posix.POLL.IN, .revents = 0 });

            _ = try lib_posix.poll(fds.items, s.pollTimeout());

            if (fds.items[1].revents & lib_posix.POLL.IN != 0) {
                signal.drainSignalPipe() catch {
                    std.log.info("server: SIGTERM", .{});
                    return;
                };
                s.reapSpawns();
                s.reapRuns();
            }
            if (fds.items[0].revents & lib_posix.POLL.IN != 0) s.accept();

            for (s.peers.items[0..npeers], fds.items[2..][0..npeers]) |p, pfd| {
                if (p.dead) continue;
                if (pfd.revents & lib_posix.POLL.IN != 0) s.readPeer(p);
                if (!p.dead and pfd.revents & lib_posix.POLL.OUT != 0) s.writePeer(p);
                if (!p.dead and pfd.revents & lib_posix.POLL.IN == 0 and
                    pfd.revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) p.dead = true;
            }
            for (s.entries.items[0..nentries], fds.items[2 + npeers ..][0..nentries]) |e, pfd| {
                if (e.dead or e.fd < 0) continue;
                if (pfd.revents & lib_posix.POLL.IN != 0) s.readEntry(e);
                // A refusal closes the connection in `readEntry`.
                if (e.fd < 0) continue;
                if (!e.dead and pfd.revents & lib_posix.POLL.OUT != 0) s.writeEntry(e);
                if (!e.dead and pfd.revents & lib_posix.POLL.IN == 0 and
                    pfd.revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) s.entryGone(e);
            }
            for (chans.items, fds.items[2 + npeers + nentries ..][0..chans.items.len]) |c, pfd| {
                if (c.peer.dead or c.ch.fd < 0) continue;
                if (!c.ch.closed and pfd.revents & lib_posix.POLL.IN != 0) s.readChannel(c.peer, c.ch);
                if (c.ch.fd < 0 or c.peer.dead) continue;
                if (pfd.revents & lib_posix.POLL.OUT != 0) s.writeChannel(c.peer, c.ch);
                if (c.ch.fd >= 0 and pfd.revents & lib_posix.POLL.IN == 0 and
                    pfd.revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) s.channelGone(c.peer, c.ch);
            }
            for (s.runs.items[0..nruns], fds.items[2 + npeers + nentries + chans.items.len ..][0..nruns]) |r, pfd| {
                if (r.out_fd >= 0 and pfd.revents != 0) s.readRun(r);
            }
            s.timers();
            s.sweep();
            if (s.prune_due and s.allSettled()) {
                s.prune_due = false;
                s.pruneBuilds();
            }
        }
        // `server.exit`: the reply goes out before the server closes, for at
        // most 1 s. Other clients' queues are dropped.
        if (s.findPeer(s.exit_peer orelse return)) |p| s.flushFor(p, 1000);
    }

    fn flushFor(s: *Server, p: *Peer, ms: i64) void {
        const deadline = s.now() + ms;
        while (p.out.len() + p.control.bytes > 0 and !p.dead) {
            const left = deadline - s.now();
            if (left <= 0) return;
            var pfd = [_]lib_posix.pollfd{.{ .fd = p.fd, .events = lib_posix.POLL.OUT, .revents = 0 }};
            _ = lib_posix.poll(&pfd, @intCast(left)) catch return;
            s.writePeer(p);
        }
    }

    fn pollEvents(out: *const session.OutQueue) i16 {
        var events: i16 = lib_posix.POLL.IN;
        if (out.len() > 0) events |= lib_posix.POLL.OUT;
        return events;
    }

    fn peerEvents(p: *const Peer) i16 {
        var events: i16 = lib_posix.POLL.IN;
        if (p.pending() > 0) events |= lib_posix.POLL.OUT;
        return events;
    }

    /// The time until the next deadline, or -1 for none.
    fn pollTimeout(s: *const Server) i32 {
        const t = s.now();
        var next: ?i64 = null;
        if (s.idle_since) |since| next = since + idle_exit_ms;
        for (s.spawns.items) |sp| {
            const d = sp.started_at + spawn_ms;
            next = @min(next orelse d, d);
        }
        for (s.runs.items) |r| if (!r.timed_out) {
            next = @min(next orelse r.deadline, r.deadline);
        };
        for (s.peers.items) |p| if (!p.greeted) {
            const d = p.connected_at + hello_ms;
            next = @min(next orelse d, d);
        };
        for (s.entries.items) |e| {
            if (e.kill_deadline) |d| next = @min(next orelse d, d);
            if (!e.settled(t)) {
                const d = e.connected_at + settle_ms;
                next = @min(next orelse d, d);
            }
        }
        for (s.peers.items) |p| for (p.channels.items) |ch| if (ch.fd >= 0 and !ch.closed) {
            if (ch.flow.deadline(ch.q.stale())) |d| next = @min(next orelse d, d);
        };
        const d = next orelse return -1;
        return @intCast(std.math.clamp(d - t, 0, std.math.maxInt(i32)));
    }

    // ── Exit ────────────────────────────────────────────────────────────────

    /// True when the server has had no session, no client and no start in
    /// flight for `idle_exit_ms`, and no client waits in the backlog.
    fn idleExpired(s: *Server) bool {
        // A refused session has no connection: see if it still runs.
        if (s.peers.items.len == 0 and s.spawns.items.len == 0) s.checkRefused();
        const idle = s.peers.items.len == 0 and s.entries.items.len == 0 and s.spawns.items.len == 0 and s.runs.items.len == 0;
        if (!idle) {
            s.idle_since = null;
            return false;
        }
        const t = s.now();
        const since = s.idle_since orelse {
            s.idle_since = t;
            return false;
        };
        if (t - since < idle_exit_ms) return false;
        // A client in the backlog is accepted, and the server stays. One that
        // connects after the close gets EOF before `hello`: it starts a
        // server and connects again.
        s.accept();
        if (s.peers.items.len > 0) {
            s.idle_since = null;
            return false;
        }
        std.log.info("server: no session and no client, exiting", .{});
        s.closeListen();
        return true;
    }

    /// Closes the socket, unlinks it, then lets the server lock go. Only the
    /// holder of the lock unlinks, so the socket that goes is this server's.
    /// A start after this finds no server and starts one.
    fn closeListen(s: *Server) void {
        if (s.listen_fd < 0) return;
        lib_posix.close(s.listen_fd);
        s.listen_fd = -1;
        session.unlinkSocket(s.dir, socket_name);
        lib_posix.close(s.lock_fd);
        s.lock_fd = -1;
    }

    /// Closes everything. Sessions see a client leave and keep running.
    fn shutdown(s: *Server) void {
        s.closeListen();
        for (s.peers.items) |p| {
            lib_posix.close(p.fd);
            for (p.channels.items) |ch| if (ch.fd >= 0) lib_posix.close(ch.fd);
        }
        for (s.entries.items) |e| if (e.fd >= 0) lib_posix.close(e.fd);
        for (s.runs.items) |r| lib_posix.kill(-r.pid, lib_posix.SIG.KILL) catch {};
    }

    // ── Sessions ────────────────────────────────────────────────────────────

    /// Connects to every session socket in the directory. A socket that
    /// refuses the connection is left as it is: a session that starts with
    /// that name removes it.
    fn discover(s: *Server) void {
        var dir = std.Io.Dir.openDirAbsolute(s.io, s.dir, .{ .iterate = true }) catch return;
        defer dir.close(s.io);
        var it = dir.iterate();
        while (it.next(s.io) catch null) |entry| {
            if (entry.kind != .unix_domain_socket or !session.validName(entry.name)) continue;
            s.connectEntry(entry.name) catch |err|
                std.log.info("server: session {s} does not answer: {s}", .{ entry.name, @errorName(err) });
        }
    }

    fn connectEntry(s: *Server, id: []const u8) !void {
        const path = try socket.getSocketPath(s.gpa, s.dir, id);
        defer s.gpa.free(path);
        const fd = try connectNonblocking(path);
        errdefer lib_posix.close(fd);
        const e = try s.gpa.create(Entry);
        errdefer s.gpa.destroy(e);
        e.* = .{ .id = try s.gpa.dupe(u8, id), .fd = fd, .connected_at = s.now() };
        errdefer s.gpa.free(e.id);
        try s.entries.append(s.gpa, e);
        s.sendEntryControl(e, s.hello());
    }

    fn findEntry(s: *Server, id: []const u8) ?*Entry {
        for (s.entries.items) |e| if (!e.dead and std.mem.eql(u8, e.id, id)) return e;
        return null;
    }

    fn readEntry(s: *Server, e: *Entry) void {
        var buf: [16 * 1024]u8 = undefined;
        const n = lib_posix.read(e.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return s.entryGone(e),
        };
        if (n == 0) return s.entryGone(e);
        e.in.appendSlice(s.gpa, buf[0..n]) catch return s.entryGone(e);

        var used: usize = 0;
        defer if (!e.dead) e.in.replaceRangeAssumeCapacity(0, used, &.{});
        while (!e.dead and e.fd >= 0) {
            const rest = e.in.items[used..];
            if (rest.len >= frame.header_len and std.mem.readInt(u32, rest[0..4], .little) > frame_max)
                return s.brokenEntry(e, "a frame over 1 MiB");
            const parsed = (frame.parse(rest) catch return s.brokenEntry(e, "a bad frame")) orelse break;
            used += parsed.len;
            s.handleEntryFrame(e, parsed.frame);
        }
    }

    fn handleEntryFrame(s: *Server, e: *Entry, f: frame.Frame) void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (f.channel == frame.control_channel) {
            const msg = m.decodeControl(arena, f.body) catch return s.brokenEntry(e, "a bad message");
            switch (msg) {
                .hello => |h| {
                    if (e.greeted or e.refused) return;
                    e.build = s.gpa.dupe(u8, buildName(h.build)) catch return s.entryGone(e);
                    e.level = h.level;
                    switch (m.negotiate(s.hello(), h)) {
                        .speak => e.greeted = true,
                        .refuse => |r| {
                            std.log.info("server: session {s} speaks level {d}, refused", .{ e.id, h.level });
                            // One try: a session that already left needs no refusal.
                            s.sendEntryControl(e, r);
                            _ = lib_posix.write(e.fd, e.out.buf.items) catch {};
                            s.refuseEntry(e);
                        },
                    }
                },
                .refuse => |r| {
                    std.log.info("server: session {s} refused the server: {s}", .{ e.id, r.reason });
                    s.refuseEntry(e);
                },
                else => {},
            }
            return;
        }
        if (!e.greeted or f.channel != m.pane_channel or f.kind != .msg) return;
        const msg = msgpack.decodeSlice(m.PaneMessage, arena, f.body) catch return s.brokenEntry(e, "a bad message");
        if (std.mem.eql(u8, msg.t, m.State.name)) {
            const st = m.decodePane(m.State, arena, msg) catch return s.brokenEntry(e, "a bad state");
            // The server may SIGKILL this pid. 0, 1 and -1 would reach a
            // process group or every process of the user, and a session's pid
            // never changes: fail closed.
            if (!validPid(st.pid) or !validPid(st.shell_pid))
                return s.brokenEntry(e, "a pid that the server cannot signal");
            if (e.state) |old| if (old.pid != st.pid or old.shell_pid != st.shell_pid)
                return s.brokenEntry(e, "a pid other than its first");
            const first = e.state == null;
            var state: Entry.State = .{ .pid = st.pid, .shell_pid = st.shell_pid, .cols = st.cols, .rows = st.rows, .clients = st.clients };
            state.pty_len = @min(st.pty.bytes.len, state.pty_buf.len);
            @memcpy(state.pty_buf[0..state.pty_len], st.pty.bytes[0..state.pty_len]);
            e.state = state;
            if (first) s.settle(e);
        } else if (std.mem.eql(u8, msg.t, m.Exit.name)) {
            const x = m.decodePane(m.Exit, arena, msg) catch return s.brokenEntry(e, "a bad exit");
            if (e.exit != null) return;
            e.exit = .{ .code = x.code, .signal = x.signal };
            std.log.info("server: session {s} exited code={?d} signal={?d}", .{ e.id, x.code, x.signal });
            s.announce(e);
            if (e.killing) s.take(e);
        }
        // `lead` and later messages: not the server's.
    }

    /// The session's state is in: the requests that wait for it get it.
    fn settle(s: *Server, e: *Entry) void {
        const waiters = e.waiters.toOwnedSlice(s.gpa) catch return;
        defer s.gpa.free(waiters);
        for (waiters) |w| switch (w.kind) {
            .create => s.reply(w.peer, w.re, m.SessionCreate, .{ .session = e.info() }),
            .info => s.reply(w.peer, w.re, m.SessionInfo, .{ .session = e.info() }),
            .kill, .list => s.wait(&e.waiters, w),
        };
        s.answerLists();
    }

    /// A session that breaks the protocol. Its connection closes, and it is
    /// listed as `refused`: the server can say nothing true of it. No exit
    /// goes out, because nothing says that it ended.
    fn brokenEntry(s: *Server, e: *Entry, what: []const u8) void {
        std.log.warn("server: session {s} sent {s}, closed", .{ e.id, what });
        s.refuseEntry(e);
    }

    fn refuseEntry(s: *Server, e: *Entry) void {
        e.refused = true;
        e.state = null;
        lib_posix.close(e.fd);
        e.fd = -1;
        s.settle(e);
    }

    fn announce(s: *Server, e: *Entry) void {
        if (e.announced) return;
        e.announced = true;
        const x = e.exit orelse session.ExitStatus{};
        s.emit(m.SessionExit, .{ .id = e.id, .code = x.code, .signal = x.signal });
    }

    fn take(s: *Server, e: *Entry) void {
        if (e.taken) return;
        e.taken = true;
        s.sendEntryPane(e, m.Take, .{});
    }

    /// The session's connection closed: the session process ended.
    fn entryGone(s: *Server, e: *Entry) void {
        if (e.dead) return;
        e.dead = true;
        s.prune_due = true;
        if (e.state != null) s.announce(e);
        std.log.info("server: session {s} is gone", .{e.id});
        for (e.waiters.items) |w| switch (w.kind) {
            .kill => s.reply(w.peer, w.re, m.SessionKill, .{}),
            .create => s.replyError(w.peer, w.re, "start_failed", "The session ended before it was ready."),
            .info, .list => s.replyError(w.peer, w.re, "not_found", "No session has this id."),
        };
        e.waiters.clearRetainingCapacity();
        s.answerLists();
    }

    fn timers(s: *Server) void {
        const t = s.now();
        for (s.entries.items) |e| {
            if (e.dead) continue;
            if (e.kill_deadline) |d| if (t >= d) {
                std.log.warn("server: session {s} did not end, SIGKILL", .{e.id});
                // The pid is the first that the session reported (`validPid`).
                // The pty closes with it, and the kernel hangs up the shell.
                if (e.state) |st| lib_posix.kill(@intCast(st.pid), lib_posix.SIG.KILL) catch {};
                e.kill_deadline = null;
            };
            if (!e.settled(t)) continue;
            // A session that never answered: an info that waits for it gets
            // nothing true to show.
            if (e.state == null and !e.refused and e.waiters.items.len > 0) {
                const waiters = e.waiters.toOwnedSlice(s.gpa) catch continue;
                defer s.gpa.free(waiters);
                for (waiters) |w| switch (w.kind) {
                    .create => s.replyError(w.peer, w.re, "start_failed", "The session does not answer."),
                    .info, .list => s.replyError(w.peer, w.re, "not_found", "The session does not answer."),
                    .kill => s.wait(&e.waiters, w),
                };
            }
        }
        for (s.peers.items) |p| for (p.channels.items) |ch| {
            if (ch.fd < 0 or ch.closed) continue;
            if (ch.flow.mustSkip(ch.q.stale(), t)) s.skip(ch, t) else if (ch.flow.mustAskAgain(t)) s.askSnapshot(ch, t);
        };
        for (s.peers.items) |p| if (!p.greeted and !p.dead and t - p.connected_at >= hello_ms) {
            std.log.info("server: a client sent no hello, closed", .{});
            p.dead = true;
        };
        for (s.spawns.items) |sp| if (t >= sp.started_at + spawn_ms and sp.started_at >= 0) {
            std.log.warn("server: session {s} start takes too long, SIGKILL", .{sp.id});
            lib_posix.kill(sp.pid, lib_posix.SIG.KILL) catch {};
            // Once: SIGCHLD reaps it, and the create fails.
            sp.started_at = -1;
        };
        for (s.runs.items) |r| if (!r.timed_out and t >= r.deadline) {
            std.log.warn("server: a command ran too long, SIGKILL", .{});
            r.timed_out = true;
            // The process group: a child of the command can hold stdout too.
            lib_posix.kill(-r.pid, lib_posix.SIG.KILL) catch {};
            if (r.out_fd >= 0) lib_posix.close(r.out_fd);
            r.out_fd = -1;
        };
        s.finishRuns();
        s.answerLists();
    }

    fn writeEntry(s: *Server, e: *Entry) void {
        if (e.out.len() == 0) return;
        const n = lib_posix.write(e.fd, e.out.buf.items) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return s.entryGone(e),
        };
        e.out.consume(n);
    }

    fn sendEntryControl(s: *Server, e: *Entry, value: anytype) void {
        const body = msgpack.encodeAlloc(s.gpa, value) catch return;
        defer s.gpa.free(body);
        e.out.append(s.gpa, frame.control_channel, .msg, body, false) catch return s.entryGone(e);
    }

    fn sendEntryPane(s: *Server, e: *Entry, comptime M: type, value: M) void {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        m.encodePane(&out.writer, M, value) catch return;
        e.out.append(s.gpa, m.pane_channel, .msg, out.written(), false) catch return s.entryGone(e);
    }

    // ── Starting a session ──────────────────────────────────────────────────

    /// Forks and execs this binary as `session`. That command starts the
    /// session process (setsid, and on macOS the disclaim, `session.zig`)
    /// and exits when its socket accepts connections.
    /// The size is cut to `session.max_cells`, as a session cuts a resize.
    fn spawn(s: *Server, id: []const u8, args: m.SessionCreate.Args) !*Spawn {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        try argv.append(arena, s.exe.ptr);
        try argv.append(arena, "session");
        try argv.append(arena, "--cols");
        try argv.append(arena, (try std.fmt.allocPrintSentinel(arena, "{d}", .{@min(args.cols, session.max_cells)}, 0)).ptr);
        try argv.append(arena, "--rows");
        try argv.append(arena, (try std.fmt.allocPrintSentinel(arena, "{d}", .{@min(args.rows, session.max_cells)}, 0)).ptr);
        if (args.cwd) |cwd| {
            try argv.append(arena, "--cwd");
            try argv.append(arena, (try arena.dupeSentinel(u8, cwd.bytes, 0)).ptr);
        }
        try argv.append(arena, (try arena.dupeSentinel(u8, id, 0)).ptr);
        if (args.command) |command| {
            try argv.append(arena, "--");
            for (command) |arg| try argv.append(arena, (try arena.dupeSentinel(u8, arg.bytes, 0)).ptr);
        }
        try argv.append(arena, null);
        const envp = try s.sessionEnv(arena, args.env);

        const pipe = try lib_posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        errdefer lib_posix.close(pipe[0]);
        const sp = try s.gpa.create(Spawn);
        errdefer s.gpa.destroy(sp);
        sp.* = .{ .pid = 0, .id = try s.gpa.dupe(u8, id), .err_fd = pipe[0], .started_at = s.now() };
        errdefer s.gpa.free(sp.id);
        try s.spawns.append(s.gpa, sp);
        errdefer _ = s.spawns.pop();

        const pid = lib_posix.fork() catch |err| {
            lib_posix.close(pipe[1]);
            return err;
        };
        if (pid == 0) {
            // The child: stderr to the pipe, then this binary again.
            lib_posix.dup2(pipe[1], lib_posix.STDERR_FILENO) catch std.c._exit(127);
            _ = std.c.execve(s.exe.ptr, @ptrCast(argv.items.ptr), envp);
            std.c._exit(127);
        }
        lib_posix.close(pipe[1]);
        sp.pid = pid;
        std.log.info("server: starting session {s} pid={d}", .{ id, pid });
        return sp;
    }

    /// The environment of a new session: the client's entries, or the
    /// server's own environment when it sent none. The runtime directory is
    /// always the server's, so that the session listens where the server
    /// looks.
    fn sessionEnv(s: *const Server, arena: std.mem.Allocator, env: ?[]const msgpack.Bin) ![*:null]const ?[*:0]const u8 {
        const entries = env orelse return @ptrCast(std.c.environ);
        var list: std.ArrayList(?[*:0]const u8) = .empty;
        for (entries) |entry| {
            if (std.mem.startsWith(u8, entry.bytes, runtime.dir_env ++ "=")) continue;
            try list.append(arena, (try arena.dupeSentinel(u8, entry.bytes, 0)).ptr);
        }
        try list.append(arena, (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ runtime.dir_env, s.dir }, 0)).ptr);
        try list.append(arena, null);
        return @ptrCast(list.items.ptr);
    }

    /// Reaps the `session` children that exited. A session process is their
    /// child, and it leaves. The server's only other children are the
    /// commands of `command.run` (`reapRuns`).
    fn reapSpawns(s: *Server) void {
        var i: usize = 0;
        while (i < s.spawns.items.len) {
            const sp = s.spawns.items[i];
            const res = lib_posix.waitpid(sp.pid, std.c.W.NOHANG);
            if (res.pid != sp.pid) {
                i += 1;
                continue;
            }
            _ = s.spawns.orderedRemove(i);
            s.spawnDone(sp, session.ExitStatus.fromWait(res.status));
            lib_posix.close(sp.err_fd);
            sp.waiters.deinit(s.gpa);
            s.gpa.free(sp.id);
            s.gpa.destroy(sp);
        }
    }

    /// The child exited. With 0, the session listens. Else a session of
    /// this id may already run (one that the server did not start): the
    /// server uses it, so that the same id finds the same session.
    fn spawnDone(s: *Server, sp: *Spawn, status: session.ExitStatus) void {
        if (s.connectEntry(sp.id)) |_| {
            const e = s.findEntry(sp.id).?;
            e.waiters.appendSlice(s.gpa, sp.waiters.items) catch
                for (sp.waiters.items) |w| s.replyError(w.peer, w.re, "start_failed", "The server is out of memory.");
            return;
        } else |err| if (status.code == 0)
            std.log.warn("server: session {s} started but does not answer: {s}", .{ sp.id, @errorName(err) });
        var buf: [1024]u8 = undefined;
        const n = lib_posix.read(sp.err_fd, &buf) catch 0;
        const text = errorText(buf[0..n]);
        std.log.warn("server: session {s} did not start: {s}", .{ sp.id, text });
        for (sp.waiters.items) |w| s.replyError(w.peer, w.re, "start_failed", text);
    }

    // ── Clients ─────────────────────────────────────────────────────────────

    /// Accepts every client in the backlog.
    fn accept(s: *Server) void {
        var n: usize = 0;
        while (n < max_clients and s.acceptOne()) : (n += 1) {}
    }

    /// False when the backlog is empty.
    fn acceptOne(s: *Server) bool {
        const fd = lib_posix.accept(s.listen_fd, null, null, lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC) catch return false;
        s.addPeer(fd);
        return true;
    }

    fn addPeer(s: *Server, fd: i32) void {
        if (!runtime.allowPeer(runtime.peerUid(fd), std.c.getuid())) {
            std.log.warn("server: refused a peer of another user", .{});
            lib_posix.close(fd);
            return;
        }
        if (s.peers.items.len >= max_clients) {
            std.log.warn("server: {d} clients, a new one closed", .{max_clients});
            lib_posix.close(fd);
            return;
        }
        // Output that waits in the kernel goes before channel 0, whatever
        // order the relay chose: keep that buffer small (Linux gives about
        // 200 KiB by default, macOS 8 KiB).
        const sndbuf: c_int = peer_sndbuf;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDBUF, std.mem.asBytes(&sndbuf), @sizeOf(c_int));
        const p = s.gpa.create(Peer) catch {
            lib_posix.close(fd);
            return;
        };
        p.* = .{ .id = s.next_peer, .fd = fd, .connected_at = s.now() };
        s.next_peer += 1;
        s.peers.append(s.gpa, p) catch {
            s.gpa.destroy(p);
            lib_posix.close(fd);
            return;
        };
        s.sendControl(p, s.hello());
    }

    fn findPeer(s: *Server, id: u64) ?*Peer {
        for (s.peers.items) |p| if (p.id == id and !p.dead) return p;
        return null;
    }

    fn readPeer(s: *Server, p: *Peer) void {
        var buf: [16 * 1024]u8 = undefined;
        const n = lib_posix.read(p.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                p.dead = true;
                return;
            },
        };
        if (n == 0) {
            p.dead = true;
            return;
        }
        p.in.appendSlice(s.gpa, buf[0..n]) catch {
            p.dead = true;
            return;
        };

        var used: usize = 0;
        defer if (!p.dead) p.in.replaceRangeAssumeCapacity(0, used, &.{});
        while (!p.dead and !p.closing and !s.exiting) {
            const rest = p.in.items[used..];
            if (rest.len >= frame.header_len and std.mem.readInt(u32, rest[0..4], .little) > frame_max) {
                p.dead = true;
                return;
            }
            const parsed = (frame.parse(rest) catch {
                p.dead = true;
                return;
            }) orelse break;
            used += parsed.len;
            s.handlePeerFrame(p, parsed.frame);
        }
    }

    fn handlePeerFrame(s: *Server, p: *Peer, f: frame.Frame) void {
        if (f.channel != frame.control_channel) {
            if (p.greeted) s.relayToSession(p, f);
            return;
        }
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const msg = m.decodeControl(arena, f.body) catch {
            p.dead = true;
            return;
        };

        if (!p.greeted) {
            const theirs = switch (msg) {
                .hello => |h| h,
                else => {
                    p.dead = true;
                    return;
                },
            };
            switch (m.negotiate(s.hello(), theirs)) {
                .refuse => |r| {
                    std.log.info("server: refused a {s} at level {d}: {s}", .{ @tagName(theirs.role), theirs.level, r.reason });
                    s.sendControl(p, r);
                    p.closing = true;
                },
                .speak => p.greeted = true,
            }
            return;
        }
        switch (msg) {
            .request => |req| s.handleRequest(p, arena, req),
            else => {},
        }
    }

    fn handleRequest(s: *Server, p: *Peer, arena: std.mem.Allocator, req: m.Request) void {
        inline for (m.methods) |M| {
            if (std.mem.eql(u8, req.m, M.name)) {
                // Every connection to this socket is `local` (design/006 §2).
                if (!m.maySend(M, .local)) {
                    std.log.warn("server: {s} from a local client, refused", .{M.name});
                    return s.replyError(p.id, req.id, "forbidden", "This connection may not send this request.");
                }
                const args = m.decodeArgs(M, arena, req) catch
                    return s.replyError(p.id, req.id, "invalid_args", "The arguments do not decode.");
                return s.call(M, p, req.id, args);
            }
        }
        s.replyError(p.id, req.id, "unknown_method", "The server has no such method.");
    }

    fn call(s: *Server, comptime M: type, p: *Peer, re: u64, args: M.Args) void {
        switch (M) {
            m.SessionCreate => s.create(p, re, args),
            m.SessionList => {
                if (s.allSettled()) return s.replyList(p.id, re);
                s.wait(&s.list_waiters, .{ .peer = p.id, .re = re, .kind = .list });
            },
            m.SessionInfo => {
                const e = s.findEntry(args.id) orelse
                    return s.replyError(p.id, re, "not_found", "No session has this id.");
                if (e.listed()) return s.reply(p.id, re, m.SessionInfo, .{ .session = e.info() });
                s.wait(&e.waiters, .{ .peer = p.id, .re = re, .kind = .info });
            },
            m.SessionKill => s.kill(p, re, args.id),
            m.ServerExit => {
                std.log.info("server: server.exit", .{});
                // Unlinked before the reply, so that a start that follows the
                // reply finds no server (design/002).
                s.closeListen();
                s.reply(p.id, re, m.ServerExit, .{});
                s.exit_peer = p.id;
                s.exiting = true;
            },
            m.ControlResume => s.resumeControl(p, re, args),
            m.ChannelOpen => s.openChannel(p, re, args.session),
            m.ChannelClose => {
                const ch = p.findChannel(args.channel) orelse
                    return s.replyError(p.id, re, "not_found", "No channel has this number.");
                ch.closed = true;
                ch.q.deinit(s.gpa);
                s.reply(p.id, re, m.ChannelClose, .{});
            },
            m.ChannelPause => {
                const ch = p.findChannel(args.channel) orelse
                    return s.replyError(p.id, re, "not_found", "No channel has this number.");
                ch.flow.paused = true;
                const open_kept = ch.q.dropStale(s.gpa);
                ch.flow.discard_snapshot = ch.flow.in_snapshot and !open_kept;
                s.reply(p.id, re, m.ChannelPause, .{});
            },
            m.ChannelResume => {
                const ch = p.findChannel(args.channel) orelse
                    return s.replyError(p.id, re, "not_found", "No channel has this number.");
                if (ch.flow.paused) {
                    ch.flow.paused = false;
                    s.askSnapshot(ch, s.now());
                }
                s.reply(p.id, re, m.ChannelResume, .{});
            },
            m.Ping => s.reply(p.id, re, m.Ping, .{}),
            m.CommandRun => s.runCommand(p, re, args),
            else => s.replyError(p.id, re, "unknown_method", "The server has no such method."),
        }
    }

    fn create(s: *Server, p: *Peer, re: u64, args: m.SessionCreate.Args) void {
        if (!session.validName(args.id))
            return s.replyError(p.id, re, "invalid_args", "A session id can have only letters, digits, '-', '_' and '.'. It cannot start with '.' or '-'.");
        if (args.cwd) |cwd| if (cwd.bytes.len == 0 or cwd.bytes[0] != '/' or std.mem.findScalar(u8, cwd.bytes, 0) != null)
            return s.replyError(p.id, re, "invalid_args", "The folder must be an absolute path.");
        if (args.command) |command| for (command) |arg| if (std.mem.findScalar(u8, arg.bytes, 0) != null)
            return s.replyError(p.id, re, "invalid_args", "A command argument cannot hold a NUL byte.");
        if (args.env) |env| for (env) |entry| if (std.mem.findScalar(u8, entry.bytes, 0) != null or std.mem.findScalar(u8, entry.bytes, '=') == null)
            return s.replyError(p.id, re, "invalid_args", "An environment entry must be NAME=value with no NUL byte.");
        if (args.cols == 0 or args.rows == 0)
            return s.replyError(p.id, re, "invalid_args", "The size must be at least 1 by 1.");
        const waiter: Waiter = .{ .peer = p.id, .re = re, .kind = .create };
        // The same id again: the session that the first request started.
        if (s.findEntry(args.id)) |e| {
            // A session whose shell exited is not given out as a new one:
            // the client ends it (`session.kill`) and asks again.
            if (e.exit != null) return s.replyError(p.id, re, "exited", "The session's shell exited. End the session first.");
            if (e.listed()) return s.reply(p.id, re, m.SessionCreate, .{ .session = e.info() });
            return s.wait(&e.waiters, waiter);
        }
        for (s.spawns.items) |sp| if (std.mem.eql(u8, sp.id, args.id)) return s.wait(&sp.waiters, waiter);
        const sp = s.spawn(args.id, args) catch |err| {
            std.log.warn("server: cannot start session {s}: {s}", .{ args.id, @errorName(err) });
            return s.replyError(p.id, re, "start_failed", "The server cannot start a process.");
        };
        s.wait(&sp.waiters, waiter);
    }

    // ── Running a command ───────────────────────────────────────────────────

    fn runCommand(s: *Server, p: *Peer, re: u64, args: m.CommandRun.Args) void {
        if (args.argv.len == 0 or args.argv[0].bytes.len == 0 or args.argv[0].bytes[0] != '/')
            return s.replyError(p.id, re, "invalid_args", "The program must be an absolute path.");
        for (args.argv) |arg| if (std.mem.findScalar(u8, arg.bytes, 0) != null)
            return s.replyError(p.id, re, "invalid_args", "A command argument cannot hold a NUL byte.");
        if (args.cwd) |cwd| if (cwd.bytes.len == 0 or cwd.bytes[0] != '/' or std.mem.findScalar(u8, cwd.bytes, 0) != null)
            return s.replyError(p.id, re, "invalid_args", "The folder must be an absolute path.");
        if (args.timeout_ms == 0 or args.timeout_ms > run_timeout_max_ms)
            return s.replyError(p.id, re, "invalid_args", "The time limit must be from 1 ms to 60 s.");
        if (s.runs.items.len >= max_runs)
            return s.replyError(p.id, re, "busy", "Too many commands run now.");
        s.startRun(p.id, re, args) catch |err| {
            std.log.warn("server: cannot run a command: {s}", .{@errorName(err)});
            s.replyError(p.id, re, "start_failed", "The server cannot start a process.");
        };
    }

    /// Forks the command in a process group of its own, with stdout on a
    /// pipe. stdin and stderr are the server's `/dev/null` (`detachStdio`).
    fn startRun(s: *Server, peer: u64, re: u64, args: m.CommandRun.Args) !void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        for (args.argv) |arg| try argv.append(arena, (try arena.dupeSentinel(u8, arg.bytes, 0)).ptr);
        try argv.append(arena, null);
        const cwd: ?[*:0]const u8 = if (args.cwd) |c| (try arena.dupeSentinel(u8, c.bytes, 0)).ptr else null;

        // Only the read end is non-blocking: a command that writes to a
        // non-blocking stdout fails on a full pipe.
        const pipe = try lib_posix.pipe2(.{ .CLOEXEC = true });
        errdefer lib_posix.close(pipe[0]);
        errdefer lib_posix.close(pipe[1]);
        const flags = try lib_posix.fcntl(pipe[0], lib_posix.F.GETFL, 0);
        _ = try lib_posix.fcntl(pipe[0], lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
        const r = try s.gpa.create(Run);
        errdefer s.gpa.destroy(r);
        r.* = .{ .pid = 0, .peer = peer, .re = re, .out_fd = pipe[0], .deadline = s.now() + args.timeout_ms };
        try s.runs.append(s.gpa, r);
        errdefer _ = s.runs.pop();

        // `main` ignores SIGPIPE, and that survives exec: the command gets
        // the default, as a session's shell does (`daemonize.zig`).
        const dfl: lib_posix.Sigaction = .{
            .handler = .{ .handler = lib_posix.SIG.DFL },
            .mask = lib_posix.sigemptyset(),
            .flags = 0,
        };
        const pid = try lib_posix.fork();
        if (pid == 0) {
            lib_posix.sigaction(lib_posix.SIG.PIPE, &dfl, null);
            _ = std.c.setpgid(0, 0);
            lib_posix.dup2(pipe[1], lib_posix.STDOUT_FILENO) catch std.c._exit(127);
            if (cwd) |c| if (std.c.chdir(c) != 0) std.c._exit(126);
            _ = std.c.execve(argv.items[0].?, @ptrCast(argv.items.ptr), @ptrCast(std.c.environ));
            std.c._exit(127);
        }
        lib_posix.close(pipe[1]);
        r.pid = pid;
        // The parent too, so that a SIGKILL at the deadline finds the group
        // even before the child ran its own `setpgid`.
        _ = std.c.setpgid(pid, pid);
    }

    /// Reads what the command wrote. Past `run_output_max` it reads and
    /// drops, so that the command never blocks on a full pipe.
    fn readRun(s: *Server, r: *Run) void {
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = lib_posix.read(r.out_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => 0,
            };
            if (n == 0) {
                lib_posix.close(r.out_fd);
                r.out_fd = -1;
                // `timers` answers it: the poll loop still walks `runs`.
                return;
            }
            const room = run_output_max - r.output.items.len;
            if (n > room) r.truncated = true;
            r.output.appendSlice(s.gpa, buf[0..@min(n, room)]) catch {
                r.truncated = true;
            };
        }
    }

    fn reapRuns(s: *Server) void {
        for (s.runs.items) |r| {
            if (r.status != null) continue;
            const res = lib_posix.waitpid(r.pid, std.c.W.NOHANG);
            if (res.pid == r.pid) r.status = session.ExitStatus.fromWait(res.status);
        }
    }

    /// Answers and frees each command that ended. Only `timers` calls it,
    /// after the poll loop walked `runs`.
    fn finishRuns(s: *Server) void {
        var i: usize = 0;
        while (i < s.runs.items.len) {
            const r = s.runs.items[i];
            if (!r.done()) {
                i += 1;
                continue;
            }
            _ = s.runs.orderedRemove(i);
            if (r.timed_out) {
                s.replyError(r.peer, r.re, "timeout", "The command did not end in time.");
            } else {
                const st = r.status.?;
                s.reply(r.peer, r.re, m.CommandRun, .{
                    .output = .{ .bytes = r.output.items },
                    .truncated = r.truncated,
                    .code = st.code,
                    .signal = st.signal,
                });
            }
            r.output.deinit(s.gpa);
            s.gpa.destroy(r);
        }
    }

    fn kill(s: *Server, p: *Peer, re: u64, id: []const u8) void {
        const e = s.findEntry(id) orelse return s.replyError(p.id, re, "not_found", "No session has this id.");
        if (e.refused) return s.replyError(p.id, re, "refused", "The session runs a build that this server cannot speak to.");
        const st = e.state orelse return s.replyError(p.id, re, "starting", "The session is not ready.");
        s.wait(&e.waiters, .{ .peer = p.id, .re = re, .kind = .kill });
        if (e.killing) return;
        e.killing = true;
        e.kill_deadline = s.now() + kill_grace_ms;
        if (e.exit != null) {
            s.take(e);
        } else {
            // The session ends its shell itself: SIGHUP to the shell's process
            // group, then SIGKILL (`Session.end`). It alone knows if the shell
            // was reaped, so it never signals a pid that is used again.
            std.log.info("server: kill session {s} pid={d}", .{ e.id, st.pid });
            s.sendEntryPane(e, m.End, .{});
        }
    }

    /// Adds a waiter, or answers it at once when there is no memory for it.
    fn wait(s: *Server, list: *std.ArrayList(Waiter), w: Waiter) void {
        list.append(s.gpa, w) catch s.replyError(w.peer, w.re, "unavailable", "The server is out of memory.");
    }

    /// A refused session has no connection. Each list and each idle check
    /// connects to its socket again, so that one that ended is not listed.
    fn checkRefused(s: *Server) void {
        for (s.entries.items) |e| {
            if (!e.refused or e.dead) continue;
            const path = socket.getSocketPath(s.gpa, s.dir, e.id) catch continue;
            defer s.gpa.free(path);
            if (connectNonblocking(path)) |fd| lib_posix.close(fd) else |err| switch (err) {
                error.WouldBlock => {},
                else => e.dead = true,
            }
        }
    }

    fn allSettled(s: *const Server) bool {
        const t = s.now();
        for (s.entries.items) |e| if (!e.dead and !e.settled(t)) return false;
        return true;
    }

    fn answerLists(s: *Server) void {
        if (s.list_waiters.items.len == 0 or !s.allSettled()) return;
        const waiters = s.list_waiters.toOwnedSlice(s.gpa) catch return;
        defer s.gpa.free(waiters);
        for (waiters) |w| s.replyList(w.peer, w.re);
    }

    fn replyList(s: *Server, peer: u64, re: u64) void {
        s.checkRefused();
        var list: std.ArrayList(m.Session) = .empty;
        defer list.deinit(s.gpa);
        for (s.entries.items) |e| if (e.listed()) list.append(s.gpa, e.info()) catch return;
        std.mem.sortUnstable(m.Session, list.items, {}, struct {
            fn less(_: void, a: m.Session, b: m.Session) bool {
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.less);
        s.reply(peer, re, m.SessionList, .{ .sessions = list.items });
    }

    fn reply(s: *Server, peer: u64, re: u64, comptime M: type, result: M.Result) void {
        const p = s.findPeer(peer) orelse return;
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        m.encodeResult(&out.writer, re, M, result) catch return;
        s.sendBody(p, out.written());
    }

    fn replyError(s: *Server, peer: u64, re: u64, code: []const u8, message: []const u8) void {
        const p = s.findPeer(peer) orelse return;
        s.sendControl(p, m.Response{ .re = re, .err = .{ .code = code, .message = message } });
    }

    /// One event is one batch: one consistent state (design/003 §5).
    fn emit(s: *Server, comptime E: type, value: E) void {
        const args = msgpack.encodeAlloc(s.gpa, value) catch return;
        defer s.gpa.free(args);
        s.seq += 1;
        const ev = [_]m.Event{.{ .e = E.name, .a = .{ .bytes = args } }};
        const batch: m.EventBatch = .{ .seq = s.seq, .ev = &ev };
        const body = msgpack.encodeAlloc(s.gpa, batch) catch return;
        const kept = s.keepBatch(body);
        defer if (!kept) s.gpa.free(body);
        for (s.peers.items) |p| if (p.greeted and !p.dead) s.sendBody(p, body);
    }

    /// Keeps the batch for `control.resume`, and gives up the oldest ones.
    /// The ring owns `body` when this returns true. On an allocation failure
    /// the ring is emptied, so that a resume never skips a batch.
    fn keepBatch(s: *Server, body: []u8) bool {
        s.batches.append(s.gpa, .{ .seq = s.seq, .body = body }) catch {
            for (s.batches.items) |b| s.gpa.free(b.body);
            s.batches.clearRetainingCapacity();
            return false;
        };
        while (s.batches.items.len > batch_ring) {
            s.gpa.free(s.batches.orderedRemove(0).body);
        }
        return true;
    }

    /// `control.resume`: sends the batches after `args.seq` when the epoch is
    /// this server's and the ring still holds every one of them.
    fn resumeControl(s: *Server, p: *Peer, re: u64, args: m.ControlResume.Args) void {
        const held = s.batches.items;
        const complete = args.epoch == s.epoch and args.seq <= s.seq and
            (args.seq == s.seq or (held.len > 0 and held[0].seq <= args.seq + 1));
        if (complete) {
            for (held) |b| if (b.seq > args.seq) s.sendBody(p, b.body);
        }
        s.reply(p.id, re, m.ControlResume, .{ .replayed = complete, .seq = s.seq });
    }

    fn sendControl(s: *Server, p: *Peer, value: anytype) void {
        const body = msgpack.encodeAlloc(s.gpa, value) catch return;
        defer s.gpa.free(body);
        s.sendBody(p, body);
    }

    fn sendBody(s: *Server, p: *Peer, body: []const u8) void {
        p.control.push(s.gpa, frame.control_channel, .msg, body, s.now(), .message) catch {
            p.dead = true;
            return;
        };
        s.checkPeerCap(p);
    }

    fn checkPeerCap(s: *Server, p: *Peer) void {
        _ = s;
        if (p.kept() > session.client_hard_cap) {
            std.log.warn("server: client fd={d} does not read, closed", .{p.fd});
            p.dead = true;
        }
    }

    fn writePeer(s: *Server, p: *Peer) void {
        if (p.out.len() == 0) {
            var queues: std.ArrayList(*relay.Queue) = .empty;
            defer queues.deinit(s.gpa);
            for (p.channels.items) |ch| queues.append(s.gpa, &ch.q) catch {
                p.dead = true;
                return;
            };
            relay.fill(s.gpa, &p.out.buf, &p.control, queues.items, &p.turn) catch {
                p.dead = true;
                return;
            };
            // Whole frames, none of which may be dropped.
            p.out.keep_end = p.out.len();
        }
        if (p.out.len() > 0) {
            const n = lib_posix.write(p.fd, p.out.buf.items) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    p.dead = true;
                    return;
                },
            };
            p.out.consume(n);
        }
        if (p.pending() == 0 and p.closing) p.dead = true;
    }

    // ── The relay (relay.zig) ───────────────────────────────────────────────

    fn openChannel(s: *Server, p: *Peer, re: u64, id: []const u8) void {
        const e = s.findEntry(id) orelse return s.replyError(p.id, re, "not_found", "No session has this id.");
        if (e.refused) return s.replyError(p.id, re, "refused", "The session runs a build that this server cannot speak to.");
        if (e.state == null) return s.replyError(p.id, re, "starting", "The session is not ready.");
        if (p.channels.items.len >= max_channels)
            return s.replyError(p.id, re, "busy", "This connection has too many open channels.");
        const path = socket.getSocketPath(s.gpa, s.dir, id) catch
            return s.replyError(p.id, re, "unavailable", "The server is out of memory.");
        defer s.gpa.free(path);
        const fd = connectNonblocking(path) catch |err| {
            std.log.warn("server: cannot connect to session {s} for a channel: {s}", .{ id, @errorName(err) });
            return s.replyError(p.id, re, "unavailable", "The session does not answer.");
        };
        const ch = s.gpa.create(Channel) catch {
            lib_posix.close(fd);
            return s.replyError(p.id, re, "unavailable", "The server is out of memory.");
        };
        ch.* = .{ .id = p.next_channel, .session = s.gpa.dupe(u8, id) catch {
            lib_posix.close(fd);
            s.gpa.destroy(ch);
            return s.replyError(p.id, re, "unavailable", "The server is out of memory.");
        }, .fd = fd };
        p.channels.append(s.gpa, ch) catch {
            ch.deinit(s.gpa);
            return s.replyError(p.id, re, "unavailable", "The server is out of memory.");
        };
        p.next_channel +%= 1;
        if (p.next_channel == frame.control_channel) p.next_channel = 1;
        // The reply goes when the session's `hello` comes, so that a session
        // that refuses the server gives an error, not a channel that is
        // silent.
        ch.open_re = re;
        s.sendChannelControl(ch, s.hello());
    }

    /// A frame from the client on a pane channel goes to the session, never
    /// dropped. A frame for a channel that is not open is ignored.
    fn relayToSession(s: *Server, p: *Peer, f: frame.Frame) void {
        const ch = p.findChannel(f.channel) orelse return;
        if (ch.fd < 0) return;
        ch.to_session.append(s.gpa, m.pane_channel, f.kind, f.body, false) catch return s.channelGone(p, ch);
        if (ch.to_session.len() > session.client_hard_cap) {
            std.log.warn("server: session {s} does not read its channel, closed", .{ch.session});
            s.channelGone(p, ch);
        }
    }

    fn readChannel(s: *Server, p: *Peer, ch: *Channel) void {
        var buf: [16 * 1024]u8 = undefined;
        const n = lib_posix.read(ch.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return s.channelGone(p, ch),
        };
        if (n == 0) return s.channelGone(p, ch);
        ch.in.appendSlice(s.gpa, buf[0..n]) catch return s.channelGone(p, ch);

        const t = s.now();
        var used: usize = 0;
        defer if (ch.fd >= 0) ch.in.replaceRangeAssumeCapacity(0, used, &.{});
        while (ch.fd >= 0 and !p.dead) {
            const rest = ch.in.items[used..];
            if (rest.len >= frame.header_len and std.mem.readInt(u32, rest[0..4], .little) > frame_max) {
                std.log.warn("server: session {s} sent a frame over 1 MiB on a channel, closed", .{ch.session});
                return s.channelGone(p, ch);
            }
            const parsed = (frame.parse(rest) catch return s.channelGone(p, ch)) orelse break;
            used += parsed.len;
            s.handleChannelFrame(p, ch, parsed.frame, t);
        }
        if (ch.fd >= 0 and ch.flow.mustSkip(ch.q.stale(), t)) s.skip(ch, t);
        s.checkPeerCap(p);
    }

    fn handleChannelFrame(s: *Server, p: *Peer, ch: *Channel, f: frame.Frame, t: i64) void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (f.channel == frame.control_channel) {
            const msg = m.decodeControl(arena, f.body) catch return s.channelGone(p, ch);
            switch (msg) {
                .hello => |h| if (!ch.greeted) switch (m.negotiate(s.hello(), h)) {
                    .speak => {
                        ch.greeted = true;
                        if (ch.open_re) |re| s.reply(p.id, re, m.ChannelOpen, .{ .channel = ch.id });
                        ch.open_re = null;
                    },
                    .refuse => |r| {
                        std.log.info("server: session {s} speaks level {d}, channel closed", .{ ch.session, h.level });
                        s.sendChannelControl(ch, r);
                        _ = lib_posix.write(ch.fd, ch.to_session.buf.items) catch {};
                        s.channelGone(p, ch);
                    },
                },
                .refuse => s.channelGone(p, ch),
                else => {},
            }
            return;
        }
        if (!ch.greeted or f.channel != m.pane_channel) return;
        const class: relay.Class = switch (f.kind) {
            .msg => blk: {
                const msg = msgpack.decodeSlice(m.PaneMessage, arena, f.body) catch return s.channelGone(p, ch);
                if (std.mem.eql(u8, msg.t, m.SnapshotStart.name)) break :blk .snapshot_start;
                if (std.mem.eql(u8, msg.t, m.SnapshotEnd.name)) break :blk .snapshot_end;
                break :blk .message;
            },
            .bytes => if (ch.flow.in_snapshot) .snapshot else .output,
            _ => return,
        };
        if (ch.flow.classify(class) == .drop) return;
        ch.q.push(s.gpa, ch.id, f.kind, f.body, t, class) catch s.channelGone(p, ch);
    }

    /// The channel's output is too old or too large: drop it, and show the
    /// screen as it is now (design/003 §6).
    fn skip(s: *Server, ch: *Channel, t: i64) void {
        std.log.info("server: channel {d} (session {s}) fell behind, output dropped", .{ ch.id, ch.session });
        ch.flow.skipped(ch.q.dropStale(s.gpa), t);
        s.sendRefresh(ch);
    }

    /// Output stops until the session's snapshot starts.
    fn askSnapshot(s: *Server, ch: *Channel, t: i64) void {
        ch.flow.want_snapshot = true;
        ch.flow.asked_at = t;
        s.sendRefresh(ch);
    }

    fn sendRefresh(s: *Server, ch: *Channel) void {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        m.encodePane(&out.writer, m.Refresh, .{}) catch return;
        ch.to_session.append(s.gpa, m.pane_channel, .msg, out.written(), false) catch {
            lib_posix.close(ch.fd);
            ch.fd = -1;
        };
    }

    fn writeChannel(s: *Server, p: *Peer, ch: *Channel) void {
        if (ch.to_session.len() == 0) return;
        const n = lib_posix.write(ch.fd, ch.to_session.buf.items) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return s.channelGone(p, ch),
        };
        ch.to_session.consume(n);
    }

    /// The session closed the channel's connection. The frames that wait
    /// still go to the client (a last `exit`), then the channel goes.
    fn channelGone(s: *Server, p: *Peer, ch: *Channel) void {
        if (ch.open_re) |re| s.replyError(p.id, re, "unavailable", "The session closed the connection.");
        ch.open_re = null;
        if (ch.fd < 0) return;
        lib_posix.close(ch.fd);
        ch.fd = -1;
    }

    fn sendChannelControl(s: *Server, ch: *Channel, value: anytype) void {
        const body = msgpack.encodeAlloc(s.gpa, value) catch return;
        defer s.gpa.free(body);
        ch.to_session.append(s.gpa, frame.control_channel, .msg, body, false) catch {
            lib_posix.close(ch.fd);
            ch.fd = -1;
        };
    }

    /// On a host, removes the file of each server build that no session
    /// runs (design/002, design/005 step 5). The app installs each build as
    /// `macterm-<key>` in one folder, and a session keeps the build that
    /// started it, so a file goes when the last session of its build ends.
    /// The server never removes its own file.
    ///
    /// It fails closed: it does nothing unless the server runs from such a
    /// file (not the Mac's bundle, not a file that was replaced), nothing
    /// while a session's build has no key, and it keeps a file of the last
    /// minute (`fresh_build_ms`), whose proxy may still come.
    fn pruneBuilds(s: *Server) void {
        const own = buildKey(build_options.version) orelse return;
        const folder = std.fs.path.dirname(s.exe) orelse return;
        if (!isBuildFile(std.fs.path.basename(s.exe), own)) return;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(s.gpa);
        for (s.entries.items) |e| {
            if (e.dead) continue;
            keys.append(s.gpa, buildKey(e.build) orelse return) catch return;
        }
        var dir = std.Io.Dir.openDirAbsolute(s.io, folder, .{ .iterate = true }) catch return;
        defer dir.close(s.io);
        const now_ms = std.Io.Timestamp.now(s.io, .real).toMilliseconds();
        var it = dir.iterate();
        while (it.next(s.io) catch null) |entry| {
            if (entry.kind != .file or !staleBuild(entry.name, own, keys.items)) continue;
            // A build that an app just installed: its proxy has not started
            // yet, so no session reports it.
            const stat = dir.statFile(s.io, entry.name, .{}) catch continue;
            if (now_ms - stat.mtime.toMilliseconds() < fresh_build_ms) continue;
            dir.deleteFile(s.io, entry.name) catch |err| {
                std.log.warn("server: cannot remove {s}: {s}", .{ entry.name, @errorName(err) });
                continue;
            };
            std.log.info("server: removed {s}, which no session runs", .{entry.name});
        }
    }

    fn sweep(s: *Server) void {
        var i: usize = 0;
        while (i < s.peers.items.len) {
            const p = s.peers.items[i];
            if (p.dead) {
                // Nobody waits for its commands: they end now, and free
                // their places (`max_runs`).
                for (s.runs.items) |r| if (r.peer == p.id and !r.timed_out) {
                    r.timed_out = true;
                    lib_posix.kill(-r.pid, lib_posix.SIG.KILL) catch {};
                    if (r.out_fd >= 0) lib_posix.close(r.out_fd);
                    r.out_fd = -1;
                };
                lib_posix.close(p.fd);
                p.in.deinit(s.gpa);
                p.out.deinit(s.gpa);
                p.control.deinit(s.gpa);
                for (p.channels.items) |ch| ch.deinit(s.gpa);
                p.channels.deinit(s.gpa);
                s.gpa.destroy(p);
                _ = s.peers.orderedRemove(i);
            } else {
                // A channel that the client closed goes when its input went
                // to the session. A channel whose session left goes when its
                // last frames went to the client.
                var j: usize = 0;
                while (j < p.channels.items.len) {
                    const ch = p.channels.items[j];
                    if (if (ch.closed) ch.fd < 0 or ch.to_session.len() == 0 else ch.fd < 0 and ch.q.empty()) {
                        ch.deinit(s.gpa);
                        _ = p.channels.orderedRemove(j);
                        if (p.turn > j) p.turn -= 1;
                    } else j += 1;
                }
                if (p.channels.items.len > 0) p.turn %= p.channels.items.len else p.turn = 0;
                i += 1;
            }
        }
        i = 0;
        while (i < s.entries.items.len) {
            const e = s.entries.items[i];
            if (e.dead) {
                if (e.fd >= 0) lib_posix.close(e.fd);
                e.in.deinit(s.gpa);
                e.out.deinit(s.gpa);
                e.waiters.deinit(s.gpa);
                s.gpa.free(e.build);
                s.gpa.free(e.id);
                s.gpa.destroy(e);
                _ = s.entries.orderedRemove(i);
            } else i += 1;
        }
    }
};

/// The absolute path of this binary, to start sessions with.
fn selfExe(buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    if (comptime builtin.os.tag.isDarwin()) {
        // It can be relative to the folder at start.
        var raw: [std.fs.max_path_bytes]u8 = undefined;
        var len: u32 = raw.len;
        if (std.c._NSGetExecutablePath(&raw, &len) != 0) return error.ExecutablePathTooLong;
        if (std.c.realpath(@ptrCast(&raw), buf) == null) return error.ExecutablePathUnknown;
        const n = std.mem.findScalar(u8, buf, 0) orelse return error.ExecutablePathTooLong;
        return buf[0..n :0];
    }
    const n = std.c.readlink("/proc/self/exe", buf, buf.len - 1);
    if (n <= 0) return error.ExecutablePathUnknown;
    buf[@intCast(n)] = 0;
    return buf[0..@intCast(n) :0];
}

/// A connect that fails with `error.WouldBlock` when the session's backlog
/// is full, so that a stuck session never stops the server.
fn connectNonblocking(path: []const u8) !i32 {
    var addr = try lib_posix.initUnix(path);
    const fd = try lib_posix.socket(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM | lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC, 0);
    errdefer lib_posix.close(fd);
    try lib_posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

/// A session's build as the server keeps it: at most 64 bytes of printable
/// ASCII, or `unknown`.
fn buildName(build: []const u8) []const u8 {
    if (build.len == 0 or build.len > 64) return "unknown";
    for (build) |c| if (c < 0x20 or c > 0x7e) return "unknown";
    return build;
}

/// The build key in a version (`1.0.1+thdxg.<key>`, `scripts/build-server.sh`):
/// lowercase hex, at most 40 characters. Null for any other version.
pub fn buildKey(version: []const u8) ?[]const u8 {
    const marker = "+thdxg.";
    const at = std.mem.find(u8, version, marker) orelse return null;
    const key = version[at + marker.len ..];
    return if (validKey(key)) key else null;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 40) return false;
    for (key) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// `macterm-<key>`: the name of the server file of the build `key` on a host.
fn isBuildFile(name: []const u8, key: []const u8) bool {
    const prefix = "macterm-";
    return std.mem.startsWith(u8, name, prefix) and std.mem.eql(u8, name[prefix.len..], key);
}

/// A server file of another build than `own` that no session runs. A temp
/// file of an install (`.macterm-…`) is not one.
fn staleBuild(name: []const u8, own: []const u8, running: []const []const u8) bool {
    const prefix = "macterm-";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const key = name[prefix.len..];
    if (!validKey(key) or std.mem.eql(u8, key, own)) return false;
    for (running) |k| if (std.mem.eql(u8, k, key)) return false;
    return true;
}

/// A pid that the server may signal: above 1, and a `pid_t`.
fn validPid(pid: i64) bool {
    return pid > 1 and pid <= std.math.maxInt(lib_posix.pid_t);
}

/// The text of a `session` child's failure, for the error reply: its first
/// line without the `error: ` prefix. Text that is not UTF-8 is replaced.
fn errorText(stderr: []const u8) []const u8 {
    var line = std.mem.trim(u8, stderr, " \r\n");
    if (std.mem.findScalar(u8, line, '\n')) |i| line = line[0..i];
    if (std.mem.startsWith(u8, line, "error: ")) line = line["error: ".len..];
    if (line.len == 0 or !std.unicode.utf8ValidateSlice(line)) return "The session did not start.";
    return line;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the error text is the first line without its prefix" {
    try testing.expectEqualStrings("session \"a\" already exists", errorText("error: session \"a\" already exists\n"));
    try testing.expectEqualStrings("one", errorText("one\ntwo\n"));
    try testing.expectEqualStrings("The session did not start.", errorText(""));
    try testing.expectEqualStrings("The session did not start.", errorText("error: \xff\n"));
}

test "the server signals no pid that reaches a group or every process" {
    try testing.expect(validPid(2));
    try testing.expect(!validPid(1));
    try testing.expect(!validPid(0));
    try testing.expect(!validPid(-1));
    try testing.expect(!validPid(-500));
    try testing.expect(!validPid(@as(i64, std.math.maxInt(lib_posix.pid_t)) + 1));
}

test "a build key comes only from a version of the fork" {
    try testing.expectEqualStrings("2705a118fde2c903", buildKey("1.0.1+thdxg.2705a118fde2c903").?);
    try testing.expect(buildKey("1.0.1") == null);
    try testing.expect(buildKey("unknown") == null);
    try testing.expect(buildKey("1.0.1+thdxg.") == null);
    try testing.expect(buildKey("1.0.1+thdxg.ABC") == null);
    try testing.expect(buildKey("1.0.1+thdxg.a/b") == null);
}

test "a server file goes only when it is another build that no session runs" {
    const running = [_][]const u8{"bbbb"};
    try testing.expect(staleBuild("macterm-cccc", "aaaa", &running));
    try testing.expect(!staleBuild("macterm-aaaa", "aaaa", &running));
    try testing.expect(!staleBuild("macterm-bbbb", "aaaa", &running));
    try testing.expect(!staleBuild(".macterm-cccc.123.456", "aaaa", &running));
    try testing.expect(!staleBuild("macterm-cccc.old", "aaaa", &running));
    try testing.expect(!staleBuild("zmx", "aaaa", &running));
    try testing.expect(!staleBuild("macterm-", "aaaa", &running));
    try testing.expect(isBuildFile("macterm-aaaa", "aaaa"));
    try testing.expect(!isBuildFile("zmx", "aaaa"));
    try testing.expect(!isBuildFile("macterm-aaaa (deleted)", "aaaa"));
}

test "a session's build is kept only as short printable text" {
    try testing.expectEqualStrings("1.0.1+thdxg.abc", buildName("1.0.1+thdxg.abc"));
    try testing.expectEqualStrings("unknown", buildName(""));
    try testing.expectEqualStrings("unknown", buildName("a\x1b[2Jb"));
    const long: [65]u8 = @splat('x');
    try testing.expectEqualStrings("unknown", buildName(&long));
}

test "the server's socket name is no session name" {
    try testing.expect(!session.validName(socket_name));
    try testing.expect(!session.validName(lock_name));
}
