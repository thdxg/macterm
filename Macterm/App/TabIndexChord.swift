import Foundation

/// Accumulates Cmd+digit presses into a multi-digit tab number, so a
/// workspace with more than nine tabs is still fully reachable from the
/// keyboard (Cmd+1 then 2 → tab 12, Cmd+1 then 0 → tab 10).
///
/// Selection stays EAGER: the first digit switches immediately, exactly as
/// the single-digit binding always did, and a following digit re-selects the
/// wider number. Deferring the switch until the number is known would be the
/// obvious alternative, but it puts a timeout's worth of latency on Cmd+1 —
/// the overwhelmingly common press — to serve the rare two-digit one.
///
/// A run ends when Command is released (`reset`, driven by the flags monitor)
/// or when `window` passes between digits, so a Cmd+1 now and a Cmd+2 later
/// can never join into 12.
struct TabIndexChord {
    /// Idle gap after which the next digit starts a new number. Backstop for
    /// the Command-release reset — a Command held across unrelated work must
    /// not keep an ancient digit alive.
    static let window: TimeInterval = 1.0

    private var digits: String = ""
    private var lastPress: Date?

    /// Records a digit press and returns the 1-based tab number it addresses,
    /// or nil when no tab can be addressed (a bare `0`, or a digit past the
    /// end of a workspace too small for it).
    ///
    /// A digit that can't extend the current number restarts the run rather
    /// than being dropped — with 5 tabs, Cmd+1 then Cmd+2 selects tab 2 (12
    /// doesn't exist), which is what the single-digit binding did.
    mutating func press(digit: Int, tabCount: Int, now: Date = Date()) -> Int? {
        let isStale = lastPress.map { now.timeIntervalSince($0) > Self.window } ?? true
        if isStale { digits = "" }

        if let extended = Int(digits + String(digit)), extended >= 1, extended <= tabCount {
            digits += String(digit)
            lastPress = now
            return extended
        }
        guard digit >= 1, digit <= tabCount else {
            reset()
            return nil
        }
        digits = String(digit)
        lastPress = now
        return digit
    }

    /// Ends the current run — the next digit starts a fresh number.
    mutating func reset() {
        digits = ""
        lastPress = nil
    }
}
