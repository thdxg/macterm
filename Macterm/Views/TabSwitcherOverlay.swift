import AppKit
import SwiftUI

// MARK: - Overlay

/// Transient tab switcher shown while the Recent Tab shortcut is held (#344).
///
/// Deliberately not the command palette: the palette is a search surface with
/// a text field and a focus handoff, while this is a read-only heads-up
/// display for a gesture that starts and ends inside one key-hold. It shares
/// the palette's chrome (`glassPanel`) so the two read as the same family of
/// floating surfaces, and nothing else — no scrim (the gesture is over in
/// under a second, and dimming the window the user is switching *within*
/// hides the very thing they're choosing between), no hit testing (there is
/// no pointer in this interaction; a click target would only steal the press
/// that lands after the modifier releases).
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
            let entries = tabs(in: workspace)
            GeometryReader { geo in
                VStack {
                    Spacer()
                    TabSwitcherStrip(
                        entries: entries,
                        selection: appState.tabCycleSelection,
                        availableWidth: geo.size.width,
                        paneAspect: appState.paneContainerAspect
                    )
                    .glassPanel()
                    // Sits low in the window, out of the terminal's working
                    // area and clear of the titlebar — the same instinct as
                    // the palette's 15%-from-top placement, mirrored.
                    .padding(.bottom, 44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
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

/// The cards themselves — a fixed-width viewport onto the cycle order, scrolled
/// to keep the selection centered, with a slice of the neighbouring card
/// showing at each edge that has more behind it.
///
/// A viewport rather than a scroll view: the gesture is keyboard-only and lasts
/// under a second, so there is nothing to scroll *with*, and a strip that grew
/// with the tab count would run past the window on a project with a dozen tabs
/// (measured: five cards already overflowed a 948pt window edge to edge). How
/// many fit is asked of the window rather than hardcoded, so a wide window
/// shows more of the order and a narrow one still shows a readable card.
private struct TabSwitcherStrip: View {
    let entries: [TabSwitcherEntry]
    let selection: Int
    let availableWidth: CGFloat
    /// Width over height of the region the panes actually fill, so cards are
    /// shaped like the thing they picture. nil before anything was measured.
    let paneAspect: CGFloat?

    private static let spacing: CGFloat = 10
    private static let insets: CGFloat = 14
    /// Left clear on both sides of the panel, so it reads as floating in the
    /// window rather than spanning it.
    private static let windowMargin: CGFloat = 48
    /// Width reserved on a side that has more tabs behind it, so a slice of
    /// the next card shows through the clip. That sliver IS the overflow
    /// indicator — a chevron and a count said the same thing in a second
    /// visual language, when the strip can just show you the thing itself.
    /// Its own width plus the gap before it, so `peek - spacing` of card
    /// stays visible.
    private static let peek: CGFloat = 34

    var body: some View {
        let cardWidth = TabSwitcherCard.width(forPaneAspect: paneAspect)
        let capacity = capacity(for: availableWidth, cardWidth: cardWidth)
        let step = cardWidth + Self.spacing
        let content = span(of: entries.count, cardWidth: cardWidth)
        // The viewport is `capacity` whole cards plus a peek on each side, and
        // it does NOT change as the strip moves: the panel keeping a constant
        // width is the point. An earlier cut added each peek only when that
        // side had something behind it, so the panel visibly grew and shrank
        // as the selection passed the ends.
        let viewport = min(content, span(of: capacity, cardWidth: cardWidth) + Self.peek * 2)
        let scroll = scrollOffset(step: step, cardWidth: cardWidth, viewport: viewport, content: content)
        // Every card is laid out, always, and the whole row is TRANSLATED
        // under the clip. Rendering only a windowed slice instead meant a step
        // inserted one view and removed another, so the cards already on
        // screen slid while the incoming one appeared out of nothing at the
        // edge. Sliding the strip makes one motion of it: everything moves
        // together and the next card comes in from under the clip.
        HStack(spacing: Self.spacing) {
            ForEach(entries, id: \.tab.id) { entry in
                TabSwitcherCard(
                    tab: entry.tab,
                    number: entry.number,
                    isSelected: entry.index == selection,
                    paneAspect: paneAspect
                )
            }
        }
        .offset(x: -scroll)
        .frame(width: viewport, alignment: .leading)
        .clipped()
        .padding(Self.insets)
        .animation(.easeOut(duration: 0.16), value: scroll)
    }

    /// Width of `count` cards laid out with the strip's spacing.
    private func span(of count: Int, cardWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return cardWidth * CGFloat(count) + Self.spacing * CGFloat(count - 1)
    }

    /// How far the row is scrolled: the selected card centered in the
    /// viewport, clamped to the ends. Clamping is what fills the peek slots
    /// with real cards at the ends instead of leaving empty panel there, and
    /// it is stateless — the same selection always yields the same offset, so
    /// nothing drifts across a gesture.
    private func scrollOffset(step: CGFloat, cardWidth: CGFloat, viewport: CGFloat, content: CGFloat) -> CGFloat {
        guard let position = entries.firstIndex(where: { $0.index == selection }) else { return 0 }
        let centered = CGFloat(position) * step + cardWidth / 2 - viewport / 2
        return min(max(0, centered), max(0, content - viewport))
    }

    /// How many cards fit, at least one. Both peeks are reserved whether or
    /// not a neighbour is showing in them, so the capacity — and the panel's
    /// width — can't change as the strip moves.
    private func capacity(for width: CGFloat, cardWidth: CGFloat) -> Int {
        let chrome = Self.windowMargin * 2 + Self.insets * 2 + Self.peek * 2
        let perCard = cardWidth + Self.spacing
        let fits = Int(((width - chrome + Self.spacing) / perCard).rounded(.down))
        return max(1, min(entries.count, fits))
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

    /// Height of the preview area. Fixed, with the width following the pane
    /// region's real aspect — the other way round (fixed width, derived
    /// height) makes a portrait window's card taller than the strip.
    static let previewHeight: CGFloat = 140
    /// Aspect assumed before anything has been measured. Only reachable for a
    /// workspace whose panes have never been on screen this run.
    static let fallbackAspect: CGFloat = 16.0 / 10.0
    /// Floor on the card's width, so a very narrow (portrait) pane region
    /// doesn't produce a card too small to carry an icon and any title at all.
    /// The preview is centered in it and the title row aligns to the preview,
    /// not to the card — see `body`.
    private static let minimumWidth: CGFloat = 110
    private static let cornerRadius: CGFloat = 8
    /// Halo left around the preview for the selection fill to show in. Zero
    /// would hide it: the thumbnail is opaque, so a highlight exactly the
    /// preview's size sits entirely behind it.
    private static let selectionHalo: CGFloat = 4

    /// The card's width for a given pane region — the preview at
    /// `previewHeight` plus its halo, floored by `minimumWidth`.
    static func width(forPaneAspect aspect: CGFloat?) -> CGFloat {
        max(minimumWidth, boxWidth(forPaneAspect: aspect))
    }

    /// Width of the preview plus the halo around it: the card's real content,
    /// and what the title row is sized and aligned to.
    private static func boxWidth(forPaneAspect aspect: CGFloat?) -> CGFloat {
        (previewHeight * (aspect ?? fallbackAspect)).rounded() + selectionHalo * 2
    }

    private var cardWidth: CGFloat { Self.width(forPaneAspect: paneAspect) }

    var body: some View {
        let boxWidth = Self.boxWidth(forPaneAspect: paneAspect)
        // Preview and title share a left edge. The VStack is only as wide as
        // the preview box, so centering it inside `cardWidth` moves the title
        // with the picture instead of pinning the title to the card's edge and
        // leaving it adrift of a narrower preview.
        VStack(alignment: .leading, spacing: 6) {
            PaneMosaic(node: tab.splitRoot, focusedPaneID: tab.focusedPaneID)
                // The mosaic gets the pane region's real proportions, so every
                // leaf inside it gets its own pane's proportions and the
                // captured frames drop in uncropped.
                .aspectRatio(paneAspect ?? Self.fallbackAspect, contentMode: .fit)
                .frame(height: Self.previewHeight)
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
            .frame(width: boxWidth, alignment: .leading)
        }
        .frame(width: cardWidth)
        .padding(.vertical, 2)
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
                } else if let preview, !preview.lines.isEmpty {
                    PanePreviewText(lines: preview.lines, columns: preview.columns)
                }
            }
            .clipped()
            // The focused pane is marked the way the split view marks it: the
            // others are dimmed rather than this one being highlighted.
            .overlay(isFocused ? Color.clear : Color.black.opacity(0.22))
    }
}

/// Fallback preview for a pane no frame was ever captured from — a tab that
/// has never been focused this run (see `PanePreview`).
///
/// Typeset to stand in for the picture we couldn't take: the pane's own column
/// count is mapped onto the card's width, so a line lands at the same relative
/// size a real thumbnail of that pane would have shown, and rows run top down
/// like the screen they came from. A fixed point size was the earlier cut and
/// it read as a bug — 5pt text in a 100pt card made an idle shell's prompt
/// span the whole width, several times larger than the same prompt in the
/// captured frame beside it, and bottom-aligning it put a fresh shell's prompt
/// under the card instead of at its top.
private struct PanePreviewText: View {
    let lines: [String]
    /// The terminal's width in columns. nil falls back to a typical 80.
    let columns: Int?

    /// Advance width of a monospaced glyph as a fraction of point size. SF
    /// Mono and friends sit at 0.6; close enough to place the text at the
    /// right scale, which is all this needs to do.
    private static let advanceRatio: CGFloat = 0.6
    /// Below this the glyphs stop resolving into anything, so the text is
    /// dropped rather than drawn as grey mush.
    private static let minimumFontSize: CGFloat = 1.6

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width / (CGFloat(max(columns ?? 80, 1)) * Self.advanceRatio)
            if size >= Self.minimumFontSize {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: size, design: .monospaced))
                            .foregroundStyle(MactermTheme.fgMuted)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .clipped()
    }
}
