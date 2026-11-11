//! The server's relay of session channels over one client stream
//! (design/003 §1, §6). On a host, the app reaches every pane through one
//! ssh stream: `macterm proxy` joins it to the server's socket, and the
//! server joins each channel to a connection of its own to the session.
//!
//! The order of the stream: channel 0 first, then the pane channels in turn,
//! each with a fair share. A channel whose oldest output or snapshot waits
//! longer than `skip_ms`, or that holds more than `skip_bytes` of them, is
//! skipped ahead: its output and the snapshots that did not start to go out
//! are dropped, and the session sends the screen again. The session's other
//! messages are never dropped. Input is never dropped.
//!
//! This file has the queues and the order. `server.zig` has the sockets.

const std = @import("std");
const frame = @import("protocol/protocol.zig").frame;

/// Output older than this is skipped ahead (design/003 §6: start at 1 s).
/// Measured (scripts/session_bench.py, relay flood, 50 ms round trip and
/// 100 Mbit/s): a flood that fills the link skips ahead about 75 times in
/// each run of a few seconds, which is `skip_bytes` and not the age, and an
/// interrupt shows its prompt after about 210 ms. The age trips only for
/// output a little faster than the link, so 1 s stays.
pub const skip_ms = 1000;

/// A channel with more than this to drop is skipped ahead. The same cap as a
/// session's for one client (`session.client_cap`).
pub const skip_bytes = 1024 * 1024;

/// The most that one channel sends in its turn, when others wait.
pub const quantum = 8 * 1024;

/// The most that goes to the socket in one fill. Channel 0 waits at most
/// behind this much output, plus what the buffers on the way hold.
pub const wire_budget = 32 * 1024;

/// What a frame from the session is to the relay.
pub const Class = enum {
    /// Pane output.
    output,
    /// A message other than the two snapshot markers. Never dropped.
    message,
    snapshot_start,
    /// Snapshot data.
    snapshot,
    snapshot_end,
};

/// Whole frames that wait for one client, in order.
pub const Queue = struct {
    items: std.ArrayList(Item) = .empty,
    head: usize = 0,
    /// The bytes of every frame, headers included.
    bytes: usize = 0,
    /// The start of a snapshot went out, and its end did not.
    sending_snapshot: bool = false,

    pub const Item = struct {
        /// The frame, header included.
        data: []u8,
        /// When it came, in ms.
        at: i64,
        class: Class,
    };

    pub fn deinit(q: *Queue, gpa: std.mem.Allocator) void {
        for (q.items.items[q.head..]) |it| gpa.free(it.data);
        q.items.deinit(gpa);
        q.* = .{};
    }

    pub fn empty(q: *const Queue) bool {
        return q.head == q.items.items.len;
    }

    pub fn push(q: *Queue, gpa: std.mem.Allocator, channel: u32, kind: frame.Kind, body: []const u8, at: i64, class: Class) !void {
        const data = try gpa.alloc(u8, frame.header_len + body.len);
        errdefer gpa.free(data);
        try frame.writeHeader(data[0..frame.header_len], channel, kind, body.len);
        @memcpy(data[frame.header_len..], body);
        try q.items.append(gpa, .{ .data = data, .at = at, .class = class });
        q.bytes += data.len;
    }

    /// The first frame. The caller frees its `data`.
    pub fn pop(q: *Queue) ?Item {
        if (q.empty()) return null;
        const it = q.items.items[q.head];
        q.head += 1;
        q.bytes -= it.data.len;
        switch (it.class) {
            .snapshot_start => q.sending_snapshot = true,
            .snapshot_end => q.sending_snapshot = false,
            else => {},
        }
        if (q.empty()) {
            q.items.clearRetainingCapacity();
            q.head = 0;
        }
        return it;
    }

    pub fn peek(q: *const Queue) ?Item {
        if (q.empty()) return null;
        return q.items.items[q.head];
    }

    /// What a skip would drop: every output frame, and every snapshot whose
    /// start did not go out. The rest of a snapshot that started to go out
    /// stays, so that the client gets its end.
    pub const Stale = struct {
        bytes: usize = 0,
        /// When the oldest of them came.
        oldest: ?i64 = null,
    };

    pub fn stale(q: *const Queue) Stale {
        var out: Stale = .{};
        var keep_snapshot = q.sending_snapshot;
        for (q.items.items[q.head..]) |it| {
            if (!q.dropped(it.class, &keep_snapshot)) continue;
            out.bytes += it.data.len;
            if (out.oldest == null) out.oldest = it.at;
        }
        return out;
    }

    /// Drops what `stale` names. Returns true when a snapshot that started
    /// to go out has not ended in the queue: the rest of it, which the
    /// session still sends, must go out too.
    pub fn dropStale(q: *Queue, gpa: std.mem.Allocator) bool {
        var keep_snapshot = q.sending_snapshot;
        var kept: usize = q.head;
        for (q.items.items[q.head..]) |it| {
            if (q.dropped(it.class, &keep_snapshot)) {
                gpa.free(it.data);
                q.bytes -= it.data.len;
                continue;
            }
            q.items.items[kept] = it;
            kept += 1;
        }
        q.items.shrinkRetainingCapacity(kept);
        if (q.empty()) {
            q.items.clearRetainingCapacity();
            q.head = 0;
        }
        return keep_snapshot;
    }

    /// `keep_snapshot` is true while the frames belong to a snapshot whose
    /// start went out.
    fn dropped(q: *const Queue, class: Class, keep_snapshot: *bool) bool {
        _ = q;
        return switch (class) {
            .output => true,
            .message => false,
            .snapshot_start => true,
            .snapshot => !keep_snapshot.*,
            .snapshot_end => {
                const keep = keep_snapshot.*;
                keep_snapshot.* = false;
                return !keep;
            },
        };
    }
};

