import AppKit
import IOSurface

/// Samples every visible pane in the active terminal window and publishes its
/// temporary terminal-app background. A single pane may tint the whole window;
/// split panes are always isolated to their own bounds. Sampling follows render
/// activity plus a low-frequency monitor for static TUIs and costs nothing
/// until the user enables the feature.
@MainActor
final class AdaptiveTerminalChrome {
    static let shared = AdaptiveTerminalChrome()

    private var stabilizers: [ObjectIdentifier: AdaptiveTerminalBackgroundStabilizer] = [:]
    private var sampleTimer: Timer?
    private var monitorTimer: Timer?
    private var verificationTimer: Timer?

    private init() {}

    func preferenceDidEnable() {
        startMonitoring()
        scheduleSample(delay: 0)
    }

    /// Property observers do not run while `Preferences` initializes, so a
    /// persisted enabled value needs one explicit lifecycle handoff after the
    /// main window exists.
    func mainWindowDidAppear() {
        guard Preferences.shared.adaptiveTerminalChromeEnabled else { return }
        preferenceDidEnable()
    }

    func preferenceDidDisable() {
        cancelTimers()
        stabilizers.removeAll()
        for view in GhosttyTerminalNSView.allLiveViews() {
            clearPresentation(of: view)
        }
        GhosttyApp.shared.adoptAdaptiveBackgroundColor(nil)
    }

    func focusDidChange(to view: GhosttyTerminalNSView) {
        guard shouldHandleEvent(from: view) else { return }
        startMonitoring()
        scheduleSample(delay: 0)
    }

    func terminalDidRender(_ view: GhosttyTerminalNSView) {
        guard shouldHandleEvent(from: view) else { return }
        startMonitoring()
        scheduleSample(delay: 0.12)
    }

    /// OSC 11 is explicit terminal-native evidence and takes effect
    /// immediately; inferred IOSurface colors retain two-observation
    /// stabilization.
    func terminalBackgroundDidChange(_ color: NSColor, in view: GhosttyTerminalNSView) {
        guard shouldHandleEvent(from: view) else { return }
        let candidate = effectiveCandidate(color)
        var stabilizer = stabilizers[ObjectIdentifier(view)] ?? AdaptiveTerminalBackgroundStabilizer()
        stabilizer.reset(to: candidate)
        stabilizers[ObjectIdentifier(view)] = stabilizer
        refreshPresentation(for: monitoredViews())
    }

    func terminalBackgroundDidReset(in view: GhosttyTerminalNSView) {
        guard shouldHandleEvent(from: view) else { return }
        stabilizers[ObjectIdentifier(view)] = AdaptiveTerminalBackgroundStabilizer()
        view.sampledDominantBackgroundColor = nil
        scheduleSample(delay: 0)
    }

    private func scheduleSample(delay: TimeInterval) {
        guard sampleTimer == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleTimer = nil
                self?.sampleVisiblePanes()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func startMonitoring() {
        guard monitorTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleVisiblePanes()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    private func sampleVisiblePanes() {
        guard Preferences.shared.adaptiveTerminalChromeEnabled else { return }
        let views = monitoredViews()
        pruneState(keeping: views)
        guard !views.isEmpty else {
            verificationTimer?.invalidate()
            verificationTimer = nil
            GhosttyApp.shared.adoptAdaptiveBackgroundColor(nil)
            return
        }

        let needsVerification = views.map(sample).contains(true)
        refreshPresentation(for: views)
        if needsVerification {
            scheduleVerification()
        } else {
            verificationTimer?.invalidate()
            verificationTimer = nil
        }
    }

    /// Returns true when this pane has a first, unconfirmed inferred
    /// observation and needs the short verification sample.
    private func sample(_ view: GhosttyTerminalNSView) -> Bool {
        let id = ObjectIdentifier(view)
        var stabilizer = stabilizers[id] ?? AdaptiveTerminalBackgroundStabilizer()

        if let reported = effectiveCandidate(view.reportedBackgroundColor) {
            stabilizer.reset(to: reported)
            stabilizers[id] = stabilizer
            return false
        }

        let candidate: NSColor? = if let surface = view.layer?.contents as? IOSurface {
            effectiveCandidate(AdaptiveTerminalBackgroundDetector.dominantColor(in: surface)?.color)
        } else {
            nil
        }

        let change = stabilizer.observe(candidate)
        stabilizers[id] = stabilizer
        switch change {
        case .applyColor:
            view.sampledDominantBackgroundColor = candidate
        case .clear:
            view.sampledDominantBackgroundColor = nil
        case nil:
            break
        }
        return stabilizer.hasPendingObservation
    }

    private func refreshPresentation(for views: [GhosttyTerminalNSView]) {
        let candidates = views.map(currentCandidate)
        let paneColors = AdaptiveTerminalBackgroundPresentation.paneColors(for: candidates)
        for (view, color) in zip(views, paneColors) {
            view.presentAdaptivePaneBackground(color)
        }
        GhosttyApp.shared.adoptAdaptiveBackgroundColor(
            AdaptiveTerminalBackgroundPresentation.windowColor(for: candidates)
        )
    }

    private func currentCandidate(for view: GhosttyTerminalNSView) -> NSColor? {
        effectiveCandidate(view.reportedBackgroundColor)
            ?? effectiveCandidate(view.sampledDominantBackgroundColor)
    }

    private func scheduleVerification() {
        guard verificationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.verificationTimer = nil
                self?.sampleVisiblePanes()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        verificationTimer = timer
    }

    private func monitoredViews() -> [GhosttyTerminalNSView] {
        let eligible = GhosttyTerminalNSView.allLiveViews().filter(isVisible)
        guard let window = preferredWindow(from: eligible) else { return [] }
        return eligible.filter { $0.window === window }
    }

    private func preferredWindow(from views: [GhosttyTerminalNSView]) -> NSWindow? {
        if let key = NSApp.keyWindow, views.contains(where: { $0.window === key }) {
            return key
        }
        if let main = NSApp.mainWindow, views.contains(where: { $0.window === main }) {
            return main
        }
        return views.first(where: { !($0.window is NSPanel) })?.window ?? views.first?.window
    }

    private func shouldHandleEvent(from view: GhosttyTerminalNSView) -> Bool {
        guard Preferences.shared.adaptiveTerminalChromeEnabled, isVisible(view) else { return false }
        return monitoredViews().contains { $0 === view }
    }

    private func isVisible(_ view: GhosttyTerminalNSView) -> Bool {
        guard let window = view.window,
              window.occlusionState.contains(.visible),
              !view.isHiddenOrHasHiddenAncestor,
              view.bounds.width > 0,
              view.bounds.height > 0
        else { return false }
        return true
    }

    private func effectiveCandidate(_ color: NSColor?) -> NSColor? {
        guard let color else { return nil }
        return color.distance(to: GhosttyApp.shared.backgroundColor) >= 0.04 ? color : nil
    }

    private func pruneState(keeping views: [GhosttyTerminalNSView]) {
        let active = Set(views.map(ObjectIdentifier.init))
        stabilizers = stabilizers.filter { active.contains($0.key) }
        for view in GhosttyTerminalNSView.allLiveViews() where !active.contains(ObjectIdentifier(view)) {
            clearPresentation(of: view)
        }
    }

    private func clearPresentation(of view: GhosttyTerminalNSView) {
        view.sampledDominantBackgroundColor = nil
        view.presentAdaptivePaneBackground(nil)
    }

    private func cancelTimers() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        monitorTimer?.invalidate()
        monitorTimer = nil
        verificationTimer?.invalidate()
        verificationTimer = nil
    }
}
