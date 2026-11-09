import AppKit

/// The question before the first install of the Macterm server on a host
/// (design/006 §5), as a sheet on a terminal window, like the login's
/// questions (`SSHLoginPrompts`). Return installs; Escape cancels.
@MainActor
enum RemoteServerConsent {
    static func ask(_ request: RemoteServers.ConsentRequest) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Install the Macterm server on \(request.host)?")
        let size = ByteCountFormatter.string(fromByteCount: request.size, countStyle: .file)
        alert.informativeText = String(
            localized: """
            With the server, your sessions on this host keep running when you quit Macterm or the \
            connection stops. Macterm puts it in ~/.local/share/macterm (\(size)). It runs while you \
            have sessions on this host. Without it, your shells end when the connection stops.
            """,
            comment: "The text of the sheet before the first install of the Macterm server on a remote host. The path stays as it is."
        )
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard let window = SSHLoginPrompts.terminalWindow() else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
