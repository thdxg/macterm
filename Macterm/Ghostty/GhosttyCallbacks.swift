import AppKit
import GhosttyKit

/// Routes libghostty runtime callbacks to the appropriate terminal views.
final class GhosttyCallbacks: @unchecked Sendable {
    func wakeup() {
        DispatchQueue.main.async { GhosttyApp.shared.tick() }
    }

    func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = surfaceView(from: target), let ptr = action.action.set_title.title else { return true }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view.onTitleChange?(title) }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let view = surfaceView(from: target) else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async { view.onSearchStart?(needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.onSearchEnd?() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let view = surfaceView(from: target) else { return true }
            let v = action.action.search_total.total
            let value = v >= 0 ? Int(v) : nil
            DispatchQueue.main.async { view.onSearchTotal?(value) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let view = surfaceView(from: target) else { return true }
            let v = action.action.search_selected.selected
            let value = v >= 0 ? Int(v) : nil
            DispatchQueue.main.async { view.onSearchSelected?(value) }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return true
        default:
            return false
        }
    }

    func readClipboard(ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        text.withCString { ghostty_surface_complete_clipboard_request(surface(from: ud), $0, state, false) }
        return true
    }

    func confirmReadClipboard(ud: UnsafeMutableRawPointer?, content: UnsafePointer<CChar>?, state: UnsafeMutableRawPointer?) {
        guard let content else { return }
        ghostty_surface_complete_clipboard_request(surface(from: ud), content, state, true)
    }

    func writeClipboard(content: UnsafePointer<ghostty_clipboard_content_s>?, len: UInt) {
        guard let content, len > 0 else { return }
        for item in UnsafeBufferPointer(start: content, count: Int(len)) {
            guard let data = item.data, let mime = item.mime, String(cString: mime).hasPrefix("text/plain") else { continue }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: data), forType: .string)
            return
        }
    }

    func closeSurface(ud: UnsafeMutableRawPointer?) {
        guard let ud else { return }
        let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async { view.onProcessExit?() }
    }

    private func surfaceView(from target: ghostty_target_s) -> GhosttyTerminalNSView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttyTerminalNSView>.fromOpaque(ud).takeUnretainedValue()
    }

    private func surface(from ud: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let ud else { return nil }
        return Unmanaged<GhosttyTerminalNSView>.fromOpaque(ud).takeUnretainedValue().surface
    }
}
