import AppKit
import SwiftUI

/// Settings → Extensions: every extension as a card in one searchable grid —
/// installed ones (folders in `~/.config/macterm/extensions/`,
/// `CustomPaletteStore`) and the ones in Macterm's repository not installed
/// yet (`PaletteRegistry`), by name. Each card shows the screenshots of its
/// extension, one page at a time, and a click on one shows them at full size
/// in a sheet. An extension without screenshots shows its icon there.
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
    @State private var viewing: ScreenshotSheet.Viewing?

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 12, alignment: .top)]

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
                        let screenshots = item.screenshots(ref: registry.ref)
                        ExtensionCard(
                            item: item,
                            screenshots: screenshots,
                            loader: registry.screenshots,
                            link: folderURL(item, ref: registry.ref),
                            isInstalling: installingIDs.contains(item.extensionID) || registry.writingIDs.contains(item.extensionID),
                            install: install,
                            update: { installed, update in
                                switch update {
                                case let .available(entry): self.update(entry)
                                case let .replacesChanges(entry): confirmingUpdate = (installed, entry)
                                }
                            },
                            uninstall: { uninstalling = $0 },
                            enlarge: { viewing = .init(title: item.title, screenshots: screenshots, index: $0) }
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
        .sheet(item: $viewing) { ScreenshotSheet(viewing: $0, loader: registry.screenshots) }
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

/// One extension: its screenshots; glyph, name and a line saying what it is
/// for, each cut short with an ellipsis so every card is the same size; a
/// link to its folder on GitHub when it comes from the repository; and a
/// button saying whether it is installed.
private struct ExtensionCard: View {
    @Environment(\.openURL)
    private var openURL

    let item: ExtensionGalleryItem
    let screenshots: [ExtensionScreenshot]
    let loader: ExtensionScreenshotLoader
    let link: URL?
    let isInstalling: Bool
    let install: (PaletteRegistry.Entry) -> Void
    let update: (CustomPaletteStore.InstalledExtension, ExtensionGalleryItem.Update) -> Void
    let uninstall: (CustomPaletteStore.InstalledExtension) -> Void
    let enlarge: (Int) -> Void

    @State private var page: Int? = 0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ScreenshotPager(
                    screenshots: screenshots,
                    icon: item.icon,
                    loader: loader,
                    page: $page,
                    maxPixelSize: ScreenshotPager.cardPixelSize,
                    enlarge: enlarge
                )
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

/// The screenshots of an extension, one page at a time, at the aspect ratio
/// of every screenshot (`MactermExtension.screenshotPointSize`). A swipe, an
/// arrow or a dot on the screenshot goes to another page. The card and the
/// sheet show the same pager. On a card, a click opens the sheet at that
/// screenshot (`enlarge`). An extension without screenshots shows its icon
/// in the same space, so every card has the same height.
private struct ScreenshotPager: View {
    let screenshots: [ExtensionScreenshot]
    let icon: PaletteIcon
    let loader: ExtensionScreenshotLoader
    @Binding var page: Int?
    /// The longer edge of each image, in pixels (`ExtensionScreenshotLoader`).
    let maxPixelSize: Int
    /// nil in the sheet, where a click does nothing.
    var enlarge: ((Int) -> Void)?

    /// The longer edge of the image of a card, in pixels: a card is at most
    /// 420 points wide, 840 pixels at 2x.
    static let cardPixelSize = 900
    private static let aspectRatio = MactermExtension.screenshotPointSize.width / MactermExtension.screenshotPointSize.height
    private static let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    private var current: Int { min(max(page ?? 0, 0), max(screenshots.count - 1, 0)) }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if screenshots.isEmpty {
                PaletteIconImage(icon: icon, side: 40)
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
            } else {
                pages
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(Self.shape)
        .overlay { Self.shape.strokeBorder(.separator) }
        .overlay { arrows }
        .overlay(alignment: .bottom) { dots }
    }

    private var pages: some View {
        ScrollViewReader { proxy in
            scrollView
                // A `scrollPosition` that is set before the scroll view
                // appears does not move it. The sheet opens at the page
                // that was clicked, so scroll there once the pages exist.
                .onAppear {
                    guard let page, page > 0 else { return }
                    Task { @MainActor in proxy.scrollTo(page, anchor: .leading) }
                }
        }
    }

    private var scrollView: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(screenshots.enumerated()), id: \.offset) { index, screenshot in
                    Group {
                        if let enlarge {
                            Button { enlarge(index) } label: {
                                ScreenshotImage(screenshot: screenshot, loader: loader, maxPixelSize: maxPixelSize)
                            }
                            .buttonStyle(.plain)
                            .zoomInPointer()
                            .help("Show the screenshots at full size")
                        } else {
                            ScreenshotImage(screenshot: screenshot, loader: loader, maxPixelSize: maxPixelSize)
                        }
                    }
                    .containerRelativeFrame(.horizontal)
                    .accessibilityLabel(Text("Screenshot \(index + 1) of \(screenshots.count)"))
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.never)
    }

    /// An arrow shows only where there is a page to go to. They do not wait
    /// for a hover: a tracking area does not follow the content that a
    /// SwiftUI `ScrollView` moves, so after a scroll a hover showed the
    /// arrows of another card, and a click on a hidden arrow opened the sheet.
    private var arrows: some View {
        HStack {
            arrow(systemImage: "chevron.left", label: "Previous Screenshot", key: .leftArrow, isShown: current > 0) {
                go(to: current - 1)
            }
            Spacer()
            arrow(systemImage: "chevron.right", label: "Next Screenshot", key: .rightArrow, isShown: current < screenshots.count - 1) {
                go(to: current + 1)
            }
        }
        .padding(8)
    }

    /// In the sheet, the Left and Right Arrow keys press the arrows. A card
    /// has no keys: the grid has many cards.
    private func arrow(
        systemImage: String,
        label: LocalizedStringKey,
        key: KeyEquivalent,
        isShown: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .keyboardShortcut(enlarge == nil ? KeyboardShortcut(key, modifiers: []) : nil)
        .disabled(!isShown)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .animation(.easeOut(duration: 0.12), value: isShown)
    }

    /// One dot for each screenshot, on a capsule over the bottom of the
    /// screenshot. There are no dots for one screenshot or none.
    @ViewBuilder private var dots: some View {
        if screenshots.count > 1 {
            HStack(spacing: 2) {
                ForEach(screenshots.indices, id: \.self) { index in
                    Button { go(to: index) } label: {
                        Circle()
                            .fill(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(width: 6, height: 6)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Screenshot \(index + 1) of \(screenshots.count)"))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 8)
        }
    }

    private func go(to index: Int) {
        Self.go(to: index, page: $page)
    }

    /// Goes to the page `index` with the slide of a swipe.
    static func go(to index: Int, page: Binding<Int?>) {
        withAnimation(.smooth(duration: 0.25)) { page.wrappedValue = index }
    }
}

private extension View {
    /// The zoom-in pointer over a screenshot that a click shows at full
    /// size. macOS 14 has no zoom-in pointer and keeps the arrow.
    @ViewBuilder
    func zoomInPointer() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.zoomIn)
        } else {
            self
        }
    }
}

/// A screenshot, read and decoded off the main thread when it first shows
/// (`ExtensionScreenshotLoader`). A screenshot that a view read before
/// shows at once.
private struct ScreenshotImage: View {
    let screenshot: ExtensionScreenshot
    let loader: ExtensionScreenshotLoader
    let maxPixelSize: Int

    @State private var loaded: NSImage?
    @State private var failure: String?

    var body: some View {
        ZStack {
            if let image = loaded ?? loader.cachedImage(of: screenshot, maxPixelSize: maxPixelSize) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let failure {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .help(failure)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(MactermExtension.screenshotPointSize.width / MactermExtension.screenshotPointSize.height, contentMode: .fit)
        .task(id: screenshot) {
            guard loader.cachedImage(of: screenshot, maxPixelSize: maxPixelSize) == nil else { return }
            failure = nil
            do {
                loaded = try await loader.image(of: screenshot, maxPixelSize: maxPixelSize)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The screenshots of one extension at full size, in the pager of the card
/// (`ScreenshotPager`), at the screenshot that was clicked. The Left and
/// Right Arrow keys go to another page. Done or Escape closes it.
private struct ScreenshotSheet: View {
    struct Viewing: Identifiable {
        let id = UUID()
        let title: String
        let screenshots: [ExtensionScreenshot]
        let index: Int
    }

    @Environment(\.dismiss)
    private var dismiss

    let viewing: Viewing
    let loader: ExtensionScreenshotLoader
    @State private var page: Int?

    init(viewing: Viewing, loader: ExtensionScreenshotLoader) {
        self.viewing = viewing
        self.loader = loader
        _page = State(initialValue: viewing.index)
    }

    var body: some View {
        VStack(spacing: 12) {
            ScreenshotPager(
                screenshots: viewing.screenshots,
                icon: .symbol(MactermExtension.defaultIcon),
                loader: loader,
                page: $page,
                maxPixelSize: MactermExtension.screenshotPixelSize.width
            )
            .frame(width: 720, height: 450)
            HStack(spacing: 8) {
                Text(viewing.title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onExitCommand { dismiss() }
    }
}
