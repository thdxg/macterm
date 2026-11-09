@testable import Macterm
import Testing

struct MemoryRedactionTests {
    private let mask = MemoryRedaction.mask

    @Test(arguments: [
        ("export GITHUB_TOKEN=abc123", "export GITHUB_TOKEN=•••"),
        ("API_KEY='s3cr3t value' npm run deploy", "API_KEY=••• npm run deploy"),
        ("DB_PASSWORD=\"hunter2\" ./migrate", "DB_PASSWORD=••• ./migrate"),
        ("$env.OPENAI_SECRET = abc", "$env.OPENAI_SECRET = •••"),
        ("curl -H 'Authorization: Bearer abc.def' https://api", "curl -H 'Authorization: •••' https://api"),
        ("mysql --password=hunter2 db", "mysql --password=••• db"),
        ("tool --token abc123 run", "tool --token ••• run"),
        ("curl -u admin:hunter2 https://x", "curl -u admin:••• https://x"),
        ("git clone https://me:ghp_secret@github.com/a/b", "git clone https://me:•••@github.com/a/b"),
        ("echo ghp_abcdefghijklmnopqrstuvwxyz0123", "echo •••"),
    ])
    func a_secret_is_masked(input: String, expected: String) {
        #expect(MemoryRedaction.redact(input) == expected)
    }

    @Test(arguments: [
        ("TOKEN=abc; make", "TOKEN=•••; make"),
        ("TOKEN=abc;make", "TOKEN=•••;make"),
        ("TOKEN=abc&& make", "TOKEN=•••&& make"),
        ("TOKEN=abc& make", "TOKEN=•••& make"),
        ("TOKEN=abc|| make", "TOKEN=•••|| make"),
        ("TOKEN=abc| base64", "TOKEN=•••| base64"),
        ("(TOKEN=abc)", "(TOKEN=•••)"),
        ("echo $(TOKEN=abc env)", "echo $(TOKEN=••• env)"),
        ("TOKEN=abc>out", "TOKEN=•••>out"),
        ("TOKEN=abc<in", "TOKEN=•••<in"),
        ("/bin/sh -c 'echo token=ghp_abcdefghijklmnopqrstuvwxyz0123456789; exit 3'", "/bin/sh -c 'echo token=•••; exit 3'"),
        ("tool --token abc; make", "tool --token •••; make"),
        ("tool --password=abc&& make", "tool --password=•••&& make"),
        ("curl -u admin:hunter2; echo", "curl -u admin:•••; echo"),
        ("curl -u admin:hunter2|jq", "curl -u admin:•••|jq"),
    ])
    func a_separator_after_a_secret_is_kept(input: String, expected: String) {
        #expect(MemoryRedaction.redact(input) == expected)
    }

    /// A separator that is quoted or escaped is part of the secret, and so is
    /// all that follows a quote with no end.
    @Test(arguments: [
        ("TOKEN=ab\\;cd; make", "TOKEN=•••; make"),
        ("TOKEN=ab';'cd; make", "TOKEN=•••; make"),
        ("TOKEN=ab\";\"cd; make", "TOKEN=•••; make"),
        ("TOKEN=\"a\\\"b; c\"; make", "TOKEN=•••; make"),
        ("TOKEN=$(pass show x); make", "TOKEN=•••; make"),
        ("TOKEN=`pass show x`; make", "TOKEN=•••; make"),
        ("TOKEN=ab\"cd;ef", "TOKEN=•••"),
        ("TOKEN=ab'cd|ef gh", "TOKEN=••• gh"),
        ("TOKEN=\"abc", "TOKEN=•••"),
        ("curl -u admin:pa\\|ss|jq", "curl -u admin:•••|jq"),
    ])
    func a_quoted_or_escaped_separator_stays_masked(input: String, expected: String) {
        #expect(MemoryRedaction.redact(input) == expected)
    }

    @Test(arguments: [
        "git commit --author \"Ann <a@b.c>\" -m fix",
        "npm test",
        "ls -la ~/dev",
        "cargo build --release",
        "ssh user@host",
    ])
    func an_ordinary_command_is_unchanged(command: String) {
        #expect(MemoryRedaction.redact(command) == command)
    }

    @Test
    func a_leading_space_marks_a_command_private() {
        #expect(MemoryRedaction.isPrivate(" export TOKEN=x"))
        #expect(!MemoryRedaction.isPrivate("export TOKEN=x"))
    }
}