/// What a channel does with one frame from its session's pane channel.
pub const Inbound = enum { send, drop };

/// The relay state of one channel, apart from its sockets.
pub const Flow = struct {
    /// The client paused the channel: no output goes out.
    paused: bool = false,
    /// Output goes out again only after a snapshot starts: after a skip or a
    /// resume. `asked_at` is when the server asked for it.
    want_snapshot: bool = false,
    asked_at: i64 = 0,
    /// The frames between `snapshot.start` and `snapshot.end`.
    in_snapshot: bool = false,
    /// A skip dropped the start of the snapshot that comes in now: drop the
    /// rest of it, up to its end.
    discard_snapshot: bool = false,

    /// Sorts one frame that came from the session.
    pub fn classify(f: *Flow, class: Class) Inbound {
        switch (class) {
            .message => return .send,
            .snapshot_start => {
                f.in_snapshot = true;
                f.want_snapshot = false;
                f.discard_snapshot = false;
                return .send;
            },
            .snapshot => return if (f.discard_snapshot) .drop else .send,
            .snapshot_end => {
                f.in_snapshot = false;
                if (f.discard_snapshot) {
                    f.discard_snapshot = false;
                    return .drop;
                }
                return .send;
            },
            .output => return if (f.in_snapshot or f.paused or f.want_snapshot) .drop else .send,
        }
    }

    /// After a skip dropped the queue's stale frames. `open_kept` is what
    /// `Queue.dropStale` returned.
    pub fn skipped(f: *Flow, open_kept: bool, now: i64) void {
        f.discard_snapshot = f.in_snapshot and !open_kept;
        f.want_snapshot = true;
        f.asked_at = now;
    }

    /// True when the channel must skip ahead.
    pub fn mustSkip(f: *const Flow, st: Queue.Stale, now: i64) bool {
        if (f.paused or f.want_snapshot) return false;
        if (st.bytes > skip_bytes) return true;
        const oldest = st.oldest orelse return false;
        return now - oldest >= skip_ms;
    }

    /// True when a snapshot that the server asked for did not come in time
    /// (the session ignored the request: no client attached yet). Ask again.
    pub fn mustAskAgain(f: *const Flow, now: i64) bool {
        return f.want_snapshot and !f.paused and now - f.asked_at >= skip_ms;
    }

    /// The next time that `mustSkip` or `mustAskAgain` can change.
    pub fn deadline(f: *const Flow, st: Queue.Stale) ?i64 {
        if (f.paused) return null;
        if (f.want_snapshot) return f.asked_at + skip_ms;
        const oldest = st.oldest orelse return null;
        return oldest + skip_ms;
    }
};

/// Moves frames into `wire` until it holds `wire_budget` bytes or nothing
/// waits: all of `control` first, then each queue of `channels` in turn from
/// `next.*`, at most `quantum` bytes (and at least one frame) in each turn.
/// `next.*` is where the next fill starts, so that no channel goes first
/// every time. The frames stay whole.
pub fn fill(
    gpa: std.mem.Allocator,
    wire: *std.ArrayList(u8),
    control: *Queue,
    channels: []const *Queue,
    next: *usize,
) !void {
    while (wire.items.len < wire_budget) {
        if (!control.empty()) {
            try take(gpa, wire, control, std.math.maxInt(usize));
            continue;
        }
        const n = channels.len;
        var i: usize = 0;
        const pick = while (i < n) : (i += 1) {
            const k = (next.* + i) % n;
            if (!channels[k].empty()) break k;
        } else return;
        try take(gpa, wire, channels[pick], quantum);
        next.* = (pick + 1) % n;
    }
}

