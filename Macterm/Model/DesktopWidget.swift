import CoreGraphics
import Foundation

/// The geometry macOS gives its own desktop widgets, so a Macterm widget sits
/// among them as one of the family.
///
/// Measured, not guessed: chronod logs the `CHSWidgetMetricsSpecification` the
/// widget host hands it (`log show --predicate 'process == "chronod"'`, the
/// entries carrying `cornerRadius`), and on macOS 27 every family has a
/// 27.88pt corner and 18pt content margins, at 164 / 344 / 704pt edges. The
/// corner is Apple's continuous curve (`ContainerRelativeShape`), not a
/// circular arc. Macterm cannot ship a real WidgetKit widget — chronod purges
/// the descriptors of an extension signed without an Apple team, which is how
/// Macterm is signed — and WidgetKit could not host a live terminal anyway,
/// so this is the shape of one, drawn by a window of our own.
enum DesktopWidgetMetrics {
    static let cornerRadius: CGFloat = 27.88

    /// Inset of the terminal from the widget's edge. The HIG gives 16pt as
    /// the standard margin, 11pt as the tight one, and notes that desktop
    /// widgets on the Mac use smaller margins than elsewhere (chronod's 18 is
    /// Notification Center's). A terminal is dense content, so the tight
    /// margin — which still keeps the first cell well clear of the corner
    /// curve.
    static let contentMargin: CGFloat = 11
}

/// A widget's size in grid cells. The system's four families are all spans
/// of one grid — a 164pt cell with a 16pt gap is exactly what makes Medium
/// 344 wide and Extra Large 704 — so a span covers them and everything a
/// resize snaps to in between.
struct DesktopWidgetSpan: Codable, Equatable, Hashable, CustomStringConvertible {
    var columns: Int
    var rows: Int

    init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    /// `3x2` — the CLI's spelling of a span that isn't a family.
    init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]), columns >= 1, rows >= 1 else {
            return nil
        }
        self.init(columns: columns, rows: rows)
    }

    var description: String { "\(columns)x\(rows)" }
}

/// The system widgets' size families, as the right-click menu offers them:
/// the same names at the same dimensions.
enum DesktopWidgetSize: String, CaseIterable, Codable {
    case small
    case medium
    case large
    case extraLarge = "extra-large"

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    var span: DesktopWidgetSpan {
        switch self {
        case .small: DesktopWidgetSpan(columns: 1, rows: 1)
        case .medium: DesktopWidgetSpan(columns: 2, rows: 1)
        case .large: DesktopWidgetSpan(columns: 2, rows: 2)
        case .extraLarge: DesktopWidgetSpan(columns: 4, rows: 2)
        }
    }

    /// The family a span is, if any.
    init?(span: DesktopWidgetSpan) {
        guard let match = Self.allCases.first(where: { $0.span == span }) else { return nil }
        self = match
    }

    /// A family name or a `CxR` span.
    static func parseSpan(_ text: String) -> DesktopWidgetSpan? {
        Self(rawValue: text.lowercased())?.span ?? DesktopWidgetSpan(parsing: text)
    }

    /// The family name, else `CxR`.
    static func name(of span: DesktopWidgetSpan) -> String {
        Self(span: span)?.rawValue ?? span.description
    }

    /// The menu's and Settings' label for a span.
    static func title(of span: DesktopWidgetSpan) -> String {
        Self(span: span)?.title ?? "\(span.columns) × \(span.rows)"
    }
}

/// Stored by raw value (Settings → Widgets' default size). Declared here, not
/// beside the other preference enums: `PreferenceValue` needs `Sendable`,
/// which only this file can conform the enum to.
extension DesktopWidgetSize: PreferenceValue {}

/// One terminal on the desktop: a single pane whose zmx session outlives a
/// quit exactly like a pinned tab's, placed where the user left it.
///
/// A widget is one pane by design — the widget is the unit the user places
/// and sizes, so there is nothing a split inside it would add that a second
/// widget doesn't. The pane still lives in a `TerminalTab` because that is
/// what the snapshot, the split-tree views and every pane-walking helper
/// already speak.
///
/// Whether a widget is being edited is not the widget's to hold: at most one
/// is at a time, and none after a launch, so it is `AppState`'s
/// (`editingDesktopWidgetID`) and never persisted.
@MainActor @Observable
final class DesktopWidget: Identifiable {
    /// The routing id of every widget's panes — the counterpart of
    /// `QuickTerminalService.projectID`, and fresh per launch for the same
    /// reason: widgets are restored by the caller that knows they are
    /// widgets, so nothing may key on a persisted value.
    static let projectID = UUID()

