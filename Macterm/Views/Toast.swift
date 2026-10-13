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

    /// How long the toast stays up before auto-dismissing. The time grows with
    /// the text to read (title and subtitle together), so a long error message
    /// stays up long enough to read and a short confirmation does not linger
    /// over the terminal.
    var duration: Duration { Self.duration(forCharacters: title.count + (subtitle?.count ?? 0)) }

    /// A short toast stays up at least this long, so that it reads as deliberate.
    static let minimumDuration: Duration = .seconds(2)
    /// The subtitle truncates to one line, so text past this time is not
    /// visible to read.
    static let maximumDuration: Duration = .seconds(6)
    /// The time to see that a toast arrived, before reading starts.
    private static let glanceTime: Duration = .seconds(1)
    /// A slow reading rate (about 180 words per minute). A toast arrives
    /// without warning, over work the user looks at.
    private static let charactersPerSecond = 15.0

    static func duration(forCharacters count: Int) -> Duration {
        let reading = glanceTime + .seconds(Double(count) / charactersPerSecond)
        return min(max(reading, minimumDuration), maximumDuration)
    }

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
                    // A short drop rather than `.move(edge: .top)`, which
                    // travels the toast's whole height (and further on a
                    // two-line one) — enough motion to read as arriving from
                    // above without a long slide over the terminal.
                    .transition(
                        .offset(y: -8)
                            .combined(with: .opacity)
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        // Purely informational: it must never intercept a click meant for the
        // terminal underneath, and there's nothing here to interact with.
        .allowsHitTesting(false)
        // No bounce: over an 8pt travel a spring's overshoot is most of the
        // motion, which reads as a wobble rather than a settle.
        .animation(.easeOut(duration: 0.22), value: appState.activeToast)
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
                    // A file path is the long case. Truncate the *middle* so
                    // both ends survive — the leading `~/…` says where it is
                    // and the filename says which one, while eliding the
                    // predictable directory in between. The cap applies to the
                    // subtitle alone, so it bounds the one line that can run
                    // long without padding out a short toast.
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
        // Hug the content: without this the stack accepts whatever width the
        // overlay offers and the panel floats far past its text.
        .fixedSize()
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
