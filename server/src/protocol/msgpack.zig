//! MessagePack for the protocol (design/003 §2), with comptime reflection.
//!
//! `encode` writes a Zig value. `decode` reads one. A struct is a map with
//! string keys, one for each field. These rules make the format add-only:
//!
//! - `encode` leaves out an optional field that is null.
//! - `decode` skips a key that the struct does not have.
//! - `decode` gives a missing field its default value, or null for an
//!   optional field. A missing field with no default is `error.MissingField`.
//!
//! The Zig type sets the wire type:
//!
//! | Zig                  | MessagePack                        |
//! | -------------------- | ---------------------------------- |
//! | `bool`               | bool                               |
//! | integer              | the smallest int that holds it     |
//! | enum                 | str, the tag name (1)              |
//! | `[]const u8`         | str, valid UTF-8                   |
//! | `Bin`                | bin, any bytes                     |
//! | `Secret`             | bin, any bytes (see `Secret`)      |
//! | `Raw`                | one encoded value, copied as it is |
//! | `[]const T`          | array                              |
//! | struct               | map                                |
//!
//! (1) A tag that the enum does not have decodes to `.unknown` if the enum
//! has that tag, and is `error.UnknownEnumTag` if not.
//!
//! `decode` copies nothing: a string, a `Bin` or a `Raw` points into the
//! input. It allocates only the arrays. Give it an arena that lives as long
//! as the input.

const std = @import("std");

/// Bytes that are not text: a path or a command line that is not UTF-8.
pub const Bin = struct {
    bytes: []const u8,
};

/// A password or another secret (design/006 §4). On the wire it is a bin.
/// The type is its own, so that a check on the schema can find every field
/// that holds one, and so that a log line prints no secret.
pub const Secret = struct {
    bytes: []const u8,

    pub fn format(_: Secret, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("<secret>");
    }
};

/// One encoded value, kept as bytes. A request keeps its arguments as `Raw`
/// until it knows the method, and then decodes them with the method's type.
pub const Raw = struct {
    bytes: []const u8,
};

/// The deepest nesting that `decode` and `skip` accept. Input from a host is
/// not trusted, and each level is a stack frame.
pub const max_depth = 32;

pub const DecodeError = error{
    /// The input ends inside a value.
    EndOfInput,
    /// The value has another type than the field.
    WrongType,
    /// An integer does not fit the field.
    Overflow,
    /// A str is not valid UTF-8.
    InvalidUtf8,
    /// A str names no tag of the enum.
    UnknownEnumTag,
    /// A struct field with no default is not in the map.
    MissingField,
    /// A map has one key two times.
    DuplicateField,
    /// The value is nested deeper than `max_depth`.
    TooDeep,
    /// A type byte that MessagePack does not define (0xc1).
    InvalidFormat,
    OutOfMemory,
};

// ── Encode ──────────────────────────────────────────────────────────────────

pub fn encode(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (T) {
        Bin, Secret => return writeBin(w, value.bytes),
        Raw => return w.writeAll(value.bytes),
        []const u8 => return writeStr(w, value),
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => try w.writeByte(if (value) 0xc3 else 0xc2),
        .int, .comptime_int => try writeInt(w, value),
        .@"enum" => try writeStr(w, @tagName(value)),
        .optional => if (value) |v| try encode(w, v) else try w.writeByte(0xc0),
        .pointer => |p| {
            if (p.size != .slice) @compileError("cannot encode " ++ @typeName(T));
            try writeArrayLen(w, value.len);
            for (value) |item| try encode(w, item);
        },
        .@"struct" => |s| {
            var count: usize = 0;
            inline for (s.field_names) |name| {
                if (present(@field(value, name))) count += 1;
            }
            try writeMapLen(w, count);
            inline for (s.field_names) |name| {
                if (present(@field(value, name))) {
                    try writeStr(w, name);
                    try encode(w, @field(value, name));
                }
            }
        },
        else => @compileError("cannot encode " ++ @typeName(T)),
    }
}

fn present(value: anytype) bool {
    return if (@typeInfo(@TypeOf(value)) == .optional) value != null else true;
}

