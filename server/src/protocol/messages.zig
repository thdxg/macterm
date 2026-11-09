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
//! A field added to a type of an older level names its level in the type's
//! `field_since` declaration: `pub const field_since = .{ .hint = 2 };`.
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

/// Stops a channel's pane output, for a pane that no one sees. The session's
/// messages on the channel (its exit, its state) still come (design/003 §6).
pub const ChannelPause = struct {
    pub const name = "channel.pause";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { channel: u32 };
    pub const Result = struct {};
};

/// Starts a paused channel's output again. A snapshot of the screen comes
/// first on the channel.
pub const ChannelResume = struct {
    pub const name = "channel.resume";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { channel: u32 };
    pub const Result = struct {};
};

/// Tells a client that the link is up. Any frame does the same; this one gets
/// an answer when nothing else moves (design/005, "Reconnect").
pub const Ping = struct {
    pub const name = "ping";
    pub const since = 1;
    pub const senders = everyone;

    pub const Args = struct {};
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
    pub const Result = struct { session: Session };
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
    pub const Result = struct { session: Session };
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
pub const methods = .{ ChannelOpen, ChannelClose, ChannelPause, ChannelResume, Ping, SessionCreate, SessionList, SessionInfo, SessionKill, ServerExit };

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

/// Every event type. A new event goes here. Each one declares `name`,
/// `since` and `senders`, as a method does, and its fields are the event's
/// `a`. No event may hold a `Secret` (design/006 §1); `schema.check` refuses
/// one.
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

/// The client ends the session: the session sends SIGHUP to the shell's
/// process group, SIGKILL 0.5 s later if it still runs, and then ends. It
/// sends no `exit`.
pub const End = struct {
    pub const name = "end";
    pub const since = 1;
    pub const senders = from_client;
};

/// The client asks for a snapshot of the screen, after it dropped output or
/// did not show it (a server's relay, design/003 §6). The session drops the
/// output that waits for that client and sends the snapshot, with no
/// scrollback. A client that does not show the pane gets nothing.
pub const Refresh = struct {
    pub const name = "refresh";
    pub const since = 1;
    pub const senders = from_client;
};

// The session's events (design/003 §5, design/004 §6). The session reads
// them from its own terminal and pty, so they are right for a client that
// does not show the pane. Every greeted client gets them; a client that
// connects gets the current title, cwd, foreground, progress, status and
// program status after `State`. Each one is sent before the pane output
// that follows it.
//
// Title, cwd, progress, program status and bell coalesce: the first in a
// quiet period goes at once, later ones in the next `coalesce_ms` merge and
// go at its end, newest value wins. Activity goes at most once in
// `activity_ms`, and the rest is dropped. Foreground, marks and status are
// never held.

/// The window in which title, cwd, progress, program status and bell
/// coalesce.
pub const coalesce_ms = 16;

/// The output heartbeat goes at most once in this time (v1's libghostty
/// `OUTPUT_ACTIVITY`): leading edge, the rest dropped, never deferred.
pub const activity_ms = 500;

/// The terminal title (OSC 0 and OSC 2).
pub const Title = struct {
    pub const name = "title";
    pub const since = 1;
    pub const senders = from_session;

    /// As the program sent it. Not UTF-8 on every program.
    title: msgpack.Bin,
};

/// The working directory that the shell reports (OSC 7).
pub const Cwd = struct {
    pub const name = "cwd";
    pub const since = 1;
    pub const senders = from_session;

    /// The OSC 7 payload as the shell sent it: usually a `file://` URL,
    /// percent-encoded. The receiver decodes it.
    url: msgpack.Bin,
};

/// The process group that holds the pty (zmx 0010). Sent when the group or
/// its leader's name changes, and to a client that connects or catches up.
pub const Foreground = struct {
    pub const name = "foreground";
    pub const since = 1;
    pub const senders = from_session;

    /// The group is the session's own shell.
    idle: bool,
    /// `comm` is in the host's `/etc/shells`. Null when the host has none.
    shell: ?bool = null,
    /// The process name: the executable path on macOS, the kernel `comm` on
    /// Linux.
    comm: msgpack.Bin,
    /// The command line, its arguments joined by spaces.
    args: msgpack.Bin,
};

pub const MarkKind = enum {
    /// The shell starts to draw a prompt (OSC 133;A).
    prompt,
    /// The prompt is drawn and the user can type (OSC 133;B).
    input,
    /// The user submitted a command and it runs (OSC 133;C).
    output,
    /// The command finished (OSC 133;D).
    end,
    unknown,
};

/// A step of a command, from shell integration (OSC 133).
pub const Mark = struct {
    pub const name = "mark";
    pub const since = 1;
    pub const senders = from_session;

    kind: MarkKind,
    /// For `output` and `end`: the command line. The shell's own text when
    /// it sent one, else the input cells of the prompt. Null when there is
    /// neither.
    command: ?msgpack.Bin = null,
    /// For `end`: the exit code, when the shell sent one.
    exit_code: ?i32 = null,
};

pub const ProgressState = enum {
    remove,
    set,
    @"error",
    indeterminate,
    pause,
    unknown,
};

/// A progress report (OSC 9;4).
pub const Progress = struct {
    pub const name = "progress";
    pub const since = 1;
    pub const senders = from_session;

    state: ProgressState,
    /// 0 to 100, when the program sent one.
    percent: ?u8 = null,
};

/// The program rang the bell (BEL).
pub const Bell = struct {
    pub const name = "bell";
    pub const since = 1;
    pub const senders = from_session;
};

/// The pane printed output (the heartbeat, `activity_ms`).
pub const Activity = struct {
    pub const name = "activity";
    pub const since = 1;
    pub const senders = from_session;
};

pub const RunState = enum {
    /// No command ran yet.
    idle,
    running,
    done,
    unknown,
};

/// The pane's run, derived from the marks and the progress reports only:
/// `running` from OSC 133;C or a progress report that sets work, `done` from
/// OSC 133;D or a report that ends it. A shell with no integration and a
/// program with no progress report stay `idle`.
pub const Status = struct {
    pub const name = "status";
    pub const since = 1;
    pub const senders = from_session;

    state: RunState,
    /// With `done`: a progress report said error (v1's red dot). The exit
    /// code does not count: it judges the command, not the run.
    failed: bool = false,
};

pub const ProgramState = enum {
    /// At rest, waits for the user's next instruction.
    idle,
    working,
    /// Finished work that the user did not look at yet.
    done,
    /// Cannot continue until the user does something.
    blocked,
    @"error",
    unknown,
};

/// What a blocked program needs from the user.
pub const ProgramNeed = enum {
    /// Approval to do something.
    permission,
    /// An answer that the user types.
    question,
    /// A login, a token or another credential.
    auth,
    unknown,
};

/// One record of a program's status (OSC 7501).
pub const ProgramRecord = struct {
    /// The record's id: names joined by `/`, where `a/b` is a child of `a`.
    /// Empty for the root record, which is the program itself.
    id: []const u8 = "",
    state: ProgramState,
    /// With `blocked`: what the program needs.
    kind: ?ProgramNeed = null,
    /// With `working` or `blocked`: 0 to 100. Null when the program gave
    /// none.
    progress: ?u8 = null,
    /// A stable name for the program (`cargo`, `claude-code`). A record that
    /// gave none has the `app` of its nearest ancestor that gave one, the
    /// root record included.
    app: ?[]const u8 = null,
    /// A short label for the record, decoded. UTF-8 with no control
    /// characters; still the program's text.
    title: ?[]const u8 = null,
    /// One line that says what the record does or waits for, decoded. As
    /// `title`.
    msg: ?[]const u8 = null,
};

/// Every record of the program status protocol (OSC 7501) that the pane
/// holds now, oldest first. Each change sends all of them, so an empty list
/// clears them all. It coalesces as the title does.
///
/// The session keeps the records as the protocol's terminal does: a report
/// replaces its record, `clear` removes a record and the records under it, a
/// new shell prompt (OSC 133;A) removes the `working` and `blocked` records,
/// and a full reset removes every record. It keeps at most
/// `max_program_records`, and removes the record that changed least
/// recently to make space. `done` and `error` stay until the program
/// replaces or clears them.
pub const ProgramStatus = struct {
    pub const name = "program_status";
    pub const since = 1;
    pub const senders = from_session;

    records: []const ProgramRecord,
};

/// The most records that a pane keeps (the protocol requires 64 or more).
pub const max_program_records = 64;

/// Every message on a pane channel. A new one goes here.
pub const pane_messages = .{
    State, Attach, Resize,     Claim, Lead,     SnapshotStart, SnapshotEnd, Exit,   Take,          End, Refresh,
    Title, Cwd,    Foreground, Mark,  Progress, Bell,          Activity,    Status, ProgramStatus,
};

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
