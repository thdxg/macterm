import Foundation

@MainActor @Observable
final class MactermConfig {
    static let shared = MactermConfig()

    let ghosttyConfigURL: URL

    private init() {
        let dir = FileStorage.appSupportDirectory()
        ghosttyConfigURL = dir.appendingPathComponent("ghostty.conf")
        seedIfNeeded()
        // Ensure option-as-alt is set for pre-existing installs that were
        // seeded before this default became part of Macterm.
        if value(for: "macos-option-as-alt") == nil {
            updateValue("macos-option-as-alt", value: "true")
        }
    }

    var ghosttyConfigPath: String { ghosttyConfigURL.path }

    func readConfig() -> String {
        (try? String(contentsOf: ghosttyConfigURL, encoding: .utf8)) ?? ""
    }

    func setManagedWindowPaddingTop(_ value: Int) {
        updateValue("window-padding-top", value: String(max(0, value)))
        updateValue("window-padding-balance", value: "false")
    }

    func updateValue(_ key: String, value: String) {
        var lines = readConfig().components(separatedBy: "\n")
        let entry = "\(key) = \(value)"
        if let index = findLine(for: key, in: lines) {
            lines[index] = entry
        } else {
            lines.insert(entry, at: 0)
        }
        try? Data(lines.joined(separator: "\n").utf8).write(to: ghosttyConfigURL, options: .atomic)
    }

    func removeValue(_ key: String) {
        var lines = readConfig().components(separatedBy: "\n")
        if let index = findLine(for: key, in: lines) {
            lines.remove(at: index)
            try? Data(lines.joined(separator: "\n").utf8).write(to: ghosttyConfigURL, options: .atomic)
        }
    }

    func value(for key: String) -> String? {
        let lines = readConfig().components(separatedBy: .newlines)
        guard let index = findLine(for: key, in: lines) else { return nil }
        let line = lines[index]
        guard let eqIndex = line.firstIndex(of: "=") else { return nil }
        return String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
    }

    private func findLine(for key: String, in lines: [String]) -> Int? {
        lines.firstIndex { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key) else { return false }
            let rest = t.dropFirst(key.count)
            guard let next = rest.first else { return false }
            return next == "=" || next.isWhitespace
        }
    }

    private func seedIfNeeded() {
        guard !FileManager.default.fileExists(atPath: ghosttyConfigURL.path) else { return }
        let systemConfig = NSHomeDirectory() + "/.config/ghostty/config"
        var content = ""
        if FileManager.default.fileExists(atPath: systemConfig),
           let sysContent = try? String(contentsOfFile: systemConfig, encoding: .utf8)
        {
            content = sysContent
        } else {
            content = "scrollbar = system\n"
        }
        // Option-as-Alt defaults on so shells/editors receive the Alt
        // modifier for word navigation etc. Users can opt out in
        // Settings → Appearance → Input or by editing the config.
        if !content.contains("macos-option-as-alt") {
            content += (content.hasSuffix("\n") ? "" : "\n") + "macos-option-as-alt = true\n"
        }

        try? Data(content.utf8).write(to: ghosttyConfigURL, options: .atomic)
    }
}
