//! The schema of the protocol, read from `messages.zig` by comptime
//! reflection (design/003 §3). The server binary's hidden `__schema` command
//! writes three files from it (`scripts/protocol.sh`):
//!
//! - `metadata`: every message, method, event, type and field, with `since`
//!   and the trust levels that may send each one (`server/schema/protocol.json`);
//! - `swift`: the Swift types of the app (`Macterm/Protocol/MactermProtocol.generated.swift`);
//! - `fixtures`: frames that this Zig code encodes, which the Swift tests
//!   decode and encode again (`server/schema/frames.json`).
//!
//! `check` compares the metadata of this build with an older one: the
//! add-only rule of `messages.zig` as a test, and no saved secret in a reply
//! or an event (design/006 §1).

const std = @import("std");
const msgpack = @import("msgpack.zig");
const messages = @import("messages.zig");
const frame = @import("frame.zig");

const Bin = msgpack.Bin;
const Secret = msgpack.Secret;
const Raw = msgpack.Raw;

// ── Metadata ────────────────────────────────────────────────────────────────

pub const Field = struct {
    /// The key on the wire.
    name: []const u8,
    /// `bool`, `u8` to `u64`, `i8` to `i64`, `str`, `bin`, `secret`, `raw`,
    /// `[T]` for an array, or the name of a type in `types`.
    type: []const u8,
    optional: bool = false,
    /// The value that a decoder uses when the key is not there: a number,
    /// `true` or `false`, an enum tag, `[]`, or a JSON string.
    default: ?[]const u8 = null,
    since: u32,
};

pub const TypeDef = struct {
    /// The Zig name under `messages.zig`: `Hello`, `ChannelOpen.Args`.
    name: []const u8,
    kind: enum { @"struct", @"enum" },
    fields: []const Field = &.{},
    cases: []const []const u8 = &.{},
};

pub const Message = struct {
    /// The name on the wire.
    name: []const u8,
    /// Its type in `types`.
    type: []const u8,
    since: u32,
    senders: []const []const u8,
};

pub const Method = struct {
    name: []const u8,
    /// The Zig name of the method: `ChannelOpen`.
    type: []const u8,
    since: u32,
    senders: []const []const u8,
    args: []const u8,
    result: []const u8,
};

pub const Metadata = struct {
    level: u32,
    min_level: u32,
    trust: []const []const u8,
    /// The frozen first messages: `hello` and `refuse`.
    messages: []const Message,
    /// The types of the requests, responses, event batches and pane messages.
    envelopes: []const []const u8,
    methods: []const Method,
    events: []const Message,
    /// The messages on a pane channel, in `{t, a}`. Empty in metadata from
    /// before they were added.
    pane_messages: []const Message = &.{},
    types: []const TypeDef,
};

/// The schema of this build.
pub const metadata: Metadata = build();

fn build() Metadata {
    @setEvalBranchQuota(100_000);
    comptime {
        const handshake = .{ messages.Hello, messages.Refuse };
        const envelopes = .{ messages.Request, messages.Response, messages.EventBatch, messages.PaneMessage };

        var types: []const type = &.{};
        for (handshake) |T| types = collect(T, types);
        for (envelopes) |T| types = collect(T, types);
        for (messages.methods) |M| types = collect(M.Result, collect(M.Args, types));
        for (messages.events) |E| types = collect(E, types);
        for (messages.pane_messages) |P| types = collect(P, types);

        var handshake_out: [handshake.len]Message = undefined;
        for (handshake, 0..) |T, i| handshake_out[i] = message(T);
        var envelope_out: [envelopes.len][]const u8 = undefined;
        for (envelopes, 0..) |T, i| envelope_out[i] = shortName(T);
        var method_out: [messages.methods.len]Method = undefined;
        for (messages.methods, 0..) |M, i| method_out[i] = .{
            .name = M.name,
            .type = shortName(M),
            .since = M.since,
            .senders = trustNames(M.senders),
            .args = shortName(M.Args),
            .result = shortName(M.Result),
        };
        var event_out: [messages.events.len]Message = undefined;
        for (messages.events, 0..) |E, i| event_out[i] = message(E);
        var pane_out: [messages.pane_messages.len]Message = undefined;
        for (messages.pane_messages, 0..) |P, i| pane_out[i] = message(P);
        var type_out: [types.len]TypeDef = undefined;
        for (types, 0..) |T, i| type_out[i] = typeDef(T);
        // Swift declares a nested type in an extension of its parent, so the
        // parent must be a method or a type of the schema.
        for (type_out) |t| {
            const dot = std.mem.lastIndexOfScalar(u8, t.name, '.') orelse continue;
            const parent = t.name[0..dot];
            const known = for (method_out) |m| {
                if (std.mem.eql(u8, m.type, parent)) break true;
            } else for (type_out) |o| {
                if (std.mem.eql(u8, o.name, parent)) break true;
            } else false;
            if (!known) @compileError(t.name ++ ": declare it in a method or in a type of the schema");
        }

        const trust = std.meta.fieldNames(messages.Trust);
        var trust_out: [trust.len][]const u8 = undefined;
        for (trust, 0..) |name, i| trust_out[i] = name;

        const h = handshake_out;
        const e = envelope_out;
        const ms = method_out;
        const ev = event_out;
        const pm = pane_out;
        const ty = type_out;
        const tr = trust_out;
        return .{
            .level = messages.level,
            .min_level = messages.min_level,
            .trust = &tr,
            .messages = &h,
            .envelopes = &e,
            .methods = &ms,
            .events = &ev,
            .pane_messages = &pm,
            .types = &ty,
        };
    }
}

fn message(comptime T: type) Message {
    return .{
        .name = T.name,
        .type = shortName(T),
        .since = T.since,
        .senders = trustNames(T.senders),
    };
}

