import AppKit
import SwiftUI

/// Recursively renders a split tree as nested split views or a single terminal pane.
struct SplitTreeView: View {
    let node: SplitNode
    let focusedPaneID: UUID?
    let isActiveProject: Bool
    let projectID: UUID
    let isSplit: Bool
    let onFocusPane: (UUID) -> Void
    let onSplit: (UUID, SplitDirection) -> Void
    let onClosePane: (UUID) -> Void

    init(
        node: SplitNode,
        focusedPaneID: UUID?,
        isActiveProject: Bool,
        projectID: UUID,
        isSplit: Bool = false,
        onFocusPane: @escaping (UUID) -> Void,
        onSplit: @escaping (UUID, SplitDirection) -> Void,
        onClosePane: @escaping (UUID) -> Void
    ) {
        self.node = node
        self.focusedPaneID = focusedPaneID
        self.isActiveProject = isActiveProject
        self.projectID = projectID
        self.isSplit = isSplit
        self.onFocusPane = onFocusPane
        self.onSplit = onSplit
        self.onClosePane = onClosePane
    }

    var body: some View {
        switch node {
        case let .pane(pane):
            let isFocused = focusedPaneID == pane.id && isActiveProject
            TerminalPane(
                pane: pane,
                focused: isFocused,
                onFocus: { onFocusPane(pane.id) },
                onProcessExit: { onClosePane(pane.id) },
                onSplitRequest: { dir, _ in onSplit(pane.id, dir) }
            )
            .overlay {
                if !isFocused, isSplit {
                    Color.black.opacity(0.2)
                        .allowsHitTesting(false)
                }
            }

        case let .split(branch):
            SplitDividerView(branch: branch) {
                SplitTreeView(
                    node: branch.first,
                    focusedPaneID: focusedPaneID,
                    isActiveProject: isActiveProject,
                    projectID: projectID,
                    isSplit: true,
                    onFocusPane: onFocusPane,
                    onSplit: onSplit,
                    onClosePane: onClosePane
                )
            } second: {
                SplitTreeView(
                    node: branch.second,
                    focusedPaneID: focusedPaneID,
                    isActiveProject: isActiveProject,
                    projectID: projectID,
                    isSplit: true,
                    onFocusPane: onFocusPane,
                    onSplit: onSplit,
                    onClosePane: onClosePane
                )
            }
        }
    }
}

/// A resizable split container with a draggable divider.
struct SplitDividerView<First: View, Second: View>: View {
    let branch: SplitBranch
    @ViewBuilder
    let first: First
    @ViewBuilder
    let second: Second

    var body: some View {
        GeometryReader { geo in
            let h = branch.direction == .horizontal
            let total = h ? geo.size.width : geo.size.height
            let firstSize = max(0, total * branch.ratio - 0.5)
            let secondSize = max(0, total * (1 - branch.ratio) - 0.5)
            let layout = h ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))

            layout {
                first.frame(width: h ? firstSize : nil, height: h ? nil : firstSize)

                Color.clear
                    .frame(width: h ? 1 : nil, height: h ? nil : 1)
                    .overlay(Rectangle().fill(MactermTheme.border))
                    .overlay {
                        Color.clear
                            .frame(width: h ? 5 : nil, height: h ? nil : 5)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                                let pos = h ? v.location.x : v.location.y
                                let origin = h ? v.startLocation.x : v.startLocation.y
                                let newPos = total * branch.ratio + (pos - origin)
                                branch.ratio = min(max(newPos / total, 0.15), 0.85)
                            })
                            .onHover { on in
                                if on {
                                    (h ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                    }

                second.frame(width: h ? secondSize : nil, height: h ? nil : secondSize)
            }
        }
    }
}
