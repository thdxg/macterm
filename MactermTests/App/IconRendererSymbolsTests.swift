import Foundation
import Testing

/// `macterm-icon-renderer` checks the symbols in `RequiredSymbols.swift`
/// before its first private call, and links against
/// `PrivateInterfaces/IconRendering.tbd`. A symbol in one list and not the
/// other is either never checked (a dyld abort, not a named exit) or never
/// linked (a build error), so the two must be the same.
struct IconRendererSymbolsTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // App
        .deletingLastPathComponent() // MactermTests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("IconRenderer")

    private static func matches(_ pattern: String, in file: String) throws -> Set<String> {
        let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    @Test
    func theCheckedSymbolsAreTheLinkedSymbols() throws {
        let linked = try Self.matches(#"^\s*- '_(\$s[^']+)'$"#, in: "PrivateInterfaces/IconRendering.tbd")
        let checked = try Self.matches(#"^\s*"(\$s[^"]+)",$"#, in: "RequiredSymbols.swift")
        #expect(!linked.isEmpty)
        #expect(linked == checked, "only linked: \(linked.subtracting(checked)), only checked: \(checked.subtracting(linked))")
    }

    @Test
    func theCheckedClassesAreTheLinkedClasses() throws {
        let linked = try Self.matches(#"objc-classes:\s*\[\s*(.+?)\s*\]"#, in: "PrivateInterfaces/CoreUI.tbd")
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let checked = try Self.matches(#"objcClasses = \[(.+)\]"#, in: "RequiredSymbols.swift")
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } }
        #expect(Set(linked) == Set(checked))
    }
}
