import AppKit
import SwiftUI

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
}

// MARK: - Color helpers (for the inactive-glass tint)

extension NSColor {
    /// Perceptual luminance in 0...1, computed in sRGB. Returns 0 for colors
    /// that can't be converted to an RGB space (e.g. pattern colors).
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    var isLightColor: Bool { luminance > 0.5 }

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
/// glass material) plus an inactive-window tint overlay. Mirrors Ghostty's
/// `TerminalGlassView` (`TerminalViewContainer.swift`). Macterm inserts this
/// below the window's content view, filling the whole window — including the
/// region under the titlebar (via a negative top inset equal to the content
/// view's top safe-area inset) — so the glass reads as one continuous surface
/// behind the sidebar, titlebar, and terminal.
@available(macOS 26.0, *)
final class MactermGlassView: NSView {
    private let glassEffectView = NSGlassEffectView()
    private let tintOverlay = NSView()
    private var topConstraint: NSLayoutConstraint!

    /// The window opacity the glass is currently configured for. The inactive
    /// tint is scaled by this so an unfocused window never reads as more opaque
    /// than the user asked for — at 30% opacity the desaturation overlay is far
    /// subtler than at 100%.
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
        // resigns key, matching how the system desaturates inactive glass.
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
        let isLight = color.isLightColor
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
        let bg = GhosttyApp.shared.backgroundColor
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

    /// Update the inactive-glass tint when the window gains/loses key status.
    /// Cheap no-op unless the glass view is currently installed.
    static func syncKeyStatus(window: NSWindow) {
        guard glassSupported else { return }
        if #available(macOS 26.0, *) {
            guard let glass = existingGlass(in: window) else { return }
            glass.updateKeyStatus(window.isKeyWindow, backgroundColor: GhosttyApp.shared.backgroundColor)
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

    private static func syncTitlebar(window: NSWindow, isTransparent: Bool) {
        guard let container = titlebarContainer(in: window) else { return }

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
        // normal mode, and on a separate NSToolbarFullScreenWindow in native
        // fullscreen. We don't support native fullscreen tab bars, so the
        // first path suffices for Macterm.
        guard let contentView = window.contentView else { return nil }
        var root: NSView = contentView
        while let s = root.superview {
            root = s
        }
        if String(describing: type(of: root)) == "NSTitlebarContainerView" { return root }
        return root.firstDescendant(withClassName: "NSTitlebarContainerView")
    }
}
