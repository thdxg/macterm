import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: appBundleID, category: "WindowAppearance")

extension NSView {
    /// Recursively finds the first descendant view whose class name (as a string)
    /// matches `name`. Used to reach into AppKit's private titlebar view tree —
    /// the only known way to colorize the titlebar to match a transparent
    /// window background. Lifted from Ghostty's NSView+Extension.swift.
    func firstDescendant(withClassName name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                return subview
            }
            if let found = subview.firstDescendant(withClassName: name) {
                return found
            }
        }
        return nil
    }

    /// Every descendant whose class name matches `name` — for private views
    /// that can exist once per scroll view (e.g. `NSScrollPocket`), where
    /// hiding only the first would leave the rest in place.
    func forEachDescendant(withClassName name: String, _ body: (NSView) -> Void) {
        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                body(subview)
            }
            subview.forEachDescendant(withClassName: name, body)
        }
    }

    /// First `NSSplitView` at or below this view. Callers sit beside the split
    /// view (a `.background` probe, the window's content view), so the search
    /// runs down from wherever the caller stands.
    var firstSplitView: NSSplitView? {
        if let split = self as? NSSplitView { return split }
        for subview in subviews {
            if let found = subview.firstSplitView { return found }
        }
        return nil
    }

    /// The `NSSplitViewController` whose root view this is. A view controller
    /// inserts itself into its root view's responder chain, so walking up from
    /// the split view reaches it.
    var owningSplitViewController: NSSplitViewController? {
        var responder: NSResponder? = nextResponder
        while let current = responder {
            if let controller = current as? NSSplitViewController { return controller }
            responder = current.nextResponder
        }
        return nil
    }
}

// MARK: - Color helpers (for the inactive-glass tint)

extension NSColor {
    /// Returns a copy with its HSB saturation multiplied by `factor` (clamped
    /// to 0...1). Used to make the inactive-window overlay read as a desaturated
    /// version of the terminal background, matching Ghostty.
    func adjustingSaturation(by factor: CGFloat) -> NSColor {
        guard let hsb = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(max(s * factor, 0), 1), brightness: b, alpha: a)
    }
}

// MARK: - Private CGS blur SPI

/// `CGSSetWindowBackgroundBlurRadius` is a private CoreGraphics API that
/// every macOS terminal (Terminal.app, iTerm, Ghostty) uses to blur the
/// content behind a translucent window. It's undocumented but stable;
/// libghostty exposes the same call.
private let cgsConnectionFnPtr: @convention(c) () -> Int32 = {
    let handle = dlopen(nil, RTLD_NOW)
    guard let sym = dlsym(handle, "CGSDefaultConnectionForThread") else {
        fatalError("CGSDefaultConnectionForThread symbol not found")
    }
    return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
}()

private let cgsSetBlurFnPtr: @convention(c) (Int32, Int, Int32) -> Int32 = {
    let handle = dlopen(nil, RTLD_NOW)
    guard let sym = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else {
        fatalError("CGSSetWindowBackgroundBlurRadius symbol not found")
    }
    return unsafeBitCast(sym, to: (@convention(c) (Int32, Int, Int32) -> Int32).self)
}()

@MainActor
func setWindowBackgroundBlur(_ window: NSWindow, radius: Int) {
    _ = cgsSetBlurFnPtr(cgsConnectionFnPtr(), window.windowNumber, Int32(radius))
}

// MARK: - Liquid glass background