fn take(gpa: std.mem.Allocator, wire: *std.ArrayList(u8), q: *Queue, limit: usize) !void {
    var sent: usize = 0;
    while (q.peek()) |it| {
        if (sent > 0 and sent + it.data.len > limit) return;
        try wire.appendSlice(gpa, it.data);
        sent += it.data.len;
        gpa.free(q.pop().?.data);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The channels of the frames in `wire`, in order.
fn channelsIn(gpa: std.mem.Allocator, wire: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    var rest = wire;
    while ((try frame.parse(rest))) |p| {
        try out.append(gpa, p.frame.channel);
        rest = rest[p.len..];
    }
    try testing.expectEqual(0, rest.len);
    return out.toOwnedSlice(gpa);
}

test "channel 0 goes before any output, also behind a flood" {
    const gpa = testing.allocator;
    var control: Queue = .{};
    defer control.deinit(gpa);
    var flood: Queue = .{};
    defer flood.deinit(gpa);
    const big: [4096]u8 = @splat('x');
    for (0..100) |_| try flood.push(gpa, 1, .bytes, &big, 0, .output);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    var next: usize = 0;

    try fill(gpa, &wire, &control, &.{&flood}, &next);
    // One fill sends at most the budget and one frame.
    try testing.expect(wire.items.len <= wire_budget + big.len + frame.header_len);

    // A reply comes while the flood waits: it goes first in the next fill.
    try control.push(gpa, 0, .msg, &.{0x80}, 0, .message);
    wire.clearRetainingCapacity();
    try fill(gpa, &wire, &control, &.{&flood}, &next);
    const chans = try channelsIn(gpa, wire.items);
    defer gpa.free(chans);
    try testing.expectEqual(0, chans[0]);
}

test "a flooding channel sends one turn, then the other channel's output goes" {
    const gpa = testing.allocator;
    var control: Queue = .{};
    defer control.deinit(gpa);
    var flood: Queue = .{};
    defer flood.deinit(gpa);
    var quiet: Queue = .{};
    defer quiet.deinit(gpa);
    const big: [4096]u8 = @splat('x');
    for (0..200) |_| try flood.push(gpa, 1, .bytes, &big, 0, .output);
    try quiet.push(gpa, 2, .bytes, "k", 0, .output);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    // The flood's turn comes first.
    var next: usize = 0;
    try fill(gpa, &wire, &control, &.{ &flood, &quiet }, &next);
    const chans = try channelsIn(gpa, wire.items);
    defer gpa.free(chans);
    try testing.expectEqual(1, chans[0]);
    var before: usize = 0;
    for (chans) |c| {
        if (c == 2) break;
        before += 1;
    } else return error.TestExpectedEqual;
    // At most one turn of the flood goes before it.
    try testing.expect(before * (big.len + frame.header_len) <= quantum);
}

test "frames stay whole and in order" {
    const gpa = testing.allocator;
    var control: Queue = .{};
    defer control.deinit(gpa);
    var a: Queue = .{};
    defer a.deinit(gpa);
    for (0..5) |i| try a.push(gpa, 1, .bytes, &.{@intCast(i)}, 0, .output);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    var next: usize = 0;
    try fill(gpa, &wire, &control, &.{&a}, &next);
    var rest: []const u8 = wire.items;
    var i: u8 = 0;
    while (try frame.parse(rest)) |p| : (i += 1) {
        try testing.expectEqualSlices(u8, &.{i}, p.frame.body);
        rest = rest[p.len..];
    }
    try testing.expectEqual(5, i);
    try testing.expect(a.empty());
}

fn expectBodies(gpa: std.mem.Allocator, q: *Queue, want: []const []const u8) !void {
    for (want) |w| {
        const it = q.pop().?;
        defer gpa.free(it.data);
        try testing.expectEqualStrings(w, it.data[frame.header_len..]);
    }
    try testing.expect(q.empty());
}

test "a skip drops output and unsent snapshots, and keeps messages in order" {
    const gpa = testing.allocator;
    var q: Queue = .{};
    defer q.deinit(gpa);
    try q.push(gpa, 1, .bytes, "out1", 0, .output);
    try q.push(gpa, 1, .msg, "lead", 0, .message);
    try q.push(gpa, 1, .msg, "start", 0, .snapshot_start);
    try q.push(gpa, 1, .bytes, "snap", 0, .snapshot);
    try q.push(gpa, 1, .msg, "end", 0, .snapshot_end);
    try q.push(gpa, 1, .bytes, "out2", 0, .output);
    try q.push(gpa, 1, .msg, "exit", 0, .message);
    try testing.expect(!q.dropStale(gpa));
    try expectBodies(gpa, &q, &.{ "lead", "exit" });
    try testing.expectEqual(0, q.bytes);
}

test "a skip keeps the rest of a snapshot that started to go out" {
    const gpa = testing.allocator;
    var q: Queue = .{};
    defer q.deinit(gpa);
    try q.push(gpa, 1, .msg, "start", 0, .snapshot_start);
    try q.push(gpa, 1, .bytes, "snap1", 0, .snapshot);
    gpa.free(q.pop().?.data);
    try q.push(gpa, 1, .bytes, "snap2", 0, .snapshot);
    try q.push(gpa, 1, .msg, "end", 0, .snapshot_end);
    try q.push(gpa, 1, .msg, "start2", 0, .snapshot_start);
    try q.push(gpa, 1, .bytes, "snap3", 0, .snapshot);
    // Its end is in the queue: nothing of it comes later.
    try testing.expect(!q.dropStale(gpa));
    try expectBodies(gpa, &q, &.{ "snap1", "snap2", "end" });

    // A snapshot that started to go out and whose end did not come yet.
    try q.push(gpa, 1, .msg, "start", 0, .snapshot_start);
    gpa.free(q.pop().?.data);
    try q.push(gpa, 1, .bytes, "snap", 0, .snapshot);
    try testing.expect(q.dropStale(gpa));
    try expectBodies(gpa, &q, &.{"snap"});
}

test "a skip during an incoming snapshot drops the rest of it, then waits for the next one" {
    var f: Flow = .{};
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_start));
    f.skipped(false, 0);
    try testing.expectEqual(Inbound.drop, f.classify(.snapshot));
    try testing.expectEqual(Inbound.drop, f.classify(.snapshot_end));
    try testing.expectEqual(Inbound.drop, f.classify(.output));
    try testing.expectEqual(Inbound.send, f.classify(.message));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_start));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_end));
    try testing.expectEqual(Inbound.send, f.classify(.output));

    // The snapshot whose start went out comes whole.
    f = .{};
    _ = f.classify(.snapshot_start);
    f.skipped(true, 0);
    try testing.expectEqual(Inbound.send, f.classify(.snapshot));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_end));
}

