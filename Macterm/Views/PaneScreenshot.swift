import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "PaneScreenshot")

/// Capture Pane: copies the focused pane to the clipboard as an image.
///
/// The image is the pane's own rendered frame (`PanePreviewCapture`, the
/// frame the tab switcher shows), not the screen under the pane. It is
/// opaque: the pane's effective background fills the cells that ghostty
/// leaves transparent, so window opacity, blur and glass never show, and
/// nothing behind the window can show through. It also needs no Screen
/// Recording. The cursor stays as the frame drew it.
@MainActor
enum PaneScreenshot {
    static func copy(_ pane: Pane, appState: AppState) {
        let preview = PanePreviewCapture.capture(pane, longEdge: nil, fillsBackground: true)
        guard let image = preview.image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            logger.info("capture pane: no rendered frame")
            appState.presentToast("Cannot capture the pane", subtitle: "The pane has no frame yet. Try again.")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        // Points, not pixels: the PNG then carries the display's DPI, as a
        // macOS screenshot does, and pastes at the size it had on screen.
        if let size = preview.pointSize { rep.size = size }
        guard let png = rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation
        else {
            appState.presentToast("Cannot capture the pane", subtitle: "Macterm could not encode the image.")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
        appState.presentToast("Pane copied to the clipboard")
    }
}
