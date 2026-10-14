const std = @import("std");
const builtin = @import("builtin");
const lib_posix = @import("posix.zig");
const Cfg = @import("cfg.zig");
const socket = @import("socket.zig");
const ipc = @import("ipc.zig");
const assert = std.debug.assert;
const log = @import("log.zig");
const cross = @import("cross.zig");

const Cmd = struct {
    file: [*:0]const u8,
    argv_ptr: [*:null]const ?[*:0]const u8,
};

pub fn createCmdZ(def_shell: []const u8, is_task_mode: bool, command: ?[]const []const u8) !Cmd {
    const gpa = std.heap.c_allocator;

    if (command) |cmd_args| {
        const argv = try gpa.allocSentinel(?[*:0]const u8, cmd_args.len, null);
        for (cmd_args, 0..) |arg, i| {
            argv[i] = try gpa.dupeZ(u8, arg);
        }
        return .{
            .file = argv[0].?,
            .argv_ptr = argv.ptr,
        };
    }

    const z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{def_shell}, 0);
    const shell: [:0]const u8 = if (is_task_mode) "bash" else z;

    // Use "-shellname" as argv[0] to signal login shell (traditional method)
    const login_shell = try std.fmt.allocPrintSentinel(gpa, "-{s}", .{std.fs.path.basename(shell)}, 0);
    const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = login_shell.ptr;

    return .{
        .file = shell,
        .argv_ptr = argv,
    };
}

/// Runs in the forked child. Either execs or returns an error (caller
/// must exit on error -- returning would fall through to parent code).
fn exec(sesh_name: []const u8, cmd: Cmd) !noreturn {
    const gpa = std.heap.c_allocator;

    // main() set SIGPIPE to SIG_IGN, which (unlike handlers) survives
    // exec. Restore the default so the shell and its children behave
    // normally (e.g. `yes | head` should exit 141 via SIGPIPE).
    const dfl: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.DFL },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    lib_posix.sigaction(lib_posix.SIG.PIPE, &dfl, null);

    const session_env = try std.fmt.allocPrintSentinel(
        gpa,
        "ZMX_SESSION={s}",
        .{sesh_name},
        0,
    );
    _ = cross.c.putenv(session_env.ptr);

    if (cross.c.getenv("TERM")) |term_env| {
        if (std.mem.eql(u8, std.mem.span(term_env), "dumb")) {
            _ = cross.c.putenv(@constCast("TERM=xterm-256color"));
        }
    } else {
        _ = cross.c.putenv(@constCast("TERM=xterm-256color"));
    }

    const err = lib_posix.execvpeZ(cmd.file, cmd.argv_ptr, std.c.environ);
    std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd.file, @errorName(err) });
    lib_posix.exit(1);
}

pub const PtyInfo = struct {
    master_fd: c_int = undefined,
    pid: c_int = undefined,
};

/// spawnPty runs forkpty() and executes the shell or shell command the user
/// provides.
///
/// This is the second fork in the double-fork technique explained in the
/// daemonize() comment.
pub fn spawnPty(sesh_name: []const u8, cmd: Cmd, size: ipc.Resize) !PtyInfo {
    var ws: cross.c.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };

    var master_fd: c_int = undefined;
    const pid = cross.forkpty(&master_fd, null, null, &ws);
    if (pid < 0) {
        return error.ForkPtyFailed;
    }

    if (pid == 0) { // child pid code path
        // In the forked child, ANY error must exit rather than propagate:
        // a returned error falls through to the parent code path below,
        // running a second daemon on the same socket (or worse, hitting
        // errdefers that delete the parent's socket file).
        exec(sesh_name, cmd) catch |err| {
            std.log.err("child setup failed: {s}", .{@errorName(err)});
            lib_posix.exit(1);
        };
        unreachable; // exec() either execs or exits, never returns ok
    }
    // master pid code path
    std.log.info("pty spawned session={s} pid={d}", .{ sesh_name, pid });

    // make pty non-blocking
    const flags = try lib_posix.fcntl(master_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(master_fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);

    return .{
        .master_fd = master_fd,
        .pid = pid,
    };
}

