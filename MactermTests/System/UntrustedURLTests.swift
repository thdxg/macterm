import Foundation
@testable import Macterm
import Testing

/// The OSC 8 link policy, ported with upstream Ghostty's own cases plus the
/// file-URL edges Macterm's port relies on.
struct UntrustedURLTests {
    @Test(arguments: ["http://example.com", "https://example.com/path", "mailto:user@example.com"])
    func allowsSafeSchemes(_ value: String) {
        guard case let .allow(url) = UntrustedURL(value).decision else {
            Issue.record("expected an allowed URL")
            return
        }
        #expect(url.absoluteString == value)
    }

    @Test(arguments: ["https:relative", "http:///missing-host"])
    func rejectsWebURLsWithoutHosts(_ value: String) {
        #expect(UntrustedURL(value).decision == .deny(.invalidWebURL))
    }

    @Test(arguments: ["", "/tmp/file.txt", "../file.txt", "payload.command", "mailto:"])
    func rejectsMalformedTargets(_ value: String) {
        #expect(UntrustedURL(value).decision == .deny(.malformedURL))
    }

    @Test(arguments: ["vscode://file/tmp/example.swift", "ssh://example.com"])
    func confirmsCustomSchemes(_ value: String) {
        guard case let .confirm(url) = UntrustedURL(value).decision else {
            Issue.record("expected a confirmation decision")
            return
        }
        #expect(url.absoluteString == value)
    }

    @Test(arguments: ["\u{0085}", "\u{2028}", "\u{2029}", "\u{202E}", "\u{2066}", "\u{200B}", "\u{FEFF}"])
    func rejectsInvisibleAndLineBreakingCharacters(_ scalar: String) {
        let value = "https://example.com/before\(scalar)after"
        #expect(UntrustedURL(value).decision == .deny(.unsafeCharacters))
    }

    @Test(arguments: [
        "file://evil.example.com/tmp/document.txt",
        "file:///tmp/document.txt?x=1",
        "file:///tmp/document.txt#frag",
    ])
    func rejectsRemoteHostsQueriesAndFragmentsInFileURLs(_ value: String) {
        #expect(UntrustedURL(value).decision == .deny(.malformedURL))
    }

    @Test
    func rejectsMissingLocalFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "absent.txt")
        #expect(UntrustedURL(missing.absoluteString).decision == .deny(.inaccessibleFile))
    }

    @Test
    func allowsNonExecutableLocalFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "document.txt")
        try "safe".write(to: file, atomically: true, encoding: .utf8)

        guard case let .allow(result) = UntrustedURL(file.absoluteString).decision else {
            Issue.record("expected a safe local file")
            return
        }
        #expect(result == file.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test
    func allowsLocalhostFileURLsAndPlainDirectories() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "document.txt")
        try "safe".write(to: file, atomically: true, encoding: .utf8)

        let localhost = "file://localhost" + file.path
        guard case .allow = UntrustedURL(localhost).decision else {
            Issue.record("expected localhost to name this machine")
            return
        }
        guard case .allow = UntrustedURL(directory.absoluteString).decision else {
            Issue.record("expected a plain directory to be revealed")
            return
        }
    }

    @Test(arguments: ["my-mac.local", "MY-MAC.LOCAL"])
    func allowsFileURLsNamingThisMachinesHostname(_ host: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "document.txt")
        try "safe".write(to: file, atomically: true, encoding: .utf8)

        // What `fd --hyperlink` and `ls --hyperlink` write.
        let value = "file://\(host)\(file.path)"
        guard case let .allow(result) = UntrustedURL(value, localHostname: "my-mac.local").decision else {
            Issue.record("expected this machine's hostname to be local")
            return
        }
        #expect(result == file.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test
    func hostnameDoesNotExemptExecutables() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appending(path: "payload.command")
        try "#!/bin/sh\n".write(to: payload, atomically: true, encoding: .utf8)

        let value = "file://my-mac.local\(payload.path)"
        #expect(UntrustedURL(value, localHostname: "my-mac.local").decision == .deny(.unsafeFile))
    }

    @Test
    func otherHostsStayRemoteEvenWithAHostnameKnown() {
        let value = "file://other-mac.local/tmp/document.txt"
        #expect(UntrustedURL(value, localHostname: "my-mac.local").decision == .deny(.malformedURL))
        #expect(UntrustedURL(value, localHostname: nil).decision == .deny(.malformedURL))
    }

    @Test
    func readsThisMachinesHostname() {
        #expect(UntrustedURL.currentHostname()?.isEmpty == false)
    }

    @Test(arguments: ["payload.command", "payload.tool", "payload.app", "payload.workflow", "payload.terminal"])
    func rejectsDangerousLocalFileExtensions(_ filename: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: filename)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(UntrustedURL(file.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func rejectsApplicationBundleDirectories() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appending(path: "Payload.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)

        #expect(UntrustedURL(bundle.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func rejectsScriptContentTypes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "payload.sh")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(UntrustedURL(file.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func rejectsExecutableFilesRegardlessOfExtension() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "payload.txt")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        #expect(UntrustedURL(file.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func resolvesSymlinksBeforeClassifyingFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appending(path: "payload.command")
        let link = directory.appending(path: "document.txt")
        try "#!/bin/sh\n".write(to: payload, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)

        #expect(UntrustedURL(link.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func collapsesTraversalBeforeClassifyingFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appending(path: "payload.command")
        try "#!/bin/sh\n".write(to: payload, atomically: true, encoding: .utf8)
        let decoy = directory.absoluteString + "document.txt/../payload.command"

        #expect(UntrustedURL(decoy).decision == .deny(.unsafeFile))
    }

    @Test(arguments: ["\u{0085}", "\u{2028}", "\u{2029}"])
    func previewShowsTheEffectiveStandardizedPath(_ separator: String) {
        let value = "/tmp/preview\(separator)////../payload.command////"
        #expect(UntrustedURL(value).displayString == "/tmp/payload.command")
    }

    @Test
    func previewEscapesBidirectionalControls() {
        let value = "https://example.com/a\u{202E}b"
        #expect(UntrustedURL(value).displayString == "https://example.com/a\\u{202E}b")
    }

    @Test
    func previewKeepsWebURLsByteForByte() {
        let value = "https://example.com//a/../b"
        #expect(UntrustedURL(value).displayString == value)
    }

    @Test
    func escapingLeavesOrdinaryTextAlone() {
        #expect(UntrustedURL.escapingUnsafeCharacters("src/main.swift:12") == "src/main.swift:12")
        #expect(UntrustedURL.escapingUnsafeCharacters("a\u{2028}b\u{200B}") == "a\\u{2028}b\\u{200B}")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
}
