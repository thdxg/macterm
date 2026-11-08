const std = @import("std");
const zmx = @import("client.zig");
const builtin = @import("builtin");
const Environ = std.process.Environ;
const build_options = @import("build_options");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const util = @import("util.zig");
const socket = @import("socket.zig");
const label = @import("label.zig");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const Cfg = @import("cfg.zig");
const loop = @import("loop.zig");
const daemonize = @import("daemonize.zig");
const foreground = @import("foreground.zig");
const schema = @import("protocol/schema.zig");
const v2session = @import("session.zig");
const runtime = @import("runtime.zig");
const v2attach = @import("attach.zig");
const Daemon = loop.Daemon;
const version = build_options.version;
const ghostty_version = build_options.ghostty_version;

pub const std_options: std.Options = .{
    .logFn = log.zmxLogFn,
    .log_level = .debug,
};

fn detectHelp(arg: []const u8) bool {
    return (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"));
}

/// Prints an error message to stderr and exits with status 1.
fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("error: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}
pub fn main(init: std.process.Init) !void {
    mainImpl(init) catch |err| switch (err) {
        error.Sighup => signal.reraise(.HUP),
        error.Sigint => signal.reraise(.INT),
        error.Sigterm => signal.reraise(.TERM),
        else => return err,
    };
}

fn mainImpl(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Every subcommand may write to a Unix-domain socket; a peer that
    // disappears between probe and send would otherwise kill us before
    // write() can return BrokenPipe. Inherited across fork, so this also
    // covers the daemon.
    signal.ignoreSigpipe();

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // skip program name
    const first_arg = args.next();

    // Needs no config, no log and no session directory: CI runs it.
    if (first_arg != null and std.mem.eql(u8, first_arg.?, "__schema")) {
        return schemaCommand(gpa, io, args.next(), args.next());
    }

    // The v2 session runs before `Cfg`: it uses none of v1's directories or
    // its log (see session.zig).
    if (first_arg) |c| {
        // No log file until the session opens its own: lines go to stderr.
        log.log_system.io = io;
        const shell = init.environ_map.get("SHELL") orelse "/bin/sh";
        if (std.mem.eql(u8, c, "session")) return sessionCommand(gpa, io, init.environ_map, shell, &args);
        if (std.mem.eql(u8, c, v2session.reexec_command)) return sessionEntry(gpa, io, init.environ_map, &args);
        if (std.mem.eql(u8, c, "connect")) return connectCommand(gpa, io, init.environ_map, &args);
    }

    var cfg = try Cfg.init(gpa, io);
    defer cfg.deinit(gpa);

    const log_path = try std.fs.path.join(gpa, &.{ cfg.log_dir, "zmx.log" });
    defer gpa.free(log_path);
    const log_mode = std.Io.File.Permissions.fromMode(@intCast(cfg.log_mode));
    try log.log_system.init(io, log_path, log_mode);
    defer log.log_system.deinit();

    const shell_env = init.environ_map.get("SHELL") orelse "/bin/sh";

    const cmd = first_arg orelse {
        return list(gpa, io, &cfg, false);
    };

    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "--version")) {
        return printVersion(io, &cfg);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "-h")) {
        return help(io);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "l") or std.mem.eql(u8, cmd, "ls")) {
        var short = false;
        while (args.next()) |arg| {
            if (detectHelp(arg)) return help(io);
            if (std.mem.eql(u8, arg, "--short")) short = true;
        }
        return list(gpa, io, &cfg, short);
    } else if (std.mem.eql(u8, cmd, "get") or std.mem.eql(u8, cmd, "g")) {
        const sesh_name = args.next() orelse {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        };
        if (detectHelp(sesh_name)) return help(io);
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_name);
        defer gpa.free(sesh);
        const single_kv = args.next() orelse "";
        return labelGet(gpa, io, &cfg, sesh, single_kv);
    } else if (std.mem.eql(u8, cmd, "set")) {
        const sesh_name = args.next() orelse {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        };
        if (detectHelp(sesh_name)) return help(io);
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_name);
        defer gpa.free(sesh);

        var kvs = std.ArrayList(u8).empty;
        defer kvs.deinit(gpa);
        var first = true;
        while (args.next()) |arg| {
            if (!first) try kvs.append(gpa, ' ');
            try kvs.appendSlice(gpa, arg);
            first = false;
        }
        if (kvs.items.len == 0) {
            return printError(io, "at least one key=value pair required", .{});
        }
        return labelSet(gpa, io, &cfg, sesh, kvs.items);
    } else if (std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "cl")) {
        const sesh_name = args.next() orelse {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        };
        if (detectHelp(sesh_name)) return help(io);
        const sesh = try socket.resolveSessionOrEnv(gpa, io, sesh_name);
        defer gpa.free(sesh);
        return labelClear(gpa, io, &cfg, sesh);
    } else if (std.mem.eql(u8, cmd, "history") or std.mem.eql(u8, cmd, "hi")) {
        var session_name: ?[]const u8 = null;
        var format: util.HistoryFormat = .plain;
        var scrollback_rows: ?u32 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return help(io);
            } else if (std.mem.eql(u8, arg, "--vt")) {
                format = .vt;
            } else if (std.mem.eql(u8, arg, "--html")) {
                format = .html;
            } else if (std.mem.eql(u8, arg, "--screen")) {
                if (scrollback_rows != null) return printError(io, "--screen and --scrollback may only be specified once", .{});
                scrollback_rows = 0;
            } else if (std.mem.eql(u8, arg, "--scrollback")) {
                if (scrollback_rows != null) return printError(io, "--screen and --scrollback may only be specified once", .{});
                const count = args.next() orelse return printError(io, "--scrollback requires a row count", .{});
                scrollback_rows = std.fmt.parseInt(u32, count, 10) catch return printError(io, "invalid scrollback row count: {s}", .{count});
            } else if (session_name == null) {
                session_name = arg;
            }
        }
        const sesh_env = socket.getSeshNameFromEnv();
        const raw_name = session_name orelse (if (sesh_env.len > 0) sesh_env else {
            return printError(io, "session name required (or run inside a zmx session)", .{});
        });
        const sesh = try socket.getSeshName(gpa, raw_name);
        defer gpa.free(sesh);
        return history(gpa, io, &cfg, sesh, format, scrollback_rows);
    } else if (std.mem.eql(u8, cmd, "attach") or std.mem.eql(u8, cmd, "a")) {
        var attach_args: std.ArrayList([]const u8) = .empty;
        defer attach_args.deinit(gpa);
        while (args.next()) |arg| {
            try attach_args.append(gpa, arg);
        }

        const parsed = parseAttachArgs(attach_args.items);
        if (parsed.want_help) {
            return help(io);
        }
        if (parsed.missing_labels_value) {
            return printError(io, "--labels requires \"key=value ...\"", .{});
        }
        // Before ensureSession, so a rejected label does not leave a session
        // behind that the caller never asked for.
        if (parsed.labels) |kvs| assertLabels(io, kvs);

        var command: ?[][]const u8 = null;
        if (parsed.command_start < attach_args.items.len) {
            command = attach_args.items[parsed.command_start..];
        }

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const cwd = cwd_buf[0..cwd_len];

        // The session's shell does not inherit it: the daemon removes it in
        // the child that execs the shell (see foreground.zig).
        const foreground_events = lib_posix.getenv(foreground.env_var) != null;

        zmx.attach(gpa, io, parsed.session_name, .{
            .command = command,
            .cwd = cwd,
            .shell = shell_env,
            .labels = parsed.labels,
            .foreground_events = foreground_events,
        }) catch |err| switch (err) {
            error.Sighup, error.Sigint, error.Sigterm => return err,
            else => return printError(io, "cannot connect to session \"{s}\": {s}", .{ parsed.session_name, @errorName(err) }),
        };
        return;
    } else if (std.mem.eql(u8, cmd, "send") or std.mem.eql(u8, cmd, "s")) {
        const session_name = args.next() orelse "";
        if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
            return help(io);
        }
        if (session_name.len == 0) {
            return printError(io, "session name required", .{});
        }

        var text_parts: std.ArrayList([]const u8) = .empty;
        defer text_parts.deinit(gpa);
        while (args.next()) |arg| {
            try text_parts.append(gpa, arg);
        }

        send(gpa, io, session_name, text_parts.items) catch |err| {
            if (err == error.SessionUnresponsive) std.process.exit(1);
            return printError(io, "send failed: {s}", .{@errorName(err)});
        };
    } else if (std.mem.eql(u8, cmd, "kill") or std.mem.eql(u8, cmd, "k")) {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        const stderr = &stderr_writer.interface;

        var matchers: std.ArrayList(socket.SessionMatch) = .empty;
        defer {
            for (matchers.items) |m| {
                gpa.free(m.name);
            }
            matchers.deinit(gpa);
        }
        var force = false;
        while (args.next()) |session_name| {
            if (std.mem.eql(u8, session_name, "--help") or std.mem.eql(u8, session_name, "-h")) {
                return help(io);
            }
            if (std.mem.eql(u8, session_name, "--force")) {
                force = true;
                continue;
            }
            const m = try socket.parseSessionArg(gpa, session_name);
            try matchers.append(gpa, m);
        }
        if (matchers.items.len == 0) {
            return printError(io, "session name required", .{});
        }
        const sessions = try zmx.list(gpa, io);
        defer {
            for (sessions) |session| {
                session.deinit(gpa);
            }
            gpa.free(sessions);
        }

        var killed_any = false;
        for (sessions) |session| {
            for (matchers.items) |m| {
                if (!m.matches(session.name)) continue;
                kill(gpa, io, &cfg, session.name, force) catch |err| {
                    if (err == error.SessionNotFound and force) {
                        killed_any = true;
                        continue;
                    }
                    try stderr.print("failed to kill session={s}: {s}\n", .{ session.name, @errorName(err) });
                    try stderr.flush();
                };
                killed_any = true;
                break;
            }
        }
        if (!killed_any) {
            for (matchers.items) |m| {
                if (m.is_prefix) continue;
                kill(gpa, io, &cfg, m.name, force) catch |err| {
                    if (err == error.SessionNotFound and force) {
                        killed_any = true;
                        continue;
                    }
                    return printError(io, "failed to kill session={s}: {s}", .{ m.name, @errorName(err) });
                };
                killed_any = true;
            }
            if (!killed_any) return printError(io, "no matching sessions found", .{});
        }
    } else if (std.mem.eql(u8, cmd, daemonize.reexec_command)) {
        return daemonEntry(gpa, io, &cfg, &args);
    } else {
        return printError(io, "unknown command \"{s}\"", .{cmd});
    }
}