    let id: UUID
    private(set) var tab: TerminalTab
    /// Optional label (Settings, `widget list`, `widgets.yaml`'s matching).
    var name: String?
    var span: DesktopWidgetSpan
    /// The widget's top-left corner in global AppKit screen coordinates
    /// (y grows upward). Top-left rather than AppKit's bottom-left origin
    /// because that is the corner the grid is laid out from and the one that
    /// stays put when a preset size is picked.
    var topLeft: CGPoint
    /// The respawn recipe (`widgets.yaml`'s `run:`/`cwd:`): typed into and
    /// started in a fresh shell whenever the widget starts a session — at
    /// creation, when its shell exits and it starts over, and at a launch
    /// that finds its session gone. Never on a reattach, whose shell already
    /// ran it. Refreshed from what the pane is actually running
    /// (`AppState.refreshDesktopWidgetRecipes`), the way a pinned tab's is.
    var command: String?
    var cwd: String?

    init(
        id: UUID = UUID(),
        tab: TerminalTab? = nil,
        name: String? = nil,
        span: DesktopWidgetSpan,
        topLeft: CGPoint,
        command: String? = nil,
        cwd: String? = nil
    ) {
        self.id = id
        self.name = name
        self.span = span
        self.topLeft = topLeft
        self.command = command
        self.cwd = cwd
        self.tab = tab ?? Self.freshTab(command: command, cwd: cwd)
    }

    /// The widget's one pane.
    var pane: Pane? {
        tab.splitRoot.allPanes().first
    }

    /// The widget's frame in AppKit's bottom-left-origin screen space.
    var frame: CGRect {
        DesktopWidgetGrid.frame(topLeft: topLeft, span: span)
    }

    /// Replace the pane with a fresh shell in a new session — what happens
    /// when the widget's shell exits. The caller has already disposed of the
    /// old pane (its surface and session).
    func startOver() {
        tab = Self.freshTab(command: command, cwd: cwd)
    }

    private static func freshTab(command: String?, cwd: String?) -> TerminalTab {
        // A declared directory that no longer exists (a hand-edit, a deleted
        // checkout) starts the shell at home rather than failing its `cd`.
        var isDirectory: ObjCBool = false
        let declared = cwd.map { ($0 as NSString).expandingTildeInPath }
        let directory = declared.flatMap {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil
        } ?? NSHomeDirectory()
        return TerminalTab(
            projectPath: directory,
            projectID: projectID,
            sessionSlug: ZmxSessionName.desktopWidgetSlug,
            command: command
        )
    }
}

/// A screen widgets can sit on: its name (`widgets.yaml`'s `display:`) and
/// the part of it windows may use.
struct DesktopScreen: Equatable {
    let name: String
    let visibleFrame: CGRect
}

/// The virtual grid widgets snap to, one per screen: 164pt cells with 16pt
/// gaps (the system widgets' own module), laid out from the screen's
/// visible top-left corner with a gap's inset. Pure, so every snapping and
/// placement rule is unit-testable.
enum DesktopWidgetGrid {
    static let cell: CGFloat = 164
    static let gap: CGFloat = 16
    static var pitch: CGFloat { cell + gap }

    static func dimensions(of span: DesktopWidgetSpan) -> CGSize {
        CGSize(
            width: CGFloat(span.columns) * cell + CGFloat(span.columns - 1) * gap,
            height: CGFloat(span.rows) * cell + CGFloat(span.rows - 1) * gap
        )
    }

    static func frame(topLeft: CGPoint, span: DesktopWidgetSpan) -> CGRect {
        let size = dimensions(of: span)
        return CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }

