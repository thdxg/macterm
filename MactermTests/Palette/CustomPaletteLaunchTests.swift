import Foundation
@testable import Macterm
import Testing

/// How a palette `run:` starts before the pane's shell (`CustomPaletteLaunch`):
/// the arguments the surface puts in front of the resolved command, and the
/// runner reading them back.
struct CustomPaletteLaunchTests {
    @Test
    func every_shell_is_started_interactive_and_login_unless_it_spells_that_its_own_way() {
        for shell in [
            "/bin/zsh",
            "/bin/bash",
            "/opt/homebrew/bin/fish",
            "/opt/homebrew/bin/nu",
            "/usr/local/bin/xonsh",
            "/bin/ksh",
            "/bin/dash",
        ] {
            #expect(CustomPaletteLaunch.flags(forShell: shell) == ["-i", "-l", "-c"], "\(shell)")
        }
        #expect(CustomPaletteLaunch.flags(forShell: "/bin/tcsh") == ["-c"])
        #expect(CustomPaletteLaunch.flags(forShell: "/bin/csh") == ["-c"])
        #expect(CustomPaletteLaunch.flags(forShell: "/opt/homebrew/bin/elvish") == ["-c"])
        #expect(CustomPaletteLaunch.flags(forShell: "/usr/local/bin/pwsh") == ["-Login", "-Interactive", "-Command"])
    }

    /// A listing's login shell: no interactive flag, and plain `-c` for the
    /// shells that refuse `-l` beside it.
    @Test
    func a_listing_starts_its_shell_as_a_login_shell_where_it_can() {
        #expect(CustomPaletteLaunch.loginFlags(forShell: "/bin/zsh") == ["-l", "-c"])
        #expect(CustomPaletteLaunch.loginFlags(forShell: "/opt/homebrew/bin/nu") == ["-l", "-c"])
        #expect(CustomPaletteLaunch.loginFlags(forShell: "/bin/tcsh") == ["-c"])
        #expect(CustomPaletteLaunch.loginFlags(forShell: "/opt/homebrew/bin/elvish") == ["-c"])
        #expect(CustomPaletteLaunch.loginFlags(forShell: "/usr/local/bin/pwsh") == ["-Login", "-Command"])
    }

    @Test
    func the_runner_reads_back_the_shell_it_was_given_and_the_argv_ghostty_appended() throws {
        let wrapper = CustomPaletteLaunch.wrapperArgv(cli: "/App/bin/macterm", shell: "/opt/homebrew/bin/nu")
        #expect(wrapper == ["/App/bin/macterm", "palette", "exec", "/opt/homebrew/bin/nu", "-i", "-l", "-c", "--"])

        // What the runner's own arguments are once ghostty has appended the
        // resolved launch: everything after `palette exec`.
        let resolved = ["/usr/bin/login", "-flp", "me", "/bin/bash", "--noprofile", "--norc", "-c", "exec -l /opt/homebrew/bin/nu"]
        let launch = try #require(CustomPaletteLaunch.parse(Array(wrapper.dropFirst(3)) + resolved))
        #expect(launch.shell == ["/opt/homebrew/bin/nu", "-i", "-l", "-c"])
        #expect(launch.exec == resolved, "the resolved launch is exec'd untouched, its own -- included")

        let withSeparatorInside = ["/bin/zsh", "-i", "-l", "-c", "--", "/bin/sh", "-c", "echo", "--", "x"]
        #expect(CustomPaletteLaunch.parse(withSeparatorInside)?.exec == ["/bin/sh", "-c", "echo", "--", "x"])

        #expect(CustomPaletteLaunch.parse(["/bin/zsh", "-c"]) == nil, "no separator")
        #expect(CustomPaletteLaunch.parse(["--", "/bin/zsh"]) == nil, "no shell")
        #expect(CustomPaletteLaunch.parse(["/bin/zsh", "--"]) == nil, "nothing to exec")
    }
}
