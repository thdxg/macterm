import AppKit
import SwiftUI

/// Settings → Extensions: every extension as a card in one searchable grid —
/// installed ones (folders in `~/.config/macterm/extensions/`,
/// `CustomPaletteStore`) and the ones in Macterm's repository not installed
/// yet (`PaletteRegistry`), by name.
/// Each card's button says which: **Install** copies it in at once (its
/// folder on GitHub is a link beside the button), **Installed** offers to move it to
/// the Trash. An installed card also has an Update button when the
/// repository's version differs (`ExtensionGalleryItem.update`). The
/// built-in screens aren't extensions and have no card.
struct ExtensionsSettings: View {
    @Environment(AppState.self)
    private var appState

    @State private var query = ""
    @State private var filter = ExtensionGalleryItem.Filter.all
    @State private var installingIDs: Set<String> = []
    @State private var uninstalling: CustomPaletteStore.InstalledExtension?
    /// An update that replaces a copy with changes, waiting for a yes.
    @State private var confirmingUpdate: (installed: CustomPaletteStore.InstalledExtension, entry: PaletteRegistry.Entry)?
    @State private var problem: String?
    @State private var autoUpdate = Preferences.shared.autoUpdateExtensions

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12, alignment: .top)]

    var body: some View {
        let registry = appState.paletteRegistry
        let items = ExtensionGalleryItem.items(
            installed: appState.customPalettes.extensions,
            registry: registry.entries,
            query: query,
            filter: filter
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    SettingsSearchField(text: $query, prompt: "Search extensions")
                    Picker(Self.filterLabel, selection: $filter) {
                        ForEach(ExtensionGalleryItem.Filter.allCases) { Text(Self.title(of: $0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                RegistryStatus(state: registry.state)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .settingsCaption()
                }

                if items.isEmpty {
                    Text(query.isEmpty && filter == .all ? "No extensions yet." : "No extensions match.")
                        .settingsCaption()
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        ExtensionCard(
                            item: item,
                            link: folderURL(item, ref: registry.ref),
                            isInstalling: installingIDs.contains(item.extensionID) || registry.writingIDs.contains(item.extensionID),
                            install: install,
                            update: { installed, update in
                                switch update {
                                case let .available(entry): self.update(entry)
                                case let .replacesChanges(entry): confirmingUpdate = (installed, entry)
                                }
                            },
                            uninstall: { uninstalling = $0 }
                        )
                    }
                }

                Toggle("Update extensions automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, on in
                        Preferences.shared.autoUpdateExtensions = on
                        if on { Task { await appState.extensionAutoUpdater.runOnce() } }
                    }

                HStack(alignment: .firstTextBaseline) {
                    Text("Extensions add screens to the command palette.")
                        .settingsCaption()
                    Spacer()
                    DocsLink(.extensionsSettings)
                }
            }
            .padding(20)
        }
        .onAppear {
            appState.customPalettes.reloadIfChanged()
            registry.refresh()
            adoptIfLoaded()
        }
        .onChange(of: registry.state) { adoptIfLoaded() }
        .confirmationDialog(
            "Update \(confirmingUpdate?.installed.name ?? "")?",
            isPresented: Binding(get: { confirmingUpdate != nil }, set: { if !$0 { confirmingUpdate = nil } }),
            presenting: confirmingUpdate
        ) { pending in
            Button("Update", role: .destructive) { update(pending.entry) }
        } message: { pending in
            let name = pending.installed.name
            Text(pending.installed.source == nil
                ? "Your copy of \(name) is not the same as the version in the Macterm repository. Your copy goes to the Trash."
                : "You changed \(name). Your changed copy goes to the Trash.")
        }
        .confirmationDialog(
            "Uninstall \(uninstalling?.name ?? "")?",
            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
            presenting: uninstalling
        ) { installed in
            Button("Uninstall", role: .destructive) {
                do {
                    try appState.customPalettes.uninstall(extensionID: installed.id)
                    problem = nil
                } catch {
                    problem = String(localized: "Cannot uninstall \(installed.name): \(error.localizedDescription)")
                }
            }
        } message: { installed in
            Text(installed.uninstallMessage)
        }
    }

    /// The label of a filter in the Show menu. The raw value is an
    /// identifier, not a label.
    /// The label of the filter menu. The menu hides it, but VoiceOver reads it.
    private static let filterLabel = String(
        localized: "extensions.filter.show",
        defaultValue: "Show",
        comment: "Settings → Extensions: the label of the filter menu (All, Installed, Not Installed)"
    )

    private static func title(of filter: ExtensionGalleryItem.Filter) -> String {
        switch filter {
        case .all: String(localized: "All", comment: "Settings → Extensions: the filter that shows every extension")
        case .installed: String(localized: "Installed", comment: "Settings → Extensions: the filter that shows installed extensions")
        case .notInstalled: String(
                localized: "Not Installed",
                comment: "Settings → Extensions: the filter that shows extensions that are not installed"
            )
        }
    }

    /// Installs `entry` at once — its folder on GitHub, a click away on the card, is
    /// where to read it first.
    private func install(_ entry: PaletteRegistry.Entry) {
        installingIDs.insert(entry.id)
        Task {
            do {
                try await appState.paletteRegistry.install(entry, into: appState.customPalettes)
                problem = nil
            } catch {
                problem = String(localized: "Cannot install \(entry.name): \(error.localizedDescription)")
            }
            installingIDs.remove(entry.id)
        }
    }

    /// Replaces the installed copy of `entry` with the repository's version.
    private func update(_ entry: PaletteRegistry.Entry) {
        installingIDs.insert(entry.id)
        Task {
            do {
                try await appState.paletteRegistry.update(entry, into: appState.customPalettes)
                problem = nil
            } catch {
                problem = String(localized: "Cannot update \(entry.name): \(error.localizedDescription)")
            }
            installingIDs.remove(entry.id)
        }
    }

    /// Records where an unrecorded copy came from when it is the same as the
    /// repository's (`PaletteRegistry.adoptUnrecordedInstalls`).
    private func adoptIfLoaded() {
        guard case .loaded = appState.paletteRegistry.state else { return }
        appState.paletteRegistry.adoptUnrecordedInstalls(in: appState.customPalettes)
    }

    /// The folder of an extension the repository has; none for a palette
    /// file of the user's own.
    private func folderURL(_ item: ExtensionGalleryItem, ref: String) -> URL? {
        switch item {
        case let .installed(_, registry): registry.map { PaletteRegistry.folderURL(ref: ref, id: $0.id) }
        case let .available(entry): PaletteRegistry.folderURL(ref: ref, id: entry.id)
        }
    }
}

