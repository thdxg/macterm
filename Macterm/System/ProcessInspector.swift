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

    /// The argument vector of `pid` (argv[0…argc-1]) via KERN_PROCARGS2, or nil.
    static func argv(pid: pid_t) -> [String]? {
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

        // Layout: [int32 argc][exec_path\0][\0 padding][argv0\0…argv(argc-1)\0][env…].
        // Split on NUL, drop empties; the first token is exec_path, then argv.
        let rest = buffer[MemoryLayout<Int32>.size...]
        let tokens = rest.split(separator: 0, omittingEmptySubsequences: true).compactMap {
            String(bytes: $0, encoding: .utf8)
        }
        guard tokens.count >= Int(argc) + 1 else { return nil }
        return Array(tokens[1 ..< (1 + Int(argc))])
    }

    /// Whether `argv0` names a shell (so a foreground process matching it is an
    /// idle prompt, not a command worth capturing). Matches the basename with a
    /// leading login-shell `-` stripped.
    private static func isShell(_ argv0: String) -> Bool {
        var name = argv0
        if name.hasPrefix("-") { name.removeFirst() }
        let base = (name as NSString).lastPathComponent
        return knownShells.contains(base)
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
