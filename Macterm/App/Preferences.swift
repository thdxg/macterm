import AppKit
import Foundation
import Observation

/// When the numbered tab switcher in the title bar is shown.
enum TabSwitcherVisibility: String, CaseIterable, Identifiable {
    case always
    case whenMultiple = "when_multiple"
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: "Always"
        case .whenMultiple: "When multiple tabs"
        case .hidden: "Hidden"
        }
    }
}

/// Which edge of the title bar the numbered tab switcher sits on (#186).
/// `leading` maps to the `.navigation` toolbar slot, which AppKit places
/// ahead of the inline window title — the switcher hugs the sidebar edge
/// and the title shifts right of it.
/// Which Sparkle appcast channel the updater draws from.
///
/// `stable` maps to Sparkle's default channel (items with no
/// `<sparkle:channel>`); `beta` and `tip` additionally allow items tagged with
/// the matching `<sparkle:channel>`. The raw values are persisted, so renaming a
/// case is a stored-preference migration — and every non-stable case's raw value
/// IS the channel name sent to Sparkle (see `betaUpdateChannel` /
/// `tipUpdateChannel`), so it is a wire-format migration too.
///
/// Sparkle always admits the default channel on top of whatever
/// `allowedChannels` returns, so a beta or tip follower still sees stable items.
/// That is harmless because the comparison versions can't collide: a beta sorts
/// below the stable release of the same `X.Y.Z` and a tip sorts above it (see
/// `sparkle_comparison_version` in scripts/_lib.sh).
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta
    /// Every commit on main that passes CI, built and published by
    /// `.github/workflows/release-tip.yml`. Not release-tested.
    case tip

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        case .tip: "Tip"
        }
    }

    /// The channel this BUILD was cut for, baked into `Info.plist` as
    /// `MactermUpdateChannel` by `scripts/build.sh`. Used as the default when
    /// the user has never chosen a channel.
    ///
    /// This exists for tip specifically. A tip DMG downloaded by hand from the
    /// rolling `tip` release would otherwise sit on `stable`, and because a tip
    /// version outranks every stable release of the same base, Sparkle would
    /// report "You're up to date" forever — a silent dead end. A beta needs no
    /// such treatment (it sorts *below* its stable, so the stable release still
    /// reaches it), which is why `macterm_update_channel` in scripts/_lib.sh
    /// only ever stamps `tip` or `stable`.
    static var bundleDefault: UpdateChannel {
        (Bundle.main.object(forInfoDictionaryKey: "MactermUpdateChannel") as? String)
            .flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }
}

/// How large the leading glyph on a sidebar project/tab row draws, relative to
/// the row's text. `medium` is the system default: the SF Symbols take
/// whatever size the row's ambient font gives them, exactly as they did before
/// this preference existed, so it is the one case that applies no sizing at
/// all. The raw values are persisted.
enum SidebarIconSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Multiplier for the sidebar glyphs sized by hand rather than by SwiftUI's
    /// `imageScale` — the agent logo's frame, the plain-digit number glyph, the
    /// running spinner, the completion dot. Taken from AppKit rather than
    /// guessed so those glyphs track the SF Symbols beside them instead of
    /// drifting: `NSImage.SymbolConfiguration` renders a 13pt symbol 12/14/18pt
    /// tall at small/medium/large.
    var glyphScale: CGFloat {
        switch self {
        case .small: 12.0 / 14.0
        case .medium: 1
        case .large: 18.0 / 14.0
        }
    }
}

/// Whether a quick-terminal geometry axis (position or size) comes from the
/// Settings sliders (`fixed`) or is remembered from the user's own
/// manipulation of the panel — dragging the grab handle, resizing from the
/// edges (`dynamic`). The raw values are persisted.
enum QuickTerminalAdjustMode: String, CaseIterable, Identifiable {
    case fixed
    case dynamic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fixed: "Fixed"
        case .dynamic: "Dynamic"
        }
    }
}

enum TabSwitcherPosition: String, CaseIterable, Identifiable {
    case leading
    case trailing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leading: "Left"
        case .trailing: "Right"
        }
    }
}

/// Which `NSGlassEffectView.Style` the liquid-glass window background uses.
/// Maps to AppKit's `.regular` / `.clear` (see `WindowAppearance`).
enum WindowGlassStyle: String, CaseIterable, Identifiable {
    case regular
    case clear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .clear: "Clear"
        }
    }
}

/// How a hidden sidebar appears while the pointer rests at the window's
/// leading edge. The normal pinned sidebar always remains a native split-view
/// column; this only controls the temporary hover peek.
enum SidebarPeekStyle: String, CaseIterable, Identifiable {
    case resizeTerminal = "resize_content"
    case overlayTerminal = "overlay_on_hover"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .resizeTerminal: "Resize terminal"
        case .overlayTerminal: "Overlay terminal"
        }
    }

    var explanation: String {
        switch self {
        case .resizeTerminal:
            "Slides the native sidebar column out and temporarily resizes the terminal."
        case .overlayTerminal:
            "Shows a floating sidebar over the terminal without changing its size."
        }
    }
}