fn writeInt(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    if (value >= 0) {
        const v: u64 = @intCast(value);
        if (v <= 0x7f) return w.writeByte(@intCast(v));
        if (v <= 0xff) {
            try w.writeByte(0xcc);
            return w.writeByte(@intCast(v));
        }
        if (v <= 0xffff) {
            try w.writeByte(0xcd);
            return w.writeInt(u16, @intCast(v), .big);
        }
        if (v <= 0xffff_ffff) {
            try w.writeByte(0xce);
            return w.writeInt(u32, @intCast(v), .big);
        }
        try w.writeByte(0xcf);
        return w.writeInt(u64, v, .big);
    }
    const v: i64 = @intCast(value);
    if (v >= -32) return w.writeByte(@bitCast(@as(i8, @intCast(v))));
    if (v >= std.math.minInt(i8)) {
        try w.writeByte(0xd0);
        return w.writeInt(i8, @intCast(v), .big);
    }
    if (v >= std.math.minInt(i16)) {
        try w.writeByte(0xd1);
        return w.writeInt(i16, @intCast(v), .big);
    }
    if (v >= std.math.minInt(i32)) {
        try w.writeByte(0xd2);
        return w.writeInt(i32, @intCast(v), .big);
    }
    try w.writeByte(0xd3);
    return w.writeInt(i64, v, .big);
}

fn writeStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (s.len <= 31) {
        try w.writeByte(0xa0 | @as(u8, @intCast(s.len)));
    } else if (s.len <= 0xff) {
        try w.writeByte(0xd9);
        try w.writeByte(@intCast(s.len));
    } else if (s.len <= 0xffff) {
        try w.writeByte(0xda);
        try w.writeInt(u16, @intCast(s.len), .big);
    } else {
        try w.writeByte(0xdb);
        try w.writeInt(u32, @intCast(s.len), .big);
    }
    try w.writeAll(s);
}

fn writeBin(w: *std.Io.Writer, b: []const u8) std.Io.Writer.Error!void {
    if (b.len <= 0xff) {
        try w.writeByte(0xc4);
        try w.writeByte(@intCast(b.len));
    } else if (b.len <= 0xffff) {
        try w.writeByte(0xc5);
        try w.writeInt(u16, @intCast(b.len), .big);
    } else {
        try w.writeByte(0xc6);
        try w.writeInt(u32, @intCast(b.len), .big);
    }
    try w.writeAll(b);
}

fn writeArrayLen(w: *std.Io.Writer, len: usize) std.Io.Writer.Error!void {
    if (len <= 15) return w.writeByte(0x90 | @as(u8, @intCast(len)));
    if (len <= 0xffff) {
        try w.writeByte(0xdc);
        return w.writeInt(u16, @intCast(len), .big);
    }
    try w.writeByte(0xdd);
    try w.writeInt(u32, @intCast(len), .big);
}

fn writeMapLen(w: *std.Io.Writer, len: usize) std.Io.Writer.Error!void {
    if (len <= 15) return w.writeByte(0x80 | @as(u8, @intCast(len)));
    if (len <= 0xffff) {
        try w.writeByte(0xde);
        return w.writeInt(u16, @intCast(len), .big);
    }
    try w.writeByte(0xdf);
    try w.writeInt(u32, @intCast(len), .big);
}

