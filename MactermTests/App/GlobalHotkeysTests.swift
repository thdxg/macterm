import AppKit
import Carbon
@testable import Macterm
import Testing

@MainActor
struct GlobalHotkeysTests {
    /// Restore the flag afterwards: `globalActions()` is a cached, process-wide
    /// read, so a leaked flag would follow a later test into a real Carbon
    /// registration attempt.
    private func withGlobal(_ action: HotkeyAction, _ body: () throws -> Void) rethrows {
        HotkeyRegistry.setGlobal(true, for: action)
        defer { HotkeyRegistry.setGlobal(false, for: action) }
        try body()
    }

    private func shortcut(_ raw: String) throws -> HotkeyShortcut {
        try #require(HotkeyRegistry.parseShortcut(raw))
    }

    // MARK: - The flag

    @Test
    func the_global_flag_persists_and_is_off_by_default() {
        let action = HotkeyAction.newTab
        #expect(!HotkeyRegistry.isGlobal(action))
        withGlobal(action) {
            #expect(HotkeyRegistry.isGlobal(action))
            #expect(HotkeyRegistry.globalActions().contains(action))
        }
        #expect(!HotkeyRegistry.isGlobal(action))
        #expect(!HotkeyRegistry.globalActions().contains(action))
    }

    /// Its own defaults key, so flipping it can't disturb the binding or the
    /// passthrough flag that live beside it.
    @Test
    func the_global_flag_has_its_own_key() {
        #expect(HotkeyAction.newTab.globalDefaultsKey == "macterm.hotkey.new_tab.global")
        #expect(HotkeyAction.newTab.globalDefaultsKey != HotkeyAction.newTab.defaultsKey)
        #expect(HotkeyAction.newTab.globalDefaultsKey != HotkeyAction.newTab.passthroughDefaultsKey)
    }

    /// The quick terminal has been a system-wide Carbon hot key since it
    /// shipped; the flag can't take that away, and it reads as on.
    @Test
    func the_quick_terminal_is_always_global() {
        #expect(HotkeyAction.toggleQuickTerminal.isAlwaysGlobal)
        #expect(HotkeyRegistry.isGlobal(.toggleQuickTerminal))
        #expect(HotkeyRegistry.globalActions().contains(.toggleQuickTerminal))
        HotkeyRegistry.setGlobal(false, for: .toggleQuickTerminal)
        #expect(HotkeyRegistry.isGlobal(.toggleQuickTerminal))
        #expect(!Preferences.defaults.bool(forKey: HotkeyAction.toggleQuickTerminal.globalDefaultsKey))
    }

    @Test
    func no_action_ships_flagged_global_except_the_quick_terminal() {
        #expect(HotkeyRegistry.globalActions() == [.toggleQuickTerminal])
    }

    // MARK: - Chord → Carbon

    @Test
    func a_chord_maps_to_its_hardware_key_code() throws {
        // A global hot key is matched by key position, so `keyCodes`' US-ANSI
        // table is exactly the right source.
        #expect(try shortcut("cmd+t").carbonKeyCode == 17)
        #expect(try shortcut("ctrl+`").carbonKeyCode == 50)
        #expect(try shortcut("cmd+shift+return").carbonKeyCode == 36)
        #expect(try shortcut("opt+left").carbonKeyCode == 123)
    }