/// The macOS session daemon after its disclaiming re-exec; not a user command
/// (see `daemonize.reexecDisclaimed`). argv is `__daemon <session> [-- command...]`;
/// the rest of the state rides in `daemonize.reexec_env` and is consumed here,
/// before the shell exists.
fn daemonEntry(gpa: std.mem.Allocator, io: std.Io, cfg: *Cfg, args: anytype) !void {
    const sesh = args.next() orelse {
        return printError(io, "{s}: session name required", .{daemonize.reexec_command});
    };
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    if (args.next()) |sep| {
        if (!std.mem.eql(u8, sep, "--")) {
            return printError(io, "{s}: unexpected argument \"{s}\"", .{ daemonize.reexec_command, sep });
        }
        while (args.next()) |arg| try command.append(gpa, arg);
    }
    const state = (try daemonize.takeReexecState(gpa)) orelse {
        return printError(io, "{s}: no re-exec state in the environment", .{daemonize.reexec_command});
    };
    defer gpa.free(state.shell);
    defer gpa.free(state.cwd);

    const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => return socket.printSessionNameTooLong(io, sesh, cfg.socket_dir),
        error.OutOfMemory => return err,
    };
    defer gpa.free(socket_path);
    var daemon = Daemon.init(io, cfg, sesh, socket_path);
    daemon.shell = state.shell;
    if (command.items.len > 0) daemon.command = command.items;
    if (state.cwd.len > 0) daemon.setCwd(state.cwd);
    std.log.info("daemon re-exec'd disclaimed session={s} pid={d}", .{ sesh, std.c.getpid() });
    _ = try daemon.resumeAfterReexec(io, state.server_sock_fd, state.size);
}

