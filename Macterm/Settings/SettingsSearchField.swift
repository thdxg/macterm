import AppKit
import SwiftUI

/// AppKit's search field for a Settings list (saved passwords, keybinds,
/// extensions) — SwiftUI has no standalone one on macOS outside
/// `.searchable`, which would put it in the Settings window's toolbar.
/// Every one is a `.large` control, for room around its text; a picker
/// beside one takes `.large` too, so the two line up.
struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: LocalizedStringResource

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .large
        field.placeholderString = String(localized: prompt)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context _: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
