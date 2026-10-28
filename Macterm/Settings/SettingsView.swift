import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

/// The panes of the settings window, in sidebar order. Titles are the
/// user-visible sidebar labels — Title Case, matching the macOS convention the
/// rest of the app's menus follow. The raw value is an identifier; `title` is
/// the label in the user's language.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case projects = "Projects"
    case appearance = "Appearance"
    case animations = "Animations"
    case quickTerminal = "Quick Terminal"
    case widgets = "Widgets"
    case passwords = "Password Manager"
    case extensions = "Extensions"
    case keymaps = "Keymaps"
    case updates = "Updates"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General", comment: "Settings pane")
        case .projects: String(localized: "Projects")
        case .appearance: String(localized: "Appearance", comment: "Settings pane")
        case .animations: String(localized: "Animations", comment: "Settings pane")
        case .quickTerminal: String(localized: "Quick Terminal", comment: "Settings pane")
        case .widgets: String(localized: "Widgets", comment: "Settings pane")
        case .passwords: String(localized: "Password Manager", comment: "Settings pane")
        case .extensions: String(localized: "Extensions", comment: "Settings pane")
        case .keymaps: String(localized: "Keymaps", comment: "Settings pane")
        case .updates: String(localized: "Updates", comment: "Settings pane")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .projects: "folder"
        case .appearance: "paintpalette"
        case .animations: "wand.and.sparkles"
        case .quickTerminal: "rectangle.bottomthird.inset.filled"
        case .widgets: "widget.small"
        case .keymaps: "keyboard"
        case .extensions: "puzzlepiece.extension"
        case .passwords: "key"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// Sidebar-style preferences window, mirroring the macOS System Settings
/// shape: a source list of panes on the left, the selected pane's `Form` on
/// the right. `NavigationSplitView` is the native container — it also places
/// the pane title over the detail column, which nothing else does (see
/// `PinnedSidebar`).
///
/// The soft scroll-edge band of the titlebar darkens the top of a selected
/// first row like a shadow. AppKit has no switch for the band, and a top
/// margin on the list does not clear it. A sidebar `.searchable` field
/// clears it, but it blanks the icons of the unselected rows for about
/// 100 ms each time that the window opens, so the sidebar has no search.
struct SettingsView: View {
    @State private var selection: SettingsPane = .general

    /// Sidebar width — the pane list is six short labels, so there's nothing to
    /// gain from resizing it, and dragging it narrow just truncates them.
    static let sidebarWidth: CGFloat = 190

    /// Floor for the content column — enough for the widest pane's controls
    /// (the Keymaps rows) without horizontal clipping.
    static let detailMinWidth: CGFloat = 440

    static let windowMinHeight: CGFloat = 520

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection) {
                ForEach(SettingsPane.allCases) { pane in
                    NavigationLink(value: pane) {
                        Label(pane.title, systemImage: pane.symbol)
                    }
                }
            }
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
            .hidingSidebarToggle()
        } detail: {
            detail
                .navigationTitle(selection.title)
                .frame(minWidth: Self.detailMinWidth)
        }
        .background(PinnedSidebar(width: Self.sidebarWidth))
        .frame(
            minWidth: Self.sidebarWidth + Self.detailMinWidth,
            idealWidth: Self.sidebarWidth + Self.detailMinWidth,
            minHeight: Self.windowMinHeight,
            idealHeight: 600
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettings()
        case .projects: ProjectsSettings()
        case .appearance: AppearanceSettings()
        case .animations: AnimationsSettings()
        case .quickTerminal: QuickTerminalSettings()
        case .widgets: WidgetsSettings()
        case .keymaps: KeymapSettings()
        case .extensions: ExtensionsSettings()
        case .passwords: PasswordsSettings()
        case .updates: UpdatesSettings()
        }
    }
}

// MARK: - Pinned sidebar + window chrome

/// Fixes the sidebar's width, stops it collapsing, and applies the main
/// window's titlebar chrome.
///
/// None of this is expressible in SwiftUI: `navigationSplitViewColumnWidth`
/// and `columnVisibility` are documented *preferences* the framework may
/// override ("SwiftUI may use a different width for your column"). The
/// properties that bind live on `NSSplitViewItem`, reached through the
/// `NSSplitViewController` SwiftUI builds.
///
/// Finding that controller is the trick: it's not in this probe's responder
/// chain (the probe sits in a `.background`, a sibling subtree) and not a child
/// of the window's root view controller. It *owns* the split view, so the route
/// is a view-tree walk down to the `NSSplitView`, then a responder walk up.
/// Replacing the split view's delegate is not an option — AppKit raises
/// "a SplitView managed by a SplitViewController cannot have its delegate
/// modified" and the app dies.
///
/// The pin is re-applied from two notifications, not just SwiftUI updates.
/// `NSWindow.didResizeNotification` covers a window resize. The important one
/// is `NSSplitView.didResizeSubviewsNotification`, which covers a **divider
/// drag** — dragging never resizes the window, so without it a drag to the far
/// left collapsed the sidebar to zero and nothing put it back. SwiftUI's split
/// view controller can collapse the column from its own state even with
/// `canCollapse` false, so restoring it there is the backstop.
///
/// **Why a shield rather than constraints alone.** The constraints above do
/// lock the column — with every re-assert disabled, drags left, right, and past
/// the window edge all left it at exactly its pinned width. But they don't
/// *stay* applied: SwiftUI re-applies its own column metrics on events we can't
/// enumerate (a window move fires neither a resize nor an `updateNSView`), and
/// once it does the drag affordance returns and the column can collapse until
/// the next re-assert. Observed directly: no handle on a freshly opened window,
/// handle back after moving the window or switching panes, and a collapsed
/// sidebar springing back on the next focus change.
///
/// `DividerShield` doesn't depend on any of that — it sits over the divider and
/// takes the mouse before AppKit sees it, so it holds no matter what SwiftUI
/// resets underneath. The constraints stay as the underlying truth; the shield
/// makes the behavior deterministic.
///
/// Alternatives that don't work: the split view's delegate owns the divider's
/// effective rect, and AppKit raises rather than let a controller-managed
/// delegate be replaced; a plain (non-`.sidebar`) item drops the affordance but
/// moves the pane title off the detail column, and
/// `NSTrackingSeparatorToolbarItem` doesn't move it back — it aligns toolbar
/// item groups, not the window title.
private struct PinnedSidebar: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context _: Context) -> NSView {
        // Zero-size and hidden: a handle into the hierarchy, never visible
        // chrome.
        let probe = NSView(frame: .zero)
        probe.isHidden = true
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The split view doesn't exist on the first pass; a later update lands
        // once it does. Every call is idempotent.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            SettingsWindowChrome.apply(to: window)
            context.coordinator.pin(window: window, width: width)
        }
    }

    func makeCoordinator() -> Pinner {
        Pinner()
    }

    /// Pairs the resize observer with a removal. Teardown lives here, a
    /// `@MainActor` hook, rather than in `deinit` — which is `nonisolated`
    /// under Swift 6 and can't touch the coordinator's non-Sendable observer
    /// (the same reason `HotkeyCaptureView` tears down this way).
    static func dismantleNSView(_: NSView, coordinator: Pinner) {
        coordinator.tearDown()
    }

    @MainActor
    final class Pinner {
        private var observers: [any NSObjectProtocol] = []
        private var width: CGFloat = 0
        /// Guards the re-assert: un-collapsing inside a resize notification
        /// posts another one, which would recurse.
        private var isReasserting = false

        func pin(window: NSWindow, width: CGFloat) {
            self.width = width
            apply(in: window)
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            // A window resize.
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.apply(in: window) }
            })
            // A divider drag. This is the one that matters for the snap-to-zero:
            // dragging the divider never resizes the WINDOW, so the window
            // notification above doesn't fire and nothing undoes the collapse.
            guard let split = window.contentView?.firstSplitView else { return }
            observers.append(center.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: split,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { self?.apply(in: window) }
            })
        }

        func tearDown() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        private func apply(in window: NSWindow) {
            guard !isReasserting,
                  let split = window.contentView?.firstSplitView,
                  let controller = split.owningSplitViewController,
                  let sidebar = controller.splitViewItems.first
            else { return }
            isReasserting = true
            defer { isReasserting = false }
            // Equal min and max leave no range for a drag to land in, and a
            // high holding priority makes a window resize take width from the
            // detail column instead of this one.
            sidebar.canCollapse = false
            sidebar.minimumThickness = width
            sidebar.maximumThickness = width
            sidebar.holdingPriority = .required
            // Undo a collapse that slipped through anyway. SwiftUI's split view
            // controller can collapse the column from its own state even with
            // `canCollapse` false, so this is the backstop — reached from the
            // divider-drag notification, which is when it actually happens.
            if sidebar.isCollapsed { sidebar.isCollapsed = false }
            // And restore the width if the drag left it anywhere else.
            let current = sidebar.viewController.view.frame.width
            if abs(current - width) > 0.5 {
                split.setPosition(width, ofDividerAt: 0)
            }
            positionShield(over: split)
        }

        /// Keeps an invisible shield over the divider so it shows no resize
        /// cursor and starts no drag — the affordance stock Settings' sidebar
        /// doesn't have either.
        ///
        /// The shield is a sibling of the split view, never a subview:
        /// `NSSplitView` treats its subviews as panes, so adding it there would
        /// create a third column.
        private func positionShield(over split: NSSplitView) {
            guard let host = split.superview else { return }
            let shield = self.shield ?? {
                let view = DividerShield()
                self.shield = view
                return view
            }()
            if shield.superview !== host { host.addSubview(shield) }
            // Cover the divider plus a hair on each side: AppKit's drag region
            // is slightly wider than the drawn hairline.
            let padding: CGFloat = 3
            let dividerInSplit = NSRect(
                x: width,
                y: 0,
                width: max(split.dividerThickness, 1),
                height: split.bounds.height
            )
            shield.frame = host.convert(dividerInSplit, from: split).insetBy(dx: -padding, dy: 0)
            // Stay above the split view so the divider never sees the mouse.
            if host.subviews.last !== shield {
                shield.removeFromSuperview()
                host.addSubview(shield, positioned: .above, relativeTo: nil)
            }
            shield.window?.invalidateCursorRects(for: shield)
        }

        private var shield: DividerShield?
    }
}

