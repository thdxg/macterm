//! Where the v2 sockets live, and who may connect to them (design/006 §1).
//!
//! One directory holds the sockets of the sessions. It is mode 0700 and
//! belongs to the user. The session checks it with `lstat` before it binds,
//! and refuses to start when the check fails. Each accept checks the peer's
//! uid. Nothing here reads `ZMX_DIR`: v1's sessions stay where they are.

const std = @import("std");
const builtin = @import("builtin");
const cross = @import("cross");

/// Names the directory. Tests and the server set it.
pub const dir_env = "MACTERM_RUNTIME_DIR";

/// The variable that the shell of a session gets: the session's name.
pub const session_env = "MACTERM_SESSION";

/// The directory, from the first that is set: `MACTERM_RUNTIME_DIR`,
/// `$XDG_RUNTIME_DIR/macterm`, `$TMPDIR/macterm` on macOS (a folder of the
/// user's own, not the shared `/tmp`), else `~/.local/state/macterm/run`.
/// The macOS path is short on purpose: a socket path has at most 103 bytes.
pub fn resolveDir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get(dir_env)) |dir| if (dir.len > 0) return gpa.dupe(u8, trimSlash(dir));
    if (env.get("XDG_RUNTIME_DIR")) |dir| if (dir.len > 0)
        return std.fs.path.join(gpa, &.{ trimSlash(dir), "macterm" });
    if (builtin.os.tag.isDarwin()) {
        if (env.get("TMPDIR")) |dir| if (dir.len > 0)
            return std.fs.path.join(gpa, &.{ trimSlash(dir), "macterm" });
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ trimSlash(home), ".local", "state", "macterm", "run" });
}

fn trimSlash(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    return p;
}

pub const DirError = error{
    /// The path is a symbolic link.
    IsSymlink,
    /// The path is not a directory.
    NotADirectory,
    /// Another user owns the directory.
    WrongOwner,
    /// The mode is not 0700.
    WrongMode,
    /// `lstat` or `mkdir` failed.
    Unreadable,
};

/// Makes the directory if it is not there (its parents too, 0700), then
/// checks it with `lstat`: a directory, not a symbolic link, owned by this
/// uid, mode exactly 0700. An existing directory is never changed: a wrong
/// one is an error that names it.
pub fn ensureDir(path: []const u8) DirError!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len == 0 or path.len >= buf.len) return error.Unreadable;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (!exists(buf[0..path.len :0])) {
        // Each missing parent, from the top. A parent that exists is left
        // as it is; only the last directory must pass the check.
        var i: usize = 1;
        while (i <= path.len) : (i += 1) {
            if (i != path.len and buf[i] != '/') continue;
            const saved = buf[i];
            buf[i] = 0;
            const part = buf[0..i :0];
            if (!exists(part) and std.c.mkdir(part, 0o700) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST))
                return error.Unreadable;
            buf[i] = saved;
        }
    }
    return checkDir(buf[0..path.len :0], std.c.getuid());
}

fn exists(path: [:0]const u8) bool {
    var st: cross.struct_stat = undefined;
    return cross.lstat(path.ptr, &st) == 0;
}

/// The check alone. `uid` is the owner that the directory must have.
pub fn checkDir(path: [:0]const u8, uid: std.c.uid_t) DirError!void {
    var st: cross.struct_stat = undefined;
    if (cross.lstat(path.ptr, &st) != 0) return error.Unreadable;
    const kind = st.st_mode & cross.S_IFMT;
    if (kind == cross.S_IFLNK) return error.IsSymlink;
    if (kind != cross.S_IFDIR) return error.NotADirectory;
    if (st.st_uid != uid) return error.WrongOwner;
    if (st.st_mode & 0o7777 != 0o700) return error.WrongMode;
}

/// The text for a refusal, for people.
pub fn describe(err: DirError) []const u8 {
    return switch (err) {
        error.IsSymlink => "is a symbolic link",
        error.NotADirectory => "is not a directory",
        error.WrongOwner => "belongs to another user",
        error.WrongMode => "has a mode other than 0700",
        error.Unreadable => "cannot be made or read",
    };
}

/// The uid of the process at the other end of a connected Unix socket. Null
/// when the system does not say.
pub fn peerUid(fd: std.c.fd_t) ?std.c.uid_t {
    if (comptime builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) {
        var uid: std.c.uid_t = undefined;
        var gid: std.c.gid_t = undefined;
        if (getpeereid(fd, &uid, &gid) != 0) return null;
        return uid;
    } else if (comptime builtin.os.tag == .linux) {
        const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
        var cred: Ucred = undefined;
        var len: std.c.socklen_t = @sizeOf(Ucred);
        if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.PEERCRED, &cred, &len) != 0) return null;
        if (len != @sizeOf(Ucred)) return null;
        return cred.uid;
    } else {
        return null;
    }
}

extern "c" fn getpeereid(fd: std.c.fd_t, uid: *std.c.uid_t, gid: *std.c.gid_t) c_int;

/// The peer may connect when it is this user or root (design/006 §1: root
/// is not refused, and is not protected against). An unknown peer is
/// refused: fail closed.
pub fn allowPeer(peer: ?std.c.uid_t, own: std.c.uid_t) bool {
    const uid = peer orelse return false;
    return uid == own or uid == 0;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the peer check lets in this user and root, and nobody else" {
    try testing.expect(allowPeer(501, 501));
    try testing.expect(allowPeer(0, 501));
    try testing.expect(!allowPeer(502, 501));
    try testing.expect(!allowPeer(null, 501));
}

test "a socket pair's peer is this user" {
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(0, std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try testing.expectEqual(std.c.getuid(), peerUid(fds[0]).?);
    try testing.expect(allowPeer(peerUid(fds[0]), std.c.getuid()));
}

test "the directory check refuses a symlink, a file, and a mode other than 0700" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(testing.io, &base_buf);
    const base = base_buf[0..base_len];

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const run = try std.fmt.bufPrintSentinel(&path_buf, "{s}/a/b/run", .{base}, 0);
    try ensureDir(run);
    try checkDir(run, std.c.getuid());
    // A second call finds it and passes.
    try ensureDir(run);
    try testing.expectError(error.WrongOwner, checkDir(run, std.c.getuid() +% 1));

    try testing.expectEqual(0, std.c.chmod(run.ptr, 0o750));
    try testing.expectError(error.WrongMode, ensureDir(run));
    try testing.expectEqual(0, std.c.chmod(run.ptr, 0o700));

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&link_buf, "{s}/link", .{base}, 0);
    try testing.expectEqual(0, std.c.symlink(run.ptr, link.ptr));
    try testing.expectError(error.IsSymlink, ensureDir(link));

    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrintSentinel(&file_buf, "{s}/file", .{base}, 0);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "" });
    try testing.expectError(error.NotADirectory, ensureDir(file));
}

test "the directory comes from MACTERM_RUNTIME_DIR first" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/u");
    {
        const dir = try resolveDir(testing.allocator, &env);
        defer testing.allocator.free(dir);
        if (!builtin.os.tag.isDarwin()) try testing.expectEqualStrings("/home/u/.local/state/macterm/run", dir);
    }
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000/");
    {
        const dir = try resolveDir(testing.allocator, &env);
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("/run/user/1000/macterm", dir);
    }
    try env.put(dir_env, "/tmp/x/");
    {
        const dir = try resolveDir(testing.allocator, &env);
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("/tmp/x", dir);
    }
}
