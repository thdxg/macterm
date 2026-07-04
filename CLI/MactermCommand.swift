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
        subcommands: [Status.self, ProjectCommand.self, TabCommand.self, PaneCommand.self, SessionCommand.self]
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

// MARK: - Subcommands

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether Macterm is running and which project is active."
    )

    @OptionGroup var options: ConnectionOptions

    func run() throws {
        try runControlCommand(command: "status", options: options)
    }
}

struct ProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "List and inspect projects.",
        subcommands: [List.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all projects.")

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "project.list", options: options)
        }
    }
}

struct TabCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "List and inspect tabs.",
        subcommands: [List.self],
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
}

struct PaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "List and inspect panes.",
        subcommands: [List.self],
        defaultSubcommand: List.self
    )

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
}

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Inspect zmx-backed terminal sessions.",
        subcommands: [List.self, Info.self],
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
}
