import AppKit

/// The alerts that carry out an `UntrustedURL` decision: a confirmation before
/// a custom scheme reaches its handler, and the notice for a refused target.
/// Both show the target through `UntrustedURL.displayString`, never the raw
/// string. Ported from upstream Ghostty's `UntrustedURLAlert`.
@MainActor
enum UntrustedURLAlert {
    static func presentConfirmation(for url: URL, displayString: String, in window: NSWindow?) {
        let workspace = NSWorkspace.shared
        let handler = workspace.urlForApplication(toOpen: url)
            .map { "\u{201C}\($0.deletingPathExtension().lastPathComponent)\u{201D}" }
            ?? "the default application"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.messageText = "Open Link from Terminal Output?"
        alert.informativeText = "This link will open in \(handler). "
            + "Only continue if you recognize and trust the destination."
        alert.accessoryView = targetView(displayString)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Link")

        present(alert, in: window) { response in
            // Cancel is deliberately the default button.
            guard response == .alertSecondButtonReturn else { return }
            workspace.open(url)
        }
    }

    static func presentBlock(reason: UntrustedURL.DenialReason, displayString: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.messageText = "\(appDisplayName) Blocked This Link"
        alert.informativeText = reason.message
        alert.accessoryView = targetView(displayString)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Link")

        present(alert, in: window) { response in
            // A blocked target never reaches Launch Services. Copying the
            // shown, sanitized value is a deliberate way forward without a
            // one-click bypass of the policy.
            guard response == .alertSecondButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(displayString, forType: .string)
        }
    }

    /// A sheet on the window of the pane whose link was clicked, else a modal.
    /// A modal in an inactive app never comes forward, so the app is
    /// activated for it first.
    private static func present(
        _ alert: NSAlert,
        in window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            NSApp.activate()
            completion(alert.runModal())
        }
    }

    /// The target in a selectable, scrollable monospaced box, so a long URL
    /// is shown whole rather than truncated where the deception could hide.
    private static func targetView(_ target: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = target
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        return scrollView
    }
}
