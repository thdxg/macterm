import SwiftUI

struct TerminalSearchBar: View {
    @Bindable
    var searchState: TerminalSearchState
    let onNavigateNext: () -> Void
    let onNavigatePrevious: () -> Void
    let onClose: () -> Void
    @FocusState
    private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(MactermTheme.fgMuted)
                    TextField("Search", text: $searchState.needle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(MactermTheme.fg)
                        .focused($isFieldFocused)
                        .onSubmit { onNavigateNext() }
                        .onChange(of: searchState.needle) { searchState.pushNeedle() }
                    if !searchState.displayText.isEmpty {
                        Text(searchState.displayText)
                            .font(.system(size: 10))
                            .foregroundStyle(MactermTheme.fgMuted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(MactermTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MactermTheme.border, lineWidth: 1))

                Button(action: onNavigateNext) {
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                }.buttonStyle(SearchButtonStyle())
                Button(action: onNavigatePrevious) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }.buttonStyle(SearchButtonStyle())
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }.buttonStyle(SearchButtonStyle())
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Color.clear)
            Rectangle().fill(MactermTheme.border).frame(height: 1)
        }
        .onAppear { isFieldFocused = true }
        .onKeyPress(.escape) { onClose()
            return .handled
        }
        // Ghostty search walks newest→oldest: `next` moves up the scrollback,
        // `previous` back down. Enter = up (onSubmit above), Shift+Enter = down.
        .onKeyPress(keys: [.return]) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            onNavigatePrevious()
            return .handled
        }
        // Cmd+F again while the bar is open (and the search field has focus)
        // closes it — a toggle. When the terminal surface has focus instead,
        // the keystroke reaches ghostty's start_search binding, which
        // onSearchStart toggles there.
        .onKeyPress(keys: ["f"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            onClose()
            return .handled
        }
    }
}

private struct SearchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .foregroundStyle(MactermTheme.fgMuted)
            .background(configuration.isPressed ? MactermTheme.surface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
