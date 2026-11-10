import AppKit

/// The question before the first install of the Macterm server on a host
/// (design/006 §5), as a sheet on a terminal window, like the login's
/// questions (`SSHLoginPrompts`). Return installs. Escape continues
/// without the server.
@MainActor
enum RemoteServerConsent {
    static func ask(_ host: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Install the Macterm server on \(host)?")
        alert.informativeText = String(
            localized: """
            Your sessions on this host keep running when the connection stops. \
            Macterm installs its server in ~/.local/share/macterm.
            """,
            comment: "The text of the sheet before the first install of the Macterm server on a remote host. The path stays as it is."
        )
        alert.addButton(withTitle: String(localized: "Install"))
        let withoutServer = alert.addButton(withTitle: String(
            localized: "Continue Without Server",
            comment: "The button that closes the server install sheet with no install."
        ))
        withoutServer.keyEquivalent = "\u{1b}"
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