    @Test
    func cocoa_modifiers_map_to_carbons_bitmask() throws {
        #expect(try shortcut("cmd+t").carbonModifiers == UInt32(cmdKey))
        #expect(try shortcut("ctrl+t").carbonModifiers == UInt32(controlKey))
        #expect(try shortcut("shift+t").carbonModifiers == UInt32(shiftKey))
        #expect(try shortcut("opt+t").carbonModifiers == UInt32(optionKey))
        #expect(
            try shortcut("cmd+ctrl+opt+shift+t").carbonModifiers
                == UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey)
        )
        // Order in the string is irrelevant — the bitmask is a set.
        #expect(try shortcut("shift+cmd+t").carbonModifiers == shortcut("cmd+shift+t").carbonModifiers)
    }

    /// Carbon identifies a hot key by a `UInt32` we choose; the round trip has
    /// to be exact or a fired chord would run a different action.
    @Test
    func every_action_round_trips_through_its_carbon_hot_key_id() {
        for action in HotkeyAction.allCases {
            #expect(GlobalHotkeys.action(forHotKeyID: GlobalHotkeys.hotKeyID(for: action)) == action)
        }
        // Never zero: Carbon ids are ours to pick, and 0 is the value a
        // zero-initialized `EventHotKeyID` carries.
        #expect(HotkeyAction.allCases.allSatisfy { GlobalHotkeys.hotKeyID(for: $0) != 0 })
        #expect(GlobalHotkeys.action(forHotKeyID: 0) == nil)
        #expect(GlobalHotkeys.action(forHotKeyID: UInt32(HotkeyAction.allCases.count) + 1) == nil)
    }

    // MARK: - Prechecks

    @Test
    func a_chord_with_a_modifier_is_offered_to_the_system() throws {
        #expect(try GlobalHotkeyPlan.precheck(shortcut("cmd+t"), passesThroughToPrograms: false) == nil)
    }

    /// A bare key registered system-wide would swallow that character in every
    /// app, so it never reaches Carbon.
    @Test
    func a_modifier_less_chord_is_refused_before_carbon_is_asked() throws {
        #expect(try GlobalHotkeyPlan.precheck(shortcut("t"), passesThroughToPrograms: false) == .noModifier)
    }

    /// The two flags contradict each other: a Carbon registration takes the
    /// chord before any pane sees it, so passthrough could never happen.
    @Test
    func a_passthrough_chord_is_refused_rather_than_silently_defeating_passthrough() throws {
        #expect(try GlobalHotkeyPlan.precheck(shortcut("ctrl+h"), passesThroughToPrograms: true) == .passesThrough)
        // The more fundamental refusal wins when both apply.
        #expect(try GlobalHotkeyPlan.precheck(shortcut("h"), passesThroughToPrograms: true) == .noModifier)
    }

    /// `eventHotKeyExistsErr` is reachable from a second action of ours on the
    /// same chord as well as from another app, so the verdict is "taken" and
    /// the message names neither.
    @Test
    func a_taken_chord_is_reported_as_taken_and_anything_else_as_a_status() {
        #expect(GlobalHotkeyRefusal.from(status: OSStatus(eventHotKeyExistsErr)) == .taken)
        #expect(GlobalHotkeyRefusal.from(status: -1) == .failed(-1))
        // Every reason says something a user can act on.
        for refusal in [GlobalHotkeyRefusal.noModifier, .passesThrough, .taken, .failed(-1)] {
            #expect(!refusal.message.isEmpty)
        }
        #expect(!GlobalHotkeyRefusal.taken.message.contains("app"))
    }

    // MARK: - Reconciliation

    @Test
    func a_newly_flagged_chord_is_registered() throws {
        let diff = try GlobalHotkeyPlan.diff(registered: [:], desired: [.newTab: shortcut("cmd+ctrl+t")])
        #expect(diff.unregister.isEmpty)
        #expect(diff.register.keys.sorted { $0.rawValue < $1.rawValue } == [.newTab])
    }

    @Test
    func an_unflagged_action_is_unregistered_and_nothing_replaces_it() {
        let diff = GlobalHotkeyPlan.diff(registered: [.newTab: "cmd+ctrl+t"], desired: [:])
        #expect(diff.unregister == [.newTab])
        #expect(diff.register.isEmpty)
    }

    @Test
    func a_rebind_releases_the_old_chord_before_taking_the_new_one() throws {
        let diff = try GlobalHotkeyPlan.diff(
            registered: [.newTab: "cmd+ctrl+t"],
            desired: [.newTab: shortcut("cmd+ctrl+y")]
        )
        #expect(diff.unregister == [.newTab])
        #expect(diff.register[.newTab]?.id == "cmd+ctrl+y")
    }

    /// Re-registering a live hot key would release it for an instant, and
    /// another app watching for the chord could take the slot — so an
    /// unchanged binding is left strictly alone.
    @Test
    func an_unchanged_chord_is_left_alone() throws {
        let diff = try GlobalHotkeyPlan.diff(
            registered: [.newTab: "cmd+ctrl+t"],
            desired: [.newTab: shortcut("cmd+ctrl+t")]
        )
        #expect(diff == GlobalHotkeyPlan.Diff())
    }

    /// A refused chord is absent from the registered set, so the next sync asks
    /// for it again — that retry is the whole recovery path once the other app
    /// releases it.
    @Test
    func a_refused_chord_is_retried_on_the_next_sync() throws {
        let desired: [HotkeyAction: HotkeyShortcut] = try [.newTab: shortcut("cmd+ctrl+t")]
        #expect(GlobalHotkeyPlan.diff(registered: [:], desired: desired).register.count == 1)
        #expect(GlobalHotkeyPlan.diff(registered: [:], desired: desired).register.count == 1)
    }

    // MARK: - One owner

    /// The double-fire rule. Carbon consumes a registered hot key system-wide,
    /// but the local monitor yields it explicitly so the action can only ever
    /// run once while Macterm is frontmost.
    @Test
    func the_local_monitor_yields_only_the_chords_carbon_holds() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        ))
        // Nothing is registered in a hosted test run — `GlobalHotkeys.install`
        // is only reached from the launch path, which xctest skips — so the
        // local monitor keeps every chord and the responders run as always.
        #expect(!GlobalHotkeys.shared.isRegistered(.newTab))
        #expect(!GlobalHotkeys.shared.yieldsToCarbon(event))
        // Flagging alone changes nothing: a chord is yielded because Carbon
        // HOLDS it, not because the user asked for it. That is what makes a
        // refused chord degrade to a plain local keybind instead of going dead.
        withGlobal(.newTab) {
            #expect(!GlobalHotkeys.shared.isRegistered(.newTab))
            #expect(!GlobalHotkeys.shared.yieldsToCarbon(event))
        }
    }

    // MARK: - Fronting a window

    /// Carbon delivers the chord from any app, so an action that acts on a
    /// window has to bring one forward first.
    @Test
    func an_action_fired_from_another_app_fronts_a_window() {
        #expect(GlobalHotkeyPlan.frontsWindow(for: .newTab, appIsActive: false, hasVisibleTerminalWindow: true))
        #expect(GlobalHotkeyPlan.frontsWindow(for: .toggleCommandPalette, appIsActive: false, hasVisibleTerminalWindow: false))
    }

    /// Already frontmost with a window on screen: nothing to front.
    @Test
    func an_action_fired_inside_macterm_fronts_nothing() {
        #expect(!GlobalHotkeyPlan.frontsWindow(for: .newTab, appIsActive: true, hasVisibleTerminalWindow: true))
    }

    /// The last window hidden by its close button (#241): active, but with
    /// nothing on screen to act on.
    @Test
    func an_action_fires_a_window_open_when_the_last_one_is_hidden() {
        #expect(GlobalHotkeyPlan.frontsWindow(for: .newTab, appIsActive: true, hasVisibleTerminalWindow: false))
    }

    /// The quick terminal's panel is non-activating by design — it shows over
    /// whatever app the user is in, and fronting Macterm would take the focus
    /// the panel exists to avoid taking.
    @Test
    func the_quick_terminal_never_fronts_a_window() {
        for active in [true, false] {
            for visible in [true, false] {
                #expect(!GlobalHotkeyPlan.frontsWindow(
                    for: .toggleQuickTerminal,
                    appIsActive: active,
                    hasVisibleTerminalWindow: visible
                ))
            }
        }
    }
}
