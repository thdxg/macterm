import CoreGraphics
@testable import Macterm
import Testing

@MainActor
struct SidebarPeekInteractionTests {
    @Test
    func launch_reconciliation_uses_the_restored_native_sidebar_state() {
        let hidden = SidebarPeekInteraction.launchResolution(
            nativeVisible: false,
            modelVisible: true
        )
        #expect(!hidden.columnVisible)
        #expect(hidden.modelVisible == false)

        let alreadySynchronized = SidebarPeekInteraction.launchResolution(
            nativeVisible: true,
            modelVisible: true
        )
        #expect(alreadySynchronized.columnVisible)
        #expect(alreadySynchronized.modelVisible == nil)
    }

    @Test
    func overlay_gets_intent_aware_acquisition_without_changing_resize_mode() {
        #expect(SidebarPeekInteraction.shouldBeginHover(
            style: .overlayTerminal,
            pointX: 10,
            previousX: 20
        ))
        #expect(!SidebarPeekInteraction.shouldBeginHover(
            style: .resizeTerminal,
            pointX: 10,
            previousX: 20
        ))
        #expect(SidebarPeekInteraction.shouldBeginHover(
            style: .resizeTerminal,
            pointX: 4,
            previousX: nil
        ))
    }

    @Test
    func opening_the_native_column_promotes_an_overlay_peek() {
        #expect(SidebarPeekInteraction.shouldPromoteOverlay(
            activeStyle: .overlayTerminal,
            columnVisible: true
        ))
        #expect(!SidebarPeekInteraction.shouldPromoteOverlay(
            activeStyle: .overlayTerminal,
            columnVisible: false
        ))
        #expect(!SidebarPeekInteraction.shouldPromoteOverlay(
            activeStyle: .resizeTerminal,
            columnVisible: true
        ))
    }

    @Test
    func pointer_menu_and_drag_each_retain_the_overlay() {
        #expect(retains(pointer: true))
        #expect(retains(windowIsKey: false, menuTrackingDepth: 1))
        #expect(retains(windowIsKey: false, pressedMouseButtons: 1))
        #expect(!retains(windowIsKey: false))
    }

    @Test
    func inactive_or_invalid_window_state_never_retains_the_overlay() {
        #expect(!retains(appIsActive: false, menuTrackingDepth: 1))
        #expect(!retains(windowIsVisible: false, menuTrackingDepth: 1))
        #expect(!retains(windowIsMiniaturized: true, menuTrackingDepth: 1))
        #expect(!retains(peekEnabled: false, menuTrackingDepth: 1))
        #expect(!retains(configuredStyle: .resizeTerminal, menuTrackingDepth: 1))
    }

    @Test
    func resize_release_collapses_only_after_the_pointer_passes_the_sidebar() {
        #expect(!SidebarPeekInteraction.shouldCollapseAfterResize(
            lastHoverX: nil,
            sidebarWidth: 180
        ))
        #expect(!SidebarPeekInteraction.shouldCollapseAfterResize(
            lastHoverX: 188,
            sidebarWidth: 180
        ))
        #expect(SidebarPeekInteraction.shouldCollapseAfterResize(
            lastHoverX: 189,
            sidebarWidth: 180
        ))
    }

    private func retains(
        appIsActive: Bool = true,
        windowIsVisible: Bool = true,
        windowIsMiniaturized: Bool = false,
        windowIsKey: Bool = true,
        peekEnabled: Bool = true,
        configuredStyle: SidebarPeekStyle = .overlayTerminal,
        menuTrackingDepth: Int = 0,
        pressedMouseButtons: Int = 0,
        pointer: Bool = false
    ) -> Bool {
        SidebarPeekInteraction.shouldRetainOverlay(.init(
            appIsActive: appIsActive,
            windowIsVisible: windowIsVisible,
            windowIsMiniaturized: windowIsMiniaturized,
            windowIsKey: windowIsKey,
            peekEnabled: peekEnabled,
            configuredStyle: configuredStyle,
            menuTrackingDepth: menuTrackingDepth,
            pressedMouseButtons: pressedMouseButtons,
            pointerIsRetained: pointer
        ))
    }
}
