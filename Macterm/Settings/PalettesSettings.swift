import AppKit
import SwiftUI

/// Settings → Palettes: every palette as a card in a searchable grid —
/// the built-in screens, the custom ones installed (files in
/// `~/.config/macterm/palettes/`, extensions in `~/.config/macterm/extensions/`
/// — `CustomPaletteStore`), and the extensions in Macterm's repository not
/// installed yet (`PaletteRegistry`), each with an Install button that shows
/// its files before copying it in.
///
/// A built-in or installed palette has a switch. Off, it leaves the command
/// palette and its menu, and its chord says where it went; the chord itself
/// stays bound in Settings → Keymaps for when it comes back. An installed
/// file that failed to read keeps its switch, with a warning glyph whose
/// tooltip is the error.
struct PalettesSettings: View {
    @Environment(AppState.self)
    private var appState

    @State private var query = ""
    @State private var installing: PaletteRegistry.Entry?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12, alignment: .top)]

    var body: some View {
        let registry = appState.paletteRegistry
        let sections = PaletteGalleryItem.sections(
            builtIn: PaletteScopeID.builtIn,
            installed: appState.customPalettes.entries,
            registry: registry.entries,
            query: query
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    SettingsSearchField(text: $query, prompt: "Search palettes")
                    Button {
                        registry.refresh(force: true)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(registry.state == .loading)
                    .help("Read the extensions in Macterm's repository again")
                }
                RegistryStatus(state: registry.state, ref: registry.ref)

                ForEach(sections, id: \.title) { section in
                    if !section.items.isEmpty || (section.title == "Installed" && query.isEmpty) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                            if section.items.isEmpty {
                                Text("No custom palettes installed.")
                                    .settingsCaption()
                            }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(section.items) { item in
                                    PaletteCard(item: item) { installing = $0 }
                                }
                            }
                        }
                    }
                }

                LabeledContent("Palettes folder") {
                    Button(Self.folderPath(appState)) {
                        appState.customPalettes.revealDirectory()
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Text(
                    "A palette is a YAML file in the folder: a command whose output becomes rows, "
                        + "each opening another screen or running a command. "
                        + "Available ones are extensions from Macterm's repository, for this version, "
                        + "installed as folders in ~/.config/macterm/extensions. "
                        + "A palette turned off leaves the command palette and its menu; "
                        + "its keybind, if any, says so instead of reaching the terminal."
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
            InstallPaletteSheet(entry: entry) { installing = nil }
        }
    }

    /// `~/.config/macterm/palettes`, home-contracted.
    static func folderPath(_ appState: AppState) -> String {
        let path = appState.customPalettes.directoryURL.path(percentEncoded: false)
        let home = ProjectPath.currentHome
        let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return shown.hasSuffix("/") ? String(shown.dropLast()) : shown
    }
}

/// Where the repository's palettes stand: reading, read (and when), or why
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
            Text("Available extensions for \(ref), read \(date.formatted(.relative(presentation: .named))).")
                .settingsCaption()
        case let .failed(reason):
            Label("Couldn't read the available extensions: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .settingsCaption()
        }
    }
}

/// One palette: glyph, name, a line saying what it is for, and what can be
/// done with it — a switch once it is built in or installed, Install while
/// it isn't.
private struct PaletteCard: View {
    let item: PaletteGalleryItem
    let install: (PaletteRegistry.Entry) -> Void

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
                    control
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

    @ViewBuilder private var control: some View {
        switch item {
        case let .builtIn(scope):
            PaletteSwitch(settingsID: scope.settingsID)
        case let .installed(entry, _):
            HStack(spacing: 6) {
                if let failure = entry.failure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MactermTheme.failure)
                        .help("\(entry.fileURL.lastPathComponent): \(failure.localizedDescription)")
                }
                PaletteSwitch(settingsID: entry.settingsID)
            }
        case let .available(entry):
            Button("Install") { install(entry) }
                .controlSize(.small)
                .disabled(entry.failure != nil)
                .help(entry.failure
                    .map { "This version of Macterm can't read it: \($0.localizedDescription)" } ?? "Show its files, then install it")
        }
    }
}

/// A palette's on/off switch (`Preferences.isPaletteEnabled`).
private struct PaletteSwitch: View {
    let settingsID: String
    @State private var enabled: Bool

    init(settingsID: String) {
        self.settingsID = settingsID
        _enabled = State(initialValue: Preferences.shared.isPaletteEnabled(settingsID))
    }

    var body: some View {
        Toggle("On", isOn: $enabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: enabled) { _, on in
                Preferences.shared.setPalette(settingsID, enabled: on)
            }
    }
}

/// An extension from the repository, shown in full before anything is
/// written: its README, then every text file in it — every command runs on
/// this machine.
private struct InstallPaletteSheet: View {
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
