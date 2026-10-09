import AppKit
import SwiftUI

/// Settings → Extensions: every extension as a card in one searchable grid —
/// installed ones (folders in `~/.config/macterm/extensions/` and palette
/// files in `~/.config/macterm/palettes/`, `CustomPaletteStore`) and the ones
/// in Macterm's repository not installed yet (`PaletteRegistry`), by name.
/// Each card's button says which: **Install** copies it in at once (its
/// folder on GitHub is a link beside the button), **Installed** offers to move it to
/// the Trash. The built-in screens aren't extensions and have no card.
struct ExtensionsSettings: View {
    @Environment(AppState.self)
    private var appState

    @State private var query = ""
    @State private var filter = ExtensionGalleryItem.Filter.all
    @State private var installingIDs: Set<String> = []
    @State private var uninstalling: CustomPaletteStore.InstalledExtension?
    @State private var problem: String?

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
                SettingsSearchField(text: $query, prompt: "Search extensions")
                Picker("Show", selection: $filter) {
                    ForEach(ExtensionGalleryItem.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
                            isInstalling: installingIDs.contains(item.extensionID),
                            install: install,
                            uninstall: { uninstalling = $0 }
                        )
                    }
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
        }
        .confirmationDialog(
            "Uninstall \(uninstalling?.name ?? "")?",
            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
            presenting: uninstalling
        ) { installed in
            Button("Move to Trash", role: .destructive) {
                do {
                    try appState.customPalettes.uninstall(extensionID: installed.id)
                    problem = nil
                } catch {
                    problem = "Couldn't uninstall \(installed.name): \(error.localizedDescription)"
                }
            }
        } message: { installed in
            Text("Its folder, \(installed.id), goes to the Trash, and its palettes leave the command palette.")
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
                problem = "Couldn't install \(entry.name): \(error.localizedDescription)"
            }
            installingIDs.remove(entry.id)
        }
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
                Text("Reading extensions from Macterm's repository…").settingsCaption()
            }
        case let .failed(reason):
            Label("Couldn't read Macterm's extensions: \(reason)", systemImage: "exclamationmark.triangle.fill")
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
    let uninstall: (CustomPaletteStore.InstalledExtension) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // A Button, not a `Link`: a bordered `Link` draws at its
                    // own height, a little off the Install button beside it.
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
            .help(entry.failure.map { "This version of Macterm can't read it: \($0.localizedDescription)" } ?? "Install it")
        }
    }
}

/// A card button's glyph and title, spaced as text — `Label` sets its icon
/// in a fixed-width slot, which left a wide gap either side of the glyph —
/// and drawn a little inside the bezel's own side padding, which is sized
/// for a full-width push button and left these small ones mostly margin.
private struct ButtonLabel: View {
    let title: String?
    let systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            // Every glyph in a slot as tall as a line of text and a circled
            // symbol: a bordered button takes its height from its label, and
            // the book alone came out shorter than "Install" beside it.
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
