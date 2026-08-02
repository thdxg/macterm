import SwiftUI

/// A transient confirmation for actions whose success leaves no visible trace.
///
/// Save Layout, Apply Layout (when the live tree already matches the file) and
/// Reload Ghostty Config all used to succeed in total silence — the failure
/// paths raise alerts, so a quiet outcome was ambiguous between "worked" and
/// "the keybind didn't fire". This is the success-side counterpart, deliberately
/// *not* an alert: these outcomes carry no decision, so they must not take focus
/// or need dismissing.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    /// Optional second line — the detail that makes the toast informative
    /// (which file was written, how many tabs were applied).
    var subtitle: String?

    /// How long the toast stays up before auto-dismissing. Two seconds reads as
    /// deliberate without lingering over the terminal; a subtitle earns a little
    /// longer because there's more to read.
    var duration: Duration { subtitle == nil ? .seconds(2) : .seconds(2.6) }

    static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
    }
}

/// Renders the active toast at the top of the window and owns its auto-dismiss.
///
/// Mirrors the command palette's presentation (glass on Tahoe, native material
/// below) so the two floating surfaces read as one system.
struct ToastOverlay: View {
    @Environment(AppState.self)
    private var appState

    private static let cornerRadius: CGFloat = 12

    var body: some View {
        VStack {
            if let toast = appState.activeToast {
                content(toast)
                    // Keyed by identity so a second toast arriving while the
                    // first is up re-runs the dismiss task instead of inheriting
                    // the old one's remaining time.
                    .id(toast.id)
                    .task(id: toast.id) {
                        try? await Task.sleep(for: toast.duration)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            appState.dismissToast(toast.id)
                        }
                    }
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        // Purely informational: it must never intercept a click meant for the
        // terminal underneath, and there's nothing here to interact with.
        .allowsHitTesting(false)
        .animation(.spring(duration: 0.3), value: appState.activeToast)
    }

    private func content(_ toast: Toast) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(toast.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MactermTheme.fg)
            if let subtitle = toast.subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(MactermTheme.fgMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .toastBackground(cornerRadius: Self.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(MactermTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
        // VoiceOver gets the announcement the sighted user gets from the toast
        // appearing; without this the confirmation is silent for them too.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

private extension View {
    /// Liquid glass on macOS 26; the closest native material on older systems.
    /// Same treatment as the command palette (`paletteBackground`).
    @ViewBuilder
    func toastBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}
