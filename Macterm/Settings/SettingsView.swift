import AppKit
import Carbon
import SwiftUI

/// The panes of the settings window, in sidebar order. Titles are the
/// user-visible sidebar labels — Title Case, matching the macOS convention the
/// rest of the app's menus follow.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case projects = "Projects"
    case appearance = "Appearance"
    case quickTerminal = "Quick Terminal"
    case keymaps = "Keymaps"
    case updates = "Updates"

    var id: String { rawValue }
    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .projects: "folder"
        case .appearance: "paintpalette"
        case .quickTerminal: "rectangle.bottomthird.inset.filled"
        case .keymaps: "keyboard"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// Sidebar-style preferences window, mirroring the macOS System Settings
/// shape: a source list of panes on the left, the selected pane's `Form` on
/// the right. `NavigationSplitView` is the native container — it also places
/// the pane title over the detail column, which nothing else does (see
/// `PinnedSidebar`).
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
            List(SettingsPane.allCases, selection: $selection) { pane in
                NavigationLink(value: pane) {
                    Label(pane.title, systemImage: pane.symbol)
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
        case .quickTerminal: QuickTerminalSettings()
        case .keymaps: KeymapSettings()
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

    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let display: (Double) -> String

    var body: some View {
        // The `Slider` dims itself inside a `.disabled(_:)` scope, but the
        // flanking `Text`s are not controls and wouldn't follow on their own.
        HStack {
            Text(label)
                .frame(width: Self.labelWidth, alignment: .leading)
                .dimsWhenDisabled()
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(display(value))
                .monospacedDigit()
                .frame(width: Self.valueWidth, alignment: .trailing)
                .dimsWhenDisabled()
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
    if abs(value - 0.5) < 0.001 { return "Center" }
    return "\(Int((value * 100).rounded()))%"
}

// MARK: - General

private struct GeneralSettings: View {
    /// Seeded from and written back through `Preferences` (the single
    /// UserDefaults seam that redirects to a wiped side-suite under XCTest).
    /// NOT `@AppStorage`, which binds to `UserDefaults.standard` — banned by the
    /// project, and it diverged from the `.onChange` write-through under test.
    @State private var autoTilingEnabled: Bool = Preferences.shared.autoTilingEnabled
    @State private var backgroundSSHConnections: Bool = Preferences.shared.backgroundSSHConnections
    @State private var reconnectRemotePanes: Bool = Preferences.shared.reconnectRemotePanes
    @State private var restoreAllProjectsOnLaunch: Bool = Preferences.shared.restoreAllProjectsOnLaunch

    /// Why session persistence is inactive, when it is. Missing binary is a
    /// dev-build state; an over-budget socket path is an environment problem
    /// (very long home/TMPDIR paths push past sun_path).
    private var zmxUnavailableReason: String {
        if !ZmxClient.live.isBundled() {
            return "Session persistence is inactive: the zmx binary isn't bundled. Run `mise run setup` and rebuild."
        }
        return "Session persistence is inactive: this system's zmx socket path is too long. Terminals run without persistence."
    }

    @State
    private var terminalScrollSpeed: Double = Preferences.shared.terminalScrollSpeed
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
                    Text("Files load from top to bottom; later files override earlier ones.")
                        .settingsCaption()
                    Spacer()
                    Button("Reload") {
                        commitGhosttyConfig()
                    }
                    .help("Re-read your Ghostty config. Click after saving external edits.")
                }
            } header: {
                HStack {
                    Text("Ghostty Config")
                    Spacer()
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

            Section("Terminal") {
                SettingsSlider(
                    label: "Scroll speed",
                    value: $terminalScrollSpeed,
                    range: 0.25 ... 3.0,
                    step: nil,
                    display: { String(format: "%.2f×", $0) }
                )
                .onChange(of: terminalScrollSpeed) { _, v in
                    Preferences.shared.terminalScrollSpeed = v
                }
                Text("Scrollback speed for trackpads and mouse wheels.")
                    .settingsCaption()
            }

            Section("Layout") {
                Toggle("Auto-tile panes", isOn: $autoTilingEnabled)
                    .onChange(of: autoTilingEnabled) { _, v in
                        Preferences.shared.autoTilingEnabled = v
                    }
                Text("Distributes pane sizes evenly on split and close.")
                    .settingsCaption()
            }

            Section("Remote Projects") {
                Toggle("Background SSH connections", isOn: $backgroundSSHConnections)
                    .onChange(of: backgroundSSHConnections) { _, v in
                        Preferences.shared.backgroundSSHConnections = v
                    }
                Text(
                    "Probes remote hosts for live tab names and close warnings. "
                        + "Turn off if each connection prompts for Touch ID."
                )
                .settingsCaption()
                Toggle("Reconnect panes after a dropped connection", isOn: $reconnectRemotePanes)
                    .onChange(of: reconnectRemotePanes) { _, v in
                        Preferences.shared.reconnectRemotePanes = v
                    }
                Text(
                    "Reattaches a disconnected pane's session when you wake "
                        + "the Mac or return to the app."
                )
                .settingsCaption()
            }

            Section("Session Persistence") {
                Toggle("Restore and expand every project on launch", isOn: $restoreAllProjectsOnLaunch)
                    .onChange(of: restoreAllProjectsOnLaunch) { _, v in
                        Preferences.shared.restoreAllProjectsOnLaunch = v
                    }
                Text("Reattaches saved terminals immediately and reveals their tabs in the sidebar.")
                    .settingsCaption()

                // Persistence can fail silently when zmx is unavailable
                // (Supacode shipped the same probe and users only noticed via
                // a buried log line), so keep the warning beside the setting.
                if ZmxClient.live.executableURL() == nil {
                    Label {
                        Text(zmxUnavailableReason)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(MactermTheme.warning)
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
            // Default files are created and deleted in other apps, so
            // discovery can only have changed while we were inactive.
            defaultGhosttyConfigFiles = GhosttyConfigSource.defaultFileLocations()
            Task { await refreshNotificationBanner() }
        }
        .task { await refreshNotificationBanner() }
        .onChange(of: isCustomGhosttyConfigFieldFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused else { return }
            commitCustomGhosttyConfigEdit()
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
            GhosttyDefaultLocationRow(file: file)
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
                prompt: Text("~/.config/ghostty/config")
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($isCustomGhosttyConfigFieldFocused)
            .onSubmit { commitCustomGhosttyConfigEdit() }
        }
        .padding(.vertical, 2)
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
            return "File not found."
        }
        return isDirectory.boolValue ? "Not a file." : nil
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
        panel.prompt = "Add"
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
/// symlink leads). Customization happens in the custom list instead.
private struct GhosttyDefaultLocationRow: View {
    let file: GhosttyConfigSource.DefaultFileLocation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text((file.searchedPath as NSString).abbreviatingWithTildeInPath)
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
/// override earlier ones. A non-nil `problem` swaps the file icon for a
/// warning triangle whose tooltip carries the reason, keeping the row
/// single-line.
private struct GhosttyConfigFileRow: View {
    let path: String
    let problem: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
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

            Text((path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
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
                    Text(
                        "macOS will ask folder by folder as terminal commands touch "
                            + "Documents, Downloads, and other protected locations. "
                            + "One Full Disk Access grant covers them all."
                    )
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
                    Text("Macterm doesn't have notification permission")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Your Ghostty config is set to deliver notifications.")
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
    @State private var autoNameTabs: Bool = Preferences.shared.autoNameTabs
    @State private var peekSidebarWhenHidden: Bool = Preferences.shared.peekSidebarWhenHidden
    @State private var showNewProjectButton: Bool = Preferences.shared.showNewProjectButton
    @State private var tabSwitcherVisibility: String = Preferences.shared.tabSwitcherVisibility.rawValue
    @State private var tabSwitcherPosition: String = Preferences.shared.tabSwitcherPosition.rawValue
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
    /// Inverted view of `Preferences.hideTitleBar`: the control reads as
    /// "Show toolbar" (on by default), the preference stores the hide.
    @State
    private var showToolbar: Bool = !Preferences.shared.hideTitleBar

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

                Text(blurFootnote)
                    .settingsCaption()

                Toggle("Adaptive background", isOn: $adaptiveTerminalChrome)
                    .onChange(of: adaptiveTerminalChrome) { _, enabled in
                        Preferences.shared.adaptiveTerminalChromeEnabled = enabled
                    }
                Text("Matches the whole window for a single pane; in a split, only each full-screen app's pane changes color.")
                    .settingsCaption()
            }

            Section("Sidebar") {
                Toggle("Peek sidebar when hidden", isOn: $peekSidebarWhenHidden)
                    .onChange(of: peekSidebarWhenHidden) { _, v in Preferences.shared.peekSidebarWhenHidden = v }
                Text("Shows the hidden sidebar while the pointer rests at the window's left edge.")
                    .settingsCaption()

                Group {
                    Picker("Peek style", selection: $sidebarPeekStyle) {
                        ForEach(SidebarPeekStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .onChange(of: sidebarPeekStyle) { _, style in
                        Preferences.shared.sidebarPeekStyle = style
                    }
                    Text(sidebarPeekStyle.explanation)
                        .settingsCaption()
                }
                .disabled(!peekSidebarWhenHidden)

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

                Toggle("Auto-name tabs", isOn: $autoNameTabs)
                    .onChange(of: autoNameTabs) { _, v in
                        Preferences.shared.autoNameTabs = v
                    }
                Text("Names tabs after the running program. When off, tabs show the shell or host name.")
                    .settingsCaption()

                Toggle("Show AI agent icons", isOn: $showAgentIcons)
                    .onChange(of: showAgentIcons) { _, v in
                        Preferences.shared.showAgentIcons = v
                    }
                Text("Uses the logo of the AI agent running in a tab as its icon.")
                    .settingsCaption()

                Toggle("Show tab status indicator", isOn: $showTabStatusIndicator)
                    .onChange(of: showTabStatusIndicator) { _, v in
                        Preferences.shared.showTabStatusIndicator = v
                    }
                Text("Shows a spinner while a command runs, and a dot when it finishes.")
                    .settingsCaption()

                Group {
                    Toggle(isOn: $showSpinnerOverAgentIcons) {
                        Text("Show spinner over agent icons").dimsWhenDisabled()
                    }
                    .onChange(of: showSpinnerOverAgentIcons) { _, v in
                        Preferences.shared.showSpinnerOverAgentIcons = v
                    }
                    Text("When off, a tab running an AI agent keeps its logo while busy. The completion dot still appears.")
                        .settingsCaption()
                }
                .disabled(!(showTabStatusIndicator && showAgentIcons))
                .padding(.leading, 16)

                Toggle("Show New Project button", isOn: $showNewProjectButton)
                    .onChange(of: showNewProjectButton) { _, v in Preferences.shared.showNewProjectButton = v }
                Text("When hidden, create projects via the command palette or context menu.")
                    .settingsCaption()
            }

            Section("Toolbar") {
                Toggle("Show toolbar", isOn: $showToolbar)
                    .onChange(of: showToolbar) { _, v in
                        Preferences.shared.hideTitleBar = !v
                    }
                Text("Hiding it removes the title bar, window buttons, and drag area; switch tabs via the sidebar or ⌘ and the tab number.")
                    .settingsCaption()

                Group {
                    Picker(selection: $tabSwitcherVisibility) {
                        ForEach(TabSwitcherVisibility.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    } label: {
                        Text("Tab switcher").dimsWhenDisabled()
                    }
                    .onChange(of: tabSwitcherVisibility) { _, v in
                        Preferences.shared.tabSwitcherVisibility = TabSwitcherVisibility(rawValue: v) ?? .whenMultiple
                    }
                    Text("Numbered control in the title bar for switching tabs by index.")
                        .settingsCaption()

                    Picker(selection: $tabSwitcherPosition) {
                        ForEach(TabSwitcherPosition.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    } label: {
                        Text("Tab switcher position").dimsWhenDisabled()
                    }
                    .onChange(of: tabSwitcherPosition) { _, v in
                        Preferences.shared.tabSwitcherPosition = TabSwitcherPosition(rawValue: v) ?? .trailing
                    }
                    Text("Left places the switcher before the window title, next to the sidebar.")
                        .settingsCaption()
                }
                .disabled(!showToolbar)
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

    private var blurFootnote: String {
        if backgroundOpacity >= 0.999 {
            return WindowAppearance.glassSupported
                ? "Blur and Liquid Glass only take effect when opacity is below 100%."
                : "Blur only takes effect when opacity is below 100%."
        }
        if liquidGlass {
            return "Liquid Glass uses the macOS material (blur slider ignored). Regular is frostier; Clear is more transparent."
        }
        return "Set blur to 0 to disable."
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
            Section("Quick Terminal") {
                LabeledContent(
                    "Shortcut",
                    value: HotkeyRegistry.displayString(
                        for: HotkeyRegistry.selectedShortcutString(for: .toggleQuickTerminal)
                    )
                )
                Text("Works globally, even when Macterm isn't active. Rebind it in Keymaps, or clear it to disable the quick terminal.")
                    .settingsCaption()
            }

            Section("Position") {
                Picker("Mode", selection: $positionMode) {
                    ForEach(QuickTerminalAdjustMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: positionMode) { _, v in
                    Preferences.shared.quickTerminalPositionMode = v
                }
                Text("Fixed anchors the panel with the sliders. Dynamic adds a grab handle and remembers where you drag it.")
                    .settingsCaption()

                SettingsSlider(
                    label: "X",
                    value: $fixedX,
                    range: 0 ... 1,
                    step: 0.05,
                    display: { anchorName($0, zero: "Left", one: "Right") }
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
                    display: { anchorName($0, zero: "Top", one: "Bottom") }
                )
                .onChange(of: fixedYTopDown) { _, v in
                    Preferences.shared.quickTerminalFixedY = 1 - v
                }
                .disabled(positionMode != .fixed)
            }

            Section("Size") {
                Picker("Mode", selection: $sizeMode) {
                    ForEach(QuickTerminalAdjustMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: sizeMode) { _, v in
                    Preferences.shared.quickTerminalSizeMode = v
                }
                Text("Fixed sizes the panel with the sliders. Dynamic lets you resize it from its edges and reopens it at that size.")
                    .settingsCaption()

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
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keymaps

private struct KeymapSettings: View {
    @State
    private var values: [String: String] = [:]
    @State
    private var passthrough: [String: Bool] = [:]
    @State
    private var capturingActionID: String?

    /// Column geometry, shared by the header and every row so the three columns
    /// actually line up. The keybind width lives on the *button*, not on its
    /// label, so the header measures the same box the border draws.
    ///
    /// Alignment holds only because the header and every row are built as the
    /// SAME four children — title, flexible spacer, then three fixed-width
    /// boxes — with an explicit `columnGap`. Both are load-bearing: SwiftUI's
    /// default `HStack` spacing varies with the *types* of the adjacent views
    /// (two Texts space differently than a Text and a Button), and because the
    /// spacer pins everything after it to the trailing edge, one extra child or
    /// one wider trailing view shifts that row's columns out of line with the
    /// header. Don't add a control to a row without giving it a box here.
    private static let columnGap: CGFloat = 8
    private static let passthroughColumn: CGFloat = 92
    private static let keybindColumn: CGFloat = 140
    private static let clearColumn: CGFloat = 20
    private static let warningColumn: CGFloat = 16
    private static let trailingColumn: CGFloat = clearColumn + warningColumn

    /// Short enough for a column header; the precise rule lives in the
    /// checkbox's tooltip rather than a description line under every row.
    private static let passthroughTitle = "Pass to TUI"
    private static let passthroughHelp = """
    When one of the programs listed at the top of this tab is running in the \
    focused pane, send this chord to it instead of running the action. \
    Everywhere else the action still runs.
    """

    /// Titles of the *other* actions that share `action`'s binding, for the
    /// inline conflict message.
    private func conflictPartners(for action: HotkeyAction) -> [String] {
        guard let key = HotkeyRegistry.conflictKey(for: values[action.id] ?? "disabled") else {
            return []
        }
        return HotkeyAction.allCases
            .filter { $0.id != action.id && HotkeyRegistry.conflictKey(for: values[$0.id] ?? "disabled") == key }
            .map(\.title)
    }

    /// Bindable actions grouped by the category of the `AppCommand` they back,
    /// so the keymaps list mirrors the command palette's sectioning instead of
    /// being one long flat list. Categories appear in `AppCommand.allCases`
    /// declaration order; actions keep their order within each.
    private var actionsByCategory: [(category: AppCommand.Category, actions: [HotkeyAction])] {
        var order: [AppCommand.Category] = []
        var grouped: [AppCommand.Category: [HotkeyAction]] = [:]
        for action in HotkeyAction.allCases {
            let category = action.appCommand.category
            if grouped[category] == nil { order.append(category) }
            grouped[category, default: []].append(action)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        Form {
            Section("Passthrough Programs") {
                TextField(
                    "Programs",
                    text: Binding(
                        get: { Preferences.shared.passthroughPrograms },
                        set: { Preferences.shared.passthroughPrograms = $0 }
                    ),
                    prompt: Text(verbatim: "nvim, hx")
                )
                Text(
                    "Keybinds checked below yield to these programs instead of running "
                        + "their action. Match the name shown in the tab title; separate with commas."
                )
                .settingsCaption()
            }

            ForEach(actionsByCategory, id: \.category) { group in
                Section(group.category.rawValue) {
                    columnHeader
                    ForEach(group.actions) { action in
                        hotkeyRow(action)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .background(
            HotkeyCaptureView(capturingActionID: $capturingActionID) { event, actionID in
                guard let action = HotkeyAction(rawValue: actionID),
                      let shortcut = HotkeyRegistry.shortcutString(from: event)
                else { return }
                values[action.id] = shortcut
                HotkeyRegistry.setShortcutString(shortcut, for: action)
                capturingActionID = nil
                HotkeyCaptureState.shared.isCapturing = false
            }
        )
        .onAppear {
            var map: [String: String] = [:]
            var flags: [String: Bool] = [:]
            for action in HotkeyAction.allCases {
                map[action.id] = HotkeyRegistry.selectedShortcutString(for: action)
                flags[action.id] = HotkeyRegistry.passesThroughToPrograms(for: action)
            }
            values = map
            passthrough = flags
        }
        .onDisappear {
            capturingActionID = nil
            HotkeyCaptureState.shared.isCapturing = false
        }
    }

    /// Names the three columns once per section. Repeated per section rather
    /// than once per pane because each section scrolls independently in a long
    /// list, and a header that has scrolled away explains nothing.
    private var columnHeader: some View {
        HStack(spacing: Self.columnGap) {
            Text("Action")
            Spacer(minLength: 0)
            Text(Self.passthroughTitle)
                .frame(width: Self.passthroughColumn, alignment: .center)
            Text("Keybind")
                .frame(width: Self.keybindColumn, alignment: .leading)
            // Stands in for each row's trailing block (clear button + warning
            // slot) as ONE box of the same width, so the two columns to its
            // left land in the same place in the header as in every row.
            Spacer().frame(width: Self.trailingColumn)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func hotkeyRow(_ action: HotkeyAction) -> some View {
        let partners = conflictPartners(for: action)
        let isCapturing = capturingActionID == action.id
        let isUnmapped = HotkeyRegistry.displaySymbols(for: values[action.id] ?? "disabled").isEmpty
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Self.columnGap) {
                Text(action.title)
                Spacer(minLength: 0)

                Toggle("", isOn: passthroughBinding(action))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: Self.passthroughColumn, alignment: .center)
                    .help(Self.passthroughHelp)

                Button {
                    HotkeyCaptureState.shared.isCapturing = true
                    capturingActionID = action.id
                } label: {
                    Text(
                        isCapturing
                            ? "Press keys..."
                            : HotkeyRegistry
                            .displayString(for: values[action.id] ?? "disabled")
                    )
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle((isUnmapped && !isCapturing) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .frame(width: Self.keybindColumn)

                // Both trailing controls in ONE box of `trailingColumn`, spaced
                // zero: as two siblings they added an extra inter-child gap and
                // the clear button's own intrinsic width, which is what pushed
                // every row's columns left of the header labels.
                HStack(spacing: 0) {
                    Button {
                        values[action.id] = "disabled"
                        HotkeyRegistry.setShortcutString("disabled", for: action)
                        if capturingActionID == action.id {
                            capturingActionID = nil
                            HotkeyCaptureState.shared.isCapturing = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    // Nothing to clear on an already-unmapped action, and a
                    // live control that does nothing reads as broken.
                    .disabled(isUnmapped)
                    .help("Clear this keybind")
                    .frame(width: Self.clearColumn)

                    // Space is always reserved: shown conditionally, a conflict
                    // would shift that row's columns out of line with every
                    // other row — in exactly the row asking to be read closely.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MactermTheme.warning)
                        .opacity(partners.isEmpty ? 0 : 1)
                        .frame(width: Self.warningColumn)
                }
                .frame(width: Self.trailingColumn)
            }

            if !partners.isEmpty {
                Text("Conflicts with \(partners.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(MactermTheme.warning)
            }
        }
    }
}

private struct HotkeyCaptureView: NSViewRepresentable {
    @Binding
    var capturingActionID: String?
    let onCapture: (NSEvent, String) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.capturingActionID = capturingActionID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
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
        private let onCapture: (NSEvent, String) -> Void

        init(onCapture: @escaping (NSEvent, String) -> Void) {
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
    private var automaticallyChecks: Bool = Updater.shared.automaticallyChecksForUpdates
    @State
    private var automaticallyDownloads: Bool = Updater.shared.automaticallyDownloadsUpdates
    @State
    private var updateChannel: String = Updater.shared.updateChannel.rawValue

    var body: some View {
        Form {
            Section("Automatic Updates") {
                Toggle("Check for updates automatically", isOn: $automaticallyChecks)
                    .onChange(of: automaticallyChecks) { _, v in
                        updater.automaticallyChecksForUpdates = v
                    }

                Toggle(isOn: $automaticallyDownloads) {
                    Text("Download updates in the background").dimsWhenDisabled()
                }
                .disabled(!automaticallyChecks)
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

                Text("Updates are verified with an EdDSA signature. No analytics are collected.")
                    .settingsCaption()
            }

            // Deliberately its own section, and NOT disabled when automatic
            // checks are off: the channel governs which updates are visible to
            // any check, including a manual "Check for Updates Now".
            Section("Channel") {
                Picker("Update channel", selection: $updateChannel) {
                    ForEach(UpdateChannel.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .onChange(of: updateChannel) { _, v in
                    updater.updateChannel = UpdateChannel(rawValue: v) ?? .stable
                }

                Text("Tip builds come from every commit that passes CI and are not release-tested.")
                    .settingsCaption()
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
