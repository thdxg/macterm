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
    /// The command running in the pane's foreground, or nil if the pane is idle
    /// at a shell prompt, has no live surface, or the process can't be read.
    /// The string is the resolved argv joined with spaces (e.g.
    /// `node …/npm-cli.js run dev`), not necessarily what the user typed.
    @MainActor
    static func runningCommand(forPane pane: Pane) -> String? {
        guard let pid = pane.nsView?.foregroundPID else { return nil }
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
    /// This is the source of truth for the tab name: it's deterministic and
    /// immune to the shell's prompt-title churn (Starship & ghostty
    /// shell-integration emit cwd/prompt titles that overwrite a command's OSC
    /// title), unlike OSC-2.
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
        guard let pid = pane.nsView?.foregroundPID else { return nil }
        guard var comm = comm(pid: pid), !comm.isEmpty else { return nil }
        // A login shell's comm may carry a leading `-` (e.g. `-zsh`).
        if comm.hasPrefix("-") { comm.removeFirst() }
        return comm
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
        guard let pid = pane.nsView?.foregroundPID else { return nil }
        guard let args = argv(pid: pid), let first = args.first, isShell(first) else { return nil }
        // Skip the user's default login shell — only a shell they switched to is
        // worth recording.
        let base = shellBasename(first)
        if base == loginShellBasename { return nil }
        // Prefer the absolute exec_path; fall back to argv[0] (login `-` stripped).
        if let path = execPath(pid: pid), !path.isEmpty { return path }
        return first.hasPrefix("-") ? String(first.dropFirst()) : first
    }

    /// Basename of a shell argv/path with a leading login-shell `-` stripped.
    private static func shellBasename(_ s: String) -> String {
        var name = s
        if name.hasPrefix("-") { name.removeFirst() }
        return (name as NSString).lastPathComponent
    }

    /// Basename of the user's login shell (`getpwuid`), for distinguishing a
    /// deliberately-launched shell from the idle default.
    private static let loginShellBasename: String = {
        guard let loginShell = getpwuid(getuid())?.pointee.pw_shell.map({ String(cString: $0) }) else { return "" }
        return (loginShell as NSString).lastPathComponent
    }()

    /// The argument vector of `pid` (argv[0…argc-1]) via KERN_PROCARGS2, or nil.
    static func argv(pid: pid_t) -> [String]? {
        guard let tokens = procArgsTokens(pid: pid) else { return nil }
        let (argc, args) = tokens
        // args[0] is exec_path; argv follows.
        guard args.count >= argc + 1 else { return nil }
        return Array(args[1 ..< (1 + argc)])
    }

    /// The kernel `exec_path` of `pid` (the first NUL-delimited token after argc
    /// in KERN_PROCARGS2) — an absolute path to the executable — or nil.
    static func execPath(pid: pid_t) -> String? {
        guard let (_, args) = procArgsTokens(pid: pid), let path = args.first else { return nil }
        return path
    }

    /// Raw KERN_PROCARGS2 read: `(argc, [exec_path, argv0, argv1, …, env…])`.
    /// Layout: `[int32 argc][exec_path\0][\0 padding][argv0\0…][env…]`.
    private static func procArgsTokens(pid: pid_t) -> (argc: Int, tokens: [String])? {
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

        let rest = buffer[MemoryLayout<Int32>.size...]
        let tokens = rest.split(separator: 0, omittingEmptySubsequences: true).compactMap {
            String(bytes: $0, encoding: .utf8)
        }
        return (Int(argc), tokens)
    }

    /// Whether `argv0` names a shell (so a foreground process matching it is an
    /// idle prompt, not a command worth capturing). Matches the basename with a
    /// leading login-shell `-` stripped.
    private static func isShell(_ argv0: String) -> Bool {
        knownShells.contains(shellBasename(argv0))
    }

    private static let knownShells: Set<String> = [
        "sh", "bash", "zsh", "fish", "nu", "dash", "ksh", "tcsh", "csh", "ash", "xonsh", "elvish",
    ]

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
