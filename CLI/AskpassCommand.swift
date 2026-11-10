import ArgumentParser
import Foundation

/// `macterm askpass <prompt>`: the `SSH_ASKPASS` of a host's ssh master
/// (design/005 step 2), through the `macterm-askpass` shim in
/// `Contents/Resources/ssh-bridge`. It sends ssh's prompt to the app that
/// started that ssh (`MACTERM_ASKPASS_SOCKET`) and prints the answer for ssh.
/// The app answers only when this process's parent is one of its ssh
/// masters. Exit 1: cancelled or refused, and ssh stops the login.
struct AskpassCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "askpass",
        abstract: "Ask Macterm what an ssh login asks. ssh runs it; you do not.",
        shouldDisplay: false
    )

    @Argument(help: "The prompt that ssh gives.")
    var prompt: String = ""

    /// A user's answer can take a while; the login's own limit is the
    /// server's LoginGraceTime.
    static let answerTimeout = 600

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["SSH_ASKPASS_PROMPT"]
        // "none" is a notice that ssh ends itself (a security key to touch).
        // There is nothing to answer.
        if mode == "none" { return }
        guard let socket = environment["MACTERM_ASKPASS_SOCKET"], !socket.isEmpty else {
            Output.printError("macterm askpass runs only for an ssh that Macterm started")
            throw ExitCode(1)
        }
        var args = ControlArgs()
        args.prompt = prompt
        args.confirm = mode == "confirm" ? true : nil
        let client = ControlClient(socketOverride: socket, readTimeout: Self.answerTimeout)
        let response: ControlResponse
        do {
            response = try client.send(command: "ssh.askpass", args: args)
        } catch let error as ControlClient.ClientError {
            Output.printError(error.description)
            throw ExitCode(1)
        }
        guard response.ok, let answer = response.data?.askpass?.answer else {
            if let error = response.error { Output.printError(error.message) }
            throw ExitCode(1)
        }
        if mode != "confirm" { print(answer) }
    }
}

#if DEBUG
/// DEBUG-only: open or end a host's one ssh connection (`SSHConnections`),
/// and reach its server (`RemoteServers`), so that the login sheet and the
/// install's consent sheet can be seen before remote projects use them.
struct HostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "[debug] Open or end a host's ssh connection, or reach its server.",
        subcommands: [Connect.self, Server.self, Disconnect.self]
    )

    struct Connect: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "[debug] Log in to a host, or reuse its connection.")

        @Argument(help: "The ssh destination: [user@]host.")
        var host: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs()
            args.host = host
            try runControlCommand(command: "host.connect", args: args, options: options, readTimeout: AskpassCommand.answerTimeout)
        }
    }

    struct Server: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "[debug] Connect to a host's Macterm server. Install it first when it is not there."
        )

        @Argument(help: "The ssh destination: [user@]host.")
        var host: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs()
            args.host = host
            try runControlCommand(command: "host.server", args: args, options: options, readTimeout: AskpassCommand.answerTimeout)
        }
    }

    struct Disconnect: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "[debug] End Macterm's ssh connection to a host.")

        @Argument(help: "The ssh destination: [user@]host.")
        var host: String

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            var args = ControlArgs()
            args.host = host
            try runControlCommand(command: "host.disconnect", args: args, options: options)
        }
    }
}
#endif
