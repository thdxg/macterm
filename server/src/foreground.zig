//! Foreground reports: the daemon tells a client that asked which process
//! group holds its pty, each time that changes.
//!
//! A GUI frontend over a remote session (Macterm) names the tab after the
//! foreground process, warns before it closes a pane whose program is still
//! running, and shows a logo for a coding agent. Without this it had to
//! ask the host over a separate ssh connection every few seconds, and the
//! answer was a round trip old: when an agent quit, the shell's prompt
//! title arrived while the last answer still said the agent was in front.
//!
//! The daemon reads the pty's foreground process group before it forwards
//! each chunk of output (and on a timer, for a program that is silent), and
//! sends `Tag.Foreground` to every client that subscribed. The client writes
//! the report into its stdout as an APC sequence, `ESC _ <report> ESC \`,
//! in front of the output it precedes. The order is the point: a report
//! that the shell is back always lands before the shell's prompt. APC
//! because no keyboard produces one, a terminal that does not know it
//! discards it, and it rides the client's own connection.
//!
//! Only a client started with `ZMX_FOREGROUND_EVENTS` in its environment
//! subscribes and writes the sequence, so no other terminal ever sees it.
//! The client removes the variable from its environment before the session
//! starts, so a shell in the session does not inherit it: a nested
//! `zmx attach` would otherwise report its own session's foreground into
//! the outer one.
//!
//! The report is `zmx;foreground;<idle>;<shell>;<comm>;<args>`:
//!   - `idle` is `1` when the foreground group is the session's own shell
//!     (the group of the process the daemon spawned), `0` otherwise. It is
//!     the host's verdict, so the frontend needs no shell database.
//!   - `shell` is `1` when `comm` is listed in the host's `/etc/shells`, `0`
//!     when it is not, and empty when the host has no `/etc/shells`. A
//!     terminal multiplexer never counts (Debian lists tmux and screen).
//!   - `comm` is the process name: the executable path on macOS, the kernel
//!     `comm` on Linux. The last field, `args`, is the command line. Both
//!     have every control byte replaced by a space, `comm` has `;` replaced
//!     too, and `args` is cut at `args_max`, so the sequence always ends
//!     where the client ends it.
//!
//! On a platform with no process reader (`supported` is false) the daemon
//! never reports, and a frontend falls back to whatever it did before.
const std = @import("std");
const builtin = @import("builtin");
const lib_posix = @import("posix.zig");

/// Set in the client's environment to subscribe. Any value.
pub const env_var = "ZMX_FOREGROUND_EVENTS";

/// How often the daemon reads the foreground group while a client is
/// subscribed and no output wakes it: a program that takes the pty and
/// prints nothing (`sleep`, a quiet build) is reported within this.
pub const poll_interval_ms: i32 = 500;

/// Where the daemon can read a process by its pid.
pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

pub const prefix = "zmx;foreground;";
pub const comm_max = 512;
pub const args_max = 1024;
/// A buffer this long holds any report `write` produces.
pub const report_max = prefix.len + 4 + comm_max + 1 + args_max;

pub const Report = struct {
    idle: bool,
    /// null: the host has no `/etc/shells` to ask.
    shell: ?bool,
    comm: []const u8,
    args: []const u8,
};

/// Formats a report into `buf` (at least `report_max` long) and returns it.
pub fn write(buf: []u8, report: Report) []const u8 {
    std.debug.assert(buf.len >= report_max);
    var n: usize = 0;
    n += copy(buf[n..], prefix);
    n += copy(buf[n..], if (report.idle) "1;" else "0;");
    n += copy(buf[n..], if (report.shell) |s| (if (s) "1;" else "0;") else ";");
    n += copyField(buf[n..], report.comm, comm_max, true);
    n += copy(buf[n..], ";");
    n += copyField(buf[n..], report.args, args_max, false);
    return buf[0..n];
}

fn copy(dst: []u8, src: []const u8) usize {
    @memcpy(dst[0..src.len], src);
    return src.len;
}

/// Copies `src` cut at `max` bytes, backing off a UTF-8 continuation byte
/// so a multibyte character is never split, with every control byte (and
/// `;` when `no_semicolon`) replaced by a space.
fn copyField(dst: []u8, src: []const u8, max: usize, no_semicolon: bool) usize {
    var len = @min(src.len, max);
    while (len > 0 and len < src.len and isUtf8Continuation(src[len])) : (len -= 1) {}
    for (src[0..len], 0..) |c, i| {
        dst[i] = if (c < 0x20 or c == 0x7f or (no_semicolon and c == ';')) ' ' else c;
    }
    return len;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xBF;
}

