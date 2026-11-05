import Foundation
@testable import Macterm
import Testing

struct OutputExplanationTests {
    // MARK: - The last command

    @Test
    func last_command_is_between_the_last_two_prompts() {
        let screen = """
        ❯ ls
        a b
        ❯ cargo test
        running 3 tests
        test result: FAILED. 2 passed; 1 failed
        ❯

        """
        let found = OutputExplanation.lastCommand(in: screen)
        #expect(found?.command == "cargo test")
        #expect(found?.output == "running 3 tests\ntest result: FAILED. 2 passed; 1 failed")
        #expect(found?.linesBelowOutput == 1)
    }

    @Test
    func last_command_reads_a_prompt_with_user_and_host() {
        let screen = "me@box:~/src$ make\ncc -c x.c\nx.c:3: error: y\nme@box:~/src$ "
        let found = OutputExplanation.lastCommand(in: screen)
        #expect(found?.command == "make")
        #expect(found?.output == "cc -c x.c\nx.c:3: error: y")
    }

    @Test
    func last_command_reads_a_two_line_prompt() {
        // nushell and starship: a path line, then the mark line.
        let screen = "~/dev\n❯ git status\nnothing to commit\n~/dev\n❯"
        let found = OutputExplanation.lastCommand(in: screen)
        #expect(found?.command == "git status")
        #expect(found?.output == "nothing to commit")
        #expect(found?.linesBelowOutput == 2)
    }

    @Test
    func a_changed_prompt_header_stays_in_the_output() {
        // After `cd`, the header differs, so it cannot be told from output.
        let screen = "~\n❯ cd src\n~/src\n❯"
        #expect(OutputExplanation.lastCommand(in: screen)?.output == "~/src")
    }

    @Test
    func blank_lines_below_the_output_count_as_rows() {
        let found = OutputExplanation.lastCommand(in: "$ make\nok\n\n\n$")
        #expect(found?.output == "ok")
        #expect(found?.linesBelowOutput == 3)
    }

    @Test
    func last_command_is_nil_without_a_command_line() {
        #expect(OutputExplanation.lastCommand(in: "line one\nline two\n❯") == nil)
        #expect(OutputExplanation.lastCommand(in: "no prompt here\nat all") == nil)
        #expect(OutputExplanation.lastCommand(in: "") == nil)
    }

    @Test
    func a_mark_inside_a_word_is_not_a_prompt() {
        // `$ ` follows `cost`, so it is in a word: output, not a prompt line.
        let screen = "$ report\ntotal cost$ 40\n$"
        #expect(OutputExplanation.lastCommand(in: screen)?.command == "report")
    }

    @Test
    func prompt_mark_is_the_first_token_with_a_terminator() {
        #expect(OutputExplanation.promptMark(in: "~/dev ❯") == "❯")
        #expect(OutputExplanation.promptMark(in: "me@box:~$ ") == "me@box:~$")
        #expect(OutputExplanation.promptMark(in: "plain text") == nil)
    }

    @Test
    func screen_without_prompt_drops_the_cursor_line() {
        #expect(OutputExplanation.screenWithoutPrompt("a\nb\n❯\n\n") == "a\nb")
        #expect(OutputExplanation.screenWithoutPrompt("").isEmpty)
    }

    // MARK: - The command above a selected output

    @Test
    func command_takes_every_line_of_a_continued_command() {
        let screen = """
        ❯ ls
        a
        ❯ cargo build \\
          --release
           Compiling x v0.1.0
        error: could not compile `x`
        ❯
        """
        let output = "   Compiling x v0.1.0\nerror: could not compile `x`"
        #expect(OutputExplanation.command(in: screen, before: output) == "cargo build \\\n  --release")
    }

    @Test
    func command_takes_a_heredoc() {
        let screen = "$ cat <<EOF\n> a\n> EOF\na\n$ "
        #expect(OutputExplanation.command(in: screen, before: "a") == "cat <<EOF\n> a\n> EOF")
    }

    @Test
    func command_of_one_line_is_that_line() {
        let screen = "~\n❯ git status\nnothing to commit\n~\n❯"
        #expect(OutputExplanation.command(in: screen, before: "nothing to commit") == "git status")
    }

    @Test
    func command_uses_the_last_copy_of_an_output_that_repeats() {
        let screen = "$ true\nok\n$ make\nok\n$"
        #expect(OutputExplanation.command(in: screen, before: "ok") == "make")
    }

