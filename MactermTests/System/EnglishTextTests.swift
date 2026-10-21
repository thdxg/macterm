import Foundation
@testable import Macterm
import Testing

/// The CLI and the logs stay English. `localizedDescription` follows the
/// language of the app, and Foundation localizes its own errors once the
/// bundle has a translation, so these texts never come from it.
struct EnglishTextTests {
    @Test
    func a_resource_resolves_to_its_english_text() {
        #expect(String(english: "New Tab") == "New Tab")
        #expect(String(english: LocalizedStringResource("tab.status.done", defaultValue: "Done")) == "Done")
    }

    @Test
    func a_foundation_error_is_its_domain_code_and_path() {
        let error = CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "/tmp/missing.yaml"])
        #expect(EnglishErrorText.describe(error) == "NSCocoaErrorDomain error 260 (/tmp/missing.yaml)")
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 2)
        #expect(EnglishErrorText.describe(posix) == "NSPOSIXErrorDomain error 2")
    }

    @Test
    func a_decoding_error_is_its_path_and_debug_description() {
        struct Shape: Decodable { let name: String }
        let decoded = Result { try JSONDecoder().decode(Shape.self, from: Data(#"{"name": 1}"#.utf8)) }
        guard case let .failure(error) = decoded else {
            Issue.record("expected a decoding error")
            return
        }
        let text = EnglishErrorText.describe(error)
        #expect(text.hasPrefix("name: "), "\(text)")
    }

    /// A Swift error of a library describes itself; its `localizedDescription`
    /// would only be Foundation's generic text with the type name.
    @Test
    func a_swift_error_describes_itself() {
        struct LibraryError: Error, CustomStringConvertible {
            var description: String { "unexpected token at line 3" }
        }
        #expect(EnglishErrorText.describe(LibraryError()) == "unexpected token at line 3")
    }

    @Test
    func a_layout_error_is_english_for_the_cli() {
        let underlying = CocoaError(.fileReadCorruptFile)
        let error = LayoutFileError.parse(underlying: underlying)
        #expect(EnglishErrorText.describe(error) == "The layout file is invalid and was not applied.\n\nNSCocoaErrorDomain error 259")
        #expect(
            EnglishErrorText.describe(LayoutFileError.noProjectFile(projectPath: "~/dev/api"))
                == "No layout file declares ~/dev/api. Use “Save Layout” to create one."
        )
    }

    @Test
    func a_bilingual_message_has_an_english_form_for_the_log() {
        let message = BilingualMessage({ "could not read widgets.yaml: \($0)" }, error: CocoaError(.fileReadNoPermission))
        #expect(message.english == "could not read widgets.yaml: NSCocoaErrorDomain error 257")
    }
}
