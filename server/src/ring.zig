//! The output ring of a session (design/003 §7). It holds the last bytes of
//! pane output, so that a client that lost its link for a short time can ask
//! for the bytes after its offset, and get no redraw.
//!
//! An offset counts the output bytes since the session started. The ring
//! grows with the output, up to its cap plus `slack`, so a session with no
//! output holds no memory for it.

const std = @import("std");

/// The most that a ring keeps (design/003 §7: start at 256 KiB).
pub const default_cap = 256 * 1024;

/// A ring drops its oldest bytes only when it holds this much more than its
/// cap, so a flood of output does not move memory for each write. A ring
/// that held a flood keeps its memory: at most cap + slack, 320 KiB.
const slack = 64 * 1024;

pub const Ring = struct {
    bytes: std.ArrayList(u8) = .empty,
    cap: usize = default_cap,
    /// The offset of `bytes[0]`.
    base: u64 = 0,

    pub fn deinit(r: *Ring, gpa: std.mem.Allocator) void {
        r.bytes.deinit(gpa);
        r.* = .{};
    }

    /// The offset after the last byte: the count of all output so far.
    pub fn end(r: *const Ring) u64 {
        return r.base + r.bytes.items.len;
    }

    /// The offset of the first byte that the ring still holds.
    pub fn start(r: *const Ring) u64 {
        return r.base;
    }

    /// Adds output. When memory runs out the ring forgets what it holds but
    /// still counts the bytes, so an offset never goes wrong: a resume then
    /// finds no bytes and gets a snapshot.
    pub fn append(r: *Ring, gpa: std.mem.Allocator, data: []const u8) void {
        if (data.len == 0) return;
        r.bytes.appendSlice(gpa, data) catch {
            r.base = r.end() + data.len;
            r.bytes.clearAndFree(gpa);
            return;
        };
        if (r.bytes.items.len > r.cap + slack) {
            const drop = r.bytes.items.len - r.cap;
            r.bytes.replaceRangeAssumeCapacity(0, drop, &.{});
            r.base += drop;
        }
    }

    /// The bytes after `offset`, or null when the ring lost some of them
    /// (`offset` is before `start`) or the offset is ahead of the output.
    pub fn since(r: *const Ring, offset: u64) ?[]const u8 {
        if (offset < r.base or offset > r.end()) return null;
        return r.bytes.items[@intCast(offset - r.base)..];
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a ring with no output holds no memory and resumes at offset 0" {
    var r: Ring = .{};
    defer r.deinit(testing.allocator);
    try testing.expectEqual(0, r.bytes.capacity);
    try testing.expectEqual(0, r.end());
    try testing.expectEqualStrings("", r.since(0).?);
    try testing.expectEqual(null, r.since(1));
}

test "since gives the bytes after an offset" {
    var r: Ring = .{};
    defer r.deinit(testing.allocator);
    r.append(testing.allocator, "hello ");
    r.append(testing.allocator, "world");
    try testing.expectEqual(11, r.end());
    try testing.expectEqualStrings("hello world", r.since(0).?);
    try testing.expectEqualStrings("world", r.since(6).?);
    try testing.expectEqualStrings("", r.since(11).?);
    // A client cannot be ahead of the output.
    try testing.expectEqual(null, r.since(12));
}

test "the oldest bytes go over the cap, and an offset before them gets no bytes" {
    var r: Ring = .{ .cap = 16 };
    defer r.deinit(testing.allocator);
    const chunk: [1024]u8 = @splat('a');
    for (0..200) |_| r.append(testing.allocator, &chunk);
    try testing.expectEqual(200 * 1024, r.end());
    // It never holds more than the cap and the slack.
    try testing.expect(r.end() - r.start() <= 16 + slack);
    try testing.expect(r.end() - r.start() >= 16);
    try testing.expectEqual(null, r.since(0));
    try testing.expectEqual(null, r.since(r.start() - 1));
    try testing.expectEqual(r.end() - r.start(), r.since(r.start()).?.len);
    // The last 16 bytes are always there.
    try testing.expectEqual(16, r.since(r.end() - 16).?.len);
}

test "the bytes stay in order across a drop" {
    var r: Ring = .{ .cap = 16 };
    defer r.deinit(testing.allocator);
    var big: [slack]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast(i % 251);
    r.append(testing.allocator, &big);
    r.append(testing.allocator, "0123456789");
    const tail = r.since(r.end() - 10).?;
    try testing.expectEqualStrings("0123456789", tail);
}