/// A container that hosts a macOS 26 `NSGlassEffectView` (the real liquid
/// glass material) plus an inactive-window tint overlay. Modeled on Ghostty's
/// `TerminalGlassView` (`TerminalViewContainer.swift`), with one deliberate
/// divergence noted below.
///
/// `NSGlassEffectView` desaturates itself when its window is not key — native
/// liquid-glass behavior with no API to opt out of (the macOS 26 SDK header
/// exposes only `tintColor`/`style`/`cornerRadius`). The overlay fades a
/// saturation-boosted tint of the background *in* as the window resigns key
/// and back *out* when it regains key. This isn't decoration: with no overlay
/// the raw system dimming reads as the window becoming markedly more
/// translucent on unfocus; the fade-in tint tames that. Focused, the tint is
/// at alpha 0, so the focused glass matches the user's chosen opacity exactly
/// (a *constant* tint would over-darken the focused window past that opacity).
///
/// Divergence from Ghostty: the unfocused tint alpha is scaled by the window
/// opacity (`tint.opacity * backgroundOpacity`), not the raw `tint.opacity`
/// Ghostty uses. Macterm exposes a full-range opacity slider, and an unscaled
/// tint would jump a very-translucent window to a near-opaque unfocused state,
/// ignoring the slider. Scaling keeps the inactive appearance proportional to
/// the setting.
///
/// Macterm inserts this below the window's content view, filling the whole
/// window — including the region under the titlebar (via a negative top inset
/// equal to the content view's top safe-area inset) — so the glass reads as
/// one continuous surface behind the sidebar, titlebar, and terminal.
@available(macOS 26.0, *)
final class MactermGlassView: NSView {
    private let glassEffectView = NSGlassEffectView()
    private let tintOverlay = NSView()
    private var topConstraint: NSLayoutConstraint!

    /// The window opacity the glass is currently configured for. The inactive
    /// tint is scaled by this so the unfocused window honors the user's opacity
    /// slider instead of jumping to a fixed tint — a deliberate divergence from
    /// Ghostty, which uses the raw tint opacity regardless of the setting.
    private var backgroundOpacity: CGFloat = 1

