import AppKit
import os
import SwiftUI

private let styleLogger = Logger(subsystem: appBundleID, category: "WindowStyler")

struct MainWindow: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    /// This window's own selection state (#345). `@State` so each window
    /// instance of the `WindowGroup` gets its own, which is what lets two
    /// windows show different projects.
    @State
    private var windowState = WindowState()
    @State
    private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State
    private var detailWidth: CGFloat = .infinity
    @State
    private var preferences = Preferences.shared
    @State
    private var attachedWindow: NSWindow?
    @State
    private var windowCornerRadius: CGFloat?
    @State
    private var windowTopSafeAreaInset: CGFloat = 0
    @State
    private var initialNativeSidebarVisible: Bool?
    @State
    private var initialSidebarVisibilityBeingApplied: Bool?
    @State
    private var sidebarPresentation = SidebarPresentationState()
    /// The sidebar is temporarily out because the pointer is at the leading
    /// edge while the user's toggle state still says hidden. Resize peeks use
    /// `columnVisibility`; overlay peeks leave that column hidden and mount a
    /// separate glass surface.
    @State
    private var activePeekStyle: SidebarPeekStyle?
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
    private var sidebarWidthHandoff = SidebarWidthHandoff(
        width: CGFloat(Preferences.shared.launchSidebarWidth)
    )
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
    private var deferredUnpeekTask: Task<Void, Never>?
    /// A peek is queued behind the collapse animation (the pointer may be
    /// parked in the strip, generating no further hover events to retry on).
    @State
    private var deferredPeekTask: Task<Void, Never>?
    @State
    private var overlayWindowExitTask: Task<Void, Never>?
    /// Last hover location, for deferred re-checks that fire without a fresh
    /// event. Cleared when the pointer leaves the window.
    @State
    private var lastHoverPoint: CGPoint?
    @State
    private var wasApproachingSidebar = false
    @State
    private var sidebarWidthHandoffTask: Task<Void, Never>?
    @State
    private var isResizingOverlay = false
    @State
    private var overlayMenuTrackingDepth = 0

    /// Conservative bound on the column expand/collapse animation, including a
    /// margin — deferring the opposite transition slightly long is invisible,
    /// cutting it short reverses the animation mid-flight and corrupts
    /// NavigationSplitView's stored width metric.
    private let peekAnimationDuration: TimeInterval = 0.4

    private let peekTransitionAnimation = Animation.easeOut(duration: 0.2)

    private var isPeeking: Bool { activePeekStyle != nil }
    private var isOverlayPeeking: Bool { activePeekStyle == .overlayTerminal }
    private var sidebarWidth: CGFloat { sidebarWidthHandoff.width }
    private var peekStripWidth: CGFloat { SidebarOverlayMetrics.hoverActivationWidth }
    /// How far in from the leading edge the CONFIGURED style can acquire a
    /// peek. The overlay's intent-aware corridor is far wider than the strip,
    /// so `suppressPeekUntilExit` has to be armed and cleared against this —
    /// against the strip, an explicit hide with the pointer at x=40 armed
    /// nothing and the smallest leftward move popped the overlay back out.
    /// For the resize style the two are the same value.
    private var peekAcquisitionWidth: CGFloat {
        preferences.sidebarPeekStyle == .overlayTerminal
            ? SidebarOverlayMetrics.hoverApproachWidth
            : SidebarOverlayMetrics.hoverActivationWidth
    }

    private var peekExitPadding: CGFloat { SidebarOverlayMetrics.hoverExitPadding }
    private var isNativeSidebarInteractive: Bool {
        windowState.sidebarVisible || activePeekStyle == .resizeTerminal
    }

    var body: some View {
        // Derive bindings to the @Observable AppState via @Bindable (the
        // Observation-era idiom) rather than a hand-rolled Binding(get:set:).
        @Bindable var windowState = windowState
        // Read in body, not inside the toolbar builder, so the Observation
        // dependency is registered and a Settings change re-places the item.
        let switcherPosition = preferences.tabSwitcherPosition
        // Hiding the window toolbar (#226) also drops the titlebar itself,
        // traffic lights included — that's AppKit's behavior for a toolbar-less
        // fullSizeContentView window, not something we do separately. Read in
        // body so flipping the setting re-applies live.
        let chromeHidden = preferences.hideTitleBar
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarContent(
                presentation: sidebarPresentation,
                isInteractive: isNativeSidebarInteractive
            )
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
                if width >= 100 { recordNativeSidebarWidth(width) }
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
        .overlay(alignment: .leading) {
            if isOverlayPeeking, !windowState.sidebarVisible {
                SidebarOverlayPanel(
                    width: sidebarWidth,
                    chromeHidden: chromeHidden,
                    windowCornerRadius: windowCornerRadius,
                    windowTopSafeAreaInset: windowTopSafeAreaInset,
                    presentation: sidebarPresentation,
                    isInteractive: isOverlayPeeking,
                    onResize: { recordOverlaySidebarWidth($0) },
                    onResizeStateChanged: { handleOverlayResizeState($0) }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .toolbar(chromeHidden ? .hidden : .visible, for: .windowToolbar)
        .background(WindowStyler(
            hideTitle: chromeHidden,
            windowCornerRadius: $windowCornerRadius,
            windowTopSafeAreaInset: $windowTopSafeAreaInset,
            initialSidebarVisible: $initialNativeSidebarVisible,
            onWindowAttached: { window in
                // Register HERE, not in `onAppear`. SwiftUI instantiates a
                // view — and its `@State` — more than once per real window,
                // and `onAppear` fires for the throwaway too, which registered
                // a phantom second window on every launch. An `NSWindow` is
                // one per actual window, so attachment is the real identity.
                // Arm before `WindowAppearance.sync` runs inside the styler,
                // and before the geometry hook writes the column's
                // content-derived width over the stored value.
                let resolved = appState.canonicalWindowState(for: window, proposed: windowState)
                WindowAppearance.armSidebarWidthRestore(for: window) {
                    // nil until the launch task has read the saved windows;
                    // the restore retries until then.
                    guard appState.hasRestoredWindows else { return nil }
                    return WindowAppearance.SidebarRestorePlan(
                        width: CGFloat(resolved.sidebarWidth),
                        visible: resolved.sidebarVisible
                    )
                }
                appState.appDelegate?.registerTerminalWindow(window)
                attachedWindow = window
                // Adopt the canonical state for this NSWindow. A second view
                // instance for the same window drops its own and takes the
                // first one's, so the app never sees a phantom window.
                windowState = appState.canonicalWindowState(for: window, proposed: windowState)
            },
            // Resolve the state THROUGH the window, not from the captured
            // `windowState`: this closure is built by whichever view instance
            // SwiftUI happened to evaluate, and a throwaway instance's own
            // state is never registered — noting it as key left the app's
            // key-window record pointing at a phantom.
            onWindowBecameKey: { window in
                appState.noteKeyWindow(appState.canonicalWindowState(for: window, proposed: windowState))
            },
            shouldHideOnClose: { appState.appDelegate?.hidesInsteadOfClosing($0) ?? true }
        ))
        .overlay {
            if windowState.isCommandPaletteVisible {
                CommandPaletteOverlay()
            }
        }
        // Below the palette (the two can't be up together — cycling commits on
        // modifier release), above the terminal it describes.
        .overlay {
            // Only in the window the user is cycling in (#345): the cycle
            // state is app-wide, and ungated every window drew the strip.
            if appState.isTabCycling, preferences.showTabSwitcherOverlay,
               appState.keyWindowID == windowState.id
            {
                TabSwitcherOverlay()
            }
        }
        // Above the palette overlay so a toast fired by a palette command isn't
        // covered by the palette's own dismissal animation.
        .overlay {
            ToastOverlay()
        }
        .sheet(isPresented: $windowState.isNewRemoteProjectSheetPresented) {
            NewRemoteProjectSheet()
        }
        .environment(windowState)
        // Applied here rather than in the scene so each copy knows WHICH
        // window it is: they stay grouped in these three modifiers, which is
        // the rule — the alerts must not scatter back into `body`.
        .modifier(CloseConfirmationAlerts(appState: appState, windowID: windowState.id))
        .modifier(ProjectConfirmationAlerts(appState: appState, windowID: windowState.id))
        .modifier(LayoutAlerts(appState: appState, windowID: windowState.id))
        .onAppear {
            AdaptiveTerminalChrome.shared.mainWindowDidAppear()
        }
        .onDisappear {
            if let attachedWindow { appState.windowDidClose(attachedWindow) }
            cancelDeferredPeek()
            cancelDeferredUnpeek()
            cancelOverlayWindowExit()
            cancelSidebarWidthHandoff()
        }
        .task {
            guard !appState.hasRestoredSelection else { return }
            appState.restoreSelection(projects: projectStore.projects)
            // After the restore, never before: "is this a fresh install?" is
            // only answerable once the snapshot is loaded, `pinned.yaml` is
            // reconciled and a load failure is known (see FirstRunSeed).
            appState.seedFirstRunIfNeeded(projectStore: projectStore)
            // After the restore, so the saved windows' projects exist. This
            // window adopts the first saved entry and opens the rest (#345).
            appState.restoreWindows(adopting: windowState)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            handleSidebarPeekHover(phase)
        }
        .onChange(of: initialNativeSidebarVisible) { _, visible in
            guard visible != nil else { return }
            // The window's own record decides (#345): a restored window comes
            // back the way it was saved and a new window comes up with the
            // sidebar shown. AppKit's autosaved collapse state used to win
            // here (`SidebarPeekInteraction.launchResolution`), and it is per
            // autosave SLOT, so a new window inherited whatever the last
            // window at that slot had left. The column follows the model;
            // `WindowAppearance.restoreSidebarWidth` uncollapses the native
            // item to match before applying the width.
            initialSidebarVisibilityBeingApplied = nil
            let modelVisible = windowState.sidebarVisible
            let column: NavigationSplitViewVisibility = modelVisible ? .automatic : .detailOnly
            if columnVisibility != column { columnVisibility = column }
        }
        .onChange(of: windowState.sidebarVisible) { _, visible in
            let isInitialReconciliation = initialSidebarVisibilityBeingApplied == visible
            if isInitialReconciliation { initialSidebarVisibilityBeingApplied = nil }
            cancelDeferredPeek()
            cancelDeferredUnpeek()
            cancelOverlayWindowExit()
            if visible {
                scheduleSidebarWidthHandoff()
                activePeekStyle = nil
            } else if !isInitialReconciliation,
                      isPeeking || lastHoverPoint.map({ $0.x <= peekAcquisitionWidth }) == true
            {
                // Hidden by shortcut while peeked out under the pointer: don't
                // let the very next hover event pop it straight back open.
                activePeekStyle = nil
                suppressPeekUntilExit = true
            }
            if !visible { cancelSidebarWidthHandoff() }
            if !visible, !isInitialReconciliation {
                // A shortcut hide collapses the column just like a peek's
                // retraction. Both presentations wait for that one native
                // collapse, so their next edge entry starts at the same time.
                peekCollapseSettleTime = Date().addingTimeInterval(peekAnimationDuration)
            }
            if isInitialReconciliation {
                columnVisibility = visible ? .automatic : .detailOnly
            } else {
                withAnimation {
                    columnVisibility = visible ? .automatic : .detailOnly
                }
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            // The column can move without going through AppState (toolbar
            // button, drag-out); mirror it back so the toggle shortcut acts on
            // what's on screen — desynced, it needed two presses to re-hide.
            // A peek is the exception: the column shows while the user's
            // toggle state stays hidden.
            if isPeeking {
                if isOverlayPeeking {
                    // The overlay never changes the split-view column. If the
                    // toolbar button opens that column, promote the temporary
                    // peek to the one pinned native sidebar and remove the
                    // overlay immediately.
                    if SidebarPeekInteraction.shouldPromoteOverlay(
                        activeStyle: activePeekStyle,
                        columnVisible: visibility != .detailOnly
                    ) {
                        activePeekStyle = nil
                        windowState.sidebarVisible = true
                    }
                    return
                }
                // The toolbar button honors the sidebar's real configuration
                // (hidden), not the peeked column it happens to see — so its
                // collapse means "show": pin the sidebar instead of letting
                // it vanish. Our own unpeek can't land here (`endPeek` drops
                // the flag before collapsing).
                if visibility == .detailOnly {
                    activePeekStyle = nil
                    windowState.sidebarVisible = true
                }
                return
            }
            let visible = visibility != .detailOnly
            if windowState.sidebarVisible != visible {
                windowState.sidebarVisible = visible
            }
        }
        .onChange(of: preferences.sidebarPeekStyle) { oldStyle, newStyle in
            guard oldStyle != newStyle else { return }
            cancelDeferredPeek()
            cancelOverlayWindowExit()
            if !windowState.sidebarVisible { cancelSidebarWidthHandoff() }
            guard isPeeking, !windowState.sidebarVisible else { return }
            // The presentation that began the peek owns its full transition.
            // Finish it before the new preference can start a fresh peek.
            suppressPeekUntilExit = true
            endPeek(allowCancellation: false)
        }
        .onChange(of: preferences.peekSidebarWhenHidden) { _, enabled in
            if !enabled {
                cancelDeferredPeek()
                cancelOverlayWindowExit()
                if isPeeking {
                    suppressPeekUntilExit = true
                    endPeek(allowCancellation: false)
                }
            }
        }
        .onChange(of: windowState.isCommandPaletteVisible) { _, visible in
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
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            if isOverlayPeeking { overlayMenuTrackingDepth += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            guard overlayMenuTrackingDepth > 0 else { return }
            overlayMenuTrackingDepth -= 1
            if overlayMenuTrackingDepth == 0, isOverlayPeeking, lastHoverPoint == nil {
                scheduleOverlayWindowExit()
            }
        }
    }

    /// Remember an open sidebar width, and persist it for the next launch.
    ///
    /// The geometry callback fires continuously through a drag, so the write
    /// is filtered to changes worth a defaults round-trip — sub-point jitter
    /// (and every frame of an animating peek that lands back where it started)
    /// writes nothing.
    private func persistSidebarWidth(_ width: CGFloat) {
        // Until the restore has run, the column is showing SwiftUI's
        // content-derived width; recording it would overwrite the width we are
        // about to restore with the default it replaces.
        //
        // A nil `attachedWindow` counts as "not yet": the geometry hook fires
        // during layout, BEFORE the styler has found the window, so treating
        // nil as "nothing pending" let the content-derived width through —
        // which is exactly how 144 kept landing in the snapshot.
        guard let attachedWindow,
              !WindowAppearance.isAwaitingSidebarWidthRestore(for: attachedWindow)
        else { return }
        let rounded = (Double(width) * 2).rounded() / 2
        // This window's own width, and the app-wide default a NEW window opens
        // at — dragging one window's sidebar should not resize another's, but
        // the next window you open should match what you just set (#345).
        if abs(rounded - windowState.sidebarWidth) >= 0.5 {
            windowState.sidebarWidth = rounded
            appState.noteSidebarWidthChanged()
        }
        guard abs(rounded - preferences.sidebarWidth) >= 0.5 else { return }
        preferences.sidebarWidth = rounded
    }

    private func recordNativeSidebarWidth(_ width: CGFloat) {
        guard let accepted = sidebarWidthHandoff.nativeMeasured(width) else { return }
        persistSidebarWidth(accepted)
    }

    private func recordOverlaySidebarWidth(_ width: CGFloat) {
        persistSidebarWidth(sidebarWidthHandoff.overlayResized(to: width))
    }

    private func scheduleSidebarWidthHandoff() {
        cancelSidebarWidthHandoff()
        let targetWidth = sidebarWidthHandoff.beginNativeHandoff()
        sidebarWidthHandoffTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(peekAnimationDuration))
            } catch {
                return
            }
            guard windowState.sidebarVisible || activePeekStyle == .resizeTerminal,
                  let window = attachedWindow,
                  WindowAppearance.setSidebarWidth(targetWidth, window: window)
            else {
                // Nothing applied the target, so nothing will ever measure it.
                sidebarWidthHandoffTask = nil
                sidebarWidthHandoff.endNativeHandoff()
                return
            }
            // AppKit can settle short of the target — a narrow window clamps
            // the divider — and no later measurement would match it. Give the
            // geometry hook one settle window to confirm, then disarm anyway.
            do {
                try await Task.sleep(for: .seconds(peekAnimationDuration))
            } catch {
                return
            }
            sidebarWidthHandoffTask = nil
            sidebarWidthHandoff.endNativeHandoff()
        }
    }

    private func cancelSidebarWidthHandoff() {
        sidebarWidthHandoffTask?.cancel()
        sidebarWidthHandoffTask = nil
        // An abandoned handoff must not keep rejecting native measurements.
        // `scheduleSidebarWidthHandoff` re-arms straight after cancelling, and
        // the pending target only ever holds the current width, so re-arming
        // reproduces the same value.
        sidebarWidthHandoff.endNativeHandoff()
    }

    /// Hover-peek for the hidden sidebar. The resize style uses the native
    /// split-view column; the overlay style leaves that column hidden and
    /// draws a separate glass panel over the terminal.
    private func handleSidebarPeekHover(_ phase: HoverPhase) {
        switch phase {
        case let .active(point):
            let previousPoint = lastHoverPoint
            wasApproachingSidebar = previousPoint.map { point.x < $0.x }
                ?? (point.x <= SidebarOverlayMetrics.hoverApproachWidth)
            lastHoverPoint = point
            cancelOverlayWindowExit()
            if isResizingOverlay { return }
            guard !windowState.sidebarVisible else { return }
            // Toggleable in Settings → Appearance → Sidebar. Checked here, not
            // at the modifier, so flipping it off mid-peek still retracts.
            guard preferences.peekSidebarWhenHidden else {
                if isPeeking { endPeek() }
                return
            }
            if suppressPeekUntilExit {
                if point.x > peekAcquisitionWidth { suppressPeekUntilExit = false }
                return
            }
            let shouldBegin = SidebarPeekInteraction.shouldBeginHover(
                style: preferences.sidebarPeekStyle,
                pointX: point.x,
                previousX: previousPoint?.x
            )
            if !isPeeking, shouldBegin {
                beginPeek()
            } else if isPeeking {
                if point.x <= sidebarWidth + peekExitPadding {
                    if !suppressPeekUntilExit { cancelDeferredUnpeek() }
                } else {
                    endPeek()
                }
            }
        case .ended:
            let exitPoint = lastHoverPoint
            let exitedLeadingWindowEdge = pointerIsOutsideLeadingWindowEdge
            let recoverFastOverlayEntry = !isPeeking
                && !windowState.sidebarVisible
                && preferences.peekSidebarWhenHidden
                && preferences.sidebarPeekStyle == .overlayTerminal
                && !suppressPeekUntilExit
                && SidebarOverlayMetrics.shouldRecoverFastExit(
                    lastX: exitPoint?.x,
                    wasApproaching: wasApproachingSidebar
                )
                && exitedLeadingWindowEdge
                && pointerIsWithinOverlayRetentionRegion
            lastHoverPoint = nil
            wasApproachingSidebar = false
            cancelDeferredPeek()
            if recoverFastOverlayEntry {
                beginPeek(whileOutsideWindow: true)
            } else if isOverlayPeeking, !isResizingOverlay {
                scheduleOverlayWindowExit()
            } else if isPeeking, !isResizingOverlay {
                endPeek()
            }
            suppressPeekUntilExit = false
        }
    }

    /// Start the peek — but never by interrupting the collapse animation: a
    /// too-quick re-entry defers the peek until the collapse has settled, then
    /// re-checks against the pointer's last known position (it may be parked
    /// in the strip, generating no further events to retry on).
    private func beginPeek(whileOutsideWindow: Bool = false) {
        let style = preferences.sidebarPeekStyle
        if whileOutsideWindow, !pointerIsWithinOverlayRetentionRegion { return }
        let remaining = peekCollapseSettleTime.timeIntervalSinceNow
        guard remaining <= 0 else {
            guard deferredPeekTask == nil else { return }
            deferredPeekTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
                deferredPeekTask = nil
                let pointerEligible: Bool = if whileOutsideWindow {
                    pointerIsWithinOverlayRetentionRegion
                } else if style == .overlayTerminal {
                    lastHoverPoint.map { $0.x <= SidebarOverlayMetrics.hoverApproachWidth } ?? false
                } else {
                    lastHoverPoint.map { $0.x <= peekStripWidth } ?? false
                }
                guard !isPeeking, !windowState.sidebarVisible,
                      preferences.peekSidebarWhenHidden, !suppressPeekUntilExit,
                      preferences.sidebarPeekStyle == style,
                      pointerEligible
                else { return }
                expandPeek(style: style, whileOutsideWindow: whileOutsideWindow)
            }
            return
        }
        expandPeek(style: style, whileOutsideWindow: whileOutsideWindow)
    }

    private func expandPeek(style: SidebarPeekStyle, whileOutsideWindow: Bool = false) {
        cancelDeferredPeek()
        if style == .overlayTerminal {
            // `activePeekStyle` is the transition state, so assigning it inside
            // the transaction animates the overlay's conditional mount.
            withAnimation(peekTransitionAnimation) { activePeekStyle = style }
            if whileOutsideWindow, lastHoverPoint == nil { scheduleOverlayWindowExit() }
            return
        }
        activePeekStyle = style
        peekExpandSettleTime = Date().addingTimeInterval(peekAnimationDuration)
        withAnimation(peekTransitionAnimation) { columnVisibility = .automatic }
        scheduleSidebarWidthHandoff()
    }

    /// Retract the peek — but never by interrupting the expand animation.
    /// Collapsing the column mid-expand corrupts NavigationSplitView's stored
    /// width metric (the sidebar then reopens at the default width, and no
    /// `ideal` can override a stored metric), so a too-quick exit defers the
    /// retraction until the expand has settled.
    private func endPeek(allowCancellation: Bool = true) {
        guard let style = activePeekStyle else { return }
        if style == .overlayTerminal {
            collapsePeek(style: style)
            return
        }
        let remaining = peekExpandSettleTime.timeIntervalSinceNow
        guard remaining <= 0 else {
            if allowCancellation {
                guard deferredUnpeekTask == nil else { return }
            } else {
                cancelDeferredUnpeek()
            }
            deferredUnpeekTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
                deferredUnpeekTask = nil
                guard activePeekStyle == style else { return }
                collapsePeek(style: style)
            }
            return
        }
        collapsePeek(style: style)
    }

    private func collapsePeek(style: SidebarPeekStyle) {
        guard activePeekStyle == style else { return }
        cancelDeferredUnpeek()
        if style == .overlayTerminal {
            isResizingOverlay = false
            overlayMenuTrackingDepth = 0
            cancelOverlayWindowExit()
            sidebarPresentation.discardRename()
            withAnimation(peekTransitionAnimation) { activePeekStyle = nil }
            DispatchQueue.main.async {
                guard let window = attachedWindow,
                      window.isKeyWindow, window.attachedSheet == nil,
                      !windowState.isCommandPaletteVisible
                else { return }
                appState.restoreFocusToActivePane()
            }
            return
        }
        activePeekStyle = nil
        peekCollapseSettleTime = Date().addingTimeInterval(peekAnimationDuration)
        withAnimation(peekTransitionAnimation) { columnVisibility = .detailOnly }
    }

    private func cancelDeferredPeek() {
        deferredPeekTask?.cancel()
        deferredPeekTask = nil
    }

    private func cancelDeferredUnpeek() {
        deferredUnpeekTask?.cancel()
        deferredUnpeekTask = nil
    }

    private func scheduleOverlayWindowExit() {
        guard overlayWindowExitTask == nil else { return }
        overlayWindowExitTask = Task { @MainActor in
            var lastPointer: CGPoint?
            var stationaryTicks = 0
            while !Task.isCancelled {
                guard isOverlayPeeking, !windowState.sidebarVisible, !isResizingOverlay,
                      let window = attachedWindow
                else {
                    overlayWindowExitTask = nil
                    return
                }

                let pointer = NSEvent.mouseLocation
                if let lastPointer, abs(pointer.x - lastPointer.x) < 0.5,
                   abs(pointer.y - lastPointer.y) < 0.5
                {
                    stationaryTicks += 1
                } else {
                    stationaryTicks = 0
                }
                lastPointer = pointer
                let pointerIsRetained = SidebarOverlayMetrics.retainsOutsidePointer(
                    pointer,
                    windowFrame: window.frame,
                    sidebarWidth: sidebarWidth
                )
                let shouldRetain = SidebarPeekInteraction.shouldRetainOverlay(.init(
                    appIsActive: NSApp.isActive,
                    windowIsVisible: window.isVisible,
                    windowIsMiniaturized: window.isMiniaturized,
                    windowIsKey: window.isKeyWindow,
                    peekEnabled: preferences.peekSidebarWhenHidden,
                    configuredStyle: preferences.sidebarPeekStyle,
                    menuTrackingDepth: overlayMenuTrackingDepth,
                    pressedMouseButtons: NSEvent.pressedMouseButtons,
                    pointerIsRetained: pointerIsRetained
                ))
                guard shouldRetain else {
                    overlayWindowExitTask = nil
                    collapsePeek(style: .overlayTerminal)
                    return
                }

                do {
                    // A parked pointer cannot leave the retention region, and
                    // this region has no time-based dismissal, so a pointer
                    // resting in it would otherwise wake the main actor 30
                    // times a second indefinitely. Back off once it has been
                    // still for ~half a second; any movement snaps the poll
                    // straight back to the responsive rate.
                    try await Task.sleep(
                        for: .milliseconds(stationaryTicks >= 15 ? 500 : 33)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func cancelOverlayWindowExit() {
        overlayWindowExitTask?.cancel()
        overlayWindowExitTask = nil
    }

    private var pointerIsOutsideLeadingWindowEdge: Bool {
        guard let window = attachedWindow else { return false }
        return NSEvent.mouseLocation.x <= window.frame.minX + 2
    }

    private var pointerIsWithinOverlayRetentionRegion: Bool {
        guard let window = attachedWindow else { return false }
        return SidebarOverlayMetrics.retainsOutsidePointer(
            NSEvent.mouseLocation,
            windowFrame: window.frame,
            sidebarWidth: sidebarWidth
        )
    }

    private func handleOverlayResizeState(_ isResizing: Bool) {
        isResizingOverlay = isResizing
        guard !isResizing else { return }
        if let lastHoverPoint {
            if SidebarPeekInteraction.shouldCollapseAfterResize(
                lastHoverX: lastHoverPoint.x,
                sidebarWidth: sidebarWidth
            ) {
                endPeek()
            }
        } else {
            scheduleOverlayWindowExit()
        }
    }

    private var activeProject: Project? {
        // This window's project, never `appState.activeProjectID` — that
        // mirrors whichever window is KEY, so a background window would redraw
        // itself as whatever the frontmost one is showing (#345).
        guard let pid = windowState.activeProjectID else { return nil }
        // The pinned workspace has no ProjectStore row; render it through the
        // synthetic project.
        if pid == PinnedTabs.projectID { return PinnedTabs.project }
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
        // The pinned workspace has no project directory worth advertising.
        if project.id == PinnedTabs.projectID { return "" }
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
    /// This window's own view of the project (#345). Never `ws.activeTab`:
    /// that is the KEY window's, and a pane's one NSView can only be in one
    /// window — so when another window owns the selected tab this renders a
    /// mirror of it, and every callback maps back onto the real tab.
    @Environment(WindowState.self)
    private var windowState
    /// The pane currently dragged by its grab handle, bubbled up via
    /// `DraggingPaneKey` so the dragged pane's own leaf drops its target.
    @State
    private var draggedPaneID: UUID?
    /// The live drop resolution shared by the per-leaf pane targets and the
    /// workspace-level tab target; the workspace overlay renders its preview.
    @State
    private var dropResolution: TabDropResolution?

    var body: some View {
        if let view = appState.viewTab(for: project.id, in: windowState) {
            workspace(view)
        }
    }

    @ViewBuilder
    private func workspace(_ view: AppState.WindowTabView) -> some View {
        let tab = view.tab
        let real = view.real
        // Position maps the real tab's focus and zoom onto the view (an
        // identity for the real view); callbacks map view panes back.
        let focusedPaneID = real.focusedPaneID.flatMap { appState.viewPaneID(forReal: $0, in: view) }
        let zoomedPaneID = real.zoomedPaneID.flatMap { appState.viewPaneID(forReal: $0, in: view) }
        let renderedNode = renderedNode(of: tab, zoomedPaneID: zoomedPaneID)
        SplitTreeView(
            node: renderedNode,
            focusedPaneID: focusedPaneID,
            zoomedPaneID: zoomedPaneID,
            isActiveProject: true,
            projectID: project.id,
            nonLeaderPaneIDs: appState.nonLeaderPaneIDs(in: tab),
            onFocusPane: { paneID in focus(paneID, in: view) },
            onSplit: { paneID, dir in split(paneID, direction: dir, in: view) },
            // This closure is the PROCESS-EXIT path only (SplitTreeView
            // wires it to the surface's onProcessExit; the user's Cmd+W
            // goes through Responders → requestClosePane directly).
            // handleProcessExit classifies a remote pane's exit
            // (drop → keep for the reconnect sweep, #281) and routes a
            // real end through paneProcessExited, where a pinned tab's
            // last pane unloads the tab instead of closing it (#285).
            //
            // A mirror's exit is NOT routed: its client dying alone is a
            // detach, and when the session itself ends the real pane's
            // own exit closes the tab, taking this view with it.
            onClosePane: { paneID in
                if !view.isMirror { appState.handleProcessExit(paneID, projectID: project.id) }
            },
            onCommandFinished: { paneID in acknowledge(paneID, in: view) },
            onAdaptiveBackgroundChange: { paneID, color in adopt(color, paneID: paneID, in: view) },
            onToggleZoom: { paneID in toggleZoom(paneID, in: view) },
            paneDrop: dropContext(for: view, renderedNode: renderedNode)
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
            if zoomedPaneID != nil {
                ZoomIndicator(onExit: { appState.toggleZoom(projectID: project.id) })
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }

    private func renderedNode(of tab: TerminalTab, zoomedPaneID: UUID?) -> SplitNode {
        if let zoomedPaneID, let pane = tab.splitRoot.findPane(id: zoomedPaneID) {
            return .pane(pane)
        }
        return tab.splitRoot
    }

    private func focus(_ paneID: UUID, in view: AppState.WindowTabView) {
        if view.isMirror {
            appState.focusMirroredPane(paneID, in: view)
        } else {
            appState.focusPane(paneID, projectID: project.id)
        }
    }

    private func split(_ paneID: UUID, direction: SplitDirection, in view: AppState.WindowTabView) {
        guard let realID = appState.realPaneID(for: paneID, in: view) else { return }
        appState.splitPane(realID, direction: direction, projectID: project.id, projectDirectory: project.path)
    }

    private func acknowledge(_ paneID: UUID, in view: AppState.WindowTabView) {
        guard let realID = appState.realPaneID(for: paneID, in: view) else { return }
        appState.acknowledgeFinishedCommandIfActive(paneID: realID, projectID: project.id)
    }

    private func adopt(_ color: CGColor?, paneID: UUID, in view: AppState.WindowTabView) {
        if view.isMirror {
            appState.setAdaptiveBackgroundColor(color, paneID: paneID, in: view.tab)
        } else {
            appState.setAdaptiveBackgroundColor(color, paneID: paneID, projectID: project.id)
        }
    }

    private func toggleZoom(_ paneID: UUID, in view: AppState.WindowTabView) {
        guard let realID = appState.realPaneID(for: paneID, in: view) else { return }
        view.real.toggleZoom(paneID: realID)
    }

    /// Rearranging happens on the real tab; a mirror view follows its shape
    /// but accepts no drops of its own.
    private func dropContext(for view: AppState.WindowTabView, renderedNode: SplitNode) -> PaneDropContext {
        let tab = view.tab
        var context = PaneDropContext(
            root: renderedNode,
            resolution: $dropResolution,
            draggedPaneID: draggedPaneID,
            renderedTabID: view.real.id,
            onMovePane: { paneID, target in
                guard !view.isMirror else { return }
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
        if view.isMirror { context.onMergeTab = nil }
        return context
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
    @Binding
    var windowCornerRadius: CGFloat?
    @Binding
    var windowTopSafeAreaInset: CGFloat
    @Binding
    var initialSidebarVisible: Bool?
    /// Called once this view's `NSWindow` exists, and again when it goes away.
    /// The window is how a `MainWindow` identifies itself to the app: the
    /// responder chain needs an exact "is the key window one of ours" answer
    /// (#345), and the key window is what points `AppState.activeProjectID` at
    /// the right window's project.
    var onWindowAttached: (NSWindow) -> Void = { _ in }
    var onWindowBecameKey: (NSWindow) -> Void = { _ in }
    /// Whether the red close button should hide the window rather than close
    /// it — the app's one close policy (`AppDelegate.hidesInsteadOfClosing`).
    var shouldHideOnClose: (NSWindow) -> Bool = { _ in true }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            windowCornerRadius: $windowCornerRadius,
            windowTopSafeAreaInset: $windowTopSafeAreaInset,
            initialSidebarVisible: $initialSidebarVisible
        )
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
            coordinator.syncWindowCornerRadius(window: window)
            coordinator.syncWindowTopSafeAreaInset(window: window)
            coordinator.syncInitialSidebarVisibility(window: window)
            coordinator.observe(window: window)
            coordinator.onWindowBecameKey = onWindowBecameKey
            coordinator.shouldHideOnClose = shouldHideOnClose
            onWindowAttached(window)
            // A window that opens already key never posts didBecomeKey, so
            // seed the app's notion of the frontmost project from it.
            if window.isKeyWindow { onWindowBecameKey(window) }
            // Intercept the close button to hide instead of close,
            // preserving terminal surfaces and running processes.
            coordinator.interceptClose(window: window)
        }
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Follow live setting flips. Async because SwiftUI forbids window
        // mutation from inside the update pass.
        let hide = hideTitle
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = hide ? .hidden : .visible
            WindowAppearance.syncTitleBarHidden(window: window)
            context.coordinator.syncWindowCornerRadius(window: window)
            context.coordinator.syncWindowTopSafeAreaInset(window: window)
            context.coordinator.syncInitialSidebarVisibility(window: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        nonisolated(unsafe) private var observer: Any?
        private var contentLayoutObservation: NSKeyValueObservation?
        nonisolated(unsafe) weak var swiftuiDelegate: (any NSWindowDelegate)?
        private var windowCornerRadius: Binding<CGFloat?>
        private var windowTopSafeAreaInset: Binding<CGFloat>
        private var initialSidebarVisible: Binding<Bool?>
        private var didSyncInitialSidebarVisibility = false

        init(
            windowCornerRadius: Binding<CGFloat?>,
            windowTopSafeAreaInset: Binding<CGFloat>,
            initialSidebarVisible: Binding<Bool?>
        ) {
            self.windowCornerRadius = windowCornerRadius
            self.windowTopSafeAreaInset = windowTopSafeAreaInset
            self.initialSidebarVisible = initialSidebarVisible
        }

        @MainActor
        func syncWindowCornerRadius(window: NSWindow) {
            windowCornerRadius.wrappedValue = WindowAppearance.windowCornerRadius(window)
        }

        @MainActor
        func syncWindowTopSafeAreaInset(window: NSWindow) {
            guard let contentView = window.contentView else { return }
            let contentFrame = contentView.convert(contentView.bounds, to: nil)
            windowTopSafeAreaInset.wrappedValue = SidebarOverlayMetrics.topObscuredInset(
                contentFrameInWindow: contentFrame,
                contentLayoutRect: window.contentLayoutRect
            )
        }

        @MainActor
        func syncInitialSidebarVisibility(window: NSWindow) {
            guard !didSyncInitialSidebarVisibility,
                  let visible = WindowAppearance.sidebarIsVisible(window: window)
            else { return }
            didSyncInitialSidebarVisibility = true
            initialSidebarVisible.wrappedValue = visible
        }

        @MainActor
        func observe(window: NSWindow) {
            contentLayoutObservation = window.observe(\.contentLayoutRect, options: [.initial, .new]) {
                [weak self] window, _ in
                MainActor.assumeIsolated { self?.syncWindowTopSafeAreaInset(window: window) }
            }
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

        var onWindowBecameKey: (NSWindow) -> Void = { _ in }
        var shouldHideOnClose: (NSWindow) -> Bool = { _ in true }

        func windowDidBecomeKey(_ notification: Notification) {
            if let window = notification.object as? NSWindow { onWindowBecameKey(window) }
            swiftuiDelegate?.windowDidBecomeKey?(notification)
        }

        func windowDidBecomeMain(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            onWindowBecameKey(window)
            WindowAppearance.sync(window: window)
            syncWindowCornerRadius(window: window)
            syncWindowTopSafeAreaInset(window: window)
            syncInitialSidebarVisibility(window: window)
            swiftuiDelegate?.windowDidBecomeMain?(notification)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            syncWindowCornerRadius(window: window)
            syncWindowTopSafeAreaInset(window: window)
            swiftuiDelegate?.windowDidEnterFullScreen?(notification)
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            syncWindowCornerRadius(window: window)
            syncWindowTopSafeAreaInset(window: window)
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
            // Only the LAST visible terminal window hides (#345); any other
            // really closes, exactly as ⌘⇧W does. Hiding a second window made
            // it a zombie — see `AppDelegate.hidesInsteadOfClosing`.
            guard shouldHideOnClose(sender) else { return true }
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
