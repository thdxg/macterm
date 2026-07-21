import ArgumentParser
import Foundation

/// `macterm` — control a running Macterm app from the shell.
///
/// Talks to the app over its Unix control socket (see `ControlProtocol`).
/// Exit codes: 0 success, 1 the app returned an error, 2 the app couldn't
/// be reached. stdout carries only successful output.
@main
struct MactermCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macterm",
        abstract: "Control a running Macterm: projects, tabs, panes, zmx sessions.",
        subcommands: [
            Status.self,
            ProjectCommand.self,
            TabCommand.self,
            PaneCommand.self,
            Grid.self,
            SessionCommand.self,
            LayoutCommand.self,
        ]
    )
}

/// Options every subcommand shares.
struct ConnectionOptions: ParsableArguments {
    @Option(help: "Control socket path (overrides discovery).")
    var socket: String?

    @Flag(help: "Print the raw JSON payload instead of a table.")
    var json = false
}

/// Send a request, apply the safe-fail contract, render the result.
func runControlCommand(command: String, args: ControlArgs? = nil, options: ConnectionOptions) throws {
    let client = ControlClient(socketOverride: options.socket)
    let response: ControlResponse
    do {
        response = try client.send(command: command, args: args)
    } catch let error as ControlClient.ClientError {
        Output.printError(error.description)
        throw ExitCode(error.isConnectionFailure ? 2 : 1)
    }
    if response.ok {
        try Output.render(response.data, asJSON: options.json)
        return
    }
    let error = response.error ?? ControlError(code: .internalError, message: "unknown error")
    Output.printError(error.message, action: error.action)
    throw ExitCode(1)
}

/// The pane self-address the app injects into every pane's shell. Used as the
/// implicit target when a pane verb names no explicit one (Zentty-style
/// "current pane" context) — explicit selectors always win.
func sessionFromEnvironment() -> String? {
    let value = ProcessInfo.processInfo.environment[ControlProtocol.sessionEnvVar]
    return (value?.isEmpty ?? true) ? nil : value
}

/// Shared pane-target options: `--session`/`--pane` are explicit; inside a
/// Macterm pane, `MACTERM_SESSION` fills in when neither is given (nor a tab
/// scope — an explicit tab means "that tab's focused pane", not self).
struct PaneTarget: ParsableArguments {
    @Option(help: "Project scope (name, UUID, or index). Defaults to the active project.")
    var project: String?

    @Option(help: "Tab scope (title, UUID, or index).")
    var tab: String?

    @Option(help: "Target pane by UUID, or index within the tab (pane:2).")
    var pane: String?

    @Option(help: "Target pane by zmx session name (restart-stable).")
    var session: String?

    func controlArgs() -> ControlArgs {
        ControlArgs(
            project: project,
            tab: tab,
            pane: pane,
            session: session ?? (pane == nil && tab == nil ? sessionFromEnvironment() : nil)
        )
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether Macterm is running and which project is active."
    )

    @OptionGroup var options: ConnectionOptions

    func run() throws {
        try runControlCommand(command: "status", options: options)
    }
}

// MARK: - Project

struct ProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "List, create, and select projects.",
        subcommands: [List.self, Create.self, Select.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all projects.")

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "project.list", options: options)
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a project for a local directory (idempotent by path)."
        )

        @Argument(help: "Project directory (absolute or ~-prefixed).")
        var path: String

        @Option(help: "Display name. Defaults to the directory name.")
        var name: String?

        @Flag(help: "Also select it (applies a matching project file's layout on first open).")
        var select = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "project.create",
                args: ControlArgs(path: path, name: name, select: select),
                options: options
            )
        }
    }

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make a project active.")

        @Argument(help: "Project name, UUID, or index.")
        var project: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "project.select", args: ControlArgs(project: project), options: options)
        }
    }
}

// MARK: - Tab

