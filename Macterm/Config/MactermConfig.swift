import Foundation

@MainActor @Observable
final class MactermConfig {
    static let shared = MactermConfig()

    let ghosttyConfigURL: URL

    private init() {
        let dir = FileStorage.appSupportDirectory()
        ghosttyConfigURL = dir.appendingPathComponent("ghostty.conf")
        seedIfNeeded()
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
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        return trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
            .description
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

        try? Data(content.utf8).write(to: ghosttyConfigURL, options: .atomic)
    }
}
