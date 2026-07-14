import Darwin
import Foundation

/// Reads the command currently running in a pane by resolving its foreground
/// process. libghostty hands us the pid directly
/// (`ghostty_surface_foreground_pid`, exposed as `GhosttyTerminalNSView
/// .foregroundPID`); we turn that pid into a command string via the OS process
/// table (`KERN_PROCARGS2`). No process-tree walking or env markers needed.
///
/// Everything is best-effort: any failure yields nil rather than throwing. Only
/// same-uid processes are readable, which the pane's foreground process is.
enum ProcessInspector {
    /// The pid to inspect for a pane's foreground process. When the pane's
    /// shell is wrapped in zmx, libghostty's `foregroundPID` points at the
    /// local `zmx attach` client (whose `comm` is just `zmx`), while the real
    /// shell / program runs under the zmx daemon — a detached process tree
    /// reachable only by session name. `ZmxForegroundResolver` maps the name
    /// to the daemon's pty foreground process; use that when available, else
    /// fall back to libghostty's pid (no zmx, over-budget bypass, or before
    /// the first `zmx ls` populates the cache).
    /// The resolved foreground pid for a pane — the zmx daemon-side shell/program
    /// when wrapped, else libghostty's client pid — the SAME value the title
    /// provenance gate (`foregroundProgramPID`) and name lookups resolve through.
    /// Callers comparing against `Pane.programTitlePID` (the title's pin) MUST use
    /// this, not `nsView.foregroundPID` (the raw client pid) — for a wrapped pane
    /// the two never match, which would expire every adopted OSC title on the
    /// next poll.
    @MainActor
    static func resolvedForegroundPID(forPane pane: Pane) -> pid_t? {
        foregroundPID(forPane: pane)
    }

    @MainActor
    private static func foregroundPID(forPane pane: Pane) -> pid_t? {
        // Remote panes (#104): the only local process is the ssh client — no
        // local pid ever describes what runs inside the pane. Every pane-level
        // API returns nil/false, so layout save emits a plain leaf, reconcile
        // matches the pane as idle, and titles come from the remote pipeline
        // (`RemoteForegroundResolver` / execution-gated OSC titles).
        guard !pane.isRemote else { return nil }
        if let resolved = ZmxForegroundResolver.foregroundPID(sessionName: pane.sessionName) {
            return resolved
        }
        // For a zmx-WRAPPED pane, libghostty's `foregroundPID` is the local
        // `zmx attach` CLIENT — never the real shell (that runs under the
        // daemon, reachable only by session name via the resolver above). If
        // the resolver hasn't populated the cache yet (the async-registration
        // race right after spawn/restore), returning the client pid would make
        // the tab read `zmx` and Save Layout capture the wrapper argv as a
        // `run:` command. Return nil instead: the pane reads as resolving
        // (falls back to the shell name, saves no run) until the cache catches
        // up. The client-pid fallback is only correct for UNWRAPPED panes
        // (zmx unbundled / over the socket-path budget).
        if pane.nsView?.isZmxWrapped == true { return nil }
        return pane.nsView?.foregroundPID
    }

    /// The command running in the pane's foreground, or nil if the pane is idle
    /// at a shell prompt, has no live surface, or the process can't be read.
    /// The string is the resolved argv joined with spaces (e.g.
    /// `node …/npm-cli.js run dev`), not necessarily what the user typed.
    @MainActor
    static func runningCommand(forPane pane: Pane) -> String? {
        guard let pid = foregroundPID(forPane: pane) else { return nil }
        guard let args = argv(pid: pid), !args.isEmpty else { return nil }
        // Idle at a prompt: the foreground process is the shell itself. Nothing
        // worth recording as a `run` command.
        if isShell(args[0]) { return nil }
        return displayCommand(args)
    }

