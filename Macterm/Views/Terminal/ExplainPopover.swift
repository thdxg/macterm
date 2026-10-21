import AppKit
import SwiftUI

/// The popover of Explain Output: Apple's on-device model explains the
/// selection, or the output of the last command, at the text it explains.
///
/// An `NSPopover` with `.transient` behavior. It takes key when it opens, so
/// Escape closes it, ⌘C copies a selection of its text, and the Copy button
/// works with one click. When it closes, key goes back to the terminal's
/// window, whose first responder is still the pane. Closing it stops the
/// model. One popover for each pane view: a second request replaces the
/// first.
///
/// A new popover never opens while the old one is still closing: it waits
/// for `popoverDidClose`. When the old popover's window gave key back to the
/// terminal after the new one took it, AppKit closed the new transient
/// popover at once.
@MainActor
final class ExplainPopover: NSObject, NSPopoverDelegate {
    let model = ExplainPopoverModel()
    private var popover: NSPopover?
    private weak var anchorView: NSView?
    private var task: Task<Void, Never>?
    /// What runs when the popover of the current request closes.
    private var onClose: (() -> Void)?
    /// A request that waits for the old popover to close.
    private struct Pending {
        var anchor: NSRect
        var edge: NSRectEdge
        weak var view: NSView?
    }

    private var pending: Pending?

    var isShown: Bool {
        popover?.isShown ?? false
    }

    /// Explain `explanation` in a popover at `anchor`, on its `edge` side
    /// when there is room. `onClose` runs when that popover closes, or when
    /// a new request replaces this one.
    func show(
        _ explanation: OutputExplanation,
        anchor: NSRect,
        edge: NSRectEdge = .minY,
        in view: NSView,
        onClose: (() -> Void)? = nil
    ) {
        task?.cancel()
        task = nil
        self.onClose?()
        self.onClose = onClose
        model.start(source: explanation.source)
        present(at: anchor, edge: edge, in: view)
        guard explanation.hasText else {
            model.fail(String(localized: "There is no output to explain."))
            return
        }
        let stream = OnDeviceModel.stream(
            instructions: OutputExplanation.instructions,
            prompt: explanation.prompt,
            maximumResponseTokens: OutputExplanation.maximumReplyTokens
        )
        task = Task { [model] in
            do {
                for try await partial in stream {
                    model.receive(partial)
                }
                // A cancelled loop ends without an error.
                guard !Task.isCancelled else { return }
                model.finish()
            } catch is CancellationError {
                // Closed, or replaced by a new request.
            } catch {
                model.fail(Self.message(for: error))
            }
        }
    }

    func close() {
        pending = nil
        popover?.performClose(nil)
    }

    /// Run the current request's `onClose` now, and not again at close.
    /// Explain clears the selection that it made before it reads the next
    /// one, so that a second Explain does not take it for the user's.
    func dropOnClose() {
        onClose?()
        onClose = nil
    }

    private func present(at anchor: NSRect, edge: NSRectEdge, in view: NSView) {
        if let popover {
            // A new edge needs a new popover: `show` sets the edge.
            pending = Pending(anchor: anchor, edge: edge, view: view)
            if popover.isShown { popover.performClose(nil) }
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: ExplainPopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: anchor, of: view, preferredEdge: edge)
        popover.contentViewController?.view.window?.makeKey()
        self.popover = popover
        anchorView = view
    }

    /// Whether the popover held key as it began to close. Escape, Copy, or
    /// a click in its own text: key goes back to the terminal. A click in
    /// another window has made that window key already: it keeps key.
    private var closingWithKey = false

    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        closingWithKey = popover?.contentViewController?.view.window?.isKeyWindow ?? false
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
        if let window = anchorView?.window, window.isVisible, closingWithKey || NSApp.keyWindow == nil {
            window.makeKey()
        }
        closingWithKey = false
        anchorView = nil
        if let pending {
            // The request that replaced this one keeps its task.
            self.pending = nil
            if let view = pending.view {
                present(at: pending.anchor, edge: pending.edge, in: view)
                return
            }
        }
        task?.cancel()
        task = nil
        onClose?()
        onClose = nil
    }

    private static func message(for error: Error) -> String {
        switch error as? OnDeviceModel.Failure {
        case .unavailable:
            String(localized: "Apple Intelligence is not available. Turn it on in System Settings.")
        case .tooLong:
            String(localized: "The text is too long to explain. Select a shorter part, then try again.")
        case .refused:
            String(localized: "Apple Intelligence did not explain this text.")
        case .other,
             nil:
            String(localized: "Macterm could not explain this text. Try again.")
        }
    }
}

@MainActor
@Observable
final class ExplainPopoverModel {
    enum Phase: String {
        case waiting
        case streaming
        case done
        case failed
    }

    private(set) var phase = Phase.waiting
    private(set) var source = OutputExplanation.Source.selection
    /// The reply so far, or the failure message.
    private(set) var text = ""

    func start(source: OutputExplanation.Source) {
        self.source = source
        phase = .waiting
        text = ""
    }

    func receive(_ partial: String) {
        text = partial
        phase = .streaming
    }

    func finish() {
        phase = text.isEmpty ? .failed : .done
        if text.isEmpty { text = String(localized: "Macterm could not explain this text. Try again.") }
    }

    func fail(_ message: String) {
        text = message
        phase = .failed
    }
}

struct ExplainPopoverView: View {
    let model: ExplainPopoverModel

    static let width: CGFloat = 420
    static let maximumTextHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            footer
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    private var header: some View {
        Label {
            Text(model.source == .selection ? "Explain Selection" : "Explain Output")
                .font(.headline)
        } icon: {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .waiting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Explaining…")
                    .foregroundStyle(.secondary)
            }
        case .streaming,
             .done:
            ScrollView {
                Text(Self.rendered(model.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: Self.maximumTextHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .failed:
            Text(verbatim: model.text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.phase == .done {
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }
                .controlSize(.small)
            }
        }
    }

    /// The reply with its inline Markdown (backticks, bold) drawn, or as
    /// plain text when it does not parse — a reply that is still streaming
    /// can end in the middle of a mark.
    static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
