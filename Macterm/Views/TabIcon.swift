import SwiftUI

// MARK: - Tab glyph

/// The single decision about what glyph a tab shows, shared by the sidebar row
/// and the tab switcher's cards (#344) so the two can never disagree about the
/// user's preferences.
///
/// Four preferences feed it — the chosen tab icon (`tabIconSymbol`, which the
/// sidebar may override per row), whether a live AI agent's logo replaces it
/// (`showAgentIcons`), whether a running/done status badge is drawn at all
/// (`showTabStatusIndicator`), and whether the running spinner also replaces an
/// agent logo (`showSpinnerOverAgentIcons`, #225). Reading them in one view is
/// what keeps a second surface from quietly re-deriving three of the four and
/// drifting: the switcher's first cut hardcoded a terminal symbol and a
/// spinner, honouring none of them.
///
/// `Preferences.noIcon` means the user asked for no icon, so nothing is drawn
/// unless there is a live signal to show (a status badge or an agent logo).
/// In that case it resolves to no view at all rather than an invisible one,
/// which both callers depend on for layout: the sidebar must not let an empty
/// image hold the Label's icon column, and the switcher's title has to start
/// flush with its preview instead of behind a reserved gap.
struct TabGlyph: View {
    let tab: TerminalTab
    /// 1-based row number, for the numbered icon variants.
    let index: Int
    /// Per-row override of the icon preference (pinned rows carry their own).
    var symbolOverride: String?
    /// Color for the symbol and the spinner, and for an agent logo in place of
    /// its brand color. nil keeps the hierarchical `.secondary` these glyphs
    /// have always used — which is NOT the same as passing `Color.secondary`,
    /// since the hierarchical style resolves against a selected sidebar row's
    /// own foreground (see `TabStatusGlyph.iconStyle`). The sidebar passes the
    /// project's tag color; the switcher passes its selected/unselected color.
    var tint: Color?

    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol = "terminal"
    @AppStorage(Preferences.Keys.showAgentIcons)
    private var showAgentIcons = true
    @AppStorage(Preferences.Keys.showTabStatusIndicator)
    private var showTabStatusIndicator = false
    @AppStorage(Preferences.Keys.showSpinnerOverAgentIcons)
    private var showSpinnerOverAgentIcons = true

    private var symbol: String { symbolOverride ?? tabIconSymbol }
    private var agent: AgentIcon? { showAgentIcons ? tab.agentIcon : nil }

    private var iconStyle: AnyShapeStyle {
        tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
    }

    var body: some View {
        if showTabStatusIndicator, !(symbol == Preferences.noIcon && tab.executionState == .idle && agent == nil) {
            TabStatusGlyph(
                state: tab.executionState,
                symbol: symbol,
                index: index,
                agent: agent,
                tint: tint,
                spinnerOverAgent: showSpinnerOverAgentIcons
            )
        } else if symbol != Preferences.noIcon || agent != nil {
            // "None" suppresses the user's icon, not the agent logo — that is
            // a live status signal, so it survives the preference.
            TabRowIcon(symbol: symbol, index: index, agent: agent, agentTint: tint)
                .foregroundStyle(iconStyle)
        }
    }
}

/// The tab icon with a coexisting status indicator (the maintainer's
/// suggestion): the user's chosen icon stays put, and status is additive.
///
/// - `running`: a small spinner replaces the icon (temporary prominence,
///   Xcode-build-navigator style) — unless the icon is an AI agent's logo and
///   the user turned "Show spinner over agent icons" off (#225): agent CLIs
///   draw their own busy indicator in the tab title, so the logo can stay put.
/// - `done` (needs attention): the icon with a small solid status dot in the
///   bottom-trailing corner — like the Messages/FaceTime "available" dot. A
///   dot reads as "done/positive" without competing with the icon's identity,
///   and it avoids the heavy, off-platform look of a checkmark glyph badge.
///   It overlays the agent logo the same way, regardless of the spinner
///   preference — "unread agent messages" is the signal #225 asked to keep.
/// - `idle`: the icon as-is.
struct TabStatusGlyph: View {
    let state: TerminalExecutionState
    let symbol: String
    let index: Int
    var agent: AgentIcon?
    /// The project tag's color, nil when untagged — see
    /// `SidebarTabRow.tagColor`, or the switcher's selection color.
    var tint: Color?
    var spinnerOverAgent = true
    @AppStorage(Preferences.Keys.sidebarIconSize)
    private var iconSizeRaw = SidebarIconSize.medium.rawValue

    private var size: SidebarIconSize {
        SidebarIconSize(rawValue: iconSizeRaw) ?? .medium
    }

    /// The spinner is a control, so it steps between AppKit's control sizes
    /// rather than scaling continuously with the icons. `.mini` (12pt) matches
    /// a small symbol closely; `.regular` is 32pt, far past even a large one,
    /// so large stays on `.small` and only its frame grows.
    private var spinnerControlSize: ControlSize {
        size == .small ? .mini : .small
    }

    /// The tag when tagged, else the hierarchical `.secondary` these glyphs
    /// have always used — see `SidebarTabRow.iconStyle` for why a `??` here
    /// would quietly change every untagged row.
    private var iconStyle: AnyShapeStyle {
        tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
    }

