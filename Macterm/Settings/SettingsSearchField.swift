import SwiftUI

/// The search field of every Settings list (saved passwords, keybinds,
/// extensions) — one view, so they read the same wherever they sit. Drawn in
/// SwiftUI rather than `NSSearchField`, whose height is fixed by its control
/// size and leaves no room for padding. Its height is that of a `.large`
/// control, so a large picker beside it lines up.
struct SettingsSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringResource

    @FocusState
    private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(text: $text) { Text(prompt) }
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            Capsule().strokeBorder(
                isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                lineWidth: isFocused ? 2 : 1
            )
        )
        .contentShape(Capsule())
        .onTapGesture { isFocused = true }
    }
}
