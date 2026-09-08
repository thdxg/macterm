import Foundation
@testable import Macterm
import Testing

/// `ProcessLocale` undoes exactly one category of libghostty's
/// `setlocale(LC_ALL, "")` — the one macOS 27's SwiftUI toolbar trips over
/// (#370) — and leaves the rest of what ghostty asked for in place.
///
/// The C locale is process-global state, so this suite is serialized and
/// restores the default `C` locale on the way out; nothing else in the test
/// process reads the C locale (Swift and Foundation don't), but a parallel
/// run of this suite against itself would.
@Suite(.serialized)
struct ProcessLocaleTests {
    /// A comma-decimal locale macOS ships. Skipped rather than failed where the
    /// locale definition is missing, since the test is about our behavior, not
    /// the OS's locale catalog.
    private static let commaLocale = "pl_PL.UTF-8"

    private func withLibghosttyStyleLocale(_ body: () -> Void) throws {
        // Same call libghostty's ensureLocale makes once LANG is populated.
        try #require(setlocale(LC_ALL, Self.commaLocale) != nil, "locale \(Self.commaLocale) unavailable on this host")
        defer { setlocale(LC_ALL, "C") }
        body()
    }

    @Test
    func pins_numeric_back_to_C_and_reports_what_it_replaced() throws {
        try withLibghosttyStyleLocale {
            #expect(ProcessLocale.currentNumeric == Self.commaLocale)
            #expect(String(cString: localeconv().pointee.decimal_point) == ",")

            let previous = ProcessLocale.pinNumericToC()

            #expect(previous == Self.commaLocale)
            #expect(ProcessLocale.currentNumeric == "C")
            // The property the macOS 27 CoreUI bug actually depends on.
            #expect(String(cString: localeconv().pointee.decimal_point) == ".")
        }
    }

    @Test
    func leaves_every_other_category_as_libghostty_set_it() throws {
        try withLibghosttyStyleLocale {
            ProcessLocale.pinNumericToC()

            // ghostty's own reason for the setlocale is gettext (LC_MESSAGES);
            // the user-visible categories a child would care about are the
            // environment's business, but nothing here may regress them either.
            for category in [LC_MESSAGES, LC_COLLATE, LC_CTYPE, LC_TIME, LC_MONETARY] {
                let value = setlocale(category, nil).map { String(cString: $0) }
                #expect(value == Self.commaLocale, "category \(category) was disturbed")
            }
        }
    }

    @Test
    func is_idempotent_and_harmless_on_the_default_locale() {
        setlocale(LC_ALL, "C")
        #expect(ProcessLocale.pinNumericToC() == "C")
        #expect(ProcessLocale.pinNumericToC() == "C")
        #expect(ProcessLocale.currentNumeric == "C")
    }
}
