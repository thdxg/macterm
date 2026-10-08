import AppKit
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: appBundleID, category: "PaletteScreenshot")

/// Capture Palette Screenshot: the command palette as it is on screen, framed
/// the same way every time (`MactermExtension.screenshotRect`) and written as
/// a PNG of exactly `MactermExtension.screenshotPixelSize` — the screenshot
/// an extension in the repository must have, so every one in the gallery is
/// the same size whatever its theme. Raycast's Window Capture is the model.
///
/// It is the screen that is captured, not the view drawn again: the palette's
/// glass shows what is behind it, which neither `ImageRenderer` nor
/// `cacheDisplay` can draw. That takes macOS's Screen Recording permission,
/// asked for the first time.
@MainActor
enum PaletteScreenshot {
    /// Captures the key window's palette and asks where to save it. With the
    /// palette down (the menu, the palette's own row) it opens the palette
    /// first and captures its first screen once it is drawn; a deeper
    /// screen is captured by this command's keybind, pressed on it.
    static func capture(appState: AppState) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            appState.presentToast(
                "Macterm needs Screen Recording to capture the palette",
                subtitle: "Allow it in System Settings → Privacy & Security, then try again."
            )
            return
        }
        guard let windowState = appState.keyWindow ?? appState.windows.first else { return }
        if windowState.isCommandPaletteVisible, windowState.paletteAnchor?.window != nil {
            Task { await captureAndSave(windowState: windowState, appState: appState) }
            return
        }
        appState.isCommandPaletteVisible = true
        Task {
            // Long enough for the panel to mount and its first rows to draw.
            try? await Task.sleep(for: .milliseconds(400))
            await captureAndSave(windowState: windowState, appState: appState)
        }
    }

    private static func captureAndSave(windowState: WindowState, appState: AppState) async {
        guard let anchor = windowState.paletteAnchor, let window = anchor.window, let screen = window.screen else {
            appState.presentToast("Open the command palette to capture it")
            return
        }
        let palette = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let rect = MactermExtension.screenshotRect(around: palette, in: screen.frame)
        let folder = defaultFolder(windowState: windowState, appState: appState)
        do {
            let png = try await capture(rect: rect, on: screen)
            save(png, suggestedFolder: folder, appState: appState)
        } catch {
            logger.error("palette screenshot: \(error.localizedDescription, privacy: .public)")
            appState.presentToast("Couldn't capture the palette", subtitle: error.localizedDescription)
        }
    }

    /// `rect` (AppKit screen coordinates, on `screen`) as a PNG of exactly
    /// the screenshot size, without the pointer.
    private static func capture(rect: CGRect, on screen: NSScreen) async throws -> Data {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID else { throw CaptureError.noDisplay }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let size = MactermExtension.screenshotPixelSize
        let configuration = SCStreamConfiguration()
        // ScreenCaptureKit's source rect is in the display's points, from its
        // top-left corner; AppKit's screen coordinates run up from the bottom.
        configuration.sourceRect = CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try png(image, width: size.width, height: size.height)
    }

    /// `image` drawn into exactly `width`×`height`, as PNG data — whatever
    /// size the capture came back at, the file is the size the rule names.
    private static func png(_ image: CGImage, width: Int, height: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw CaptureError.encoding }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let fitted = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: fitted).representation(using: .png, properties: [:])
        else { throw CaptureError.encoding }
        return data
    }

    /// The open palette's own `screenshots/` folder when it is an installed
    /// extension; the Desktop otherwise, where macOS puts screenshots.
    private static func defaultFolder(windowState: WindowState, appState: AppState) -> URL {
        let paletteID = windowState.paletteStack.lazy.compactMap { frame -> String? in
            if case let .custom(target) = frame.scopeID { return target.paletteID }
            return nil
        }.first
        if let paletteID, let folder = appState.customPalettes.entry(id: paletteID)?.extensionDirectory {
            return folder.appendingPathComponent(MactermExtension.screenshotsFolder, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private static func save(_ png: Data, suggestedFolder: URL, appState: AppState) {
        try? FileManager.default.createDirectory(at: suggestedFolder, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.title = "Save Palette Screenshot"
        panel.message = "Extensions keep their screenshots in a screenshots folder beside palette.yaml."
        panel.allowedContentTypes = [.png]
        panel.directoryURL = suggestedFolder
        panel.nameFieldStringValue = MactermExtension.nextScreenshotName(in: suggestedFolder)
        panel.canCreateDirectories = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try png.write(to: url, options: .atomic)
                    appState.presentToast("Screenshot saved", subtitle: url.lastPathComponent)
                } catch {
                    appState.presentToast("Couldn't save the screenshot", subtitle: error.localizedDescription)
                }
            }
        }
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case encoding
        var errorDescription: String? {
            switch self {
            case .noDisplay: "The palette's display can't be captured."
            case .encoding: "The capture couldn't be written as a PNG."
            }
        }
    }
}

/// Puts an invisible view under the palette and its breadcrumb row and hands
/// it to the window's state, so a capture can find where the palette is on
/// screen. It takes no clicks.
struct PaletteScreenshotAnchor: NSViewRepresentable {
    let windowState: WindowState

    func makeNSView(context _: Context) -> NSView {
        let view = AnchorView()
        windowState.paletteAnchor = view
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        windowState.paletteAnchor = view
    }

    private final class AnchorView: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
}