    var body: some View {
        switch state {
        case .running:
            if let agent, !spinnerOverAgent {
                TabRowIcon(symbol: symbol, index: index, agent: agent, agentTint: tint)
                    .foregroundStyle(iconStyle)
                    .help("Running")
            } else {
                let side = 16 * size.glyphScale
                ProgressView()
                    .controlSize(spinnerControlSize)
                    .tint(tint ?? .secondary)
                    .help("Running")
                    .frame(width: side, height: side)
            }
        case .done:
            TabRowIcon(symbol: symbol, index: index, agent: agent, agentTint: tint)
                .foregroundStyle(iconStyle)
                .overlay(alignment: .bottomTrailing) {
                    // Opaque (not translucent) so it reads clearly over the
                    // icon and the sidebar background. Nested in a background
                    // ring so it stays legible over any icon color. Sized off
                    // the icon so the dot keeps hugging its corner at every
                    // icon size instead of floating away from a smaller glyph.
                    Circle()
                        .fill(.background)
                        .frame(width: 7 * size.glyphScale, height: 7 * size.glyphScale)
                        .overlay(
                            Circle()
                                .fill(MactermTheme.success)
                                .frame(width: 5 * size.glyphScale, height: 5 * size.glyphScale)
                        )
                        .offset(x: 2.5 * size.glyphScale, y: 2.5 * size.glyphScale)
                }
                .help("Done")
        case .idle:
            TabRowIcon(symbol: symbol, index: index, agent: agent, agentTint: tint)
                .foregroundStyle(iconStyle)
                .help("Idle")
        }
    }
}

extension AgentIcon {
    /// The agent's brand tint. These are vendor identity colors, not theme
    /// colors, so they're the one deliberate exception to "all colors come
    /// from MactermTheme". Monochrome brands (Cursor, Grok, opencode) use
    /// `.primary` so they stay black-on-light / white-on-dark like the brand.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // Anthropic coral
        case .codex: Color(red: 0xAB / 255, green: 0xAB / 255, blue: 0xAB / 255) // OpenAI light gray
        case .gemini: Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255) // Google blue
        case .copilot: Color(red: 0x89 / 255, green: 0x57 / 255, blue: 0xE5 / 255) // GitHub purple
        case .antigravity: Color(red: 0x31 / 255, green: 0x86 / 255, blue: 0xFF / 255) // Google Antigravity blue
        case .opencode,
             .cursor,
             .grok,
             .pi: .primary
        }
    }
}

struct TabRowIcon: View {
    let symbol: String
    let index: Int
    var agent: AgentIcon?
    /// The project tag's color, which outranks the agent's brand color: a
    /// tagged project claims every icon in its rows, so the logo's SHAPE says
    /// which agent and the color says which project. Coral sitting among a
    /// red project's icons read as a mistake rather than as a brand. Nil
    /// (untagged) keeps the brand color.
    var agentTint: Color?
    @AppStorage(Preferences.Keys.sidebarIconSize)
    private var iconSizeRaw = SidebarIconSize.medium.rawValue
    /// Scales with the user's text size like the sibling SF Symbols do; a
    /// fixed 15pt would stay small next to enlarged row text.
    @ScaledMetric(relativeTo: .body)
    private var agentIconSize: CGFloat = 15

    private var size: SidebarIconSize {
        SidebarIconSize(rawValue: iconSizeRaw) ?? .medium
    }

    var body: some View {
        if let agent {
            // A live AI agent in the tab overrides the user's chosen icon —
            // the logo is a status signal, tinted with the agent's brand color
            // (overriding the row's .secondary tint) unless the project's own
            // tag claims it.
            let side = agentIconSize * size.glyphScale
            Image(agent.rawValue)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
                .foregroundStyle(agentTint ?? agent.brandColor)
        } else if Preferences.numberIconChoices.contains(symbol) {
            NumberGlyph(index: index, variant: symbol, size: size)
        } else {
            Image(systemName: symbol)
                .imageScale(size.imageScale)
        }
    }
}

extension SidebarIconSize {
    /// SwiftUI's own symbol scaling, which sizes a symbol against whatever font
    /// the row hands it. `medium` is the default, so the middle case leaves an
    /// icon exactly the size it was before this preference existed rather than
    /// pinning it to a point size of our own.
    var imageScale: Image.Scale {
        switch self {
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}

private struct NumberGlyph: View {
    let index: Int
    let variant: String
    var size: SidebarIconSize = .medium
    /// The `.body` point size, as a metric so the digits keep tracking the
    /// user's text size once `glyphScale` has been applied — `imageScale` is
    /// no help here, since these variants draw text rather than a symbol.
    @ScaledMetric(relativeTo: .body)
    private var bodyFontSize: CGFloat = 13

    private var digitFont: Font {
        .system(size: bodyFontSize * size.glyphScale).monospacedDigit()
    }

    var body: some View {
        if variant == Preferences.numberIconPlain {
            Text("\(index)")
                .font(digitFont)
        } else if let suffix = shapeSuffix, (1 ... 50).contains(index) {
            // SF Symbols ships `1.<shape>` through `50.<shape>`; beyond that,
            // fall back to plain digits so we don't render a missing glyph.
            Image(systemName: "\(index).\(suffix)")
                .imageScale(size.imageScale)
        } else {
            Text("\(index)")
                .font(digitFont)
        }
    }

    /// Maps the sentinel token (e.g. `number.circle.fill`) to the suffix used
    /// by the indexed SF Symbol (e.g. `circle.fill` in `1.circle.fill`).
    private var shapeSuffix: String? {
        switch variant {
        case Preferences.numberIconCircleFill: "circle.fill"
        case Preferences.numberIconCircle: "circle"
        case Preferences.numberIconSquareFill: "square.fill"
        case Preferences.numberIconSquare: "square"
        default: nil
        }
    }
}