    init(topOffset: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(equalTo: topAnchor, constant: topOffset)
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // The inactive tint sits above the glass and fades in when the window
        // resigns key, masking the system's inactive-glass desaturation.
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.wantsLayer = true
        tintOverlay.alphaValue = 0
        addSubview(tintOverlay, positioned: .above, relativeTo: glassEffectView)
        NSLayoutConstraint.activate([
            tintOverlay.topAnchor.constraint(equalTo: glassEffectView.topAnchor),
            tintOverlay.leadingAnchor.constraint(equalTo: glassEffectView.leadingAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: glassEffectView.bottomAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: glassEffectView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        style: NSGlassEffectView.Style,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
        isKeyWindow: Bool
    ) {
        glassEffectView.style = style
        glassEffectView.tintColor = backgroundColor.withAlphaComponent(backgroundOpacity)
        glassEffectView.cornerRadius = cornerRadius ?? 0
        self.backgroundOpacity = CGFloat(backgroundOpacity)
        updateKeyStatus(isKeyWindow, backgroundColor: backgroundColor)
    }

    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }

    func updateKeyStatus(_ isKeyWindow: Bool, backgroundColor: NSColor) {
        let tint = tintProperties(for: backgroundColor)
        tintOverlay.layer?.backgroundColor = tint.color.cgColor
        // Scale by the window opacity so the inactive tint stays within the
        // translucency the user chose — otherwise an unfocused window reads as
        // near-opaque regardless of the opacity slider.
        tintOverlay.alphaValue = isKeyWindow ? 0 : tint.opacity * backgroundOpacity
    }

    /// A saturation-boosted tint + opacity for the inactive overlay, lifted
    /// from Ghostty's `tintProperties`.
    private func tintProperties(for color: NSColor) -> (color: NSColor, opacity: CGFloat) {
        let isLight = color.prefersDarkForeground
        let vibrant = color.adjustingSaturation(by: 1.2)
        let overlayOpacity: CGFloat = isLight ? 0.35 : 0.85
        return (vibrant, overlayOpacity)
    }
}

// MARK: - Window styling

/// Encapsulates the Tahoe-only window styling work needed to make the titlebar
/// blend with a transparent terminal background. AppKit gives us two surface
/// areas — the content view and a separate, system-owned titlebar view tree —
/// that don't compose visually with a single `backgroundColor` setting. To
/// make them look uniform we have to reach into the private titlebar hierarchy
/// and override its layer color directly.
///
/// Mirrors the `syncAppearanceTahoe` path in Ghostty's
/// `TransparentTitlebarTerminalWindow.swift`. Pre-Tahoe macOS releases need
/// different incantations (hiding NSVisualEffectView, etc.) — Macterm targets
/// macOS 26+ so we only ship the Tahoe path.
@MainActor
enum WindowAppearance {
    /// Apply the current opacity/blur settings to `window`. Safe to call any
    /// time — re-applies idempotently. Should be called after the window is
    /// onscreen, on theme changes, and on focus changes (AppKit recreates
    /// titlebar subviews under us in some cases, e.g. tab bar appearing).
    static func sync(window: NSWindow) {
        let opacity = Preferences.shared.windowOpacity
        let blurRadius = Preferences.shared.windowBlurRadius
        let bg = MactermTheme.nsBg
        let isTransparent = opacity < 1.0

        // Native fullscreen draws its own opaque grey background; widgets show
        // through any transparency we apply, so force opaque while fullscreened.
        let forceOpaque = window.styleMask.contains(.fullScreen)
        let effectiveTransparent = isTransparent && !forceOpaque

        // Liquid glass replaces the CGS blur when enabled. It only makes sense
        // while the window is translucent; at full opacity there's nothing to
        // see behind, so we fall back to the plain solid-background path.
        let useGlass = glassSupported && Preferences.shared.windowGlassEnabled && effectiveTransparent

        if effectiveTransparent {
            window.isOpaque = false
            if useGlass {
                // The NSGlassEffectView is the tinted layer. Keep the window
                // background itself clear so we don't double-tint over the
                // glass material.
                window.backgroundColor = .clear
                setWindowBackgroundBlur(window, radius: 0)
                syncGlass(window: window, backgroundColor: bg, opacity: opacity)
            } else {
                // The window's backgroundColor is the *only* tinted layer.
                // Ghostty renders fully transparent, the detail ZStack and
                // sidebar paint nothing, so the whole interior — including the
                // strip around the system glass sidebar — reads as one
                // continuous translucent surface backed by this color.
                window.backgroundColor = bg.withAlphaComponent(opacity)
                // Apply blur unconditionally; passing 0 clears any previous blur.
                setWindowBackgroundBlur(window, radius: blurRadius)
                removeGlass(window: window)
            }
        } else {
            window.isOpaque = true
            window.backgroundColor = bg
            // Make sure a previous blur is cleared when going opaque.
            setWindowBackgroundBlur(window, radius: 0)
            removeGlass(window: window)
        }

        // Override the titlebar's private background layer so its color
        // matches the terminal background (or stays transparent when the
        // window is). Without this the titlebar paints its own material
        // and you get a visible seam at y=titlebarHeight.
        syncTitlebar(window: window, isTransparent: effectiveTransparent)

        syncToolbar(window: window)

        disableSidebarEdgeHoverReveal(window: window)
        restoreSidebarWidth(window: window)
        enforceSidebarWidthLimit(window: window)
        _ = disableProactivePeekOnce
    }

    /// Reopen the sidebar at the width the user last dragged it to.
    ///
    /// Two SwiftUI mechanisms are supposed to cover this and neither does.
    /// `navigationSplitViewColumnWidth`'s `ideal:` is a documented preference,
    /// and measured here it is ignored outright — with a cleared autosave and
    /// `ideal: 250` the column still came up at 144, its content-derived width.
    /// SwiftUI's own autosave does record every drag, but under a key it can
    /// never read back: the name is `String(describing:)` of the WindowGroup's
    /// whole modifier-chain type, in which private types print as `(unknown
    /// context at $ADDR)` — a runtime address, so ASLR gives each launch a
    /// fresh key (49 of them, 49 distinct addresses, in one real defaults
    /// domain). `MainWindow` therefore persists the width itself and the
    /// restore is AppKit's: move the divider, the same reach-through
    /// `PinnedSidebar` makes in Settings, for the same reason.
    ///
    /// Once per launch, on the first `sync` that finds a split view laid out —
    /// from then on the column carries SwiftUI's in-session metric, which a
    /// user drag owns and which the peek's expand restores.
    private static var didRestoreSidebarWidth = false

    private static func restoreSidebarWidth(window: NSWindow) {
        guard !didRestoreSidebarWidth,
              let split = window.contentView?.firstSplitView,
              split.arrangedSubviews.count > 1,
              let sidebar = split.owningSplitViewController?.splitViewItems.first
        else { return }
        // Consumed as soon as the split view exists, collapsed or not. `sync`
        // also runs on every window-became-main, so an arm left standing would
        // later snap a width the user had since dragged.
        didRestoreSidebarWidth = true
        pinSidebarAutosaveName(split: split)
        // A sidebar the user left hidden must stay hidden: moving divider 0 on
        // a collapsed item is what would pop it open on every launch. Showing
        // it mid-session then gives SwiftUI's own width — the next launch with
        // it visible restores properly.
        guard !sidebar.isCollapsed else { return }
        // The frozen launch value, never the live property — see its doc.
        let width = CGFloat(Preferences.shared.launchSidebarWidth)
        split.setPosition(width, ofDividerAt: 0)
        logger.info("sidebar width restored to \(width, privacy: .public)")
    }

    /// Cap the sidebar column at `Preferences.sidebarWidthRange`'s upper bound.
    ///
    /// `navigationSplitViewColumnWidth`'s `max:` is as much a preference as its
    /// `ideal:` — the column drags straight past it, across half the window.
    /// The bound that actually binds is `NSSplitViewItem.maximumThickness`, but
    /// it doesn't *stay* applied: SwiftUI re-applies its own column metrics on
    /// events we can't enumerate (`PinnedSidebar` in Settings fights the same
    /// reset). So besides asserting it here on every `sync`, the cap is
    /// re-asserted from `NSSplitView.didResizeSubviewsNotification` — the one
    /// notification a divider drag is guaranteed to fire, since a drag never
    /// resizes the window — and any width that slipped past before the
    /// re-assert landed is snapped back to the limit.
    ///
    /// Only the maximum is enforced. The minimum is SwiftUI's to manage: a
    /// drag-to-collapse legitimately passes below it, and pinning
    /// `minimumThickness` would fight that animation.
    private struct SidebarClamp {
        // A struct field, not a `static weak var` — the swiftformat and
        // swiftlint configs disagree on that modifier order and reject each
        // other's spelling.
        weak var split: NSSplitView?
        let observer: any NSObjectProtocol
    }

    private static var sidebarClamp: SidebarClamp?
    /// Guards the re-assert: `setPosition` inside a resize notification posts
    /// another one, which would recurse.
    private static var isClampingSidebarWidth = false

    private static func enforceSidebarWidthLimit(window: NSWindow) {
        guard let split = window.contentView?.firstSplitView,
              split.owningSplitViewController?.splitViewItems.first != nil
        else { return }
        clampSidebarWidth(split: split)
        // One observer on the current split view; re-keyed if SwiftUI ever
        // rebuilds it.
        guard sidebarClamp?.split !== split else { return }
        if let clamp = sidebarClamp {
            NotificationCenter.default.removeObserver(clamp.observer)
        }
        let observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: split,
            queue: .main
        ) { [weak split] _ in
            guard let split else { return }
            MainActor.assumeIsolated { clampSidebarWidth(split: split) }
        }
        sidebarClamp = SidebarClamp(split: split, observer: observer)
    }

    private static func clampSidebarWidth(split: NSSplitView) {
        guard !isClampingSidebarWidth,
              let sidebar = split.owningSplitViewController?.splitViewItems.first,
              !sidebar.isCollapsed
        else { return }
        isClampingSidebarWidth = true
        defer { isClampingSidebarWidth = false }
        let limit = CGFloat(Preferences.sidebarWidthRange.upperBound)
        sidebar.maximumThickness = limit
        if sidebar.viewController.view.frame.width > limit + 0.5 {
            split.setPosition(limit, ofDividerAt: 0)
        }
    }

    /// Our own autosave name for the sidebar split view, and a sweep of the
    /// keys SwiftUI's name left behind.
    ///
    /// AppKit's autosave key is `NSSplitView Subview Frames <autosaveName>`,
    /// so SwiftUI's address-bearing name (see above) doesn't just fail to
    /// restore — it writes a **brand-new key on every launch**, forever. They
    /// accumulate unread: 9 in one release domain, 51 in a debug one. Pinning
    /// the name gives AppKit a single key it rewrites in place.
    ///
    /// This is hygiene, not the restore: `restoreSidebarWidth` above stays the
    /// authority on the launch width, because when AppKit consults its own
    /// autosave relative to SwiftUI's layout pass is exactly what isn't
    /// dependable here.
    private static let sidebarAutosaveName = "MactermMainSidebar"

    private static func pinSidebarAutosaveName(split: NSSplitView) {
        guard split.autosaveName != sidebarAutosaveName else { return }
        split.autosaveName = sidebarAutosaveName
        pruneChurnedSidebarAutosaveKeys()
    }

    /// Drop the per-launch keys written before the name was pinned. Matched on
    /// the address marker, so the stable names (ours, and the Settings
    /// window's `com_apple_SwiftUI_Settings_window…`) are never touched.
    ///
    /// Reads `UserDefaults.standard` deliberately, against the usual rule:
    /// AppKit wrote these keys to the app's real domain, so that is the only
    /// place they exist. Skipped under a test run so a hosted suite can't
    /// reach into the developer's live domain.
    private static func pruneChurnedSidebarAutosaveKeys() {
        guard !Preferences.isTestRun else { return }
        let defaults = UserDefaults.standard
        let stale = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("NSSplitView Subview Frames ") && $0.contains("(unknown context at $")
        }
        guard !stale.isEmpty else { return }
        for key in stale {
            defaults.removeObject(forKey: key)
        }
        logger.info("pruned \(stale.count, privacy: .public) churned sidebar autosave keys")
    }

