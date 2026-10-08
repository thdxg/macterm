import AppKit
import SwiftUI

/// Settings → Extensions: every extension as a card in one searchable grid —
/// installed ones (folders in `~/.config/macterm/extensions/` and palette
/// files in `~/.config/macterm/palettes/`, `CustomPaletteStore`) and the ones
/// in Macterm's repository not installed yet (`PaletteRegistry`), by name.
/// Each card's button says which: **Install** shows the extension's files
/// before copying it in, **Installed** offers to move it to the Trash. The
/// built-in screens aren't extensions and have no card.
struct ExtensionsSettings: View {
    @Environment(AppState.self)
    private var appState

    @State private var query = ""
    @State private var installing: PaletteRegistry.Entry?
    @State private var uninstalling: CustomPaletteStore.Entry?
    @State private var problem: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12, alignment: .top)]

    var body: some View {
        let registry = appState.paletteRegistry
        let items = ExtensionGalleryItem.items(
            installed: appState.customPalettes.entries,
            registry: registry.entries,
            query: query
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    SettingsSearchField(text: $query, prompt: "Search extensions")
                    Button {
                        registry.refresh(force: true)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(registry.state == .loading)
                    .help("Read the extensions in Macterm's repository again")
                    DocsLink(.extensionsSettings)
                }
                RegistryStatus(state: registry.state, ref: registry.ref)
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
                        ExtensionCard(item: item, install: { installing = $0 }, uninstall: { uninstalling = $0 })
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
                    "An extension adds screens to the command palette: a command whose output becomes rows, "
                        + "each opening another screen or running a command. "
                        + "Install one from Macterm's repository — the ones written for this version — "
                        + "or write your own as a YAML file in your palettes folder."
                )
                .settingsCaption()
            }
            .padding(20)
        }
        .onAppear {
            appState.customPalettes.reloadIfChanged()
            registry.refresh()
        }
        .sheet(item: $installing) { entry in
            InstallExtensionSheet(entry: entry) { installing = nil }
        }
        .confirmationDialog(
            "Uninstall \(uninstalling?.pill.title ?? "")?",
            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
            presenting: uninstalling
        ) { entry in
            Button("Move to Trash", role: .destructive) {
                do {
                    try appState.customPalettes.uninstall(id: entry.id)
                    problem = nil
                } catch {
                    problem = "Couldn't uninstall \(entry.pill.title): \(error.localizedDescription)"
                }
            }
        } message: { entry in
            let name = (entry.extensionDirectory ?? entry.fileURL).lastPathComponent
            Text("\(name) goes to the Trash, and its screens leave the command palette.")
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

/// Where the repository's extensions stand: reading, read (and when), or why
/// they couldn't be.
private struct RegistryStatus: View {
    let state: PaletteRegistry.State
    let ref: String

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading extensions from Macterm's repository…").settingsCaption()
            }
        case let .loaded(date):
            Text("Extensions for \(ref), read \(date.formatted(.relative(presentation: .named))).")
                .settingsCaption()
        case let .failed(reason):
            Label("Couldn't read Macterm's extensions: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .settingsCaption()
        }
    }
}

/// One extension: glyph, name, a line saying what it is for, its authors,
/// and a button saying whether it is installed.
private struct ExtensionCard: View {
    let item: ExtensionGalleryItem
    let install: (PaletteRegistry.Entry) -> Void
    let uninstall: (CustomPaletteStore.Entry) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    button
                }
                Text(item.summary)
                    .settingsCaption()
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.authors.isEmpty {
                    Text(item.authors.map { "@\($0)" }.formatted(.list(type: .and)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder private var button: some View {
        switch item {
        case let .installed(entry, _):
            HStack(spacing: 6) {
                if let failure = entry.failure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MactermTheme.failure)
                        .help("\(entry.fileURL.lastPathComponent): \(failure.localizedDescription)")
                }
                Button { uninstall(entry) } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                }
                .controlSize(.small)
                .help("Uninstall it")
            }
        case let .available(entry):
            Button { install(entry) } label: {
                Label("Install", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
            .disabled(entry.failure != nil)
            .help(entry.failure
                .map { "This version of Macterm can't read it: \($0.localizedDescription)" } ?? "Show its files, then install it")
        }
    }
}

/// An extension from the repository, shown in full before anything is
/// written: its README, then every text file in it — every command runs on
/// this machine.
private struct InstallExtensionSheet: View {
    @Environment(AppState.self)
    private var appState

    let entry: PaletteRegistry.Entry
    let dismiss: () -> Void
    @State private var shown = MactermExtension.readmeName
    @State private var problem: String?
    @State private var working = false
    @State private var screenshots: [NSImage] = []

    /// The sheet's tabs: the README, the screenshots when there are any,
    /// then every text file.
    private static let screenshotsTab = "Screenshots"
    private var paths: [String] {
        let texts = entry.files.map(\.path).filter { entry.texts[$0] != nil }
        let readme = texts.filter { $0 == MactermExtension.readmeName }
        let shots = entry.screenshots.isEmpty ? [] : [Self.screenshotsTab]
        return readme + shots + texts.filter { $0 != MactermExtension.readmeName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install \(entry.name)?").font(.headline)
                    if !entry.authors.isEmpty {
                        Text("By \(entry.authors.map { "@\($0)" }.formatted(.list(type: .and)))").settingsCaption()
                    }
                }
            }
            Text("Its commands run on this Mac when you open it. These are its files:")
                .settingsCaption()
            Picker("File", selection: $shown) {
                ForEach(paths, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            ScrollView {
                Group {
                    if shown == Self.screenshotsTab {
                        VStack(spacing: 8) {
                            if screenshots.isEmpty { ProgressView().controlSize(.small) }
                            ForEach(screenshots.indices, id: \.self) { index in
                                Image(nsImage: screenshots[index])
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    } else if shown == MactermExtension.readmeName {
                        Text(Self.markdown(entry.texts[shown] ?? ""))
                    } else {
                        Text(entry.texts[shown] ?? "")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 220, maxHeight: 360)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .settingsCaption()
            }
            HStack {
                Text("Saved in your extensions folder as \(entry.id).")
                    .settingsCaption()
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    working = true
                    Task {
                        do {
                            try await appState.paletteRegistry.install(entry, into: appState.customPalettes)
                            dismiss()
                        } catch {
                            problem = error.localizedDescription
                        }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { if !paths.contains(shown) { shown = paths.first ?? "" } }
        .task(id: entry.id) {
            var images: [NSImage] = []
            for path in entry.screenshots {
                if let data = await appState.paletteRegistry.screenshot(path, of: entry), let image = NSImage(data: data) {
                    images.append(image)
                }
            }
            screenshots = images
        }
    }

    /// A README's text with its inline markdown — emphasis, code, links —
    /// and its lines kept; headings and images stay as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
