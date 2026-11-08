//! The messages on channel 0 (design/003 §2, §4; design/006 §2).
//!
//! Each message type is a Zig struct, and this file is the one source of the
//! schema: the Swift side and the metadata are made from it (issue 0045).
//! Each type declares:
//!
//! - `name`: the method or message name on the wire;
//! - `since`: the protocol level that added it;
//! - `senders`: the trust levels of the connections that may send it.
//!
//! The add-only rule: never remove or rename a message or a field, and never
//! change a field's type. A new field is optional or has a default, so that
//! an older peer's message still decodes. A peer skips keys it does not know.

const std = @import("std");
const msgpack = @import("msgpack.zig");

const Raw = msgpack.Raw;

/// The level that this build speaks. It counts additions to the protocol.
pub const level: u32 = 1;

/// The lowest level that this build accepts from a peer.
pub const min_level: u32 = 1;

/// What a peer says it is in `hello`. The trust of a connection never comes
/// from this field (design/006 §2).
pub const Role = enum {
    gui,
    cli,
    server,
    session,
    /// A role that a later build added. It decodes, so that the two builds
    /// can still refuse each other clearly.
    unknown,
};

/// How a connection came, and so what its peer may send (design/006 §2).
pub const Trust = enum {
    /// The GUI or the CLI on the local socket, with the peer uid checked.
    local,
    /// A local session process to its server.
    session,
    /// A host's server, through the app's ssh.
    remote,
};

const everyone: []const Trust = &.{ .local, .session, .remote };

// ── Handshake ───────────────────────────────────────────────────────────────

/// The first message in each direction. Its layout is frozen for ever, so
/// that any two builds can at least refuse each other clearly.
pub const Hello = struct {
    pub const name = "hello";
    pub const since = 1;
    pub const senders = everyone;

    level: u32,
    min_level: u32,
    build: []const u8,
    role: Role,
    /// A random id for each server start. A new epoch tells a client that
    /// the server restarted.
    epoch: u64,
    /// What the build or its platform can do apart from its level (`tcc`,
    /// `password-tty`). A peer ignores a cap it does not know.
    caps: []const []const u8,
};

/// Sent in place of any other message when the peer speaks too low a level.
/// The sender then closes the connection. Its layout is frozen, as `Hello`'s.
pub const Refuse = struct {
    pub const name = "refuse";
    pub const since = 1;
    pub const senders = everyone;

    /// A code, not text for people: `level_too_low`.
    reason: []const u8,
    /// The lowest level that the sender accepts.
    needs_level: u32,
};

pub const Negotiation = union(enum) {
    /// Both sides speak this level.
    speak: u32,
    /// Send this, then close.
    refuse: Refuse,
};

/// Decides the level from our `hello` and the peer's. Each side checks only
/// its own `min_level`: if the level is under the peer's, the peer refuses.
///
/// The CLI is always the same build as its server (design/007), so a CLI on
/// either side refuses any other build (`build_mismatch`). The CLI names
/// both builds from the two hellos.
pub fn negotiate(mine: Hello, theirs: Hello) Negotiation {
    const speak = @min(mine.level, theirs.level);
    if (speak < mine.min_level) return .{ .refuse = .{
        .reason = "level_too_low",
        .needs_level = mine.min_level,
    } };
    if ((mine.role == .cli or theirs.role == .cli) and !std.mem.eql(u8, mine.build, theirs.build))
        return .{ .refuse = .{ .reason = "build_mismatch", .needs_level = mine.level } };
    return .{ .speak = speak };
}

// ── Envelopes ───────────────────────────────────────────────────────────────

/// `{id, m, a}`. The id comes from the client and is unique for its
/// connection epoch, so that a request sent again after a resume is matched
/// and not done two times.
pub const Request = struct {
    id: u64,
    m: []const u8,
    /// The method's `Args`. Null for an empty argument map.
    a: ?Raw = null,
};

