import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ExceptionReporting")

/// Last-chance logging for uncaught Objective-C exceptions.
///
/// An NSException nobody catches doesn't crash-report: it unwinds to
/// HIToolbox's top-level handler, which logs `FAULT: <name>: <private>` —
/// reason redacted — and exits the process. No signal means ReportCrash never
/// writes an .ips, so the redacted FAULT line is the entire postmortem. The
/// one observed in the wild (2026-07-28, ViewBridge throwing out of the quick
/// terminal's makeKeyAndOrderFront) left nothing to debug with. This handler
/// records the full name, reason, and backtrace at error level — which
/// persists in the unified log unlike our info-level messages — before the
/// process dies.
enum ExceptionReporting {
    /// Preserved so install() composes with any handler registered before us
    /// (e.g. XCTest's, when the app is hosting the test bundle).
    nonisolated(unsafe) private static var previousHandler: (@convention(c) (NSException) -> Void)?

    static func install() {
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // @convention(c) — no captures allowed; globals/statics only.
            logger
                .error(
                    "Uncaught exception \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "no reason", privacy: .public)"
                )
            logger.error("Backtrace:\n\(exception.callStackSymbols.joined(separator: "\n"), privacy: .public)")
            ExceptionReporting.previousHandler?(exception)
        }
    }
}
