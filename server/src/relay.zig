//! The server's relay of session channels over one client stream
//! (design/003 §1, §6). On a host, the app reaches every pane through one
//! ssh stream: `macterm proxy` joins it to the server's socket, and the
//! server joins each channel to a connection of its own to the session.
//!
//! The order of the stream: channel 0 first, then the pane channels in turn,
//! each with a fair share. A channel whose oldest output waits longer than
//! `skip_ms`, or that holds more than `skip_bytes` of output, is skipped
//! ahead: its output is dropped, and the session sends the screen again. A
//! session's own messages and its snapshots are never dropped. Input is
//! never dropped.
//!
//! This file has the queues and the order. `server.zig` has the sockets.

const std = @import("std");
const frame = @import("protocol/protocol.zig").frame;

/// Output older than this is skipped ahead (design/003 §6: start at 1 s).
pub const skip_ms = 1000;

/// A channel with more output than this waiting is skipped ahead. The same
/// cap as a session's for one client (`session.client_cap`).
pub const skip_bytes = 1024 * 1024;

/// The most that one channel sends in its turn, when others wait.
pub const quantum = 8 * 1024;

/// The most that goes to the socket in one fill. Channel 0 waits at most
/// behind this much output, plus what the kernel holds.
pub const wire_budget = 32 * 1024;

