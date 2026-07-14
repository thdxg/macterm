import Foundation

/// Human and JSON renderers for control responses. The safe-fail contract:
/// stdout carries ONLY successful command output; every diagnostic goes to
/// stderr so scripted callers can trust what they capture.
enum Output {
    /// Render a successful response: `--json` prints the raw `data` payload;
    /// otherwise the human formatter for the fields present.
    static func render(_ data: ControlData?, asJSON: Bool) throws {
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = try encoder.encode(data ?? ControlData())
            print(String(decoding: payload, as: UTF8.self))
            return
        }
        guard let data else { return }
        if let status = data.status { renderStatus(status) }
        if let projects = data.projects { renderProjects(projects) }
        if let tabs = data.tabs { renderTabs(tabs) }
        if let panes = data.panes { renderPanes(panes) }
        if let sessions = data.sessions { renderSessions(sessions) }
        if let inspect = data.inspect { renderInspect(inspect) }
        if let dump = data.dump { renderDump(dump) }
    }

    private static func renderStatus(_ status: ControlStatusInfo) {
        var line = "Macterm \(status.version) (pid \(status.pid))"
        if let project = status.activeProject {
            line += " — active project: \(project)"
        }
        print(line)
    }

    private static func renderProjects(_ projects: [ControlProjectInfo]) {
        let rows = projects.enumerated().map { index, project -> [String] in
            let tabs = project.tabCount.map { "\($0) tab\($0 == 1 ? "" : "s")" } ?? "—"
            return [
                "project:\(index + 1)",
                project.active ? "*" : " ",
                project.name,
                project.loaded ? tabs : "not loaded",
                project.path,
            ]
        }
        printColumns(rows)
    }

    private static func renderTabs(_ tabs: [ControlTabInfo]) {
        let rows = tabs.map { tab -> [String] in
            [
                "tab:\(tab.index)",
                tab.active ? "*" : " ",
                tab.title,
                "\(tab.paneCount) pane\(tab.paneCount == 1 ? "" : "s")",
            ]
        }
        printColumns(rows)
    }

    private static func renderPanes(_ panes: [ControlPaneInfo]) {
        let rows = panes.map { pane -> [String] in
            [
                "tab:\(pane.tabIndex)",
                "pane:\(pane.index)",
                pane.focused ? "*" : " ",
                pane.session,
                pane.process ?? "-",
                pane.cwd ?? "-",
            ]
        }
        printColumns(rows)
    }

    private static func renderSessions(_ sessions: [ControlSessionInfo]) {
        let rows = sessions.map { session -> [String] in
            let clients = session.clients.map(String.init) ?? "?"
            return [
                session.name,
                "clients:\(clients)",
                session.leaderPID.map { "pid:\($0)" } ?? "pid:-",
                session.paneID != nil ? "attached-pane" : "orphan",
            ]
        }
        printColumns(rows)
    }

    private static func renderInspect(_ i: ControlPaneInspect) {
        func opt(_ v: (some Any)?) -> String {
            v.map { "\($0)" } ?? "-"
        }
        let scrollback = (i.scrollbackTotal != nil)
            ? "\(opt(i.scrollbackTotal)) total, \(opt(i.scrollbackOffset)) offset, \(opt(i.scrollbackLen)) len"
            : "-"
        let fg = i.foregroundPID.map { pid in
            let argv = i.foregroundArgv?.joined(separator: " ") ?? ""
            return argv.isEmpty ? "\(pid)" : "\(pid) (\(argv))"
        } ?? "-"
        let rows: [[String]] = [
            ["session", i.session],
            ["grid", "\(i.cols)×\(i.rows)"],
            ["cell px", "\(i.cellWidthPx)×\(i.cellHeightPx)"],
            ["surface px", "\(i.widthPx)×\(i.heightPx)"],
            ["scrollback", scrollback],
            ["alt-screen", opt(i.altScreen)],
            ["content scale", opt(i.contentScale)],
            ["foreground", fg],
            ["process exited", "\(i.processExited)"],
            ["needs confirm quit", "\(i.needsConfirmQuit)"],
        ]
        printColumns(rows)
    }

    /// Print dumped terminal text verbatim to stdout (pipeline-friendly — the
    /// whole point is capturing it), with no framing. Ensure exactly one
    /// trailing newline for non-empty text so the shell prompt lands cleanly on
    /// its own line without appending a blank one to already-terminated text.
    private static func renderDump(_ d: ControlPaneDump) {
        if d.text.isEmpty {
            return
        }
        print(d.text, terminator: d.text.hasSuffix("\n") ? "" : "\n")
    }

    /// Left-align columns to the widest cell in each.
    private static func printColumns(_ rows: [[String]]) {
        guard !rows.isEmpty else { return }
        let columnCount = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columnCount)
        for row in rows {
            for (i, cell) in row.enumerated() {
                widths[i] = max(widths[i], cell.count)
            }
        }
        for row in rows {
            let line = row.enumerated()
                .map { i, cell in i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
            print(line)
        }
    }

    /// Print an error to stderr, with its recovery hint when present.
    static func printError(_ message: String, action: String? = nil) {
        FileHandle.standardError.write(Data("macterm: \(message)\n".utf8))
        if let action {
            FileHandle.standardError.write(Data("  hint: \(action)\n".utf8))
        }
    }
}