/// `session [--cols N] [--rows N] [--cwd DIR] <name> [--] [command...]`: starts
/// a v2 session (session.zig) and returns once its socket accepts
/// connections. Not in `help` yet: the server (issue 0048) runs it.
fn sessionCommand(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, shell: []const u8, args: anytype) !void {
    var opts: v2session.Options = .{ .name = "", .shell = shell };
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    while (args.next()) |arg| {
        if (opts.name.len > 0) {
            if (command.items.len == 0 and std.mem.eql(u8, arg, "--")) continue;
            try command.append(gpa, arg);
        } else if (std.mem.eql(u8, arg, "--cols") or std.mem.eql(u8, arg, "--rows")) {
            const value = args.next() orelse return printError(io, "{s} requires a number", .{arg});
            const n = std.fmt.parseInt(u16, value, 10) catch 0;
            if (n == 0) return printError(io, "{s}: not a size: {s}", .{ arg, value });
            if (arg[2] == 'c') opts.size.cols = n else opts.size.rows = n;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            const dir = args.next() orelse return printError(io, "--cwd requires a directory", .{});
            const handle = std.Io.Dir.openDirAbsolute(io, dir, .{}) catch |err|
                return printError(io, "cannot open directory {s}: {s}", .{ dir, @errorName(err) });
            defer handle.close(io);
            std.process.setCurrentDir(io, handle) catch |err|
                return printError(io, "cannot enter directory {s}: {s}", .{ dir, @errorName(err) });
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return printError(io, "unknown option \"{s}\"", .{arg});
        } else {
            opts.name = arg;
        }
    }
    if (opts.name.len == 0) return printError(io, "session name required", .{});
    if (command.items.len > 0) opts.command = command.items;

    const dir = runtime.resolveDir(gpa, env) catch return printError(io, "no runtime directory: set {s}", .{runtime.dir_env});
    defer gpa.free(dir);
    v2session.start(gpa, io, dir, opts) catch |err| switch (err) {
        error.InvalidName => return printError(io, "invalid session name \"{s}\": use letters, digits, '-', '_' and '.', not first", .{opts.name}),
        error.NameTooLong => return printError(io, "session name \"{s}\" is too long for a socket in {s}", .{ opts.name, dir }),
        error.SessionExists => return printError(io, "session \"{s}\" already exists", .{opts.name}),
        error.RuntimeDir => {
            const reason = if (runtime.ensureDir(dir)) |_| "failed the check" else |e| runtime.describe(e);
            return printError(io, "runtime directory {s} {s}", .{ dir, reason });
        },
        else => return printError(io, "cannot start session \"{s}\": {s}", .{ opts.name, @errorName(err) }),
    };
}

