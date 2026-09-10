import AppKit
import Carbon
import os

private let logger = Logger(subsystem: appBundleID, category: "GlobalHotkeys")

/// Why a global-flagged action's chord is not live system-wide. Surfaced in
/// Settings → Keymaps beside the row, because a registration that fails
/// silently leaves the user with a chord that does nothing anywhere: once
/// another app owns a chord the system delivers the keystroke to that app, and
/// Macterm sees no keyDown for it whether it is frontmost or not.
enum GlobalHotkeyRefusal: Equatable {
    /// The chord has no modifier. Registering a bare key system-wide would
    /// swallow that character in every app, so it is refused before Carbon is
    /// asked; the binding keeps working locally.
    case noModifier
    /// The action is also flagged to pass through to programs, and the two
    /// flags contradict each other: a Carbon registration takes the chord
    /// before any pane sees it, so the program would never receive it. Refused
    /// rather than silently defeating passthrough.
    case passesThrough
    /// The system declined because the chord is already held
    /// (`eventHotKeyExistsErr`) — by another app, or by another action of ours
    /// flagged global on the same chord. Carbon does not say which, and it is
    /// reachable both ways (measured), so the message names neither.
    case taken
    /// Any other Carbon status.
    case failed(OSStatus)

    static func from(status: OSStatus) -> GlobalHotkeyRefusal {
        status == OSStatus(eventHotKeyExistsErr) ? .taken : .failed(status)
    }

    /// Sentence case, like every other Settings control's copy.
    var message: String {
        switch self {
        case .noModifier: "Not global: a system-wide keybind needs a modifier key."
        case .passesThrough: "Not global: this keybind passes through to programs instead."
        case .taken: "Not global: this keybind is already taken."
        case let .failed(status): "Not global: the system refused it (error \(status))."
        }
    }
}

/// The pure half of global registration: which chords may be registered, what
/// has to change to get there, and what a fired chord should do first. Free of
/// Carbon and AppKit state so the rules are unit-testable.
enum GlobalHotkeyPlan {
    /// A chord's fitness for system-wide registration, or nil when Carbon may
    /// be asked for it.
    static func precheck(_ shortcut: HotkeyShortcut, passesThroughToPrograms: Bool) -> GlobalHotkeyRefusal? {
        if shortcut.modifiers.isEmpty { return .noModifier }
        if passesThroughToPrograms { return .passesThrough }
        return nil
    }

    struct Diff: Equatable {
        var unregister: [HotkeyAction] = []
        var register: [HotkeyAction: HotkeyShortcut] = [:]
    }

    /// What has to change to move from `registered` (action → the shortcut id
    /// Carbon currently holds) to `desired`. An action whose chord is unchanged
    /// is left alone: re-registering a live hot key would release it for an
    /// instant, and another app watching for that chord could take the slot.
    static func diff(registered: [HotkeyAction: String], desired: [HotkeyAction: HotkeyShortcut]) -> Diff {
        var diff = Diff()
        for (action, shortcutID) in registered where desired[action]?.id != shortcutID {
            diff.unregister.append(action)
        }
        for (action, shortcut) in desired where registered[action] != shortcut.id {
            diff.register[action] = shortcut
        }
        diff.unregister.sort { $0.rawValue < $1.rawValue }
        return diff
    }

    /// Whether firing `action` should bring a terminal window forward first.
    ///
    /// The action itself always runs: Carbon delivers a registered chord to
    /// Macterm whether or not Macterm is frontmost, so gating the action on
    /// "we were in the background" would make the chord dead inside Macterm
    /// (the local monitor never sees it — see `GlobalHotkeys.yieldsToCarbon`).
    ///
    /// The quick-terminal toggle never fronts anything: its panel is
    /// non-activating by design and shows over whatever app the user is in,
    /// and activating Macterm would take focus away from it. Every other
    /// action acts on a window, so it fronts one when Macterm is in the
    /// background, or when Macterm is active with no terminal window on screen
    /// (the last window hidden by its close button, #241).
    static func frontsWindow(for action: HotkeyAction, appIsActive: Bool, hasVisibleTerminalWindow: Bool) -> Bool {
        if action == .toggleQuickTerminal { return false }
        return !appIsActive || !hasVisibleTerminalWindow
    }
}

