import AppKit
import SwiftUI

// MARK: - Overlay

/// Transient tab switcher shown while the Recent Tab shortcut is held (#344).
///
/// Deliberately not the command palette: the palette is a search surface with
/// a text field and a focus handoff, while this is a heads-up display for a
/// gesture that starts and ends inside one key-hold. It shares the palette's
/// chrome (`glassPanel`) so the two read as the same family of floating
/// surfaces, but not its scrim — the gesture is over in under a second, and
/// dimming the window the user is switching *within* hides the very thing
/// they are choosing between.
///
/// The panel takes the pointer: hovering a card moves the selection, clicking
/// one commits to it. Only the panel does — nothing else in the overlay draws
/// a background, so presses outside it fall through to the terminal
/// underneath. Note that a click here is necessarily a *modifier*-click, since
/// releasing the modifier is what ends the gesture.
///
/// With the strip up, cycling moves the selection only — the tab behind it and
/// the pane holding focus stay put until the modifier is released (see
/// `AppState.cycleRecentTab`). So the strip is the whole interface for the
/// gesture: it has to show where the next press lands, not just confirm where
/// the last one did.
/// One tab in the strip: where it sits in the cycle, its 1-based number in
/// the workspace (what the numbered tab icons show), and the tab itself.
struct TabSwitcherEntry {
    let index: Int
    let number: Int
    let tab: TerminalTab
}

struct TabSwitcherOverlay: View {
    @Environment(AppState.self)
    private var appState