/// Invisible cover over the split view's divider. The divider itself can't be
/// made non-interactive — that lives on the split view's delegate, and AppKit
/// forbids replacing a controller-managed one — so the mouse is intercepted
/// before it reaches the divider instead. Drawing nothing, it changes only the
/// cursor and the drag, not the look.
private final class DividerShield: NSView {
    /// Claim every point in bounds, so the divider underneath never receives a
    /// hover or a click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return frame.contains(superview.convert(point, from: superview.superview)) ? self : nil
    }

    override func resetCursorRects() {
        // Plain arrow: no resize affordance.
        addCursorRect(bounds, cursor: .arrow)
    }

    // Swallow clicks so no drag ever begins.
    override func mouseDown(with _: NSEvent) {}
    override func mouseDragged(with _: NSEvent) {}
    override func mouseUp(with _: NSEvent) {}
}

/// The main window's titlebar chrome, applied to the settings window so the two
/// match: transparent and separator-less, content extending underneath, and an
/// empty unified toolbar. Having a toolbar at all is what makes AppKit lay out
/// the taller titlebar and inset the traffic lights (~23pt, measured identical
/// to the main window; without one they sit at ~16pt).
@MainActor
private enum SettingsWindowChrome {
    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        // `.unified`, not `.unifiedCompact` — compact shrinks the titlebar back
        // to its toolbar-less height, losing the spacing the toolbar buys.
        if window.toolbar == nil {
            window.toolbar = NSToolbar(identifier: "SettingsToolbar")
        }
        // Icon-only, matching the main window's locked display mode — the
        // default reserves an extra label row, which reads as unexplained
        // padding under the titlebar.
        window.toolbar?.displayMode = .iconOnly
        window.toolbarStyle = .unified
        // A hard floor at the AppKit level. SwiftUI's `.frame(minWidth:)` is a
        // layout preference the split view can satisfy by collapsing the
        // sidebar instead of refusing to shrink.
        window.minSize = NSSize(
            width: SettingsView.sidebarWidth + SettingsView.detailMinWidth,
            height: SettingsView.windowMinHeight
        )
    }

    /// Makes the titlebar draggable again after a `Slider` drag.
    ///
    /// Once a slider's tracking loop ends, a titlebar drag stops moving this
    /// window — the press reaches `NSThemeFrame` and nothing moves — until
    /// something makes AppKit hand the window server its drag state again: a
    /// click in the content, a pane switch, a programmatic move. `isMovable`
    /// still reads true and the hit test lands on the toolbar throughout, so
    /// nothing readable is wrong; flipping `isMovable` and back is the public
    /// call that re-sends it (measured: the flip restores the drag, attaching
    /// a debugger alone does not). Restores the prior value rather than
    /// assuming true.
    static func refreshWindowDrag(of window: NSWindow) {
        let movable = window.isMovable
        window.isMovable = !movable
        window.isMovable = movable
    }
}

// MARK: - Shared styling

/// Caption text is plain `Text`, which ignores the `isEnabled` environment
/// that makes native controls draw themselves dimmed inside `.disabled(_:)`
/// scopes — so a caption under a disabled control stayed full-strength while
/// the control above it faded. Reading `\.isEnabled` here (the same value the
/// built-in controls consult) lets every caption follow its group's state.
private struct SettingsCaption: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }
}

/// Primary text that should fade with its `.disabled(_:)` scope. Grouped-form
/// rows draw a control's string-initializer label themselves, outside the
/// control's own disabled rendering — the popup dims, its label doesn't — so
/// controls pass an explicit label `Text` carrying this modifier instead. The
/// label closure evaluates inside the control's scope, where `isEnabled` is
/// already false.
private struct DimsWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    }
}

extension View {
    /// The one style for a control's explanatory line. Every pane's
    /// descriptions went through this by hand before (one had drifted to
    /// `.footnote`), so it lives in a modifier now.
    func settingsCaption() -> some View {
        modifier(SettingsCaption())
    }

    /// Fades primary text to match a disabled control — see `DimsWhenDisabled`.
    func dimsWhenDisabled() -> some View {
        modifier(DimsWhenDisabled())
    }

    @ViewBuilder
    func hidingSidebarToggle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }

    // Drops the sidebar collapse button — there's nothing to reveal when the
    // pane list is the only way to navigate, and the sidebar can't collapse.
    // The API landed in macOS 15; on 14 the pinned `columnVisibility` already
    // makes the button inert, so the older system keeps a harmless no-op
    // control rather than a broken one.
}

/// The one shape for a slider row: fixed-width leading label, the track, and
/// a fixed-width trailing readout. Every slider in Settings renders through
/// this so all tracks start and end at the same x, across rows *and* panes —
/// per-row label widths, or min/max labels on the slider itself, are how
/// tracks drift out of alignment.
private struct SettingsSlider: View {
    /// Wide enough for the longest label ("Background opacity"); shared so
    /// no pane picks its own column and breaks the cross-pane alignment.
    static let labelWidth: CGFloat = 126
    static let valueWidth: CGFloat = 52

    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let display: (Double) -> String

    @State private var host = HostWindow()

    var body: some View {
        // The `Slider` dims itself inside a `.disabled(_:)` scope, but the
        // flanking `Text`s are not controls and wouldn't follow on their own.
        HStack {
            Text(label)
                .frame(width: Self.labelWidth, alignment: .leading)
                .dimsWhenDisabled()
            if let step {
                Slider(value: $value, in: range, step: step, onEditingChanged: editingChanged)
            } else {
                Slider(value: $value, in: range, onEditingChanged: editingChanged)
            }
            Text(display(value))
                .monospacedDigit()
                .frame(width: Self.valueWidth, alignment: .trailing)
                .dimsWhenDisabled()
        }
        .background(HostWindowReader(host: host))
    }

    /// Once a drag ends, restore the window's titlebar drag — see
    /// `SettingsWindowChrome.refreshWindowDrag`. Deferred a turn so the
    /// slider's tracking loop has fully unwound first.
    private func editingChanged(_ editing: Bool) {
        guard !editing else { return }
        DispatchQueue.main.async {
            guard let window = host.window else { return }
            SettingsWindowChrome.refreshWindowDrag(of: window)
        }
    }
}

/// The window a view is in, for the few AppKit calls SwiftUI has no route to.
/// A class so the reader can fill it in without an update cycle.
@MainActor
private final class HostWindow {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context _: Context) -> NSView {
        let view = Probe()
        view.host = host
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? Probe)?.host = host
        host.window = nsView.window
    }

    private final class Probe: NSView {
        weak var host: HostWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }
}