/// `{re, ok}` or `{re, err}`: exactly one of the two. `decodeControl`
/// refuses a response with both or neither.
pub const Response = struct {
    re: u64,
    /// The method's `Result`.
    ok: ?Raw = null,
    err: ?ErrorInfo = null,
};

pub const ErrorInfo = struct {
    /// snake_case, as in v1: `not_found`, `busy`, `unknown_method`.
    code: []const u8,
    message: []const u8,
    /// The level that the request needs, when the error is that the peer
    /// speaks a lower one.
    level: ?u32 = null,
};

pub const Event = struct {
    e: []const u8,
    a: ?Raw = null,
};

/// One consistent state: the receiver applies all of its events at once.
pub const EventBatch = struct {
    /// Counts batches within one epoch.
    seq: u64,
    ev: []const Event,
};

// ── Methods ─────────────────────────────────────────────────────────────────

/// Opens a channel for a session's pane (design/003 §1).
pub const ChannelOpen = struct {
    pub const name = "channel.open";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { session: []const u8 };
    pub const Result = struct { channel: u32 };
};

pub const ChannelClose = struct {
    pub const name = "channel.close";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { channel: u32 };
    pub const Result = struct {};
};

/// What the server knows of one session (design/001). The session process
/// holds all of it, so a new server reads it again from each session.
pub const Session = struct {
    /// The session's name: the file name of its socket. The client that
    /// asked for the session made it.
    id: []const u8,
    state: SessionState,
    /// The session's build and level, from its `hello`.
    build: []const u8,
    level: u32,
    /// The session process. Null when `state` is `refused`.
    pid: ?i64 = null,
    /// The shell (or the command) of the session.
    shell_pid: ?i64 = null,
    /// The path of the pty's slave side.
    pty: ?msgpack.Bin = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    /// The exit code, when `state` is `exited` and the shell exited.
    code: ?u8 = null,
    /// The signal number, when `state` is `exited` and a signal ended the
    /// shell.
    signal: ?u8 = null,
};

pub const SessionState = enum {
    running,
    /// The shell ended. The session keeps the status until a client sends
    /// `session.kill`.
    exited,
    /// The session and the server have no level in common. The server
    /// cannot read its state or end it.
    refused,
    /// A state that a later build added.
    unknown,
};

/// Starts a session process (design/001). The server answers when the
/// session's socket accepts connections and the session sent its state.
pub const SessionCreate = struct {
    pub const name = "session.create";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        /// Made by the client, so that a request sent again finds the session
        /// that the first one started, and starts no second one. Only
        /// letters, digits, `-`, `_` and `.`; not `.` first.
        id: []const u8,
        /// The session's folder, an absolute path. Null is the home folder.
        cwd: ?msgpack.Bin = null,
        /// The command in place of a login shell.
        command: ?[]const msgpack.Bin = null,
        cols: u16 = 80,
        rows: u16 = 24,
    };
    pub const Result = Session;
};

pub const SessionList = struct {
    pub const name = "session.list";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {};
    pub const Result = struct { sessions: []const Session };
};

pub const SessionInfo = struct {
    pub const name = "session.info";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: []const u8 };
    pub const Result = Session;
};

/// Ends a session. A running session ends its shell (SIGHUP to the shell's
/// process group, then SIGKILL). An exited session gives its status to no
/// one more and ends. The server answers when the session process is gone.
pub const SessionKill = struct {
    pub const name = "session.kill";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: []const u8 };
    pub const Result = struct {};
};

/// The server exits and leaves every session running, so that a newer app
/// can start its own server (design/002).
pub const ServerExit = struct {
    pub const name = "server.exit";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {};
    pub const Result = struct {};
};

/// Every request method. A new method goes here.
pub const methods = .{ ChannelOpen, ChannelClose, SessionCreate, SessionList, SessionInfo, SessionKill, ServerExit };

// ── Events ──────────────────────────────────────────────────────────────────