/// Single observable source of truth for UserDefaults-backed preferences.
///
/// Macterm only stores app-shaped state here (window opacity/blur, quick
/// terminal, hotkeys, etc.). Anything that's a ghostty config setting lives
/// in the user's Ghostty config instead — see `MactermConfig` for the wrapper
/// files Macterm generates around it.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences(defaults: defaults)

    /// The UserDefaults domain all Macterm state persists to — `.standard` in
    /// the app, a wiped side suite under test (see `resolveDefaults()`). Use
    /// this instead of `UserDefaults.standard` anywhere the app reads or
    /// writes defaults directly (project recency, hotkey overrides), so those
    /// writes get the same test isolation as `Preferences` properties.
    /// `nonisolated(unsafe)` because the SDK doesn't mark `UserDefaults`
    /// Sendable even though it's documented thread-safe.
    nonisolated(unsafe) static let defaults: UserDefaults = resolveDefaults()

    // MARK: - Layout / appearance

    var autoTilingEnabled: Bool {
        didSet {
            defaults.set(autoTilingEnabled, forKey: Keys.autoTiling)
            // Legacy notification — listeners predate Preferences.
            NotificationCenter.default.post(name: .autoTilingEnabledDidChange, object: nil)
        }
    }

    /// Multiplier applied to terminal scroll wheel / trackpad row deltas.
    var terminalScrollSpeed: Double {
        didSet { defaults.set(terminalScrollSpeed, forKey: Keys.terminalScrollSpeed) }
    }

    /// Presentation used by `peekSidebarWhenHidden`. The pinned sidebar is
    /// always the native split-view column.
    var sidebarPeekStyle: SidebarPeekStyle {
        didSet { defaults.set(sidebarPeekStyle.rawValue, forKey: Keys.sidebarPeekStyle) }
    }

    // MARK: - Sidebar icons

    var projectIconSymbol: String {
        didSet { defaults.set(projectIconSymbol, forKey: Keys.projectIconSymbol) }
    }

    var tabIconSymbol: String {
        didSet { defaults.set(tabIconSymbol, forKey: Keys.tabIconSymbol) }
    }

    /// How large the leading glyph on project and tab rows draws.
    var sidebarIconSize: SidebarIconSize {
        didSet { defaults.set(sidebarIconSize.rawValue, forKey: Keys.sidebarIconSize) }
    }

    /// Replace a tab's icon with the running AI agent's logo (Claude Code,
    /// Codex, …) while one holds the pane's foreground. On by default.
    var showAgentIcons: Bool {
        didSet { defaults.set(showAgentIcons, forKey: Keys.showAgentIcons) }
    }

    /// Show a status badge over each tab icon: a spinner while a command is
    /// running (replacing the icon) and a small status dot when a command has
    /// finished and awaits attention. Off = pure icons, no status tracking.
    var showTabStatusIndicator: Bool {
        didSet { defaults.set(showTabStatusIndicator, forKey: Keys.showTabStatusIndicator) }
    }

    /// Whether the running spinner also replaces an AI agent's logo (#225).
    /// Off keeps the agent logo while the agent works — agent CLIs draw their
    /// own busy indicator in the tab title, so the spinner is redundant there —
    /// while the done dot still appears (it overlays the logo rather than
    /// replacing it). Meaningful only while `showTabStatusIndicator` and
    /// `showAgentIcons` are both on.
    var showSpinnerOverAgentIcons: Bool {
        didSet { defaults.set(showSpinnerOverAgentIcons, forKey: Keys.showSpinnerOverAgentIcons) }
    }

    /// Auto-name tabs after the live foreground process / OSC title (on by
    /// default). Off = tabs hold their static fallback (login shell name, or
    /// the host name for remote panes); a user-set custom title always wins
    /// either way. Display-only: the polling and probing keep running for
    /// busy-close verdicts and execution tracking (`Pane.displayTitle` is
    /// the single gate).
    var autoNameTabs: Bool {
        didSet { defaults.set(autoNameTabs, forKey: Keys.autoNameTabs) }
    }

    var showNewProjectButton: Bool {
        didSet { defaults.set(showNewProjectButton, forKey: Keys.showNewProjectButton) }
    }

    /// Allow non-interactive background ssh connections to remote-project
    /// hosts: the foreground probe (live tab names, busy-close verdicts,
    /// layout `run:` capture) and the opt-in terminfo install. On by default.
    /// Off exists for keys gated behind a per-connection biometric dialog
    /// (#272): every background connection raises a Touch ID prompt BatchMode
    /// can't suppress, so off narrows Macterm's ssh traffic to the panes' own
    /// connections plus the one-shot `zmx kill` of an explicit close. Remote
    /// tabs then fall back to the host name / OSC titles, and closing warns
    /// only on a positively-known running command (OSC 133 execution state) —
    /// never from the conservative ssh-is-always-busy fallback.
    var backgroundSSHConnections: Bool {
        didSet { defaults.set(backgroundSSHConnections, forKey: Keys.backgroundSSHConnections) }
    }

    /// Reconnect a remote pane whose ssh connection died (#281): respawn the
    /// surface so it redials and reattaches the SAME zmx session (which
    /// replays scrollback), instead of leaving the pane on ghostty's
    /// abnormal-exit overlay until the app is relaunched. Trigger-driven —
    /// system wake, app activation, project selection — never a timer, so an
    /// unreachable host is retried a bounded number of times per return, not
    /// polled. Off exists for the same reason as `backgroundSSHConnections`:
    /// a Touch ID-gated key (#272) would raise one prompt per dead pane on
    /// every wake.
    var reconnectRemotePanes: Bool {
        didSet { defaults.set(reconnectRemotePanes, forKey: Keys.reconnectRemotePanes) }
    }

    /// Stable per-installation identity, lazily created on first use. Stamped
    /// onto remote zmx sessions as a `macterm.owner` label so the orphan sweep
    /// can tell OUR sessions apart from another machine's on a shared host
    /// (#281) — never the hostname, which two Macs can share and the user can
    /// rename. UUID hex without dashes, because zmx label values allow only
    /// `[A-Za-z0-9._-]`. Not `@Observable` state (no UI reads it), so it's a
    /// computed lazy read-through rather than a stored property.
    var installationID: String {
        if let existing = defaults.string(forKey: Keys.installationID), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(fresh, forKey: Keys.installationID)
        return fresh
    }

    /// Slide the hidden sidebar out while the pointer sits at the window's
    /// leading edge, and back in when it leaves (`MainWindow`'s hover peek).
    var peekSidebarWhenHidden: Bool {
        didSet { defaults.set(peekSidebarWhenHidden, forKey: Keys.peekSidebarWhenHidden) }
    }

    /// Last width the user dragged the sidebar to, seeded into the column's
    /// `ideal` at launch. We persist it ourselves because SwiftUI's own
    /// autosave never survives a relaunch — see `MainWindow.sidebarWidth`.
    var sidebarWidth: Double {
        didSet { defaults.set(sidebarWidth, forKey: Keys.sidebarWidth) }
    }

    /// `sidebarWidth` as it stood at launch, frozen. What the restore must
    /// read: the column lays out (and `MainWindow`'s geometry callback writes
    /// its content-derived width over the stored one) *before* the window is
    /// styled, so by restore time the live property already says 144.
    private(set) var launchSidebarWidth: Double = defaultSidebarWidth

    /// Bounds of the sidebar column, shared by the persisted width's clamp and
    /// `MainWindow`'s `navigationSplitViewColumnWidth` so a stored value can
    /// never fall outside what the column accepts.
    static let sidebarWidthRange: ClosedRange<Double> = 140 ... 400
    static let defaultSidebarWidth: Double = 180

    /// Which appcast channel auto-updates come from. Read by `Updater`'s
    /// `allowedChannels(for:)`, so `.beta`/`.tip` make the matching prerelease
    /// items visible to both the scheduled check and "Check for Updates…".
    ///
    /// Defaults to `UpdateChannel.bundleDefault`, which is `.stable` for every
    /// build except a tip one — so a fresh install of a stable or beta DMG never
    /// sees anything but stable, while a hand-installed tip DMG follows tip
    /// instead of dead-ending (see `bundleDefault`).
    ///
    /// Sparkle reads `allowedChannels` fresh on every check, so changing this
    /// takes effect on the next check with no restart.
    var updateChannel: UpdateChannel {
        didSet { defaults.set(updateChannel.rawValue, forKey: Keys.updateChannel) }
    }

    // MARK: - Hotkeys

    /// Bumped by `HotkeyRegistry.setShortcutString` on every rebind. Hotkey
    /// bindings live in raw UserDefaults keys (`macterm.hotkey.<action_id>`),
    /// not in a `Preferences` property, so SwiftUI has nothing to observe when
    /// one changes. Ordinary views that render a binding (the shortcut hints in
    /// `WelcomeView`/`EmptyProjectView`) read this to register a dependency and
    /// refresh on rebind.
    ///
    /// This does *not* reach the menu bar: a SwiftUI `.commands` tree is built
    /// once and never re-evaluated from observable state, so no amount of
    /// invalidation updates a `.keyboardShortcut`. `HotkeyMenuSync` patches the
    /// live `NSMenuItem`s for that.
    private(set) var hotkeyVersion = 0

    /// Not persisted — the version only orders rebuilds within a launch.
    func bumpHotkeyVersion() {
        hotkeyVersion &+= 1
    }

    // MARK: - Toolbar

    var tabSwitcherVisibility: TabSwitcherVisibility {
        didSet { defaults.set(tabSwitcherVisibility.rawValue, forKey: Keys.tabSwitcherVisibility) }
    }

    var tabSwitcherPosition: TabSwitcherPosition {
        didSet { defaults.set(tabSwitcherPosition.rawValue, forKey: Keys.tabSwitcherPosition) }
    }

    /// Sentinel for "no icon" — sidebar rows skip the leading glyph when set.
    static let noIcon = "none"
    /// Sentinels for "show 1-based top-down position" — sidebar rows render a number glyph.
    /// Each variant picks a different SF Symbols container (or plain text) around the digit.
    static let numberIconCircleFill = "number.circle.fill"
    static let numberIconCircle = "number.circle"
    static let numberIconSquareFill = "number.square.fill"
    static let numberIconSquare = "number.square"
    static let numberIconPlain = "number.plain"

    static let numberIconChoices: Set<String> = [
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
    ]

    /// Curated SF Symbols offered in Settings — keeps users from typing invalid names.
    static let projectIconChoices: [String] = [
        noIcon,
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
        "folder",
        "folder.fill",
        "briefcase",
        "shippingbox",
        "cube",
        "hammer",
    ]
    static let tabIconChoices: [String] = [
        noIcon,
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
        "terminal",
        "chevron.right",
        "chevron.compact.right",
        "circle.fill",
        "circle",
        "command",
    ]

    // MARK: - Window

    /// Macterm-painted window background opacity (0–1). Macterm composites
    /// this translucency at the window level while `macterm-overrides.conf`
    /// sets `background-default-transparent` so ghostty never paints the
    /// default background — avoiding the double-paint problem when both
    /// layers tint. The value is also written into the overrides as
    /// `background-opacity`, which ghostty applies to TUI-painted cell
    /// backgrounds when the user's own `background-opacity-cells` flag is
    /// on — hence the debounced config reload alongside the instant window
    /// resync.
    var windowOpacity: Double {
        didSet {
            defaults.set(windowOpacity, forKey: Keys.windowOpacity)
            notifyWindowAppearanceChanged()
            scheduleGhosttyConfigReload()
        }
    }

    /// CGSSetWindowBackgroundBlurRadius value (0–100). 0 = no blur.
    var windowBlurRadius: Int {
        didSet {
            defaults.set(windowBlurRadius, forKey: Keys.windowBlurRadius)
            notifyWindowAppearanceChanged()
        }
    }

    /// Use the macOS 26 liquid-glass material (`NSGlassEffectView`) for the
    /// translucent window background instead of the legacy CGS Gaussian blur.
    /// Only has any effect when `windowOpacity < 1` — at full opacity the
    /// window is solid and neither blur nor glass is visible. When enabled the
    /// `windowBlurRadius` slider is ignored; the glass material defines its own
    /// look.
    var windowGlassEnabled: Bool {
        didSet {
            defaults.set(windowGlassEnabled, forKey: Keys.windowGlassEnabled)
            notifyWindowAppearanceChanged()
        }
    }

    /// Which liquid-glass material to use when `windowGlassEnabled` is on.
    /// `.regular` is frostier/more tinted; `.clear` is more transparent. No
    /// effect unless glass is enabled.
    var windowGlassStyle: WindowGlassStyle {
        didSet {
            defaults.set(windowGlassStyle.rawValue, forKey: Keys.windowGlassStyle)
            notifyWindowAppearanceChanged()
        }
    }

    /// Match an opaque color painted across most of a terminal surface. A lone
    /// pane may tint the window; split panes are adapted independently. Off by
    /// default: the user's Ghostty theme remains the source of truth unless
    /// they explicitly opt in.
    var adaptiveTerminalChromeEnabled: Bool {
        didSet {
            defaults.set(adaptiveTerminalChromeEnabled, forKey: Keys.adaptiveTerminalChromeEnabled)
            if adaptiveTerminalChromeEnabled {
                AdaptiveTerminalChrome.shared.preferenceDidEnable()
            } else {
                AdaptiveTerminalChrome.shared.preferenceDidDisable()
            }
            notifyWindowAppearanceChanged()
        }
    }

    /// Hide the window's title bar entirely: the toolbar (sidebar toggle, tab
    /// switcher, update button), the title text, and — a side effect of
    /// SwiftUI removing the window toolbar — the traffic lights. The sidebar
    /// and terminal surface extend to the window's top edge. Tab switching
    /// stays available via the sidebar and Cmd+digit; close/minimize/zoom stay
    /// available from the Window menu. No AppKit private API involved: the
    /// window keeps its normal style mask, so edge-resizing still works.
    var hideTitleBar: Bool {
        didSet {
            defaults.set(hideTitleBar, forKey: Keys.hideTitleBar)
        }
    }

    // MARK: - Ghostty config

    /// The selected source for the user's Ghostty config.
    private(set) var ghosttyConfigSelection: GhosttyConfigSelection

    func setGhosttyConfig(loadsDefaultFiles: Bool, customPaths: [String]) {
        ghosttyConfigSelection = GhosttyConfigSelection(
            loadsDefaultFiles: loadsDefaultFiles,
            customPaths: customPaths
        )
        defaults.set(loadsDefaultFiles, forKey: Keys.loadsDefaultGhosttyConfigFiles)
        defaults.set(customPaths, forKey: Keys.customGhosttyConfigPaths)
        defaults.removeObject(forKey: Keys.userGhosttyConfigPath)
    }

    /// Programs a passthrough-flagged keybind yields to, as the user typed them
    /// (`nvim, hx`). Stored raw so the Settings field round-trips their spacing
    /// verbatim; `KeybindPassthrough.programNames` does the parsing and is the
    /// only thing that should read this for matching.
    ///
    /// Empty by default: a name list is the user's to author, and until they
    /// name something a flagged keybind simply keeps firing its action.
    var passthroughPrograms: String {
        didSet {
            defaults.set(passthroughPrograms, forKey: Keys.passthroughPrograms)
        }
    }

    /// Window-level appearance + libghostty reload. Both happen on the same
    /// notification so the renderer and the window chrome stay in sync.
    private func notifyConfigChanged() {
        MactermConfig.shared.regenerate()
        GhosttyApp.shared.reloadConfig()
    }

    /// Notify observers that a WINDOW-APPEARANCE pref (opacity/blur/glass)
    /// changed, WITHOUT regenerating the ghostty config or reloading libghostty.
    /// `WindowAppearance.sync` reads these values straight from Preferences.
    /// Previously these setters ran the full `notifyConfigChanged()` (two file
    /// writes + a whole-config libghostty reload) purely to piggy-back on the
    /// `.mactermConfigDidChange` post it ends with — heavyweight, and fired
    /// continuously while dragging a slider.
    ///
    /// One value DOES also live in the regenerated overrides: `windowOpacity`
    /// is written as ghostty's `background-opacity` (so the user's
    /// `background-opacity-cells` makes painted cells translucent at the
    /// window opacity). That side is followed by `scheduleGhosttyConfigReload`
    /// below — debounced, so slider drags stay on this cheap path and the
    /// libghostty reload fires once after the value settles.
    private func notifyWindowAppearanceChanged() {
        NotificationCenter.default.post(name: .mactermConfigDidChange, object: nil)
    }

    /// The pending debounced reload for `windowOpacity`'s ghostty-side copy.
    @ObservationIgnored private var ghosttyOpacityReloadTask: Task<Void, Never>?

    /// Regenerate + reload the ghostty config shortly after the last call,
    /// so a slider drag costs one whole-config reload instead of dozens.
    private func scheduleGhosttyConfigReload() {
        ghosttyOpacityReloadTask?.cancel()
        ghosttyOpacityReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.notifyConfigChanged()
        }
    }

    // MARK: - Quick terminal

    /// Fraction of screen width (0–1).
    var quickTerminalWidthFraction: Double {
        didSet { defaults.set(quickTerminalWidthFraction, forKey: Keys.quickTerminalWidth) }
    }

    /// Fraction of screen height (0–1).
    var quickTerminalHeightFraction: Double {
        didSet { defaults.set(quickTerminalHeightFraction, forKey: Keys.quickTerminalHeight) }
    }

    /// How the panel's position is decided at show time: `fixed` anchors it
    /// with the X/Y sliders below; `dynamic` shows a grab handle and reopens
    /// the panel where the user last dragged it. Defaults to `fixed` with
    /// centered sliders — the classic quick-terminal contract.
    var quickTerminalPositionMode: QuickTerminalAdjustMode {
        didSet { defaults.set(quickTerminalPositionMode.rawValue, forKey: Keys.quickTerminalPositionMode) }
    }

    /// Fixed-position anchors, as the panel origin's place within the screen's
    /// spare room per axis (0…1). X: 0 = left, 1 = right. Y is in placement
    /// space — 0 = bottom, 1 = top; the Settings slider reads Top…Bottom and
    /// inverts. 0.5/0.5 = centered.
    var quickTerminalFixedX: Double {
        didSet { defaults.set(quickTerminalFixedX, forKey: Keys.quickTerminalFixedX) }
    }

    var quickTerminalFixedY: Double {
        didSet { defaults.set(quickTerminalFixedY, forKey: Keys.quickTerminalFixedY) }
    }

    /// How the panel's size is decided at show time: `fixed` uses the
    /// width/height sliders; `dynamic` makes the panel edge-resizable and
    /// reopens it at the size the user last resized it to.
    var quickTerminalSizeMode: QuickTerminalAdjustMode {
        didSet { defaults.set(quickTerminalSizeMode.rawValue, forKey: Keys.quickTerminalSizeMode) }
    }

    /// The panel size the user last resized to, as fractions of the screen's
    /// visible frame; `nil` = never resized, the size sliders' values apply.
    var quickTerminalDynamicSize: CGSize? {
        didSet {
            if let size = quickTerminalDynamicSize {
                defaults.set(Double(size.width), forKey: Keys.quickTerminalDynamicWidth)
                defaults.set(Double(size.height), forKey: Keys.quickTerminalDynamicHeight)
            } else {
                defaults.removeObject(forKey: Keys.quickTerminalDynamicWidth)
                defaults.removeObject(forKey: Keys.quickTerminalDynamicHeight)
            }
        }
    }

    /// Where the user last dragged the panel: each axis is the panel origin's
    /// place within the screen's spare room on that axis (0.5 = centered;
    /// beyond 0…1 = the user left the panel overhanging a screen edge, which
    /// the restore honors down to a grabbable minimum). Stored as fractions
    /// rather than points so the position stays sensible across screen and
    /// size changes; `nil` = never dragged, panel centers.
    var quickTerminalPosition: CGPoint? {
        didSet {
            if let position = quickTerminalPosition {
                defaults.set(Double(position.x), forKey: Keys.quickTerminalPositionX)
                defaults.set(Double(position.y), forKey: Keys.quickTerminalPositionY)
            } else {
                defaults.removeObject(forKey: Keys.quickTerminalPositionX)
                defaults.removeObject(forKey: Keys.quickTerminalPositionY)
            }
        }
    }

    // MARK: - Session

    /// Start every restored project's terminal surfaces at launch instead of
    /// waiting for each project to be selected. Off by default: eager restore
    /// can open many shells or remote SSH connections at once. Launch warming
    /// stays staggered, with same-host remote panes paced more conservatively.
    var restoreAllProjectsOnLaunch: Bool {
        didSet { defaults.set(restoreAllProjectsOnLaunch, forKey: Keys.restoreAllProjectsOnLaunch) }
    }

    /// Persisted so the app re-opens to the last-used project on launch.
    var activeProjectID: UUID? {
        didSet { defaults.set(activeProjectID?.uuidString, forKey: Keys.activeProjectID) }
    }

    // MARK: - Init

    /// The unit-test suite runs hosted inside the debug app, so
    /// `UserDefaults.standard` there is the developer's real
    /// `com.thdxg.macterm.debug` domain — a test mutating a preference (even
    /// indirectly, e.g. `AppState.activeProjectID`'s write-through) would
    /// corrupt the app they use day to day. Under a test run, back the app's
    /// defaults with a wiped side suite instead so writes never leave the run.
    nonisolated private static func resolveDefaults() -> UserDefaults {
        guard isTestRun else { return .standard }
        let suiteName = appBundleID + ".tests"
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        // Wipe residue from previous runs so every test run starts clean.
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    /// True when this process is an XCTest / Swift Testing host. Detected via
    /// the runner's environment (`XCTestConfigurationFilePath`,
    /// `XCTestSessionIdentifier`, … — the exact key varies by Xcode version)
    /// rather than a loaded-class check: the test bundle injects only after app
    /// launch, but the environment is set from process start, so this is
    /// correct however early `shared` is first touched.
    nonisolated static var isTestRun: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults) {
        self.defaults = defaults
        autoTilingEnabled = defaults.bool(forKey: Keys.autoTiling)
        terminalScrollSpeed = Self.clampScrollSpeed(defaults.double(forKey: Keys.terminalScrollSpeed), fallback: 1.0)
        sidebarPeekStyle = (defaults.string(forKey: Keys.sidebarPeekStyle))
            .flatMap(SidebarPeekStyle.init(rawValue:)) ?? .resizeTerminal
        windowOpacity = (defaults.object(forKey: Keys.windowOpacity) as? Double) ?? 1.0
        windowBlurRadius = defaults.integer(forKey: Keys.windowBlurRadius)
        windowGlassEnabled = defaults.object(forKey: Keys.windowGlassEnabled) as? Bool ?? false
        windowGlassStyle = (defaults.string(forKey: Keys.windowGlassStyle))
            .flatMap(WindowGlassStyle.init(rawValue:)) ?? .regular
        adaptiveTerminalChromeEnabled = defaults.object(forKey: Keys.adaptiveTerminalChromeEnabled) as? Bool ?? false
        hideTitleBar = defaults.object(forKey: Keys.hideTitleBar) as? Bool ?? false
        ghosttyConfigSelection = Self.readGhosttyConfigSelection(from: defaults)
        passthroughPrograms = defaults.string(forKey: Keys.passthroughPrograms) ?? ""
        quickTerminalWidthFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalWidth), fallback: 0.6)
        quickTerminalHeightFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalHeight), fallback: 0.5)
        quickTerminalPositionMode = (defaults.string(forKey: Keys.quickTerminalPositionMode))
            .flatMap(QuickTerminalAdjustMode.init(rawValue:)) ?? .fixed
        quickTerminalFixedX = Self.clampUnitFraction(defaults.object(forKey: Keys.quickTerminalFixedX) as? Double)
        quickTerminalFixedY = Self.clampUnitFraction(defaults.object(forKey: Keys.quickTerminalFixedY) as? Double)
        quickTerminalSizeMode = (defaults.string(forKey: Keys.quickTerminalSizeMode))
            .flatMap(QuickTerminalAdjustMode.init(rawValue:)) ?? .fixed
        if let w = defaults.object(forKey: Keys.quickTerminalDynamicWidth) as? Double,
           let h = defaults.object(forKey: Keys.quickTerminalDynamicHeight) as? Double
        {
            quickTerminalDynamicSize = CGSize(
                width: Self.clampFraction(w, fallback: 0.6),
                height: Self.clampFraction(h, fallback: 0.5)
            )
        } else {
            quickTerminalDynamicSize = nil
        }
        if let x = defaults.object(forKey: Keys.quickTerminalPositionX) as? Double,
           let y = defaults.object(forKey: Keys.quickTerminalPositionY) as? Double
        {
            // No clamp: out-of-0…1 values are legitimate (panel left
            // overhanging an edge). QuickTerminalPlacement.frame bounds the
            // restore, so a corrupt value can't strand the panel.
            quickTerminalPosition = CGPoint(x: x, y: y)
        } else {
            quickTerminalPosition = nil
        }
        activeProjectID = (defaults.string(forKey: Keys.activeProjectID)).flatMap(UUID.init)
        projectIconSymbol = defaults.string(forKey: Keys.projectIconSymbol) ?? "folder"
        tabIconSymbol = defaults.string(forKey: Keys.tabIconSymbol) ?? "terminal"
        sidebarIconSize = (defaults.string(forKey: Keys.sidebarIconSize))
            .flatMap(SidebarIconSize.init(rawValue:)) ?? .medium
        showAgentIcons = defaults.object(forKey: Keys.showAgentIcons) as? Bool ?? true
        showTabStatusIndicator = defaults.object(forKey: Keys.showTabStatusIndicator) as? Bool ?? false
        showSpinnerOverAgentIcons = defaults.object(forKey: Keys.showSpinnerOverAgentIcons) as? Bool ?? true
        autoNameTabs = defaults.object(forKey: Keys.autoNameTabs) as? Bool ?? true
        showNewProjectButton = defaults.object(forKey: Keys.showNewProjectButton) as? Bool ?? true
        backgroundSSHConnections = defaults.object(forKey: Keys.backgroundSSHConnections) as? Bool ?? true
        reconnectRemotePanes = defaults.object(forKey: Keys.reconnectRemotePanes) as? Bool ?? true
        restoreAllProjectsOnLaunch = defaults.object(forKey: Keys.restoreAllProjectsOnLaunch) as? Bool ?? false
        peekSidebarWhenHidden = defaults.object(forKey: Keys.peekSidebarWhenHidden) as? Bool ?? true
        let storedSidebarWidth = Self.clampSidebarWidth(defaults.object(forKey: Keys.sidebarWidth) as? Double)
        sidebarWidth = storedSidebarWidth
        launchSidebarWidth = storedSidebarWidth
        updateChannel = (defaults.string(forKey: Keys.updateChannel))
            .flatMap(UpdateChannel.init(rawValue:)) ?? UpdateChannel.bundleDefault
        tabSwitcherVisibility = (defaults.string(forKey: Keys.tabSwitcherVisibility))
            .flatMap(TabSwitcherVisibility.init(rawValue:)) ?? .whenMultiple
        tabSwitcherPosition = (defaults.string(forKey: Keys.tabSwitcherPosition))
            .flatMap(TabSwitcherPosition.init(rawValue:)) ?? .trailing
        Self.runOneTimeMigrations(defaults: defaults)
    }

    private static func clampFraction(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.2, min(1.0, v))
    }

    /// Fixed-position anchors: an absent key means centered, and any stored
    /// value is bounded to the 0…1 anchor range.
    private static func clampUnitFraction(_ v: Double?) -> Double {
        guard let v else { return 0.5 }
        return max(0, min(1, v))
    }

    /// An absent key (never dragged) and an out-of-range one (a stale value
    /// from a build with different column bounds) both land on the default.
    static func clampSidebarWidth(_ v: Double?) -> Double {
        guard let v, v > 0 else { return defaultSidebarWidth }
        return min(max(v, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    private static func clampScrollSpeed(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.25, min(3.0, v))
    }

    /// Pre-v2 builds stored theme/font/option-as-alt in UserDefaults. Those
    /// settings now live entirely in the user's Ghostty config, so the keys
    /// are dead. Drop them so `defaults read com.thdxg.macterm` is clean
    /// and there's no risk of resurrecting the old values if someone wires
    /// them back up later.
    private static func runOneTimeMigrations(defaults: UserDefaults) {
        if !defaults.bool(forKey: Keys.migrationV2GhosttyConfigOwned) {
            defaults.removeObject(forKey: "macterm.appearance.theme")
            defaults.removeObject(forKey: "macterm.appearance.fontFamily")
            defaults.removeObject(forKey: "macterm.appearance.fontSize")
            defaults.removeObject(forKey: "macterm.input.optionAsAlt")
            defaults.set(true, forKey: Keys.migrationV2GhosttyConfigOwned)
        }
        // Eager tab start and session persistence are both unconditional now,
        // so their keys are dead. Drop the stored values rather than leave them
        // to silently take effect again if anything is ever wired back onto
        // those keys.
        if !defaults.bool(forKey: Keys.migrationRetiredToggleKeys) {
            defaults.removeObject(forKey: "macterm.eagerlyStartProjectTabs.enabled")
            defaults.removeObject(forKey: "macterm.session.terminateOnQuit")
            defaults.set(true, forKey: Keys.migrationRetiredToggleKeys)
        }
        // The unfocused-split dim is now driven by the user's ghostty config
        // (`unfocused-split-opacity` / `unfocused-split-fill`), so the
        // Macterm-side slider key is dead.
        if !defaults.bool(forKey: Keys.migrationRetiredPaneDimKey) {
            defaults.removeObject(forKey: "macterm.pane.dimOpacity")
            defaults.set(true, forKey: Keys.migrationRetiredPaneDimKey)
        }
    }

    /// Reads the two-layer config preference. The single-path key came from the
    /// previous UI, where choosing a custom path replaced Ghostty's defaults.
    /// Keep that exact behavior when migrating it.
    static func readGhosttyConfigSelection(from defaults: UserDefaults) -> GhosttyConfigSelection {
        let hasCurrentValue = defaults.object(forKey: Keys.loadsDefaultGhosttyConfigFiles) != nil
            || defaults.object(forKey: Keys.customGhosttyConfigPaths) != nil
        if hasCurrentValue {
            return GhosttyConfigSelection(
                loadsDefaultFiles: defaults.object(forKey: Keys.loadsDefaultGhosttyConfigFiles) as? Bool ?? true,
                customPaths: defaults.stringArray(forKey: Keys.customGhosttyConfigPaths) ?? []
            )
        }
        guard let legacyPath = defaults.string(forKey: Keys.userGhosttyConfigPath) else {
            return .automatic
        }
        return GhosttyConfigSelection(
            loadsDefaultFiles: false,
            customPaths: legacyPath.isEmpty ? [] : [legacyPath]
        )
    }

    // MARK: - UserDefaults keys

    enum Keys {
        static let autoTiling = "macterm.autoTiling.enabled"
        static let terminalScrollSpeed = "macterm.terminal.scrollSpeed"
        static let sidebarPeekStyle = "macterm.sidebar.presentation"
        static let windowOpacity = "macterm.window.opacity"
        static let windowBlurRadius = "macterm.window.blurRadius"
        static let windowGlassEnabled = "macterm.window.glassEnabled"
        static let windowGlassStyle = "macterm.window.glassStyle"
        static let adaptiveTerminalChromeEnabled = "macterm.window.adaptiveTerminalChromeEnabled"
        static let hideTitleBar = "macterm.window.hideTitleBar"
        static let loadsDefaultGhosttyConfigFiles = "macterm.ghostty.loadsDefaultConfigFiles"
        static let customGhosttyConfigPaths = "macterm.ghostty.customConfigPaths"
        /// Legacy single-path key. Read only for migration.
        static let userGhosttyConfigPath = "macterm.ghostty.userConfigPath"
        static let passthroughPrograms = "macterm.hotkey.passthroughPrograms"
        static let quickTerminalWidth = "macterm.quickTerminal.width"
        static let quickTerminalHeight = "macterm.quickTerminal.height"
        static let quickTerminalPositionMode = "macterm.quickTerminal.positionMode"
        static let quickTerminalFixedX = "macterm.quickTerminal.fixedX"
        static let quickTerminalFixedY = "macterm.quickTerminal.fixedY"
        static let quickTerminalSizeMode = "macterm.quickTerminal.sizeMode"
        static let quickTerminalDynamicWidth = "macterm.quickTerminal.dynamicWidth"
        static let quickTerminalDynamicHeight = "macterm.quickTerminal.dynamicHeight"
        static let quickTerminalPositionX = "macterm.quickTerminal.positionX"
        static let quickTerminalPositionY = "macterm.quickTerminal.positionY"
        static let activeProjectID = "macterm.activeProjectID"
        static let projectIconSymbol = "macterm.sidebar.projectIcon"
        static let tabIconSymbol = "macterm.sidebar.tabIcon"
        static let sidebarIconSize = "macterm.sidebar.iconSize"
        static let showAgentIcons = "macterm.sidebar.showAgentIcons"
        static let showTabStatusIndicator = "macterm.sidebar.showTabStatusIndicator"
        static let showSpinnerOverAgentIcons = "macterm.sidebar.showSpinnerOverAgentIcons"
        static let autoNameTabs = "macterm.tabs.autoName"
        static let showNewProjectButton = "macterm.sidebar.showNewProjectButton"
        static let backgroundSSHConnections = "macterm.remote.backgroundSSHConnections"
        static let reconnectRemotePanes = "macterm.remote.reconnectDroppedPanes"
        static let restoreAllProjectsOnLaunch = "macterm.session.restoreAllProjectsOnLaunch"
        static let installationID = "macterm.installationID"
        static let peekSidebarWhenHidden = "macterm.sidebar.peekWhenHidden"
        static let sidebarWidth = "macterm.sidebar.width"
        static let updateChannel = "macterm.updates.channel"
        static let tabSwitcherVisibility = "macterm.toolbar.tabSwitcherVisibility"
        static let tabSwitcherPosition = "macterm.toolbar.tabSwitcherPosition"
        static let migrationV2GhosttyConfigOwned = "macterm.migration.v2_ghostty_config_owned"
        static let migrationRetiredToggleKeys = "macterm.migration.retired_toggle_keys"
        static let migrationRetiredPaneDimKey = "macterm.migration.retired_pane_dim_key"
    }
}