/// Whole frames that wait for one client, in order.
pub const Queue = struct {
    items: std.ArrayList(Item) = .empty,
    head: usize = 0,
    /// The bytes of every frame, headers included.
    bytes: usize = 0,
    /// The bytes of the output frames alone.
    output: usize = 0,

    pub const Item = struct {
        /// The frame, header included.
        data: []u8,
        /// When it came, in ms.
        at: i64,
        /// Pane output, which a skip can drop. Not a message or a snapshot.
        output: bool,
    };

    pub fn deinit(q: *Queue, gpa: std.mem.Allocator) void {
        for (q.items.items[q.head..]) |it| gpa.free(it.data);
        q.items.deinit(gpa);
        q.* = .{};
    }

    pub fn empty(q: *const Queue) bool {
        return q.head == q.items.items.len;
    }

    pub fn push(q: *Queue, gpa: std.mem.Allocator, channel: u32, kind: frame.Kind, body: []const u8, at: i64, output: bool) !void {
        const data = try gpa.alloc(u8, frame.header_len + body.len);
        errdefer gpa.free(data);
        try frame.writeHeader(data[0..frame.header_len], channel, kind, body.len);
        @memcpy(data[frame.header_len..], body);
        try q.items.append(gpa, .{ .data = data, .at = at, .output = output });
        q.bytes += data.len;
        if (output) q.output += data.len;
    }

    /// The first frame. The caller frees its `data`.
    pub fn pop(q: *Queue) ?Item {
        if (q.empty()) return null;
        const it = q.items.items[q.head];
        q.head += 1;
        q.bytes -= it.data.len;
        if (it.output) q.output -= it.data.len;
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

    /// When the oldest output came, or null for none.
    pub fn oldestOutput(q: *const Queue) ?i64 {
        if (q.output == 0) return null;
        for (q.items.items[q.head..]) |it| if (it.output) return it.at;
        return null;
    }

    /// Removes every output frame. Messages and snapshots stay, in order.
    pub fn dropOutput(q: *Queue, gpa: std.mem.Allocator) void {
        if (q.output == 0) return;
        var kept: usize = q.head;
        for (q.items.items[q.head..]) |it| {
            if (it.output) {
                gpa.free(it.data);
                q.bytes -= it.data.len;
                continue;
            }
            q.items.items[kept] = it;
            kept += 1;
        }
        q.items.shrinkRetainingCapacity(kept);
        q.output = 0;
        if (q.empty()) {
            q.items.clearRetainingCapacity();
            q.head = 0;
        }
    }
};

/// What a channel does with one frame from its session's pane channel.
pub const Inbound = enum {
    /// Send it to the client: output.
    output,
    /// Send it to the client: a message or snapshot data.
    keep,
    /// Drop it: output while the channel is paused or waits for a snapshot.
    drop,
};

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

    /// `start` and `end` say if a message is `snapshot.start` or
    /// `snapshot.end`.
    pub fn message(f: *Flow, start: bool, end: bool) Inbound {
        if (start) {
            f.in_snapshot = true;
            f.want_snapshot = false;
        } else if (end) f.in_snapshot = false;
        return .keep;
    }

    pub fn bytes(f: *const Flow) Inbound {
        if (f.in_snapshot) return .keep;
        if (f.paused or f.want_snapshot) return .drop;
        return .output;
    }

    /// True when the channel must skip ahead: drop its output and ask the
    /// session for the screen.
    pub fn mustSkip(f: *const Flow, q: *const Queue, now: i64) bool {
        if (f.paused or f.want_snapshot) return false;
        if (q.output > skip_bytes) return true;
        const oldest = q.oldestOutput() orelse return false;
        return now - oldest >= skip_ms;
    }

    /// True when a snapshot that the server asked for did not come in time
    /// (the session dropped the request: no client attached yet). Ask again.
    pub fn mustAskAgain(f: *const Flow, now: i64) bool {
        return f.want_snapshot and !f.paused and now - f.asked_at >= skip_ms;
    }

    /// The next time that `mustSkip` or `mustAskAgain` can change.
    pub fn deadline(f: *const Flow, q: *const Queue) ?i64 {
        if (f.paused) return null;
        if (f.want_snapshot) return f.asked_at + skip_ms;
        const oldest = q.oldestOutput() orelse return null;
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
    for (0..100) |_| try flood.push(gpa, 1, .bytes, &big, 0, true);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    var next: usize = 0;

    try fill(gpa, &wire, &control, &.{&flood}, &next);
    // One fill sends at most the budget and one frame.
    try testing.expect(wire.items.len <= wire_budget + big.len + frame.header_len);

    // A reply comes while the flood waits: it goes first in the next fill.
    try control.push(gpa, 0, .msg, &.{0x80}, 0, false);
    wire.clearRetainingCapacity();
    try fill(gpa, &wire, &control, &.{&flood}, &next);
    const chans = try channelsIn(gpa, wire.items);
    defer gpa.free(chans);
    try testing.expectEqual(0, chans[0]);
}

test "a flooding channel does not delay the other channel's output" {
    const gpa = testing.allocator;
    var control: Queue = .{};
    defer control.deinit(gpa);
    var flood: Queue = .{};
    defer flood.deinit(gpa);
    var quiet: Queue = .{};
    defer quiet.deinit(gpa);
    const big: [4096]u8 = @splat('x');
    for (0..200) |_| try flood.push(gpa, 1, .bytes, &big, 0, true);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    var next: usize = 0;

    // The flood fills the first wire.
    try fill(gpa, &wire, &control, &.{ &flood, &quiet }, &next);
    wire.clearRetainingCapacity();
    // The other pane echoes a key: it goes in the next fill, in its turn.
    try quiet.push(gpa, 2, .bytes, "k", 0, true);
    try fill(gpa, &wire, &control, &.{ &flood, &quiet }, &next);
    const chans = try channelsIn(gpa, wire.items);
    defer gpa.free(chans);
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
    for (0..5) |i| try a.push(gpa, 1, .bytes, &.{@intCast(i)}, 0, true);
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

test "a skip drops output and keeps messages and snapshots in order" {
    const gpa = testing.allocator;
    var q: Queue = .{};
    defer q.deinit(gpa);
    try q.push(gpa, 1, .bytes, "out1", 0, true);
    try q.push(gpa, 1, .msg, "lead", 0, false);
    try q.push(gpa, 1, .bytes, "snap", 0, false);
    try q.push(gpa, 1, .bytes, "out2", 0, true);
    try q.push(gpa, 1, .msg, "exit", 0, false);
    q.dropOutput(gpa);
    try testing.expectEqual(0, q.output);
    const want = [_][]const u8{ "lead", "snap", "exit" };
    for (want) |w| {
        const it = q.pop().?;
        defer gpa.free(it.data);
        try testing.expectEqualStrings(w, it.data[frame.header_len..]);
    }
    try testing.expect(q.empty());
    try testing.expectEqual(0, q.bytes);
}

test "a channel skips ahead when its output is too old or too large" {
    const gpa = testing.allocator;
    var q: Queue = .{};
    defer q.deinit(gpa);
    var f: Flow = .{};
    try testing.expect(!f.mustSkip(&q, 10_000));
    try q.push(gpa, 1, .msg, "m", 0, false);
    try testing.expect(!f.mustSkip(&q, 10_000));
    try q.push(gpa, 1, .bytes, "x", 100, true);
    try testing.expect(!f.mustSkip(&q, 100 + skip_ms - 1));
    try testing.expect(f.mustSkip(&q, 100 + skip_ms));
    try testing.expectEqual(100 + skip_ms, f.deadline(&q).?);

    var big: Queue = .{};
    defer big.deinit(gpa);
    const chunk: [64 * 1024]u8 = @splat('y');
    for (0..17) |_| try big.push(gpa, 1, .bytes, &chunk, 0, true);
    try testing.expect(f.mustSkip(&big, 0));
}

test "a paused channel drops output and passes messages; a resume waits for a snapshot" {
    var f: Flow = .{ .paused = true };
    try testing.expectEqual(Inbound.drop, f.bytes());
    try testing.expectEqual(Inbound.keep, f.message(false, false));

    // Resume: output waits for the snapshot that the session sends.
    f = .{ .want_snapshot = true, .asked_at = 0 };
    try testing.expectEqual(Inbound.drop, f.bytes());
    try testing.expectEqual(Inbound.keep, f.message(true, false));
    try testing.expectEqual(Inbound.keep, f.bytes());
    try testing.expectEqual(Inbound.keep, f.message(false, true));
    try testing.expectEqual(Inbound.output, f.bytes());
    try testing.expect(!f.want_snapshot);

    // A request that the session dropped is sent again.
    f = .{ .want_snapshot = true, .asked_at = 50 };
    try testing.expect(!f.mustAskAgain(50 + skip_ms - 1));
    try testing.expect(f.mustAskAgain(50 + skip_ms));
}