    @Test
    func command_is_nil_when_the_output_or_the_prompt_is_not_on_screen() {
        #expect(OutputExplanation.command(in: "$ make\nlater lines\n$", before: "earlier output") == nil)
        #expect(OutputExplanation.command(in: "no prompt\nok", before: "ok") == nil)
        #expect(OutputExplanation.command(in: "", before: "ok") == nil)
    }

    @Test
    func prompt_puts_a_multiline_command_on_its_own_lines() {
        let explanation = OutputExplanation(source: .output, command: "cat <<EOF\n> a\n> EOF", text: "a")
        #expect(explanation.prompt.hasPrefix("Explain the output of this command:\ncat <<EOF\n> a\n> EOF\n<<<\n"))
    }

    @Test
    func cursor_prompt_mark_is_the_mark_of_the_last_line() {
        #expect(OutputExplanation.cursorPromptMark(in: "~\n❯ ls\na\n~\n❯\n\n") == "❯")
        #expect(OutputExplanation.cursorPromptMark(in: "no prompt") == nil)
    }

    @Test
    func selection_starts_at_the_command_on_its_prompt_line() {
        let selection = "❯ loop { seq 1 10; sleep 1sec; }\n^CError: nu::shell::error"
        #expect(OutputExplanation.selection(selection, startsAtCommand: "loop { seq 1 10; sleep 1sec; }", mark: "❯"))
        // One row short: the selection starts in the output.
        #expect(!OutputExplanation.selection("^CError: x", startsAtCommand: "loop { }", mark: "❯"))
        // A wrapped or continued command line is not its prompt line.
        #expect(!OutputExplanation.selection("  --release\nok", startsAtCommand: "cargo build \\", mark: "❯"))
        #expect(!OutputExplanation.selection("", startsAtCommand: "ls", mark: "❯"))
    }

    // MARK: - Budget

    @Test
    func excerpt_keeps_short_text_whole() {
        #expect(OutputExplanation.excerpt(of: "\n  a  \nb\n\n", tokenBudget: 100) == "  a\nb")
    }

    @Test
    func excerpt_keeps_the_start_and_the_end_of_long_text() {
        let text = (1 ... 1000).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = OutputExplanation.excerpt(of: text, tokenBudget: 200)
        #expect(excerpt.hasPrefix("line 1\n"))
        #expect(excerpt.hasSuffix("line 1000"))
        #expect(excerpt.contains("lines not shown"))
        #expect(OutputExplanation.estimatedTokens(excerpt) <= 200 + 10)
    }

    @Test
    func excerpt_keeps_the_end_of_one_very_long_line() {
        let text = String(repeating: "a", count: 10000) + "END"
        let excerpt = OutputExplanation.excerpt(of: text, tokenBudget: 50)
        #expect(excerpt.hasSuffix("END"))
        #expect(OutputExplanation.estimatedTokens(excerpt) <= 60)
    }

    @Test
    func token_estimate_counts_non_ascii_as_one_token_each() {
        #expect(OutputExplanation.estimatedTokens("abcdef") == 3)
        #expect(OutputExplanation.estimatedTokens("abcdefghij") == 4)
        #expect(OutputExplanation.estimatedTokens("빌드 실패") == 5)
    }

    @Test
    func the_budget_fits_the_context_window() {
        let framing = OutputExplanation.estimatedTokens(OutputExplanation.instructions) + 100
        #expect(framing <= OutputExplanation.framingTokens)
        for contextSize in [4096, 8192] {
            let budget = OutputExplanation.textTokenBudget(contextSize: contextSize)
            #expect(framing + budget + OutputExplanation.maximumReplyTokens <= contextSize)
        }
        #expect(OutputExplanation.textTokenBudget(contextSize: 8192) > 2 * OutputExplanation.textTokenBudget(contextSize: 4096))
    }

    // MARK: - Fit

    /// A traceback of `frames` frames: about 2.5 characters to a token.
    private func traceback(frames: Int) -> String {
        (0 ..< frames).flatMap { index in
            [
                "  File \"/srv/orbit/app/module_\(index).py\", line \(100 + index), in handler_\(index)",
                "    result = dispatch(request, config[\"key_\(index)\"])",
            ]
        }.joined(separator: "\n") + "\nKeyError: 'ORBIT_DATABASE_URL'"
    }

    /// The tokens that a model with `charactersPerToken` counts, and the
    /// counts that it made.
    @MainActor
    private final class Counter {
        let charactersPerToken: Double
        var calls = 0
        init(charactersPerToken: Double) {
            self.charactersPerToken = charactersPerToken
        }