fn trustNames(comptime senders: []const messages.Trust) []const []const u8 {
    comptime {
        var out: [senders.len][]const u8 = undefined;
        for (senders, 0..) |t, i| out[i] = @tagName(t);
        const final = out;
        return &final;
    }
}

/// Adds `T` and every struct and enum that it holds to `list`.
fn collect(comptime T: type, comptime list: []const type) []const type {
    comptime {
        switch (T) {
            Bin, Secret, Raw, []const u8 => return list,
            else => {},
        }
        for (list) |L| if (L == T) return list;
        switch (@typeInfo(T)) {
            .optional => |o| return collect(o.child, list),
            .pointer => |p| return collect(p.child, list),
            .@"enum" => return list ++ &[_]type{T},
            .@"struct" => |s| {
                var out: []const type = list ++ &[_]type{T};
                for (s.field_types) |F| out = collect(F, out);
                return out;
            },
            else => return list,
        }
    }
}

/// The name of a type declared in `messages.zig`, without its module path.
fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const marker = "messages.";
    const i = std.mem.lastIndexOf(u8, full, marker) orelse
        @compileError("declare " ++ full ++ " by name in messages.zig");
    return full[i + marker.len ..];
}

fn wireType(comptime T: type) []const u8 {
    switch (T) {
        bool => return "bool",
        Bin => return "bin",
        Secret => return "secret",
        Raw => return "raw",
        []const u8 => return "str",
        u8, u16, u32, u64, i8, i16, i32, i64 => return @typeName(T),
        else => {},
    }
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice and @typeInfo(p.child) != .optional)
            "[" ++ wireType(p.child) ++ "]"
        else
            @compileError("no wire type for " ++ @typeName(T)),
        .@"struct", .@"enum" => shortName(T),
        else => @compileError("no wire type for " ++ @typeName(T)),
    };
}

fn typeDef(comptime T: type) TypeDef {
    comptime {
        switch (@typeInfo(T)) {
            .@"enum" => |e| {
                var cases: [e.field_names.len][]const u8 = undefined;
                for (e.field_names, 0..) |name, i| {
                    checkName(name);
                    cases[i] = name;
                }
                const final = cases;
                return .{ .name = shortName(T), .kind = .@"enum", .cases = &final };
            },
            .@"struct" => |s| {
                var fields: [s.field_names.len]Field = undefined;
                for (s.field_names, s.field_types, s.field_attrs, 0..) |name, F, attrs, i| {
                    checkName(name);
                    const optional = @typeInfo(F) == .optional;
                    const Inner = if (optional) @typeInfo(F).optional.child else F;
                    if (optional and attrs.defaultValue(F) != null and attrs.defaultValue(F).? != null)
                        @compileError(name ++ ": an optional field has no default but null");
                    fields[i] = .{
                        .name = name,
                        .type = wireType(Inner),
                        .optional = optional,
                        .default = if (optional) null else if (attrs.defaultValue(F)) |d| defaultText(F, d) else null,
                        .since = fieldSince(T, name),
                    };
                }
                const final = fields;
                return .{ .name = shortName(T), .kind = .@"struct", .fields = &final };
            },
            else => unreachable,
        }
    }
}

/// A field's level: `T.field_since.<name>` for a field added after its type,
/// else the type's own `since`, else the `since` of the method whose `Args`
/// or `Result` it is, else 1. A new field in a type of an older
/// level must name its level in `field_since`; `check` refuses it if not.
fn fieldSince(comptime T: type, comptime name: []const u8) u32 {
    if (@hasDecl(T, "field_since") and @hasField(@TypeOf(T.field_since), name))
        return @field(T.field_since, name);
    if (@hasDecl(T, "since")) return T.since;
    for (messages.methods) |M| {
        if (T == M.Args or T == M.Result) return M.since;
    }
    return 1;
}

/// Names that the generated Swift uses for its own locals.
const reserved_names = [_][]const u8{ "self", "key", "reader", "writer", "key_count" };

/// A field name or an enum tag must be a snake_case identifier: the Swift
/// side compares it as a String, and only for ASCII is that the same as the
/// byte compare of the Zig side.
fn checkName(comptime name: []const u8) void {
    comptime {
        if (name.len == 0 or !std.ascii.isLower(name[0]))
            @compileError("'" ++ name ++ "' must start with a lowercase letter");
        for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_'))
            @compileError("'" ++ name ++ "' must be snake_case: a to z, 0 to 9 and _");
        if (std.mem.indexOf(u8, name, "__") != null or name[name.len - 1] == '_')
            @compileError("'" ++ name ++ "' has an _ that the Swift name cannot keep");
        for (reserved_names) |r| if (std.mem.eql(u8, r, name))
            @compileError("'" ++ name ++ "' is a name that the generated Swift uses");
    }
}

fn defaultText(comptime F: type, comptime value: F) []const u8 {
    if (F == bool) return if (value) "true" else "false";
    if (F == []const u8) {
        for (value) |c| if (c == '"' or c == '\\' or c < 0x20)
            @compileError("a default string has a quote, a backslash or a control character");
        return "\"" ++ value ++ "\"";
    }
    return switch (@typeInfo(F)) {
        .int => std.fmt.comptimePrint("{d}", .{value}),
        .@"enum" => @tagName(value),
        .pointer => if (value.len == 0) "[]" else @compileError("a default array must be empty"),
        else => @compileError("no default of type " ++ @typeName(F)),
    };
}

pub fn writeMetadata(w: *std.Io.Writer, meta: Metadata) std.Io.Writer.Error!void {
    try std.json.Stringify.value(meta, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, w);
    try w.writeByte('\n');
}

// ── Check ───────────────────────────────────────────────────────────────────

