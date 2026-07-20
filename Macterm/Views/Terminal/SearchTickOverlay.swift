import AppKit

/// Tick marks over the scroller track showing where search matches live in the
/// scrollback (Xcode-style). Pure presentation: rows come from `SearchTicks`,
/// geometry mirrors the scroller (fraction of total scrollback rows). The view
/// never participates in hit testing, so the scroller underneath keeps full
/// click/drag behavior.
final class SearchTickOverlay: NSView {
    var tickColor: NSColor = .systemYellow
    var selectedColor: NSColor = .systemOrange

    /// Distinct tick fractions (0 = top of history, 1 = bottom), deduped so a
    /// pathological needle can't queue thousands of overlapping draw rects.
    private var fractions: [CGFloat] = []
    private var selectedFraction: CGFloat?

    func update(matchRows: [Int], selectedRow: Int?, totalRows: Int) {
        guard totalRows > 0, !matchRows.isEmpty else {
            fractions = []
            selectedFraction = nil
            needsDisplay = true
            return
        }
        let unique = Set(matchRows)
        fractions = unique.map { Self.fraction(row: $0, totalRows: totalRows) }.sorted()
        selectedFraction = selectedRow.map { Self.fraction(row: $0, totalRows: totalRows) }
        needsDisplay = true
    }

    static func fraction(row: Int, totalRows: Int) -> CGFloat {
        (CGFloat(row) + 0.5) / CGFloat(totalRows)
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func draw(_: NSRect) {
        guard !fractions.isEmpty, bounds.height > 0 else { return }
        for f in fractions where f != selectedFraction {
            tickColor.setFill()
            tickPath(at: f).fill()
        }
        // Selected last, so it always wins overlapping ticks.
        if let selectedFraction {
            selectedColor.setFill()
            tickPath(at: selectedFraction).fill()
        }
    }

    private func tickPath(at fraction: CGFloat) -> NSBezierPath {
        let tickHeight: CGFloat = 4
        let inset: CGFloat = 2
        // AppKit Y is up; fraction 0 (top of history) draws at the top.
        let y = (bounds.height - tickHeight) * (1 - fraction)
        let rect = NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: tickHeight)
        return NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
    }
}
