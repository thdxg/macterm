import Foundation

extension String {
    /// The English text of `resource`, whatever the language of the app.
    /// English is the source language, so this is the text of the code. Use
    /// it for the CLI and logs, which stay English, and for text that a
    /// search must also match in English.
    init(english resource: LocalizedStringResource) {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        self.init(localized: resource)
    }
}

/// A message in two languages: in the user's language for the GUI, and in
/// English for the log.
struct BilingualMessage: Equatable {
    let localized: String
    let english: String

    init(_ resource: LocalizedStringResource) {
        localized = String(localized: resource)
        english = String(english: resource)
    }

    /// A message about `error`. `message` gets the text of the error in the
    /// language that the message resolves to.
    init(_ message: (_ detail: String) -> LocalizedStringResource, error: Error) {
        localized = String(localized: message(error.localizedDescription))
        english = String(english: message(EnglishErrorText.describe(error)))
    }
}

/// An error that can say what went wrong in English, for the CLI and logs.
/// Its `localizedDescription` is in the user's language, for the GUI.
protocol EnglishDescribedError: Error {
    var englishDescription: String { get }
}

/// The text of an error in English, for the CLI and logs.
///
/// `localizedDescription` follows the language of the app. When the bundle
/// has a translation, Foundation also localizes its own errors (Cocoa, POSIX,
/// `DecodingError`), so the text of a system error would be Korean on a
/// Korean Mac. This function never uses that text.
enum EnglishErrorText {
    static func describe(_ error: Error) -> String {
        if let error = error as? EnglishDescribedError { return error.englishDescription }
        if let error = error as? DecodingError { return describe(error) }
        if isFoundationError(error) {
            let ns = error as NSError
            var text = "\(ns.domain) error \(ns.code)"
            if let path = ns.userInfo[NSFilePathErrorKey] as? String ?? (ns.userInfo[NSURLErrorKey] as? URL)?.path {
                text += " (\(path))"
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
                text += ": \(describe(underlying))"
            }
            return text
        }
        // A Swift error of a library (Yams) describes itself in English. Its
        // `localizedDescription` is only Foundation's localized
        // "The operation couldn't be completed" with the type name.
        return String(describing: error)
    }

    /// The debug description of a decoding error, which Foundation never
    /// localizes, and the path of the value that failed.
    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context? = switch error {
        case let .dataCorrupted(context),
             let .keyNotFound(_, context),
             let .typeMismatch(_, context),
             let .valueNotFound(_, context): context
        @unknown default: nil
        }
        guard let context else { return String(describing: error) }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }

    /// Whether `error` is an `NSError` of Foundation or the system, which
    /// Foundation localizes, and not a Swift error that only bridges to one.
    private static func isFoundationError(_ error: Error) -> Bool {
        type(of: error) is NSError.Type || error is CocoaError || error is POSIXError || error is URLError
    }
}