/// Registers every global-flagged action's chord as a Carbon system-wide hot
/// key, so it fires while another app is frontmost — Ghostty's `global:`
/// keybind prefix, expressed as the per-action flag that sits beside
/// passthrough (`macterm.hotkey.<action_id>.global`).
///
/// Carbon `RegisterEventHotKey` rather than the CGEvent tap Ghostty uses: it
/// needs no Accessibility grant (measured — a hermetic instance with no grant
/// fired a flagged chord from Finder), the system reports a chord it will not
/// give us so the UI can say so, and it is the mechanism the quick terminal
/// already relied on. The quick terminal's own registration moved in here — it
/// is the one action that is global by construction
/// (`HotkeyAction.isAlwaysGlobal`) — so the process has one Carbon event
/// handler and one registration per live chord instead of two schemes.
///
/// **Carbon is the sole owner of a chord it holds.** A registered hot key is
/// consumed by the system, so the app's own `NSEvent` monitor never sees that
/// keyDown even while Macterm is frontmost — measured, and the reason the
/// quick terminal's local responder branch has always been unreachable while
/// its chord is registered. `yieldsToCarbon` states that ownership at the
/// `KeyRouter` funnel rather than resting on the measurement. The consequence
/// is worth knowing before flagging a pane-scoped action global: the chord
/// then always runs the app-level `AppCommand`, so it no longer reaches the
/// quick-terminal responder's own splits, and it cannot pass through to a
/// program (which is why the two flags together are refused).
///
/// What Carbon does NOT do is arbitrate across processes the way a single
/// owner would: a Debug and a Release Macterm both registered `ctrl+\``
/// successfully at the same time. So a refusal is a real signal when it comes
/// (a second action of ours on one chord is refused with
/// `eventHotKeyExistsErr`, measured), but its absence is not a promise that
/// nothing else holds the chord.
///
/// A fired chord dispatches through `AppCommand.action(in:)` — the same path
/// the palette, the menu bar and a local keypress take. Nothing here
/// re-implements an action.
@MainActor
@Observable
final class GlobalHotkeys {
    static let shared = GlobalHotkeys()

    private struct Registration {
        let ref: EventHotKeyRef
        let shortcutID: String
    }

    /// Flagged actions whose chord is NOT live, by reason. Observable so the
    /// Keymaps rows can say so; every `sync` retries a refused chord, so the
    /// message clears as soon as the other app lets go and the user re-toggles
    /// or rebinds.
    private(set) var refusals: [HotkeyAction: GlobalHotkeyRefusal] = [:]

    @ObservationIgnored private var registrations: [HotkeyAction: Registration] = [:]
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var installed = false
    @ObservationIgnored private var context: AppCommandContext?

    /// Four-char code identifying our hot keys to Carbon ('MUXY', inherited
    /// from the quick terminal's registration).
    private static let signature = OSType(0x4D55_5859)

    private init() {}

