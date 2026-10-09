import AppKit
import SwiftUI

/// Settings → Extensions: every extension as a card in one searchable grid —
/// installed ones (folders in `~/.config/macterm/extensions/` and palette
/// files in `~/.config/macterm/palettes/`, `CustomPaletteStore`) and the ones
/// in Macterm's repository not installed yet (`PaletteRegistry`), by name.
/// Each card's button says which: **Install** copies it in at once (its
/// README is a link beside the button), **Installed** offers to move it to
/// the Trash. The built-in screens aren't extensions and have no card.
struct ExtensionsSettings: View {
    @Environment(AppState.self)
    private var appState

    @State private var query = ""
    @State private var installingIDs: Set<String> = []
    @State private var uninstalling: CustomPaletteStore.InstalledExtension?
    @State private var problem: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12, alignment: .top)]

    var body: some View {
        let registry = appState.paletteRegistry
        let items = ExtensionGalleryItem.items(
            installed: appState.customPalettes.extensions,
            registry: registry.entries,
            query: query
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    SettingsSearchField(text: $query, prompt: "Search extensions")
                    DocsLink(.extensionsSettings)
                }
                RegistryStatus(state: registry.state)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .settingsCaption()
                }

                if items.isEmpty {
                    Text(query.isEmpty ? "No extensions yet." : "No extensions match.")
                        .settingsCaption()
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        ExtensionCard(
                            item: item,
                            readme: readmeURL(item, ref: registry.ref),
                            isInstalling: installingIDs.contains(item.extensionID),
                            install: install,
                            uninstall: { uninstalling = $0 }
                        )
                    }
                }

                LabeledContent("Extensions folder") {
                    FolderLink(url: appState.customPalettes.extensionsURL) {
                        appState.customPalettes.revealExtensionsDirectory()
                    }
                }
                LabeledContent("Your own palettes") {
                    FolderLink(url: appState.customPalettes.directoryURL) {
                        appState.customPalettes.revealDirectory()
                    }
                }
                Text(
                    "An extension adds to what Macterm can do — today, screens in the command palette: "
                        + "a command whose output becomes rows, each opening another screen or running a command. "
                        + "The ones listed come from Macterm's repository. "
                        + "A palette of your own needs no extension: a YAML file in your palettes folder."
                )
                .settingsCaption()
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

    /// Installs `entry` at once — its README, a click away on the card, is
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

    /// The README of an extension the repository has; none for a palette
    /// file of the user's own.
    private func readmeURL(_ item: ExtensionGalleryItem, ref: String) -> URL? {
        switch item {
        case let .installed(_, registry): registry.map { PaletteRegistry.readmeURL(ref: ref, id: $0.id) }
        case let .available(entry): PaletteRegistry.readmeURL(ref: ref, id: entry.id)
        }
    }
}

/// A folder, home-contracted, as a link that shows it in Finder.
private struct FolderLink: View {
    let url: URL
    let reveal: () -> Void

    var body: some View {
        Button(Self.path(url), action: reveal)
            .buttonStyle(.link)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    static func path(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let home = ProjectPath.currentHome
        let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return shown.hasSuffix("/") ? String(shown.dropLast()) : shown
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
/// README when it comes from the repository; and a button saying whether it
/// is installed.
private struct ExtensionCard: View {
    let item: ExtensionGalleryItem
    let readme: URL?
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
                    if let readme {
                        Link(destination: readme) {
                            Image(systemName: "book")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Read its README on GitHub")
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

/// A button's glyph and title, spaced as text: `Label` sets its icon in a
/// fixed-width slot, which left a wide gap either side of the glyph.
private struct ButtonLabel: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(title)
        }
    }
}
