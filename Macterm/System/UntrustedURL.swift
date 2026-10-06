import Foundation
import UniformTypeIdentifiers

/// A link target that came from a source Macterm doesn't trust — an OSC 8
/// hyperlink, whose target is whatever the program writing to the terminal
/// chose — and so must never be handed to Launch Services unexamined: a link
/// labelled `README` can name a `.command` file, an `.app`, or a custom
/// scheme that launches some other application.
///
/// The policy is upstream Ghostty's (ghostty `77537c806`, "macos: handled
/// untrusted OSC8 hyperlinks more carefully"): web and mail links open,
/// custom schemes are confirmed, and anything malformed, deceptive or able to
/// execute code is refused. `decision` is the whole rule; the alerts that
/// carry it out are `UntrustedURLAlert`.
struct UntrustedURL: Equatable {
    enum DenialReason: Equatable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        /// A `file:` URL that names another computer, or carries a query or
        /// fragment — well-formed, but naming nothing on this disk.
        case unsupportedFileURL
        case inaccessibleFile
        case unsafeFile

        var message: String {
            switch self {
            case .malformedURL:
                "The target is not an absolute URL with a scheme."
            case .unsafeCharacters:
                "The target contains invisible or line-breaking characters."
            case .invalidWebURL:
                "The web target does not contain a valid host."
            case .unsupportedFileURL:
                "The file target names another computer, or carries a query or fragment."
            case .inaccessibleFile:
                "The local target does not exist or is not a regular file or directory."
            case .unsafeFile:
                "Opening this local target could execute code."
            }
        }
    }

    enum Decision: Equatable {
        /// A scheme with well-understood, non-executing behavior: open it.
        case allow(URL)
        /// A custom scheme, dispatched to whichever app registered it: ask.
        case confirm(URL)
        /// Malformed, deceptive, or an executable local file: never open.
        case deny(DenialReason)
    }

    let string: String
    /// This Mac's hostname, which a `file://` URL may name as its host: the
    /// tools that emit OSC 8 file links (GNU `ls --hyperlink`, `fd
    /// --hyperlink`) write `file://<hostname>/path`, per the spec's advice. Injectable for
    /// tests; nil when it couldn't be read, which leaves only `localhost`.
    let localHostname: String?

    init(_ string: String, localHostname: String? = Self.currentHostname()) {
        self.string = string
        self.localHostname = localHostname
    }

    /// `gethostname(3)` — the name ghostty's own `os.hostname.isLocal` checks
    /// an OSC 7 host against. Not `ProcessInfo.hostName`, which can block on
    /// a DNS lookup.
    static func currentHostname() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    var decision: Decision {
        guard !string.isEmpty else { return .deny(.malformedURL) }

        // Foundation accepts many control and formatting characters in a URL,
        // and AppKit renders the same characters as line breaks, zero-width
        // text or bidirectional overrides — so the text a user is shown can
        // differ from the target opened. Reject them before parsing.
        guard !string.unicodeScalars.contains(where: Self.isUnsafeCharacter) else {
            return .deny(.unsafeCharacters)
        }

        // `URL(string:)` also accepts relative references. Require an explicit
        // scheme so a later layer can't reinterpret the target as a local path.
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            return .deny(.malformedURL)
        }

        switch scheme {
        case "http",
             "https":
            // "https:relative" has a scheme but no authority, and consumers
            // disagree on how to resolve it.
            guard let host = url.host, !host.isEmpty else {
                return .deny(.invalidWebURL)
            }
            return .allow(url)

        case "mailto":
            // The address is the path; a bare "mailto:" would hand the mail
            // app an empty request.
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !components.path.isEmpty
            else {
                return .deny(.malformedURL)
            }
            return .allow(url)

        case "file":
            return fileDecision(for: url)

        default:
            // A custom scheme can invoke any application registered with
            // Launch Services, so the user sees the target and its handler
            // first.
            return .confirm(url)
        }
    }

    /// The effective target on one line, for the alerts. A local file URL is
    /// standardized exactly as `decision` standardizes it before opening —
    /// symlinks resolved — so dot traversal and repeated separators can't make
    /// the shown and the opened targets differ; other URLs stay byte-for-byte,
    /// since repeated separators can mean something to their handler. That
    /// includes a file URL `decision` refuses for its host, query or
    /// fragment: `URL.path` would drop all three, and the blocked alert (and
    /// its Copy Link) would then show a local path the link never named.
    var displayString: String {
        let normalized = if let url = URL(string: string), url.scheme != nil {
            url.isFileURL && isPlainLocalFile(url) ? url.standardizedFileURL.resolvingSymlinksInPath().path : string
        } else {
            // Never opened, but still shown in the blocked alert: standardize
            // so slash padding and dot traversal can't hide the real path.
            URL(filePath: string).standardizedFileURL.path
        }
        return Self.escapingUnsafeCharacters(normalized)
    }

    /// `text` with every invisible or line-breaking scalar spelled out as
    /// `\u{…}`, so it shows as text and can't open a second display line or
    /// reorder what surrounds it. For showing a link target anywhere — the
    /// hover banner uses it on links that were never classified.
    static func escapingUnsafeCharacters(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

private extension UntrustedURL {
    func fileDecision(for url: URL) -> Decision {
        guard url.isFileURL, isPlainLocalFile(url) else {
            return .deny(.unsupportedFileURL)
        }

        // Classify the effective object, not the spelling the program wrote:
        // this collapses dot traversal and stops a harmless-looking symlink
        // name from hiding an executable target.
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resourceValues: URLResourceValues
        do {
            // Reading the keys together also proves the target exists and is
            // accessible.
            resourceValues = try canonicalURL.resourceValues(forKeys: [
                .contentTypeKey,
                .isDirectoryKey,
                .isExecutableKey,
                .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }

        // Exclude devices, sockets and other special objects. A directory is
        // safe to reveal in Finder unless it is a bundle that would launch.
        guard resourceValues.isDirectory == true || resourceValues.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        guard !Self.isUnsafeFile(canonicalURL, resourceValues: resourceValues) else {
            return .deny(.unsafeFile)
        }
        return .allow(canonicalURL)
    }

    /// Whether a `file:` URL names something on this disk and nothing more.
    /// A query or fragment names no part of a filesystem object, and Launch
    /// Services handlers may read one inconsistently. An empty host,
    /// `localhost` and this Mac's own hostname are this machine; any other
    /// host could trigger network access.
    func isPlainLocalFile(_ url: URL) -> Bool {
        guard url.query == nil, url.fragment == nil else { return false }
        if let host = url.host, !host.isEmpty, !isLocalHost(host) { return false }
        return true
    }

    func isLocalHost(_ host: String) -> Bool {
        // Hostnames compare case-insensitively.
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        guard let localHostname else { return false }
        return host.caseInsensitiveCompare(localHostname) == .orderedSame
    }

    static func isUnsafeFile(_ url: URL, resourceValues: URLResourceValues) -> Bool {
        // Launch Services picks a handler by extension, so known executable
        // containers are refused even with the POSIX executable bit clear.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        // The content type catches a missing or misleading extension; the
        // broad system types take in subtypes (shell scripts, app bundles).
        if let contentType = resourceValues.contentType,
           unsafeContentTypes.contains(where: { contentType.conforms(to: $0) })
        {
            return true
        }
        // Last, any regular file the filesystem marks executable.
        return resourceValues.isDirectory != true && resourceValues.isExecutable == true
    }

    static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0/C1 controls: CR, LF, NEL and the other non-printing bytes.
        case 0x00 ... 0x1F,
             0x7F ... 0x9F:
            true
        // Directional marks and zero-width characters reorder or conceal part
        // of the target without changing what the handler receives.
        case 0x061C,
             0x200B ... 0x200F,
             0x202A ... 0x202E,
             0x2066 ... 0x2069:
            true
        // Line and paragraph separators open new visual lines in AppKit and
        // SwiftUI text, though OSC accepts their UTF-8 bytes.
        case 0x2028 ... 0x2029:
            true
        // Word joiner and BOM: invisible padding that can disguise a target
        // as another that looks identical.
        case 0x2060,
             0xFEFF:
            true
        default:
            false
        }
    }

    static let unsafePathExtensions: Set<String> = [
        "action",
        "app",
        "applescript",
        "class",
        "command",
        "desktop",
        "inetloc",
        "jar",
        "mobileconfig",
        "mpkg",
        "pkg",
        "scpt",
        "terminal",
        "tool",
        "url",
        "webloc",
        "workflow",
    ]

    static let unsafeContentTypes: [UTType] = [.application, .executable, .script]
}