/// `zmx connect <name>`: the pane's client of a v2 session (attach.zig). It
/// becomes `macterm attach` when v1's `attach` goes (design/007 §6).
fn connectCommand(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: anytype) !void {
    const name = args.next() orelse return printError(io, "session name required", .{});
    if (args.next()) |extra| return printError(io, "unexpected argument \"{s}\"", .{extra});
    const dir = runtime.resolveDir(gpa, env) catch return printError(io, "no runtime directory: set {s}", .{runtime.dir_env});
    defer gpa.free(dir);
    const outcome = v2attach.run(gpa, dir, name) catch |err| switch (err) {
        error.Sighup, error.Sigint, error.Sigterm => return err,
        error.InvalidName => return printError(io, "invalid session name \"{s}\"", .{name}),
        error.RuntimeDir => return printError(io, "runtime directory {s} failed the check", .{dir}),
        error.NoSession => return printError(io, "no session \"{s}\"", .{name}),
        error.WrongPeer => return printError(io, "session \"{s}\" belongs to another user", .{name}),
        error.NoAnswer => return printError(io, "session \"{s}\" did not answer", .{name}),
        error.Protocol => return printError(io, "connection to session \"{s}\" failed", .{name}),
        error.OutOfMemory => return err,
    };
    switch (outcome) {
        .session_too_old => |o| return printError(io, "session \"{s}\" speaks protocol level {d}, and this build needs level {d} or later", .{ name, o.level, o.min_level }),
        .refused => |r| {
            if (std.mem.eql(u8, r.reason, "level_too_low"))
                return printError(io, "session \"{s}\" needs protocol level {d} or later, and this build speaks level {d}", .{ name, r.needs_level, v2attach.protocol_level });
            return printError(io, "session \"{s}\" refused this build: {s}", .{ name, r.reason });
        },
        .closed => return printError(io, "session \"{s}\" closed", .{name}),
        else => std.process.exit(v2attach.exitCode(outcome)),
    }
}

/// The macOS v2 session after its disclaiming re-exec; not a user command.
/// argv is `__session <name> [-- command...]`, the rest rides in
/// `daemonize.reexec_env`, as for `__daemon`.
fn sessionEntry(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: anytype) !void {
    const name = args.next() orelse return printError(io, "{s}: session name required", .{v2session.reexec_command});
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    if (args.next()) |sep| {
        if (!std.mem.eql(u8, sep, "--")) return printError(io, "{s}: unexpected argument \"{s}\"", .{ v2session.reexec_command, sep });
        while (args.next()) |arg| try command.append(gpa, arg);
    }
    const state = (try daemonize.takeReexecState(gpa)) orelse
        return printError(io, "{s}: no re-exec state in the environment", .{v2session.reexec_command});
    const dir = try runtime.resolveDir(gpa, env);
    v2session.resumeAfterReexec(dir, .{
        .name = name,
        .command = if (command.items.len > 0) command.items else null,
        .shell = state.shell,
        .size = state.size,
    }, state.server_sock_fd);
}