/// Encodes `value` into memory from `gpa`. The caller frees the result.
pub fn encodeAlloc(gpa: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    encode(&out.writer, value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// ── Decode ──────────────────────────────────────────────────────────────────

/// Decodes one value of type `T` that fills all of `bytes`.
pub fn decodeSlice(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) DecodeError!T {
    var r: Reader = .{ .bytes = bytes };
    const value = try r.decode(T, arena);
    if (r.pos != bytes.len) return error.WrongType;
    return value;
}

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    depth: u8 = 0,

    pub fn decode(r: *Reader, comptime T: type, arena: std.mem.Allocator) DecodeError!T {
        switch (T) {
            Bin => return .{ .bytes = try r.readBin() },
            Secret => return .{ .bytes = try r.readBin() },
            Raw => {
                const start = r.pos;
                try r.skip();
                return .{ .bytes = r.bytes[start..r.pos] };
            },
            []const u8 => return r.readStr(),
            else => {},
        }
        switch (@typeInfo(T)) {
            .bool => return switch (try r.byte()) {
                0xc2 => false,
                0xc3 => true,
                else => error.WrongType,
            },
            .int => return r.readInt(T),
            .@"enum" => {
                const tag = try r.readStr();
                if (std.meta.stringToEnum(T, tag)) |v| return v;
                return if (@hasField(T, "unknown")) .unknown else error.UnknownEnumTag;
            },
            .optional => |o| {
                if (try r.peek() == 0xc0) {
                    r.pos += 1;
                    return null;
                }
                return try r.decode(o.child, arena);
            },
            .pointer => |p| {
                if (p.size != .slice) @compileError("cannot decode " ++ @typeName(T));
                const len = try r.readArrayLen();
                // Each element takes one byte or more, so a length over the
                // rest of the input is false. Check it before the allocation.
                if (len > r.bytes.len - r.pos) return error.EndOfInput;
                try r.enter();
                defer r.depth -= 1;
                const items = try arena.alloc(p.child, len);
                for (items) |*item| item.* = try r.decode(p.child, arena);
                return items;
            },
            .@"struct" => |s| {
                const len = try r.readMapLen();
                try r.enter();
                defer r.depth -= 1;
                var result: T = undefined;
                var seen: [s.field_names.len]bool = @splat(false);
                for (0..len) |_| {
                    const key = try r.readStr();
                    inline for (s.field_names, s.field_types, 0..) |name, F, i| {
                        if (std.mem.eql(u8, key, name)) {
                            if (seen[i]) return error.DuplicateField;
                            seen[i] = true;
                            @field(result, name) = try r.decode(F, arena);
                            break;
                        }
                    } else try r.skip();
                }
                inline for (s.field_names, s.field_types, s.field_attrs, 0..) |name, F, attrs, i| {
                    if (!seen[i]) {
                        if (attrs.defaultValue(F)) |default| {
                            @field(result, name) = default;
                        } else if (@typeInfo(F) == .optional) {
                            @field(result, name) = null;
                        } else {
                            return error.MissingField;
                        }
                    }
                }
                return result;
            },
            else => @compileError("cannot decode " ++ @typeName(T)),
        }
    }

    fn enter(r: *Reader) DecodeError!void {
        if (r.depth >= max_depth) return error.TooDeep;
        r.depth += 1;
    }

    fn peek(r: *Reader) DecodeError!u8 {
        if (r.pos >= r.bytes.len) return error.EndOfInput;
        return r.bytes[r.pos];
    }

    fn byte(r: *Reader) DecodeError!u8 {
        const b = try r.peek();
        r.pos += 1;
        return b;
    }

    fn take(r: *Reader, n: usize) DecodeError![]const u8 {
        if (n > r.bytes.len - r.pos) return error.EndOfInput;
        const out = r.bytes[r.pos..][0..n];
        r.pos += n;
        return out;
    }

    fn big(r: *Reader, comptime T: type) DecodeError!T {
        const b = try r.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .big);
    }

    fn readInt(r: *Reader, comptime T: type) DecodeError!T {
        const b = try r.byte();
        const wide: i128 = switch (b) {
            0x00...0x7f => b,
            0xe0...0xff => @as(i8, @bitCast(b)),
            0xcc => try r.big(u8),
            0xcd => try r.big(u16),
            0xce => try r.big(u32),
            0xcf => try r.big(u64),
            0xd0 => try r.big(i8),
            0xd1 => try r.big(i16),
            0xd2 => try r.big(i32),
            0xd3 => try r.big(i64),
            else => return error.WrongType,
        };
        return std.math.cast(T, wide) orelse error.Overflow;
    }

    fn readStr(r: *Reader) DecodeError![]const u8 {
        const b = try r.byte();
        const len: usize = switch (b) {
            0xa0...0xbf => b & 0x1f,
            0xd9 => try r.big(u8),
            0xda => try r.big(u16),
            0xdb => try r.big(u32),
            else => return error.WrongType,
        };
        const s = try r.take(len);
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
        return s;
    }

    fn readBin(r: *Reader) DecodeError![]const u8 {
        const len: usize = switch (try r.byte()) {
            0xc4 => try r.big(u8),
            0xc5 => try r.big(u16),
            0xc6 => try r.big(u32),
            else => return error.WrongType,
        };
        return r.take(len);
    }

    fn readArrayLen(r: *Reader) DecodeError!usize {
        const b = try r.byte();
        return switch (b) {
            0x90...0x9f => b & 0x0f,
            0xdc => try r.big(u16),
            0xdd => try r.big(u32),
            else => error.WrongType,
        };
    }

    pub fn readMapLen(r: *Reader) DecodeError!usize {
        const b = try r.byte();
        return switch (b) {
            0x80...0x8f => b & 0x0f,
            0xde => try r.big(u16),
            0xdf => try r.big(u32),
            else => error.WrongType,
        };
    }

    /// Reads past one value of any type. This is how `decode` ignores a key
    /// that it does not know, also one that holds a type it never decodes
    /// (a float, an ext).
    pub fn skip(r: *Reader) DecodeError!void {
        const b = try r.byte();
        switch (b) {
            0x00...0x7f, 0xe0...0xff, 0xc0, 0xc2, 0xc3 => {},
            0xc1 => return error.InvalidFormat,
            0xa0...0xbf => _ = try r.take(b & 0x1f),
            0x80...0x8f => try r.skipItems(@as(usize, b & 0x0f) * 2),
            0x90...0x9f => try r.skipItems(b & 0x0f),
            0xcc, 0xd0 => _ = try r.take(1),
            0xcd, 0xd1 => _ = try r.take(2),
            0xca, 0xce, 0xd2 => _ = try r.take(4),
            0xcb, 0xcf, 0xd3 => _ = try r.take(8),
            0xc4, 0xd9 => _ = try r.take(try r.big(u8)),
            0xc5, 0xda => _ = try r.take(try r.big(u16)),
            0xc6, 0xdb => _ = try r.take(try r.big(u32)),
            0xdc => try r.skipItems(try r.big(u16)),
            0xdd => try r.skipItems(try r.big(u32)),
            0xde => try r.skipItems(@as(usize, try r.big(u16)) * 2),
            0xdf => try r.skipItems(@as(usize, try r.big(u32)) * 2),
            0xd4 => _ = try r.take(2),
            0xd5 => _ = try r.take(3),
            0xd6 => _ = try r.take(5),
            0xd7 => _ = try r.take(9),
            0xd8 => _ = try r.take(17),
            0xc7 => _ = try r.take(@as(usize, try r.big(u8)) + 1),
            0xc8 => _ = try r.take(@as(usize, try r.big(u16)) + 1),
            0xc9 => _ = try r.take(@as(usize, try r.big(u32)) + 1),
        }
    }

    fn skipItems(r: *Reader, n: usize) DecodeError!void {
        try r.enter();
        defer r.depth -= 1;
        for (0..n) |_| try r.skip();
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn roundTrip(comptime T: type, value: T) !T {
    const bytes = try encodeAlloc(testing.allocator, value);
    defer testing.allocator.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const back = try decodeSlice(T, arena.allocator(), bytes);
    // Encode again: the same bytes mean the same value, also for the slices
    // that point into the freed input.
    const again = try encodeAlloc(testing.allocator, back);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
    return value;
}

test "integers use the smallest form and keep their value" {
    const cases = [_]struct { v: i64, len: usize }{
        .{ .v = 0, .len = 1 },                    .{ .v = 127, .len = 1 },
        .{ .v = 128, .len = 2 },                  .{ .v = 255, .len = 2 },
        .{ .v = 256, .len = 3 },                  .{ .v = 65536, .len = 5 },
        .{ .v = 1 << 40, .len = 9 },              .{ .v = -1, .len = 1 },
        .{ .v = -32, .len = 1 },                  .{ .v = -33, .len = 2 },
        .{ .v = -200, .len = 3 },                 .{ .v = -70000, .len = 5 },
        .{ .v = std.math.minInt(i64), .len = 9 },
    };
    for (cases) |c| {
        const bytes = try encodeAlloc(testing.allocator, c.v);
        defer testing.allocator.free(bytes);
        try testing.expectEqual(c.len, bytes.len);
        try testing.expectEqual(c.v, try decodeSlice(i64, testing.allocator, bytes));
    }
    const max = try encodeAlloc(testing.allocator, @as(u64, std.math.maxInt(u64)));
    defer testing.allocator.free(max);
    try testing.expectEqual(std.math.maxInt(u64), try decodeSlice(u64, testing.allocator, max));
}

test "an integer that does not fit the field is refused" {
    const bytes = try encodeAlloc(testing.allocator, @as(u32, 300));
    defer testing.allocator.free(bytes);
    try testing.expectError(error.Overflow, decodeSlice(u8, testing.allocator, bytes));
    const neg = try encodeAlloc(testing.allocator, @as(i32, -1));
    defer testing.allocator.free(neg);
    try testing.expectError(error.Overflow, decodeSlice(u32, testing.allocator, neg));
}

test "strings, bin and secrets keep every length form" {
    var long: [70000]u8 = undefined;
    @memset(&long, 'x');
    for ([_]usize{ 0, 31, 32, 255, 256, 65535, 65536 }) |n| {
        _ = try roundTrip([]const u8, long[0..n]);
        _ = try roundTrip(Bin, .{ .bytes = long[0..n] });
        _ = try roundTrip(Secret, .{ .bytes = long[0..n] });
    }
}

test "a str that is not UTF-8 is refused, and bin carries it" {
    const bad = "\xff\xfe";
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStr(&w, bad);
    try testing.expectError(error.InvalidUtf8, decodeSlice([]const u8, testing.allocator, w.buffered()));
    _ = try roundTrip(Bin, .{ .bytes = bad });
}

test "a secret prints no bytes" {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{Secret{ .bytes = "hunter2" }});
    try testing.expectEqualStrings("<secret>", s);
}

const Sample = struct {
    name: []const u8,
    count: u32 = 7,
    flag: bool,
    kind: enum { one, two },
    note: ?[]const u8 = null,
    tags: []const []const u8,
    raw: Raw,
};

test "a struct round-trips, and a null optional is left out" {
    const value: Sample = .{
        .name = "pane",
        .flag = true,
        .kind = .two,
        .tags = &.{ "a", "b" },
        .raw = .{ .bytes = &.{ 0x93, 1, 2, 3 } },
    };
    _ = try roundTrip(Sample, value);
    const bytes = try encodeAlloc(testing.allocator, value);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u8, 0x86), bytes[0]); // 6 keys: no `note`
}