    /// Kill NSSplitView's windowed "proactive peek" of the collapsed sidebar:
    /// it pops a minimum-width overlay that crams the traffic lights against
    /// the toolbar, never retracts, and races `MainWindow`'s own hover peek —
    /// when ours uncollapses the column mid-engage, the native peek's state is
    /// freed and `mouseExited:` → `_cancelProactivePeek` crashes on it (seen
    /// in a real crash log). There is no per-item opt-out and its tracker
    /// views reinstall on every collapse, so the race-free kill is replacing
    /// the one gate every engage path consults (verified by disassembly) with
    /// a constant NO. If an OS update drops the method this no-ops — the cost
    /// is the native peek returning, never a crash.
    private static let disableProactivePeekOnce: Void = {
        let gate = Selector(("_canDoSidebarProactivePeek"))
        guard let method = class_getInstanceMethod(NSSplitView.self, gate) else {
            logger.info("proactive-peek gate not found; native peek left as is")
            return
        }
        let no: @convention(block) (NSSplitView) -> Bool = { _ in false }
        method_setImplementation(method, imp_implementationWithBlock(no))
        logger.info("sidebar proactive peek disabled")
    }()

    /// Stop AppKit's edge-hover reveal of the collapsed sidebar — the peek's
    /// fullscreen sibling. Sidebar `NSSplitViewItem`s default the private
    /// `revealsOnEdgeHoverInFullscreen` flag to true; clearing it and
    /// re-running `_updateHasItemToRevealOnEdgeHover` (which derives "anything
    /// to reveal" solely from that flag and `canCollapse*`, verified by
    /// disassembly) tears the hover tracking down. `MainWindow`'s hover peek
    /// replaces both native mechanisms. SPI, so probed with `responds(to:)`
    /// and a silent no-op if an OS update removes it.
    private static func disableSidebarEdgeHoverReveal(window: NSWindow) {
        guard let split = window.contentView?.firstSplitView,
              let controller = split.owningSplitViewController,
              let sidebar = controller.splitViewItems.first
        else { return }
        let flag = "revealsOnEdgeHoverInFullscreen"
        guard sidebar.responds(to: Selector(("setRevealsOnEdgeHoverInFullscreen:"))),
              (sidebar.value(forKey: flag) as? Bool) == true
        else { return }
        sidebar.setValue(false, forKey: flag)
        let update = Selector(("_updateHasItemToRevealOnEdgeHover"))
        if controller.responds(to: update) {
            controller.perform(update)
        }
        logger.info("sidebar edge-hover reveal disabled")
    }

