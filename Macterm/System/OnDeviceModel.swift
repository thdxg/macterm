import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import os

private let logger = Logger(subsystem: appBundleID, category: "OnDeviceModel")

/// Apple's on-device language model (FoundationModels). This is the only
/// file that imports the framework, so the rest of the app compiles and runs
/// the same on macOS 14.
///
/// The model needs macOS 26, a Mac that supports Apple Intelligence, and
/// Apple Intelligence turned on. Nothing that it reads leaves the Mac.
@MainActor
enum OnDeviceModel {
    enum Availability: Equatable {
        /// This macOS or this Mac cannot run the model.
        case unsupported
        /// The Mac can run the model, but it is not ready: Apple Intelligence
        /// is off, or the model is still downloading.
        case notReady
        case available
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unsupported
            case .unavailable: return .notReady
            }
        }
        #endif
        return .unsupported
    }

    /// Why a request failed, as the user reads it.
    enum Failure: Error, Equatable {
        case unavailable
        /// The input and the reply did not fit the context window.
        case tooLong
        /// The model's safety rules refused the text.
        case refused
        case other
    }

    /// Stream the reply to `prompt`. Each element is the whole reply so far.
    /// Every request has a new session: a session keeps its transcript, and a
    /// transcript that grows fills the context window for good. Cancel the
    /// consuming task to stop the model.
    static func stream(
        instructions: String,
        prompt: String,
        maximumResponseTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), availability == .available else {
            continuation.finish(throwing: Failure.unavailable)
            return stream
        }
        let task = Task { @MainActor in
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: maximumResponseTokens)
            do {
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    continuation.yield(snapshot.content)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch let error as LanguageModelSession.GenerationError {
                logger.info("generation failed: \(EnglishErrorText.describe(error), privacy: .public)")
                continuation.finish(throwing: failure(for: error))
            } catch {
                logger.info("generation failed: \(EnglishErrorText.describe(error), privacy: .public)")
                continuation.finish(throwing: Failure.other)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        #else
        continuation.finish(throwing: Failure.unavailable)
        #endif
        return stream
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func failure(for error: LanguageModelSession.GenerationError) -> Failure {
        switch error {
        case .exceededContextWindowSize: .tooLong
        case .guardrailViolation,
             .refusal: .refused
        case .assetsUnavailable: .unavailable
        default: .other
        }
    }
    #endif

    /// The English name of the app's language for a reply, or nil for
    /// English. The model writes English when the prompt does not say.
    static var replyLanguage: String? {
        guard let code = Bundle.main.preferredLocalizations.first, !code.hasPrefix("en") else { return nil }
        return Locale(identifier: "en").localizedString(forIdentifier: code)
    }
}
