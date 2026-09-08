import ArgumentParser
import Foundation

/// `macterm tutor [topic]` — print a short tutorial as terminal output. Seeded
/// into a fresh install's panes as their `run:` (see `FirstRunSeed`), and
/// re-runnable by hand afterwards.
///
/// Deliberately NOT offline like `macterm ssh`: the text is rendered by the
/// app (`Tutorial`) because its shortcut columns come from the user's live
/// keybindings, overrides included. A copy of the default table over here
/// would print `⌘T` at someone who rebound it.
///
/// It runs at app launch by construction, so it tolerates the one race that
/// implies: the control socket answers `starting` until `AppState` attaches
/// its handler, and a tutorial that printed that error into the pane it was
/// meant to teach in would be worse than a beat of latency.
struct TutorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tutor",
        abstract: "Print a short tutorial (uses your current keybindings).",
        discussion: """
        Topics: project (projects, tabs, splits, the CLI) and pinned (what \
        the pinned row above the projects is for). Defaults to project.
        """
    )

    @Argument(help: "Tutorial topic: project or pinned.")
    var topic: String = "project"

    @OptionGroup var options: ConnectionOptions

    /// How long to keep retrying a `starting` app before giving up. Generous
    /// because losing the race costs the user their tutorial, and cheap
    /// because a running app answers on the first try.
    private static let startingRetries = 20
    private static let startingRetryDelay: TimeInterval = 0.25

    func run() throws {
        let args = ControlArgs(
            // The app renders the text; only we can see whether it is going
            // to a terminal, so the styling verdict travels with the request.
            topic: topic,
            styled: isatty(STDOUT_FILENO) == 1
        )
        let client = ControlClient(socketOverride: options.socket)
        var attempt = 0
        while true {
            let response: ControlResponse
            do {
                response = try client.send(command: "tutor.render", args: args)
            } catch let error as ControlClient.ClientError {
                Output.printError(error.description)
                throw ExitCode(error.isConnectionFailure ? 2 : 1)
            }
            if response.ok {
                try Output.render(response.data, asJSON: options.json)
                return
            }
            let error = response.error ?? ControlError(code: .internalError, message: "unknown error")
            guard error.code == .starting, attempt < Self.startingRetries else {
                Output.printError(error.message, action: error.action)
                throw ExitCode(1)
            }
            attempt += 1
            Thread.sleep(forTimeInterval: Self.startingRetryDelay)
        }
    }
}
