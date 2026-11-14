//! The packet layer of the roaming link (design/009 §2). No cipher of ours:
//! one reviewed AEAD from the standard library, ChaCha20-Poly1305 (the app's
//! side is CryptoKit's `ChaChaPoly`, which has the same bytes).
//!
//! A packet on the wire:
//!
//!     key_id  u32 LE   names the key; part of the associated data
//!     counter u64 LE   bit 63 is the direction; the rest counts packets
//!     sealed           the payload, then the 16 byte tag
//!
//! The nonce is 4 zero bytes and the counter. Each direction counts from 1 and
//! never repeats under one key. The associated data is the first 12 bytes.
//!
//! This file has only the nonce, the replay window and the roam rule. It does
//! no I/O and keeps no address. Anything that does not authenticate is an
//! error, and the caller sends no reply to it (design/009 §2).

const std = @import("std");
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const key_len = Aead.key_length;
pub const tag_len = Aead.tag_length;
pub const header_len = 12;
/// The least a packet holds: the header and the tag.
pub const overhead = header_len + tag_len;
/// The most that one packet holds. A datagram that fits the common path MTU.
pub const max_packet = 1200;
pub const max_payload = max_packet - overhead;

/// A key that does more than this many packets in one direction is done. The
/// host makes a new key long before (design/009: 24 h).
pub const counter_limit: u64 = 1 << 48;

const direction_bit: u64 = 1 << 63;

/// Who sent a packet. A packet is only good in the direction that its
/// receiver expects, so a reflected packet fails.
pub const Direction = enum(u1) {
    client_to_host = 0,
    host_to_client = 1,
};

pub const Error = error{
    /// The packet is too short or too long.
    Malformed,
    /// Another key, or the packet did not authenticate.
    Rejected,
    /// The direction bit is the receiver's own direction.
    WrongDirection,
    /// The counter was used already, or is too old for the window.
    Replay,
    /// The sender used up its counter.
    Exhausted,
};

/// The most recent counters that the window remembers.
pub const window_bits = 64;

/// What `open` found.
pub const Opened = struct {
    payload: []u8,
    counter: u64,
    /// The counter is higher than any accepted before. Only then may the
    /// caller move the peer's address (Mosh's roam rule, design/009 §2).
    newest: bool,
};

/// One end of a link: the key, the counter of what it sends and the window of
/// what it received. One `Link` for each key, for the life of that key: a
/// second `Link` that starts at counter 1 on the same key repeats nonces, and
/// so does a copy of one. Pass it by pointer.
pub const Link = struct {
    key: [key_len]u8,
    key_id: u32,
    /// The direction of what this end sends.
    sends: Direction,
    next: u64 = 1,
    /// The highest counter that authenticated, 0 before any.
    highest: u64 = 0,
    /// Bit i is set when `highest - i` was accepted.
    seen: u64 = 0,

    pub fn init(key: [key_len]u8, key_id: u32, sends: Direction) Link {
        return .{ .key = key, .key_id = key_id, .sends = sends };
    }

    /// Wipes the key.
    pub fn deinit(l: *Link) void {
        std.crypto.secureZero(u8, &l.key);
    }

    /// Seals `payload` into `out`. Returns the packet, a slice of `out`.
    pub fn seal(l: *Link, out: []u8, payload: []const u8) Error![]u8 {
        if (payload.len > max_payload or out.len < payload.len + overhead) return error.Malformed;
        if (l.next >= counter_limit) return error.Exhausted;
        const counter = l.next | if (l.sends == .host_to_client) direction_bit else 0;
        l.next += 1;
        std.mem.writeInt(u32, out[0..4], l.key_id, .little);
        std.mem.writeInt(u64, out[4..12], counter, .little);
        const body = out[header_len..][0..payload.len];
        var tag: [tag_len]u8 = undefined;
        Aead.encrypt(body, &tag, payload, out[0..header_len], nonce(counter), l.key);
        @memcpy(out[header_len + payload.len ..][0..tag_len], &tag);
        return out[0 .. payload.len + overhead];
    }

    /// Opens `packet` in place. The payload is a slice of `packet`. The
    /// window moves only after the tag is good, so a forged packet changes
    /// no state. After an error the bytes of `packet` are unspecified.
    pub fn open(l: *Link, packet: []u8) Error!Opened {
        if (packet.len < overhead or packet.len > max_packet) return error.Malformed;
        if (std.mem.readInt(u32, packet[0..4], .little) != l.key_id) return error.Rejected;
        const counter = std.mem.readInt(u64, packet[4..12], .little);
        const from_host = counter & direction_bit != 0;
        if (from_host == (l.sends == .host_to_client)) return error.WrongDirection;
        const n = counter & ~direction_bit;
        if (n == 0 or n >= counter_limit) return error.Rejected;
        if (l.replayed(n)) return error.Replay;
        const len = packet.len - overhead;
        const body = packet[header_len..][0..len];
        var tag: [tag_len]u8 = undefined;
        @memcpy(&tag, packet[header_len + len ..][0..tag_len]);
        Aead.decrypt(body, body, tag, packet[0..header_len], nonce(counter), l.key) catch return error.Rejected;
        const newest = n > l.highest;
        l.accept(n);
        return .{ .payload = body, .counter = n, .newest = newest };
    }

    fn replayed(l: *const Link, n: u64) bool {
        if (n > l.highest) return false;
        const back = l.highest - n;
        if (back >= window_bits) return true;
        return (l.seen >> @intCast(back)) & 1 == 1;
    }

    fn accept(l: *Link, n: u64) void {
        if (n > l.highest) {
            const shift = n - l.highest;
            l.seen = if (shift >= window_bits) 0 else l.seen << @intCast(shift);
            l.seen |= 1;
            l.highest = n;
        } else {
            l.seen |= @as(u64, 1) << @intCast(l.highest - n);
        }
    }
};

