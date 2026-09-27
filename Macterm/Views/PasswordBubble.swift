import AppKit
import SwiftUI

/// The popover a password prompt gets, pointing at the cursor — the end of
/// the prompt line — the way Safari's autofill bubble points at a password
/// field. An `NSPopover` with `.applicationDefined` behavior: clicking in the
/// terminal doesn't close it (typing the password there is expected); the
/// monitor closes it when there is nothing left to offer.
///
/// It never keeps keyboard focus. Showing it doesn't take key, and when a
/// click on one of its buttons makes the popover's own window key, the action
/// hands key straight back to the terminal's window (`returnKey`), so the
/// next keystroke lands in the pane. Return and Escape reach it through the
/// terminal's own key path (`PasswordPromptMonitor`), never as popover
/// shortcuts, which is why the buttons carry no key hints.
@MainActor
class PasswordBubble: NSObject, NSPopoverDelegate {
    enum Content: Equatable {
        case autofill(PasswordEntryID, busy: Bool)
        case rejected(PasswordEntryID)
        /// `problem` is a keychain write that failed; the offer stays up
        /// with it until the user retries or cancels.
        case save(PasswordEntryID, isUpdate: Bool, problem: String?)
    }

    struct Actions {
        /// Save / Update / OK — what Return does.
        var primary: @MainActor () -> Void = {}
        var autofill: @MainActor () -> Void = {}
        /// Not Now / Cancel — what Escape does.
        var dismiss: @MainActor () -> Void = {}
        var removeSaved: @MainActor () -> Void = {}
    }

    var actions = Actions() {
        didSet { model.actions = wrapped(actions) }
    }

    private let model = PasswordBubbleModel()
    private var popover: NSPopover?
    private weak var anchorView: NSView?
    /// What the bubble last said, kept across an off-screen spell (anchor
    /// nil: the cursor scrolled away, the tab hidden) so coming back is not
    /// mistaken for a new bubble.
    private var lastContent: Content?

    /// True while a popover is on screen. Tracked here rather than read off
    /// the popover so a test double can stand in (`present`/`dismiss` are
    /// the AppKit seams).
    private(set) var isShown = false

    /// Show `content` at `anchor` (in `view`'s coordinates), move the arrow
    /// if the popover is already up, or close it when either is nil. Returns
    /// true when the bubble now says something it didn't before — a new
    /// bubble, or new content in one — and false for a re-anchor of the same
    /// content, which is what lets the monitor tell "typed under this
    /// bubble" apart from "scrolled away and back".
    @discardableResult
    func show(_ content: Content?, anchor: NSRect?, in view: NSView) -> Bool {
        guard let content else {
            close()
            return false
        }
        let changed = content != lastContent
        lastContent = content
        if model.content != content { model.content = content }
        guard let anchor else {
            dismiss()
            return changed
        }
        present(at: anchor, in: view)
        isShown = true
        return changed
    }

    func close() {
        dismiss()
        lastContent = nil
    }

    private func dismiss() {
        isShown = false
        tearDown()
    }

    /// Put the popover up at `anchor`, or move it there. Overridden by the
    /// test double.
    func present(at anchor: NSRect, in view: NSView) {
        if let popover, popover.isShown, anchorView === view {
            if popover.positioningRect != anchor { popover.positioningRect = anchor }
            return
        }
        tearDown()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PasswordBubbleView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        self.popover = popover
        anchorView = view
        returnKey(to: view)
    }

    /// Take the popover down. Overridden by the test double.
    func tearDown() {
        popover?.close()
        popover = nil
        anchorView = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
        anchorView = nil
        isShown = false
    }

    /// Hand key back to the window `view` lives in when the popover took it
    /// (a click on a button) or nothing holds it (the authentication sheet
    /// just closed). Never when another window of ours is key: a save offer
    /// arriving in a window the user has left must not pull them back. The
    /// window keeps its own first responder, so whichever pane had focus
    /// gets it.
    func returnKey(to view: NSView) {
        guard let window = view.window, window.isVisible, NSApp.keyWindow !== window else { return }
        let popoverWindow = popover?.contentViewController?.view.window
        guard NSApp.keyWindow == nil || NSApp.keyWindow === popoverWindow else { return }
        window.makeKey()
    }

    private func wrapped(_ actions: Actions) -> Actions {
        let refocus: @MainActor () -> Void = { [weak self] in
            if let self, let view = anchorView { returnKey(to: view) }
        }
        return Actions(
            primary: {
                refocus()
                actions.primary()
            },
            autofill: { actions.autofill() },
            dismiss: {
                refocus()
                actions.dismiss()
            },
            removeSaved: {
                refocus()
                actions.removeSaved()
            }
        )
    }
}

@MainActor
@Observable
final class PasswordBubbleModel {
    var content: PasswordBubble.Content?
    @ObservationIgnored var actions = PasswordBubble.Actions()
}

private struct PasswordBubbleView: View {
    let model: PasswordBubbleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.content {
            case let .autofill(id, busy):
                header(
                    symbol: "key.fill",
                    title: "Password Prompt Detected",
                    detail: "A password is saved for this prompt."
                )
                entry(id)
                HStack {
                    Spacer()
                    Button("Not Now") { model.actions.dismiss() }
                    Button("Autofill") { model.actions.autofill() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            case let .rejected(id):
                header(
                    symbol: "key.slash",
                    title: "Saved Password Didn’t Work",
                    detail: "Type the password. Once it works, Macterm offers to update the saved one."
                )
                entry(id)
                HStack {
                    Button("Remove Saved Password", role: .destructive) { model.actions.removeSaved() }
                    Spacer()
                    Button("OK") { model.actions.primary() }
                        .buttonStyle(.borderedProminent)
                }
            case let .save(id, isUpdate, problem):
                header(
                    symbol: "key.fill",
                    title: isUpdate ? "Update Saved Password?" : "Save Password?",
                    detail: "Macterm can fill it in the next time this prompt appears."
                )
                entry(id, showsSecret: true)
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(MactermTheme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 34)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.actions.dismiss() }
                    Button(isUpdate ? "Update" : "Save") { model.actions.primary() }
                        .buttonStyle(.borderedProminent)
                }
            case nil:
                EmptyView()
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The command-and-prompt pair the password is filed under.
    private func entry(_ id: PasswordEntryID, showsSecret: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let command = id.displayCommand {
                Text(command)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(id.prompt)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if showsSecret {
                Text(verbatim: "••••••••")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Password")
            }
        }
        .padding(.leading, 34)
    }
}
