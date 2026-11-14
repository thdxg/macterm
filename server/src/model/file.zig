//! `model.json` (design/010 §2): the model as JSON, and its load and save.
//!
//! The file has a `version`. A file with a newer version is refused, and the
//! caller must not write over it (`error.NewerVersion`): an older build
//! never destroys the data of a newer one. A file that does not parse, or
//! does not validate, is refused too, and nothing is written over it.
//!
//! Only `Data` is in the file. The zoom and the focus history of a tab stay
//! in memory (design/010 §1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

pub const Model = model.Model;

pub const LoadError = error{
    OutOfMemory,
    /// Not JSON, or not the shape of `Data`.
    Syntax,
    /// `version` is higher than this build writes. `peekVersion` has the
    /// number.
    NewerVersion,
    /// A fault in the model; `parse` gives it in its `fault` argument.
    Invalid,
};

/// The `version` of a file, if it has one.
pub fn peekVersion(gpa: Allocator, bytes: []const u8) ?u32 {
    const Head = struct { version: u32 };
    const parsed = std.json.parseFromSlice(Head, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return parsed.value.version;
}

/// Reads a model from JSON text. The model copies every string, so `bytes`
/// can go away. `fault` gets the first fault when the
/// result is `error.Invalid`.
pub fn parse(gpa: Allocator, bytes: []const u8, fault: *model.Fault) LoadError!Model {
    if (peekVersion(gpa, bytes)) |v| {
        if (v > model.version) return error.NewerVersion;
    }
    var m = Model.init(gpa);
    errdefer m.deinit();
    m.data = std.json.parseFromSliceLeaky(model.Data, m.arena.allocator(), bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Syntax,
    };
    if (try model.validate(gpa, &m.data)) |f| {
        fault.* = f;
        return error.Invalid;
    }
    return m;
}

/// Writes the model as JSON.
pub fn write(m: *const Model, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.value(m.data, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, w);
    try w.writeByte('\n');
}

pub const FileError = LoadError || error{ ReadFailed, WriteFailed };

/// Reads `path`. A missing file gives an empty model (a first start).
pub fn load(gpa: Allocator, io: std.Io, path: []const u8, fault: *model.Fault) FileError!Model {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return Model.init(gpa),
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes, fault);
}

/// Writes `path` through a temporary file and a rename, so a crash leaves
/// the old file whole. `path` is absolute.
pub fn save(gpa: Allocator, io: std.Io, m: *const Model, path: []const u8) FileError!void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(m, &out.writer) catch return error.OutOfMemory;
    const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{path}) catch return error.OutOfMemory;
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out.written() }) catch return error.WriteFailed;
    std.Io.Dir.renameAbsolute(tmp, path, io) catch return error.WriteFailed;
}
