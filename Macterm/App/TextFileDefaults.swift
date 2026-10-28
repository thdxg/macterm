import AppKit
import os
import UniformTypeIdentifiers

private let logger = Logger(subsystem: appBundleID, category: "TextFileDefaults")

/// Settings → General → Opening Text Files → Make Default: Finder's
/// Get Info → Change All, for every text file type at once.
///
/// Launch Services keeps the default app for each content type on its own. A
/// default for `public.text` does not reach `public.python-script`, so the
/// button sets each concrete type that a text file can have. A type is in the
/// list because a file extension has it: the extensions that Info.plist
/// declares (the types that macOS does not know) and `commonExtensions` (the
/// types that macOS types as text).
///
/// The plist ranks Macterm `Alternate`, so it is never a default until the
/// user asks. This button is that request, so nothing calls it without a click.
enum TextFileDefaults {
    /// Extensions whose system types are text that a terminal editor edits.
    /// The extensions that Info.plist declares come in addition.
    static let commonExtensions: [String] = [
        "txt", "text", "md", "markdown", "json", "yaml", "yml", "toml", "ini", "cfg", "xml",
        "csv", "tsv", "log", "sh", "bash", "zsh", "py", "rb", "pl", "php", "swift",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "js", "mjs", "java", "css", "scss",
        "sql", "diff", "patch", "s", "proto", "mk",
    ]

    /// Text that another kind of app owns: a browser opens HTML, a word
    /// processor opens styled text, and SVG is an image. A type that conforms
    /// to one of these stays out, also when an extension in the list has it.
    static let excludedTypes: [UTType] = [.html, .rtf, .rtfd, .flatRTFD, .image]

    /// The extensions of the plist's document types, in plist order.
    static func declaredExtensions(in info: [String: Any]?) -> [String] {
        let documentTypes = info?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return documentTypes.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
    }

    /// One type for each distinct identifier, in extension order. A type
    /// stays when it is text, or when macOS does not know the extension (a
    /// dynamic type, which only the plist's claim names). `ts` is the case for
    /// the filter: macOS types it as MPEG-2 video, and a click must not make
    /// Macterm the player of every video of that type.
    static func contentTypes(
        forExtensions extensions: [String],
        type: (String) -> UTType? = { UTType(filenameExtension: $0) }
    ) -> [UTType] {
        var seen = Set<String>()
        var types: [UTType] = []
        for ext in extensions {
            guard let candidate = type(ext),
                  isEligible(candidate),
                  seen.insert(candidate.identifier).inserted
            else { continue }
            types.append(candidate)
        }
        return types
    }

    /// Text, or an extension that macOS does not know, and not a type in
    /// `excludedTypes`.
    static func isEligible(_ type: UTType) -> Bool {
        (type.conforms(to: .text) || type.isDynamic) && !excludedTypes.contains { type.conforms(to: $0) }
    }

    /// The extensions whose types the button sets, in list order. The docs
    /// list them (`TextFileDefaultsTests` compares the two).
    static func extensions(bundle: Bundle = .main) -> [String] {
        (commonExtensions + declaredExtensions(in: bundle.infoDictionary)).filter { ext in
            UTType(filenameExtension: ext).map(isEligible) ?? false
        }
    }

    /// The types that the button sets for this app.
    static func contentTypes(bundle: Bundle = .main) -> [UTType] {
        contentTypes(forExtensions: commonExtensions + declaredExtensions(in: bundle.infoDictionary))
    }

    /// The types whose default app is not this app, compared by bundle
    /// identifier (`TextFileOpening.isDefaultApp` does the same for a file).
    static func typesNotOpenedHere(
        _ types: [UTType],
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaultApp: (UTType) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    ) -> [UTType] {
        guard let bundleIdentifier else { return types }
        return types.filter { type in
            guard let app = defaultApp(type) else { return true }
            return Bundle(url: app)?.bundleIdentifier != bundleIdentifier
        }
    }

    /// Makes `appURL` the default app of each type, one at a time: Launch
    /// Services can ask the user to agree, and one request at a time keeps
    /// those dialogs in a line. Returns the types that it could not set.
    @MainActor
    static func makeDefault(_ types: [UTType], appURL: URL = Bundle.main.bundleURL) async -> [UTType] {
        var failed: [UTType] = []
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
            } catch {
                logger.error(
                    "default app for \(type.identifier, privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)"
                )
                failed.append(type)
            }
        }
        logger.info("default app for \(types.count - failed.count, privacy: .public) of \(types.count, privacy: .public) text types")
        return failed
    }
}
