@testable import Macterm
import Testing

/// Where the editor files an entry (`PasswordEditorSheet.filing`).
@MainActor
struct PasswordEditorSheetTests {
    private let passphrase = "Enter passphrase for key '/k':"

    @Test
    func an_untouched_entry_stays_where_detection_filed_it() throws {
        // A passphrase asked by a replaceable program is filed under that
        // program; the declared rules would move it to the key's shared entry.
        let homebrew = PasswordEntryID(command: "/opt/homebrew/bin/ssh prod", prompt: passphrase)
        #expect(try PasswordEditorSheet.filing(command: #require(homebrew.command), prompt: passphrase, editing: homebrew) == homebrew)
        // A program named sudo outside the system folders keeps its own entry.
        let fakeSudo = PasswordEntryID(command: "/Users/me/bin/sudo ls", prompt: "Password:")
        #expect(try PasswordEditorSheet.filing(command: #require(fakeSudo.command), prompt: "Password:", editing: fakeSudo) == fakeSudo)
    }

    @Test
    func an_edited_field_files_through_the_declared_rules() {
        let current = PasswordEntryID(command: "/usr/bin/ssh prod", prompt: "Password:")
        #expect(PasswordEditorSheet.filing(command: "sudo apt update", prompt: "Password:", editing: current)
            == PasswordEntryID(command: "sudo", prompt: "Password:"))
        #expect(PasswordEditorSheet.filing(command: "deploy", prompt: "", editing: nil)
            == PasswordEntryID(command: "deploy", prompt: ""))
    }
}