/// Writes one line for each change from `old` to `new` that an older peer
/// could not read, and for each reply or event that holds a `secret`.
/// Returns the count of lines. `old` is null when there is no older
/// metadata: only the secret check runs.
pub fn check(w: *std.Io.Writer, old: ?Metadata, new: Metadata) std.Io.Writer.Error!usize {
    var n: usize = 0;

    if (new.min_level > new.level) {
        try w.print("min_level {d} is over level {d}\n", .{ new.min_level, new.level });
        n += 1;
    }

    for (new.methods) |method| {
        if (holdsSecret(new, method.result, 0)) {
            try w.print("method {s}: its result holds a secret\n", .{method.name});
            n += 1;
        }
    }
    for (new.events) |event| {
        if (holdsSecret(new, event.type, 0)) {
            try w.print("event {s} holds a secret\n", .{event.name});
            n += 1;
        }
    }
    // A pane message goes to every client of the session, as an event does.
    for (new.pane_messages) |msg| {
        if (holdsSecret(new, msg.type, 0)) {
            try w.print("pane message {s} holds a secret\n", .{msg.name});
            n += 1;
        }
    }

    const o = old orelse return n;

    if (new.level < o.level) {
        try w.print("level went down from {d} to {d}\n", .{ o.level, new.level });
        n += 1;
    }

    n += try checkMessages(w, "message", o.messages, new.messages, new.level);
    n += try checkMessages(w, "event", o.events, new.events, new.level);
    n += try checkMessages(w, "pane message", o.pane_messages, new.pane_messages, new.level);

    for (o.methods) |om| {
        const nm = findName(Method, new.methods, om.name) orelse {
            try w.print("method {s} was removed\n", .{om.name});
            n += 1;
            continue;
        };
        if (nm.since != om.since) {
            try w.print("method {s}: since changed from {d} to {d}\n", .{ om.name, om.since, nm.since });
            n += 1;
        }
        if (!std.mem.eql(u8, nm.args, om.args) or !std.mem.eql(u8, nm.result, om.result)) {
            try w.print("method {s}: its args or result type changed\n", .{om.name});
            n += 1;
        }
    }
    for (new.methods) |nm| {
        if (findName(Method, o.methods, nm.name) == null and nm.since != new.level) {
            try w.print("method {s} is new, but its since is {d}, not {d}\n", .{ nm.name, nm.since, new.level });
            n += 1;
        }
    }

    for (o.envelopes) |name| {
        for (new.envelopes) |e| {
            if (std.mem.eql(u8, e, name)) break;
        } else {
            try w.print("envelope {s} was removed\n", .{name});
            n += 1;
        }
    }

    for (new.types) |nt| {
        if (findName(TypeDef, o.types, nt.name) != null) continue;
        for (nt.fields) |nf| {
            if (nf.since != new.level) {
                try w.print("{s}.{s} is new, but its since is {d}, not {d}\n", .{ nt.name, nf.name, nf.since, new.level });
                n += 1;
            }
        }
    }

    for (o.types) |ot| {
        const nt = findName(TypeDef, new.types, ot.name) orelse {
            try w.print("type {s} was removed\n", .{ot.name});
            n += 1;
            continue;
        };
        if (nt.kind != ot.kind) {
            try w.print("type {s}: its kind changed\n", .{ot.name});
            n += 1;
            continue;
        }
        for (ot.cases) |case| {
            for (nt.cases) |c| {
                if (std.mem.eql(u8, c, case)) break;
            } else {
                try w.print("enum {s}: case {s} was removed\n", .{ ot.name, case });
                n += 1;
            }
        }
        // An older peer refuses a tag that it does not know, unless the enum
        // has `unknown`.
        const open = for (ot.cases) |c| {
            if (std.mem.eql(u8, c, "unknown")) break true;
        } else false;
        if (!open) for (nt.cases) |case| {
            for (ot.cases) |c| {
                if (std.mem.eql(u8, c, case)) break;
            } else {
                try w.print("enum {s}: case {s} is new, but the enum has no unknown case\n", .{ ot.name, case });
                n += 1;
            }
        };
        for (ot.fields) |of| {
            const nf = findName(Field, nt.fields, of.name) orelse {
                try w.print("{s}.{s} was removed\n", .{ ot.name, of.name });
                n += 1;
                continue;
            };
            if (!std.mem.eql(u8, nf.type, of.type) or nf.optional != of.optional or
                !optionalEql(nf.default, of.default))
            {
                try w.print("{s}.{s}: its type or default changed\n", .{ ot.name, of.name });
                n += 1;
            }
            if (nf.since != of.since) {
                try w.print("{s}.{s}: since changed from {d} to {d}\n", .{ ot.name, of.name, of.since, nf.since });
                n += 1;
            }
        }
        for (nt.fields) |nf| {
            if (findName(Field, ot.fields, nf.name) != null) continue;
            if (!nf.optional and nf.default == null) {
                try w.print("{s}.{s} is new, but it is not optional and has no default\n", .{ ot.name, nf.name });
                n += 1;
            }
            if (nf.since != new.level) {
                try w.print("{s}.{s} is new, but its since is {d}, not {d}\n", .{ ot.name, nf.name, nf.since, new.level });
                n += 1;
            }
        }
    }
    return n;
}

fn checkMessages(
    w: *std.Io.Writer,
    comptime what: []const u8,
    old: []const Message,
    new: []const Message,
    level: u32,
) std.Io.Writer.Error!usize {
    var n: usize = 0;
    for (old) |om| {
        const nm = findName(Message, new, om.name) orelse {
            try w.print(what ++ " {s} was removed\n", .{om.name});
            n += 1;
            continue;
        };
        if (nm.since != om.since or !std.mem.eql(u8, nm.type, om.type)) {
            try w.print(what ++ " {s}: its since or type changed\n", .{om.name});
            n += 1;
        }
    }
    for (new) |nm| {
        if (findName(Message, old, nm.name) == null and nm.since != level) {
            try w.print(what ++ " {s} is new, but its since is {d}, not {d}\n", .{ nm.name, nm.since, level });
            n += 1;
        }
    }
    return n;
}