    var body: some View {
        if let workspace = activeWorkspace, appState.tabCycleTabIDs.count > 1 {
            TabSwitcherStrip(
                entries: tabs(in: workspace),
                selection: appState.tabCycleSelection,
                paneAspect: appState.paneContainerAspect,
                onHover: { appState.focusTabCycle(at: $0) },
                onClick: { index in
                    guard let projectID = appState.activeProjectID else { return }
                    appState.commitTabCycle(projectID: projectID, at: index)
                }
            )
            // Centered: the strip is the whole interface for the gesture
            // (the window behind it does not change until release), so it
            // belongs where the eye already is rather than tucked at an
            // edge — and centering is also what makes it a plausible
            // pointer target.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }

    private var activeWorkspace: Workspace? {
        guard let pid = appState.activeProjectID else { return nil }
        return appState.workspaces[pid]
    }

    /// The cycle order resolved to live tabs, dropping any that closed
    /// mid-gesture so the strip can't render a hole. Each entry carries the
    /// tab's own 1-based position in the workspace too, because the numbered
    /// icon variants show that number — not the tab's place in the cycle.
    private func tabs(in workspace: Workspace) -> [TabSwitcherEntry] {
        appState.tabCycleTabIDs.enumerated().compactMap { index, id in
            guard let position = workspace.tabs.firstIndex(where: { $0.id == id }) else { return nil }
            return TabSwitcherEntry(index: index, number: position + 1, tab: workspace.tabs[position])
        }
    }
}

// MARK: - Strip

/// The cards themselves, wrapped into centered rows (`CenteredRows`) at the
/// width the window leaves inside `windowMargin`, so a wide window shows more
/// of the order per row and a narrow one still shows a readable card.
///
/// The panel hugs its rows while they fit the window's height and becomes a
/// vertical scroll view when they don't (`ViewThatFits`). An earlier cut
/// rejected a scroll view because the gesture is keyboard-only and over in
/// under a second, so there is nothing to scroll *with* — that still holds for
/// the keyboard: a step keeps the selected card centered on its own, so nobody
/// has to scroll to follow it. The scroll view exists for the Unlimited
/// candidate count, where the rows can outgrow any window: the pointer is
/// available for the whole hold (a click here is a modifier-click already), so
/// a wheel over the panel reaches the rows the selection is not on. A hover
/// never scrolls — the hovered card is under the pointer, so it is already
/// visible, and centering it would slide the rows away under the cursor (see
/// `HoverSelectionTracker`).
private struct TabSwitcherStrip: View {
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    let entries: [TabSwitcherEntry]
    let selection: Int
    /// Width over height of the region the panes actually fill, so cards are
    /// shaped like the thing they picture. nil before anything was measured.
    let paneAspect: CGFloat?
    /// Pointer handlers, both taking a card's index in the cycle order.
    let onHover: (Int) -> Void
    let onClick: (Int) -> Void

    private static let spacing: CGFloat = 10
    /// Inset from the panel's edge to the cards. The preview inside a card
    /// carries `TabSwitcherCard.selectionHalo` on top of this, so the gap the
    /// eye actually reads — panel edge to picture — is the sum, equally on
    /// every side. Anything that pads one axis and not the other shows up
    /// immediately here: the card used to carry a stray `.padding(.vertical, 2)`
    /// (left over from a uniform padding that was removed around it), which
    /// made the top gap 20 against 18 at the sides.
    private static let insets: CGFloat = 14
    /// Clear space between the panel and the window edges — applied as padding
    /// on both axes, so it bounds the rows' width and the panel's height as a
    /// layout fact rather than a number the wrapping has to agree with.
    private static let windowMargin: CGFloat = 48

    @State
    private var hoverTracker = HoverSelectionTracker()
    /// The width the rows laid out at inside the scroll view, so the panel can
    /// hug them there too. nil until the scroll view has laid out once.
    @State
    private var scrolledRowsWidth: CGFloat?

    var body: some View {
        // One card tree, built once: `ViewThatFits` keeps every candidate it
        // measures in the graph, so two copies of the rows would mean every
        // card body — and every pane preview — evaluating twice per tick.
        let rows = cards.padding(Self.insets)

        ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                rows

                ScrollView(.vertical) {
                    rows.onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        scrolledRowsWidth = $0
                    }
                }
                .scrollIndicators(.visible)
                // A vertical scroll view is greedy in width, so left alone it
                // would stretch the panel to the window margins with the rows
                // centered inside — a different panel shape from the hugging
                // one above, and a hit-testable band beside the rows that
                // stops clicks reaching the terminal. Sized to the rows
                // instead, from the width they lay out at: only the content
                // knows it, and the same rows come out at that width again.
                .frame(maxWidth: scrolledRowsWidth)
            }
            // Once, outside the branch: `ViewThatFits` reports the chosen
            // child's size, so the glass still hugs whichever is showing.
            .glassPanel()
            // `initial: true`: the strip is born with the selection already
            // advanced (the first press both starts the cycle and moves), so
            // the scroll view has to find it, not just follow it. In the
            // hugging branch there is nothing to scroll and this is a no-op.
            .onChange(of: selection, initial: true) { _, index in
                guard !hoverTracker.isHoverSelection(index),
                      let tabID = entries.first(where: { $0.index == index })?.tab.id
                else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    proxy.scrollTo(tabID, anchor: .center)
                }
            }
        }
        .padding(Self.windowMargin)
    }

    private var cards: some View {
        CenteredRows(spacing: Self.spacing) {
            ForEach(entries, id: \.tab.id) { entry in
                TabSwitcherCard(
                    tab: entry.tab,
                    number: entry.number,
                    isSelected: entry.index == selection,
                    paneAspect: paneAspect
                )
                .onContinuousHover { phase in
                    guard case .active = phase,
                          hoverTracker.noteHover(over: entry.index, current: selection)
                    else { return }
                    onHover(entry.index)
                }
                .onTapGesture { onClick(entry.index) }
                .id(entry.tab.id)
            }
        }
    }
}