fn help(io: std.Io) !void {
    const help_text =
        \\zmx - session persistence for terminal processes
        \\
        \\Usage: zmx <command> [args...]
        \\
        \\Commands:
        \\  [a]ttach [--labels kv] <name> [command...]                 Attach to session, creating if needed
        \\  [s]end <name> <text...>                                    Send raw input to session PTY
        \\  [l]ist|ls [--short]                                        List active sessions
        \\  [g]et <name>                                               Get session labels
        \\  set <name> k=v ...                                         Set session labels (k= to remove)
        \\  [cl]ear <name>                                             Clear all session labels
        \\  [k]ill <name>... [--force]                                 Kill session and all attached clients
        \\  [hi]story <name> [--vt|--html] [--screen|--scrollback]     Output session scrollback
        \\  [v]ersion                                                  Show version and metadata (socket dir, log dir)
        \\  [h]elp                                                     Show this help
        \\
        \\Attach:
        \\  This will spawn a login $SHELL with a PTY.  You can provide a
        \\  command instead of creating a shell.  Ctrl+\ detaches.
        \\
        \\  --labels applies labels as the session is created, in the same form
        \\  `zmx set` takes. A caller that creates and then labels in two steps
        \\  leaves an unlabelled session behind if it dies between them.
        \\
        \\  Examples:
        \\    zmx attach dev
        \\    zmx attach dev vim
        \\    zmx attach --labels "project=api role=worker" build
        \\
        \\History:
        \\  This should generally be used with `tail` to print the last lines
        \\  of the session's scrollback history.
        \\
        \\  --screen outputs only the active screen, and --scrollback N adds up
        \\  to N rows of scrollback above it, so pollers can skip formatting
        \\  history they would discard. Both work with --vt and --html.
        \\
        \\  Examples:
        \\    zmx history <session> | tail -100
        \\    zmx history --screen <session>
        \\    zmx history --scrollback 512 <session>
        \\
        \\Send:
        \\  Sends raw text to the session's PTY input (fire-and-forget).
        \\  Useful for TUI applications, interactive prompts, or any program
        \\  that reads stdin directly.
        \\
        \\  Text is sent byte-for-byte with no automatic carriage return.
        \\  Append \r yourself when you want the shell to execute a command.
        \\
        \\  Text can also be piped via stdin:
        \\    printf 'ls -la\r' | zmx send dev
        \\
        \\  Examples:
        \\    printf 'echo hello\r' | zmx send dev
        \\    zmx send dev $(printf '\x03')
        \\    zmx send dev /compact
        \\
        \\Labels:
        \\  Attach key=value labels to live sessions for discovery and
        \\  filtering. Labels are in-memory and scoped to session lifetime.
        \\
        \\  Examples:
        \\    zmx set dev project=zmx env=dev
        \\    zmx set dev project=            # unset a label
        \\    zmx set . status=fail           # "." resolves to current session
        \\    zmx get dev
        \\    zmx get dev project
        \\    zmx set next "$(zmx get prev)"  # set labels from other session
        \\    zmx list | grep project=zmx
        \\    zmx clear dev
        \\
        \\Environment variables:
        \\  SHELL                Default shell for new sessions
        \\  ZMX_DIR              Socket directory (priority 1)
        \\  XDG_RUNTIME_DIR      Socket directory (priority 2)
        \\  TMPDIR               Socket directory (priority 3)
        \\  ZMX_SESSION          Session name (injected automatically; makes attach
        \\                       switch this session)
        \\  ZMX_SESSION_PREFIX   Prefix added to all session names
        \\  ZMX_DIR_MODE         Sets mode for socket and log directories (octal, defaults to 0750)
        \\  ZMX_LOG_MODE         Sets mode for log files (octal, defaults to 0640)
        \\  ZMX_NO_DETACH_KEY    Disables the ctrl+\ detach shortcut (set to any value)
        \\
    ;
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(help_text, .{});
    try w.interface.flush();
}

