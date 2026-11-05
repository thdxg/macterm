import Foundation

/// One finished command in a project's memory.
///
/// A structured record, never a copy of the scrollback: the command line,
/// where it ran, how it ended, and — for a failure only — a short tail of its
/// output. Every text field has gone through `MemoryRedaction`.
struct MemoryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The command line as the user typed it, or nil when the screen did not
    /// show it (`CommandRecordExtractor`). A record with no command still says
    /// when something ran and how it ended.
    var command: String?
    /// The shell's working directory when the command finished (OSC 7).
    var directory: String?
    /// The exit code, or nil when the shell reported none.
    var exitCode: Int?
    var finishedAt: Date
    /// Seconds.
    var duration: TimeInterval
    /// The last lines of a failed command's output, redacted and capped
    /// (`MemoryEntry.failureTailLines`, `failureTailBytes`). nil for a success.
    var failureTail: String?

    static let failureTailLines = 20
    static let failureTailBytes = 2048

    var startedAt: Date { finishedAt.addingTimeInterval(-duration) }

    enum Outcome: String, Codable {
        case success
        case failure
        case unknown
    }

    var outcome: Outcome {
        switch exitCode {
        case nil: .unknown
        case 0: .success
        default: .failure
        }
    }

    /// The last `failureTailLines` lines of `output`, at most
    /// `failureTailBytes` bytes, with trailing blank lines removed.
    static func tail(of output: String) -> String? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        var tail = lines.suffix(failureTailLines).joined(separator: "\n")
        while tail.utf8.count > failureTailBytes, let newline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: newline)...])
        }
        if tail.utf8.count > failureTailBytes {
            tail = String(decoding: tail.utf8.suffix(failureTailBytes), as: UTF8.self)
        }
        return tail.isEmpty ? nil : tail
    }
}

/// A project's memory file: `<App Support>/Memory/<project id>.json`.
struct MemoryFile: Codable, Equatable {
    static let currentVersion = 1
    var version = MemoryFile.currentVersion
    /// Oldest first.
    var entries: [MemoryEntry] = []
    /// The last summary of the on-device model, kept with the records so
    /// that a relaunch shows it at once. Absent in a file from before it.
    var summary: StoredSummary?
}

/// A summary that the on-device model wrote (`ProjectMemorySummarizer`),
/// with the key of the records it is for (`ProjectMemoryDigest.key`).
struct StoredSummary: Codable, Equatable {
    var key: String
    var text: String
    var writtenAt: Date
}