/// Whether `comm` names a shell of this host: its basename, without the
/// login `-`, ends a line of `/etc/shells`. A multiplexer never counts,
/// whatever the file says, because `tmux attach` is a program to report.
pub fn isListedShell(etc_shells: []const u8, comm: []const u8) bool {
    var base = comm;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base = base[i + 1 ..];
    if (base.len > 0 and base[0] == '-') base = base[1..];
    if (base.len == 0) return false;
    for ([_][]const u8{ "tmux", "screen", "zellij" }) |mux| {
        if (std.mem.eql(u8, base, mux)) return false;
    }
    var lines = std.mem.splitScalar(u8, etc_shells, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len > base.len and line[line.len - base.len - 1] == '/' and
            std.mem.endsWith(u8, line, base))
        {
            return true;
        }
    }
    return false;
}

/// Reads `/etc/shells` into `buf`, or null when the host has none (or it
/// is unreadable, which means the same to a report).
pub fn readEtcShells(buf: []u8) ?[]const u8 {
    return readFile("/etc/shells", buf);
}

pub const Process = struct {
    comm: []const u8,
    args: []const u8,
};

/// Reads the name and command line of `pid`. `comm_buf` and `args_buf`
/// receive the fields; `scratch` is for the raw kernel data (macOS). null
/// when the process is gone or cannot be read; a process whose command
/// line alone cannot be read gets an empty `args`.
pub fn readProcess(pid: lib_posix.pid_t, comm_buf: []u8, args_buf: []u8, scratch: []u8) ?Process {
    switch (builtin.os.tag) {
        .macos => {
            const n = macos.proc_pidpath(@intCast(pid), comm_buf.ptr, @intCast(comm_buf.len));
            if (n <= 0) return null;
            const comm = comm_buf[0..@intCast(n)];
            var mib = [_]c_int{ macos.CTL_KERN, macos.KERN_PROCARGS2, @intCast(pid) };
            var len: usize = scratch.len;
            const args = if (std.c.sysctl(&mib, mib.len, @as(*anyopaque, @ptrCast(scratch.ptr)), &len, null, 0) == 0)
                parseProcArgs2(scratch[0..len], args_buf)
            else
                "";
            return .{ .comm = comm, .args = args };
        },
        .linux => {
            var path_buf: [64]u8 = undefined;
            const comm_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
            const comm_raw = readFile(comm_path, comm_buf) orelse return null;
            const comm = std.mem.trimEnd(u8, comm_raw, "\n");
            if (comm.len == 0) return null;
            const cmdline_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;
            const args = if (readFile(cmdline_path, scratch)) |raw| joinCmdline(raw, args_buf) else "";
            return .{ .comm = comm, .args = args };
        },
        else => {
            _ = .{ pid, comm_buf, args_buf, scratch };
            return null;
        },
    }
}

const macos = struct {
    const CTL_KERN: c_int = 1;
    const KERN_PROCARGS2: c_int = 49;
    extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
};

/// The command line from a `KERN_PROCARGS2` buffer: the argument count,
/// the executable path, NUL padding, then the arguments, each NUL
/// terminated (the environment follows and is not read). Returns the
/// arguments joined by spaces, in `out`, cut at its length.
pub fn parseProcArgs2(raw: []const u8, out: []u8) []const u8 {
    if (raw.len < 4) return "";
    const argc = std.mem.readInt(u32, raw[0..4], builtin.cpu.arch.endian());
    var i: usize = 4;
    // The executable path, then its padding.
    while (i < raw.len and raw[i] != 0) : (i += 1) {}
    while (i < raw.len and raw[i] == 0) : (i += 1) {}
    var n: usize = 0;
    var taken: u32 = 0;
    while (taken < argc and i < raw.len) : (taken += 1) {
        const end = std.mem.indexOfScalarPos(u8, raw, i, 0) orelse raw.len;
        if (taken > 0) {
            if (n >= out.len) break;
            out[n] = ' ';
            n += 1;
        }
        const take = @min(end - i, out.len - n);
        @memcpy(out[n .. n + take], raw[i .. i + take]);
        n += take;
        if (take < end - i) break;
        i = end + 1;
    }
    return out[0..n];
}

