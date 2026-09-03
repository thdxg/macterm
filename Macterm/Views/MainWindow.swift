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
        appState.sidebarVisible || activePeekStyle == .resizeTerminal
    }

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
            if isOverlayPeeking, !appState.sidebarVisible {
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
            initialSidebarVisible: $initialNativeSidebarVisible
        ))
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
        .onDisappear {
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
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            handleSidebarPeekHover(phase)
        }
        .onChange(of: initialNativeSidebarVisible) { _, visible in
            guard let visible else { return }
            let resolution = SidebarPeekInteraction.launchResolution(
                nativeVisible: visible,
                modelVisible: appState.sidebarVisible
            )
            columnVisibility = resolution.columnVisible ? .automatic : .detailOnly
            if let modelVisible = resolution.modelVisible {
                initialSidebarVisibilityBeingApplied = modelVisible
                appState.sidebarVisible = modelVisible
            } else {
                initialSidebarVisibilityBeingApplied = nil
            }
        }
        .onChange(of: appState.sidebarVisible) { _, visible in
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
                        appState.sidebarVisible = true
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
                    appState.sidebarVisible = true
                }
                return
            }
            let visible = visibility != .detailOnly
            if appState.sidebarVisible != visible {
                appState.sidebarVisible = visible
            }
        }
        .onChange(of: preferences.sidebarPeekStyle) { oldStyle, newStyle in
            guard oldStyle != newStyle else { return }
            cancelDeferredPeek()
            cancelOverlayWindowExit()
            if !appState.sidebarVisible { cancelSidebarWidthHandoff() }
            guard isPeeking, !appState.sidebarVisible else { return }
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
        let rounded = (Double(width) * 2).rounded() / 2
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
            guard appState.sidebarVisible || activePeekStyle == .resizeTerminal,
                  let window = (NSApp.delegate as? AppDelegate)?.mainWindow,
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
            guard !appState.sidebarVisible else { return }
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
                && !appState.sidebarVisible
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
                guard !isPeeking, !appState.sidebarVisible,
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
                guard let window = (NSApp.delegate as? AppDelegate)?.mainWindow,
                      window.isKeyWindow, window.attachedSheet == nil,
                      !appState.isCommandPaletteVisible
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
                guard isOverlayPeeking, !appState.sidebarVisible, !isResizingOverlay,
                      let window = (NSApp.delegate as? AppDelegate)?.mainWindow
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
        guard let window = (NSApp.delegate as? AppDelegate)?.mainWindow else { return false }
        return NSEvent.mouseLocation.x <= window.frame.minX + 2
    }

    private var pointerIsWithinOverlayRetentionRegion: Bool {
        guard let window = (NSApp.delegate as? AppDelegate)?.mainWindow else { return false }
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
        guard let pid = appState.activeProjectID else { return nil }
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
                    appState.splitPane(
                        paneID,
                        direction: dir,
                        projectID: project.id,
                        projectDirectory: project.path
                    )
                },
                // This closure is the PROCESS-EXIT path only (SplitTreeView
                // wires it to the surface's onProcessExit; the user's Cmd+W
                // goes through Responders → requestClosePane directly).
                // handleProcessExit classifies a remote pane's exit
                // (drop → keep for the reconnect sweep, #281) and routes a
                // real end through paneProcessExited, where a pinned tab's
                // last pane unloads the tab instead of closing it (#285).
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
    @Binding
    var windowCornerRadius: CGFloat?
    @Binding
    var windowTopSafeAreaInset: CGFloat
    @Binding
    var initialSidebarVisible: Bool?

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

        func windowDidBecomeMain(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            syncWindowCornerRadius(window: window)
            syncWindowTopSafeAreaInset(window: window)
            syncInitialSidebarVisibility(window: window)
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