/// Readout for a 0…1 anchor slider: the endpoints and midpoint show their
/// names — the readout is what documents which way the axis runs — and
/// anything in between shows the percent. Stepped slider values accumulate
/// floating-point error, hence the tolerance.
private func anchorName(_ value: Double, zero: String, one: String) -> String {
    if abs(value) < 0.001 { return zero }
    if abs(value - 1) < 0.001 { return one }
    if abs(value - 0.5) < 0.001 {
        return String(localized: "Center", comment: "Settings → Quick Terminal: the middle of a position slider")
    }
    return "\(Int((value * 100).rounded()))%"
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self)
    private var appState

    /// Seeded from and written back through `Preferences` (the single
    /// UserDefaults seam that redirects to a wiped side-suite under XCTest).
    /// NOT `@AppStorage`, which binds to `UserDefaults.standard` — banned by the
    /// project, and it diverged from the `.onChange` write-through under test.
    @State private var autoTilingEnabled: Bool = Preferences.shared.autoTilingEnabled
    @State private var backgroundSSHConnections: Bool = Preferences.shared.backgroundSSHConnections
    @State private var reconnectRemotePanes: Bool = Preferences.shared.reconnectRemotePanes
    @State private var textFilePlacement: TextFilePlacement = Preferences.shared.textFilePlacement
    @State private var appLanguage: String? = Preferences.shared.appLanguage

    /// The text file types that Make Default sets, and the ones whose default
    /// app is another app. Read again on activation, because Finder's Get Info
    /// changes a default while this app is inactive.
    @State private var textFileTypes: [UTType] = TextFileDefaults.contentTypes()
    @State private var textFileTypesNotOpenedHere: [UTType] = []
    @State private var isConfirmingTextFileDefaults = false
    @State private var isSettingTextFileDefaults = false

    /// Why session persistence is inactive, when it is. Missing binary is a
    /// dev-build state; an over-budget socket path is an environment problem
    /// (very long home/TMPDIR paths push past sun_path).
    private var zmxUnavailableReason: String {
        if !ZmxClient.live.isBundled() {
            return String(localized: "Session persistence is off. The zmx binary is not in the app. Run `mise run setup` and build again.")
        }
        return String(
            localized: "Session persistence is off. The zmx socket path of this system is too long. Terminals run with no persistence."
        )
    }

    /// Ghostty's default locations form an optional base layer. Custom files
    /// always load afterward in their displayed order.
    @State
    private var useDefaultGhosttyConfigFiles: Bool = Preferences.shared.ghosttyConfigSelection.loadsDefaultFiles
    @State
    private var customGhosttyConfigPaths: [String] = Preferences.shared.ghosttyConfigSelection.customPaths
    @State
    private var defaultGhosttyConfigFiles: [GhosttyConfigSource.DefaultFileLocation] =
        GhosttyConfigSource.defaultFileLocations()

    /// Which custom-path row is being edited inline, with its draft text.
    /// `customGhosttyConfigPaths.count` marks a new entry being typed via
    /// "Enter Path…". Committed rows render read-only, like the Projects
    /// pane's rows; the text field exists only while adding or editing one.
    @State
    private var editingCustomGhosttyConfigIndex: Int?
    @State
    private var editingCustomGhosttyConfigText: String = ""
    @FocusState
    private var isCustomGhosttyConfigFieldFocused: Bool

    /// Re-probed when the app becomes active, so returning from System
    /// Settings after flipping the toggle clears the banner. `nil` (no
    /// evidence) hides it — never nag about a grant we can't disprove.
    @State
    private var hasFullDiskAccess: Bool? = FullDiskAccess.isGranted()

    /// True only when the user's Ghostty config asks to be notified AND macOS
    /// is dropping what Macterm posts. Both halves change only outside this
    /// window — the config in an editor, the permission in System Settings —
    /// so it's re-read on activation rather than polled. Starts false: the
    /// permission read is async, and flashing a warning during the first frame
    /// would be worse than showing it a beat late.
    @State
    private var notificationsBlocked: Bool = false

    var body: some View {
        Form {
            if hasFullDiskAccess == false {
                FullDiskAccessBanner()
            }

            if notificationsBlocked {
                NotificationPermissionBanner()
            }

            Section {
                Toggle("Load Ghostty's default config files", isOn: $useDefaultGhosttyConfigFiles)
                    .onChange(of: useDefaultGhosttyConfigFiles) { _, _ in
                        commitCustomGhosttyConfigEdit()
                        commitGhosttyConfig()
                    }

                if useDefaultGhosttyConfigFiles {
                    defaultGhosttyLocationRows
                }
                ghosttyConfigFileRows

                HStack {
                    Text("Macterm loads the files from top to bottom. A later file overrides an earlier file.")
                        .settingsCaption()
                    Spacer()
                    Button("Reload") {
                        commitGhosttyConfig()
                    }
                    .help("Read your Ghostty config again. Click after you save an edit in another app.")
                }
            } header: {
                DocsSectionHeader("Ghostty Config", docs: .ghosttyConfig) {
                    // Mirrors the Projects pane's add affordance: a plus in the
                    // header, with the creation paths in its menu.
                    Menu {
                        Button("Choose Files…") { browseForCustomGhosttyConfigFiles() }
                        Button("Enter Path…") { beginEnteringCustomGhosttyConfigPath() }
                    } label: {
                        Label("Add Config File", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a config file")
                }
            }

            Section("Layout") {
                Toggle("Auto-tile panes", isOn: $autoTilingEnabled)
                    .onChange(of: autoTilingEnabled) { _, v in
                        Preferences.shared.autoTilingEnabled = v
                    }
                Text("Gives all panes the same size when you split or close a pane.")
                    .settingsCaption()
            }

            Section {
                Picker("Open in", selection: $textFilePlacement) {
                    ForEach(TextFilePlacement.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: textFilePlacement) { _, v in
                    Preferences.shared.textFilePlacement = v
                }
                LabeledContent("Default app") {
                    if textFileTypesNotOpenedHere.isEmpty {
                        Text(verbatim: "Macterm")
                    } else {
                        Button("Make Default…") { isConfirmingTextFileDefaults = true }
                            .disabled(isSettingTextFileDefaults)
                    }
                }
                Text(textFileDefaultsCaption)
                    .settingsCaption()
            } header: {
                DocsSectionHeader("Opening Text Files", docs: .textFiles)
            }

            Section {
                Toggle("Background SSH connections", isOn: $backgroundSSHConnections)
                    .onChange(of: backgroundSSHConnections) { _, v in
                        Preferences.shared.backgroundSSHConnections = v
                    }
                Text("Enable for live tab names and close warnings.")
                    .settingsCaption()
                Toggle("Reconnect panes after a dropped connection", isOn: $reconnectRemotePanes)
                    .onChange(of: reconnectRemotePanes) { _, v in
                        Preferences.shared.reconnectRemotePanes = v
                    }
                Text("Connects a disconnected pane to its session again when you wake the Mac or return to the app.")
                    .settingsCaption()
            } header: {
                DocsSectionHeader("Remote Projects", docs: .remoteProjects)
            }

            // Shells always keep running after quit and reattach on the next
            // launch — there's no setting, so the section exists only to report
            // that persistence is unavailable. It can be silently so (Supacode
            // shipped the same probe and users only noticed via a buried log
            // line), which is the whole reason to say it in the UI at all.
            if ZmxClient.live.executableURL() == nil {
                Section("Session Persistence") {
                    Label {
                        Text(zmxUnavailableReason)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(MactermTheme.warning)
                }
            }

            Section("Language") {
                Picker("Language", selection: $appLanguage) {
                    Text("System", comment: "Settings → General → Language: follow the language of macOS")
                        .tag(String?.none)
                    // Each language in its own name, so a user who cannot
                    // read the current language still finds their own.
                    ForEach(AppLanguage.available, id: \.self) { code in
                        Text(verbatim: AppLanguage.nativeName(of: code)).tag(String?.some(code))
                    }
                }
                .onChange(of: appLanguage) { _, v in
                    Preferences.shared.appLanguage = v
                }
            }
        }
        .formStyle(.grouped)
        // Granting FDA happens in System Settings, so the state can only have
        // changed while this app was inactive — re-probe on every activation
        // rather than polling.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted()
            refreshTextFileDefaults()
            // Default files are created and deleted in other apps, so
            // discovery can only have changed while we were inactive.
            defaultGhosttyConfigFiles = GhosttyConfigSource.defaultFileLocations()
            Task { await refreshNotificationBanner() }
        }
        .task { await refreshNotificationBanner() }
        .onAppear { refreshTextFileDefaults() }
        .onChange(of: isCustomGhosttyConfigFieldFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused else { return }
            commitCustomGhosttyConfigEdit()
        }
        .alert("Make Macterm the default app for text files?", isPresented: $isConfirmingTextFileDefaults) {
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.cancelAction)
            Button("Make Default") { makeTextFileDefaults() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("""
            Finder opens \(textFileTypesNotOpenedHere.count) more text file types with Macterm. \
            To change a type back, select a file in Finder, choose File → Get Info and change Open with.
            """)
        }
    }

    private var textFileDefaultsCaption: String {
        let notOpenedHere = textFileTypesNotOpenedHere.count
        if notOpenedHere == 0 {
            return String(localized: """
            Finder opens text files with Macterm. Macterm opens them in the editor that \
            $VISUAL or $EDITOR names in your shell.
            """)
        }
        return String(localized: """
        Macterm is the default app of \(textFileTypes.count - notOpenedHere) of \(textFileTypes.count) \
        text file types. It opens them in the editor that $VISUAL or $EDITOR names in your shell.
        """)
    }

    private func refreshTextFileDefaults() {
        textFileTypesNotOpenedHere = TextFileDefaults.typesNotOpenedHere(textFileTypes)
    }

    private func makeTextFileDefaults() {
        let types = textFileTypesNotOpenedHere
        isSettingTextFileDefaults = true
        Task {
            _ = await TextFileDefaults.makeDefault(types)
            isSettingTextFileDefaults = false
            refreshTextFileDefaults()
        }
    }

    /// Cheap half first: an unreadable or notification-free config skips the
    /// permission round-trip entirely, and — because the config is the gate —
    /// a user who never asked for notifications is never told about them.
    private func refreshNotificationBanner() async {
        guard NotificationConfigIntent.wantsNotifications(
            inConfigText: MactermConfig.userGhosttyConfigText()
        )
        else {
            notificationsBlocked = false
            return
        }
        notificationsBlocked = await NotificationHandler.isDelivering() == false
    }

    /// The discovered default locations are read-only because Ghostty owns
    /// their discovery and load order.
    @ViewBuilder
    private var defaultGhosttyLocationRows: some View {
        let found = defaultGhosttyConfigFiles.filter { $0.resolvedPath != nil }
        ForEach(found) { file in
            GhosttyDefaultLocationRow(file: file) { openGhosttyConfigFile(file.searchedPath) }
        }
        if found.isEmpty {
            Text("No default config files found.")
                .foregroundStyle(.secondary)
        }
    }

    /// The config-file rows plus the inline editor and empty state, shared by
    /// the enabled and dimmed branches of the section.
    @ViewBuilder
    private var ghosttyConfigFileRows: some View {
        ForEach(customGhosttyConfigPaths.indices, id: \.self) { index in
            if editingCustomGhosttyConfigIndex == index {
                editingCustomGhosttyConfigRow
            } else {
                GhosttyConfigFileRow(
                    path: customGhosttyConfigPaths[index],
                    problem: customGhosttyConfigProblem(customGhosttyConfigPaths[index]),
                    canMoveUp: index > 0,
                    canMoveDown: index < customGhosttyConfigPaths.count - 1,
                    onOpen: { openGhosttyConfigFile(customGhosttyConfigPaths[index]) },
                    onEdit: { beginEditingCustomGhosttyConfigPath(at: index) },
                    onMoveUp: { moveCustomGhosttyConfigPath(at: index, by: -1) },
                    onMoveDown: { moveCustomGhosttyConfigPath(at: index, by: 1) },
                    onRemove: { removeCustomGhosttyConfigPath(at: index) }
                )
            }
        }
        if editingCustomGhosttyConfigIndex == customGhosttyConfigPaths.count {
            editingCustomGhosttyConfigRow
        }

        if customGhosttyConfigPaths.isEmpty, editingCustomGhosttyConfigIndex == nil {
            Text("No additional config files.")
                .foregroundStyle(.secondary)
        }
    }

    /// The one inline text field, shown in place of the row being edited (or
    /// appended for a new entry). Same leading icon as the committed rows so
    /// the list keeps its shape while a path is typed.
    private var editingCustomGhosttyConfigRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField(
                "Config file path",
                text: $editingCustomGhosttyConfigText,
                prompt: Text(verbatim: "~/.config/ghostty/config")
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($isCustomGhosttyConfigFieldFocused)
            .onSubmit { commitCustomGhosttyConfigEdit() }
        }
        .padding(.vertical, 2)
    }

    /// Open a listed config file in the terminal editor, the way Open Macterm
    /// Config does.
    private func openGhosttyConfigFile(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        appState.appDelegate?.finderServices.openTextFiles([expanded])
    }

    /// Persist both config layers together, then reload once.
    private func commitGhosttyConfig() {
        let customPaths = customGhosttyConfigPaths.filter { !$0.isEmpty }
        let selection = GhosttyConfigSelection(
            loadsDefaultFiles: useDefaultGhosttyConfigFiles,
            customPaths: customPaths
        )
        if selection != Preferences.shared.ghosttyConfigSelection {
            Preferences.shared.setGhosttyConfig(
                loadsDefaultFiles: useDefaultGhosttyConfigFiles,
                customPaths: customPaths
            )
        }
        GhosttyApp.shared.reloadAndReport()
        defaultGhosttyConfigFiles = GhosttyConfigSource.defaultFileLocations()
    }

    /// Why a custom entry gets the warning icon, or nil when it's a plausible
    /// config file. Existence only — parse errors surface through the reload
    /// alert instead, and note a TCC-protected file can read as missing until
    /// Full Disk Access is granted (the banner above covers that case).
    private func customGhosttyConfigProblem(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return String(localized: "File not found.")
        }
        return isDirectory.boolValue ? String(localized: "Not a file.") : nil
    }

    /// Expanded forms of every path already in the list, so adds and edits
    /// refuse duplicates.
    private func expandedListedGhosttyConfigPaths(excludingCustomIndex excluded: Int? = nil) -> Set<String> {
        var listed = Set<String>()
        for (index, path) in customGhosttyConfigPaths.enumerated() where index != excluded {
            listed.insert((path as NSString).expandingTildeInPath)
        }
        return listed
    }

    private func beginEnteringCustomGhosttyConfigPath() {
        guard finishPendingCustomGhosttyConfigEdit() else { return }
        editingCustomGhosttyConfigText = ""
        editingCustomGhosttyConfigIndex = customGhosttyConfigPaths.count
        isCustomGhosttyConfigFieldFocused = true
    }

    private func beginEditingCustomGhosttyConfigPath(at index: Int) {
        guard finishPendingCustomGhosttyConfigEdit() else { return }
        editingCustomGhosttyConfigText = customGhosttyConfigPaths[index]
        editingCustomGhosttyConfigIndex = index
        isCustomGhosttyConfigFieldFocused = true
    }

    /// Fold the in-flight edit back into the list: empty text removes the row
    /// (or abandons a new entry), anything else replaces or appends. A path
    /// the list already shows is refused — an edit keeps the row's previous
    /// value, an add is dropped. Persists and reloads only when the list
    /// actually changed, so blurring an untouched field doesn't churn the
    /// config.
    private func commitCustomGhosttyConfigEdit() {
        guard let index = editingCustomGhosttyConfigIndex else { return }
        editingCustomGhosttyConfigIndex = nil
        isCustomGhosttyConfigFieldFocused = false
        let trimmed = editingCustomGhosttyConfigText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingCustomGhosttyConfigText = ""
        let expanded = (trimmed as NSString).expandingTildeInPath
        let before = customGhosttyConfigPaths
        if index < customGhosttyConfigPaths.count {
            if trimmed.isEmpty {
                customGhosttyConfigPaths.remove(at: index)
            } else if !expandedListedGhosttyConfigPaths(excludingCustomIndex: index).contains(expanded) {
                customGhosttyConfigPaths[index] = trimmed
            }
        } else if !trimmed.isEmpty, !expandedListedGhosttyConfigPaths().contains(expanded) {
            customGhosttyConfigPaths.append(trimmed)
        }
        if customGhosttyConfigPaths != before {
            commitGhosttyConfig()
        }
    }

    /// Row actions capture their index at render time, so an action arriving
    /// while an inline edit is pending would apply to a possibly-shifted row.
    /// Commit the edit and report `false` so the caller drops its action; the
    /// re-rendered rows carry fresh indices for the next click.
    private func finishPendingCustomGhosttyConfigEdit() -> Bool {
        guard editingCustomGhosttyConfigIndex != nil else { return true }
        commitCustomGhosttyConfigEdit()
        return false
    }

    private func moveCustomGhosttyConfigPath(at index: Int, by offset: Int) {
        guard finishPendingCustomGhosttyConfigEdit() else { return }
        let destination = index + offset
        guard customGhosttyConfigPaths.indices.contains(index),
              customGhosttyConfigPaths.indices.contains(destination)
        else { return }
        customGhosttyConfigPaths.swapAt(index, destination)
        commitGhosttyConfig()
    }

    private func removeCustomGhosttyConfigPath(at index: Int) {
        guard finishPendingCustomGhosttyConfigEdit() else { return }
        guard customGhosttyConfigPaths.indices.contains(index) else { return }
        customGhosttyConfigPaths.remove(at: index)
        commitGhosttyConfig()
    }

    private func browseForCustomGhosttyConfigFiles() {
        commitCustomGhosttyConfigEdit()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Add", comment: "Settings → General: the button of the open panel that adds Ghostty config files")
        // Start beside the last selected file instead of at a generic location.
        if let lastPath = customGhosttyConfigPaths.last {
            let expandedPath = (lastPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expandedPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK else { return }
        addCustomGhosttyConfigPaths(panel.urls.map { $0.path(percentEncoded: false) })
    }

    private func addCustomGhosttyConfigPaths(_ paths: [String]) {
        var listed = expandedListedGhosttyConfigPaths()
        let additions = paths.compactMap { path -> String? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard !listed.contains(expanded) else { return nil }
            listed.insert(expanded)
            return trimmed
        }
        guard !additions.isEmpty else { return }
        customGhosttyConfigPaths.append(contentsOf: additions)
        commitGhosttyConfig()
    }
}

// MARK: - Ghostty config rows

/// One discovered default location, read-only: Ghostty's own loader owns
/// this set and its order, so the row just shows what was found (and where a
/// symlink leads). A click on the path opens the file in the terminal editor.
/// Customization happens in the custom list instead.
private struct GhosttyDefaultLocationRow: View {
    let file: GhosttyConfigSource.DefaultFileLocation
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Button((file.searchedPath as NSString).abbreviatingWithTildeInPath, action: onOpen)
                    .buttonStyle(.link)
                    .linkPointer()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.searchedPath)
                if let resolved = file.resolvedPath, resolved != file.searchedPath {
                    Text("Resolves to \((resolved as NSString).abbreviatingWithTildeInPath)")
                        .settingsCaption()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(resolved)
                }
            }

            Spacer(minLength: 8)

            Text("Ghostty default")
                .settingsCaption()
                .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

/// One custom config file: its path and its actions in a menu — the same row
/// shape as the Projects pane. Move Up/Down matter because later files
/// override earlier ones. A click on the path opens the file in the terminal
/// editor. A non-nil `problem` swaps the file icon for a
/// warning triangle whose tooltip carries the reason, keeping the row
/// single-line.
private struct GhosttyConfigFileRow: View {
    let path: String
    let problem: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let problem {
                // A control, not a bare image: tooltips are only dependable
                // on controls in this context, and the natural click-through
                // for a broken path is fixing it.
                Button(action: onEdit) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(MactermTheme.warning)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help(problem)
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }

            // A missing file has nothing to open; the warning icon edits it.
            Button((path as NSString).abbreviatingWithTildeInPath, action: onOpen)
                .buttonStyle(.link)
                .lineLimit(1)
                .truncationMode(.middle)
                .disabled(problem != nil)
                .linkPointer(problem == nil)
                .help(path)

            Spacer(minLength: 8)

            Menu {
                Button("Edit Path") { onEdit() }

                Divider()

                Button("Move Up") { onMoveUp() }
                    .disabled(!canMoveUp)

                Button("Move Down") { onMoveDown() }
                    .disabled(!canMoveDown)

                Divider()

                Button("Remove", role: .destructive) { onRemove() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

private extension View {
    /// The pointing hand over a path that a click opens. macOS 14 has no
    /// link pointer and keeps the arrow.
    @ViewBuilder
    func linkPointer(_ isActive: Bool = true) -> some View {
        if #available(macOS 15.0, *), isActive {
            pointerStyle(.link)
        } else {
            self
        }
    }
}

// MARK: - Full Disk Access banner

/// Shown in General settings while macOS hasn't granted the app Full Disk
/// Access. Without it, TCC prompts folder by folder (Documents, Downloads, …)
/// as terminal commands first touch each one; one FDA grant covers them all —
/// and persists across updates, now that releases are signed with a stable
/// certificate. FDA can't be requested programmatically (there is no prompt to
/// trigger), so the button deep-links to the System Settings pane and
/// `GeneralSettings` re-probes when the app becomes active again.
private struct FullDiskAccessBanner: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full Disk Access is off")
                        .font(.system(size: 13, weight: .semibold))
                    Text("""
                    macOS asks for each folder when a terminal command reads Documents, Downloads \
                    or other protected places. One Full Disk Access grant covers all of them.
                    """)
                    .settingsCaption()
                    if let url = FullDiskAccess.settingsURL {
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MactermTheme.warning)
            }
            .padding(.vertical, 2)
        }
    }
}