/// The command line from `/proc/<pid>/cmdline`: NUL-separated arguments,
/// joined by spaces, in `out`, cut at its length.
pub fn joinCmdline(raw: []const u8, out: []u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, raw, "\x00");
    const n = @min(trimmed.len, out.len);
    for (trimmed[0..n], 0..) |c, i| out[i] = if (c == 0) ' ' else c;
    return out[0..n];
}

/// Reads as much of a file as fits `buf`. null when it cannot be opened.
fn readFile(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = lib_posix.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer lib_posix.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const got = lib_posix.read(fd, buf[n..]) catch return null;
        if (got == 0) break;
        n += got;
    }
    return buf[0..n];
}

const testing = std.testing;

test "foreground: a report has every field in order" {
    var buf: [report_max]u8 = undefined;
    const report = write(&buf, .{ .idle = false, .shell = false, .comm = "/usr/bin/hx", .args = "hx README.md" });
    try testing.expectEqualStrings("zmx;foreground;0;0;/usr/bin/hx;hx README.md", report);
}

test "foreground: an idle shell and an unknown shell verdict" {
    var buf: [report_max]u8 = undefined;
    const report = write(&buf, .{ .idle = true, .shell = null, .comm = "-zsh", .args = "" });
    try testing.expectEqualStrings("zmx;foreground;1;;-zsh;", report);
}

test "foreground: control bytes cannot end the sequence early" {
    var buf: [report_max]u8 = undefined;
    const report = write(&buf, .{
        .idle = false,
        .shell = false,
        .comm = "ev;il\x1b",
        .args = "printf '\x1b\\'; echo \x07",
    });
    try testing.expectEqualStrings("zmx;foreground;0;0;ev il ;printf ' \\'; echo  ", report);
}

test "foreground: a long command line is cut at a character boundary" {
    var buf: [report_max]u8 = undefined;
    var long: [args_max + 8]u8 = undefined;
    @memset(&long, 'a');
    // A three-byte character that starts on the last byte before the cut.
    long[args_max - 1] = 0xE2;
    long[args_max] = 0x82;
    long[args_max + 1] = 0xAC;
    const report = write(&buf, .{ .idle = false, .shell = false, .comm = "x", .args = &long });
    try testing.expectEqual(prefix.len + 4 + 1 + 1 + (args_max - 1), report.len);
    try testing.expectEqual(@as(u8, 'a'), report[report.len - 1]);
}

test "foreground: isListedShell matches the basename against /etc/shells" {
    const shells = "# List of acceptable shells\n/bin/sh\n/bin/zsh\n/usr/bin/tmux\n/usr/local/bin/fish\n";
    try testing.expect(isListedShell(shells, "zsh"));
    try testing.expect(isListedShell(shells, "-zsh"));
    try testing.expect(isListedShell(shells, "/bin/zsh"));
    try testing.expect(isListedShell(shells, "fish"));
    try testing.expect(!isListedShell(shells, "sh.py"));
    try testing.expect(!isListedShell(shells, "hx"));
    try testing.expect(!isListedShell(shells, ""));
    // Listed, but a multiplexer is a program to report.
    try testing.expect(!isListedShell(shells, "tmux"));
}

test "foreground: parseProcArgs2 joins argv after the executable path" {
    var raw: [64]u8 = undefined;
    const argc: u32 = 3;
    std.mem.writeInt(u32, raw[0..4], argc, builtin.cpu.arch.endian());
    const rest = "/usr/bin/hx\x00\x00\x00hx\x00--vsplit\x00README.md\x00TERM=xterm\x00";
    @memcpy(raw[4 .. 4 + rest.len], rest);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("hx --vsplit README.md", parseProcArgs2(raw[0 .. 4 + rest.len], &out));
}

test "foreground: parseProcArgs2 cuts at the output buffer" {
    var raw: [32]u8 = undefined;
    std.mem.writeInt(u32, raw[0..4], 2, builtin.cpu.arch.endian());
    const rest = "/bin/x\x00x\x00abcdefgh\x00";
    @memcpy(raw[4 .. 4 + rest.len], rest);
    var out: [5]u8 = undefined;
    try testing.expectEqualStrings("x abc", parseProcArgs2(raw[0 .. 4 + rest.len], &out));
    try testing.expectEqualStrings("", parseProcArgs2("ab", &out));
}

test "foreground: joinCmdline turns NUL separators into spaces" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("hx --vsplit README.md", joinCmdline("hx\x00--vsplit\x00README.md\x00", &out));
    try testing.expectEqualStrings("", joinCmdline("", &out));
}
