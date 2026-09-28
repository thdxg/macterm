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

    /// What a new widget starts as, three cells a side — a terminal wants
    /// rows as much as columns, which none of the system's wide families give.
    static let initial = DesktopWidgetSpan(columns: 3, rows: 3)

    /// `3x2` — how the CLI and `widgets.yaml` spell a span.
    init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]), columns >= 1, rows >= 1 else {
            return nil
        }
        self.init(columns: columns, rows: rows)
    }

    var description: String { "\(columns)x\(rows)" }
}

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
    /// stays put when a widget is resized.
    var topLeft: CGPoint
    /// The respawn recipe (`widgets.yaml`'s `run:`/`cwd:`): typed into and
    /// started in a fresh shell whenever the widget starts a session — at
    /// creation, when its shell exits and it starts over, and at a launch
    /// that finds its session gone. Never on a reattach, whose shell already
    /// ran it. Refreshed from what the pane is actually running
    /// (`AppState.refreshDesktopWidgetRecipes`), the way a pinned tab's is.
    var command: String?
    var cwd: String?
    /// Where the user put the widget on each display and resolution it has
    /// been on, most recent last (`DesktopWidgetPlacement`). `topLeft` is
    /// where it is now, which after a display change can be a projection of
    /// one of these rather than one of them.
    var placements: [DesktopWidgetPlacement]

    init(
        id: UUID = UUID(),
        tab: TerminalTab? = nil,
        name: String? = nil,
        span: DesktopWidgetSpan,
        topLeft: CGPoint,
        command: String? = nil,
        cwd: String? = nil,
        placements: [DesktopWidgetPlacement] = []
    ) {
        self.id = id
        self.name = name
        self.span = span
        self.topLeft = topLeft
        self.command = command
        self.cwd = cwd
        self.placements = placements
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

/// A screen widgets can sit on: its name (`widgets.yaml`'s `display:`), the
/// part of it windows may use, and its resolution.
struct DesktopScreen: Equatable {
    let name: String
    let visibleFrame: CGRect
    /// The whole display in points, menu bar included. With the name, what a
    /// placement is remembered by — the whole frame rather than the visible
    /// one, so showing or hiding the Dock isn't a new resolution.
    let resolution: CGSize

    init(name: String, visibleFrame: CGRect, resolution: CGSize? = nil) {
        self.name = name
        self.visibleFrame = visibleFrame
        self.resolution = resolution ?? visibleFrame.size
    }
}

/// Where the user put a widget on one display at one resolution: its top-left
/// corner measured from the display's visible top-left, rightward and down.
///
/// Notification Center's own model. It keeps the system widgets' layout per
/// display and per resolution (it logs `Writing desktop widget placement
/// storage to disk: [number: 0, resolutions: [size: 3008.0x1662.0, groups:
/// […]]]`), and on a display it has no layout for it PROJECTS the latest one —
/// the same offsets from the top-left corner (logged as `Desktop Widget
/// Placement projection published`) — without saving anything. Only the
/// user moving a widget records a layout there, so a trip to the laptop
/// never costs the external display its arrangement. Measured going from a
/// 3008×1692 display to a 1920×1243 one, 2026-09-28.
struct DesktopWidgetPlacement: Codable, Equatable {
    var display: String
    var width: Double
    var height: Double
    var offsetX: Double
    var offsetY: Double

    init(display: String, resolution: CGSize, offset: CGPoint) {
        self.display = display
        width = resolution.width
        height = resolution.height
        offsetX = offset.x
        offsetY = offset.y
    }

    /// Where a widget whose top-left is at `topLeft` sits on `screen`.
    init(topLeft: CGPoint, on screen: DesktopScreen) {
        self.init(
            display: screen.name,
            resolution: screen.resolution,
            offset: CGPoint(x: topLeft.x - screen.visibleFrame.minX, y: screen.visibleFrame.maxY - topLeft.y)
        )
    }

    var resolution: CGSize { CGSize(width: width, height: height) }

    /// Whether this is the placement for `screen` as it is now.
    func isFor(_ screen: DesktopScreen) -> Bool {
        display == screen.name && resolution == screen.resolution
    }

    /// The same offset from `screen`'s visible top-left.
    func topLeft(on screen: DesktopScreen) -> CGPoint {
        CGPoint(x: screen.visibleFrame.minX + offsetX, y: screen.visibleFrame.maxY - offsetY)
    }

    /// The default-lattice cell the offset is nearest — how `widgets.yaml`
    /// declares it (`DesktopWidgetGrid.origin`).
    var column: Int {
        Int(((offsetX - DesktopWidgetGrid.edgeInset.width) / DesktopWidgetGrid.pitch).rounded())
    }

    var row: Int {
        Int(((offsetY - DesktopWidgetGrid.edgeInset.height) / DesktopWidgetGrid.pitch).rounded())
    }

    /// How many are kept per widget: plenty for a desk, a laptop and a
    /// projector at a couple of resolutions each.
    static let limit = 8

    /// `placements` with `placement` as the most recent, replacing any for the
    /// same display and resolution.
    static func recording(_ placement: Self, into placements: [Self]) -> [Self] {
        let kept = placements.filter { $0.display != placement.display || $0.resolution != placement.resolution }
        return Array((kept + [placement]).suffix(limit))
    }

    /// Where `resolve` puts a widget. `exact` is false for a projection.
    struct Resolved: Equatable {
        let screen: DesktopScreen
        let topLeft: CGPoint
        let exact: Bool
    }

    /// Where a widget with `placements` goes on `screens` (primary first):
    /// the display it was last put on, else the primary one; there, exactly
    /// where it was put at this resolution, else the latest placement's
    /// offsets projected onto it — kept on the screen, the widget's `size`
    /// permitting. Nothing records a projection.
    static func resolve(
        _ placements: [Self],
        size: CGSize,
        on screens: [DesktopScreen]
    ) -> Resolved? {
        guard let latest = placements.last, let primary = screens.first else { return nil }
        let screen = screens.first { $0.name == latest.display } ?? primary
        if let exact = placements.last(where: { $0.isFor(screen) }) {
            return Resolved(screen: screen, topLeft: exact.topLeft(on: screen), exact: true)
        }
        // A display's own most recent layout projects better than another
        // display's: it is the shape the user chose for this screen.
        let source = placements.last { $0.display == screen.name } ?? latest
        let projected = source.topLeft(on: screen)
        let visible = screen.visibleFrame
        let topLeft = CGPoint(
            x: max(visible.minX, min(projected.x, visible.maxX - size.width)),
            y: min(visible.maxY, max(projected.y, visible.minY + size.height))
        )
        return Resolved(screen: screen, topLeft: topLeft, exact: false)
    }
}

/// The lattices widgets snap to. A lattice is the system widgets' module —
/// 164pt cells, 16pt gaps, so a 180pt pitch — repeating from an origin, and
/// there is one per GROUP of widgets, not one per screen: that is how macOS
/// lays out its own (`NativeDesktopWidgets`). A widget let go near another
/// widget, native or ours, joins that widget's lattice; one let go in open
/// space uses the screen's default lattice, whose inset is where macOS puts
/// a group against the top-left corner. Pure, so every snapping and
/// placement rule is unit-testable.
enum DesktopWidgetGrid {
    static let cell: CGFloat = 164
    static let gap: CGFloat = 16
    static var pitch: CGFloat { cell + gap }

    /// The default lattice's inset from the screen's visible top-left.
    /// Measured: Notification Center put a group against that corner at
    /// window origin (18, 25) from the visible top-left, and a widget's
    /// window is the widget plus `NativeDesktopWidgets.windowInset` (8pt).
    static let edgeInset = CGSize(width: 26, height: 33)

    /// How near a neighbour has to be for a widget to join its lattice — a
    /// cell's pitch, gap to gap.
    static var joinDistance: CGFloat { pitch }

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

    /// The top-left of the default lattice's first cell on a screen — what
    /// `widgets.yaml`'s `column`/`row` count from.
    static func origin(in visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.minX + edgeInset.width, y: visibleFrame.maxY - edgeInset.height)
    }

    /// A default-lattice cell (column, row from the top) → its top-left.
    static func topLeft(column: Int, row: Int, in visibleFrame: CGRect) -> CGPoint {
        topLeft(column: column, row: row, lattice: origin(in: visibleFrame))
    }

    static func topLeft(column: Int, row: Int, lattice: CGPoint) -> CGPoint {
        CGPoint(x: lattice.x + CGFloat(column) * pitch, y: lattice.y - CGFloat(row) * pitch)
    }

    /// The lattice a widget at `frame` belongs to: that of the nearest of
    /// `neighbours` within `joinDistance` (a neighbour's own top-left is on
    /// its lattice), else the screen's default one.
    static func lattice(for frame: CGRect, in visibleFrame: CGRect, neighbours: [CGRect]) -> CGPoint {
        let nearest = neighbours
            .filter { visibleFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .map { (frame: $0, distance: distance(frame, $0)) }
            .filter { $0.distance <= joinDistance }
            .min { $0.distance < $1.distance }
        return nearest.map { CGPoint(x: $0.frame.minX, y: $0.frame.maxY) } ?? origin(in: visibleFrame)
    }

    /// Where a widget the user just dragged or resized to `frame` settles:
    /// the nearest span and cell of the lattice it belongs to, kept on the
    /// screen, and moved to the nearest free cell when that one would
    /// overlap a widget in `occupied` — the system's widgets never stack.
    /// `occupied` doubles as the neighbours whose lattice it may join.
    static func snap(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        avoiding occupied: [CGRect]
    ) -> (topLeft: CGPoint, span: DesktopWidgetSpan) {
        let lattice = lattice(for: frame, in: visibleFrame, neighbours: occupied)
        let span = fitted(
            DesktopWidgetSpan(
                columns: Int(((frame.width + gap) / pitch).rounded()),
                rows: Int(((frame.height + gap) / pitch).rounded())
            ),
            lattice: lattice,
            in: visibleFrame
        )
        let column = Int(((frame.minX - lattice.x) / pitch).rounded())
        let row = Int(((lattice.y - frame.maxY) / pitch).rounded())
        let topLeft = nearestFree((column, row), span: span, lattice: lattice, in: visibleFrame, avoiding: occupied)
        return (topLeft, span)
    }

    /// Where a new widget of `span` goes: the exact middle of the screen, off
    /// the lattice — the lattice's cells are a pitch apart, so its cell
    /// nearest the middle was visibly off-center — and onto the lattice at
    /// the first move or resize, like any widget. When the middle would
    /// overlap a widget in `occupied`, the free default-lattice cell nearest
    /// it instead, since widgets never stack.
    static func centered(_ span: DesktopWidgetSpan, in visibleFrame: CGRect, avoiding occupied: [CGRect]) -> CGPoint {
        let lattice = origin(in: visibleFrame)
        let span = fitted(span, lattice: lattice, in: visibleFrame)
        let size = dimensions(of: span)
        let middle = CGPoint(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: (visibleFrame.midY + size.height / 2).rounded()
        )
        let candidate = frame(topLeft: middle, span: span)
        if !occupied.contains(where: { $0.insetBy(dx: 1, dy: 1).intersects(candidate) }) {
            return middle
        }
        let columns = positions(from: lattice.x, length: size.width, lower: visibleFrame.minX, upper: visibleFrame.maxX)
        let rows = rowPositions(from: lattice.y, length: size.height, in: visibleFrame)
        let column = columns.map { ($0.lowerBound + $0.upperBound) / 2 } ?? 0
        let row = rows.map { ($0.lowerBound + $0.upperBound) / 2 } ?? 0
        return nearestFree((column, row), span: span, lattice: lattice, in: visibleFrame, avoiding: occupied)
    }

    /// The largest span no bigger than `span` that fits on the screen.
    private static func fitted(_ span: DesktopWidgetSpan, lattice: CGPoint, in visibleFrame: CGRect) -> DesktopWidgetSpan {
        var columns = max(1, span.columns)
        var rows = max(1, span.rows)
        while columns > 1, positions(
            from: lattice.x,
            length: dimensions(of: DesktopWidgetSpan(columns: columns, rows: 1)).width,
            lower: visibleFrame.minX,
            upper: visibleFrame.maxX
        ) == nil {
            columns -= 1
        }
        while rows > 1, rowPositions(
            from: lattice.y,
            length: dimensions(of: DesktopWidgetSpan(columns: 1, rows: rows)).height,
            in: visibleFrame
        ) == nil {
            rows -= 1
        }
        return DesktopWidgetSpan(columns: columns, rows: rows)
    }

    /// Lattice columns whose cell of `length` fits between `lower` and
    /// `upper`; nil when none does.
    private static func positions(from origin: CGFloat, length: CGFloat, lower: CGFloat, upper: CGFloat) -> ClosedRange<Int>? {
        let first = Int(((lower - origin) / pitch).rounded(.up))
        let last = Int(((upper - length - origin) / pitch).rounded(.down))
        return first <= last ? first ... last : nil
    }

    /// Lattice rows (counted downward) whose cell of `length` fits on the
    /// screen.
    private static func rowPositions(from origin: CGFloat, length: CGFloat, in visibleFrame: CGRect) -> ClosedRange<Int>? {
        let first = Int(((origin - visibleFrame.maxY) / pitch).rounded(.up))
        let last = Int(((origin - length - visibleFrame.minY) / pitch).rounded(.down))
        return first <= last ? first ... last : nil
    }

    /// The free cell closest to (`column`, `row`) that holds `span` on the
    /// screen, searched in rings of growing distance; the clamped cell itself
    /// when nothing is free.
    private static func nearestFree(
        _ cell: (column: Int, row: Int),
        span: DesktopWidgetSpan,
        lattice: CGPoint,
        in visibleFrame: CGRect,
        avoiding occupied: [CGRect]
    ) -> CGPoint {
        let size = dimensions(of: span)
        let columns = positions(from: lattice.x, length: size.width, lower: visibleFrame.minX, upper: visibleFrame.maxX)
            ?? cell.column ... cell.column
        let rows = rowPositions(from: lattice.y, length: size.height, in: visibleFrame) ?? cell.row ... cell.row
        let start = (
            min(max(cell.column, columns.lowerBound), columns.upperBound),
            min(max(cell.row, rows.lowerBound), rows.upperBound)
        )
        func isFree(_ c: Int, _ r: Int) -> Bool {
            let candidate = frame(topLeft: topLeft(column: c, row: r, lattice: lattice), span: span)
            // Touching edges is fine: the gap is inside the cell pitch.
            return !occupied.contains { $0.insetBy(dx: 1, dy: 1).intersects(candidate) }
        }
        let reach = max(columns.count, rows.count)
        for distance in 0 ... reach {
            var best: (cell: (Int, Int), score: Int)?
            for c in max(columns.lowerBound, start.0 - distance) ... min(columns.upperBound, start.0 + distance) {
                for r in max(rows.lowerBound, start.1 - distance) ... min(rows.upperBound, start.1 + distance)
                    where max(abs(c - start.0), abs(r - start.1)) == distance && isFree(c, r)
                {
                    // Within a ring, prefer the cell closest as the crow flies.
                    let score = (c - start.0) * (c - start.0) + (r - start.1) * (r - start.1)
                    if best.map({ score < $0.score }) ?? true { best = ((c, r), score) }
                }
            }
            if let best { return topLeft(column: best.cell.0, row: best.cell.1, lattice: lattice) }
        }
        return topLeft(column: start.0, row: start.1, lattice: lattice)
    }

    /// The gap between two rectangles (0 when they touch or overlap).
    private static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = max(0, max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX))
        let dy = max(0, max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY))
        return hypot(dx, dy)
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
            let lhsOverlap = lhs.intersection(frame)
            let rhsOverlap = rhs.intersection(frame)
            return (lhsOverlap.isNull ? 0 : lhsOverlap.width * lhsOverlap.height)
                < (rhsOverlap.isNull ? 0 : rhsOverlap.width * rhsOverlap.height)
        }
    }
}