/// `__schema swift | metadata | fixtures` writes that file of the protocol
/// schema to stdout. `__schema check [old-metadata.json]` checks this build's
/// schema against an older one and exits 1 on a problem (design/003 §3).
/// Hidden: `scripts/protocol.sh` runs it.
fn schemaCommand(gpa: std.mem.Allocator, io: std.Io, what: ?[]const u8, path: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;
    const kind = what orelse printError(io, "__schema needs swift, metadata, fixtures or check", .{});
    if (std.mem.eql(u8, kind, "swift")) {
        try schema.writeSwift(w, schema.metadata);
    } else if (std.mem.eql(u8, kind, "metadata")) {
        try schema.writeMetadata(w, schema.metadata);
    } else if (std.mem.eql(u8, kind, "fixtures")) {
        try schema.writeFixtures(arena, w);
    } else if (std.mem.eql(u8, kind, "check")) {
        const old: ?schema.Metadata = if (path) |p| blk: {
            const text = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(16 * 1024 * 1024)) catch |err|
                printError(io, "cannot read {s}: {s}", .{ p, @errorName(err) });
            break :blk std.json.parseFromSliceLeaky(schema.Metadata, arena, text, .{ .ignore_unknown_fields = true }) catch |err|
                printError(io, "cannot parse {s}: {s}", .{ p, @errorName(err) });
        } else null;
        const problems = try schema.check(w, old, schema.metadata);
        try w.flush();
        if (problems > 0) printError(io, "{d} problems in the protocol schema", .{problems});
    } else {
        printError(io, "unknown __schema output {s}", .{kind});
    }
    try w.flush();
}

fn printVersion(io: std.Io, cfg: *Cfg) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(
        "zmx\t\t{s}\nghostty_vt\t{s}\nsocket_dir\t{s}\nlog_dir\t\t{s}\n",
        .{ version, ghostty_version, cfg.socket_dir, cfg.log_dir },
    );
    try w.interface.flush();
}

fn list(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, short: bool) !void {
    const current_session = socket.getSeshNameFromEnv();
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const sessions = try zmx.list(alloc, io);
    defer {
        for (sessions) |session| {
            session.deinit(alloc);
        }
        alloc.free(sessions);
    }

    if (sessions.len == 0) {
        if (short) return;
        var errbuf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &errbuf);
        try stderr.interface.print("no sessions found in {s}\n", .{cfg.socket_dir});
        try stderr.interface.flush();
        return;
    }

    std.mem.sort(util.SessionEntry, sessions, {}, util.SessionEntry.lessThan);

    for (sessions) |session| {
        try util.writeSessionLine(&stdout.interface, session, short, current_session);
        try stdout.interface.flush();
    }
}

fn kill(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, force: bool) !void {
    _ = cfg;
    std.log.info("kill session={s}", .{session_name});
    const status = zmx.kill(alloc, io, session_name, .{ .force = force }) catch |err| switch (err) {
        error.SessionNotFound => return error.SessionNotFound,
        error.SessionUnresponsive => return error.SessionUnresponsive,
        error.BrokenPipe, error.ConnectionResetByPeer => return,
        else => return err,
    };

    if (status == .cleaned_stale) {
        var ebuf: [4096]u8 = undefined;
        var ew = std.Io.File.stderr().writer(io, &ebuf);
        ew.interface.print("cleaned up stale session {s}\n", .{session_name}) catch {};
        ew.interface.flush() catch {};
        return;
    }

    var buf: [100]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("killed session {s}\n", .{session_name});
    try w.interface.flush();
}

fn printLabelError(io: std.Io, session_name: []const u8, err: anyerror) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    switch (err) {
        error.Timeout => w.interface.print(
            "error: session \"{s}\" does not support labels (daemon too old?)\n",
            .{session_name},
        ) catch {},
        error.ConnectionRefused, error.Unexpected => w.interface.print(
            "error: session \"{s}\" not found or unresponsive\n",
            .{session_name},
        ) catch {},
        else => w.interface.print(
            "error: {s}\n",
            .{@errorName(err)},
        ) catch {},
    }
    w.interface.flush() catch {};
    std.process.exit(1);
}