/// State the macOS daemon rebuilds itself from after `reexecDisclaimed`.
/// Everything else a `Daemon` holds is either derived from the environment
/// (`Cfg`) or created after this point.
pub const Reexec = struct {
    session_name: []const u8,
    shell: []const u8,
    is_task_mode: bool,
    command: ?[]const []const u8,
    /// The session's cwd as `Daemon.cwd` holds it (OSC 7 form); empty when unknown.
    cwd: []const u8,
    /// The already-bound listen socket. It is CLOEXEC, so `reexecDisclaimed`
    /// clears that flag: recreating it in the new image would race the
    /// client, which connects the moment the fork returns to it.
    server_sock_fd: i32,
};

/// The hidden subcommand the re-exec'd image runs:
/// `zmx __daemon <session> [-- command...]`.
pub const reexec_command = "__daemon";

/// Environment variables that carry the rest of `Reexec` plus the terminal
/// size across the re-exec (argv carries only what is naturally argv: the
/// command). `takeReexecState` reads and unsets them before the shell is
/// spawned, so no program in the session ever sees them.
pub const reexec_env = struct {
    pub const socket_fd = "ZMX_DAEMON_SOCKET_FD";
    pub const rows = "ZMX_DAEMON_ROWS";
    pub const cols = "ZMX_DAEMON_COLS";
    pub const xpixel = "ZMX_DAEMON_XPIXEL";
    pub const ypixel = "ZMX_DAEMON_YPIXEL";
    pub const shell = "ZMX_DAEMON_SHELL";
    pub const task_mode = "ZMX_DAEMON_TASK_MODE";
    pub const cwd = "ZMX_DAEMON_CWD";
    pub const all = [_][:0]const u8{ socket_fd, rows, cols, xpixel, ypixel, shell, task_mode, cwd };
};

/// What `takeReexecState` hands the `__daemon` entry.
pub const ReexecState = struct {
    server_sock_fd: i32,
    size: ipc.Resize,
    shell: []const u8,
    is_task_mode: bool,
    cwd: []const u8,
};

extern "c" fn responsibility_spawnattrs_setdisclaim(attr: *std.c.posix_spawnattr_t, disclaim: c_int) c_int;

/// macOS only. Replaces this process — already forked off the client and
/// `setsid`'d — with a fresh image of zmx running `__daemon`, spawned with
/// `responsibility_spawnattrs_setdisclaim` so the kernel records the daemon
/// as its own *responsible process*. Returns only on failure; the caller then
/// carries on in the forked image as before.
///
/// Why: macOS attributes privacy-gated operations (Local Network, TCC) to the
/// responsible process, a per-process value fixed at spawn and inherited from
/// the parent, so a session created by `zmx attach` is attributed to the
/// terminal app that ran it. The moment that app exits, every process in the
/// session becomes responsible for itself, and a client reattaching over the
/// socket never re-attributes them: reattach is a connect, not a fork. From
/// then on each program in the session is judged by its own identity, which
/// for anything that is not an Apple binary means local-network access is
/// refused with EHOSTUNREACH and no prompt (macterm#419). Responsibility
/// cannot be changed after the fact (the `responsibility_set_*` calls need a
/// private entitlement), but the disclaim exists as a spawn attribute, and
/// `POSIX_SPAWN_SETEXEC` lets the forked child apply it to itself by exec'ing
/// in place: same pid, same session, same fds. The daemon is then the
/// responsible process for as long as the session lives, whatever happens to
/// the app, and its code signature's identifier is what the system asks the
/// user about: Macterm signs its bundled copy as the app itself, so the prompt
/// names Macterm and the daemon shares the app's grant.
fn reexecDisclaimed(spec: Reexec, size: ipc.Resize) !void {
    const gpa = std.heap.c_allocator;

    _ = try lib_posix.fcntl(spec.server_sock_fd, lib_posix.F.SETFD, 0);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var exe_len: u32 = exe_buf.len;
    if (std.c._NSGetExecutablePath(&exe_buf, &exe_len) != 0) return error.ExecutablePathTooLong;
    const exe = try gpa.dupeZ(u8, std.mem.sliceTo(&exe_buf, 0));

    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    try argv.append(gpa, exe.ptr);
    try argv.append(gpa, reexec_command);
    try argv.append(gpa, (try gpa.dupeZ(u8, spec.session_name)).ptr);
    if (spec.command) |command| {
        try argv.append(gpa, "--");
        for (command) |arg| try argv.append(gpa, (try gpa.dupeZ(u8, arg)).ptr);
    }
    try argv.append(gpa, null);

    try setReexecEnv(gpa, reexec_env.socket_fd, "{d}", .{spec.server_sock_fd});
    try setReexecEnv(gpa, reexec_env.rows, "{d}", .{size.rows});
    try setReexecEnv(gpa, reexec_env.cols, "{d}", .{size.cols});
    try setReexecEnv(gpa, reexec_env.xpixel, "{d}", .{size.xpixel});
    try setReexecEnv(gpa, reexec_env.ypixel, "{d}", .{size.ypixel});
    try setReexecEnv(gpa, reexec_env.shell, "{s}", .{spec.shell});
    try setReexecEnv(gpa, reexec_env.task_mode, "{d}", .{@intFromBool(spec.is_task_mode)});
    try setReexecEnv(gpa, reexec_env.cwd, "{s}", .{spec.cwd});

    var attr: std.c.posix_spawnattr_t = undefined;
    if (std.c.posix_spawnattr_init(&attr) != 0) return error.SpawnAttrInit;
    defer _ = std.c.posix_spawnattr_destroy(&attr);
    if (std.c.posix_spawnattr_setflags(&attr, .{ .SETEXEC = true }) != 0) return error.SpawnAttrFlags;
    if (responsibility_spawnattrs_setdisclaim(&attr, 1) != 0) return error.SpawnAttrDisclaim;

    var pid: std.c.pid_t = undefined;
    const rc = std.c.posix_spawn(
        &pid,
        exe.ptr,
        null,
        &attr,
        @ptrCast(argv.items.ptr),
        @ptrCast(std.c.environ),
    );
    // SETEXEC never returns on success.
    std.log.warn("posix_spawn(SETEXEC) failed rc={d}", .{rc});
    return error.ReexecFailed;
}

