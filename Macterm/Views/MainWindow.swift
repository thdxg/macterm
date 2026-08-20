import AppKit
import os
import SwiftUI

private let styleLogger = Logger(subsystem: appBundleID, category: "WindowStyler")

struct MainWindow: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @State
    private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State
    private var detailWidth: CGFloat = .infinity
    @State
    private var preferences = Preferences.shared
    /// The sidebar is temporarily out because the pointer is at the leading
    /// edge, while the user's toggle state still says hidden. Peeking drives
    /// the same `columnVisibility` path the shortcut uses — never AppKit's
    /// broken overlay reveal, disabled in `WindowAppearance`.
    @State
    private var isPeeking = false
    /// Set when the shortcut hides the sidebar with the pointer still over it,
    /// so the next hover event doesn't instantly peek it back out. Cleared
    /// once the pointer leaves the trigger strip.
    @State
    private var suppressPeekUntilExit = false
    /// Last open sidebar width: the peek's "pointer left the sidebar"
    /// threshold, and what we persist so the next launch reopens at it.
    ///
    /// SwiftUI autosaves the column width itself, but that never survives a
    /// relaunch — see `WindowAppearance.restoreSidebarWidth`, which does the
    /// reopening. This end just records the value.
    @State
    private var sidebarWidth: CGFloat = .init(Preferences.shared.launchSidebarWidth)
    /// When the running peek expand animation will have settled; a retraction
    /// requested before this waits (see `endPeek`).
    @State
    private var peekExpandSettleTime: Date = .distantPast
    /// When the running peek collapse animation will have settled; a new peek
    /// requested before this waits (see `handleSidebarPeekHover`). Besides
    /// protecting the animation, this closes a delivery race: a peek started
    /// between our collapse's state write and its `onChange` delivery made the
    /// handler see `.detailOnly` while `isPeeking` — the toolbar-button-pin
    /// signature — and wrongly pinned the sidebar, killing the hover.
    @State
    private var peekCollapseSettleTime: Date = .distantPast
    /// A retraction is queued behind the expand animation. Cleared if the
    /// pointer returns to the sidebar before it fires.
    @State
    private var deferredUnpeek = false
    /// A peek is queued behind the collapse animation (the pointer may be
    /// parked in the strip, generating no further hover events to retry on).
    @State
    private var deferredPeek = false
    /// Last hover location, for deferred re-checks that fire without a fresh
    /// event. Cleared when the pointer leaves the window.
    @State
    private var lastHoverPoint: CGPoint?

    /// Conservative bound on the column expand/collapse animation, including a
    /// margin — deferring the opposite transition slightly long is invisible,
    /// cutting it short reverses the animation mid-flight and corrupts
    /// NavigationSplitView's stored width metric.
    private let peekAnimationDuration: TimeInterval = 0.4

    /// Width of the hover strip at the leading edge that pops the hidden
    /// sidebar out — a little wider than AppKit's own edge-hover band.
    private let peekStripWidth: CGFloat = 12

    var body: some View {
        // Derive bindings to the @Observable AppState via @Bindable (the
        // Observation-era idiom) rather than a hand-rolled Binding(get:set:).
        @Bindable var appState = appState
        // Read in body, not inside the toolbar builder, so the Observation
        // dependency is registered and a Settings change re-places the item.
        let switcherPosition = preferences.tabSwitcherPosition
        // Hiding the window toolbar (#226) also drops the titlebar itself,
        // traffic lights included — that's AppKit's behavior for a toolbar-less
        // fullSizeContentView window, not something we do separately. Read in
        // body so flipping the setting re-applies live.
        let chromeHidden = preferences.hideTitleBar
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarContent()
                // Breathing room for the first row once the chrome is gone.
                // Innermost, before `ignoresSafeArea`, so the padding insets
                // the rows while the sidebar surface still reaches the edge.
                .safeAreaPadding(.top, chromeHidden ? 8 : 0)
                .navigationSplitViewColumnWidth(
                    min: CGFloat(Preferences.sidebarWidthRange.lowerBound),
                    // Measured to be ignored (the column comes up at its
                    // content width regardless) — kept as the honest request
                    // for the launch width AppKit actually installs.
                    ideal: CGFloat(Preferences.shared.launchSidebarWidth),
                    // Also ignored — a drag sails straight past it. The cap
                    // that holds is `WindowAppearance.enforceSidebarWidthLimit`
                    // (NSSplitViewItem.maximumThickness, re-asserted per drag).
                    max: CGFloat(Preferences.sidebarWidthRange.upperBound)
                )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    // Below the column's 140 minimum means mid-collapse; keep
                    // the last open width for the peek's exit threshold.
                    if width >= 100 { recordSidebarWidth(width) }
                }
                // Hiding the toolbar removes the chrome but SwiftUI keeps its
                // titlebar safe-area inset reserved; ignoring it is what lets
                // rows actually start at the window's top edge.
                .ignoresSafeArea(chromeHidden ? .container : [], edges: .top)
        } detail: {
            ZStack {
                // The window's NSWindow.backgroundColor (set by WindowAppearance)
                // fills the detail column at the configured opacity. No need
                // to paint another tinted layer here — doing so stacks two
                // translucent fills and the detail reads as darker than the
                // strip around the sidebar.
                if let project = activeProjectWithWorkspace {
                    if projectHasAnyTab(project) {
                        WorkspaceView(project: project)
                            .id(project.id)
                    } else {
                        EmptyProjectView(project: project)
                            .id(project.id)
                    }
                } else {
                    WelcomeView()
                }
            }
            // Same safe-area reclaim as the sidebar: without it the terminal
            // keeps a blank strip where the hidden titlebar used to be.
            .ignoresSafeArea(chromeHidden ? .container : [], edges: .top)
            .navigationTitle(activeProject?.name ?? appDisplayName)
            .navigationSubtitle(activeTabTitle)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                detailWidth = width
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    UpdateAvailableToolbarButton()
                }
                // Structural branch, not a placement ternary: each side is its
                // own toolbar item identity, so flipping the preference tears
                // down and re-places the control instead of relying on AppKit
                // migrating an existing item between toolbar slots.
                if switcherPosition == .leading {
                    // `.navigation` is the leading slot — AppKit puts it ahead
                    // of the inline window title, next to the sidebar (#186).
                    ToolbarItem(placement: .navigation) {
                        TabSwitcherToolbarItem(availableWidth: detailWidth)
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        TabSwitcherToolbarItem(availableWidth: detailWidth)
                    }
                }
            }
        }
        .toolbar(chromeHidden ? .hidden : .visible, for: .windowToolbar)
        .background(WindowStyler(hideTitle: chromeHidden))
        .overlay {
            if appState.isCommandPaletteVisible {
                CommandPaletteOverlay()
            }
        }
        // Above the palette overlay so a toast fired by a palette command isn't
        // covered by the palette's own dismissal animation.
        .overlay {
            ToastOverlay()
        }
        .sheet(isPresented: $appState.isNewRemoteProjectSheetPresented) {
            NewRemoteProjectSheet()
        }
        .onAppear {
            AdaptiveTerminalChrome.shared.mainWindowDidAppear()
        }
        .task {
            guard !appState.hasRestoredSelection else { return }
            appState.restoreSelection(projects: projectStore.projects)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            handleSidebarPeekHover(phase)
        }
        .onChange(of: appState.sidebarVisible) { _, visible in
            if visible {
                // A peek promoted to pinned (toolbar button, shortcut while
                // peeked): the column is already out, just drop the peek flag.
                isPeeking = false
            } else if isPeeking {
                // Hidden by shortcut while peeked out under the pointer: don't
                // let the very next hover event pop it straight back open.
                isPeeking = false
                suppressPeekUntilExit = true
            }
            if !visible {
                // A shortcut hide collapses the column just like a peek's
                // retraction; a peek starting into that animation would
                // reverse it mid-flight (see `beginPeek`).
                peekCollapseSettleTime = Date().addingTimeInterval(peekAnimationDuration)
            }
            withAnimation {
                columnVisibility = visible ? .automatic : .detailOnly
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            // The column can move without going through AppState (toolbar
            // button, drag-out); mirror it back so the toggle shortcut acts on
            // what's on screen — desynced, it needed two presses to re-hide.
            // A peek is the exception: the column shows while the user's
            // toggle state stays hidden.
            if isPeeking {
                // The toolbar button honors the sidebar's real configuration
                // (hidden), not the peeked column it happens to see — so its
                // collapse means "show": pin the sidebar instead of letting
                // it vanish. Our own unpeek can't land here (`endPeek` drops
                // the flag before collapsing).
                if visibility == .detailOnly {
                    isPeeking = false
                    appState.sidebarVisible = true
                }
                return
            }
            let visible = visibility != .detailOnly
            if appState.sidebarVisible != visible {
                appState.sidebarVisible = visible
            }
        }
        .onChange(of: appState.isCommandPaletteVisible) { _, visible in
            guard !visible else { return }
            // Run a post-dismiss action if one was registered, otherwise return
            // focus to the active terminal pane so typing resumes immediately.
            if let action = appState.postPaletteAction {
                appState.postPaletteAction = nil
                DispatchQueue.main.async { action() }
            } else {
                DispatchQueue.main.async { appState.restoreFocusToActivePane() }
            }
        }
    }

    /// Remember an open sidebar width, and persist it for the next launch.
    ///
    /// The geometry callback fires continuously through a drag, so the write
    /// is filtered to changes worth a defaults round-trip — sub-point jitter
    /// (and every frame of an animating peek that lands back where it started)
    /// writes nothing.
    private func recordSidebarWidth(_ width: CGFloat) {
        sidebarWidth = width
        let rounded = (Double(width) * 2).rounded() / 2
        guard abs(rounded - preferences.sidebarWidth) >= 0.5 else { return }
        preferences.sidebarWidth = rounded
    }

    /// Hover-peek for the hidden sidebar: pointer in the leading-edge strip
    /// slides it out at its remembered width; pointer off the sidebar (or out
    /// of the window) slides it back in. Runs through `columnVisibility`, the
    /// shortcut's path, so the titlebar lays out as for a pinned sidebar.
    private func handleSidebarPeekHover(_ phase: HoverPhase) {
        switch phase {
        case let .active(point):
            lastHoverPoint = point
            guard !appState.sidebarVisible else { return }
            // Toggleable in Settings → Appearance → Sidebar. Checked here, not
            // at the modifier, so flipping it off mid-peek still retracts.
            guard preferences.peekSidebarWhenHidden else {
                if isPeeking { endPeek() }
                return
            }
            if suppressPeekUntilExit {
                if point.x > peekStripWidth { suppressPeekUntilExit = false }
                return
            }
            if !isPeeking, point.x <= peekStripWidth {
                beginPeek()
            } else if isPeeking, point.x > sidebarWidth + 8 {
                endPeek()
            } else if isPeeking {
                // Pointer back over the sidebar: cancel a deferred retraction.
                deferredUnpeek = false
            }
        case .ended:
            // The pointer left the window entirely.
            lastHoverPoint = nil
            deferredPeek = false
            if isPeeking { endPeek() }
            suppressPeekUntilExit = false
        }
    }

    /// Start the peek — but never by interrupting the collapse animation: a
    /// too-quick re-entry defers the peek until the collapse has settled, then
    /// re-checks against the pointer's last known position (it may be parked
    /// in the strip, generating no further events to retry on).
    private func beginPeek() {
        let remaining = peekCollapseSettleTime.timeIntervalSinceNow
        guard remaining <= 0 else {
            guard !deferredPeek else { return }
            deferredPeek = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(remaining))
                guard deferredPeek else { return }
                deferredPeek = false
                guard !isPeeking, !appState.sidebarVisible,
                      preferences.peekSidebarWhenHidden, !suppressPeekUntilExit,
                      let point = lastHoverPoint, point.x <= peekStripWidth
                else { return }
                expandPeek()
            }
            return
        }
        expandPeek()
    }

    private func expandPeek() {
        isPeeking = true
        deferredPeek = false
        peekExpandSettleTime = Date().addingTimeInterval(peekAnimationDuration)
        withAnimation { columnVisibility = .automatic }
    }

    /// Retract the peek — but never by interrupting the expand animation.
    /// Collapsing the column mid-expand corrupts NavigationSplitView's stored
    /// width metric (the sidebar then reopens at the default width, and no
    /// `ideal` can override a stored metric), so a too-quick exit defers the
    /// retraction until the expand has settled.
    private func endPeek() {
        let remaining = peekExpandSettleTime.timeIntervalSinceNow
        guard remaining <= 0 else {
            guard !deferredUnpeek else { return }
            deferredUnpeek = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(remaining))
                guard deferredUnpeek, isPeeking else { return }
                collapsePeek()
            }
            return
        }
        collapsePeek()
    }

    private func collapsePeek() {
        isPeeking = false
        deferredUnpeek = false
        peekCollapseSettleTime = Date().addingTimeInterval(peekAnimationDuration)
        withAnimation { columnVisibility = .detailOnly }
    }

    private var activeProject: Project? {
        guard let pid = appState.activeProjectID else { return nil }
        return projectStore.projects.first { $0.id == pid }
    }

    private var activeProjectWithWorkspace: Project? {
        guard let project = activeProject, appState.workspaces[project.id] != nil else { return nil }
        return project
    }

    private func projectHasAnyTab(_ project: Project) -> Bool {
        !(appState.workspaces[project.id]?.tabs.isEmpty ?? true)
    }

    private var activeTabTitle: String {
        guard let project = activeProject else { return "" }
        return project.path
    }
}

