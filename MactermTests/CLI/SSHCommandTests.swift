import Foundation
import Testing

/// `macterm ssh` captures ssh's arguments with `.captureForPassthrough`, so it
/// answers a leading help flag itself, like `pane run`. The shell-integration
/// relay must not notice: it calls `ghostty +ssh <flags> -- "$@"` (the bundled
/// shim hands that to `macterm ssh` unchanged), so its capture starts with `--`
/// and a help flag the user gave still reaches ssh. `/bin/echo` stands in for
/// ssh, printing the arguments it was handed.
struct SSHCommandTests {
    @Test
    func a_leading_help_flag_prints_help() throws {
        let help = try BundledCLI.run(["help", "ssh"])
        #expect(help.status == 0)
        for arguments in [["ssh", "--help"], ["ssh", "-h"], ["ssh", "--verbose", "--help"]] {
            let result = try BundledCLI.run(arguments)
            let invocation = "macterm " + arguments.joined(separator: " ")
            #expect(result.status == 0, "`\(invocation)` exited \(result.status): \(result.stderr)")
            #expect(result.stdout == help.stdout, "`\(invocation)` did not print `macterm help ssh`")
        }
    }

    @Test
    func help_flags_the_relay_passes_reach_ssh() throws {
        let viaEcho = ["ssh", "--forward-env=false", "--terminfo=false", "--ssh", "/bin/echo"]
        let relayed = try BundledCLI.run(viaEcho + ["--", "--help"])
        #expect(relayed.status == 0)
        #expect(relayed.stdout == "-- --help\n")
        let afterDestination = try BundledCLI.run(viaEcho + ["user@example.com", "-h"])
        #expect(afterDestination.status == 0)
        #expect(afterDestination.stdout == "user@example.com -h\n")
    }
}