fn labelGet(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, single_kv: []const u8) !void {
    _ = cfg;
    std.log.info("label get session={s}", .{session_name});

    const key = if (single_kv.len == 0) null else single_kv;
    const val = zmx.get(alloc, io, session_name, key) catch |err| {
        if (err == error.LabelKeyNotFound) {
            return printError(io, "label key \"{s}\" not found in session \"{s}\"", .{ single_kv, session_name });
        }
        printLabelError(io, session_name, err);
    };
    defer alloc.free(val);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.print("{s}", .{val});
    try stdout.interface.flush();
}

/// Rejects a malformed label set before the caller acts on it. Exits rather
/// than returning, so `attach --labels` can check its labels before a session
/// exists to be left behind.
fn assertLabels(io: std.Io, labels: []const u8) void {
    var kvs = label.LabelIterator.init(labels);
    while (kvs.next()) |kv| {
        label.assertLabel(kv.key, kv.value) catch |err| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &buf);
            const msg = "error: key-value kvs can only contain [a-z, A-Z, 0-9, -_.] characters";
            switch (err) {
                error.LabelKeyEmpty => {
                    w.interface.print("error: label key cannot be empty\n", .{}) catch {};
                },
                error.LabelKeyReservedName => {
                    w.interface.print("error: \"{s}\" is a read-only built-in field\n", .{kv.key}) catch {};
                },
                error.LabelKeyInvalidChar => {
                    w.interface.print("{s}: key=[{s}]\n", .{ msg, kv.key }) catch {};
                },
                error.LabelValueInvalidChar => {
                    w.interface.print("{s}: value=[{s}]\n", .{ msg, kv.value }) catch {};
                },
            }
            w.interface.flush() catch {};
            std.process.exit(1);
        };
    }
}

fn labelSet(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, labels: []const u8) !void {
    _ = cfg;
    std.log.info("label set session={s}", .{session_name});

    assertLabels(io, labels);
    zmx.set(alloc, io, session_name, labels) catch |err| {
        printLabelError(io, session_name, err);
    };
}

fn labelClear(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8) !void {
    _ = cfg;
    std.log.info("label clear session={s}", .{session_name});

    zmx.clear(alloc, io, session_name) catch |err| {
        printLabelError(io, session_name, err);
    };
}

fn history(alloc: std.mem.Allocator, io: std.Io, cfg: *Cfg, session_name: []const u8, format: util.HistoryFormat, scrollback_rows: ?u32) !void {
    _ = cfg;
    std.log.info("history session={s}", .{session_name});

    const data = zmx.historyRange(alloc, io, session_name, format, scrollback_rows) catch |err| switch (err) {
        error.SessionNotFound => return printError(io, "session \"{s}\" does not exist", .{session_name}),
        error.SessionUnresponsive => return printError(io, "session \"{s}\" is unresponsive (SessionUnresponsive)", .{session_name}),
        error.CaptureNotSupported => return printError(io, "session \"{s}\" does not support --screen/--scrollback (daemon too old?)", .{session_name}),
        error.Timeout => {
            std.log.err("timeout waiting for history response", .{});
            return;
        },
        error.ConnectionClosed, error.ReadFailed => return,
        else => return err,
    };
    defer alloc.free(data);

    _ = lib_posix.write(lib_posix.STDOUT_FILENO, data) catch return;
}

const AttachArgs = struct {
    /// Session name, or "" when the caller did not name one.
    session_name: []const u8 = "",
    /// Index of the first word of the session command.
    command_start: usize = 0,
    /// `--labels "k=v ..."`: labels to apply once the session exists, in the
    /// same space-separated form `zmx set` takes.
    labels: ?[]const u8 = null,
    want_help: bool = false,
    /// `--labels` was given with nothing to apply.
    missing_labels_value: bool = false,
};

/// Parses the arguments that follow `zmx attach`. Flags are only recognized
/// before the session name, so everything after it stays part of the command
/// handed to the session.
fn parseAttachArgs(argv: []const []const u8) AttachArgs {
    const labels_flag = "--labels";
    var parsed: AttachArgs = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            parsed.want_help = true;
            return parsed;
        }
        if (std.mem.startsWith(u8, arg, labels_flag ++ "=")) {
            parsed.labels = arg[labels_flag.len + 1 ..];
            continue;
        }
        if (std.mem.eql(u8, arg, labels_flag)) {
            if (i + 1 >= argv.len) {
                parsed.missing_labels_value = true;
                parsed.command_start = argv.len;
                return parsed;
            }
            i += 1;
            parsed.labels = argv[i];
            continue;
        }
        parsed.session_name = arg;
        i += 1;
        break;
    }
    parsed.command_start = i;
    return parsed;
}

