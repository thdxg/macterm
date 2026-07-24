import Foundation

extension Notification.Name {
    static let toggleQuickTerminal = Notification.Name("MactermToggleQuickTerminal")
    static let mactermConfigDidChange = Notification.Name("MactermConfigDidChange")
    static let toggleSidebar = Notification.Name("MactermToggleSidebar")
    static let autoTilingEnabledDidChange = Notification.Name("MactermAutoTilingEnabledDidChange")
    /// Something happened that should wake or speed up the foreground-process
    /// poll: tab switch, OSC title, user interaction, execution-state
    /// transition. Observed by `AppState.notePollEvent()`.
    static let terminalPollEvent = Notification.Name("MactermTerminalPollEvent")
    /// A final IO heartbeat's quiet deadline. Unlike ordinary poll events,
    /// this must force one poll even when coalescing and window occlusion would
    /// otherwise leave the timer paused.
    static let terminalQuietSettleDeadline = Notification.Name("MactermTerminalQuietSettleDeadline")
    /// A zmx session was created, killed, or reattached — the
    /// `ZmxForegroundResolver` name→leader-pid cache is stale. Observed by
    /// `AppState`, which invalidates its `ZmxRefreshGate` and wakes the poll.
    static let zmxSessionsChanged = Notification.Name("MactermZmxSessionsChanged")
}