fn findName(comptime T: type, items: []const T, name: []const u8) ?T {
    for (items) |item| if (std.mem.eql(u8, item.name, name)) return item;
    return null;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn holdsSecret(meta: Metadata, type_name: []const u8, depth: usize) bool {
    var t = type_name;
    while (t.len >= 2 and t[0] == '[') t = t[1 .. t.len - 1];
    if (std.mem.eql(u8, t, "secret")) return true;
    // Types cannot nest deeper than there are types; this stops a cycle.
    if (depth > meta.types.len) return false;
    const def = findName(TypeDef, meta.types, t) orelse return false;
    for (def.fields) |f| if (holdsSecret(meta, f.type, depth + 1)) return true;
    return false;
}

// ── Swift ───────────────────────────────────────────────────────────────────

pub fn writeSwift(w: *std.Io.Writer, meta: Metadata) std.Io.Writer.Error!void {
    try w.writeAll(
        \\import Foundation
        \\
        \\/// Generated by the server binary's `__schema swift` from server/src/protocol/messages.zig.
        \\/// Do not edit. Run `mise run protocol` after a change to the Zig schema.
        \\enum MactermProtocol {
        \\
    );
    try w.print("    /// The level that this build speaks. It counts additions to the protocol.\n", .{});
    try w.print("    static let level: UInt32 = {d}\n", .{meta.level});
    try w.print("    /// The lowest level that this build accepts from a peer.\n", .{});
    try w.print("    static let minLevel: UInt32 = {d}\n\n", .{meta.min_level});
    try w.writeAll("    /// How a connection came, and so what its peer may send (design/006 §2).\n");
    try w.writeAll("    enum Trust: String {\n");
    for (meta.trust) |t| try w.print("        case {f}\n", .{swiftName(t)});
    try w.writeAll("    }\n}\n");

    for (meta.methods) |method| {
        try w.print(
            \\
            \\extension MactermProtocol {{
            \\    enum {s}: ProtocolMethod {{
            \\        static let name = "{s}"
            \\        static let since: UInt32 = {d}
            \\        static let senders: [MactermProtocol.Trust] = {f}
            \\    }}
            \\}}
            \\
        , .{ method.type, method.name, method.since, swiftSenders(method.senders) });
    }

    for (meta.types) |t| try writeSwiftType(w, t);

    for (meta.messages) |msg| try writeSwiftMessage(w, msg);
    for (meta.events) |ev| try writeSwiftMessage(w, ev);
    for (meta.pane_messages) |pm| try writeSwiftMessage(w, pm);
}

fn writeSwiftMessage(w: *std.Io.Writer, msg: Message) std.Io.Writer.Error!void {
    try w.print(
        \\
        \\extension MactermProtocol.{s}: ProtocolMessage {{
        \\    static let name = "{s}"
        \\    static let since: UInt32 = {d}
        \\    static let senders: [MactermProtocol.Trust] = {f}
        \\}}
        \\
    , .{ msg.type, msg.name, msg.since, swiftSenders(msg.senders) });
}

fn writeSwiftType(w: *std.Io.Writer, t: TypeDef) std.Io.Writer.Error!void {
    const dot = std.mem.lastIndexOfScalar(u8, t.name, '.');
    const parent = if (dot) |i| t.name[0..i] else "";
    const leaf = if (dot) |i| t.name[i + 1 ..] else t.name;
    const sep: []const u8 = if (dot == null) "" else ".";

    switch (t.kind) {
        .@"enum" => {
            try w.print("\nextension MactermProtocol{s}{s} {{\n", .{ sep, parent });
            try w.print("    enum {s}: String, Equatable {{\n", .{leaf});
            for (t.cases) |c| try w.print("        case {f}\n", .{swiftName(c)});
            try w.writeAll("    }\n}\n");

            var has_unknown = false;
            for (t.cases) |c| {
                if (std.mem.eql(u8, c, "unknown")) has_unknown = true;
            }
            try w.print("\nextension MactermProtocol.{s}: ProtocolValue {{\n", .{t.name});
            try w.writeAll("    init(from reader: inout MessagePackReader) throws {\n");
            try w.writeAll("        let tag = try reader.readString()\n");
            if (has_unknown) {
                try w.writeAll("        self = Self(rawValue: tag) ?? .unknown\n");
            } else {
                try w.writeAll("        guard let value = Self(rawValue: tag) else { throw MessagePackError.unknownEnumTag(tag) }\n");
                try w.writeAll("        self = value\n");
            }
            try w.writeAll(
                \\    }
                \\
                \\    func encode(to writer: inout MessagePackWriter) {
                \\        writer.writeString(rawValue)
                \\    }
                \\}
                \\
            );
        },
        .@"struct" => {
            try w.print("\nextension MactermProtocol{s}{s} {{\n", .{ sep, parent });
            if (t.fields.len == 0) {
                try w.print("    struct {s}: Equatable {{}}\n}}\n", .{leaf});
            } else {
                try w.print("    struct {s}: Equatable {{\n", .{leaf});
                for (t.fields) |f| {
                    try w.print("        var {f}: {f}", .{ swiftCamel(f.name), swiftType(f.type) });
                    if (f.optional) {
                        try w.writeAll("?");
                    } else if (f.default) |d| {
                        try w.print(" = {f}", .{swiftDefault(f.type, d)});
                    }
                    try w.writeByte('\n');
                }
                try w.writeAll("    }\n}\n");
            }

            try w.print("\nextension MactermProtocol.{s}: ProtocolValue {{\n", .{t.name});
            try w.writeAll("    init(from reader: inout MessagePackReader) throws {\n");
            if (t.fields.len == 0) {
                try w.writeAll("        try reader.readMap { _, _ in false }\n");
            } else {
                for (t.fields) |f| try w.print("        var {f}: {f}?\n", .{ swiftCamel(f.name), swiftType(f.type) });
                try w.writeAll("        try reader.readMap { key, reader in\n");
                try w.writeAll("            switch key {\n");
                for (t.fields) |f| {
                    if (f.optional) {
                        try w.print("            case \"{s}\": {f} = try reader.readOptional({f}.self)\n", .{
                            f.name, swiftCamel(f.name), swiftType(f.type),
                        });
                    } else {
                        try w.print("            case \"{s}\": {f} = try {f}(from: &reader)\n", .{
                            f.name, swiftCamel(f.name), swiftType(f.type),
                        });
                    }
                }
                try w.writeAll("            default: return false\n");
                try w.writeAll("            }\n");
                try w.writeAll("            return true\n");
                try w.writeAll("        }\n");
                for (t.fields) |f| {
                    if (f.optional) {
                        try w.print("        self.{f} = {f}\n", .{ swiftCamel(f.name), swiftCamel(f.name) });
                    } else if (f.default) |d| {
                        try w.print("        self.{f} = {f} ?? {f}\n", .{ swiftCamel(f.name), swiftCamel(f.name), swiftDefault(f.type, d) });
                    } else {
                        try w.print("        self.{f} = try MessagePackReader.required({f}, \"{s}\")\n", .{
                            swiftCamel(f.name), swiftCamel(f.name), f.name,
                        });
                    }
                }
            }
            try w.writeAll("    }\n\n");

            try w.writeAll("    func encode(to writer: inout MessagePackWriter) {\n");
            var required: usize = 0;
            var optionals: usize = 0;
            for (t.fields) |f| {
                if (f.optional) optionals += 1 else required += 1;
            }
            if (optionals == 0) {
                try w.print("        writer.writeMapHeader({d})\n", .{required});
            } else {
                try w.print("        var keyCount = {d}\n", .{required});
                for (t.fields) |f| {
                    if (f.optional) try w.print("        if {f} != nil {{ keyCount += 1 }}\n", .{swiftCamel(f.name)});
                }
                try w.writeAll("        writer.writeMapHeader(keyCount)\n");
            }
            for (t.fields) |f| {
                if (f.optional) {
                    try w.print("        if let {f} {{\n", .{swiftCamel(f.name)});
                    try w.print("            writer.writeString(\"{s}\")\n", .{f.name});
                    try w.print("            {f}.encode(to: &writer)\n", .{swiftCamel(f.name)});
                    try w.writeAll("        }\n");
                } else {
                    try w.print("        writer.writeString(\"{s}\")\n", .{f.name});
                    try w.print("        {f}.encode(to: &writer)\n", .{swiftCamel(f.name)});
                }
            }
            try w.writeAll("    }\n}\n");
        },
    }
}