fn setReexecEnv(gpa: std.mem.Allocator, name: [:0]const u8, comptime fmt: []const u8, args: anytype) !void {
    const value = try std.fmt.allocPrintSentinel(gpa, fmt, args, 0);
    defer gpa.free(value);
    if (cross.c.setenv(name.ptr, value.ptr, 1) != 0) return error.SetEnvFailed;
}

pub fn unsetReexecEnv() void {
    for (reexec_env.all) |name| _ = cross.c.unsetenv(name.ptr);
}

/// Reads the state `reexecDisclaimed` left in the environment, then removes
/// it. Null when this process was not re-exec'd. Strings are copied, since
/// `unsetenv` may free the originals.
pub fn takeReexecState(gpa: std.mem.Allocator) !?ReexecState {
    const fd_str = lib_posix.getenv(reexec_env.socket_fd) orelse return null;
    const state: ReexecState = .{
        .server_sock_fd = try std.fmt.parseInt(i32, fd_str, 10),
        .size = .{
            .rows = try parseReexecInt(u16, reexec_env.rows),
            .cols = try parseReexecInt(u16, reexec_env.cols),
            .xpixel = try parseReexecInt(u16, reexec_env.xpixel),
            .ypixel = try parseReexecInt(u16, reexec_env.ypixel),
        },
        .shell = try gpa.dupe(u8, lib_posix.getenv(reexec_env.shell) orelse return error.ReexecStateIncomplete),
        .is_task_mode = std.mem.eql(u8, lib_posix.getenv(reexec_env.task_mode) orelse "0", "1"),
        .cwd = try gpa.dupe(u8, lib_posix.getenv(reexec_env.cwd) orelse ""),
    };
    unsetReexecEnv();
    return state;
}

fn parseReexecInt(comptime T: type, name: [:0]const u8) !T {
    const raw = lib_posix.getenv(name) orelse return error.ReexecStateIncomplete;
    return std.fmt.parseInt(T, raw, 10);
}