    /// Apply the current opacity/blur/glass settings to the quick-terminal
    /// panel. The window-background slice of `sync(window:)` only: a borderless
    /// panel has no titlebar, sidebar, or toolbar to style, but it must make
    /// the same glass-vs-blur-vs-solid decision as the main window or the
    /// liquid glass setting silently degrades to the legacy blur there.
    ///
    /// The panel's tint deliberately lives here (window `backgroundColor` /
    /// glass tint), not in its SwiftUI content — a tinted SwiftUI background
    /// over an installed glass view would double-tint it, the same
    /// double-paint problem `macterm-overrides.conf` pins
    /// `background-opacity = 0` to avoid.
    static func syncPanel(_ panel: NSPanel) {
        let opacity = Preferences.shared.windowOpacity
        let bg = MactermTheme.nsBg
        let isTransparent = opacity < 1.0
        let useGlass = glassSupported && Preferences.shared.windowGlassEnabled && isTransparent

        if isTransparent {
            panel.isOpaque = false
            if useGlass {
                panel.backgroundColor = .clear
                setWindowBackgroundBlur(panel, radius: 0)
                syncGlass(window: panel, backgroundColor: bg, opacity: opacity)
            } else {
                panel.backgroundColor = bg.withAlphaComponent(opacity)
                setWindowBackgroundBlur(panel, radius: Preferences.shared.windowBlurRadius)
                removeGlass(window: panel)
            }
        } else {
            panel.isOpaque = true
            panel.backgroundColor = bg
            setWindowBackgroundBlur(panel, radius: 0)
            removeGlass(window: panel)
        }
    }