const swift_keywords = [_][]const u8{
    "as",      "associatedtype", "break",  "case",     "catch",  "class",   "continue",
    "default", "defer",          "do",     "else",     "enum",   "extension", "fallthrough",
    "false",   "for",            "func",   "guard",    "if",     "import",  "in",
    "init",    "inout",          "is",     "let",      "nil",    "operator", "private",
    "protocol", "public",        "repeat", "rethrows", "return", "self",    "Self",
    "static",  "struct",         "super",  "switch",   "throw",  "throws",  "true",
    "try",     "Type",           "typealias", "var",   "where",  "while",   "internal",
    "deinit",  "fileprivate",    "subscript",
};

/// A Swift identifier, in backticks where it is a keyword.
fn swiftName(name: []const u8) std.fmt.Alt([]const u8, formatName) {
    return .{ .data = name };
}

fn formatName(name: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (swift_keywords) |k| {
        if (std.mem.eql(u8, k, name)) return w.print("`{s}`", .{name});
    }
    try w.writeAll(name);
}

/// `min_level` as `minLevel`, in backticks where it is a keyword.
fn swiftCamel(name: []const u8) std.fmt.Alt([]const u8, formatCamel) {
    return .{ .data = name };
}

fn formatCamel(name: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    var upper = false;
    for (name) |c| {
        if (c == '_') {
            upper = true;
            continue;
        }
        if (len == buf.len) return error.WriteFailed;
        buf[len] = if (upper) std.ascii.toUpper(c) else c;
        len += 1;
        upper = false;
    }
    try formatName(buf[0..len], w);
}

fn swiftType(wire: []const u8) std.fmt.Alt([]const u8, formatType) {
    return .{ .data = wire };
}

fn formatType(wire: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (wire.len >= 2 and wire[0] == '[') {
        try w.writeByte('[');
        try formatType(wire[1 .. wire.len - 1], w);
        return w.writeByte(']');
    }
    const map = [_][2][]const u8{
        .{ "bool", "Bool" },     .{ "str", "String" },     .{ "bin", "ProtocolBin" },
        .{ "secret", "ProtocolSecret" }, .{ "raw", "ProtocolRaw" },
        .{ "u8", "UInt8" },      .{ "u16", "UInt16" },     .{ "u32", "UInt32" },
        .{ "u64", "UInt64" },    .{ "i8", "Int8" },        .{ "i16", "Int16" },
        .{ "i32", "Int32" },     .{ "i64", "Int64" },
    };
    for (map) |pair| {
        if (std.mem.eql(u8, pair[0], wire)) return w.writeAll(pair[1]);
    }
    try w.print("MactermProtocol.{s}", .{wire});
}

fn swiftDefault(wire: []const u8, text: []const u8) std.fmt.Alt([2][]const u8, formatDefault) {
    return .{ .data = .{ wire, text } };
}