    /// Install the Carbon handler and register the currently flagged set.
    /// Called once from `applicationDidFinishLaunching`, which early-returns
    /// under xctest — a hosted test run must never take over the developer's
    /// real chords, and `sync` stays a no-op until this has run.
    func install() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            guard id.signature == GlobalHotkeys.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
            let hotKeyID = id.id
            // Hop off the Carbon dispatch before touching app state, as the
            // quick terminal's handler always did.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner.fire(hotKeyID: hotKeyID) }
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
        guard status == noErr else {
            logger.error("InstallEventHandler failed: \(status, privacy: .public)")
            eventHandler = nil
            return
        }
        installed = true
        sync()
    }

    /// Give fired actions their `AppCommand` context, from `installResponders`.
    /// Until this lands only the quick-terminal toggle can act — it is the one
    /// action that needs no workspace.
    func attach(appState: AppState, projectStore: ProjectStore) {
        context = AppCommandContext(appState: appState, projectStore: projectStore)
    }

    /// Whether Carbon currently holds `action`'s chord.
    func isRegistered(_ action: HotkeyAction) -> Bool {
        registrations[action] != nil
    }

    /// The single ownership rule: the local `NSEvent` monitor yields exactly
    /// the chords Carbon holds, so a global chord fires once while Macterm is
    /// frontmost instead of twice. Called from `KeyRouter.dispatch` ahead of
    /// every responder.
    ///
    /// In practice the system consumes a registered hot key before the monitor
    /// runs, so this rarely gets the chance to fire; it is the rule stated in
    /// code rather than left to that measurement. What it deliberately does
    /// NOT cover is a chord flagged global that Carbon **refused** — that
    /// action is absent from `registrations`, so the local path keeps handling
    /// it, which is what makes a taken chord degrade to a plain local keybind.
    ///
    /// Costs one `isEmpty` check per keystroke in the default configuration,
    /// where nothing but the quick terminal is registered.
    func yieldsToCarbon(_ event: NSEvent) -> Bool {
        guard !registrations.isEmpty else { return false }
        guard let action = registrations.keys.first(where: { HotkeyRegistry.matches(event, action: $0) }) else {
            return false
        }
        logger.debug("local monitor yielded \(action.rawValue, privacy: .public) to its Carbon registration")
        return true
    }

    /// Reconcile Carbon with the flagged set and their current bindings. Runs
    /// after every rebind and every flag change (`HotkeyRegistry` calls it), so
    /// a toggle or a new chord takes effect without a relaunch; a cleared
    /// binding unregisters and registers nothing.
    func sync() {
        guard installed else { return }
        var desired: [HotkeyAction: HotkeyShortcut] = [:]
        var refused: [HotkeyAction: GlobalHotkeyRefusal] = [:]
        for action in HotkeyRegistry.globalActions() {
            guard let shortcut = HotkeyRegistry.selectedShortcut(for: action) else { continue }
            let passesThrough = HotkeyRegistry.passesThroughToPrograms(for: action)
            if let refusal = GlobalHotkeyPlan.precheck(shortcut, passesThroughToPrograms: passesThrough) {
                refused[action] = refusal
            } else {
                desired[action] = shortcut
            }
        }
        let diff = GlobalHotkeyPlan.diff(registered: registrations.mapValues(\.shortcutID), desired: desired)
        for action in diff.unregister {
            unregister(action)
        }
        // A chord refused by the system is not in `registrations`, so the diff
        // asks for it again on the next sync — that retry is what lets the
        // refusal clear once the other app releases the chord.
        for (action, shortcut) in diff.register {
            if let refusal = register(shortcut, for: action) {
                refused[action] = refusal
            }
        }
        if refused != refusals { refusals = refused }
    }

    private func register(_ shortcut: HotkeyShortcut, for action: HotkeyAction) -> GlobalHotkeyRefusal? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.carbonKeyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.hotKeyID(for: action)),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            logger.error(
                "RegisterEventHotKey \(shortcut.id, privacy: .public) for \(action.rawValue, privacy: .public) failed: \(status, privacy: .public)"
            )
            return .from(status: status)
        }
        registrations[action] = Registration(ref: ref, shortcutID: shortcut.id)
        logger.info("registered \(shortcut.id, privacy: .public) for \(action.rawValue, privacy: .public)")
        return nil
    }

    private func unregister(_ action: HotkeyAction) {
        guard let registration = registrations.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(registration.ref)
        logger.info("unregistered \(registration.shortcutID, privacy: .public) for \(action.rawValue, privacy: .public)")
    }

    /// Carbon identifies a hot key by a `UInt32` of our choosing; an action's
    /// position in `allCases` is stable for the life of the process, and the
    /// ids are never persisted.
    static func hotKeyID(for action: HotkeyAction) -> UInt32 {
        UInt32((HotkeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
    }

    static func action(forHotKeyID id: UInt32) -> HotkeyAction? {
        let index = Int(id) - 1
        guard HotkeyAction.allCases.indices.contains(index) else { return nil }
        return HotkeyAction.allCases[index]
    }

    private func fire(hotKeyID: UInt32) {
        guard let action = Self.action(forHotKeyID: hotKeyID), isRegistered(action) else { return }
        logger.info("global \(action.rawValue, privacy: .public) fired")
        let delegate = context?.appState.appDelegate
        if GlobalHotkeyPlan.frontsWindow(
            for: action,
            appIsActive: NSApp.isActive,
            hasVisibleTerminalWindow: delegate?.terminalWindows.contains(where: \.isVisible) ?? false
        ) {
            // Fronts the terminal window and activates the app, opening a
            // window first if the launch never produced one (#241).
            delegate?.showWindow()
        }
        guard let context else {
            // Responders aren't installed yet, so no window has appeared. The
            // quick terminal needs neither; everything else has nothing to act
            // on until the workspace exists.
            if action == .toggleQuickTerminal { QuickTerminalService.shared.toggle() }
            return
        }
        guard let run = action.appCommand.action(in: context) else {
            logger.info("global \(action.rawValue, privacy: .public) does not apply right now")
            return
        }
        run()
    }
}