struct TabCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "List, create, select, and close tabs.",
        subcommands: [List.self, New.self, Select.self, Close.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tabs (active project by default).")

        @Option(help: "Project to list (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "tab.list", args: ControlArgs(project: project), options: options)
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a new tab (becomes active).")

        @Option(help: "Project (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @Option(name: .customLong("run"), help: "Command to run in the new tab's shell.")
        var runCommand: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "tab.new",
                args: ControlArgs(project: project, run: runCommand),
                options: options
            )
        }
    }

    struct Select: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Activate a tab.")

        @Argument(help: "Tab title, UUID, or index (tab:3).")
        var tab: String

        @Option(help: "Project scope. Defaults to the active project.")
        var project: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "tab.select",
                args: ControlArgs(project: project, tab: tab),
                options: options
            )
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a tab (kills its panes' zmx sessions)."
        )

        @Argument(help: "Tab title, UUID, or index (tab:3).")
        var tab: String

        @Option(help: "Project scope. Defaults to the active project.")
        var project: String?

        @Flag(help: "Close even if a pane has a running program.")
        var force = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "tab.close",
                args: ControlArgs(project: project, tab: tab, force: force),
                options: options
            )
        }
    }
}

// MARK: - Pane

struct PaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "List, inspect, split, focus, close panes, and run commands in them.",
        subcommands: paneSubcommands,
        defaultSubcommand: List.self
    )

    /// Assembled once so the debug-only `resize` verb is present in debug
    /// builds of the CLI and absent in release. (The app also gates the
    /// server-side handler behind `#if DEBUG`, which is the authoritative
    /// boundary; this just hides the verb from `--help` in release.)
    private static var paneSubcommands: [ParsableCommand.Type] {
        var subs: [ParsableCommand.Type] = [
            List.self, Inspect.self, Dump.self, Split.self, Focus.self,
            Close.self, Run.self, Key.self, Zoom.self, ResizeSplit.self,
        ]
        #if DEBUG
        subs.append(Resize.self)
        #endif
        return subs
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List panes (active project by default).")

        @Option(help: "Project to list (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @Option(help: "Restrict to one tab (title, UUID, or index).")
        var tab: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "pane.list",
                args: ControlArgs(project: project, tab: tab),
                options: options
            )
        }
    }

    struct Split: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Split a pane. Defaults to the focused pane (or the pane you're in)."
        )

        @Option(help: "right, down, or auto (longer on-screen axis).")
        var direction: String = "auto"

        @Option(name: .customLong("run"), help: "Command to run in the new pane's shell.")
        var runCommand: String?

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.direction = direction
            args.run = runCommand
            try runControlCommand(command: "pane.split", args: args, options: options)
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Focus a pane (selects its tab and fronts the window)."
        )

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "pane.focus", args: target.controlArgs(), options: options)
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a pane (kills its zmx session)."
        )

        @OptionGroup var target: PaneTarget

        @Flag(help: "Close even if a program is running.")
        var force = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs(
                project: target.project,
                tab: target.tab,
                pane: target.pane,
                // Deliberately NOT defaulted from MACTERM_SESSION: closing
                // "whatever pane I'm in" because no target was given is a
                // destructive surprise. Explicit targets only.
                session: target.session
            )
            args.force = force
            guard args.pane != nil || args.session != nil else {
                Output.printError(
                    "pane close requires --pane or --session",
                    action: "run `macterm pane list` for targets"
                )
                throw ExitCode(1)
            }
            try runControlCommand(command: "pane.close", args: args, options: options)
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Type a command into a live pane's shell (adds a newline)."
        )

        @Argument(parsing: .captureForPassthrough, help: "The command line to run.")
        var command: [String]

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            let line = command.joined(separator: " ")
            guard !line.isEmpty else {
                Output.printError("nothing to run")
                throw ExitCode(1)
            }
            var args = target.controlArgs()
            args.run = line
            try runControlCommand(command: "pane.run", args: args, options: options)
        }
    }

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a key chord to a live pane (control/named keys, not text).",
            discussion: """
            Delivers a single key press through the terminal's key-encoding path \
            — the counterpart to `pane run`, which pastes text. Use it for control \
            keys and named keys that have no literal text form.

            The chord grammar matches keybinds: modifiers ctrl/cmd/shift/opt joined \
            with '+', then one key token. Examples:

              macterm pane key ctrl+c          # interrupt the foreground process
              macterm pane key escape          # send Esc to a TUI
              macterm pane key up              # arrow key (mode-aware encoding)
              macterm pane key 'ctrl+\\'        # SIGQUIT char (quote for the shell)
              macterm pane key enter           # submit (alias of 'return')

            With no pane/tab/session selector it targets the current pane via \
            $MACTERM_SESSION.
            """
        )

        @Argument(help: "The key chord, e.g. ctrl+c, escape, up, ctrl+\\.")
        var chord: String

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.key = chord
            try runControlCommand(command: "pane.key", args: args, options: options)
        }
    }

    struct Inspect: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report a pane's live terminal-core state (grid, scrollback, foreground process)."
        )

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "pane.inspect", args: target.controlArgs(), options: options)
        }
    }

    struct Dump: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a pane's terminal text: the viewport, or the full scrollback with --scrollback."
        )

        @Flag(help: "Include the full scrollback, not just the visible viewport.")
        var scrollback = false

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.scrollback = scrollback
            try runControlCommand(command: "pane.dump", args: args, options: options)
        }
    }

    struct Zoom: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Toggle zoom on a pane (the tab renders only that pane while zoomed)."
        )

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "pane.zoom", args: target.controlArgs(), options: options)
        }
    }

    struct ResizeSplit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resize-split",
            abstract: "Set the ratio of the nearest split around a pane (0.15–0.85)."
        )

        @Option(help: "Split axis to resize: horizontal or vertical.")
        var axis: String

        @Option(help: "Absolute ratio for the split's first child (0.15–0.85).")
        var ratio: Double

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.axis = axis
            args.ratio = ratio
            try runControlCommand(command: "pane.resize-split", args: args, options: options)
        }
    }

    #if DEBUG
    /// DEBUG-only: isolated in-place surface resize for reflow debugging (#167).
    /// Absent from release CLIs; a release app also rejects `pane.resize`.
    struct Resize: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "[debug] Resize a pane's surface in place to COLS×ROWS, bypassing layout."
        )

        @Option(help: "Target columns.")
        var cols: Int

        @Option(help: "Target rows.")
        var rows: Int

        @OptionGroup var target: PaneTarget
        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = target.controlArgs()
            args.cols = cols
            args.rows = rows
            try runControlCommand(command: "pane.resize", args: args, options: options)
        }
    }
    #endif
}