test "decode ignores unknown keys, and fills defaults and nulls" {
    const Old = struct { name: []const u8 };
    const New = struct {
        name: []const u8,
        extra: struct { deep: []const u32, f: Bin },
        more: []const []const u8,
    };
    const bytes = try encodeAlloc(testing.allocator, New{
        .name = "x",
        .extra = .{ .deep = &.{ 1, 70000 }, .f = .{ .bytes = "\x00" } },
        .more = &.{"y"},
    });
    defer testing.allocator.free(bytes);
    const old = try decodeSlice(Old, testing.allocator, bytes);
    try testing.expectEqualStrings("x", old.name);

    const Newer = struct { name: []const u8, count: u32 = 7, note: ?[]const u8 };
    const newer = try decodeSlice(Newer, testing.allocator, bytes);
    try testing.expectEqual(7, newer.count);
    try testing.expectEqual(null, newer.note);

    const Strict = struct { name: []const u8, needed: u32 };
    try testing.expectError(error.MissingField, decodeSlice(Strict, testing.allocator, bytes));
}

test "skip reads past floats and ext values" {
    // {"a": 1.5 (f64), "b": fixext1, "name": "x"}
    const bytes = [_]u8{ 0x83, 0xa1, 'a', 0xcb, 0, 0, 0, 0, 0, 0, 0, 0 } ++
        [_]u8{ 0xa1, 'b', 0xd4, 1, 2, 0xa4, 'n', 'a', 'm', 'e', 0xa1, 'x' };
    const S = struct { name: []const u8 };
    try testing.expectEqualStrings("x", (try decodeSlice(S, testing.allocator, &bytes)).name);
}

