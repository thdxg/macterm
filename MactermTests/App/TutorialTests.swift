import Foundation
@testable import Macterm
import Testing

/// The tutorial renderer. The property worth pinning is that the chord
/// columns come from the user's LIVE bindings — printing a stale `⌘T` at
/// someone who rebound it is the whole reason `macterm tutor` is a
/// control-socket verb instead of an offline one.
@MainActor
struct TutorialTests {
    @Test
    func every_topic_renders_something() {
        for topic in Tutorial.Topic.allCases {
            let text = Tutorial.render(topic: topic, styled: false, shortcut: { _ in "⌘T" })
            #expect(text.count > 200, "topic \(topic.rawValue) rendered almost nothing")
        }
    }

    @Test
    func the_chord_columns_show_the_users_own_binding() {
        // Not the default: the resolver is what the app asks HotkeyRegistry,
        // so a rebind has to reach the printed grid.
        let text = Tutorial.render(topic: .project, styled: false, shortcut: { action in
            action == .newTab ? "F13" : Tutorial.liveShortcut(action)
        })
        #expect(text.contains("F13  new tab"))
        #expect(!text.contains("⌘T  new tab"))
    }

    @Test
    func live_rebinding_is_visible_through_the_default_resolver() {
        // The real seam, end to end: HotkeyRegistry override → rendered text.
        let prior = HotkeyRegistry.selectedShortcutString(for: .newTab)
        defer { HotkeyRegistry.setShortcutString(prior, for: .newTab) }
        HotkeyRegistry.setShortcutString("ctrl+opt+n", for: .newTab)

        let text = Tutorial.render(topic: .project, styled: false)
        #expect(text.contains("⌃⌥N"))
        #expect(!text.contains("⌘T"))
    }

    @Test
    func an_action_the_user_unbound_prints_no_chord() {
        // The trap: HotkeyRegistry.displayString renders an unbound action as
        // the literal "None", which the grid would print as a chord
        // ("None  pin this tab"). pinTab/unpinTab ship unbound, so the pinned
        // topic hits this on every fresh install.
        let text = Tutorial.render(topic: .pinned, styled: false)
        #expect(!text.contains("None"))
        #expect(!text.contains("pin this tab"))
        #expect(Tutorial.liveShortcut(.pinTab).isEmpty)
        #expect(!Tutorial.liveShortcut(.newTab).isEmpty)
    }

    @Test
    func an_unbound_action_leaves_no_blank_cell() {
        // Every action unbound → the grid disappears entirely rather than
        // printing a column of empty chords, and the prose survives.
        let text = Tutorial.render(topic: .project, styled: false, shortcut: { _ in "" })
        #expect(!text.contains("new tab"))
        #expect(!text.contains("Move focus"))
        #expect(text.contains("macterm pane split"))
        // No line may end in whitespace — the padding is per-cell, and a
        // dropped cell must not leave a ragged tail behind.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(!line.hasSuffix(" "), "trailing whitespace: \(line)")
        }
    }

    @Test
    func unbound_actions_drop_out_but_bound_neighbours_stay() {
        let text = Tutorial.render(topic: .project, styled: false, shortcut: { action in
            action == .newTab ? "" : "⌘X"
        })
        #expect(!text.contains("new tab"))
        #expect(text.contains("split right"))
    }

    @Test
    func styling_is_opt_in() {
        let plain = Tutorial.render(topic: .pinned, styled: false, shortcut: { _ in "⌘T" })
        let styled = Tutorial.render(topic: .pinned, styled: true, shortcut: { _ in "⌘T" })
        #expect(!plain.contains("\u{1B}["))
        #expect(styled.contains("\u{1B}["))
        // Same content either way — the escapes are the only difference.
        #expect(strippingANSI(styled) == plain)
    }

    @Test
    func the_topic_vocabulary_is_the_wire_contract() {
        // These raw values are persisted inside seeded `run:` declarations
        // (and `pinned.yaml`), so renaming a case is a migration.
        #expect(Tutorial.Topic(rawValue: "project") == .project)
        #expect(Tutorial.Topic(rawValue: "pinned") == .pinned)
        #expect(Tutorial.Topic(rawValue: "Project") == nil)
    }

    private func strippingANSI(_ text: String) -> String {
        var out = ""
        var iterator = text.makeIterator()
        var inEscape = false
        while let char = iterator.next() {
            if inEscape {
                if char == "m" { inEscape = false }
                continue
            }
            if char == "\u{1B}" {
                inEscape = true
                continue
            }
            out.append(char)
        }
        return out
    }
}