/// A session stopped running: its shell exited, or the session process is
/// gone. Sent once for each session. A session process that ended with no
/// exit message gives no code and no signal.
pub const SessionExit = struct {
    pub const name = "session.exit";
    pub const since = 1;
    pub const senders = everyone;

    id: []const u8,
    code: ?u8 = null,
    signal: ?u8 = null,
};

/// Every event. A new event goes here.
pub const events = .{SessionExit};

/// True if a connection with this trust may send message `M`. A message from
/// a sender outside the list gets an error reply and a log line; the link
/// stays up (design/006 §2).
pub fn maySend(comptime M: type, trust: Trust) bool {
    return std.mem.findScalar(Trust, M.senders, trust) != null;
}

pub fn encodeRequest(w: *std.Io.Writer, id: u64, comptime M: type, args: M.Args) std.Io.Writer.Error!void {
    try msgpack.encode(w, struct { id: u64, m: []const u8, a: M.Args }{ .id = id, .m = M.name, .a = args });
}

pub fn encodeResult(w: *std.Io.Writer, re: u64, comptime M: type, result: M.Result) std.Io.Writer.Error!void {
    try msgpack.encode(w, struct { re: u64, ok: M.Result }{ .re = re, .ok = result });
}

pub fn decodeArgs(comptime M: type, arena: std.mem.Allocator, req: Request) msgpack.DecodeError!M.Args {
    return msgpack.decodeSlice(M.Args, arena, if (req.a) |a| a.bytes else &.{0x80});
}

/// `error.ErrorResponse` if the response is an error: read `res.err`.
pub fn decodeResult(
    comptime M: type,
    arena: std.mem.Allocator,
    res: Response,
) (msgpack.DecodeError || error{ErrorResponse})!M.Result {
    const ok = res.ok orelse return error.ErrorResponse;
    return msgpack.decodeSlice(M.Result, arena, ok.bytes);
}

// ── A session's pane channel ────────────────────────────────────────────────

/// A `msg` frame on a pane channel: `{t, a}`. `t` names one of
/// `pane_messages`, `a` holds its fields. A receiver ignores a `t` that it
/// does not know.
///
/// On a direct session socket the pane channel is `pane_channel`
/// (design/003 §1). A client sends `Attach` before it gets any pane output;
/// a client that never sends it (a server that reads the exit status) gets
/// only the session's messages.
pub const PaneMessage = struct {
    t: []const u8,
    a: ?Raw = null,
};

/// The channel of the pane on a direct session socket.
pub const pane_channel: u32 = 1;

const from_client: []const Trust = &.{.local};
const from_session: []const Trust = &.{.session};

/// The session's state, sent once after `hello`, and again when it changes.
pub const State = struct {
    pub const name = "state";
    pub const since = 1;
    pub const senders = from_session;

    /// The session process.
    pid: i64,
    /// The shell (or the command) that the session started. Its parent is
    /// the session, so the session reads its exit status.
    shell_pid: i64,
    /// The path of the pty's slave side. Not UTF-8 on every system.
    pty: msgpack.Bin,
    cols: u16,
    rows: u16,
};