fn nonce(counter: u64) [Aead.nonce_length]u8 {
    var n: [Aead.nonce_length]u8 = @splat(0);
    std.mem.writeInt(u64, n[4..12], counter, .little);
    return n;
}

const testing = std.testing;

fn testKey() [key_len]u8 {
    var k: [key_len]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    return k;
}

fn pair() struct { client: Link, host: Link } {
    return .{
        .client = Link.init(testKey(), 7, .client_to_host),
        .host = Link.init(testKey(), 7, .host_to_client),
    };
}

test "a packet goes through, both ways" {
    var p = pair();
    var buf: [max_packet]u8 = undefined;
    const pkt = try p.client.seal(&buf, "hello");
    try testing.expectEqual(@as(usize, 5 + overhead), pkt.len);
    const got = try p.host.open(pkt);
    try testing.expectEqualStrings("hello", got.payload);
    try testing.expect(got.newest);
    try testing.expectEqual(@as(u64, 1), got.counter);

    const back = try p.host.seal(&buf, "");
    const got2 = try p.client.open(back);
    try testing.expectEqual(@as(usize, 0), got2.payload.len);
}

// The vector that the Swift test (CryptoKit) checks too:
// MactermTests/Link/LinkPacketTests.swift.
test "the shared test vector" {
    var l = Link.init(testKey(), 0x01020304, .client_to_host);
    var buf: [max_packet]u8 = undefined;
    const pkt = try l.seal(&buf, "macterm link");
    var hex: [max_packet * 2]u8 = undefined;
    const text = std.fmt.bufPrint(&hex, "{x}", .{pkt}) catch unreachable;
    try testing.expectEqualStrings(vector_hex, text);
}

pub const vector_hex = "040302010100000000000000f236902bd058c23845dfc037c34bd5dd6f6bddfca6442b095c60b507";

test "a flipped bit is rejected and changes nothing" {
    var p = pair();
    var buf: [max_packet]u8 = undefined;
    const pkt = try p.client.seal(&buf, "hello");
    var i: usize = 0;
    while (i < pkt.len) : (i += 1) {
        var copy: [max_packet]u8 = undefined;
        @memcpy(copy[0..pkt.len], pkt);
        copy[i] ^= 0x01;
        const result = p.host.open(copy[0..pkt.len]);
        try testing.expect(std.meta.isError(result));
    }
    try testing.expectEqual(@as(u64, 0), p.host.highest);
    var good: [max_packet]u8 = undefined;
    @memcpy(good[0..pkt.len], pkt);
    _ = try p.host.open(good[0..pkt.len]);
}

test "a replayed packet is refused" {
    var p = pair();
    var buf: [max_packet]u8 = undefined;
    const pkt = try p.client.seal(&buf, "x");
    var a: [max_packet]u8 = undefined;
    var b: [max_packet]u8 = undefined;
    @memcpy(a[0..pkt.len], pkt);
    @memcpy(b[0..pkt.len], pkt);
    _ = try p.host.open(a[0..pkt.len]);
    try testing.expectError(error.Replay, p.host.open(b[0..pkt.len]));
}

