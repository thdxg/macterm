import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "AppIconPresenter")

/// The one place the app icon is written. `GhosttyApp` decides what the config
/// asks for (`GhosttyAppIcon`) on every load and reload; this installs it.
///
/// `NSApp.applicationIconImage` is the API Ghostty documents for its
/// `macos-icon` key: it changes the Dock tile and the app switcher, never the
/// bundle's icon in Finder. Assigning nil restores the bundle icon, which is
/// how an unset key, a bad path or an undecodable file all revert. Ghostty's
/// Dock-tile plugin (which redraws the icon while the app isn't running) is
/// deliberately not mirrored.
@MainActor
enum AppIconPresenter {
    /// What is installed right now. Lets a reload that keeps the bundled icon
    /// skip the AppKit write entirely — the common case for anyone who never
    /// set the key — while a custom icon is re-read on every reload so an
    /// edited image file is picked up the way Ghostty picks it up.
    private static var installed: GhosttyAppIcon = .bundled

    static func apply(_ icon: GhosttyAppIcon) {
        switch icon {
        case .bundled:
            guard installed != .bundled else { return }
            install(nil, as: .bundled)
        case let .custom(url):
            guard let image = loadImage(at: url) else {
                install(nil, as: .bundled)
                return
            }
            install(image, as: icon)
            logger.info("app icon set from \(url.path, privacy: .public)")
        }
    }

    private static func install(_ image: NSImage?, as icon: GhosttyAppIcon) {
        NSApp.applicationIconImage = image
        installed = icon
    }

    /// Read and decode the file, logging why it can't be used. Two steps rather
    /// than `NSImage(contentsOf:)` so a missing or unreadable file reports
    /// differently from a file that isn't an image.
    private static func loadImage(at url: URL) -> NSImage? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let reason = error.localizedDescription
            logger.warning(
                "macos-custom-icon \(url.path, privacy: .public) is unreadable, keeping the bundled icon: \(reason, privacy: .public)"
            )
            return nil
        }
        guard let image = NSImage(data: data), image.isValid, !image.representations.isEmpty else {
            logger.warning("macos-custom-icon \(url.path, privacy: .public) is not an image, keeping the bundled icon")
            return nil
        }
        return image
    }
}