/// Shown when the Ghostty config asks to be notified but macOS won't deliver.
///
/// The permission is one-shot: macOS presents its prompt the first time an app
/// asks and never again, so once it has been answered — or dismissed — the app
/// cannot re-raise it, and a denied Macterm is silent with nothing on screen to
/// explain why. System Settings is the only way back, which is what makes this
/// worth a banner rather than a log line.
private struct NotificationPermissionBanner: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Macterm has no notification permission")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Your Ghostty config asks for notifications.")
                        .settingsCaption()
                    if let url = NotificationHandler.settingsURL {
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MactermTheme.warning)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    // Seeded from / written back through `Preferences` (see GeneralSettings) —
    // not `@AppStorage`, which would bind to the banned `UserDefaults.standard`.
    @State private var projectIconSymbol: String = Preferences.shared.projectIconSymbol
    @State private var tabIconSymbol: String = Preferences.shared.tabIconSymbol
    @State private var sidebarIconSize: String = Preferences.shared.sidebarIconSize.rawValue
    @State private var showAgentIcons: Bool = Preferences.shared.showAgentIcons
    @State private var showTabStatusIndicator: Bool = Preferences.shared.showTabStatusIndicator
    @State private var showSpinnerOverAgentIcons: Bool = Preferences.shared.showSpinnerOverAgentIcons
    @State private var autoAssignProjectColors: Bool = Preferences.shared.autoAssignProjectColors
    @State private var peekSidebarWhenHidden: Bool = Preferences.shared.peekSidebarWhenHidden
    @State private var showNewProjectButton: Bool = Preferences.shared.showNewProjectButton
    @State private var showProjectNewTabButton: Bool = Preferences.shared.showProjectNewTabButton
    @State private var showTabSwitcherOverlay: Bool = Preferences.shared.showTabSwitcherOverlay
    @State private var recentTabCandidates: Int = Preferences.shared.recentTabCandidates
    @State
    private var backgroundOpacity: Double = Preferences.shared.windowOpacity
    @State
    private var backgroundBlurRadius: Double = .init(Preferences.shared.windowBlurRadius)
    @State
    private var liquidGlass: Bool = Preferences.shared.windowGlassEnabled
    @State
    private var liquidGlassStyle: WindowGlassStyle = Preferences.shared.windowGlassStyle
    @State
    private var adaptiveTerminalChrome: Bool = Preferences.shared.adaptiveTerminalChromeEnabled
    @State
    private var sidebarPeekStyle: SidebarPeekStyle = Preferences.shared.sidebarPeekStyle
    /// The toolbar controls bind to `Preferences` directly rather than a
    /// seeded `@State` copy: each can also change from the toolbar's own
    /// right-click menu (`ToolbarMenu`), and a copy would go stale under an
    /// open Settings window.
    @Bindable private var preferences = Preferences.shared

    /// Inverted view of `Preferences.hideTitleBar`: the control reads as
    /// "Show toolbar" (on by default), the preference stores the hide.
    private var showToolbar: Binding<Bool> {
        Binding(
            get: { !preferences.hideTitleBar },
            set: { preferences.hideTitleBar = !$0 }
        )
    }

    var body: some View {
        Form {
            Section("Window") {
                SettingsSlider(
                    label: "Background opacity",
                    value: $backgroundOpacity,
                    range: 0.0 ... 1.0,
                    step: nil,
                    display: { "\(Int(($0 * 100).rounded()))%" }
                )
                .onChange(of: backgroundOpacity) { _, v in
                    Preferences.shared.windowOpacity = v
                }

                // Liquid glass (NSGlassEffectView) exists only on macOS 26+;
                // hide the control entirely on older systems where it'd be
                // inert rather than show a dead picker. "None" off / a style on
                // are folded into one picker over the two underlying prefs.
                if WindowAppearance.glassSupported {
                    Picker(selection: glassSelection) {
                        Text("None").tag(WindowGlassStyle?.none)
                        ForEach(WindowGlassStyle.allCases) { style in
                            Text(style.displayName).tag(WindowGlassStyle?.some(style))
                        }
                    } label: {
                        Text("Liquid Glass").dimsWhenDisabled()
                    }
                    .disabled(backgroundOpacity >= 0.999)
                }

                SettingsSlider(
                    label: "Background blur",
                    value: $backgroundBlurRadius,
                    range: 0 ... 100,
                    step: nil,
                    display: { "\(Int($0.rounded()))%" }
                )
                .onChange(of: backgroundBlurRadius) { _, v in
                    Preferences.shared.windowBlurRadius = Int(v.rounded())
                }
                .disabled(backgroundOpacity >= 0.999 || liquidGlass)

                if let blurFootnote {
                    Text(blurFootnote)
                        .settingsCaption()
                }

                Toggle("Adaptive background", isOn: $adaptiveTerminalChrome)
                    .onChange(of: adaptiveTerminalChrome) { _, enabled in
                        Preferences.shared.adaptiveTerminalChromeEnabled = enabled
                    }
                Text("The background matches the color of each full-screen program.")
                    .settingsCaption()
            }

            // The icon is Liquid Glass, which only macOS 26 and later draw.
            if AdaptiveIcon.systemDrawsGlassIcons {
                Section("App Icon") {
                    Toggle("Adaptive icon", isOn: $preferences.adaptiveIcon)
                    Text("The Dock icon shows the colors of your terminal theme.")
                        .settingsCaption()
                }
            }

            Section("Sidebar") {
                Toggle("Peek sidebar when hidden", isOn: $peekSidebarWhenHidden)
                    .onChange(of: peekSidebarWhenHidden) { _, v in Preferences.shared.peekSidebarWhenHidden = v }

                Group {
                    Picker(selection: $sidebarPeekStyle) {
                        ForEach(SidebarPeekStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    } label: {
                        Text("Peek style").dimsWhenDisabled()
                    }
                    .onChange(of: sidebarPeekStyle) { _, style in
                        Preferences.shared.sidebarPeekStyle = style
                    }
                }
                .disabled(!peekSidebarWhenHidden)
                .padding(.leading, 16)

                Picker("Project icon", selection: $projectIconSymbol) {
                    ForEach(Preferences.projectIconChoices, id: \.self) { name in
                        iconPickerLabel(name).tag(name)
                    }
                }
                .onChange(of: projectIconSymbol) { _, v in Preferences.shared.projectIconSymbol = v }

                Picker("Tab icon", selection: $tabIconSymbol) {
                    ForEach(Preferences.tabIconChoices, id: \.self) { name in
                        iconPickerLabel(name).tag(name)
                    }
                }
                .onChange(of: tabIconSymbol) { _, v in Preferences.shared.tabIconSymbol = v }

                Picker("Icon size", selection: $sidebarIconSize) {
                    ForEach(SidebarIconSize.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .onChange(of: sidebarIconSize) { _, v in
                    Preferences.shared.sidebarIconSize = SidebarIconSize(rawValue: v) ?? .medium
                }

                Toggle("Auto-assign project colors", isOn: $autoAssignProjectColors)
                    .onChange(of: autoAssignProjectColors) { _, v in
                        Preferences.shared.autoAssignProjectColors = v
                    }

                Toggle("Show AI agent icons", isOn: $showAgentIcons)
                    .onChange(of: showAgentIcons) { _, v in
                        Preferences.shared.showAgentIcons = v
                    }

                Toggle("Show tab status indicator", isOn: $showTabStatusIndicator)
                    .onChange(of: showTabStatusIndicator) { _, v in
                        Preferences.shared.showTabStatusIndicator = v
                    }
                Text("Shows a spinner while a command runs. Shows a dot when the command ends.")
                    .settingsCaption()

                Group {
                    Toggle(isOn: $showSpinnerOverAgentIcons) {
                        Text("Show spinner over agent icons").dimsWhenDisabled()
                    }
                    .onChange(of: showSpinnerOverAgentIcons) { _, v in
                        Preferences.shared.showSpinnerOverAgentIcons = v
                    }
                }
                .disabled(!(showTabStatusIndicator && showAgentIcons))
                .padding(.leading, 16)

                Toggle("Show new project button", isOn: $showNewProjectButton)
                    .onChange(of: showNewProjectButton) { _, v in Preferences.shared.showNewProjectButton = v }

                Toggle("Show new tab button on projects", isOn: $showProjectNewTabButton)
                    .onChange(of: showProjectNewTabButton) { _, v in
                        Preferences.shared.showProjectNewTabButton = v
                    }
            }

            Section("Tab Switching") {
                Toggle("Show tab previews", isOn: $showTabSwitcherOverlay)
                    .onChange(of: showTabSwitcherOverlay) { _, v in
                        Preferences.shared.showTabSwitcherOverlay = v
                    }

                Picker("Recent tabs limit", selection: $recentTabCandidates) {
                    ForEach(Preferences.recentTabCandidateRange, id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                    Text("Unlimited").tag(Preferences.unlimitedRecentTabCandidates)
                }
                .onChange(of: recentTabCandidates) { _, v in
                    Preferences.shared.recentTabCandidates = v
                }
            }

            Section("Toolbar") {
                Toggle("Show toolbar", isOn: showToolbar)

                Group {
                    Picker(selection: $preferences.tabSwitcherVisibility) {
                        ForEach(TabSwitcherVisibility.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    } label: {
                        Text("Tab switcher").dimsWhenDisabled()
                    }

                    Picker(selection: $preferences.tabSwitcherPosition) {
                        ForEach(TabSwitcherPosition.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    } label: {
                        Text("Tab switcher position").dimsWhenDisabled()
                    }
                }
                .disabled(preferences.hideTitleBar)
            }
        }
        .formStyle(.grouped)
    }

    /// One picker over the two glass prefs: `nil` ("None") means disabled, a
    /// concrete style means enabled with that material. The remembered style is
    /// preserved across a None round-trip — picking None only flips the enabled
    /// flag, so re-selecting glass restores the last material.
    private var glassSelection: Binding<WindowGlassStyle?> {
        Binding(
            get: { liquidGlass ? liquidGlassStyle : nil },
            set: { selection in
                if let selection {
                    liquidGlassStyle = selection
                    Preferences.shared.windowGlassStyle = selection
                    liquidGlass = true
                } else {
                    liquidGlass = false
                }
                Preferences.shared.windowGlassEnabled = liquidGlass
            }
        )
    }

    private var blurFootnote: String? {
        if backgroundOpacity >= 0.999 {
            return WindowAppearance.glassSupported
                ? String(localized: "Blur and Liquid Glass work only when opacity is below 100%.")
                : String(localized: "Blur works only when opacity is below 100%.")
        }
        if liquidGlass { return nil }
        return String(localized: "Set blur to 0 to turn it off.")
    }

    @ViewBuilder
    private func iconPickerLabel(_ name: String) -> some View {
        switch name {
        case Preferences.noIcon:
            Text("None")
        case Preferences.numberIconCircleFill:
            Label("Number — filled circle", systemImage: "1.circle.fill")
        case Preferences.numberIconCircle:
            Label("Number — circle", systemImage: "1.circle")
        case Preferences.numberIconSquareFill:
            Label("Number — filled square", systemImage: "1.square.fill")
        case Preferences.numberIconSquare:
            Label("Number — square", systemImage: "1.square")
        case Preferences.numberIconPlain:
            Label("Number", systemImage: "number")
        default:
            Label(name, systemImage: name)
        }
    }
}

// MARK: - Animations

/// Motion: what moves, and how. Smooth scrolling and split animations are on
/// by default; the two cursor effects stay opt-in, since they change how the
/// focused cursor is drawn.
private struct AnimationsSettings: View {
    @State
    private var smoothScrolling: Bool = Preferences.shared.smoothScrolling
    @State
    private var snapScrollToRow: Bool = Preferences.shared.snapScrollToRow
    @State
    private var smoothCursor: Bool = Preferences.shared.smoothCursor
    @State
    private var cursorTrail: Bool = Preferences.shared.cursorTrail
    @State
    private var animatedSplits: Bool = Preferences.shared.animatedSplits

    var body: some View {
        Form {
            Section {
                Toggle("Smooth scrolling", isOn: $smoothScrolling)
                    .onChange(of: smoothScrolling) { _, v in
                        Preferences.shared.smoothScrolling = v
                    }

                Group {
                    Toggle(isOn: $snapScrollToRow) {
                        Text("Snap to whole row").dimsWhenDisabled()
                    }
                    .onChange(of: snapScrollToRow) { _, v in
                        Preferences.shared.snapScrollToRow = v
                    }
                    Text("Scrolling moves one whole row at a time. Each row slides into place.")
                        .settingsCaption()
                }
                .disabled(!smoothScrolling)
                .padding(.leading, 16)
            } header: {
                DocsSectionHeader("Scrolling", docs: .animations)
            }

            Section {
                Toggle("Smooth cursor", isOn: $smoothCursor)
                    .onChange(of: smoothCursor) { _, v in
                        Preferences.shared.smoothCursor = v
                    }
                Text("The cursor glides between positions. It does not jump.")
                    .settingsCaption()

                Toggle("Cursor trail", isOn: $cursorTrail)
                    .onChange(of: cursorTrail) { _, v in
                        Preferences.shared.cursorTrail = v
                    }
                Text("A fading streak follows the cursor on larger moves.")
                    .settingsCaption()
            } header: {
                DocsSectionHeader("Cursor", docs: .animations)
            }

            Section {
                Toggle("Animate splits", isOn: $animatedSplits)
                    .onChange(of: animatedSplits) { _, v in
                        Preferences.shared.animatedSplits = v
                    }
            } header: {
                DocsSectionHeader("Splits", docs: .animations)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Quick Terminal

private struct QuickTerminalSettings: View {
    @State
    private var positionMode: QuickTerminalAdjustMode = Preferences.shared.quickTerminalPositionMode
    @State
    private var fixedX: Double = Preferences.shared.quickTerminalFixedX
    /// The Y slider reads Top…Bottom; placement fractions run bottom-up, so
    /// this state is the inverted view of `quickTerminalFixedY`.
    @State
    private var fixedYTopDown: Double = 1 - Preferences.shared.quickTerminalFixedY
    @State
    private var sizeMode: QuickTerminalAdjustMode = Preferences.shared.quickTerminalSizeMode
    @State
    private var qtWidth: Double = Preferences.shared.quickTerminalWidthFraction
    @State
    private var qtHeight: Double = Preferences.shared.quickTerminalHeightFraction

    var body: some View {
        Form {
            Section {
                LabeledContent(
                    "Shortcut",
                    value: HotkeyRegistry.displayString(
                        for: HotkeyRegistry.selectedShortcutString(for: .toggleQuickTerminal)
                    )
                )
                Text("Works when Macterm is not the active app.")
                    .settingsCaption()
            } header: {
                DocsSectionHeader("Quick Terminal", docs: .quickTerminal)
            }

            Section {
                Picker("Mode", selection: $positionMode) {
                    ForEach(QuickTerminalAdjustMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: positionMode) { _, v in
                    Preferences.shared.quickTerminalPositionMode = v
                }

                SettingsSlider(
                    label: "X",
                    value: $fixedX,
                    range: 0 ... 1,
                    step: 0.05,
                    display: {
                        anchorName(
                            $0,
                            zero: String(localized: "Left", comment: "Settings → Quick Terminal: the left end of the X position slider"),
                            one: String(localized: "Right", comment: "Settings → Quick Terminal: the right end of the X position slider")
                        )
                    }
                )
                .onChange(of: fixedX) { _, v in
                    Preferences.shared.quickTerminalFixedX = v
                }
                .disabled(positionMode != .fixed)

                SettingsSlider(
                    label: "Y",
                    value: $fixedYTopDown,
                    range: 0 ... 1,
                    step: 0.05,
                    display: {
                        anchorName(
                            $0,
                            zero: String(localized: "Top", comment: "Settings → Quick Terminal: the top end of the Y position slider"),
                            one: String(localized: "Bottom", comment: "Settings → Quick Terminal: the bottom end of the Y position slider")
                        )
                    }
                )
                .onChange(of: fixedYTopDown) { _, v in
                    Preferences.shared.quickTerminalFixedY = 1 - v
                }
                .disabled(positionMode != .fixed)
            } header: {
                DocsSectionHeader("Position", docs: .quickTerminalGeometry)
            }

            Section {
                Picker("Mode", selection: $sizeMode) {
                    ForEach(QuickTerminalAdjustMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: sizeMode) { _, v in
                    Preferences.shared.quickTerminalSizeMode = v
                }

                SettingsSlider(
                    label: "Width",
                    value: $qtWidth,
                    range: 0.2 ... 1.0,
                    step: 0.05,
                    display: { "\(Int(($0 * 100).rounded()))%" }
                )
                .onChange(of: qtWidth) { _, v in
                    Preferences.shared.quickTerminalWidthFraction = v
                }
                .disabled(sizeMode != .fixed)

                SettingsSlider(
                    label: "Height",
                    value: $qtHeight,
                    range: 0.2 ... 1.0,
                    step: 0.05,
                    display: { "\(Int(($0 * 100).rounded()))%" }
                )
                .onChange(of: qtHeight) { _, v in
                    Preferences.shared.quickTerminalHeightFraction = v
                }
                .disabled(sizeMode != .fixed)
            } header: {
                DocsSectionHeader("Size", docs: .quickTerminalGeometry)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keymaps

private struct KeymapSettings: View {
    @Environment(AppState.self)
    private var appState

    /// Every binding's chord by row id: `HotkeyAction.id`s and the custom
    /// palettes' `PaletteHotkeys.rowID`s together, so the conflict check
    /// sees both tables.
    @State
    private var values: [String: String]
    @State
    private var passthrough: [String: Bool]
    @State
    private var global: [String: Bool]
    @State
    private var capturingActionID: String?
    @State
    private var query = ""
    /// The blocks the user folded. A search folds in its own set, cleared
    /// with each change of the query, so its matches always show and the
    /// folds of the plain list come back when the search ends.
    @State
    private var collapsed: Set<KeymapGroup> = []
    @State
    private var collapsedInSearch: Set<KeymapGroup> = []

    /// A block of the table that folds: one command category, or the
    /// palettes of the installed extensions.
    private enum KeymapGroup: Hashable {
        case category(AppCommand.Category)
        case extensions
    }

    private static let extensionsTitle = String(
        localized: "Extensions",
        comment: "Settings → Keymaps: the group of the keybinds of extension palettes"
    )

    /// Observed so a chord the system refuses to register shows its reason
    /// under the row the moment the toggle or the rebind lands.
    private let globalHotkeys = GlobalHotkeys.shared

    /// Column geometry, shared by every row so the keybind buttons line up
    /// down the table.
    ///
    /// Alignment holds only because every row ends in the SAME children — a
    /// flexible spacer, then two fixed-width boxes — with an explicit
    /// `columnGap`. Both are load-bearing: SwiftUI's default `HStack` spacing
    /// varies with the *types* of the adjacent views (two Texts space
    /// differently than a Text and a Button), and because the spacer pins
    /// everything after it to the trailing edge, one extra child or one wider
    /// trailing view shifts that row's columns out of line with the others.
    /// Don't add a control to a row without giving it a box here.
    private static let columnGap: CGFloat = 8
    private static let keybindColumn: CGFloat = 140
    private static let menuColumn: CGFloat = 24
    private static let warningColumn: CGFloat = 16
    private static let trailingColumn: CGFloat = menuColumn + warningColumn
    /// How far the rows of a category sit in from its header row.
    private static let groupIndent: CGFloat = 16

    /// Short enough for a menu item; the precise rule lives in the item's
    /// tooltip rather than a description line under every row.
    fileprivate static let passthroughTitle = String(
        localized: "Pass to TUI",
        comment: "Settings → Keymaps: the row menu item that gives a chord to a full-screen program"
    )
    fileprivate static let passthroughHelp = String(localized: """
    When one of the programs listed at the top of this tab is running in the \
    focused pane, send this chord to it instead of running the action. \
    Everywhere else the action still runs.
    """)

    fileprivate static let globalTitle = String(
        localized: "Global",
        comment: "Settings → Keymaps: the row menu item that registers a chord system-wide"
    )
    fileprivate static let globalHelp = String(localized: """
    Register this chord system-wide, so it runs the action while another app \
    is frontmost. The chord then belongs to Macterm everywhere — no other app \
    can see it, and it can no longer pass through to a program.
    """)

    /// What every row reads, built once for each render of the body: a scan
    /// of every binding for each row parsed about ten thousand chords, and a
    /// read of the theme color for each row read the ghostty palette through
    /// the C config a hundred times. Both slowed the pane to open.
    private struct RowContext {
        /// The bindings that share each chord, keyed by
        /// `HotkeyRegistry.conflictKey`, in table order.
        let chords: [String: [(rowID: String, title: String)]]
        let warning: Color
    }

    private func rowContext() -> RowContext {
        RowContext(chords: bindingsByChord(), warning: MactermTheme.warning)
    }

    /// The bindings — actions and custom palettes — that share each chord,
    /// keyed by `HotkeyRegistry.conflictKey`, in table order.
    private func bindingsByChord() -> [String: [(rowID: String, title: String)]] {
        var table: [String: [(rowID: String, title: String)]] = [:]
        for action in HotkeyAction.allCases {
            guard let key = HotkeyRegistry.conflictKey(for: values[action.id] ?? "disabled") else { continue }
            table[key, default: []].append((action.id, action.title))
        }
        for entry in appState.customPalettes.entries {
            let rowID = PaletteHotkeys.rowID(paletteID: entry.id)
            guard let key = HotkeyRegistry.conflictKey(for: values[rowID] ?? "disabled") else { continue }
            table[key, default: []].append((rowID, entry.pill.title))
        }
        return table
    }

    /// Titles of the *other* bindings that share the row `rowID`'s chord,
    /// for the inline conflict message.
    private func conflictPartners(
        forRow rowID: String,
        in table: [String: [(rowID: String, title: String)]]
    ) -> [String] {
        guard let key = HotkeyRegistry.conflictKey(for: values[rowID] ?? "disabled") else { return [] }
        return (table[key] ?? []).filter { $0.rowID != rowID }.map(\.title)
    }

    /// The extension palettes the search matches, best first (`Search.rank`,
    /// as every Settings list), in their own Extensions block after every
    /// category.
    private var matchingCustomPalettes: [CustomPaletteStore.Entry] {
        Search.rank(appState.customPalettes.entries, by: query) { entry in
            let rowID = PaletteHotkeys.rowID(paletteID: entry.id)
            let shortcut = values[rowID] ?? "disabled"
            var fields = [entry.pill.title, Self.extensionsTitle, HotkeyRegistry.displayString(for: shortcut)]
            if !HotkeyRegistry.displaySymbols(for: shortcut).isEmpty { fields.append(shortcut) }
            return fields
        }
    }

    /// Bindable actions grouped by the category of the `AppCommand` they back,
    /// so the keymaps list mirrors the command palette's sectioning instead of
    /// being one long flat list. Categories and actions appear in
    /// `AppCommand.allCases` declaration order (`HotkeyAction.inCommandOrder`),
    /// the palette's own. While searching, only the matches (`Search.rank`
    /// over `HotkeyAction.searchFields`), best first: a category comes in
    /// where its best match ranks, and one left with none drops out.
    private var actionsByCategory: [(category: AppCommand.Category, actions: [HotkeyAction])] {
        var order: [AppCommand.Category] = []
        var grouped: [AppCommand.Category: [HotkeyAction]] = [:]
        let matching = Search.rank(HotkeyAction.inCommandOrder, by: query) {
            $0.searchFields(shortcut: values[$0.id] ?? $0.defaultShortcut)
        }
        for action in matching {
            let category = action.appCommand.category
            if grouped[category] == nil { order.append(category) }
            grouped[category, default: []].append(action)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Loads the stored bindings before the first render, so that the table
    /// does not render once with no chords and again with them.
    init() {
        let stored = Self.storedBindings()
        _values = State(initialValue: stored.values)
        _passthrough = State(initialValue: stored.passthrough)
        _global = State(initialValue: stored.global)
    }

    /// Every binding's stored chord and flags, by row id.
    private struct StoredBindings {
        let values: [String: String]
        let passthrough: [String: Bool]
        let global: [String: Bool]
    }

    private static func storedBindings() -> StoredBindings {
        var map: [String: String] = [:]
        var flags: [String: Bool] = [:]
        var globals: [String: Bool] = [:]
        for action in HotkeyAction.allCases {
            map[action.id] = HotkeyRegistry.selectedShortcutString(for: action)
            flags[action.id] = HotkeyRegistry.passesThroughToPrograms(for: action)
            globals[action.id] = HotkeyRegistry.isGlobal(action)
        }
        for paletteID in PaletteHotkeys.shared.paletteIDs {
            let rowID = PaletteHotkeys.rowID(paletteID: paletteID)
            flags[rowID] = PaletteHotkeys.shared.passesThrough(paletteID: paletteID)
            globals[rowID] = PaletteHotkeys.shared.isGlobal(paletteID: paletteID)
        }
        let values = map.merging(PaletteHotkeys.shared.shortcutStringsByRowID()) { _, palette in palette }
        return StoredBindings(values: values, passthrough: flags, global: globals)
    }

    var body: some View {
        let context = rowContext()
        return Form {
            copyModeSection
            passthroughSection

            let groups = actionsByCategory
            let palettes = matchingCustomPalettes
            // One block: the search at its top, then every category as a
            // row that folds open on its keybinds, so the list reads as one
            // table and a long one can be read a category at a time.
            Section {
                SettingsSearchField(text: $query, prompt: "Search by action or keybind")
                if isSearching, groups.isEmpty, palettes.isEmpty {
                    Text("No keybinds match “\(query.trimmingCharacters(in: .whitespaces))”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.category) { group in
                    let expanded = isExpanded(.category(group.category))
                    groupHeader(group.category.title, isExpanded: expanded)
                    if expanded.wrappedValue {
                        ForEach(group.actions) { action in
                            hotkeyRow(action, context: context)
                                .padding(.leading, Self.groupIndent)
                        }
                    }
                }
                if !palettes.isEmpty {
                    let expanded = isExpanded(.extensions)
                    groupHeader(Self.extensionsTitle, isExpanded: expanded)
                    if expanded.wrappedValue {
                        ForEach(palettes) { entry in
                            customPaletteRow(entry, context: context)
                                .padding(.leading, Self.groupIndent)
                        }
                    }
                }
            } header: {
                Text("Keybinds")
            }
        }
        .formStyle(.grouped)
        .onChange(of: query) { collapsedInSearch = [] }
        .background(
            HotkeyCaptureView(
                capturingActionID: $capturingActionID,
                onClear: { rowID in
                    if let binding = Self.binding(forRow: rowID) { clearShortcut(binding) }
                },
                onCapture: { event, rowID in
                    guard let shortcut = HotkeyRegistry.shortcutString(from: event) else { return }
                    if let action = HotkeyAction(rawValue: rowID) {
                        values[action.id] = shortcut
                        HotkeyRegistry.setShortcutString(shortcut, for: action)
                    } else if let paletteID = PaletteHotkeys.paletteID(fromRowID: rowID) {
                        values[rowID] = shortcut
                        PaletteHotkeys.shared.setShortcutString(shortcut, paletteID: paletteID)
                    } else {
                        return
                    }
                    capturingActionID = nil
                    HotkeyCaptureState.shared.isCapturing = false
                }
            )
        )
        .onAppear {
            appState.customPalettes.reloadIfChanged()
            // A reload can add palettes and their stored chords. Assign only
            // a change, so the usual open renders the table once.
            let stored = Self.storedBindings()
            if stored.values != values { values = stored.values }
            if stored.passthrough != passthrough { passthrough = stored.passthrough }
            if stored.global != global { global = stored.global }
        }
        .onDisappear {
            capturingActionID = nil
            HotkeyCaptureState.shared.isCapturing = false
        }
    }

    private var copyModeSection: some View {
        Section {
            Picker(
                "Keymap",
                selection: Binding(
                    get: { Preferences.shared.copyModeKeymap },
                    set: { Preferences.shared.copyModeKeymap = $0 }
                )
            ) {
                ForEach(CopyModeKeymap.allCases) { keymap in
                    Text(keymap.displayName).tag(keymap)
                }
            }
            Text("The keys that move the cursor and select text in copy mode. A change applies the next time the mode starts.")
                .settingsCaption()
        } header: {
            DocsSectionHeader("Copy Mode", docs: .copyMode)
        }
    }

    private var passthroughSection: some View {
        Section {
            TextField(
                "Programs",
                text: Binding(
                    get: { Preferences.shared.passthroughPrograms },
                    set: { Preferences.shared.passthroughPrograms = $0 }
                ),
                prompt: Text(verbatim: "nvim, hx")
            )
            Text("A keybind with Pass to TUI selected goes to these programs. The action does not run. Separate the names with commas.")
                .settingsCaption()
        } header: {
            DocsSectionHeader("Passthrough Programs", docs: .keybinds)
        }
    }

    /// The row that folds a category: its name in the weight of a header,
    /// and a chevron after it that points down while the category is open.
    /// A row of its own and not a `DisclosureGroup`: inside a grouped form,
    /// a disclosure group draws no separators between its rows and does not
    /// indent them.
    private func groupHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .fontWeight(.semibold)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Whether the block `group` shows its rows. A search reads and writes
    /// its own folds (`collapsedInSearch`).
    private func isExpanded(_ group: KeymapGroup) -> Binding<Bool> {
        let searching = isSearching
        return Binding(
            get: { !(searching ? collapsedInSearch : collapsed).contains(group) },
            set: { expanded in
                if searching {
                    if expanded { collapsedInSearch.remove(group) } else { collapsedInSearch.insert(group) }
                } else {
                    if expanded { collapsed.remove(group) } else { collapsed.insert(group) }
                }
            }
        )
    }

    private func passthroughBinding(_ action: HotkeyAction) -> Binding<Bool> {
        Binding(
            get: { passthrough[action.id] ?? false },
            set: { enabled in
                passthrough[action.id] = enabled
                HotkeyRegistry.setPassesThroughToPrograms(enabled, for: action)
            }
        )
    }

    private func globalBinding(_ action: HotkeyAction) -> Binding<Bool> {
        Binding(
            get: { action.isAlwaysGlobal || global[action.id] == true },
            set: { enabled in
                global[action.id] = enabled
                HotkeyRegistry.setGlobal(enabled, for: action)
            }
        )
    }

    private func palettePassthroughBinding(_ paletteID: String) -> Binding<Bool> {
        let rowID = PaletteHotkeys.rowID(paletteID: paletteID)
        return Binding(
            get: { passthrough[rowID] ?? false },
            set: { enabled in
                passthrough[rowID] = enabled
                PaletteHotkeys.shared.setPassesThrough(enabled, paletteID: paletteID)
            }
        )
    }

    private func paletteGlobalBinding(_ paletteID: String) -> Binding<Bool> {
        let rowID = PaletteHotkeys.rowID(paletteID: paletteID)
        return Binding(
            get: { global[rowID] ?? false },
            set: { enabled in
                global[rowID] = enabled
                PaletteHotkeys.shared.setGlobal(enabled, paletteID: paletteID)
            }
        )
    }

    /// A custom palette's row, its flags kept by `PaletteHotkeys`.
    private func customPaletteRow(
        _ entry: CustomPaletteStore.Entry,
        context: RowContext
    ) -> some View {
        keymapRow(
            title: entry.pill.title,
            binding: .palette(entry.id),
            global: paletteGlobalBinding(entry.id),
            passthrough: palettePassthroughBinding(entry.id),
            context: context
        )
    }

    private func hotkeyRow(_ action: HotkeyAction, context: RowContext) -> some View {
        keymapRow(
            title: action.title,
            binding: .action(action),
            global: globalBinding(action),
            passthrough: passthroughBinding(action),
            context: context
        )
    }

    private static func binding(forRow rowID: String) -> HotkeyBinding? {
        if let action = HotkeyAction(rawValue: rowID) { return .action(action) }
        return PaletteHotkeys.paletteID(fromRowID: rowID).map { .palette($0) }
    }

    private func clearShortcut(_ binding: HotkeyBinding) {
        values[binding.id] = "disabled"
        switch binding {
        case let .action(action): HotkeyRegistry.setShortcutString("disabled", for: action)
        case let .palette(paletteID): PaletteHotkeys.shared.clearShortcut(paletteID: paletteID)
        }
        if capturingActionID == binding.id {
            capturingActionID = nil
            HotkeyCaptureState.shared.isCapturing = false
        }
    }

    /// One row of the table: the title (with a glyph for each flag that is
    /// on, since the flags themselves live in the menu), the keybind button,
    /// the row's menu, and the conflict slot. Action rows and palette rows
    /// both come through here, so their columns cannot drift apart.
    @ViewBuilder
    private func keymapRow(
        title: String,
        binding: HotkeyBinding,
        global: Binding<Bool>,
        passthrough: Binding<Bool>,
        context: RowContext
    ) -> some View {
        let rowID = binding.id
        let isAlwaysGlobal = if case let .action(action) = binding { action.isAlwaysGlobal } else { false }
        let partners = conflictPartners(forRow: rowID, in: context.chords)
        let isCapturing = capturingActionID == rowID
        let isUnmapped = HotkeyRegistry.displaySymbols(for: values[rowID] ?? "disabled").isEmpty
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Self.columnGap) {
                Text(title)
                flagGlyphs(global: global.wrappedValue, passthrough: passthrough.wrappedValue)
                Spacer(minLength: 0)

                Button {
                    HotkeyCaptureState.shared.isCapturing = true
                    capturingActionID = rowID
                } label: {
                    Text(verbatim: isCapturing
                        ? String(localized: "Press keys...", comment: "Settings → Keymaps: the keybind button while it records a chord")
                        : HotkeyRegistry.displayString(for: values[rowID] ?? "disabled"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle((isUnmapped && !isCapturing) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .frame(width: Self.keybindColumn)
                .help("Click, then press the keys. Press Delete to clear the keybind.")

                // The menu and the warning in ONE box of `trailingColumn`,
                // spaced zero: as two siblings they added an extra
                // inter-child gap and the menu's own intrinsic width, which
                // pushed that row's keybind column out of line.
                HStack(spacing: 0) {
                    KeymapRowMenu(
                        global: global,
                        // The quick terminal is global by construction —
                        // shown ticked so the row tells the truth, disabled
                        // because there is nothing to decide.
                        globalLocked: isAlwaysGlobal,
                        passthrough: passthrough,
                        // An unmapped row has no chord to make global or pass
                        // through, and a live item that does nothing reads as
                        // broken.
                        hasKeybind: !isUnmapped
                    )
                    .frame(width: Self.menuColumn)

                    // Space is always reserved: shown conditionally, a
                    // conflict would shift that row's columns out of line
                    // with every other row — in exactly the row asking to be
                    // read closely.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(context.warning)
                        .opacity(partners.isEmpty ? 0 : 1)
                        .frame(width: Self.warningColumn)
                }
                .frame(width: Self.trailingColumn)
            }

            if !partners.isEmpty {
                Text("Conflicts with \(partners.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(context.warning)
            }

            // A flagged chord the system would not give us. Said here rather
            // than left silent: the binding still works inside Macterm, so
            // nothing looks broken until the user tries it from another app —
            // where the keystroke never reaches us at all.
            if let refusal = globalHotkeys.refusals[binding] {
                Text(refusal.message)
                    .font(.system(size: 11))
                    .foregroundStyle(context.warning)
            }
        }
    }

    /// The flags that are on, as small gray glyphs after the title: with the
    /// toggles inside the row's menu, this is what keeps a Global or a
    /// Pass to TUI keybind visible at a glance.
    @ViewBuilder
    private func flagGlyphs(global: Bool, passthrough: Bool) -> some View {
        if global {
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Self.globalTitle)
        }
        if passthrough {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Self.passthroughTitle)
        }
    }
}

/// The ⋯ menu of a Keymaps row: Global and Pass to TUI. Clearing is a bare
/// Delete while the row records (`HotkeyCaptureView`), not an item here: a
/// menu indents every title to its checkmark column, so a Clear Keybind
/// item could not sit flush left.
///
/// AppKit, not a SwiftUI `Menu`: on macOS 26 and later a menu drops its
/// checkmark column while no item is checked, so the titles sat flush left
/// and jumped right the moment an option went on. A blank `offStateImage`
/// on every item keeps the column, and SwiftUI has no way to set one
/// (`showsStateColumn` is already true and does not help).
private struct KeymapRowMenu: NSViewRepresentable {
    var global: Binding<Bool>
    var globalLocked: Bool
    var passthrough: Binding<Bool>
    var hasKeybind: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// One image for every row. The pane makes a menu for each keybind, and
    /// the symbol lookup was a measurable part of opening it.
    private static let faceImage = NSImage(
        systemSymbolName: "ellipsis.circle",
        accessibilityDescription: String(localized: "Keybind options")
    )

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.imagePosition = .imageOnly
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.toolTip = String(localized: "Keybind options")
        // A pull-down shows its first item as the button and never lists it.
        let face = NSMenuItem()
        face.image = Self.faceImage
        button.menu?.addItem(face)
        button.menu?.autoenablesItems = false
        button.menu?.delegate = context.coordinator
        return button
    }

    func updateNSView(_: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: KeymapRowMenu

        init(_ parent: KeymapRowMenu) {
            self.parent = parent
        }

        /// Built at each open, so the checkmarks read the bindings as they
        /// are now and not as they were when the row was drawn.
        func menuNeedsUpdate(_ menu: NSMenu) {
            while menu.numberOfItems > 1 {
                menu.removeItem(at: 1)
            }
            let globalItem = item(KeymapSettings.globalTitle, help: KeymapSettings.globalHelp, action: #selector(toggleGlobal))
            globalItem.state = parent.global.wrappedValue ? .on : .off
            globalItem.isEnabled = parent.hasKeybind && !parent.globalLocked
            let passthroughItem = item(
                KeymapSettings.passthroughTitle,
                help: KeymapSettings.passthroughHelp,
                action: #selector(togglePassthrough)
            )
            passthroughItem.state = parent.passthrough.wrappedValue ? .on : .off
            passthroughItem.isEnabled = parent.hasKeybind
            menu.addItem(globalItem)
            menu.addItem(passthroughItem)
        }

        private func item(_ title: String, help: String?, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = help
            item.offStateImage = NSImage(size: item.onStateImage?.size ?? NSSize(width: 12, height: 12))
            return item
        }

        @objc
        private func toggleGlobal() {
            parent.global.wrappedValue.toggle()
        }

        @objc
        private func togglePassthrough() {
            parent.passthrough.wrappedValue.toggle()
        }
    }
}

private struct HotkeyCaptureView: NSViewRepresentable {
    @Binding
    var capturingActionID: String?
    /// A bare Delete or Forward Delete while recording: clear the row. A
    /// chord needs a modifier (`HotkeyRegistry.shortcutString`), so a bare
    /// key can never be a binding and is free to mean "no keybind".
    let onClear: (String) -> Void
    let onCapture: (NSEvent, String) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.capturingActionID = capturingActionID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onClear: onClear, onCapture: onCapture)
    }

    /// Every `addLocalMonitorForEvents` needs a paired `removeMonitor`, or each
    /// visit to the Keymaps tab leaks a monitor (and one closure call per
    /// keyDown) for the process lifetime. Removal happens here — a `@MainActor`
    /// teardown hook — rather than in `deinit`, which is `nonisolated` under
    /// Swift 6 and can't touch the coordinator's non-Sendable `monitor`.
    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject {
        let view: NSView
        var capturingActionID: String?
        private var monitor: Any?
        private let onClear: (String) -> Void
        private let onCapture: (NSEvent, String) -> Void

        init(onClear: @escaping (String) -> Void, onCapture: @escaping (NSEvent, String) -> Void) {
            self.onClear = onClear
            self.onCapture = onCapture
            view = NSView()
            super.init()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let actionID = self.capturingActionID else { return event }
                if Int(event.keyCode) == kVK_Escape {
                    self.capturingActionID = nil
                    HotkeyCaptureState.shared.isCapturing = false
                    return nil
                }
                let isBareDelete = [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode))
                    && event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
                if isBareDelete {
                    self.capturingActionID = nil
                    HotkeyCaptureState.shared.isCapturing = false
                    self.onClear(actionID)
                    return nil
                }
                self.onCapture(event, actionID)
                return nil
            }
        }

        func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Updates

private struct UpdatesSettings: View {
    /// `Updater` is `@Observable`; read the singleton directly (Observation
    /// tracks `canCheckForUpdates`/`updateAvailable` reads in `body`).
    private var updater: Updater { .shared }
    @State
    private var automaticallyDownloads: Bool = Updater.shared.automaticallyDownloadsUpdates
    @State
    private var updateChannel: String = Updater.shared.updateChannel.rawValue

    var body: some View {
        Form {
            Section("Automatic Updates") {
                Toggle("Update automatically", isOn: $automaticallyDownloads)
                    .onChange(of: automaticallyDownloads) { _, v in
                        updater.automaticallyDownloadsUpdates = v
                    }

                HStack {
                    Spacer()
                    Button("Check for Updates Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }

            // Deliberately its own section: the channel governs which updates
            // are visible to any check, including a manual "Check for Updates
            // Now".
            Section {
                Picker("Update channel", selection: $updateChannel) {
                    ForEach(UpdateChannel.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .onChange(of: updateChannel) { _, v in
                    updater.updateChannel = UpdateChannel(rawValue: v) ?? .stable
                }

                Text((UpdateChannel(rawValue: updateChannel) ?? .stable).summary)
                    .settingsCaption()
            } header: {
                Text("Channel")
            }

            Section("Version") {
                LabeledContent("Current version", value: Self.bundleVersionString)
            }
        }
        .formStyle(.grouped)
    }

    private static var bundleVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let commit = Bundle.main.infoDictionary?["GitCommit"] as? String ?? ""
        // Hide the placeholder — it only survives into dev builds that don't
        // go through scripts/build.sh (swift run, Xcode previews, etc.).
        let looksReal = !commit.isEmpty && commit != "GIT_COMMIT_PLACEHOLDER"
        return looksReal ? "\(short) (\(commit))" : short
    }
}