/// The first message of a client that shows the pane: its size. When the
/// pane has output, the session answers with a snapshot (`SnapshotStart`,
/// `bytes`, `SnapshotEnd`), laid out for that size when the client leads.
/// A size over 1000 cells is cut to 1000; a size of 0 is ignored.
pub const Attach = struct {
    pub const name = "attach";
    pub const since = 1;
    pub const senders = from_client;

    cols: u16,
    rows: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// The client's new size. Only the leader's size reaches the pty.
pub const Resize = struct {
    pub const name = "resize";
    pub const since = 1;
    pub const senders = from_client;

    cols: u16,
    rows: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// The client takes leadership without input (zmx 0003). It then sends its
/// size with `Resize`.
pub const Claim = struct {
    pub const name = "claim";
    pub const since = 1;
    pub const senders = from_client;
};

/// Tells a client that it leads (its size is the pty's) or that it does not.
/// When the leader leaves, the client that attached first of those left
/// leads. A client that starts to lead sends its size.
pub const Lead = struct {
    pub const name = "lead";
    pub const since = 1;
    pub const senders = from_session;

    leader: bool,
};

/// The `bytes` frames up to `SnapshotEnd` are a snapshot of the terminal,
/// not output. `scrollback` is false for a snapshot after dropped output:
/// it holds the screen only, and clears the old screen first.
pub const SnapshotStart = struct {
    pub const name = "snapshot.start";
    pub const since = 1;
    pub const senders = from_session;

    scrollback: bool,
};

pub const SnapshotEnd = struct {
    pub const name = "snapshot.end";
    pub const since = 1;
    pub const senders = from_session;
};

/// The shell exited. The session keeps the status, and sends this to every
/// client that connects, until one sends `Take`.
pub const Exit = struct {
    pub const name = "exit";
    pub const since = 1;
    pub const senders = from_session;

    /// The exit code, when the shell exited.
    code: ?u8 = null,
    /// The signal number, when a signal ended the shell.
    signal: ?u8 = null,
};

/// The client has the exit status. The session then ends.
pub const Take = struct {
    pub const name = "take";
    pub const since = 1;
    pub const senders = from_client;
};

/// Every message on a pane channel. A new one goes here.
pub const pane_messages = .{ State, Attach, Resize, Claim, Lead, SnapshotStart, SnapshotEnd, Exit, Take };

pub fn encodePane(w: *std.Io.Writer, comptime M: type, value: M) std.Io.Writer.Error!void {
    try msgpack.encode(w, struct { t: []const u8, a: M }{ .t = M.name, .a = value });
}

/// Decodes the fields of a pane message whose `t` is `M.name`.
pub fn decodePane(comptime M: type, arena: std.mem.Allocator, msg: PaneMessage) msgpack.DecodeError!M {
    return msgpack.decodeSlice(M, arena, if (msg.a) |a| a.bytes else &.{0x80});
}

// ── Reading channel 0 ───────────────────────────────────────────────────────

pub const Control = union(enum) {
    hello: Hello,
    refuse: Refuse,
    request: Request,
    response: Response,
    events: EventBatch,
    /// A message of a kind that a later build added. Ignore it.
    unknown,
};

/// Decodes one message from the body of a channel-0 frame. The keys name its
/// kind: `m` a request, `re` a response, `seq` an event batch, `needs_level`
/// a refusal, `level` a hello. These keys are frozen with the shapes.
pub fn decodeControl(arena: std.mem.Allocator, body: []const u8) msgpack.DecodeError!Control {
    const Kind = enum { request, response, events, refuse, hello, unknown };
    var kind: Kind = .unknown;
    var r: msgpack.Reader = .{ .bytes = body };
    const count = try r.readMapLen();
    for (0..count) |_| {
        const key = try r.decode([]const u8, arena);
        try r.skip();
        const k: Kind = if (std.mem.eql(u8, key, "m"))
            .request
        else if (std.mem.eql(u8, key, "re"))
            .response
        else if (std.mem.eql(u8, key, "seq"))
            .events
        else if (std.mem.eql(u8, key, "needs_level"))
            .refuse
        else if (std.mem.eql(u8, key, "level"))
            .hello
        else
            .unknown;
        if (@backingInt(k) < @backingInt(kind)) kind = k;
    }
    return switch (kind) {
        .request => .{ .request = try msgpack.decodeSlice(Request, arena, body) },
        .response => {
            const res = try msgpack.decodeSlice(Response, arena, body);
            if ((res.ok == null) == (res.err == null)) return error.WrongType;
            return .{ .response = res };
        },
        .events => .{ .events = try msgpack.decodeSlice(EventBatch, arena, body) },
        .refuse => .{ .refuse = try msgpack.decodeSlice(Refuse, arena, body) },
        .hello => .{ .hello = try msgpack.decodeSlice(Hello, arena, body) },
        .unknown => .unknown,
    };
}