        func count(_ text: String) -> Int {
            calls += 1
            return Int((Double(text.count) / charactersPerToken).rounded(.up))
        }
    }

    @MainActor
    private func fits(_ explanation: OutputExplanation, contextSize: Int, counter: Counter) -> Bool {
        counter.count(OutputExplanation.instructions) + counter.count(explanation.prompt)
            + OutputExplanation.chatFormatTokens + OutputExplanation.maximumReplyTokens <= contextSize
    }

    @Test @MainActor
    func fit_cuts_text_that_the_estimate_counts_low() async {
        let counter = Counter(charactersPerToken: 2)
        var explanation = OutputExplanation(source: .output, text: traceback(frames: 400))
        await explanation.fit(contextSize: 8192) { counter.count($0) }
        #expect(fits(explanation, contextSize: 8192, counter: counter))
        #expect(explanation.text.hasSuffix("KeyError: 'ORBIT_DATABASE_URL'"))
        #expect(explanation.text.contains("lines not shown"))
        // It used most of the space.
        #expect(counter.count(explanation.prompt) * 10 > 8192 * 8)
    }

    @Test @MainActor
    func fit_grows_text_that_the_estimate_counts_high() async {
        let text = (1 ... 3000).map { "Compiling crate number \($0) of the workspace" }.joined(separator: "\n")
        let estimated = OutputExplanation(source: .output, text: text, contextSize: 8192)
        let counter = Counter(charactersPerToken: 4)
        var explanation = estimated
        await explanation.fit(contextSize: 8192) { counter.count($0) }
        #expect(fits(explanation, contextSize: 8192, counter: counter))
        #expect(explanation.text.count > estimated.text.count * 3 / 2)
        #expect(counter.calls <= OutputExplanation.maximumFitPasses + 1)
    }

    @Test @MainActor
    func fit_does_not_count_short_text() async {
        let counter = Counter(charactersPerToken: 2.5)
        var explanation = OutputExplanation(source: .output, text: traceback(frames: 20))
        await explanation.fit(contextSize: 8192) { counter.count($0) }
        #expect(explanation.text == explanation.fullText)
        #expect(counter.calls == 0)
    }

    @Test @MainActor
    func fit_keeps_text_that_fits_whole_with_one_count() async {
        let counter = Counter(charactersPerToken: 2.5)
        var explanation = OutputExplanation(source: .output, text: traceback(frames: 100))
        #expect(explanation.text != explanation.fullText)
        await explanation.fit(contextSize: 8192) { counter.count($0) }
        #expect(explanation.text == explanation.fullText)
        #expect(counter.calls == 2)
    }

    @Test @MainActor
    func fit_without_a_count_uses_the_estimate_for_the_context_size() async {
        let text = traceback(frames: 400)
        var explanation = OutputExplanation(source: .output, text: text)
        await explanation.fit(contextSize: 8192, countTokens: nil)
        #expect(explanation == OutputExplanation(source: .output, text: text, contextSize: 8192))
        #expect(explanation.text.count > OutputExplanation(source: .output, text: text).text.count * 2)
    }

    @Test @MainActor
    func fit_with_a_count_that_fails_uses_the_estimate() async {
        struct Failure: Error {}
        let text = traceback(frames: 400)
        var explanation = OutputExplanation(source: .output, text: text)
        await explanation.fit(contextSize: 8192) { _ in throw Failure() }
        #expect(explanation == OutputExplanation(source: .output, text: text, contextSize: 8192))
    }

    // MARK: - Prompt

    @Test
    func prompt_names_the_command() {
        let explanation = OutputExplanation(source: .output, command: "make", text: "error: x")
        #expect(explanation.prompt == "Explain the output of the command `make`.\n<<<\nerror: x\n>>>")
    }

    @Test
    func prompt_for_a_selection_and_a_language() {
        let explanation = OutputExplanation(source: .selection, text: "EACCES", replyLanguage: "Korean")
        #expect(explanation.prompt.hasPrefix("Explain this text that the developer selected in the terminal.\n"))
        #expect(explanation.prompt.contains("Write the explanation in Korean."))
    }

    @Test
    func prompt_without_a_command() {
        let explanation = OutputExplanation(source: .output, text: "x")
        #expect(explanation.prompt.hasPrefix("Explain this command output from the terminal."))
    }

    @Test
    func has_text_is_false_for_blank_text() {
        #expect(!OutputExplanation(source: .selection, text: " \n ").hasText)
        #expect(OutputExplanation(source: .selection, text: "x").hasText)
    }
}