fn formatDefault(pair: [2][]const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const wire = pair[0];
    const text = pair[1];
    const plain = [_][]const u8{ "bool", "str", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64" };
    for (plain) |p| {
        if (std.mem.eql(u8, p, wire)) return w.writeAll(text);
    }
    if (std.mem.eql(u8, text, "[]")) return w.writeAll("[]");
    // An enum tag.
    try w.writeByte('.');
    try formatName(text, w);
}

fn swiftSenders(senders: []const []const u8) std.fmt.Alt([]const []const u8, formatSenders) {
    return .{ .data = senders };
}

fn formatSenders(senders: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (senders, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeByte('.');
        try formatName(s, w);
    }
    try w.writeByte(']');
}

// ── Fixtures ────────────────────────────────────────────────────────────────

pub const Fixture = struct {
    name: []const u8,
    /// One whole frame, header included, in lowercase hex.
    frame: []const u8,
    /// False for a frame from a later build: it decodes, but this build
    /// writes it with fewer keys.
    reencodes: bool = true,
};

/// The frames that the Swift tests decode and encode again. Each one has
/// the values that `ProtocolFixtureTests` expects.
pub fn fixtures(arena: std.mem.Allocator) ![]const Fixture {
    const m = messages;
    var list: std.ArrayList(Fixture) = .empty;

    const hello: m.Hello = .{
        .level = 1,
        .min_level = 1,
        .build = "2.0.0-tip.1",
        .role = .gui,
        .epoch = 0x1234_5678_9abc_def0,
        .caps = &.{ "tcc", "password-tty" },
    };
    try list.append(arena, try control(arena, "hello", hello, true));
    try list.append(arena, try control(arena, "refuse", m.Refuse{ .reason = "level_too_low", .needs_level = 4 }, true));

    var buf: std.Io.Writer.Allocating = .init(arena);
    try m.encodeRequest(&buf.writer, 7, m.ChannelOpen, .{ .session = "macterm-abc" });
    try list.append(arena, try control(arena, "channel.open request", Raw{ .bytes = try buf.toOwnedSlice() }, true));
    try m.encodeResult(&buf.writer, 7, m.ChannelOpen, .{ .channel = 2 });
    try list.append(arena, try control(arena, "channel.open result", Raw{ .bytes = try buf.toOwnedSlice() }, true));
    try m.encodeRequest(&buf.writer, 8, m.ChannelClose, .{ .channel = 2 });
    try list.append(arena, try control(arena, "channel.close request", Raw{ .bytes = try buf.toOwnedSlice() }, true));
    try m.encodeResult(&buf.writer, 8, m.ChannelClose, .{});
    try list.append(arena, try control(arena, "channel.close result", Raw{ .bytes = try buf.toOwnedSlice() }, true));

    try list.append(arena, try control(arena, "error", m.Response{
        .re = 9,
        .err = .{ .code = "unknown_method", .message = "No method pane.fly.", .level = 3 },
    }, true));
    try list.append(arena, try control(arena, "events", m.EventBatch{ .seq = 41, .ev = &.{
        .{ .e = "pane.title", .a = .{ .bytes = &.{ 0x81, 0xa1, 't', 0xa2, 'h', 'x' } } },
        .{ .e = "pane.bell" },
    } }, true));

    // A hello from a later build: a new field, a new cap and a new role.
    try list.append(arena, try control(arena, "later hello", .{
        .level = @as(u32, 9),
        .min_level = @as(u32, 1),
        .build = @as([]const u8, "3.0.0"),
        .role = @as([]const u8, "relay"),
        .epoch = @as(u64, 1),
        .caps = @as([]const []const u8, &.{ "tcc", "teleport" }),
        .region = .{ .name = @as([]const u8, "eu"), .ids = @as([]const u64, &.{ 1, 70000 }) },
    }, false));

    try m.encodePane(&buf.writer, m.Attach, .{ .cols = 120, .rows = 40 });
    try list.append(arena, try pane(arena, "attach", try buf.toOwnedSlice()));
    try m.encodePane(&buf.writer, m.Exit, .{ .code = 130 });
    try list.append(arena, try pane(arena, "exit", try buf.toOwnedSlice()));
    try m.encodePane(&buf.writer, m.Claim, .{});
    try list.append(arena, try pane(arena, "claim", try buf.toOwnedSlice()));

    var out: std.Io.Writer.Allocating = .init(arena);
    try frame.write(&out.writer, .{ .channel = 3, .kind = .bytes, .body = "ls\r" });
    try list.append(arena, .{ .name = "pane bytes", .frame = try hex(arena, out.written()) });

    return list.toOwnedSlice(arena);
}

fn control(arena: std.mem.Allocator, name: []const u8, value: anytype, reencodes: bool) !Fixture {
    var out: std.Io.Writer.Allocating = .init(arena);
    const body = try msgpack.encodeAlloc(arena, value);
    try frame.write(&out.writer, .{ .channel = frame.control_channel, .kind = .msg, .body = body });
    return .{ .name = name, .frame = try hex(arena, out.written()), .reencodes = reencodes };
}

fn pane(arena: std.mem.Allocator, name: []const u8, body: []const u8) !Fixture {
    var out: std.Io.Writer.Allocating = .init(arena);
    try frame.write(&out.writer, .{ .channel = messages.pane_channel, .kind = .msg, .body = body });
    return .{ .name = name, .frame = try hex(arena, out.written()) };
}

fn hex(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const digits = "0123456789abcdef";
    const out = try arena.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0x0f];
    }
    return out;
}

