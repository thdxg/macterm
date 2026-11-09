//! The Macterm protocol core (design/003, design/006): frames, MessagePack,
//! and the messages on channel 0. Nothing calls it yet.

const std = @import("std");

pub const frame = @import("frame.zig");
pub const msgpack = @import("msgpack.zig");
pub const messages = @import("messages.zig");
pub const schema = @import("schema.zig");

const Bin = msgpack.Bin;
const Secret = msgpack.Secret;
const Raw = msgpack.Raw;

/// Encodes `value` and writes it as one `msg` frame.
pub fn writeMessage(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    channel: u32,
    value: anytype,
) (frame.Error || std.Io.Writer.Error || error{OutOfMemory})!void {
    const body = try msgpack.encodeAlloc(gpa, value);
    defer gpa.free(body);
    try frame.write(w, .{ .channel = channel, .kind = .msg, .body = body });
}

/// True if `T` holds a `Secret` anywhere. No reply and no event may: a
/// saved secret never leaves the GUI through the protocol (design/006 §1).
pub fn holdsSecret(comptime T: type) bool {
    if (T == Secret) return true;
    if (T == Bin or T == Raw or T == []const u8) return false;
    return switch (@typeInfo(T)) {
        .optional => |o| holdsSecret(o.child),
        .pointer => |p| holdsSecret(p.child),
        .@"struct" => |s| inline for (s.field_types) |F| {
            if (holdsSecret(F)) break true;
        } else false,
        else => false,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const m = messages;

const hello: m.Hello = .{
    .level = m.level,
    .min_level = m.min_level,
    .build = "2.0.0-tip.1",
    .role = .gui,
    .epoch = 0x1234_5678_9abc_def0,
    .caps = &.{ "tcc", "password-tty" },
};

/// Frames `value` on channel 0, reads the frame back, and decodes it.
fn throughWire(arena: std.mem.Allocator, value: anytype) !m.Control {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeMessage(arena, &out.writer, frame.control_channel, value);
    const parsed = (try frame.parse(out.written())).?;
    try testing.expectEqual(out.written().len, parsed.len);
    try testing.expectEqual(frame.Kind.msg, parsed.frame.kind);
    return m.decodeControl(arena, parsed.frame.body);
}

test "every message round-trips through a frame" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const h = (try throughWire(arena, hello)).hello;
    try testing.expectEqual(hello.level, h.level);
    try testing.expectEqual(hello.min_level, h.min_level);
    try testing.expectEqualStrings(hello.build, h.build);
    try testing.expectEqual(hello.role, h.role);
    try testing.expectEqual(hello.epoch, h.epoch);
    try testing.expectEqual(2, h.caps.len);
    try testing.expectEqualStrings("password-tty", h.caps[1]);

    const r = (try throughWire(arena, m.Refuse{ .reason = "level_too_low", .needs_level = 4 })).refuse;
    try testing.expectEqualStrings("level_too_low", r.reason);
    try testing.expectEqual(4, r.needs_level);

    // Requests and results of every method.
    var buf: std.Io.Writer.Allocating = .init(arena);
    try m.encodeRequest(&buf.writer, 7, m.ChannelOpen, .{ .session = "macterm-abc" });
    const open = (try throughWire(arena, Raw{ .bytes = buf.written() })).request;
    try testing.expectEqual(7, open.id);
    try testing.expectEqualStrings("channel.open", open.m);
    try testing.expectEqualStrings("macterm-abc", (try m.decodeArgs(m.ChannelOpen, arena, open)).session);

    buf.clearRetainingCapacity();
    try m.encodeResult(&buf.writer, 7, m.ChannelOpen, .{ .channel = 2 });
    const opened = (try throughWire(arena, Raw{ .bytes = buf.written() })).response;
    try testing.expectEqual(7, opened.re);
    try testing.expectEqual(null, opened.err);
    try testing.expectEqual(2, (try m.decodeResult(m.ChannelOpen, arena, opened)).channel);

    buf.clearRetainingCapacity();
    try m.encodeRequest(&buf.writer, 8, m.ChannelClose, .{ .channel = 2 });
    const close = (try throughWire(arena, Raw{ .bytes = buf.written() })).request;
    try testing.expectEqual(2, (try m.decodeArgs(m.ChannelClose, arena, close)).channel);

    buf.clearRetainingCapacity();
    try m.encodeResult(&buf.writer, 8, m.ChannelClose, .{});
    const closed = (try throughWire(arena, Raw{ .bytes = buf.written() })).response;
    try testing.expectEqual(8, closed.re);
    _ = try m.decodeResult(m.ChannelClose, arena, closed);

    // A request with no arguments decodes as an empty map.
    const bare = (try throughWire(arena, m.Request{ .id = 9, .m = "channel.close" })).request;
    try testing.expectEqual(null, bare.a);
    try testing.expectError(error.MissingField, m.decodeArgs(m.ChannelClose, arena, bare));

    const failed = (try throughWire(arena, m.Response{
        .re = 9,
        .err = .{ .code = "unknown_method", .message = "No method pane.fly.", .level = 3 },
    })).response;
    try testing.expectEqual(null, failed.ok);
    try testing.expectEqualStrings("unknown_method", failed.err.?.code);
    try testing.expectEqualStrings("No method pane.fly.", failed.err.?.message);
    try testing.expectEqual(3, failed.err.?.level.?);

    const batch = (try throughWire(arena, m.EventBatch{ .seq = 41, .ev = &.{
        .{ .e = "pane.title", .a = .{ .bytes = &.{ 0x81, 0xa1, 't', 0xa2, 'h', 'x' } } },
        .{ .e = "pane.bell" },
    } })).events;
    try testing.expectEqual(41, batch.seq);
    try testing.expectEqual(2, batch.ev.len);
    try testing.expectEqualStrings("pane.title", batch.ev[0].e);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0xa1, 't', 0xa2, 'h', 'x' }, batch.ev[0].a.?.bytes);
    try testing.expectEqual(null, batch.ev[1].a);
}

