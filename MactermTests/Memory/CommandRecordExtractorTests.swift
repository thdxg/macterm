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
    func the_typed_line_ends_at_the_cursor() throws {
        // A right prompt past a gap, and an autosuggestion right after the
        // cursor: neither is the command.
        let rightPrompt = "~/app> cargo test                       11:23:45 AM"
        let typed = try #require(ScreenCommandExtractor.typedCommand(onScreen: rightPrompt, cursorColumn: 17, columns: 80))
        #expect(typed.command == "cargo test")
        let ghost = "❯ make test --verbose"
        let accepted = try #require(ScreenCommandExtractor.typedCommand(onScreen: ghost, cursorColumn: 11, columns: 80))
        #expect(accepted.command == "make test")
        // Without a cursor, the whole line.
        #expect(ScreenCommandExtractor.typedCommand(onScreen: ghost)?.command == "make test --verbose")
    }

    @Test
    func a_wrapped_line_offsets_the_cursor_by_the_rows_above() throws {
        // 20 columns: the prompt and command wrap onto a second row, where
        // the cursor sits at column 8, after `build`.
        let line = "$ rm -rf dist && cp -r build   right"
        let typed = try #require(ScreenCommandExtractor.typedCommand(onScreen: line, cursorColumn: 8, columns: 20))
        #expect(typed.command == "rm -rf dist && cp -r build")
    }

    @Test
    func a_cursor_in_the_middle_keeps_the_text_before_it() throws {
        let typed = try #require(ScreenCommandExtractor.typedCommand(onScreen: "$ rm -rf build dist", cursorColumn: 12, columns: 80))
        #expect(typed.command == "rm -rf bui")
    }

    @Test
    func the_screen_extends_a_cut_command_but_not_past_a_gap() {
        #expect(ScreenCommandExtractor.screenCommand("rm -rf build dist", extends: "rm -rf bui"))
        #expect(!ScreenCommandExtractor.screenCommand("make test        11:23", extends: "make test"))
        #expect(!ScreenCommandExtractor.screenCommand("make test", extends: "make test"))
        #expect(!ScreenCommandExtractor.screenCommand("make", extends: "make test"))
    }

    @Test
    func the_screen_shows_a_command_with_or_without_its_right_prompt() {
        #expect(ScreenCommandExtractor.screenCommand("make  test", shows: "make test"))
        #expect(ScreenCommandExtractor.screenCommand("make test        11:23", shows: "make test"))
        #expect(!ScreenCommandExtractor.screenCommand("make test --verbose", shows: "make test"))
        #expect(!ScreenCommandExtractor.screenCommand("ls", shows: "make test"))
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