pub fn writeFixtures(arena: std.mem.Allocator, w: *std.Io.Writer) !void {
    try std.json.Stringify.value(try fixtures(arena), .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Runs `check` on two metadata files in JSON, and returns its lines.
fn problems(arena: std.mem.Allocator, old_json: ?[]const u8, new_json: []const u8) ![]const u8 {
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const new = try std.json.parseFromSliceLeaky(Metadata, arena, new_json, opts);
    const old = if (old_json) |j| try std.json.parseFromSliceLeaky(Metadata, arena, j, opts) else null;
    var out: std.Io.Writer.Allocating = .init(arena);
    const n = try check(&out.writer, old, new);
    try testing.expectEqual(n, std.mem.count(u8, out.written(), "\n"));
    return out.written();
}

fn metadataJson(arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeMetadata(&out.writer, metadata);
    return out.written();
}

test "the metadata names every message, method and type" {
    try testing.expectEqual(messages.level, metadata.level);
    try testing.expectEqualStrings("hello", metadata.messages[0].name);
    try testing.expectEqualStrings("Hello", metadata.messages[0].type);
    try testing.expectEqual(messages.methods.len, metadata.methods.len);
    const open = findName(Method, metadata.methods, "channel.open").?;
    try testing.expectEqualStrings("ChannelOpen.Args", open.args);
    try testing.expectEqualStrings("local", open.senders[0]);

    const hello = findName(TypeDef, metadata.types, "Hello").?;
    try testing.expectEqualStrings("min_level", hello.fields[1].name);
    try testing.expectEqualStrings("Role", hello.fields[3].type);
    try testing.expectEqualStrings("[str]", hello.fields[5].type);

    const req = findName(TypeDef, metadata.types, "Request").?;
    try testing.expectEqualStrings("raw", req.fields[2].type);
    try testing.expect(req.fields[2].optional);

    const role = findName(TypeDef, metadata.types, "Role").?;
    try testing.expectEqual(.@"enum", role.kind);
    try testing.expectEqualStrings("unknown", role.cases[role.cases.len - 1]);
}

test "the metadata of this build passes the check against itself" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = try metadataJson(arena);
    try testing.expectEqualStrings("", try problems(arena, json, json));
    try testing.expectEqualStrings("", try problems(arena, null, json));
}

const base =
    \\{"level": 1, "min_level": 1, "trust": ["local"],
    \\ "messages": [{"name": "hello", "type": "Hello", "since": 1, "senders": ["local"]}],
    \\ "envelopes": ["Request"],
    \\ "methods": [{"name": "pane.split", "type": "PaneSplit", "since": 1, "senders": ["local"],
    \\              "args": "PaneSplit.Args", "result": "PaneSplit.Result"}],
    \\ "events": [],
    \\ "types": [
    \\   {"name": "Hello", "kind": "struct", "fields": [{"name": "level", "type": "u32", "since": 1}]},
    \\   {"name": "Request", "kind": "struct", "fields": [{"name": "id", "type": "u64", "since": 1}]},
    \\   {"name": "Role", "kind": "enum", "cases": ["gui", "unknown"]},
    \\   {"name": "PaneSplit.Args", "kind": "struct", "fields": [
    \\     {"name": "pane", "type": "str", "since": 1},
    \\     {"name": "ratio", "type": "u8", "default": "50", "since": 1}]},
    \\   {"name": "PaneSplit.Result", "kind": "struct", "fields": []}]}
;

/// `base` with one piece of text replaced.
fn edit(arena: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    try testing.expect(std.mem.count(u8, base, from) == 1);
    return std.mem.replaceOwned(u8, arena, base, from, to);
}

test "the check refuses a removed field, message, method, type or case" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("", try problems(arena, base, base));

    const no_field = try edit(arena, ",\n     {\"name\": \"ratio\", \"type\": \"u8\", \"default\": \"50\", \"since\": 1}", "");
    try testing.expectEqualStrings("PaneSplit.Args.ratio was removed\n", try problems(arena, base, no_field));

    const no_case = try edit(arena, "[\"gui\", \"unknown\"]", "[\"unknown\"]");
    try testing.expectEqualStrings("enum Role: case gui was removed\n", try problems(arena, base, no_case));

    const no_method = try edit(arena, "\"pane.split\"", "\"pane.splat\"");
    try testing.expectEqualStrings(
        "method pane.split was removed\n",
        try problems(arena, base, no_method),
    );

    const no_message = try edit(arena, "\"name\": \"hello\"", "\"name\": \"hullo\"");
    try testing.expectEqualStrings("message hello was removed\n", try problems(arena, base, no_message));

    const no_type = try edit(arena, "\"name\": \"Role\"", "\"name\": \"Rule\"");
    try testing.expectEqualStrings("type Role was removed\n", try problems(arena, base, no_type));
}

test "a new enum case needs an unknown case in the enum" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const open = try edit(arena, "[\"gui\", \"unknown\"]", "[\"gui\", \"cli\", \"unknown\"]");
    try testing.expectEqualStrings("", try problems(arena, base, open));

    const closed_old = try edit(arena, "[\"gui\", \"unknown\"]", "[\"gui\"]");
    const closed_new = try edit(arena, "[\"gui\", \"unknown\"]", "[\"gui\", \"cli\"]");
    try testing.expectEqualStrings(
        "enum Role: case cli is new, but the enum has no unknown case\n",
        try problems(arena, closed_old, closed_new),
    );
}

test "the check refuses a changed type, default or since" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wider = try edit(arena, "\"type\": \"u32\"", "\"type\": \"u64\"");
    try testing.expectEqualStrings("Hello.level: its type or default changed\n", try problems(arena, base, wider));

    const optional = try edit(arena, "\"type\": \"str\", \"since\": 1", "\"type\": \"str\", \"optional\": true, \"since\": 1");
    try testing.expectEqualStrings("PaneSplit.Args.pane: its type or default changed\n", try problems(arena, base, optional));

    const default = try edit(arena, "\"default\": \"50\"", "\"default\": \"40\"");
    try testing.expectEqualStrings("PaneSplit.Args.ratio: its type or default changed\n", try problems(arena, base, default));

    const since = try edit(arena, "\"type\": \"u64\", \"since\": 1", "\"type\": \"u64\", \"since\": 2");
    try testing.expectEqualStrings("Request.id: since changed from 1 to 2\n", try problems(arena, base, since));
}

