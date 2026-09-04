import Foundation

/// A project's optional color tag, drawn as a tint on the sidebar icons of
/// the project and of each of its tabs — and nowhere else, so a row with no
/// icon shows no tag.
///
/// Fixed system colors, not the ghostty palette — the same exception
/// `AgentIcon.brandColor` takes. Deriving them from the user's theme was tried
/// and is a trap: a theme puts any color in any ANSI slot (Rose Pine's "cyan"
/// is a rosy beige), and Rose Pine aliases its bright slots onto its base ones
/// (`9 == 1`, `13 == 5`), collapsing eight tags into six identical-looking.
///
/// `rawValue` is what `projects.json` stores, so renaming a case migrates
/// stored data. An unknown value reads as untagged, never as a wrong color.
enum ProjectColor: String, CaseIterable, Codable {
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case purple
    case pink

    /// Title Case, matching the menu convention.
    var displayName: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .cyan: "Cyan"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        }
    }
}

extension ProjectColor {
    /// The tag for a NEW project: least-used among `existing`, ties broken by
    /// `allCases` order — so the first eight get distinct colors and only the
    /// ninth repeats. `min(by:)` keeps the earliest on a tie, which is what
    /// makes it deterministic.
    static func leastUsed(among existing: [ProjectColor?]) -> ProjectColor {
        var counts: [ProjectColor: Int] = [:]
        for color in allCases {
            counts[color] = 0
        }
        for case let color? in existing {
            counts[color, default: 0] += 1
        }
        return allCases.min { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .red
    }
}
