import SwiftUI

/// The color-tag menu, shared by the sidebar context menu and Settings →
/// Projects.
///
/// Swatches come from `.pickerStyle(.palette)`. A hand-drawn icon does not
/// work, and both attempts are worth not repeating: a tinted SF Symbol renders
/// in the MENU's tint, and a non-template `NSImage` is dropped by SwiftUI's
/// menu bridge entirely (observed — the submenu came out as bare text). The
/// palette's selection ring is what marks the current color.
struct ProjectColorMenu: View {
    let selection: ProjectColor?
    let onSelect: @MainActor (ProjectColor?) -> Void

    var body: some View {
        Menu("Color") {
            // `Binding.set` is `@isolated(any) @Sendable`, so `onSelect` has to
            // be main-actor-isolated to reach it without a data-race warning —
            // but it must be *called* from a closure literal rather than passed
            // as `set: onSelect`. Handing the function value over directly asks
            // for a reabstraction thunk into `@isolated(any)`, and IRGen
            // crashes emitting it (observed on Swift 6.3.3).
            Picker("Color", selection: Binding(get: { selection }, set: { onSelect($0) })) {
                ForEach(ProjectColor.allCases, id: \.self) { color in
                    Label(color.displayName, systemImage: "circle.fill")
                        .tint(MactermTheme.color(for: color))
                        .tag(ProjectColor?.some(color))
                }
            }
            .pickerStyle(.palette)
            Divider()
            Button("None") { onSelect(nil) }
        }
    }
}
