//! The frame format (design/003 §1). One format on every link: a Unix socket
//! and an ssh stdio stream.
//!
//! `length u32` · `channel u32` · `kind u8` · body
//!
//! The header is little-endian. `length` counts the body only. A body is at
//! most `max_body` bytes.
//!
//! Channel 0 is control and carries only `msg`. Each other channel is one
//! pane: `bytes` is raw pty output or input, `msg` is the session's own
//! messages. Pane bytes never go through the MessagePack encoder.

const std = @import("std");

pub const header_len = 9;

/// 16 MiB.
pub const max_body = 16 * 1024 * 1024;

pub const control_channel: u32 = 0;

pub const Kind = enum(u8) {
    /// One MessagePack value.
    msg = 0,
    /// Raw pty bytes.
    bytes = 1,
    _,
};

pub const Frame = struct {
    channel: u32,
    kind: Kind,
    body: []const u8,
};

pub const Error = error{
    /// The header gives a body over `max_body`. The peer is broken or
    /// hostile: close the link.
    FrameTooLarge,
    /// A `bytes` frame (or a kind this build does not know) on channel 0.
    NotAMessage,
};

pub fn writeHeader(buf: *[header_len]u8, channel: u32, kind: Kind, body_len: usize) Error!void {
    if (body_len > max_body) return error.FrameTooLarge;
    std.mem.writeInt(u32, buf[0..4], @intCast(body_len), .little);
    std.mem.writeInt(u32, buf[4..8], channel, .little);
    buf[8] = @backingInt(kind);
}

pub fn write(w: *std.Io.Writer, frame: Frame) (Error || std.Io.Writer.Error)!void {
    if (frame.channel == control_channel and frame.kind != .msg) return error.NotAMessage;
    var header: [header_len]u8 = undefined;
    try writeHeader(&header, frame.channel, frame.kind, frame.body.len);
    try w.writeAll(&header);
    try w.writeAll(frame.body);
}

pub const Parsed = struct {
    frame: Frame,
    /// The bytes that the frame takes in the input, header included.
    len: usize,
};

/// Reads one frame from the start of `buf`. Null means `buf` holds no whole
/// frame yet: read more and call again. An oversized length is an error as
/// soon as the header is in, before any of the body arrives.
///
/// A kind that this build does not know is returned as it is on a pane
/// channel, so that the caller can ignore it. On channel 0 it is an error.
pub fn parse(buf: []const u8) Error!?Parsed {
    if (buf.len < header_len) return null;
    const len = std.mem.readInt(u32, buf[0..4], .little);
    if (len > max_body) return error.FrameTooLarge;
    const channel = std.mem.readInt(u32, buf[4..8], .little);
    const kind: Kind = @fromBackingInt(@intCast(buf[8]));
    if (channel == control_channel and kind != .msg) return error.NotAMessage;
    const total = header_len + @as(usize, len);
    if (buf.len < total) return null;
    return .{
        .frame = .{ .channel = channel, .kind = kind, .body = buf[header_len..total] },
        .len = total,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a frame round-trips, and a short buffer asks for more" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .channel = 3, .kind = .bytes, .body = "ls\r" });
    try write(&w, .{ .channel = 0, .kind = .msg, .body = &.{0x80} });
    const out = w.buffered();
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 3, 0, 0, 0, 1, 'l', 's', '\r' }, out[0..12]);

    for (0..12) |n| try testing.expectEqual(null, try parse(out[0..n]));
    const first = (try parse(out)).?;
    try testing.expectEqual(12, first.len);
    try testing.expectEqual(3, first.frame.channel);
    try testing.expectEqual(Kind.bytes, first.frame.kind);
    try testing.expectEqualStrings("ls\r", first.frame.body);
    const second = (try parse(out[first.len..])).?;
    try testing.expectEqual(Kind.msg, second.frame.kind);
    try testing.expectEqualSlices(u8, &.{0x80}, second.frame.body);
}

test "an empty body is a frame" {
    const p = (try parse(&.{ 0, 0, 0, 0, 1, 0, 0, 0, 1 })).?;
    try testing.expectEqual(9, p.len);
    try testing.expectEqual(0, p.frame.body.len);
}

test "an oversized frame is refused from its header alone" {
    var header: [header_len]u8 = undefined;
    try testing.expectError(error.FrameTooLarge, writeHeader(&header, 1, .bytes, max_body + 1));
    try writeHeader(&header, 1, .bytes, max_body);
    try testing.expectEqual(null, try parse(&header));
    std.mem.writeInt(u32, header[0..4], max_body + 1, .little);
    try testing.expectError(error.FrameTooLarge, parse(&header));
    std.mem.writeInt(u32, header[0..4], std.math.maxInt(u32), .little);
    try testing.expectError(error.FrameTooLarge, parse(&header));
}

test "channel 0 carries only messages" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.NotAMessage, write(&w, .{ .channel = 0, .kind = .bytes, .body = "x" }));
    try testing.expectError(error.NotAMessage, parse(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try testing.expectError(error.NotAMessage, parse(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 9 }));
}

test "a pane channel passes a kind this build does not know" {
    const p = (try parse(&.{ 0, 0, 0, 0, 2, 0, 0, 0, 9 })).?;
    try testing.expectEqual(@as(Kind, @fromBackingInt(@intCast(9))), p.frame.kind);
}
