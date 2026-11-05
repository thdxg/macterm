@testable import Macterm
import Testing

/// The extractor reads the screen once the shell has printed its next
/// prompt, so every screen here ends on that prompt.
struct CommandRecordExtractorTests {
    private let extractor = ScreenCommandExtractor()

    @Test
    func bash_prompt() throws {
        let screen = """
        me@mac:~/app$ make test
        compiling
        error: 2 tests failed
        me@mac:~/app$
        """
        let result = try #require(extractor.extract(screen: screen))
        #expect(result.command == "make test")
        #expect(result.output == "compiling\nerror: 2 tests failed")
        #expect(!result.isPrivate)
    }

    @Test
    func zsh_percent_prompt() throws {
        let screen = """
        app % npm run build
        built in 2s
        app %
        """
        let result = try #require(extractor.extract(screen: screen))
        #expect(result.command == "npm run build")
        #expect(result.output == "built in 2s")
    }

    @Test
    func starship_two_line_prompt() throws {
        let screen = """
        ~/dev/app on main
        ❯ cargo test
        test result: FAILED
        ~/dev/app on main
        ❯
        """
        let result = try #require(extractor.extract(screen: screen))
        #expect(result.command == "cargo test")
        #expect(result.output == "test result: FAILED")
    }

    @Test
    func nushell_prompt() throws {
        let screen = """
        ~/dev/app> ls | length
        12
        ~/dev/app>
        """
        let result = try #require(extractor.extract(screen: screen))
        #expect(result.command == "ls | length")
        #expect(result.output == "12")
    }

    @Test
    func a_command_with_no_output() throws {
        let screen = """
        app % touch notes.md
        app %
        """
        let result = try #require(extractor.extract(screen: screen))
        #expect(result.command == "touch notes.md")
        #expect(result.output.isEmpty)
    }

    @Test
    func a_cleared_screen_has_no_command() {
        #expect(extractor.extract(screen: "app %") == nil)
    }

    @Test
    func a_screen_with_no_prompt_mark_has_no_command() {
        #expect(extractor.extract(screen: "just some output\nmore output") == nil)
    }

    @Test
    func a_leading_space_marks_the_command_private() throws {
        let screen = """
        app %  export TOKEN=abc
        app %
        """
        let result = try #require(extractor.extract(screen: screen))
        #expect(result.command == "export TOKEN=abc")
        #expect(result.isPrivate)
    }
}