test "unknown keys, fields, caps, roles and message kinds are ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A hello from a later build: a new field, a new cap and a new role.
    const Later = struct {
        level: u32,
        min_level: u32,
        build: []const u8,
        role: []const u8,
        epoch: u64,
        caps: []const []const u8,
        region: struct { name: []const u8, ids: []const u64 },
    };
    const h = (try throughWire(arena, Later{
        .level = 9,
        .min_level = 1,
        .build = "3.0.0",
        .role = "relay",
        .epoch = 1,
        .caps = &.{ "tcc", "teleport" },
        .region = .{ .name = "eu", .ids = &.{ 1, 2 } },
    })).hello;
    try testing.expectEqual(9, h.level);
    try testing.expectEqual(m.Role.unknown, h.role);
    try testing.expectEqualStrings("teleport", h.caps[1]);
    try testing.expectEqual(m.Negotiation{ .speak = m.level }, m.negotiate(hello, h));

    // A response with a field that this build does not know.
    const res = (try throughWire(arena, struct { re: u64, ok: struct { channel: u32, extra: bool }, hint: []const u8 }{
        .re = 1,
        .ok = .{ .channel = 5, .extra = true },
        .hint = "x",
    })).response;
    try testing.expectEqual(5, (try m.decodeResult(m.ChannelOpen, arena, res)).channel);

    // A message kind that a later build added.
    try testing.expectEqual(m.Control.unknown, try throughWire(arena, struct { ping: u32 }{ .ping = 1 }));
}

test "a hello under min_level is refused with needs_level" {
    var strict = hello;
    strict.level = 5;
    strict.min_level = 3;
    var old = hello;
    old.level = 2;
    old.min_level = 1;

    const n = m.negotiate(strict, old);
    try testing.expectEqualStrings("level_too_low", n.refuse.reason);
    try testing.expectEqual(3, n.refuse.needs_level);

    // The old side does not refuse: its own minimum holds. The strict side's
    // refusal reaches it.
    try testing.expectEqual(m.Negotiation{ .speak = 2 }, m.negotiate(old, strict));

    var newer = hello;
    newer.level = 4;
    newer.min_level = 3;
    try testing.expectEqual(m.Negotiation{ .speak = 4 }, m.negotiate(strict, newer));
}

test "a CLI refuses any other build, at any level" {
    var cli = hello;
    cli.role = .cli;
    var server = hello;
    server.role = .server;
    try testing.expectEqual(m.Negotiation{ .speak = m.level }, m.negotiate(server, cli));
    server.build = "2.0.0-tip.2";
    try testing.expectEqualStrings("build_mismatch", m.negotiate(server, cli).refuse.reason);
    try testing.expectEqualStrings("build_mismatch", m.negotiate(cli, server).refuse.reason);
    // Two other roles may differ in build.
    var gui = hello;
    gui.build = "2.0.0-tip.9";
    try testing.expectEqual(m.Negotiation{ .speak = m.level }, m.negotiate(server, gui));
}

test "a response has exactly one of ok and err" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.WrongType, throughWire(arena, m.Response{ .re = 1 }));
    try testing.expectError(error.WrongType, throughWire(arena, m.Response{
        .re = 1,
        .ok = .{ .bytes = &.{0x80} },
        .err = .{ .code = "busy", .message = "Busy." },
    }));
    const failed = m.Response{ .re = 1, .err = .{ .code = "busy", .message = "Busy." } };
    try testing.expectError(error.ErrorResponse, m.decodeResult(m.ChannelClose, arena, failed));
}

test "an oversized message is refused before it is written" {
    const big = try testing.allocator.alloc(u8, frame.max_body);
    defer testing.allocator.free(big);
    @memset(big, 0);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.FrameTooLarge, writeMessage(testing.allocator, &out.writer, 1, Bin{ .bytes = big }));
    try testing.expectEqual(0, out.written().len);
}

test "the schema keeps its own rules" {
    try testing.expect(m.Hello.since <= m.level);
    try testing.expect(m.Refuse.since <= m.level);
    try testing.expect(m.min_level <= m.level);
    inline for (m.methods) |M| {
        try testing.expect(M.since <= m.level);
        try testing.expect(M.senders.len > 0);
        try testing.expect(!holdsSecret(M.Result));
    }
    inline for (m.events) |E| {
        try testing.expect(E.since <= m.level);
        try testing.expect(!holdsSecret(E));
    }
    // Responses and events carry `Raw`: the checks are on each method's
    // `Result` and on each event type above.
    try testing.expect(holdsSecret(struct { a: ?[]const struct { s: Secret } }));
}

test "only the local trust may open and close channels" {
    inline for (.{ m.ChannelOpen, m.ChannelClose }) |M| {
        try testing.expect(m.maySend(M, .local));
        try testing.expect(!m.maySend(M, .session));
        try testing.expect(!m.maySend(M, .remote));
    }
    try testing.expect(m.maySend(m.Hello, .remote));
}

test {
    _ = frame;
    _ = msgpack;
    _ = messages;
    _ = schema;
}
