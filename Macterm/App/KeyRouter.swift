import AppKit

/// Outcome of a responder examining a key event.
enum KeyDisposition {
    /// Consume the event — no further responders, no system dispatch.
    case handled
    /// Pass through — the next responder gets a look, and if none handle it,
    /// the system dispatches normally.
    case passThrough
}

/// Something that can consume keyDown events before they reach the AppKit
/// responder chain. Order matters — earlier-registered responders get first
/// look.
@MainActor
protocol KeyResponder: AnyObject {
    func handle(_ event: NSEvent) -> KeyDisposition
}

/// Routes `NSEvent.keyDown` through an ordered list of responders. Installed
/// once via `NSEvent.addLocalMonitorForEvents`; each responder owns its own
/// slice of hotkeys.
@MainActor
final class KeyRouter {
    static let shared = KeyRouter()

    private var responders: [KeyResponder] = []
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var flagsHandlers: [(NSEvent) -> Void] = []

    /// Start intercepting key events. Safe to call more than once — only the
    /// first call wires up the monitors.
    func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.dispatch(event) == true ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsHandlers.forEach { $0(event) }
            return event
        }
    }

    func register(_ responder: KeyResponder) {
        responders.append(responder)
    }

    /// Flags-changed events don't go through responders (they fire for
    /// every modifier press/release). Instead, interested parties subscribe
    /// here — currently only the tab-cycle commit.
    func registerFlagsHandler(_ handler: @escaping (NSEvent) -> Void) {
        flagsHandlers.append(handler)
    }

    private func dispatch(_ event: NSEvent) -> Bool {
        // One owner per chord: a chord Carbon holds as a system-wide hot key
        // belongs to `GlobalHotkeys`, which will run its action from the
        // hot-key event. Yielding it here is what stops a global-flagged
        // binding firing twice while Macterm is frontmost. Consumed rather
        // than passed through, so the chord never reaches a terminal surface
        // and types instead.
        if GlobalHotkeys.shared.yieldsToCarbon(event) { return true }
        for responder in responders {
            switch responder.handle(event) {
            case .handled: return true
            case .passThrough: continue
            }
        }
        return false
    }
}