test "hostile input fails cleanly" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const S = struct { a: []const u32 };
    // Truncated in every place.
    const good = try encodeAlloc(testing.allocator, S{ .a = &.{ 1, 2, 300 } });
    defer testing.allocator.free(good);
    for (0..good.len) |n| {
        try testing.expectError(error.EndOfInput, decodeSlice(S, arena, good[0..n]));
    }
    // An array that claims more items than there are bytes allocates nothing.
    const huge = [_]u8{ 0x81, 0xa1, 'a', 0xdd, 0xff, 0xff, 0xff, 0xff };
    try testing.expectError(error.EndOfInput, decodeSlice(S, arena, &huge));
    // Deep nesting in a key that is not known.
    var deep: [3 + 100]u8 = undefined;
    deep[0..3].* = .{ 0x81, 0xa1, 'z' };
    @memset(deep[3..], 0x91);
    deep[deep.len - 1] = 0x90;
    try testing.expectError(error.TooDeep, decodeSlice(S, arena, &deep));
    // A key that comes two times.
    const dup = [_]u8{ 0x82, 0xa1, 'a', 0x90, 0xa1, 'a', 0x90 };
    try testing.expectError(error.DuplicateField, decodeSlice(S, arena, &dup));
    // The reserved type byte.
    const reserved = [_]u8{ 0x81, 0xa1, 'z', 0xc1, 0xa1, 'a', 0x90 };
    try testing.expectError(error.InvalidFormat, decodeSlice(S, arena, &reserved));
}

test "an unknown enum tag is refused, or is .unknown where the enum has it" {
    const E = enum { one };
    const bytes = try encodeAlloc(testing.allocator, @as([]const u8, "two"));
    defer testing.allocator.free(bytes);
    try testing.expectError(error.UnknownEnumTag, decodeSlice(E, testing.allocator, bytes));
    const Open = enum { one, unknown };
    try testing.expectEqual(Open.unknown, try decodeSlice(Open, testing.allocator, bytes));
}
