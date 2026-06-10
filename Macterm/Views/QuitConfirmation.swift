import AppKit
import SwiftUI

/// One row in the "running processes" table shown when the user tries to quit
/// while panes still have foreground processes.
struct RunningProcessRow: Identifiable, Hashable {
    let id = UUID()
    let projectName: String
    let processName: String
}

/// SwiftUI table-backed confirmation shown in place of the old `NSAlert` when
/// the user quits with running processes. Uses native `Table` so column headers,
/// sorting, and row selection match the rest of macOS.
struct QuitConfirmationView: View {
    let rows: [RunningProcessRow]
    let onQuit: () -> Void
    let onCancel: () -> Void

    @State
    private var sortOrder: [KeyPathComparator<RunningProcessRow>] = [
        KeyPathComparator(\RunningProcessRow.projectName),
        KeyPathComparator(\RunningProcessRow.processName),
    ]

    private var sortedRows: [RunningProcessRow] {
        rows.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quit \(appDisplayName)?")
                        .font(.system(size: 13, weight: .bold))
                    Text(rows.count == 1
                        ? "1 process is still running. Quit anyway?"
                        : "\(rows.count) processes are still running. Quit anyway?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Table(sortedRows, sortOrder: $sortOrder) {
                TableColumn("Project", value: \.projectName)
                    .width(min: 120, ideal: 180)
                TableColumn("Process", value: \.processName)
                    .width(min: 120, ideal: 180)
            }
            .frame(minHeight: 180)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Quit", action: onQuit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
    }
}

/// Runs `QuitConfirmationView` as a modal window. Returns `true` when the user
/// chose Quit, `false` for Cancel. Called from `applicationShouldTerminate`,
/// which needs a synchronous answer.
@MainActor
enum QuitConfirmation {
    static func runModal(rows: [RunningProcessRow]) -> Bool {
        var result = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Quit \(appDisplayName)"
        window.isReleasedWhenClosed = false
        window.center()

        let view = QuitConfirmationView(
            rows: rows,
            onQuit: {
                result = true
                NSApp.stopModal()
            },
            onCancel: {
                result = false
                NSApp.stopModal()
            }
        )
        window.contentView = NSHostingView(rootView: view)

        NSApp.runModal(for: window)
        window.orderOut(nil)
        return result
    }
}