fn send(alloc: std.mem.Allocator, io: std.Io, session_name: []const u8, text_parts: [][]const u8) !void {
    std.log.info("send session={s}", .{session_name});

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(alloc);

    if (text_parts.len > 0) {
        for (text_parts, 0..) |part, i| {
            if (i > 0) try payload.append(alloc, ' ');
            try payload.appendSlice(alloc, part);
        }
    } else {
        // Read from stdin when no text arguments provided.
        const stdin_file = std.Io.File.stdin();
        defer stdin_file.close(io);
        var stdin_buf: [4096]u8 = undefined;
        var reader = stdin_file.reader(io, &stdin_buf);
        if (!try stdin_file.isTty(io)) {
            while (true) {
                var dest: [1024]u8 = undefined;
                const n = try reader.interface.readSliceShort(&dest);
                if (n == 0) break; // EOF
                try payload.appendSlice(alloc, dest[0..n]);
            }
            // Strip trailing newline from piped input; the caller is
            // responsible for including \r when submission is desired.
            if (payload.items.len > 0 and payload.items[payload.items.len - 1] == '\n') {
                _ = payload.pop();
            }
        }
    }

    if (payload.items.len == 0) {
        return printError(io, "text argument required (or pipe input via stdin)", .{});
    }

    zmx.send(alloc, io, session_name, payload.items) catch |err| {
        if (err == error.SessionUnresponsive) {
            var errbuf: [4096]u8 = undefined;
            var ew = std.Io.File.stderr().writer(io, &errbuf);
            ew.interface.print("session {s} is unresponsive\ndaemon may be busy: try again\n", .{session_name}) catch {};
            ew.interface.flush() catch {};
            return error.SessionUnresponsive;
        }
        return err;
    };
}

test "parseAttachArgs reads a bare session name" {
    const parsed = parseAttachArgs(&.{"dev"});
    try std.testing.expectEqualStrings("dev", parsed.session_name);
    try std.testing.expect(!parsed.want_help);
    try std.testing.expectEqual(@as(usize, 1), parsed.command_start);
}

test "parseAttachArgs keeps the session command intact" {
    const argv: []const []const u8 = &.{ "dev", "vim", "-n" };
    const parsed = parseAttachArgs(argv);
    try std.testing.expectEqualStrings("dev", parsed.session_name);
    // -n after the session name belongs to the command, not to zmx.
    try std.testing.expectEqualSlices([]const u8, argv[1..], argv[parsed.command_start..]);
}

test "parseAttachArgs reports help before the session name" {
    try std.testing.expect(parseAttachArgs(&.{"--help"}).want_help);
    try std.testing.expect(parseAttachArgs(&.{"-h"}).want_help);
    try std.testing.expect(parseAttachArgs(&.{ "--labels", "a=1", "--help" }).want_help);
    // Once a session name is read, -h belongs to the command.
    try std.testing.expect(!parseAttachArgs(&.{ "dev", "-h" }).want_help);
}

test "parseAttachArgs reads --labels in both forms" {
    for ([_][]const []const u8{
        &.{ "--labels", "a=1 b=2", "build" },
        &.{ "--labels=a=1 b=2", "build" },
    }) |argv| {
        const parsed = parseAttachArgs(argv);
        try std.testing.expectEqualStrings("a=1 b=2", parsed.labels.?);
        try std.testing.expectEqualStrings("build", parsed.session_name);
        try std.testing.expect(!parsed.missing_labels_value);
        try std.testing.expectEqual(argv.len, parsed.command_start);
    }
}

test "parseAttachArgs combines --labels with a session command" {
    const argv: []const []const u8 = &.{ "--labels", "a=1", "build", "make", "--labels" };
    const parsed = parseAttachArgs(argv);
    try std.testing.expectEqualStrings("a=1", parsed.labels.?);
    try std.testing.expectEqualStrings("build", parsed.session_name);
    // --labels after the session name belongs to the command.
    try std.testing.expectEqualSlices([]const u8, argv[3..], argv[parsed.command_start..]);
}

test "parseAttachArgs reports --labels with no value" {
    const parsed = parseAttachArgs(&.{"--labels"});
    try std.testing.expect(parsed.missing_labels_value);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.labels);
}

test "parseAttachArgs leaves labels unset when the flag is absent" {
    const parsed = parseAttachArgs(&.{"dev"});
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.labels);
    try std.testing.expect(!parsed.missing_labels_value);
}