test "a reflected packet is refused" {
    var p = pair();
    var buf: [max_packet]u8 = undefined;
    const pkt = try p.client.seal(&buf, "x");
    try testing.expectError(error.WrongDirection, p.client.open(pkt));
}

test "another key id is refused" {
    var p = pair();
    var other = Link.init(testKey(), 8, .client_to_host);
    var buf: [max_packet]u8 = undefined;
    const pkt = try other.seal(&buf, "x");
    try testing.expectError(error.Rejected, p.host.open(pkt));
}

test "another key is refused" {
    var p = pair();
    var k = testKey();
    k[0] ^= 1;
    var other = Link.init(k, 7, .client_to_host);
    var buf: [max_packet]u8 = undefined;
    const pkt = try other.seal(&buf, "x");
    try testing.expectError(error.Rejected, p.host.open(pkt));
}

test "the window takes late packets once and drops the too old" {
    var p = pair();
    var bufs: [200][max_packet]u8 = undefined;
    var lens: [200]usize = undefined;
    for (0..200) |i| lens[i] = (try p.client.seal(&bufs[i], "x")).len;
    // 150 first: newest. Then 100 (inside the window): accepted, not newest.
    const r150 = try p.host.open(bufs[149][0..lens[149]]);
    try testing.expect(r150.newest);
    const r100 = try p.host.open(bufs[99][0..lens[99]]);
    try testing.expect(!r100.newest);
    // Again: replay.
    try testing.expectError(error.Replay, p.host.open(bufs[99][0..lens[99]]));
    // 150 - 64 = 86 back: too old.
    try testing.expectError(error.Replay, p.host.open(bufs[0][0..lens[0]]));
    // 199 moves the window; 150 stays accepted-once.
    const r199 = try p.host.open(bufs[198][0..lens[198]]);
    try testing.expect(r199.newest);
    try testing.expectError(error.Replay, p.host.open(bufs[149][0..lens[149]]));
}

test "size limits" {
    var p = pair();
    var buf: [max_packet + 10]u8 = undefined;
    var big: [max_payload + 1]u8 = undefined;
    try testing.expectError(error.Malformed, p.client.seal(&buf, &big));
    var short: [overhead - 1]u8 = undefined;
    try testing.expectError(error.Malformed, p.host.open(&short));
    var long: [max_packet + 1]u8 = undefined;
    try testing.expectError(error.Malformed, p.host.open(&long));
    var full: [max_payload]u8 = undefined;
    @memset(&full, 'a');
    const pkt = try p.client.seal(&buf, &full);
    try testing.expectEqual(@as(usize, max_packet), pkt.len);
    _ = try p.host.open(pkt);
}

test "a spent counter stops the sender" {
    var l = Link.init(testKey(), 1, .client_to_host);
    l.next = counter_limit;
    var buf: [max_packet]u8 = undefined;
    try testing.expectError(error.Exhausted, l.seal(&buf, "x"));
}

test "the window agrees with a plain model" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var p = pair();
    var bufs: [300][max_packet]u8 = undefined;
    var lens: [300]usize = undefined;
    for (0..300) |i| lens[i] = (try p.client.seal(&bufs[i], "x")).len;
    var got: [300]bool = @splat(false);
    var max: u64 = 0;
    for (0..2000) |_| {
        const i = rand.uintLessThan(usize, 300);
        const n: u64 = i + 1;
        var copy: [max_packet]u8 = undefined;
        @memcpy(copy[0..lens[i]], bufs[i][0..lens[i]]);
        const expect_ok = !got[i] and (n > max or max - n < window_bits);
        if (p.host.open(copy[0..lens[i]])) |r| {
            try testing.expect(expect_ok);
            try testing.expectEqual(n > max, r.newest);
            got[i] = true;
            if (n > max) max = n;
        } else |_| try testing.expect(!expect_ok);
    }
}

test "fuzz: no input opens, and the window never moves" {
    try testing.fuzz({}, fuzzOpen, .{});
}

fn fuzzOpen(_: void, smith: *testing.Smith) anyerror!void {
    var l = Link.init(testKey(), 7, .host_to_client);
    var buf: [max_packet + 8]u8 = undefined;
    const len = smith.slice(&buf);
    // Aim some inputs at the header so that they get past the cheap checks.
    if (len >= header_len and smith.value(bool)) {
        std.mem.writeInt(u32, buf[0..4], 7, .little);
        buf[11] &= 0x7f;
    }
    if (l.open(buf[0..len])) |_| {
        return error.ForgeryAccepted;
    } else |_| {}
    try testing.expectEqual(@as(u64, 0), l.highest);
}