test "an addition needs the current level, and a new field needs a default" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // At level 1, a new optional field of level 1 is good.
    const good = try edit(arena, "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}", "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}, {\"name\": \"hint\", \"type\": \"str\", \"optional\": true, \"since\": 1}");
    try testing.expectEqualStrings("", try problems(arena, base, good));

    const required = try edit(arena, "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}", "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}, {\"name\": \"hint\", \"type\": \"str\", \"since\": 1}");
    try testing.expectEqualStrings(
        "Request.hint is new, but it is not optional and has no default\n",
        try problems(arena, base, required),
    );

    // The level went up to 2, but the new field says 1.
    const stale = try std.mem.replaceOwned(u8, arena, good, "{\"level\": 1", "{\"level\": 2");
    try testing.expectEqualStrings("Request.hint is new, but its since is 1, not 2\n", try problems(arena, base, stale));

    // A field of a new type has the current level too.
    const new_type = try std.mem.replaceOwned(u8, arena, try edit(arena, "{\"level\": 1", "{\"level\": 2"), "\"types\": [",
        \\"types": [{"name": "Size", "kind": "struct", "fields": [{"name": "rows", "type": "u16", "since": 1}]},
    );
    try testing.expectEqualStrings("Size.rows is new, but its since is 1, not 2\n", try problems(arena, base, new_type));

    const down = try edit(arena, "{\"level\": 1, \"min_level\": 1", "{\"level\": 0, \"min_level\": 0");
    try testing.expectEqualStrings("level went down from 1 to 0\n", try problems(arena, base, down));
}

test "no result and no event may hold a secret" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const leak = try edit(arena, "{\"name\": \"PaneSplit.Result\", \"kind\": \"struct\", \"fields\": []}",
        \\{"name": "PaneSplit.Result", "kind": "struct", "fields": [
        \\  {"name": "saved", "type": "[Saved]", "optional": true, "since": 1}]},
        \\{"name": "Saved", "kind": "struct", "fields": [{"name": "password", "type": "secret", "since": 1}]}
    );
    try testing.expectEqualStrings("method pane.split: its result holds a secret\n", try problems(arena, null, leak));

    const event = try edit(arena, "\"events\": []",
        \\"events": [{"name": "pane.prompt", "type": "Prompt", "since": 1, "senders": ["local"]}]
    );
    const event_leak = try std.mem.replaceOwned(u8, arena, event, "\"types\": [",
        \\"types": [{"name": "Prompt", "kind": "struct", "fields": [{"name": "typed", "type": "secret", "since": 1}]},
    );
    try testing.expectEqualStrings("event pane.prompt holds a secret\n", try problems(arena, base, event_leak));

    // A secret in a request's arguments is allowed: the GUI sends it to type
    // a password into a pane (design/006 §4).
    const args = try edit(arena, "{\"name\": \"pane\", \"type\": \"str\", \"since\": 1}", "{\"name\": \"pane\", \"type\": \"secret\", \"since\": 1}");
    try testing.expect(std.mem.indexOf(u8, try problems(arena, null, args), "secret") == null);
}

test "every fixture decodes as the message it names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try fixtures(arena);
    for (list) |f| {
        const bytes = try arena.alloc(u8, f.frame.len / 2);
        _ = try std.fmt.hexToBytes(bytes, f.frame);
        const parsed = (try frame.parse(bytes)).?;
        try testing.expectEqual(bytes.len, parsed.len);
        if (parsed.frame.kind != .msg) continue;
        if (parsed.frame.channel == messages.pane_channel) {
            const msg = try msgpack.decodeSlice(messages.PaneMessage, arena, parsed.frame.body);
            try testing.expectEqualStrings(f.name, msg.t);
            continue;
        }
        const decoded = try messages.decodeControl(arena, parsed.frame.body);
        const expected: std.meta.Tag(messages.Control) = if (std.mem.endsWith(u8, f.name, "request"))
            .request
        else if (std.mem.endsWith(u8, f.name, "result") or std.mem.eql(u8, f.name, "error"))
            .response
        else if (std.mem.eql(u8, f.name, "events"))
            .events
        else if (std.mem.eql(u8, f.name, "refuse"))
            .refuse
        else
            .hello;
        try testing.expectEqual(expected, std.meta.activeTag(decoded));
    }
}

test "the Swift output names each type and field" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeSwift(&out.writer, metadata);
    const s = out.written();
    try testing.expect(std.mem.indexOf(u8, s, "struct Hello: Equatable {") != null);
    try testing.expect(std.mem.indexOf(u8, s, "var minLevel: UInt32\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "case \"min_level\": minLevel = try UInt32(from: &reader)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "enum ChannelOpen: ProtocolMethod {") != null);
    try testing.expect(std.mem.indexOf(u8, s, "extension MactermProtocol.ChannelOpen {\n    struct Args") != null);
    try testing.expect(std.mem.indexOf(u8, s, "self = Self(rawValue: tag) ?? .unknown") != null);
}

test "Swift names: camel case and keywords" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("needsLevel", try std.fmt.bufPrint(&buf, "{f}", .{swiftCamel("needs_level")}));
    try testing.expectEqualStrings("`default`", try std.fmt.bufPrint(&buf, "{f}", .{swiftCamel("default")}));
    try testing.expectEqualStrings("[MactermProtocol.Event]", try std.fmt.bufPrint(&buf, "{f}", .{swiftType("[Event]")}));
    try testing.expectEqualStrings(".gui", try std.fmt.bufPrint(&buf, "{f}", .{swiftDefault("Role", "gui")}));
}