    /// The grid's first cell's top-left corner on a screen.
    static func origin(in visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.minX + gap, y: visibleFrame.maxY - gap)
    }

    /// Whole cells that fit across and down a screen (at least one each).
    static func capacity(of visibleFrame: CGRect) -> DesktopWidgetSpan {
        func fit(_ length: CGFloat) -> Int {
            max(1, Int(((length - 2 * gap - cell) / pitch).rounded(.down)) + 1)
        }
        return DesktopWidgetSpan(columns: fit(visibleFrame.width), rows: fit(visibleFrame.height))
    }

    /// A cell position (column, row from the top) → its top-left point.
    static func topLeft(column: Int, row: Int, in visibleFrame: CGRect) -> CGPoint {
        let origin = origin(in: visibleFrame)
        return CGPoint(x: origin.x + CGFloat(column) * pitch, y: origin.y - CGFloat(row) * pitch)
    }

    /// Where a widget the user just dragged or resized to `frame` settles:
    /// the nearest span and cell, kept on the screen, and moved to the
    /// nearest free cell when that one would overlap a widget in `occupied`
    /// — the system's widgets never stack either.
    static func snap(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        avoiding occupied: [CGRect]
    ) -> (topLeft: CGPoint, span: DesktopWidgetSpan) {
        let capacity = capacity(of: visibleFrame)
        let span = DesktopWidgetSpan(
            columns: min(capacity.columns, Int(((frame.width + gap) / pitch).rounded())),
            rows: min(capacity.rows, Int(((frame.height + gap) / pitch).rounded()))
        )
        let origin = origin(in: visibleFrame)
        let column = Int(((frame.minX - origin.x) / pitch).rounded())
        let row = Int(((origin.y - frame.maxY) / pitch).rounded())
        return (nearestFree(column: column, row: row, span: span, in: visibleFrame, avoiding: occupied), span)
    }

    /// Where a new widget of `span` goes: the free cell nearest the middle
    /// of the screen.
    static func centered(_ span: DesktopWidgetSpan, in visibleFrame: CGRect, avoiding occupied: [CGRect]) -> CGPoint {
        let capacity = capacity(of: visibleFrame)
        let fitted = DesktopWidgetSpan(columns: min(span.columns, capacity.columns), rows: min(span.rows, capacity.rows))
        let column = Int((CGFloat(capacity.columns - fitted.columns) / 2).rounded(.down))
        let row = Int((CGFloat(capacity.rows - fitted.rows) / 2).rounded(.down))
        return nearestFree(column: column, row: row, span: fitted, in: visibleFrame, avoiding: occupied)
    }

    /// The free cell closest to (`column`, `row`) that holds `span` on the
    /// screen, searched in rings of growing distance; the clamped cell itself
    /// when nothing is free.
    private static func nearestFree(
        column: Int,
        row: Int,
        span: DesktopWidgetSpan,
        in visibleFrame: CGRect,
        avoiding occupied: [CGRect]
    ) -> CGPoint {
        let capacity = capacity(of: visibleFrame)
        let maxColumn = max(0, capacity.columns - span.columns)
        let maxRow = max(0, capacity.rows - span.rows)
        let start = (min(max(column, 0), maxColumn), min(max(row, 0), maxRow))
        func isFree(_ c: Int, _ r: Int) -> Bool {
            let candidate = frame(topLeft: topLeft(column: c, row: r, in: visibleFrame), span: span)
            // Touching edges is fine: the gap is inside the cell pitch.
            return !occupied.contains { $0.insetBy(dx: 1, dy: 1).intersects(candidate) }
        }
        let reach = max(maxColumn, maxRow)
        for distance in 0 ... reach {
            var best: (cell: (Int, Int), score: Int)?
            for c in max(0, start.0 - distance) ... min(maxColumn, start.0 + distance) {
                for r in max(0, start.1 - distance) ... min(maxRow, start.1 + distance)
                    where max(abs(c - start.0), abs(r - start.1)) == distance && isFree(c, r)
                {
                    // Within a ring, prefer the cell closest as the crow flies.
                    let score = (c - start.0) * (c - start.0) + (r - start.1) * (r - start.1)
                    if best.map({ score < $0.score }) ?? true { best = ((c, r), score) }
                }
            }
            if let best { return topLeft(column: best.cell.0, row: best.cell.1, in: visibleFrame) }
        }
        return topLeft(column: start.0, row: start.1, in: visibleFrame)
    }

    /// The least of a restored widget that must land on some screen for its
    /// saved spot to be kept — enough to see it.
    static let minVisible: CGFloat = 60

    /// Whether a saved frame still has `minVisible` points on some screen —
    /// false after the display it was on went away, in which case the widget
    /// is placed afresh rather than restored somewhere nobody can reach.
    static func isReachable(_ frame: CGRect, on visibleFrames: [CGRect]) -> Bool {
        visibleFrames.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width >= minVisible && overlap.height >= minVisible
        }
    }

    /// The screen a frame belongs to: the one holding its center, else the
    /// one it overlaps most, else the first.
    static func screen(for frame: CGRect, among visibleFrames: [CGRect]) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let holding = visibleFrames.first(where: { $0.contains(center) }) { return holding }
        return visibleFrames.max { lhs, rhs in
            let a = lhs.intersection(frame), b = rhs.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
    }
}
