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
/// next keystroke lands in the pane.
@MainActor
final class PasswordBubble: NSObject, NSPopoverDelegate {
    enum Content: Equatable {
        case autofill(PasswordEntryID, busy: Bool)
        case rejected(PasswordEntryID)
        case save(PasswordEntryID, isUpdate: Bool)
    }

    struct Actions {
        var autofill: @MainActor () -> Void = {}
        var dismiss: @MainActor () -> Void = {}
        var save: @MainActor () -> Void = {}
        var cancelOffer: @MainActor () -> Void = {}
        var removeSaved: @MainActor () -> Void = {}
    }

    var actions = Actions() {
        didSet { model.actions = wrapped(actions) }
    }

    private let model = PasswordBubbleModel()
    private var popover: NSPopover?
    private weak var anchorView: NSView?

    /// Show `content` at `anchor` (in `view`'s coordinates), move the arrow
    /// if the popover is already up, or close it when either is nil.
    func show(_ content: Content?, anchor: NSRect?, in view: NSView) {
        guard let content, let anchor else {
            close()
            return
        }
        if model.content != content { model.content = content }
        if let popover, popover.isShown, anchorView === view {
            if popover.positioningRect != anchor { popover.positioningRect = anchor }
            return
        }
        close()
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
        Self.returnKey(to: view)
    }

    func close() {
        popover?.close()
        popover = nil
        anchorView = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
        anchorView = nil
    }

    /// Hand key back to the window `view` lives in, if something of ours (the
    /// popover, the authentication sheet) took it. The window keeps its own
    /// first responder, so this restores whichever pane had focus.
    static func returnKey(to view: NSView) {
        guard let window = view.window, window.isVisible, NSApp.keyWindow !== window else { return }
        window.makeKey()
    }

    private func wrapped(_ actions: Actions) -> Actions {
        let refocus: @MainActor () -> Void = { [weak self] in
            if let view = self?.anchorView { Self.returnKey(to: view) }
        }
        return Actions(
            autofill: { actions.autofill() },
            dismiss: {
                refocus()
                actions.dismiss()
            },
            save: {
                refocus()
                actions.save()
            },
            cancelOffer: {
                refocus()
                actions.cancelOffer()
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
                    if let shortcut = Self.autofillShortcut {
                        Text(shortcut)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Autofill Password")
                    }
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
                    Button("OK") { model.actions.dismiss() }
                }
            case let .save(id, isUpdate):
                header(
                    symbol: "key.fill",
                    title: isUpdate ? "Update Saved Password?" : "Save Password?",
                    detail: "Macterm can fill it in the next time this prompt appears."
                )
                entry(id, showsSecret: true)
                HStack {
                    Spacer()
                    Button("Cancel") { model.actions.cancelOffer() }
                    Button(isUpdate ? "Update" : "Save") { model.actions.save() }
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

    /// The Autofill Password chord, as the menus draw it, or nil when unbound.
    private static var autofillShortcut: String? {
        let raw = HotkeyRegistry.selectedShortcutString(for: .autofillPassword)
        guard HotkeyRegistry.parseShortcut(raw) != nil else { return nil }
        return HotkeyRegistry.displayString(for: raw)
    }
}
