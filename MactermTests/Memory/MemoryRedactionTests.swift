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
