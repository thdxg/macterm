import Foundation

/// Removes secrets from the text that project memory keeps.
///
/// Terminal text holds secrets: tokens in `export` lines, passwords in a
/// `curl -u`, keys in a URL. Memory never needs them, so every command and
/// every failure tail goes through here before it is stored. The rules
/// replace a value with `•••` and keep the shape of the line, so a command
/// is still readable and still ranks with its other runs.
///
/// A command that starts with a space is not recorded at all: the shells'
/// `HISTCONTROL=ignorespace` convention for "do not remember this".
enum MemoryRedaction {
    static let mask = "•••"

    /// Whether the user asked the shell not to remember `command`.
    static func isPrivate(_ command: String) -> Bool {
        command.first == " " || command.first == "\t"
    }

    /// `text` with every secret replaced by `mask`. For program output: a
    /// value ends only at a space, because output does not follow shell rules.
    static func redact(_ text: String) -> String {
        apply(textRules, to: text)
    }

    /// `command` with every secret replaced by `mask`. A value is a shell word,
    /// so a separator after it (`TOKEN=abc; make`) stays.
    static func redactCommand(_ command: String) -> String {
        apply(commandRules, to: command)
    }

    private static func apply(_ rules: [Rule], to text: String) -> String {
        rules.reduce(text) { result, rule in rule.apply(to: result) }
    }

    private struct Rule {
        let regex: NSRegularExpression
        /// The template that replaces a match. `$1` keeps the part before
        /// the secret.
        let template: String

        init(_ pattern: String, _ template: String) {
            // The patterns are constants: a bad one is a programming error
            // that every test run would show.
            // swiftlint:disable:next force_try
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.template = template
        }

        func apply(to text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
    }

    /// Names whose value is a secret: `API_TOKEN`, `DB_PASSWORD`, `aws_secret_access_key`.
    /// `auth` but not `author`, so `git commit --author` stays readable.
    private static let secretName = #"[A-Za-z0-9_]*(?:token|secret|passw(?:or)?d|pass|pwd|"#
        + #"api[_-]?key|access[_-]?key|private[_-]?key|auth(?!or)|credential)[A-Za-z0-9_]*"#

    /// A secret value in output: a quoted string, or else all up to a space.
    private static let textValue = #"(?:"[^"]*"|'[^']*'|\S+)"#

    /// A secret value in a command, read as one shell word. It ends at a space
    /// or at a `;`, `&`, `|`, `<` or `>` that is not quoted or escaped. A `)`
    /// ends it only before a space, a separator or the end of the line, so the
    /// rest of `pass)word` stays masked. An unclosed quote or backtick, or a
    /// trailing backslash, takes the rest of the word.
    ///
    /// A user who types a secret with an unquoted `;`, `&` or `|` in it shows
    /// the part after it: the shell reads that part as the next command, and
    /// no rule can tell the two apart.
    private static let shellWordValue = #"(?:\\.|"(?:\\.|[^"\\])*"|'[^']*'|`[^`]*`|\$\([^()]*\)"#
        + #"|\)(?![\s;&|<>)]|$)|[^\s;&|<>)"'`\\]|["'`\\]\S*)+"#

    private static let textRules = rules(value: textValue)
    private static let commandRules = rules(value: shellWordValue)

    private static func rules(value: String) -> [Rule] {
        [
            // `NAME=value`, `export NAME=value`, `$env.NAME = value`.
            Rule(#"(\b"# + secretName + #"\s*=\s*)"# + value, "$1" + mask),
            // `Authorization: Bearer abc`, `X-Api-Key: abc` in a header argument.
            // A header is almost always quoted, where a `;` is part of the value,
            // so this value ends only at a space or a quote.
            Rule(
                #"((?:authorization|proxy-authorization|x-[a-z-]*(?:key|token))\s*:\s*)(?:(?:bearer|basic|token)\s+)?[^\s"']+"#,
                "$1" + mask
            ),
            // `--password value`, `--token=value`, `-p=value`.
            Rule(#"(--?"# + secretName + #"(?:=|\s+))"# + value, "$1" + mask),
            // `curl -u user:pass`, `--user user:pass`.
            Rule(#"((?:-u|--user)\s+[^\s:]+:)"# + value, "$1" + mask),
            // `https://user:pass@host`.
            Rule(#"([a-z][a-z0-9+.-]*://[^\s/:@]+:)[^\s/@]+(@)"#, "$1" + mask + "$2"),
            // Keys with a known shape: GitHub, Slack, AWS, OpenAI and Anthropic, JWTs.
            Rule(
                #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}"#
                    + #"|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}"#
                    + #"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b"#,
                mask
            ),
        ]
    }
}