    /// The display *name* of the pane's foreground process — the kernel's short
    /// accounting name (`hx`, `btop`, `nvim`), with no path and no arguments.
    /// Returns nil when the pane is idle at a shell prompt (the foreground
    /// process is the shell itself), so callers can fall back to a shell name.
    /// This is the tab name's default source: it's deterministic and immune to
    /// the shell's prompt-title churn (Starship & ghostty shell-integration
    /// emit cwd/prompt titles), unlike OSC 0/2. (A program-reported OSC title
    /// can override it for display — see `Pane.programTitle`.)
    ///
    /// This mirrors how tmux names a window under `automatic-rename` on macOS
    /// (`osdep-darwin.c`): it reads the foreground process group's `pbsi_comm`
    /// via `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)`, NOT argv. `comm` is already a
    /// basename truncated to `MAXCOMLEN` (15 chars), which is exactly the short
    /// name we want — no path, no flags, no argv parsing. (We keep the
    /// argv-based `runningCommand` for layout *save*, which wants the full
    /// command, not a display name.)
    /// We do NOT suppress shells here (unlike `runningCommand`, which returns nil
    /// at an idle prompt because there's no command to save). For a *display*
    /// name the foreground `comm` is always the right answer: an idle pane's
    /// foreground is its own shell, so its `comm` is that shell's name (`nu`);
    /// and a nested shell the user launched (`zsh` inside `nu`) shows `zsh`
    /// rather than collapsing back to the login shell. This is also more
    /// accurate than `Pane.defaultShellName` for a layout pane with a per-pane
    /// `shell:`. The shell-name fallback only applies when there's no foreground
    /// pid at all (surface not yet created).
    @MainActor
    static func runningProcessName(forPane pane: Pane) -> String? {
        guard let pid = foregroundPID(forPane: pane) else { return nil }
        guard var comm = comm(pid: pid), !comm.isEmpty else { return nil }
        // A login shell's comm may carry a leading `-` (e.g. `-zsh`).
        if comm.hasPrefix("-") { comm.removeFirst() }
        // Some programs overwrite `p_comm` via `setproctitle`/`process.title` —
        // Claude Code sets it to its bare version (`2.1.202`), which is useless
        // as a tab name. When `comm` is version-shaped, fall back to the
        // executable's basename (the real program name, e.g. `claude`), which
        // `p_comm` no longer reflects but `exec_path` still does.
        if looksLikeVersionString(comm), let exec = execPath(pid: pid) {
            let base = (exec as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return comm
    }

    /// The basename of the pane's foreground process's argv[0] (login-shell
    /// `-` stripped), or nil. Unlike `comm` — the *executable's* basename,
    /// which for some CLIs is an arch- or version-named binary — argv[0] is
    /// the name the process was invoked as (`claude`, `codex`). Used as the
    /// agent-icon fallback when `comm` doesn't identify an agent.
    @MainActor
    static func foregroundArgv0Basename(forPane pane: Pane) -> String? {
        guard let pid = foregroundPID(forPane: pane) else { return nil }
        guard var first = argv(pid: pid)?.first, !first.isEmpty else { return nil }
        if first.hasPrefix("-") { first.removeFirst() }
        return (first as NSString).lastPathComponent
    }

    /// Whether `value` is a bare dotted version number (e.g. `2.1.202`, `1.0`) —
    /// i.e. a `setproctitle`-clobbered `p_comm` rather than a real process name.
    /// Digits and dots only, at least one dot, digits at both ends.
    static func looksLikeVersionString(_ value: String) -> Bool {
        guard value.contains(".") else { return false }
        return value.allSatisfy { $0.isNumber || $0 == "." }
            && (value.first?.isNumber ?? false)
            && (value.last?.isNumber ?? false)
    }

    /// The pid of the pane's foreground process when it's a real program, or
    /// nil when the pane is idle at a shell prompt (or unreadable). This is
    /// the provenance gate for OSC titles: a title arriving while a program
    /// holds the foreground was set by that program; one arriving while the
    /// shell holds it is prompt churn (see `Pane.receiveReportedTitle`).
    @MainActor
    static func foregroundProgramPID(forPane pane: Pane) -> pid_t? {
        guard let pid = foregroundPID(forPane: pane) else { return nil }
        guard let args = argv(pid: pid), let first = args.first, !isShell(first) else { return nil }
        return pid
    }

    /// Whether the pane's foreground process is a shell. Prefer the process's
    /// executable/argv path over its display name; the shell set itself comes
    /// from the host (`getusershell`, login shell, `$SHELL`) rather than a
    /// Macterm-maintained list.
    @MainActor
    static func foregroundProcessIsShell(forPane pane: Pane) -> Bool {
        guard let pid = foregroundPID(forPane: pane) else { return false }
        return isIdleShellProcess(pid: pid)
    }

    static func isShellProcess(pid: pid_t) -> Bool {
        if let path = execPath(pid: pid), isShellProcessName(path) { return true }
        if let firstArg = argv(pid: pid)?.first, isShellProcessName(firstArg) { return true }
        if let name = comm(pid: pid), isShellProcessName(name) { return true }
        return false
    }

    /// Whether `pid` is a shell sitting at an interactive prompt. A shell that
    /// is executing a script (including a shebang script like
    /// `/tmp/spinner-test.sh`) or a `-c` command is foreground work, not idle.
    static func isIdleShellProcess(pid: pid_t) -> Bool {
        if let args = argv(pid: pid), let first = args.first, isShell(first) {
            return isIdleShellInvocation(args)
        }
        return isShellProcess(pid: pid)
    }

    static func isIdleShellInvocation(_ argv: [String]) -> Bool {
        guard let first = argv.first, isShell(first) else { return false }
        return !shellInvocationRunsCommand(argv)
    }

    private static func shellInvocationRunsCommand(_ argv: [String]) -> Bool {
        guard argv.count > 1 else { return false }
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" { return index + 1 < argv.count }
            if !arg.hasPrefix("-") || arg == "-" { return true }
            if arg == "-c" || (arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.dropFirst().contains("c")) {
                return true
            }
            index += shellOptionConsumesNextArgument(arg) ? 2 : 1
        }
        return false
    }

    private static func shellOptionConsumesNextArgument(_ option: String) -> Bool {
        option == "--rcfile" || option == "--init-file"
    }

    /// Whether the pane's tty is in raw/cbreak-style input mode. Full-screen and
    /// interactive CLIs (editors, ssh, agent TUIs) commonly disable canonical
    /// input and/or echo while they are idle at their own prompt. Plain shell
    /// commands like `sleep 20` leave the tty in canonical mode, so this lets the
    /// sidebar avoid treating every long-lived interactive foreground process as
    /// perpetual work without app-specific process-name exclusions.
    @MainActor
    static func terminalInputIsRaw(forPane pane: Pane) -> Bool {
        // For a zmx-wrapped pane, probe the DAEMON's pty: the `zmx attach`
        // client keeps the client-side pty raw permanently (it forwards
        // keystrokes), which would misread every wrapped pane as a raw-mode
        // TUI and break the status indicator's canonical-command detection.
        let daemonTTY = ZmxForegroundResolver.daemonTTYPath(sessionName: pane.sessionName)
        if daemonTTY == nil, pane.nsView?.isZmxWrapped == true {
            // A wrapped pane whose daemon tty isn't cached yet must NOT fall
            // back to the client-side tty: the zmx attach client keeps that
            // pty permanently raw, so the answer would flap raw/canonical
            // across cache refreshes — each flip republishes execution state
            // and re-renders, which is one edge of the frozen-render loop.
            return false
        }
        return terminalInputIsRaw(ttyPath: daemonTTY ?? pane.nsView?.ttyName)
    }

    static func terminalInputIsRaw(ttyPath: String?) -> Bool {
        guard let ttyPath else { return false }
        let fd = open(ttyPath, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var attrs = termios()
        guard tcgetattr(fd, &attrs) == 0 else { return false }
        let canonical = attrs.c_lflag & tcflag_t(ICANON) != 0
        let echo = attrs.c_lflag & tcflag_t(ECHO) != 0
        return !canonical || !echo
    }

    /// The current working directory of the pane's foreground process, read
    /// straight from the kernel (`proc_pidinfo(PROC_PIDVNODEPATHINFO)`), or nil.
    ///
    /// This is the OS-truth fallback for inheriting cwd on split: unlike
    /// `GhosttyTerminalNSView.currentPwd` (populated only when the shell emits
    /// OSC 7 via shell integration), it works even when the shell reports no
    /// cwd — a prompt without shell integration, nushell, or a non-shell
    /// program (`hx`, `nvim`) holding the foreground. We read the *foreground*
    /// pid's cwd, which is what the user sees as "where they are"; for a shell
    /// at a prompt that's the shell's cwd, and for a running program it's that
    /// program's cwd (typically launched from, and matching, the shell's).
    @MainActor
    static func foregroundWorkingDirectory(forPane pane: Pane) -> String? {
        guard let pid = foregroundPID(forPane: pane) else { return nil }
        return workingDirectory(pid: pid)
    }

    /// The current working directory of `pid` via `PROC_PIDVNODEPATHINFO`, or
    /// nil. Only same-uid processes are readable (the pane's foreground is).
    static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard ret == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String? in
            let bytes = raw.bindMemory(to: CChar.self)
            return bytes.baseAddress.map { String(cString: $0) }
        }
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    /// The kernel short accounting name (`p_comm` / `pbsi_comm`) of `pid` — a
    /// basename truncated to `MAXCOMLEN`, no path or arguments — or nil. Same
    /// field tmux uses for window names.
    static func comm(pid: pid_t) -> String? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        guard ret == size else { return nil }
        return withUnsafeBytes(of: &info.pbsi_comm) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            return bytes.baseAddress.map { String(cString: $0) }
        }
    }

    /// The absolute path to the pane's foreground shell when it's a *non-default*
    /// shell — i.e. one the user explicitly dropped into (e.g. `zsh` launched
    /// from `nu`) — else nil. Used by layout *save* to capture `shell:`, so
    /// reopening the layout lands back in that shell. Returns nil when:
    /// - the foreground isn't a shell (it's a command — see `runningCommand`),
    /// - the foreground IS the user's login shell (the idle default — saving it
    ///   would just bake the machine's login shell into every pane), or
    /// - the surface/process can't be read.
    /// Returns the kernel's `exec_path` (absolute, launchable), not `argv[0]`
    /// (which may be a bare `-zsh` login form).
    @MainActor
    static func runningShell(forPane pane: Pane) -> String? {
        guard let pid = foregroundPID(forPane: pane) else { return nil }
        guard let args = argv(pid: pid), let first = args.first, isShell(first) else { return nil }
        // Skip the user's default login shell — only a shell they switched to is
        // worth recording.
        let base = shellBasename(first)
        if base == loginShellBasename { return nil }
        // Prefer the absolute exec_path; fall back to argv[0] (login `-` stripped).
        if let path = execPath(pid: pid), !path.isEmpty { return path }
        return first.hasPrefix("-") ? String(first.dropFirst()) : first
    }

    /// Whether `name` names a shell according to the system user-shell database
    /// (`/etc/shells` via `getusershell`) plus the current login/environment
    /// shell. This keeps shell detection aligned with the host instead of a
    /// hardcoded list that inevitably misses user-installed shells.
    static func isShellProcessName(_ name: String?) -> Bool {
        guard let name else { return false }
        let basename = shellBasename(name)
        guard !basename.isEmpty else { return false }
        return knownShellBasenames.contains(basename)
    }

    /// Basename of a shell argv/path with a leading login-shell `-` stripped.
    private static func shellBasename(_ s: String) -> String {
        var name = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("-") { name.removeFirst() }
        return (name as NSString).lastPathComponent.lowercased()
    }

    /// Basename of the user's login shell (`getpwuid`), for distinguishing a
    /// deliberately-launched shell from the idle default.
    private static let loginShellBasename: String = {
        guard let loginShell = getpwuid(getuid())?.pointee.pw_shell.map({ String(cString: $0) }) else { return "" }
        return (loginShell as NSString).lastPathComponent.lowercased()
    }()

    /// The argument vector of `pid` (argv[0…argc-1]) via KERN_PROCARGS2, or nil.
    static func argv(pid: pid_t) -> [String]? {
        procArgs(pid: pid)?.argv
    }

    /// The kernel `exec_path` of `pid` (the executable path stored ahead of
    /// argv in KERN_PROCARGS2) — an absolute path — or nil.
    static func execPath(pid: pid_t) -> String? {
        procArgs(pid: pid)?.execPath
    }

    /// Structured KERN_PROCARGS2 parse.
    ///
    /// Layout: `[int32 argc][exec_path\0][\0 padding][argv0\0 argv1\0 …][env…]`.
    /// We parse POSITIONALLY — read `exec_path`, skip its NUL padding, then take
    /// exactly `argc` NUL-terminated fields as argv. Crucially we do NOT use
    /// `split(omittingEmptySubsequences:)` (which would drop a legitimately
    /// empty argv element, sliding an env var into the argv window) and we
    /// decode losslessly with `String(decoding:as:)` (a non-UTF-8 argument
    /// yields replacement chars but keeps the field count correct — never
    /// dropped, which would also shift the window).
    private static func procArgs(pid: pid_t) -> (execPath: String, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let ok = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0) == 0
        }
        guard ok, size > MemoryLayout<Int32>.size else { return nil }
        buffer.removeLast(buffer.count - size)

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        // Cursor over the bytes after the argc int.
        var i = MemoryLayout<Int32>.size
        let end = buffer.count

        // exec_path: bytes up to the first NUL.
        let execStart = i
        while i < end, buffer[i] != 0 {
            i += 1
        }
        guard i < end else { return nil } // no terminator → malformed
        let execPath = String(decoding: buffer[execStart ..< i], as: UTF8.self)
        i += 1 // consume the exec_path terminator

        // Skip the NUL padding between exec_path and argv0.
        while i < end, buffer[i] == 0 {
            i += 1
        }

        // Take exactly argc NUL-terminated fields, preserving empty ones.
        var argv: [String] = []
        argv.reserveCapacity(Int(argc))
        for _ in 0 ..< Int(argc) {
            guard i < end else { break }
            let fieldStart = i
            while i < end, buffer[i] != 0 {
                i += 1
            }
            argv.append(String(decoding: buffer[fieldStart ..< i], as: UTF8.self))
            i += 1 // consume the field terminator (past `end` is harmless)
        }
        guard argv.count == Int(argc) else { return nil }
        return (execPath, argv)
    }

    /// Whether `argv0` names a shell (so a foreground process matching it is an
    /// idle prompt, not a command worth capturing). Matches the basename with a
    /// leading login-shell `-` stripped.
    private static func isShell(_ argv0: String) -> Bool {
        isShellProcessName(argv0)
    }

    private static let knownShellBasenames: Set<String> = {
        var shells = Set<String>()
        setusershell()
        while let ptr = getusershell() {
            let basename = shellBasename(String(cString: ptr))
            if !basename.isEmpty { shells.insert(basename) }
        }
        endusershell()

        if !loginShellBasename.isEmpty { shells.insert(loginShellBasename) }
        if let envShell = ProcessInfo.processInfo.environment["SHELL"] {
            let basename = shellBasename(envShell)
            if !basename.isEmpty { shells.insert(basename) }
        }
        return shells
    }()

    /// Join argv into a display command, stripping a leading login-shell `-`.
    private static func displayCommand(_ argv: [String]) -> String? {
        var args = argv
        if let first = args.first, first.hasPrefix("-") {
            args[0] = String(first.dropFirst())
        }
        let joined = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }
}