// MARK: - Grid

struct Grid: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Split a pane into an equal ROWSxCOLS grid."
    )

    @Argument(help: "Grid shape, e.g. 2x2 or 3x1.")
    var shape: String

    @Option(name: .customLong("run"), help: "Command to run in each NEW pane (the source pane keeps its shell).")
    var runCommand: String?

    @OptionGroup var target: PaneTarget
    @OptionGroup var options: ConnectionOptions

    func run() throws {
        let parts = shape.lowercased().split(separator: "x")
        guard parts.count == 2, let rows = Int(parts[0]), let cols = Int(parts[1]) else {
            Output.printError("grid shape must look like 2x2")
            throw ExitCode(1)
        }
        var args = target.controlArgs()
        args.rows = rows
        args.cols = cols
        args.run = runCommand
        try runControlCommand(command: "grid", args: args, options: options)
    }
}

// MARK: - Session

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Inspect and kill zmx-backed terminal sessions.",
        subcommands: [List.self, Info.self, Kill.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List live zmx sessions.")

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "session.list", options: options)
        }
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one zmx session.")

        @Argument(help: "Session name (macterm-<slug>-<hex>).")
        var name: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "session.info", args: ControlArgs(session: name), options: options)
        }
    }

    struct Kill: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Kill a zmx session (its shell dies; an attached pane's shell exits)."
        )

        @Argument(help: "Session name (macterm-<slug>-<hex>).")
        var name: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "session.kill", args: ControlArgs(session: name), options: options)
        }
    }
}

// MARK: - Layout

struct LayoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        abstract: "Apply or save a project's declarative layout file.",
        subcommands: [Apply.self, Save.self]
    )

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reconcile the workspace to the project's central layout file."
        )

        @Option(help: "Project (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @Flag(help: "Apply even when it would close panes.")
        var force = false

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(
                command: "layout.apply",
                args: ControlArgs(project: project, force: force),
                options: options
            )
        }
    }

    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save the live workspace as the project's layout file."
        )

        @Option(help: "Project (name, UUID, or index). Defaults to the active project.")
        var project: String?

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "layout.save", args: ControlArgs(project: project), options: options)
        }
    }
}