    /// Update the inactive-glass tint when the window gains/loses key status.
    /// Cheap no-op unless the glass view is currently installed.
    static func syncKeyStatus(window: NSWindow) {
        guard glassSupported else { return }
        if #available(macOS 26.0, *) {
            guard let glass = existingGlass(in: window) else { return }
            glass.updateKeyStatus(window.isKeyWindow, backgroundColor: MactermTheme.nsBg)
        }
    }

    /// Lock the toolbar to icon-only rendering. SwiftUI's NavigationSplitView
    /// toolbar doesn't survive the label display modes: picking "Icon and
    /// Text" from the toolbar's context menu makes AppKit fold the system
    /// sidebar-toggle item into the overflow (») menu at the trailing edge
    /// and grows the titlebar without showing any useful labels. Disabling
    /// display-mode customization removes those context-menu items; forcing
    /// `.iconOnly` repairs a mode picked before the lock existed.
    private static func syncToolbar(window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        if toolbar.displayMode != .iconOnly { toolbar.displayMode = .iconOnly }
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
    }

    /// Liquid glass (`NSGlassEffectView`) exists only on macOS 26+. Drives both
    /// the runtime appearance path and the Settings UI's glass controls.
    static var glassSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    // MARK: Liquid glass

    /// Install (if needed) and configure the liquid-glass background view so it
    /// fills the window behind SwiftUI's content, including the area under the
    /// titlebar. Follows Ghostty's `updateGlassEffectIfNeeded` pattern.
    private static func syncGlass(window: NSWindow, backgroundColor: NSColor, opacity: Double) {
        guard #available(macOS 26.0, *) else { return }
        guard let contentView = window.contentView, let themeFrame = contentView.superview else { return }

        let glass = existingGlass(in: window) ?? {
            let view = MactermGlassView(topOffset: -contentView.safeAreaInsets.top)
            // Below the content view so SwiftUI (sidebar, terminal, toolbar)
            // composites on top of the glass.
            themeFrame.addSubview(view, positioned: .below, relativeTo: contentView)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: themeFrame.topAnchor),
                view.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
                view.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
                view.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
            ])
            return view
        }()

        glass.updateTopInset(-contentView.safeAreaInsets.top)
        glass.configure(
            style: officialGlassStyle(Preferences.shared.windowGlassStyle),
            backgroundColor: backgroundColor,
            backgroundOpacity: opacity,
            cornerRadius: windowCornerRadius(window),
            isKeyWindow: window.isKeyWindow
        )
    }

    @available(macOS 26.0, *)
    private static func officialGlassStyle(_ style: WindowGlassStyle) -> NSGlassEffectView.Style {
        switch style {
        case .regular: .regular
        case .clear: .clear
        }
    }

    private static func removeGlass(window: NSWindow) {
        guard glassSupported else { return }
        if #available(macOS 26.0, *) {
            existingGlass(in: window)?.removeFromSuperview()
        }
    }

    @available(macOS 26.0, *)
    private static func existingGlass(in window: NSWindow) -> MactermGlassView? {
        guard let themeFrame = window.contentView?.superview else { return nil }
        return themeFrame.subviews.compactMap { $0 as? MactermGlassView }.first
    }

    /// The window's private corner radius, so the glass clips to the same
    /// rounded corners as the window. Falls back to nil (square) if the SPI
    /// is unavailable.
    private static func windowCornerRadius(_ window: NSWindow) -> CGFloat? {
        guard window.responds(to: Selector(("_cornerRadius"))) else { return nil }
        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    /// Apply the Hide Title Bar option (#226) to the window: hide the titlebar
    /// container, and disable click-dragging while the option is on.
    ///
    /// Hiding the window toolbar collapses the visible chrome, but two drag
    /// paths survive it. The collapsed titlebar container still tracks its old
    /// rect and swallows events over an invisible strip — hiding the container
    /// (as Ghostty's hidden titlebar style does) lets those reach the content.
    /// Even then, a `.fullSizeContentView` window keeps a titlebar-height drag
    /// band (the area above `contentLayoutRect`) that moves the window from any
    /// hit view answering `mouseDownCanMoveWindow` — Ghostty removes it by
    /// overriding `contentLayoutRect` on its NSWindow subclass, but SwiftUI
    /// owns our window class, so the public equivalent is `isMovable = false`:
    /// no user drags anywhere while hidden (programmatic moves, including
    /// window managers driving Accessibility, still work). Runs on every
    /// `sync` so AppKit rebuilding the titlebar subviews (becomeMain,
    /// fullscreen transitions) re-asserts it; `WindowStyler.updateNSView`
    /// calls it directly for live setting flips.
    static func syncTitleBarHidden(window: NSWindow) {
        let hidden = Preferences.shared.hideTitleBar
        titlebarContainer(in: window)?.isHidden = hidden
        window.isMovable = !hidden
        // SwiftUI's `.toolbar(.hidden, for: .windowToolbar)` collapses the
        // windowed titlebar but keeps the NSToolbar object on the window, and
        // in native fullscreen AppKit creates a 52pt NSToolbarFullScreenWindow
        // overlay for any window that owns a toolbar — an empty bar pinned to
        // the top of the fullscreen space. Toggling the toolbar's own
        // visibility removes the overlay; symmetric so leaving the mode (or
        // flipping the setting mid-fullscreen) restores it.
        window.toolbar?.isVisible = !hidden
        // Even toolbar-less, the overlay hosts a bare titlebar that the system
        // slides down alongside the menu bar when the pointer pushes past the
        // top of the fullscreen space, and its gray background is
        // system-painted — it ignores `titlebarAppearsTransparent`. A plain
        // `alphaValue = 0` did not survive either: the reveal animates the
        // overlay's alpha back in (observed live — the bar returned
        // translucent, mid-animation). So blank the window's whole view tree
        // from the root: the slide can animate whatever alpha it likes over a
        // window that renders nothing. The root survives the reveal's subview
        // rebuilds, and every sync re-asserts anyway. The menu bar is a
        // separate system window and still slides in for menu access.
        if let overlay = fullscreenToolbarOverlay(for: window) {
            overlay.alphaValue = hidden ? 0 : 1
            let root = overlay.contentView?.superview ?? overlay.contentView
            root?.isHidden = hidden
        }
        // The macOS 26+ scroll-edge-effect pocket: AppKit hosts it in the
        // titlebar area (moved there on macOS 27, ghostty#13390) where it sits
        // over the terminal's top rows and blocks clicks/selection once the
        // chrome is gone. Hiding NSTitlebarBackgroundView doesn't cover it, so
        // hide every pocket directly — one can exist per scroll view. On
        // systems without the class the walk finds nothing.
        window.contentView?.superview?.forEachDescendant(withClassName: "NSScrollPocket") {
            $0.isHidden = hidden
        }
    }

    private static func syncTitlebar(window: NSWindow, isTransparent: Bool) {
        guard let container = titlebarContainer(in: window) else { return }

        syncTitleBarHidden(window: window)

        if let titlebarView = container.firstDescendant(withClassName: "NSTitlebarView") {
            titlebarView.wantsLayer = true
            // On Tahoe, the NavigationSplitView's sidebar is a liquid-glass
            // surface that extends behind the titlebar by design. Painting
            // any flat color on the titlebar layer draws a band over that
            // glass and creates a visible seam. Keep the layer transparent
            // and let AppKit's default titlebar materials (or the content
            // view, with `.fullSizeContentView`) show through in both modes.
            titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        // NSTitlebarBackgroundView has subviews that force their own background
        // colors; hide it only when transparent, so the default opaque-mode
        // chrome stays intact.
        container.firstDescendant(withClassName: "NSTitlebarBackgroundView")?.isHidden = isTransparent
    }

    private static func titlebarContainer(in window: NSWindow) -> NSView? {
        // The titlebar container lives on the window's content view's root in
        // normal mode. In native fullscreen AppKit hosts it in a separate
        // NSToolbarFullScreenWindow parented to ours — without following that
        // hop, a hidden toolbar left an empty bar pinned to the top of the
        // fullscreen space (#226). Ghostty's TerminalWindow resolves it the
        // same way; matching on `parent` picks the right overlay when several
        // fullscreen windows exist.
        guard window.styleMask.contains(.fullScreen) else {
            return findTitlebarContainer(from: window.contentView)
        }
        return findTitlebarContainer(from: fullscreenToolbarOverlay(for: window)?.contentView)
    }

    /// The NSToolbarFullScreenWindow AppKit parents to `window` in native
    /// fullscreen; nil outside fullscreen or before the overlay exists.
    private static func fullscreenToolbarOverlay(for window: NSWindow) -> NSWindow? {
        guard window.styleMask.contains(.fullScreen) else { return nil }
        return NSApp.windows.first {
            $0.className == "NSToolbarFullScreenWindow" && $0.parent == window
        }
    }

    /// Root-walk then search: the container is an ancestor sibling of the
    /// content view, so the lookup climbs to the theme frame first.
    private static func findTitlebarContainer(from contentView: NSView?) -> NSView? {
        guard let contentView else { return nil }
        var root: NSView = contentView
        while let s = root.superview {
            root = s
        }
        if String(describing: type(of: root)) == "NSTitlebarContainerView" { return root }
        return root.firstDescendant(withClassName: "NSTitlebarContainerView")
    }
}