/// The repository's extensions while they're being read, or why they
/// couldn't be; nothing once they're in.
private struct RegistryStatus: View {
    let state: PaletteRegistry.State

    var body: some View {
        switch state {
        case .idle,
             .loaded:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the extensions from the Macterm repository…").settingsCaption()
            }
        case let .failed(reason):
            Label("Cannot read the extensions of Macterm: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .settingsCaption()
        }
    }
}

/// One extension: glyph, name and a line saying what it is for, each cut
/// short with an ellipsis so every card is the same size; a link to its
/// folder on GitHub when it comes from the repository; and a button saying whether it
/// is installed.
private struct ExtensionCard: View {
    @Environment(\.openURL)
    private var openURL

    let item: ExtensionGalleryItem
    let link: URL?
    let isInstalling: Bool
    let install: (PaletteRegistry.Entry) -> Void
    let update: (CustomPaletteStore.InstalledExtension, ExtensionGalleryItem.Update) -> Void
    let uninstall: (CustomPaletteStore.InstalledExtension) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    PaletteIconImage(icon: item.icon, side: 20)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // Use a Button, not a `Link`. A bordered `Link` has its
                    // own height, which is not the height of the Install button.
                    if let link {
                        Button { openURL(link) } label: {
                            ButtonLabel(title: nil, systemImage: "book")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("See its files and README on GitHub")
                    }
                    button
                }
                Text(item.summary)
                    .settingsCaption()
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4)
        }
    }

    @ViewBuilder private var button: some View {
        switch item {
        case let .installed(installed, _):
            HStack(spacing: 6) {
                if let problem = installed.problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MactermTheme.failure)
                        .help(problem)
                }
                // A glyph only, as the book button: the card is too narrow
                // for a third titled button next to its name.
                if let available = item.update {
                    Button { update(installed, available) } label: {
                        ButtonLabel(title: nil, systemImage: isInstalling ? nil : "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(available.entry.failure != nil || isInstalling)
                    .help(available.entry.failure
                        .map { String(localized: "This version of Macterm cannot read the update: \($0.localizedDescription)") }
                        ?? String(localized: "Update to the version in the Macterm repository"))
                }
                Button { uninstall(installed) } label: {
                    ButtonLabel(title: "Installed", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Uninstall it")
            }
        case let .available(entry):
            Button { install(entry) } label: {
                if isInstalling {
                    ButtonLabel(title: "Installing", systemImage: nil)
                } else {
                    ButtonLabel(title: "Install", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(entry.failure != nil || isInstalling)
            .help(entry.failure
                .map { String(localized: "This version of Macterm cannot read it: \($0.localizedDescription)") } ??
                String(localized: "Install it"))
        }
    }
}

/// The glyph and the title of a card button, with the space of text between
/// them. `Label` puts its icon in a slot of fixed width, which put a wide gap
/// on each side of the glyph. The label also goes a little into the side
/// padding of the bezel. That padding is for a wide push button, and it made
/// these small buttons mostly empty.
private struct ButtonLabel: View {
    let title: LocalizedStringKey?
    let systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            // Put each glyph in a slot that is as tall as a line of text and a
            // circled symbol. A bordered button gets its height from its
            // label. Without the slot, the book button was shorter than the
            // Install button next to it.
            ZStack {
                Text(verbatim: "X").hidden()
                Image(systemName: "circle").hidden()
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            if let title { Text(title) }
        }
        .padding(.horizontal, -3)
    }
}
