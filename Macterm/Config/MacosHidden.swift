import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "MacosHidden")

/// The user's ghostty `macos-hidden`: whether Macterm runs as an **accessory**
/// app — no Dock tile, no menu bar, absent from ⌘-Tab. Ghostty ships it for
/// "those primarily using quick-terminal mode", and it means the same here.
///
/// The value → policy mapping is a pure function so it can be tested without
/// an `NSApp`; applying it is `AppDelegate.applyActivationPolicy`, at launch
/// and again on every config reload (the same two moments Ghostty.app applies
/// it).
///
/// The raw values are ghostty's own enum tag names (`src/config/Config.zig`'s
/// `MacHidden`), because that is exactly what `ghostty_config_get` hands back
/// for an enum-valued key — so they are a wire contract with libghostty, not
/// names of ours.
enum MacosHidden: String, CaseIterable {
    /// Ghostty's default: an ordinary foreground app.
    case never
    /// Accessory: no Dock tile, no menu bar, no ⌘-Tab entry.
    case always

    static let key = "macos-hidden"

    /// An unset, empty, unreadable, or unrecognized value means `never` —
    /// ghostty's default *and* its own fallback for a value it can't parse, so
    /// a key a newer ghostty grew a third case for degrades to the visible app
    /// rather than to an invisible one.
    static func resolve(configValue: String?) -> MacosHidden {
        guard let raw = configValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .never
        }
        return MacosHidden(rawValue: raw.lowercased()) ?? .never
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .never: .regular
        case .always: .accessory
        }
    }

    /// Whether the app has no Dock tile and no ⌘-Tab entry *right now*.
    ///
    /// Asked of AppKit rather than of the config: it is the state that decides
    /// whether a window can be reached, and it stays right across a reload
    /// nobody has applied yet.
    @MainActor
    static var isRunningAsAccessory: Bool {
        NSApp.activationPolicy() == .accessory
    }

    /// Activate the app when a window is being put on screen for an explicit
    /// request (CLI `window new`/`window focus`, a revealed project) and the
    /// app is an accessory.
    ///
    /// An accessory app receives no Dock click and cannot be ⌘-Tabbed to, so a
    /// window merely ordered front while the app is inactive can be looked at
    /// but never typed into, and the user has no route left to finish the job
    /// by hand. A regular app is left alone here on purpose: it keeps both of
    /// those routes, and activating on every CLI call would let a script steal
    /// focus from the terminal the user is actually in.
    ///
    /// `ignoringOtherApps: true` is load-bearing and not a leftover, measured
    /// against a hermetic instance while another app held the front: plain
    /// `NSApp.activate()` was **refused** (silently — the window came forward
    /// unfocused), and so was a cross-process
    /// `NSRunningApplication.activate(options:)` from a second app, both by
    /// macOS's cooperative activation, which only lets an app front itself
    /// while it holds an activation right. The forcing overload took the front.
    /// This is the same call Ghostty.app makes when it has to front itself.
    @MainActor
    static func activateForWindowRequest() {
        guard isRunningAsAccessory else { return }
        NSApp.activate(ignoringOtherApps: true)
        logger.info("accessory window request: active=\(NSApp.isActive, privacy: .public)")
    }
}