/// daemonize is the first fork in a double-fork technique to create a
/// completely disconnected session (container of process groups).
///
/// When launching a daemon, you normally set the child process of the fork to
/// be the session leader via setsid() which creates a new session that removes
/// the current controlling terminal. This is important because we don't want a
/// controlling terminal for our daemon or else it could receive signals to
/// shutdown when the controlling terminal closes.
///
/// However, if the first fork's child process is also the daemon process, then
/// it's technically possible for the daemon to open a terminal device (e.g.
/// open("/dev/console", O_RDWR)) and then it would acquire a controlling
/// terminal! A controlling terminal would expose the daemon to
/// terminal-generated signals (e.g. SIGINT) or SIGHUP from terminal disconnect
/// which could kill the daemon.
///
/// The first fork produces a child guaranteed not to be a group leader, so
/// setsid() will succeed.  By forking a second time, the grandchild process
/// (the daemon) is not the session leader. Per POSIX, only a process that is
/// the session leader can acquire a controlling terminal.
///
/// Apparently this is "a bit paranoid" and on Linux it is arguable since a
/// session leader only acquires a controlling terminal under
/// implementation-defined conditions. But the double-fork is the portable way
/// to guarantee the daemon can never acquire one, regardless of how a given
/// POSIX implementation behaves. So we baked it into zmx.
///
/// PID=42  SID=10  PGID=10  ← original (PG leader, has tty)
///     │
///     │  fork #1
///     ├──────────┐
///     │ exit     │ PID=55  SID=10  PGID=10  (not a PG leader)
///     ✝          │
///                │ setsid()
///                ▼
///               PID=55  SID=55  PGID=55  (session leader, no tty)
///                 │
///                 │  fork #2
///                 ├──────────┐
///                 │ exit     │ PID=73  SID=55  PGID=55
///                 ✝          │ PID≠SID → can't get a tty
///                            ▼
///                          DAEMON ✓
pub fn daemonize(sesh_name: []const u8, cmd: Cmd, keep_fds_open: []i32, reexec: ?Reexec) !PtyInfo {
    // creates the daemon
    const pid = try lib_posix.fork();
    assert(pid != -1);

    if (pid > 0) { // parent (client)
        // cannot use a passed-in io or alloc after a fork so we create what we need
        // after the fork()
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const io = threaded.io();
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch unreachable;
        return error.IsClientProc;
    }

    assert(pid == 0); // child (daemon's parent in double-fork)
    // becomes the session leader and detaches process from its controlling terminal
    _ = try lib_posix.setsid();

    // Fetch terminal size before redirecting stdio FDs to /dev/null.
    const term_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);

    // Redirect stdin/stdout/stderr to /dev/null. The daemon
    // communicates via its unix socket, not stdio. Without
    // this, any pipe on FDs 0-2 (e.g. from bats' `run`
    // keyword) stays open for the daemon's lifetime, causing
    // the caller to hang waiting for EOF.
    {
        const devnull = lib_posix.open(
            "/dev/null",
            .{ .ACCMODE = .RDWR },
            0,
        ) catch |err| {
            std.log.warn("failed to open /dev/null: {s}", .{@errorName(err)});
            return err;
        };
        inline for (.{ lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO, lib_posix.STDERR_FILENO }) |fd| {
            _ = lib_posix.dup2(devnull, fd) catch |err| {
                std.log.warn("dup2 /dev/null -> {d}: {s}", .{ fd, @errorName(err) });
                return err;
            };
        }
        var found = false;
        for (keep_fds_open) |fd| {
            if (devnull == fd) found = true;
        }
        if (devnull > 2 and !found) lib_posix.close(devnull);
    }

    // Close file descriptors inherited from the parent that the
    // daemon doesn't need. This prevents test harnesses (like
    // bats) from hanging: they wait for their internal FDs (3+)
    // to close before exiting.
    //
    // Skip any fds that the caller wants to keep open, e.g. server_sock_fd
    // (needed for IPC) and dir.fd (needed to delete the socket file on
    // shutdown).
    {
        var fd: i32 = 3;
        while (fd < 64) : (fd += 1) {
            var found = false;
            for (keep_fds_open) |kfd| {
                if (fd == kfd) found = true;
            }
            if (!found) _ = std.c.close(fd);
        }
    }

    if (reexec) |spec| {
        reexecDisclaimed(spec, term_size) catch |err| {
            std.log.warn("daemon re-exec failed, continuing in the forked image: {s}", .{@errorName(err)});
            unsetReexecEnv();
        };
    }

    return spawnPty(sesh_name, cmd, term_size);
}