struct WelcomeView: View {
    @State
    private var preferences = Preferences.shared

    /// Reads `hotkeyVersion` so a rebind refreshes the label. Bindings live in
    /// raw defaults keys, so the `HotkeyRegistry` read alone is invisible to
    /// SwiftUI and the hint would otherwise show the launch-time shortcut.
    private func shortcutLabel(for action: HotkeyAction) -> String {
        _ = preferences.hotkeyVersion
        return HotkeyRegistry.displayString(for: HotkeyRegistry.selectedShortcutString(for: action))
    }

    private var shortcuts: [(HotkeyAction, String)] {
        [
            (.openProject, "Open a project"),
            (.toggleCommandPalette, "Command palette"),
            (.toggleSidebar, "Toggle sidebar"),
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Text(appDisplayName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MactermTheme.fg)
                Text("No project selected")
                    .font(.system(size: 12))
                    .foregroundStyle(MactermTheme.fgMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(shortcuts, id: \.0) { action, label in
                    HStack(spacing: 10) {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(MactermTheme.fgMuted)
                            .frame(width: 160, alignment: .leading)
                        Text(shortcutLabel(for: action))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MactermTheme.fgDim)
                    }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct EmptyProjectView: View {
    let project: Project

    @State
    private var preferences = Preferences.shared

    /// See `WelcomeView.shortcutLabel` — same rebind-observability need.
    private func shortcutLabel(for action: HotkeyAction) -> String {
        _ = preferences.hotkeyVersion
        return HotkeyRegistry.displayString(for: HotkeyRegistry.selectedShortcutString(for: action))
    }

    private var shortcuts: [(HotkeyAction, String)] {
        [
            (.newTab, "New tab"),
            (.openProject, "Open another project"),
            (.toggleCommandPalette, "Command palette"),
            (.toggleSidebar, "Toggle sidebar"),
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Text(project.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MactermTheme.fg)
                Text(project.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MactermTheme.fgMuted)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(shortcuts, id: \.0) { action, label in
                    HStack(spacing: 10) {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(MactermTheme.fgMuted)
                            .frame(width: 160, alignment: .leading)
                        Text(shortcutLabel(for: action))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MactermTheme.fgDim)
                    }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct WorkspaceView: View {
    let project: Project
    @Environment(AppState.self)
    private var appState
    /// The pane currently dragged by its grab handle, bubbled up via
    /// `DraggingPaneKey` so the dragged pane's own leaf drops its target.
    @State
    private var draggedPaneID: UUID?
    /// The live drop resolution shared by the per-leaf pane targets and the
    /// workspace-level tab target; the workspace overlay renders its preview.
    @State
    private var dropResolution: TabDropResolution?

    var body: some View {
        if let ws = appState.workspaces[project.id], let tab = ws.activeTab {
            let renderedNode: SplitNode = {
                if let zoomID = tab.zoomedPaneID, let pane = tab.splitRoot.findPane(id: zoomID) {
                    return .pane(pane)
                }
                return tab.splitRoot
            }()
            SplitTreeView(
                node: renderedNode,
                focusedPaneID: tab.focusedPaneID,
                zoomedPaneID: tab.zoomedPaneID,
                isActiveProject: true,
                projectID: project.id,
                onFocusPane: { appState.focusPane($0, projectID: project.id) },
                onSplit: { paneID, dir in
                    tab.split(paneID: paneID, direction: dir)
                    appState.saveWorkspaces()
                },
                onClosePane: { appState.handleProcessExit($0, projectID: project.id) },
                onCommandFinished: { paneID in
                    appState.acknowledgeFinishedCommandIfActive(paneID: paneID, projectID: project.id)
                },
                onAdaptiveBackgroundChange: { paneID, color in
                    appState.setAdaptiveBackgroundColor(color, paneID: paneID, projectID: project.id)
                },
                onToggleZoom: { tab.toggleZoom(paneID: $0) },
                paneDrop: PaneDropContext(
                    root: renderedNode,
                    resolution: $dropResolution,
                    draggedPaneID: draggedPaneID,
                    renderedTabID: tab.id,
                    onMovePane: { paneID, target in
                        if tab.movePane(paneID, to: target) {
                            appState.saveWorkspaces()
                        }
                    },
                    onMergeTab: { movable, target in
                        appState.mergeTab(
                            movable.tabID,
                            from: movable.sourceProjectID,
                            at: target,
                            inProject: project.id
                        )
                    }
                )
            )
            .id(renderedNode.id)
            // Pane grab-handle drags and sidebar tab drags are both captured
            // per leaf (see LeafDropDelegate for why there is no whole-area
            // target), sharing one resolution rendered here (#227). Uses
            // `renderedNode`, not `tab.splitRoot`: while zoomed the user sees
            // one pane, so a drop should read as a local split of it, not of
            // the hidden layout.
            .overlay {
                WorkspaceDropPreview(resolution: dropResolution)
            }
            .onPreferenceChange(DraggingPaneKey.self) { value in
                MainActor.assumeIsolated {
                    draggedPaneID = value
                    // A drag that ended without a valid drop leaves no exited
                    // event behind; clear any stray preview.
                    if value == nil { dropResolution = nil }
                }
            }
            .overlay(alignment: .topTrailing) {
                if tab.zoomedPaneID != nil {
                    ZoomIndicator(onExit: { appState.toggleZoom(projectID: project.id) })
                        .padding(8)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// Small badge shown in the corner of a tab while one of its panes is zoomed.
/// Clicking it exits zoom and restores the full split layout.
struct ZoomIndicator: View {
    let onExit: () -> Void

    var body: some View {
        Button(action: onExit) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text("Zoomed")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MactermTheme.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MactermTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(MactermTheme.border, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Exit zoom")
    }
}

private struct WindowStyler: NSViewRepresentable {
    /// Mirrors `Preferences.hideTitleBar`. The toolbar hide is SwiftUI-side
    /// (`.toolbar(.hidden, for: .windowToolbar)` in `MainWindow`); the title
    /// text is an `NSWindow` property, so it's applied here.
    var hideTitle: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Retry across run-loop ticks until the view is attached to its window.
        // A single fire-and-forget async that ran before attachment used to
        // silently skip `interceptClose`, leaving the red close button to
        // actually close the window (killing surfaces) — the exact invariant
        // this styler enforces. Bounded so a never-attached view can't spin.
        styleWhenAttached(view: view, coordinator: context.coordinator, attempts: 0)
        return view
    }

    private func styleWhenAttached(view: NSView, coordinator: Coordinator, attempts: Int) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                guard attempts < 30 else {
                    styleLogger.error("WindowStyler: view never attached to a window; close interception not installed")
                    return
                }
                styleWhenAttached(view: view, coordinator: coordinator, attempts: attempts + 1)
                return
            }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.tabbingMode = .disallowed
            // Let the content view extend under the titlebar so the sidebar
            // and terminal paint continuously up to the top of the window.
            // Without this the titlebar floats above the sidebar with a
            // visible boundary, which is jarring when both are translucent.
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = hideTitle ? .hidden : .visible
            WindowAppearance.sync(window: window)
            coordinator.observe(window: window)
            // Intercept the close button to hide instead of close,
            // preserving terminal surfaces and running processes.
            coordinator.interceptClose(window: window)
        }
    }

    func updateNSView(_ view: NSView, context _: Context) {
        // Follow live setting flips. Async because SwiftUI forbids window
        // mutation from inside the update pass.
        let hide = hideTitle
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = hide ? .hidden : .visible
            WindowAppearance.syncTitleBarHidden(window: window)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        nonisolated(unsafe) private var observer: Any?
        weak var swiftuiDelegate: (any NSWindowDelegate)?

        @MainActor
        func observe(window: NSWindow) {
            // Re-apply on config change. AppKit also rebuilds the titlebar
            // subviews on becomeMain / fullscreen transitions, so we resync
            // there too via the delegate hooks below. A system light/dark
            // switch also lands here: GhosttyApp's appearance observer posts
            // .mactermConfigDidChange so the window tint follows the resolved
            // theme (issue #38).
            observer = NotificationCenter.default.addObserver(
                forName: .mactermConfigDidChange,
                object: nil,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { WindowAppearance.sync(window: window) }
            }
        }

        func windowDidBecomeMain(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidBecomeMain?(notification)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                WindowAppearance.syncKeyStatus(window: window)
            }
            swiftuiDelegate?.windowDidBecomeKey?(notification)
        }

        func windowDidResignKey(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                WindowAppearance.syncKeyStatus(window: window)
            }
            swiftuiDelegate?.windowDidResignKey?(notification)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidEnterFullScreen?(notification)
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidExitFullScreen?(notification)
        }

        @MainActor
        func interceptClose(window: NSWindow) {
            swiftuiDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // During app termination AppKit asks every window if it can close.
            // The "hide instead of close" trick is only for the user clicking
            // the red close button while the app keeps running — when we're
            // shutting down, let the window actually close so the process can
            // exit instead of leaving an invisible window holding the app open.
            if AppTerminationState.isTerminating { return true }
            sender.orderOut(nil)
            return false
        }

        /// Forward everything else to SwiftUI's delegate
        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return swiftuiDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if swiftuiDelegate?.responds(to: aSelector) == true { return swiftuiDelegate }
            return super.forwardingTarget(for: aSelector)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
