import AppKit

/// An empty view that reports the first window it moves into.
///
/// For a representable that must act on its `NSWindow` (`WindowStyler`).
/// SwiftUI can make the view before its window exists, so `makeNSView` cannot
/// read `view.window`. Do not poll for the window with a limit on the number
/// of main-queue turns: an idle main queue runs 30 turns in a few
/// milliseconds. `WindowStyler` did that, and a window that `window new`
/// opened during launch got its view about 30 ms before its window. That
/// window never registered with `AppState`: it showed its sidebar and no
/// terminal, and `window list` did not show it.
///
/// `onAttach` runs one time, asynchronously, because AppKit can attach the
/// view inside a SwiftUI update pass, where window and state changes are not
/// allowed. A view that is never attached never calls it.
final class WindowAttachmentView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let onAttach else { return }
        self.onAttach = nil
        DispatchQueue.main.async { onAttach(window) }
    }
}