test "a channel skips ahead when its output or a snapshot is too old or too large" {
    const gpa = testing.allocator;
    var q: Queue = .{};
    defer q.deinit(gpa);
    var f: Flow = .{};
    try testing.expect(!f.mustSkip(q.stale(), 10_000));
    try q.push(gpa, 1, .msg, "m", 0, .message);
    try testing.expect(!f.mustSkip(q.stale(), 10_000));
    try q.push(gpa, 1, .bytes, "x", 100, .output);
    try testing.expect(!f.mustSkip(q.stale(), 100 + skip_ms - 1));
    try testing.expect(f.mustSkip(q.stale(), 100 + skip_ms));
    try testing.expectEqual(100 + skip_ms, f.deadline(q.stale()).?);

    // A queue of snapshots alone, which a slow link let pile up.
    var snaps: Queue = .{};
    defer snaps.deinit(gpa);
    const chunk: [64 * 1024]u8 = @splat('y');
    try snaps.push(gpa, 1, .msg, "start", 0, .snapshot_start);
    for (0..17) |_| try snaps.push(gpa, 1, .bytes, &chunk, 0, .snapshot);
    try testing.expect(f.mustSkip(snaps.stale(), 0));
    // One that started to go out does not count.
    gpa.free(snaps.pop().?.data);
    try testing.expectEqual(0, snaps.stale().bytes);
    try testing.expect(!f.mustSkip(snaps.stale(), 10_000));
}

test "a paused channel drops output and passes messages; a resume waits for a snapshot" {
    var f: Flow = .{ .paused = true };
    try testing.expectEqual(Inbound.drop, f.classify(.output));
    try testing.expectEqual(Inbound.send, f.classify(.message));

    // Resume: output waits for the snapshot that the session sends.
    f = .{ .want_snapshot = true, .asked_at = 0 };
    try testing.expectEqual(Inbound.drop, f.classify(.output));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_start));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_end));
    try testing.expectEqual(Inbound.send, f.classify(.output));
    try testing.expect(!f.want_snapshot);

    // A request that the session ignored is sent again.
    f = .{ .want_snapshot = true, .asked_at = 50 };
    try testing.expect(!f.mustAskAgain(50 + skip_ms - 1));
    try testing.expect(f.mustAskAgain(50 + skip_ms));
}
