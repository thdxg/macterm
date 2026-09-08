import Foundation

/// The process-wide C locale, which libghostty rewrites and this app must
/// partly take back.
///
/// A Cocoa app never touches the C locale: it stays at the default `C`, and
/// Foundation formats numbers through `Locale` instead. libghostty is not a
/// Cocoa app. `ghostty_init` runs `ensureLocale`, which on a GUI launch (no
/// `LANG` in the environment) derives `LANG` from the system locale and then
/// calls `setlocale(LC_ALL, "")` — so after init this process is in, say,
/// `pl_PL.UTF-8`, decimal comma included. That is what ghostty wants for the
/// *shells it spawns*, and they get it from the `LANG` it exported, not from
/// the parent's C locale; the C locale change itself buys the app nothing.
///
/// It costs the app its launch on macOS 27 (#370). SwiftUI renders the
/// `NavigationSplitView` sidebar toggle's `sidebar.leading` glyph into a
/// template `NSImage` through RenderBox → CoreUI, and somewhere on that path
/// a number is parsed with a C-locale-sensitive function: under any comma-
/// decimal `LC_NUMERIC` (pl, de, fr, ru — not en_US, C.UTF-8 or de_CH) CoreUI
/// computes a 0×0 target size and asserts
/// (`CUINamedVectorGlyph.m:2599 … targetSizeInPoints.width>0 &&
/// targetSizeInPoints.height>0`). The exception is raised inside an AppKit
/// layout pass, which `+[NSApplication _crashOnException:]` turns into a
/// SIGTRAP with nothing on stderr — `NSApplicationCrashOnExceptions` does not
/// gate it. A 25-line SwiftUI app with one `setlocale(LC_NUMERIC, "pl_PL.UTF-8")`
/// reproduces it 100%; in Macterm it depends on toolbar-build timing, so a
/// populated prefs domain hides it and a fresh install shows it. The English-
/// speaking world never sees it because en_US has a period.
///
/// The fix is the one category the bug reads: pin `LC_NUMERIC` back to `C`
/// once `ghostty_init` has returned. Nothing in this process wants a
/// localized C numeric locale — Swift and Foundation ignore it, Zig's `std.fmt`
/// ignores it, and ghostty's own reason for `setlocale` is `LC_MESSAGES`
/// (gettext), which is left alone. The environment is not touched either, so
/// every pane's shell still inherits the user's full `LANG`.
enum ProcessLocale {
    /// The C locale libghostty leaves behind is the user's; this puts
    /// `LC_NUMERIC` back to the `C` every Cocoa app runs with. Returns the
    /// numeric locale that was in effect, for the launch log.
    @discardableResult
    static func pinNumericToC() -> String {
        let previous = setlocale(LC_NUMERIC, nil).map { String(cString: $0) } ?? "C"
        setlocale(LC_NUMERIC, "C")
        return previous
    }

    /// The current `LC_NUMERIC`, as `setlocale` reports it.
    static var currentNumeric: String {
        setlocale(LC_NUMERIC, nil).map { String(cString: $0) } ?? "C"
    }
}