/// Wraps its children into rows at the width it is proposed and centers each
/// row. The native form of "how many cards fit": the layout answers from the
/// width it is actually given, so the panel's padding and the rows' spacing
/// can never disagree with a capacity computed beside them.
private struct CenteredRows: Layout {
    let spacing: CGFloat

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(fitting: proposal.width, subviews: subviews)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in rows(fitting: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// Greedy: a row takes children until the next would not fit. A row is
    /// never empty, so a child wider than the width still gets one of its own.
    private func rows(fitting width: CGFloat?, subviews: Subviews) -> [Row] {
        let limit = width ?? .infinity
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > limit {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Card

/// One tab: a miniature of its split layout with each pane's own preview and
/// name, over the tab's title row.
private struct TabSwitcherCard: View {
    let tab: TerminalTab
    /// The tab's 1-based number in the workspace, for the numbered tab icons.
    let number: Int
    let isSelected: Bool
    let paneAspect: CGFloat?

    /// Height of the preview at a comfortably wide pane region. A narrow
    /// (portrait) one grows TALLER instead of the card growing wider than its
    /// picture — see `previewHeight(forPaneAspect:)`.
    private static let basePreviewHeight: CGFloat = 140
    /// Ceiling on that growth, so an extremely tall pane region can't turn the
    /// strip into a wall.
    private static let maxPreviewHeight: CGFloat = 190
    /// Width a narrow card is grown toward — enough to carry an icon and some
    /// title. Reached by making the preview taller, NEVER by padding the card
    /// wider than its picture: a card with surplus width has to distribute it,
    /// and centering that surplus is what made the side padding drift away
    /// from the top padding as the window changed shape.
    private static let widthTarget: CGFloat = 116
    /// Aspect assumed before anything has been measured. Only reachable for a
    /// workspace whose panes have never been on screen this run.
    static let fallbackAspect: CGFloat = 16.0 / 10.0
    private static let cornerRadius: CGFloat = 8
    /// Halo left around the preview for the selection fill to show in. Zero
    /// would hide it: the thumbnail is opaque, so a highlight exactly the
    /// preview's size sits entirely behind it.
    private static let selectionHalo: CGFloat = 4

    /// Aspect to lay out at, floored so a degenerate measurement can't divide
    /// the height into something enormous.
    private static func safeAspect(_ aspect: CGFloat?) -> CGFloat {
        max(aspect ?? fallbackAspect, 0.2)
    }

    /// Preview height for a pane region: the base, grown toward `widthTarget`
    /// when the region is narrow, capped.
    static func previewHeight(forPaneAspect aspect: CGFloat?) -> CGFloat {
        min(maxPreviewHeight, max(basePreviewHeight, widthTarget / safeAspect(aspect)))
    }

    /// The card's width — exactly its preview plus the halo, at every aspect.
    /// Keeping the two equal is what makes the panel's padding uniform by
    /// construction: there is no surplus for a layout to distribute.
    static func width(forPaneAspect aspect: CGFloat?) -> CGFloat {
        (previewHeight(forPaneAspect: aspect) * safeAspect(aspect)).rounded() + selectionHalo * 2
    }

    private var cardWidth: CGFloat { Self.width(forPaneAspect: paneAspect) }

    var body: some View {
        // Preview, title row and card are all exactly `cardWidth`: the preview
        // because the card's width is derived from it, the title row because
        // it asks for the same. Nothing here is wider than its content, so
        // there is no surplus to center and the panel's padding reads the same
        // on every side at every window shape.
        VStack(alignment: .leading, spacing: 6) {
            PaneMosaic(node: tab.splitRoot, focusedPaneID: tab.focusedPaneID)
                // The mosaic gets the pane region's real proportions, so every
                // leaf inside it gets its own pane's proportions and the
                // captured frames drop in uncropped.
                .aspectRatio(Self.safeAspect(paneAspect), contentMode: .fit)
                .frame(height: Self.previewHeight(forPaneAspect: paneAspect))
                // The gaps between leaves are the miniature split dividers,
                // and they are deliberately untinted: whatever sits behind the
                // card shows through them — the selection fill on the selected
                // one, the glass panel on the rest — so a divider reads as a
                // gap in the picture rather than as a drawn line. That does
                // mean two cards of the same layout differ by their backdrop,
                // which is the intent, not a regression to fix with a fill.
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(MactermTheme.border.opacity(0.6), lineWidth: 1)
                )
                // The selection is a fill hugging the PREVIEW, evenly on all
                // four sides and concentric with its corner, rather than a
                // stroke around the whole card. A card-sized box was the wrong
                // shape for it: the preview takes the pane region's aspect, so
                // on a portrait window it sits well inside a card widened to
                // hold the title, and the highlight framed empty panel instead
                // of the picture.
                .padding(Self.selectionHalo)
                .background(
                    RoundedRectangle(
                        cornerRadius: Self.cornerRadius + Self.selectionHalo,
                        style: .continuous
                    )
                    .fill(isSelected ? MactermTheme.fg.opacity(0.14) : .clear)
                )

            HStack(spacing: 6) {
                // The sidebar's own glyph, preferences and all — the chosen
                // tab icon, the agent logo in its brand color, the running
                // spinner and the done dot. An earlier cut drew a hardcoded
                // terminal symbol and its own spinner here, so three of the
                // four preferences behind it did nothing on these cards.
                // Deliberately unframed: when the preferences leave nothing
                // to draw it contributes no view and no spacing, and the
                // title stays flush with the preview's edge.
                // Tinted with the title, so the whole row brightens on the
                // selected card rather than a white title beside a dim icon.
                TabGlyph(
                    tab: tab,
                    index: number,
                    tint: isSelected ? MactermTheme.fg : MactermTheme.fgMuted
                )
                Text(tab.sidebarRowTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? MactermTheme.fg : MactermTheme.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Inset by the halo so the icon's leading edge lands on the
            // preview's own edge rather than the highlight's.
            .padding(.horizontal, Self.selectionHalo)
            .frame(width: cardWidth, alignment: .leading)
        }
    }
}

// MARK: - Pane mosaic

/// The tab's split tree, laid out at card scale with the branches' real
/// ratios, so a 2x2 grid looks like a 2x2 grid. Each leaf renders its frozen
/// preview with the pane's name over it.
private struct PaneMosaic: View {
    let node: SplitNode
    let focusedPaneID: UUID?

    /// Gap between panes — the miniature of the split divider. Enough to read
    /// as a division at this scale without eating the previews.
    private static let gap: CGFloat = 2

    var body: some View {
        switch node {
        case let .pane(pane):
            PaneMosaicLeaf(pane: pane, isFocused: pane.id == focusedPaneID)
        case let .split(branch):
            GeometryReader { geo in
                let ratio = min(max(branch.ratio, 0.05), 0.95)
                switch branch.direction {
                case .horizontal:
                    let first = max(0, (geo.size.width - Self.gap) * ratio)
                    HStack(spacing: Self.gap) {
                        PaneMosaic(node: branch.first, focusedPaneID: focusedPaneID)
                            .frame(width: first)
                        PaneMosaic(node: branch.second, focusedPaneID: focusedPaneID)
                    }
                case .vertical:
                    let first = max(0, (geo.size.height - Self.gap) * ratio)
                    VStack(spacing: Self.gap) {
                        PaneMosaic(node: branch.first, focusedPaneID: focusedPaneID)
                            .frame(height: first)
                        PaneMosaic(node: branch.second, focusedPaneID: focusedPaneID)
                    }
                }
            }
        }
    }
}

private struct PaneMosaicLeaf: View {
    let pane: Pane
    let isFocused: Bool

    @Environment(AppState.self)
    private var appState

    var body: some View {
        let preview = appState.panePreviews[pane.id]
        // The pane's background is what defines this leaf's size. The preview
        // goes in an `overlay`, never in the layout: a `resizable` image sized
        // `.fill` reports its own (full-frame) dimensions, so as a ZStack child
        // it grew the leaf past its frame and carried the name chip out of the
        // clipped area with it — the chips were being drawn below the card.
        Rectangle()
            .fill(Color(nsColor: preview?.background ?? MactermTheme.nsBg))
            .overlay(alignment: .topLeading) {
                if let image = preview?.image {
                    // `.fit`, never `.fill`: the leaf's box already has this
                    // pane's real proportions (the mosaic is laid out at the
                    // pane region's aspect), so the frame lands in it whole.
                    // Cropping here is what made an earlier cut of this show
                    // only the top half of every tall pane.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .clipped()
            // The focused pane is marked the way the split view marks it: the
            // others are dimmed rather than this one being highlighted.
            .overlay(isFocused ? Color.clear : Color.black.opacity(0.22))
    }
}
