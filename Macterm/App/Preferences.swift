import AppKit
import Foundation
import Observation

/// Whether a new terminal starts in the project directory or the focused
/// pane's cwd — the two answers to ghostty's `tab-inherit-working-directory`
/// and `split-inherit-working-directory`, which `AppState` reads live off the
/// loaded config (`GhosttyApp.tabInheritsWorkingDirectory` and friends). In a
/// project-based terminal, ghostty's "default working directory" for the
/// `false` case is the project root.
enum NewTerminalWorkingDirectory: Equatable {
    case projectDirectory
    case activePaneDirectory

    /// The ghostty boolean's reading: `true` inherits the focused pane's cwd.
    init(inherits: Bool) {
        self = inherits ? .activePaneDirectory : .projectDirectory
    }

    /// The directory a new terminal must start in, or nil for "keep the
    /// caller's own inheritance". Nil is only ever "Active pane" with no
    /// usable LOCAL cwd — every remote pane, and any pane whose surface
    /// isn't up yet — and coercing that case to the project root would be
    /// wrong: `TerminalTab.split` inherits a remote pane's scp-style
    /// `projectPath` verbatim, so overriding it spawns a LOCAL shell at the
    /// project root instead of a remote sibling (and a pinned pane, whose
    /// own `projectPath` IS its cwd, would land at home). Callers with
    /// nothing to inherit from (a brand-new tab) coalesce to the project
    /// directory themselves.
    func resolveNewTerminalDirectory(projectDirectory: String, activePaneDirectory: String?) -> String? {
        guard self == .activePaneDirectory else { return projectDirectory }
        guard let activePaneDirectory, !activePaneDirectory.isEmpty else { return nil }
        return activePaneDirectory
    }
}

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
            Keys.autoTiling.write(autoTilingEnabled, to: defaults)
            // Legacy notification — listeners predate Preferences.
            NotificationCenter.default.post(name: .autoTilingEnabledDidChange, object: nil)
        }
    }

    // MARK: - Experimental (Settings → Experimental; all default off)

    /// Pixel-precise trackpad scrolling through scrollback. Written to the
    /// overrides as the fork's `smooth-scroll` key (`MactermConfig
    /// .Experiments`): libghostty already accumulates precise deltas in
    /// pixels, and with the key on it renders the sub-row remainder instead
    /// of dropping it. Every wheel event reaches libghostty untouched (#393),
    /// so the gate has to live on that side.
    var smoothScrolling: Bool {
        didSet {
            Keys.smoothScrolling.write(smoothScrolling, to: defaults)
            notifyConfigChanged()
        }
    }

    /// The cursor glides between cells instead of jumping. Implemented as a
    /// bundled ghostty custom shader (`Resources/shaders/cursor_glide.glsl`)
    /// that Macterm appends to the config through the overrides file, along
    /// with `cursor-opacity = 0` so the shader can be the focused cursor.
    /// See `MactermConfig.Experiments`.
    var smoothCursor: Bool {
        didSet {
            Keys.smoothCursor.write(smoothCursor, to: defaults)
            notifyConfigChanged()
        }
    }

    /// A fading streak follows the cursor across larger moves. The bundled
    /// `cursor_trail.glsl`, injected the same way as `smoothCursor`.
    var cursorTrail: Bool {
        didSet {
            Keys.cursorTrail.write(cursorTrail, to: defaults)
            notifyConfigChanged()
        }
    }

    /// Hyprland-style split animations (its `slide`): a new pane slides in
    /// from the nearest edge while its neighbours retile, a closing pane
    /// slides back out, and zoom grows the pane over the layout. Pure
    /// Macterm chrome — the tab's
    /// tree is rendered flat by `AnimatedSplitView` (one animatable frame per
    /// pane) instead of the recursive `SplitTreeView`, and nothing reaches
    /// libghostty beyond the per-frame surface resizes a divider drag already
    /// causes. Off: the recursive view, exactly as before.
    var animatedSplits: Bool {
        didSet { Keys.animatedSplits.write(animatedSplits, to: defaults) }
    }

    /// Presentation used by `peekSidebarWhenHidden`. The pinned sidebar is
    /// always the native split-view column.
    var sidebarPeekStyle: SidebarPeekStyle {
        didSet { Keys.sidebarPeekStyle.write(sidebarPeekStyle, to: defaults) }
    }

    // MARK: - Sidebar icons

    var projectIconSymbol: String {
        didSet { Keys.projectIconSymbol.write(projectIconSymbol, to: defaults) }
    }

    var tabIconSymbol: String {
        didSet { Keys.tabIconSymbol.write(tabIconSymbol, to: defaults) }
    }

    /// How large the leading glyph on project and tab rows draws.
    var sidebarIconSize: SidebarIconSize {
        didSet { Keys.sidebarIconSize.write(sidebarIconSize, to: defaults) }
    }

    /// Replace a tab's icon with the running AI agent's logo (Claude Code,
    /// Codex, …) while one holds the pane's foreground. On by default.
    var showAgentIcons: Bool {
        didSet { Keys.showAgentIcons.write(showAgentIcons, to: defaults) }
    }

    /// Show a status badge over each tab icon: a spinner while a command is
    /// running (replacing the icon) and a small status dot when a command has
    /// finished and awaits attention. Off = pure icons, no status tracking.
    var showTabStatusIndicator: Bool {
        didSet { Keys.showTabStatusIndicator.write(showTabStatusIndicator, to: defaults) }
    }

    /// Show a transient tab switcher while the Recent Tab shortcut is held
    /// (#344): a glass strip of the recency-ordered tabs with a preview of
    /// each pane, so a several-tab project shows where the next Ctrl+Tab will
    /// land. On by default. Off keeps the plain direct-cycling behavior —
    /// where each press switches tabs for real rather than moving a selection
    /// — and skips the pane snapshots entirely, so it costs nothing there.
    var showTabSwitcherOverlay: Bool {
        didSet { Keys.showTabSwitcherOverlay.write(showTabSwitcherOverlay, to: defaults) }
    }

    /// Finite candidate counts offered in Settings and accepted from storage.
    nonisolated static let recentTabCandidateRange = 2 ... 12
    /// The stored value meaning "every tab". Also the default, so an upgrade
    /// changes nothing about how far the Recent Tab shortcut reaches.
    nonisolated static let unlimitedRecentTabCandidates = 0

    /// How many of the most recent tabs the Recent Tab shortcut cycles
    /// through, with or without the switcher showing —
    /// `unlimitedRecentTabCandidates` for every tab. A tab past the limit is
    /// unreachable by the gesture, so this bounds the cycle itself, not just
    /// the cards the switcher draws; the two are always the same list.
    var recentTabCandidates: Int {
        didSet { Keys.recentTabCandidates.write(recentTabCandidates, to: defaults) }
    }

    /// Whether the running spinner also replaces an AI agent's logo (#225).
    /// Off keeps the agent logo while the agent works — agent CLIs draw their
    /// own busy indicator in the tab title, so the spinner is redundant there —
    /// while the done dot still appears (it overlays the logo rather than
    /// replacing it). Meaningful only while `showTabStatusIndicator` and
    /// `showAgentIcons` are both on.
    var showSpinnerOverAgentIcons: Bool {
        didSet { Keys.showSpinnerOverAgentIcons.write(showSpinnerOverAgentIcons, to: defaults) }
    }

    /// Auto-name tabs after the live foreground process / OSC title (on by
    /// default). Off = tabs hold their static fallback (login shell name, or
    /// the host name for remote panes); a user-set custom title always wins
    /// either way. Display-only: the polling and probing keep running for
    /// busy-close verdicts and execution tracking (`Pane.displayTitle` is
    /// the single gate).
    var autoNameTabs: Bool {
        didSet { Keys.autoNameTabs.write(autoNameTabs, to: defaults) }
    }

    /// Give each new project a color tag. Off by default, and consulted at
    /// creation only — flipping it neither tags existing projects nor clears
    /// tags already set.
    var autoAssignProjectColors: Bool {
        didSet { Keys.autoAssignProjectColors.write(autoAssignProjectColors, to: defaults) }
    }

    var showNewProjectButton: Bool {
        didSet { Keys.showNewProjectButton.write(showNewProjectButton, to: defaults) }
    }

    /// Show a New Tab button while the pointer rests on a project row.
    var showProjectNewTabButton: Bool {
        didSet { Keys.showProjectNewTabButton.write(showProjectNewTabButton, to: defaults) }
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
        didSet { Keys.backgroundSSHConnections.write(backgroundSSHConnections, to: defaults) }
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
        didSet { Keys.reconnectRemotePanes.write(reconnectRemotePanes, to: defaults) }
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

    /// Whether the first-run seed (`FirstRunSeed`) has already had its say.
    /// Set on the first launch that can answer the question — whether or not
    /// it actually seeded — so an existing install is never examined twice
    /// and a user who removes every project doesn't get a Home project back.
    /// Like `installationID`: nothing in the UI reads it, so it's a
    /// read-through rather than `@Observable` state.
    var hasSeededFirstRun: Bool {
        get { defaults.bool(forKey: Keys.hasSeededFirstRun) }
        set { defaults.set(newValue, forKey: Keys.hasSeededFirstRun) }
    }

    /// Slide the hidden sidebar out while the pointer sits at the window's
    /// leading edge, and back in when it leaves (`MainWindow`'s hover peek).
    var peekSidebarWhenHidden: Bool {
        didSet { Keys.peekSidebarWhenHidden.write(peekSidebarWhenHidden, to: defaults) }
    }

    /// Last width the user dragged the sidebar to, seeded into the column's
    /// `ideal` at launch. We persist it ourselves because SwiftUI's own
    /// autosave never survives a relaunch — see `MainWindow.sidebarWidth`.
    var sidebarWidth: Double {
        didSet { Keys.sidebarWidth.write(sidebarWidth, to: defaults) }
    }

    /// `sidebarWidth` as it stood at launch, frozen. What the restore must
    /// read: the column lays out (and `MainWindow`'s geometry callback writes
    /// its content-derived width over the stored one) *before* the window is
    /// styled, so by restore time the live property already says 144.
    private(set) var launchSidebarWidth: Double = defaultSidebarWidth

    /// Bounds of the sidebar column, shared by the persisted width's clamp and
    /// `MainWindow`'s `navigationSplitViewColumnWidth` so a stored value can
    /// never fall outside what the column accepts.
    nonisolated static let sidebarWidthRange: ClosedRange<Double> = 140 ... 400
    nonisolated static let defaultSidebarWidth: Double = 220

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
        didSet { Keys.updateChannel.write(updateChannel, to: defaults) }
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
        didSet { Keys.tabSwitcherVisibility.write(tabSwitcherVisibility, to: defaults) }
    }

    var tabSwitcherPosition: TabSwitcherPosition {
        didSet { Keys.tabSwitcherPosition.write(tabSwitcherPosition, to: defaults) }
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
            Keys.windowOpacity.write(windowOpacity, to: defaults)
            notifyWindowAppearanceChanged()
            scheduleGhosttyConfigReload()
        }
    }

    /// CGSSetWindowBackgroundBlurRadius value (0–100). 0 = no blur.
    var windowBlurRadius: Int {
        didSet {
            Keys.windowBlurRadius.write(windowBlurRadius, to: defaults)
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
            Keys.windowGlassEnabled.write(windowGlassEnabled, to: defaults)
            notifyWindowAppearanceChanged()
        }
    }

    /// Which liquid-glass material to use when `windowGlassEnabled` is on.
    /// `.regular` is frostier/more tinted; `.clear` is more transparent. No
    /// effect unless glass is enabled.
    var windowGlassStyle: WindowGlassStyle {
        didSet {
            Keys.windowGlassStyle.write(windowGlassStyle, to: defaults)
            notifyWindowAppearanceChanged()
        }
    }

    /// Match an opaque color painted across most of a terminal surface. A lone
    /// pane may tint the window; split panes are adapted independently. Off by
    /// default: the user's Ghostty theme remains the source of truth unless
    /// they explicitly opt in.
    var adaptiveTerminalChromeEnabled: Bool {
        didSet {
            Keys.adaptiveTerminalChromeEnabled.write(adaptiveTerminalChromeEnabled, to: defaults)
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
            Keys.hideTitleBar.write(hideTitleBar, to: defaults)
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
            Keys.passthroughPrograms.write(passthroughPrograms, to: defaults)
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
        didSet { Keys.quickTerminalWidth.write(quickTerminalWidthFraction, to: defaults) }
    }

    /// Fraction of screen height (0–1).
    var quickTerminalHeightFraction: Double {
        didSet { Keys.quickTerminalHeight.write(quickTerminalHeightFraction, to: defaults) }
    }

    /// How the panel's position is decided at show time: `fixed` anchors it
    /// with the X/Y sliders below; `dynamic` shows a grab handle and reopens
    /// the panel where the user last dragged it. Defaults to `fixed` with
    /// centered sliders — the classic quick-terminal contract.
    var quickTerminalPositionMode: QuickTerminalAdjustMode {
        didSet { Keys.quickTerminalPositionMode.write(quickTerminalPositionMode, to: defaults) }
    }

    /// Fixed-position anchors, as the panel origin's place within the screen's
    /// spare room per axis (0…1). X: 0 = left, 1 = right. Y is in placement
    /// space — 0 = bottom, 1 = top; the Settings slider reads Top…Bottom and
    /// inverts. 0.5/0.5 = centered.
    var quickTerminalFixedX: Double {
        didSet { Keys.quickTerminalFixedX.write(quickTerminalFixedX, to: defaults) }
    }

    var quickTerminalFixedY: Double {
        didSet { Keys.quickTerminalFixedY.write(quickTerminalFixedY, to: defaults) }
    }

    /// How the panel's size is decided at show time: `fixed` uses the
    /// width/height sliders; `dynamic` makes the panel edge-resizable and
    /// reopens it at the size the user last resized it to.
    var quickTerminalSizeMode: QuickTerminalAdjustMode {
        didSet { Keys.quickTerminalSizeMode.write(quickTerminalSizeMode, to: defaults) }
    }

    /// The panel size the user last resized to, as fractions of the screen's
    /// visible frame; `nil` = never resized, the size sliders' values apply.
    var quickTerminalDynamicSize: CGSize? {
        didSet {
            if let size = quickTerminalDynamicSize {
                Keys.quickTerminalDynamicWidth.write(Double(size.width), to: defaults)
                Keys.quickTerminalDynamicHeight.write(Double(size.height), to: defaults)
            } else {
                Keys.quickTerminalDynamicWidth.remove(from: defaults)
                Keys.quickTerminalDynamicHeight.remove(from: defaults)
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
                Keys.quickTerminalPositionX.write(Double(position.x), to: defaults)
                Keys.quickTerminalPositionY.write(Double(position.y), to: defaults)
            } else {
                Keys.quickTerminalPositionX.remove(from: defaults)
                Keys.quickTerminalPositionY.remove(from: defaults)
            }
        }
    }

    // MARK: - Session

    /// Persisted so the app re-opens to the last-used project on launch.
    var activeProjectID: UUID? {
        didSet {
            if let id = activeProjectID {
                Keys.activeProjectID.write(id.uuidString, to: defaults)
            } else {
                Keys.activeProjectID.remove(from: defaults)
            }
        }
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
        autoTilingEnabled = Keys.autoTiling.read(defaults)
        smoothScrolling = Keys.smoothScrolling.read(defaults)
        smoothCursor = Keys.smoothCursor.read(defaults)
        cursorTrail = Keys.cursorTrail.read(defaults)
        animatedSplits = Keys.animatedSplits.read(defaults)
        sidebarPeekStyle = Keys.sidebarPeekStyle.read(defaults)
        windowOpacity = Keys.windowOpacity.read(defaults)
        windowBlurRadius = Keys.windowBlurRadius.read(defaults)
        windowGlassEnabled = Keys.windowGlassEnabled.read(defaults)
        windowGlassStyle = Keys.windowGlassStyle.read(defaults)
        adaptiveTerminalChromeEnabled = Keys.adaptiveTerminalChromeEnabled.read(defaults)
        hideTitleBar = Keys.hideTitleBar.read(defaults)
        ghosttyConfigSelection = Self.readGhosttyConfigSelection(from: defaults)
        passthroughPrograms = Keys.passthroughPrograms.read(defaults)
        quickTerminalWidthFraction = Keys.quickTerminalWidth.read(defaults)
        quickTerminalHeightFraction = Keys.quickTerminalHeight.read(defaults)
        quickTerminalPositionMode = Keys.quickTerminalPositionMode.read(defaults)
        quickTerminalFixedX = Keys.quickTerminalFixedX.read(defaults)
        quickTerminalFixedY = Keys.quickTerminalFixedY.read(defaults)
        quickTerminalSizeMode = Keys.quickTerminalSizeMode.read(defaults)
        if let w = Keys.quickTerminalDynamicWidth.readStored(defaults),
           let h = Keys.quickTerminalDynamicHeight.readStored(defaults)
        {
            quickTerminalDynamicSize = CGSize(
                width: Self.clampFraction(w, fallback: Keys.quickTerminalWidth.defaultValue),
                height: Self.clampFraction(h, fallback: Keys.quickTerminalHeight.defaultValue)
            )
        } else {
            quickTerminalDynamicSize = nil
        }
        if let x = Keys.quickTerminalPositionX.readStored(defaults),
           let y = Keys.quickTerminalPositionY.readStored(defaults)
        {
            // No clamp: out-of-0…1 values are legitimate (panel left
            // overhanging an edge). QuickTerminalPlacement.frame bounds the
            // restore, so a corrupt value can't strand the panel.
            quickTerminalPosition = CGPoint(x: x, y: y)
        } else {
            quickTerminalPosition = nil
        }
        activeProjectID = Keys.activeProjectID.readStored(defaults).flatMap(UUID.init)
        projectIconSymbol = Keys.projectIconSymbol.read(defaults)
        tabIconSymbol = Keys.tabIconSymbol.read(defaults)
        sidebarIconSize = Keys.sidebarIconSize.read(defaults)
        showAgentIcons = Keys.showAgentIcons.read(defaults)
        showTabStatusIndicator = Keys.showTabStatusIndicator.read(defaults)
        showTabSwitcherOverlay = Keys.showTabSwitcherOverlay.read(defaults)
        recentTabCandidates = Keys.recentTabCandidates.read(defaults)
        showSpinnerOverAgentIcons = Keys.showSpinnerOverAgentIcons.read(defaults)
        autoNameTabs = Keys.autoNameTabs.read(defaults)
        autoAssignProjectColors = Keys.autoAssignProjectColors.read(defaults)
        showNewProjectButton = Keys.showNewProjectButton.read(defaults)
        showProjectNewTabButton = Keys.showProjectNewTabButton.read(defaults)
        backgroundSSHConnections = Keys.backgroundSSHConnections.read(defaults)
        reconnectRemotePanes = Keys.reconnectRemotePanes.read(defaults)
        peekSidebarWhenHidden = Keys.peekSidebarWhenHidden.read(defaults)
        let storedSidebarWidth = Keys.sidebarWidth.read(defaults)
        sidebarWidth = storedSidebarWidth
        launchSidebarWidth = storedSidebarWidth
        updateChannel = Keys.updateChannel.read(defaults)
        tabSwitcherVisibility = Keys.tabSwitcherVisibility.read(defaults)
        tabSwitcherPosition = Keys.tabSwitcherPosition.read(defaults)
        Self.runOneTimeMigrations(defaults: defaults)
    }

    nonisolated private static func clampFraction(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.2, min(1.0, v))
    }

    /// Fixed-position anchors: an absent key means centered, and any stored
    /// value is bounded to the 0…1 anchor range.
    nonisolated private static func clampUnitFraction(_ v: Double) -> Double {
        max(0, min(1, v))
    }

    /// An absent key (never dragged) and an out-of-range one (a stale value
    /// from a build with different column bounds) both land on the default.
    nonisolated static func clampSidebarWidth(_ v: Double?) -> Double {
        guard let v, v > 0 else { return defaultSidebarWidth }
        return min(max(v, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    /// One candidate cannot switch tabs, so a stored `1` reads as the floor.
    nonisolated private static func clampRecentTabCandidates(_ v: Int) -> Int {
        guard v != unlimitedRecentTabCandidates else { return unlimitedRecentTabCandidates }
        return min(max(v, recentTabCandidateRange.lowerBound), recentTabCandidateRange.upperBound)
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
        // The new tab / split directory choice and Shortcuts access are
        // ghostty keys now (`tab-inherit-working-directory` /
        // `split-inherit-working-directory`, `macos-shortcuts`), read off the
        // loaded config with Macterm's defaults in `macterm-defaults.conf`;
        // scrolling is libghostty's own (`mouse-scroll-multiplier`) with no
        // Macterm-side speed at all. The old keys are dead.
        if !defaults.bool(forKey: Keys.migrationRetiredGhosttyOwnedKeys) {
            defaults.removeObject(forKey: "macterm.terminal.scrollSpeed")
            defaults.removeObject(forKey: "macterm.tabs.newTabWorkingDirectory")
            defaults.removeObject(forKey: "macterm.panes.newSplitWorkingDirectory")
            defaults.removeObject(forKey: "macterm.intents.shortcutsAccess")
            defaults.set(true, forKey: Keys.migrationRetiredGhosttyOwnedKeys)
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

    /// Every persisted setting, with its default and normalization. The
    /// plain strings at the bottom are keys nothing observes — read-through
    /// state and one-time migration flags — and stay raw.
    enum Keys {
        static let autoTiling = PreferenceStorageKey("macterm.autoTiling.enabled", default: false)
        static let smoothScrolling = PreferenceStorageKey("macterm.terminal.smoothScrolling", default: false)
        static let smoothCursor = PreferenceStorageKey("macterm.terminal.smoothCursor", default: false)
        static let cursorTrail = PreferenceStorageKey("macterm.terminal.cursorTrail", default: false)
        static let animatedSplits = PreferenceStorageKey("macterm.terminal.animatedSplits", default: false)
        static let sidebarPeekStyle = PreferenceStorageKey("macterm.sidebar.presentation", default: SidebarPeekStyle.resizeTerminal)
        static let windowOpacity = PreferenceStorageKey("macterm.window.opacity", default: 1.0)
        static let windowBlurRadius = PreferenceStorageKey("macterm.window.blurRadius", default: 0)
        static let windowGlassEnabled = PreferenceStorageKey("macterm.window.glassEnabled", default: false)
        static let windowGlassStyle = PreferenceStorageKey("macterm.window.glassStyle", default: WindowGlassStyle.regular)
        static let adaptiveTerminalChromeEnabled = PreferenceStorageKey("macterm.window.adaptiveTerminalChromeEnabled", default: false)
        static let hideTitleBar = PreferenceStorageKey("macterm.window.hideTitleBar", default: false)
        static let passthroughPrograms = PreferenceStorageKey("macterm.hotkey.passthroughPrograms", default: "")
        static let quickTerminalWidth = PreferenceStorageKey("macterm.quickTerminal.width", default: 0.6) {
            clampFraction($0, fallback: 0.6)
        }

        static let quickTerminalHeight = PreferenceStorageKey("macterm.quickTerminal.height", default: 0.5) {
            clampFraction($0, fallback: 0.5)
        }

        static let quickTerminalPositionMode = PreferenceStorageKey(
            "macterm.quickTerminal.positionMode", default: QuickTerminalAdjustMode.fixed
        )
        static let quickTerminalFixedX = PreferenceStorageKey("macterm.quickTerminal.fixedX", default: 0.5, normalize: clampUnitFraction)
        static let quickTerminalFixedY = PreferenceStorageKey("macterm.quickTerminal.fixedY", default: 0.5, normalize: clampUnitFraction)
        static let quickTerminalSizeMode = PreferenceStorageKey("macterm.quickTerminal.sizeMode", default: QuickTerminalAdjustMode.fixed)
        /// Halves of `quickTerminalDynamicSize` / `quickTerminalPosition`;
        /// read stored-only, since absence means "never resized / moved".
        static let quickTerminalDynamicWidth = PreferenceStorageKey("macterm.quickTerminal.dynamicWidth", default: 0.0)
        static let quickTerminalDynamicHeight = PreferenceStorageKey("macterm.quickTerminal.dynamicHeight", default: 0.0)
        static let quickTerminalPositionX = PreferenceStorageKey("macterm.quickTerminal.positionX", default: 0.0)
        static let quickTerminalPositionY = PreferenceStorageKey("macterm.quickTerminal.positionY", default: 0.0)
        /// Stored as the UUID string; absent means no selection.
        static let activeProjectID = PreferenceStorageKey("macterm.activeProjectID", default: "")
        static let projectIconSymbol = PreferenceStorageKey("macterm.sidebar.projectIcon", default: "folder")
        static let tabIconSymbol = PreferenceStorageKey("macterm.sidebar.tabIcon", default: "terminal")
        static let sidebarIconSize = PreferenceStorageKey("macterm.sidebar.iconSize", default: SidebarIconSize.medium)
        static let showAgentIcons = PreferenceStorageKey("macterm.sidebar.showAgentIcons", default: true)
        static let showTabStatusIndicator = PreferenceStorageKey("macterm.sidebar.showTabStatusIndicator", default: false)
        static let showTabSwitcherOverlay = PreferenceStorageKey("macterm.tabSwitcher.overlay", default: true)
        static let recentTabCandidates = PreferenceStorageKey(
            "macterm.tabs.recentTabCandidates", default: unlimitedRecentTabCandidates, normalize: clampRecentTabCandidates
        )
        static let showSpinnerOverAgentIcons = PreferenceStorageKey("macterm.sidebar.showSpinnerOverAgentIcons", default: true)
        static let autoNameTabs = PreferenceStorageKey("macterm.tabs.autoName", default: true)
        static let autoAssignProjectColors = PreferenceStorageKey("macterm.projects.autoAssignColors", default: false)
        static let showNewProjectButton = PreferenceStorageKey("macterm.sidebar.showNewProjectButton", default: true)
        static let showProjectNewTabButton = PreferenceStorageKey("macterm.sidebar.showProjectNewTabButton", default: true)
        static let backgroundSSHConnections = PreferenceStorageKey("macterm.remote.backgroundSSHConnections", default: true)
        static let reconnectRemotePanes = PreferenceStorageKey("macterm.remote.reconnectDroppedPanes", default: true)
        static let peekSidebarWhenHidden = PreferenceStorageKey("macterm.sidebar.peekWhenHidden", default: true)
        static let sidebarWidth = PreferenceStorageKey("macterm.sidebar.width", default: defaultSidebarWidth) {
            clampSidebarWidth($0)
        }

        static let updateChannel = PreferenceStorageKey("macterm.updates.channel", default: UpdateChannel.bundleDefault)
        static let tabSwitcherVisibility = PreferenceStorageKey(
            "macterm.toolbar.tabSwitcherVisibility", default: TabSwitcherVisibility.whenMultiple
        )
        static let tabSwitcherPosition = PreferenceStorageKey("macterm.toolbar.tabSwitcherPosition", default: TabSwitcherPosition.trailing)

        static let loadsDefaultGhosttyConfigFiles = "macterm.ghostty.loadsDefaultConfigFiles"
        static let customGhosttyConfigPaths = "macterm.ghostty.customConfigPaths"
        /// Legacy single-path key. Read only for migration.
        static let userGhosttyConfigPath = "macterm.ghostty.userConfigPath"
        static let installationID = "macterm.installationID"
        static let hasSeededFirstRun = "macterm.firstRun.seeded"
        static let migrationV2GhosttyConfigOwned = "macterm.migration.v2_ghostty_config_owned"
        static let migrationRetiredToggleKeys = "macterm.migration.retired_toggle_keys"
        static let migrationRetiredPaneDimKey = "macterm.migration.retired_pane_dim_key"
        static let migrationRetiredGhosttyOwnedKeys = "macterm.migration.retired_ghostty_owned_keys"
    }
}

// The enums `Preferences` persists by raw value. Declared here, beside the
// enums, because `PreferenceValue` is `Sendable` and a retroactive `Sendable`
// must live in the enum's own file.
extension SidebarPeekStyle: PreferenceValue {}
extension WindowGlassStyle: PreferenceValue {}
extension QuickTerminalAdjustMode: PreferenceValue {}
extension SidebarIconSize: PreferenceValue {}
extension UpdateChannel: PreferenceValue {}
extension TabSwitcherVisibility: PreferenceValue {}
extension TabSwitcherPosition: PreferenceValue {}
