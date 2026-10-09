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

// MARK: - Tinted backdrop

/// The alpha the renderer paints a cell background with at this window opacity.
///
/// ghostty truncates (`@intFromFloat(255 * background_opacity)` in
/// `renderer/generic.zig`), so a tint carrying the raw preference sits a
/// fraction of a count above the terminal's own paint. Invisible over a dark
/// backdrop, but the whole point here is that the two match exactly.
@MainActor
func rendererQuantizedAlpha(_ opacity: Double) -> CGFloat {
    CGFloat(UInt8(clamping: Int(255 * max(0, min(1, opacity))))) / 255
}

/// A pane's claim on the window tint, in a container's coordinates: the
/// pane's whole `frame` is cut out of the window tint and refilled with the
/// pane's own `color` at the window opacity, except under `painted`, where the
/// terminal's cells already carry that color at that opacity.
struct TerminalPaintRegion: Equatable {
    var frame: CGRect
    var painted: CGRect
    /// The pure hue; the cutout applies the window opacity itself.
    var color: CGColor

    /// This region, given in `view`'s coordinates, in its window's.
    @MainActor
    func inWindow(of view: NSView) -> TerminalPaintRegion {
        TerminalPaintRegion(frame: view.convert(frame, to: nil), painted: view.convert(painted, to: nil), color: color)
    }

    /// This region, given in window coordinates, in `view`'s.
    @MainActor
    func fromWindow(into view: NSView) -> TerminalPaintRegion {
        TerminalPaintRegion(frame: view.convert(frame, from: nil), painted: view.convert(painted, from: nil), color: color)
    }
}

/// The cut a window's tinted backdrop takes where a terminal is painting its
/// own background at the window opacity, and the pane-colored tint that
/// replaces it around that paint.
///
/// Both translucency paths need the cut for the same reason. The tint is one
/// layer at `opacity`; a TUI's cells are a second layer at the same `opacity`
/// on top of it, so the pane composites to `1-(1-opacity)²` while the chrome
/// beside it stays at plain `opacity` — the pane reads near-solid next to a
/// translucent app. Cutting the tint under the paint leaves exactly one tinted
/// layer everywhere: the terminal's own inside the paint, the backdrop's
/// outside it. Only the tint is cut, never the material or blur behind it, so
/// both surfaces keep the same backdrop.
///
/// The refill is what gives a pane its *padding*. libghostty leaves
/// `window-padding` unpainted, so inside the paint the pane shows the TUI's
/// color and in the margin around it whatever the window tint is — the TUI's
/// color only while a lone pane has lent it to the whole window. In a split
/// the window keeps the configured theme, and every pane's margin showed that
/// theme as a frame around the TUI. So the cut is the whole pane, and the
/// margin is refilled with the pane's own color at the same opacity, on a
/// sibling layer the mask doesn't reach. The refill is cut under the paint
/// for the same double-layer reason the tint is.
struct TintCutout {
    private let mask = CAShapeLayer()
    private var regions: [TerminalPaintRegion] = []

    /// Returns true when the regions actually changed — this runs on every
    /// sample, and rebuilding identical layers is wasted render work.
    mutating func set(_ regions: [TerminalPaintRegion]) -> Bool {
        guard regions != self.regions else { return false }
        self.regions = regions
        return true
    }

    /// Cut `tint` (a tinted layer) around the regions and lay their refills on
    /// `refill`, a sibling above it. Regions are in `container`'s coordinates;
    /// `alpha` is the opacity the tint itself is drawn at.
    @MainActor
    func apply(to tint: NSView, refill: NSView, alpha: CGFloat, in container: NSView) {
        refill.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let layer = tint.layer else { return }
        guard !regions.isEmpty else {
            layer.mask = nil
            return
        }
        let path = CGMutablePath()
        path.addRect(tint.bounds)
        for region in regions {
            path.addRect(tint.convert(region.frame, from: container))
        }
        mask.frame = tint.bounds
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        mask.path = path
        layer.mask = mask

        for region in regions {
            let margin = CAShapeLayer()
            let outline = CGMutablePath()
            outline.addRect(refill.convert(region.frame, from: container))
            outline.addRect(refill.convert(region.painted, from: container))
            margin.frame = refill.bounds
            margin.fillRule = .evenOdd
            margin.fillColor = region.color.copy(alpha: alpha)
            margin.path = outline
            refill.layer?.addSublayer(margin)
        }
    }
}

/// The flat tinted backdrop for the plain (non-glass) translucency path.
///
/// The tint used to be `NSWindow.backgroundColor`, which is simpler but cannot
/// be cut: AppKit draws it beneath the whole window and no view can subtract
/// from it. A view can be masked, which is the only reason this exists — it
/// carries the same color at the same opacity, with the CGS blur still behind
/// it, and mirrors how the glass path installs `MactermGlassView`.
final class MactermTintBackdropView: NSView {
    private let tintView = NSView()
    /// The pane-colored refills of `TintCutout`, above the (masked) tint.
    private let refillView = NSView()
    private var topConstraint: NSLayoutConstraint!
    private var cutout = TintCutout()
    private var tintAlpha: CGFloat = 1

    init(topOffset: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        addSubview(tintView)
        topConstraint = tintView.topAnchor.constraint(equalTo: topAnchor, constant: topOffset)
        NSLayoutConstraint.activate([
            topConstraint,
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refillView.translatesAutoresizingMaskIntoConstraints = false
        refillView.wantsLayer = true
        addSubview(refillView, positioned: .above, relativeTo: tintView)
        NSLayoutConstraint.activate([
            refillView.topAnchor.constraint(equalTo: tintView.topAnchor),
            refillView.leadingAnchor.constraint(equalTo: tintView.leadingAnchor),
            refillView.bottomAnchor.constraint(equalTo: tintView.bottomAnchor),
            refillView.trailingAnchor.constraint(equalTo: tintView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sits behind the content view purely to be looked at; never takes a click.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }

    func configure(backgroundColor: NSColor, backgroundOpacity: Double, cornerRadius: CGFloat?) {
        tintAlpha = rendererQuantizedAlpha(backgroundOpacity)
        tintView.layer?.backgroundColor = backgroundColor
            .withAlphaComponent(tintAlpha)
            .cgColor
        tintView.layer?.cornerRadius = cornerRadius ?? 0
        // The system's corners are continuous. Inside a titled window the
        // window's own mask decides the visible shape either way; on a
        // borderless desktop widget this layer IS the shape.
        tintView.layer?.cornerCurve = .continuous
    }

    func setPaintRegions(_ regions: [TerminalPaintRegion]) {
        guard cutout.set(regions) else { return }
        cutout.apply(to: tintView, refill: refillView, alpha: tintAlpha, in: self)
    }

    override func layout() {
        super.layout()
        cutout.apply(to: tintView, refill: refillView, alpha: tintAlpha, in: self)
    }
}

// MARK: - Liquid glass background

/// A container that hosts a macOS 26 `NSGlassEffectView` (the real liquid
/// glass material) under Macterm's own tint layer. This is the deliberate
/// divergence from Ghostty, which puts the color *under* its glass (SwiftUI
/// `.glassEffect`, since fd17869d1): the tint has to sit as a separate layer
/// above the material so `TintCutout` can cut it out from under a pane.
///
/// **The tint does not depend on key status.** It used to: an overlay faded a
/// saturation-boosted tint of the background in as the window resigned key,
/// lifted from the Ghostty of the time, where the tint lived *inside* the
/// material as `NSGlassEffectView.tintColor` and so took the material's own
/// inactive desaturation with it — a large enough change to need compensating
/// for. Macterm's tint, being above the material, never took that
/// desaturation, and the overlay was compensating for something that wasn't
/// happening: an unfocused window visibly gained opacity, the wallpaper behind
/// it dropping out (measured 39,39,50 → 29,27,39 through the terminal area).
/// Ghostty has since dropped its overlay too. What remains on unfocus is the
/// material's own inactive desaturation (and the native sidebar's — blue −5
/// measured there), which is the only key-status dependency left in the
/// window's appearance. Don't reintroduce a focus-dependent tint here.
///
/// Macterm inserts this below the window's content view, filling the whole
/// window — including the region under the titlebar (via a negative top inset
/// equal to the content view's top safe-area inset) — so the glass reads as
/// one continuous surface behind the sidebar, titlebar, and terminal.
@available(macOS 26.0, *)
final class MactermGlassView: NSView {
    private let glassEffectView = NSGlassEffectView()
    private let tintView = NSView()
    /// The pane-colored refills of `TintCutout`, above the (masked) tint.
    private let refillView = NSView()
    private var topConstraint: NSLayoutConstraint!
    private var tintCutout = TintCutout()
    private var tintAlpha: CGFloat = 1

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

        // The window tint is its own layer above the bare glass material,
        // rather than `NSGlassEffectView.tintColor`, for one reason: a tint
        // baked into the material cannot be cut away under a pane whose TUI is
        // already painting that same color at the same opacity, and that
        // double layer is what makes such a pane read near-solid beside
        // chrome at the plain opacity. Cutting the tint keeps the *material*
        // under the pane, so both surfaces sit on the same backdrop.
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        addSubview(tintView, positioned: .above, relativeTo: glassEffectView)
        NSLayoutConstraint.activate([
            tintView.topAnchor.constraint(equalTo: glassEffectView.topAnchor),
            tintView.leadingAnchor.constraint(equalTo: glassEffectView.leadingAnchor),
            tintView.bottomAnchor.constraint(equalTo: glassEffectView.bottomAnchor),
            tintView.trailingAnchor.constraint(equalTo: glassEffectView.trailingAnchor),
        ])
        refillView.translatesAutoresizingMaskIntoConstraints = false
        refillView.wantsLayer = true
        addSubview(refillView, positioned: .above, relativeTo: tintView)
        NSLayoutConstraint.activate([
            refillView.topAnchor.constraint(equalTo: tintView.topAnchor),
            refillView.leadingAnchor.constraint(equalTo: tintView.leadingAnchor),
            refillView.bottomAnchor.constraint(equalTo: tintView.bottomAnchor),
            refillView.trailingAnchor.constraint(equalTo: tintView.trailingAnchor),
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
        cornerRadius: CGFloat?
    ) {
        glassEffectView.style = style
        glassEffectView.cornerRadius = cornerRadius ?? 0
        tintAlpha = rendererQuantizedAlpha(backgroundOpacity)
        tintView.layer?.backgroundColor = backgroundColor
            .withAlphaComponent(tintAlpha)
            .cgColor
        tintView.layer?.cornerRadius = cornerRadius ?? 0
        tintView.layer?.cornerCurve = .continuous
    }

    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }

    /// Cut the tint away under panes painting their own background at the
    /// window opacity, and refill their margins in their own colors (`regions`
    /// in this view's coordinates). The glass material stays, so the pane and
    /// the chrome sit on the same backdrop.
    func setPaintRegions(_ regions: [TerminalPaintRegion]) {
        guard tintCutout.set(regions) else { return }
        applyPaintRegions()
    }

    override func layout() {
        super.layout()
        applyPaintRegions()
    }

    private func applyPaintRegions() {
        tintCutout.apply(to: tintView, refill: refillView, alpha: tintAlpha, in: self)
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
    /// onscreen, on theme changes, when the window becomes main, and around
    /// fullscreen transitions (AppKit recreates titlebar subviews under us in
    /// some cases, e.g. tab bar appearing). Not on key changes: nothing here
    /// depends on key status (see `MactermGlassView`).
    static func sync(window: NSWindow) {
        let opacity = Preferences.shared.windowOpacity
        let blurRadius = Preferences.shared.windowBlurRadius
        // This window's own tint (#345) — never the app-wide one, or a
        // background window paints the focused window's terminal colour.
        let bg = MactermTheme.nsBg(for: window)
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
                removeTintBackdrop(window: window)
                syncGlass(window: window, backgroundColor: bg, opacity: opacity, cornerRadius: windowCornerRadius(window))
            } else {
                // One tinted layer for the whole interior — including the strip
                // around the system glass sidebar — so it reads as a single
                // continuous translucent surface. It lives in a view rather
                // than `window.backgroundColor` for one reason: a window's own
                // background cannot be cut where a terminal paints its
                // background itself, and that uncut second layer is what makes
                // such a pane read near-solid. See `TintCutout`.
                window.backgroundColor = .clear
                // Apply blur unconditionally; passing 0 clears any previous blur.
                setWindowBackgroundBlur(window, radius: blurRadius)
                removeGlass(window: window)
                syncTintBackdrop(
                    window: window,
                    backgroundColor: bg,
                    opacity: opacity,
                    cornerRadius: windowCornerRadius(window)
                )
            }
        } else {
            window.isOpaque = true
            window.backgroundColor = bg
            // Make sure a previous blur is cleared when going opaque.
            setWindowBackgroundBlur(window, radius: 0)
            removeGlass(window: window)
            removeTintBackdrop(window: window)
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
    /// Per-window sidebar bookkeeping: whether the width has been restored,
    /// the width it is waiting for, and its autosave slot.
    ///
    /// These were a single app-wide flag and a single stored width, so only
    /// the FIRST window ever restored and every other opened at SwiftUI's
    /// content-derived default (#345). Keyed weakly by the window itself, not
    /// by `ObjectIdentifier`: an identifier is an address, and a closed
    /// window's address can be handed to the next window allocated — which
    /// would then read as already restored, or inherit a slot, if the forget
    /// path had not run. A weak-keyed table drops the record with the window.
    /// What a window's sidebar should come up as, once the app knows.
    struct SidebarRestorePlan {
        let width: CGFloat
        let visible: Bool
    }

    private final class SidebarRecord {
        var restored = false
        /// nil until the snapshot has been read — the restore waits for it.
        var plan: (() -> SidebarRestorePlan?)?
        var autosaveSlot: Int?
    }

    private static let sidebarRecords = NSMapTable<NSWindow, SidebarRecord>.weakToStrongObjects()

    private static func sidebarRecord(for window: NSWindow) -> SidebarRecord {
        if let existing = sidebarRecords.object(forKey: window) { return existing }
        let record = SidebarRecord()
        sidebarRecords.setObject(record, forKey: window)
        return record
    }

    /// Tell the restore what this window's sidebar should come up as.
    ///
    /// `plan` is evaluated when the restore actually runs and may answer nil
    /// for "not yet": the window arms this as it attaches, which is before the
    /// launch task has read the saved windows out of the snapshot — a value
    /// captured here was sometimes the pre-restore default, and the first cut
    /// of this restored 144 over 144.
    ///
    /// The restore is then RETRIED across run-loop ticks until it lands.
    /// `sync` runs at attach and on became-main; at attach the split view is
    /// usually not laid out yet, so a window that never became main sat at
    /// SwiftUI's content-derived minimum until the user focused it — the
    /// reported "restored window has a minimum-width sidebar until I click
    /// it". Bounded, so a window that never lays out cannot spin.
    static func armSidebarWidthRestore(for window: NSWindow, plan: @escaping () -> SidebarRestorePlan?) {
        let record = sidebarRecord(for: window)
        guard !record.restored else { return }
        record.plan = plan
        retrySidebarRestore(window, remaining: 80)
    }

    private static func retrySidebarRestore(_ window: NSWindow, remaining: Int) {
        guard remaining > 0 else {
            logger.warning("sidebar restore gave up: split view never became ready")
            return
        }
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let window, let record = sidebarRecords.object(forKey: window), !record.restored else { return }
            restoreSidebarWidth(window: window)
            if !record.restored { retrySidebarRestore(window, remaining: remaining - 1) }
        }
    }

    /// Whether `window` is still waiting to have its sidebar restored.
    ///
    /// While it is, the column is showing SwiftUI's content-derived width, and
    /// recording that would overwrite the width being restored with the
    /// default it is meant to replace.
    static func isAwaitingSidebarWidthRestore(for window: NSWindow?) -> Bool {
        guard let window, let record = sidebarRecords.object(forKey: window) else { return false }
        return record.plan != nil && !record.restored
    }

    static func forgetSidebarWidthRestore(for window: NSWindow) {
        if let slot = sidebarRecords.object(forKey: window)?.autosaveSlot {
            clearSidebarAutosave(slot: slot)
        }
        sidebarRecords.removeObject(forKey: window)
    }

    /// The actual native sidebar state after AppKit has restored its split-view
    /// autosave. SwiftUI's `columnVisibility` binding can still say `.automatic`
    /// while this item is collapsed, so launch-time hover must synchronize from
    /// this native value rather than trusting the binding.
    static func sidebarIsVisible(window: NSWindow) -> Bool? {
        guard let split = window.contentView?.firstSplitView,
              let sidebar = split.owningSplitViewController?.splitViewItems.first
        else { return nil }
        return !sidebar.isCollapsed
    }

    private static func restoreSidebarWidth(window: NSWindow) {
        guard let record = sidebarRecords.object(forKey: window),
              !record.restored,
              let split = window.contentView?.firstSplitView,
              split.arrangedSubviews.count > 1,
              let sidebar = split.owningSplitViewController?.splitViewItems.first
        else { return }
        // The snapshot has not been read yet: the retry comes back.
        guard let plan = record.plan?() else { return }
        pinSidebarAutosaveName(split: split, window: window)
        // The window's own record decides visibility (#345), not the state
        // AppKit autosaved for this slot. A hidden sidebar has no width to
        // restore: consume, and leave it collapsed for SwiftUI's column
        // binding, which follows the same record.
        if !plan.visible {
            record.restored = true
            record.plan = nil
            return
        }
        // Visible by record but collapsed on screen — AppKit's autosaved
        // state, or SwiftUI mid-uncollapse. Moving divider 0 on a collapsed
        // item is what used to pop hidden sidebars open on every launch, so
        // uncollapse deliberately first; the width lands on the next pass.
        if sidebar.isCollapsed {
            sidebar.isCollapsed = false
            return
        }
        record.restored = true
        record.plan = nil
        split.setPosition(plan.width, ofDividerAt: 0)
        logger.info("sidebar width restored to \(plan.width, privacy: .public)")
    }

    /// Move the live main-window sidebar divider to an explicit width.
    ///
    /// The overlay uses the same persisted width as the native column, but the
    /// split view also keeps an independent in-session metric. Applying the
    /// overlay's width when it is promoted prevents that stale metric from
    /// winning and writing itself back through `MainWindow`'s geometry hook.
    @discardableResult
    static func setSidebarWidth(_ width: CGFloat, window: NSWindow) -> Bool {
        guard let split = window.contentView?.firstSplitView,
              split.arrangedSubviews.count > 1,
              let sidebar = split.owningSplitViewController?.splitViewItems.first,
              !sidebar.isCollapsed
        else { return false }

        let range = Preferences.sidebarWidthRange
        let clamped = min(max(width, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
        sidebar.maximumThickness = CGFloat(range.upperBound)
        split.setPosition(clamped, ofDividerAt: 0)
        return true
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
    /// the name gives AppKit a single key it rewrites in place. The window's
    /// own frame autosave had the same name and the same problem (#496); see
    /// `disownFrameAutosave`.
    ///
    /// This is hygiene, not the restore: `restoreSidebarWidth` above stays the
    /// authority on the launch width, because when AppKit consults its own
    /// autosave relative to SwiftUI's layout pass is exactly what isn't
    /// dependable here.
    private static let sidebarAutosaveName = "MactermMainSidebar"

    /// Per-window autosave slots, assigned lowest-free and reused when a
    /// window closes.
    ///
    /// One shared name would have every window writing its frames to the same
    /// AppKit key, so they fight. A per-window name has to stay BOUNDED,
    /// though — an unstable one is exactly what produced the unbounded
    /// `NSSplitView Subview Frames` accumulation `pruneChurnedAutosaveKeys`
    /// below exists to clean up (49 keys in one real domain, one per launch).
    /// A reused slot index is bounded by how many windows are open at once; a
    /// UUID per window would not be.
    ///
    /// Slots colliding across windows would matter if AppKit's autosave were
    /// the restore path. It is not — `restoreSidebarWidth` is — so this is
    /// hygiene either way. Stored on the window's `SidebarRecord`.
    private static func sidebarAutosaveSlot(for window: NSWindow) -> Int {
        let record = sidebarRecord(for: window)
        if let existing = record.autosaveSlot { return existing }
        var taken: Set<Int> = []
        for case let other as SidebarRecord in sidebarRecords.objectEnumerator() ?? NSEnumerator() {
            if let slot = other.autosaveSlot { taken.insert(slot) }
        }
        var slot = 0
        while taken.contains(slot) {
            slot += 1
        }
        record.autosaveSlot = slot
        return slot
    }

    private static func autosaveName(forSlot slot: Int) -> String {
        slot == 0 ? sidebarAutosaveName : "\(sidebarAutosaveName).\(slot)"
    }

    private static func pinSidebarAutosaveName(split: NSSplitView, window: NSWindow) {
        let name = autosaveName(forSlot: sidebarAutosaveSlot(for: window))
        guard split.autosaveName != name else { return }
        split.autosaveName = name
        pruneChurnedAutosaveKeys()
    }

    /// Drop the frames AppKit autosaved for a closed window's slot.
    ///
    /// Slots are reused, and setting `autosaveName` on a new window's split
    /// view REAPPLIES whatever the last window at that slot saved — which is
    /// how a new window inherited a closed window's collapsed sidebar and
    /// width. Skipped while terminating: the launch path still reads slot 0
    /// before the window's own record takes over. Reads `UserDefaults.standard`
    /// for the same reason `pruneChurnedAutosaveKeys` does — that is
    /// the only domain AppKit wrote it to — and is likewise skipped under a
    /// test run.
    private static func clearSidebarAutosave(slot: Int) {
        guard !AppTerminationState.isTerminating, !Preferences.isTestRun else { return }
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(autosaveName(forSlot: slot))")
    }

    /// Drop the per-launch keys SwiftUI's address-bearing names left behind:
    /// the sidebar's `NSSplitView Subview Frames …` from before the name was
    /// pinned, and every `NSWindow Frame …` the main window ever wrote (239 in
    /// one release domain, over a thousand in a debug one — one per launch).
    /// Matched on the address marker, so the stable names (ours, and the
    /// Settings window's `com_apple_SwiftUI_Settings_window…`) are never
    /// touched.
    ///
    /// Reads `UserDefaults.standard` deliberately, against the usual rule:
    /// AppKit wrote these keys to the app's real domain, so that is the only
    /// place they exist. Skipped under a test run so a hosted suite can't
    /// reach into the developer's live domain.
    private static func pruneChurnedAutosaveKeys() {
        guard !Preferences.isTestRun else { return }
        let defaults = UserDefaults.standard
        let stale = defaults.dictionaryRepresentation().keys.filter { key in
            (key.hasPrefix("NSSplitView Subview Frames ") || key.hasPrefix("NSWindow Frame "))
                && key.contains("(unknown context at $")
        }
        guard !stale.isEmpty else { return }
        for key in stale {
            defaults.removeObject(forKey: key)
        }
        logger.info("pruned \(stale.count, privacy: .public) churned autosave keys")
    }

    /// Stop AppKit autosaving this window's frame under SwiftUI's name.
    ///
    /// SwiftUI names a `WindowGroup` window's frame autosave after the scene's
    /// whole content type, in which a private type — `AppColorScheme` today,
    /// and SwiftUI's own `ActionsModifier` back when the alerts sat in the
    /// scene closure — prints as `(unknown context at $ADDR)`: an address that
    /// moves every launch with ASLR. So the frame was saved under a new key on
    /// every launch and never read back, and every window opened at the
    /// scene's `defaultSize` (#496).
    ///
    /// A stable name would not have been enough. Measured with
    /// `AppColorScheme` made internal: the first window then came back at its
    /// frame, but every window of the group wrote that one `AppWindow-1` key
    /// (each window is NAMED `AppWindow-N`, yet only `-1` is ever written), so
    /// SwiftUI keeps one frame per group — the last window moved — and every
    /// other restored window opened at the default size. The key also changes
    /// whenever the scene closure's modifiers do, resetting everyone's size.
    /// The frame is persisted per window in `WindowSnapshot` instead
    /// (`restoreFrame`), and AppKit's autosave is switched off: one owner.
    static func disownFrameAutosave(window: NSWindow) {
        guard !window.frameAutosaveName.isEmpty else { return }
        window.setFrameAutosaveName("")
        pruneChurnedAutosaveKeys()
    }

    /// Reopen a restored window at its saved frame. `setFrame(from:)` is the
    /// call AppKit's own autosave restores through: the descriptor carries the
    /// screen the frame was saved on, and AppKit fits it to the current
    /// displays.
    ///
    /// Not every saved frame can be fitted, though: a window manager parks
    /// windows on a hidden workspace just off a screen's corner (AeroSpace
    /// leaves 1pt showing), and that is the frame the move reports. A restored
    /// frame with too little of itself on any screen keeps its size and is
    /// centered on the main screen instead.
    static func restoreFrame(_ descriptor: String, window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(from: descriptor)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        if !DesktopWidgetGrid.isReachable(window.frame, on: visibleFrames),
           let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        {
            let size = CGSize(
                width: min(window.frame.width, screen.width),
                height: min(window.frame.height, screen.height)
            )
            let centered = CGRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            window.setFrame(centered, display: false)
            logger.info("saved window frame \(descriptor, privacy: .public) is off screen; centered it")
            return
        }
        logger.info("window frame restored to \(descriptor, privacy: .public)")
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
    /// double-paint problem `macterm-overrides.conf` sets
    /// `background-default-transparent` to avoid.
    static func syncPanel(_ panel: NSPanel) {
        let opacity = Preferences.shared.windowOpacity
        // Deliberately the configured background, not `nsBg`: the adaptive
        // tint is sampled from the main window's terminal, and the panel is a
        // separate window whose own panes carry their own adaptive fills.
        // Tinting it with another window's color painted the quick terminal in
        // the TUI's background for the frame between it being ordered front
        // and the next sample (which, monitoring the panel, then cleared it) —
        // the reported flash. `AdaptiveTerminalChrome` never adopts a
        // window-wide tint from a panel, so there is nothing to opt into here.
        let bg = MactermTheme.nsConfiguredBg
        let isTransparent = opacity < 1.0
        let useGlass = glassSupported && Preferences.shared.windowGlassEnabled && isTransparent

        if isTransparent {
            panel.isOpaque = false
            if useGlass {
                panel.backgroundColor = .clear
                setWindowBackgroundBlur(panel, radius: 0)
                removeTintBackdrop(window: panel)
                syncGlass(window: panel, backgroundColor: bg, opacity: opacity, cornerRadius: windowCornerRadius(panel))
            } else {
                panel.backgroundColor = .clear
                setWindowBackgroundBlur(panel, radius: Preferences.shared.windowBlurRadius)
                removeGlass(window: panel)
                syncTintBackdrop(window: panel, backgroundColor: bg, opacity: opacity, cornerRadius: windowCornerRadius(panel))
            }
        } else {
            panel.isOpaque = true
            panel.backgroundColor = bg
            setWindowBackgroundBlur(panel, radius: 0)
            removeGlass(window: panel)
            removeTintBackdrop(window: panel)
        }
    }

    /// The desktop-widget variant of `syncPanel`. A widget's shape is its
    /// backdrop — a borderless window has no system corner or mask — so it is
    /// never an opaque window: at full opacity the backdrop is simply an
    /// opaque rounded fill, and the corners outside it stay clear. Glass and
    /// tint take the widget's continuous corner (`DesktopWidgetMetrics`), and
    /// the CGS blur follows the window's shape, which the panel's own corner
    /// mask sets to that same corner (`DesktopWidgetPanel.cornerMask`).
    static func syncDesktopWidget(_ panel: NSPanel) {
        let opacity = Preferences.shared.windowOpacity
        let bg = MactermTheme.nsConfiguredBg
        let radius = DesktopWidgetMetrics.cornerRadius
        let isTransparent = opacity < 1.0
        panel.isOpaque = false
        panel.backgroundColor = .clear
        if glassSupported, Preferences.shared.windowGlassEnabled, isTransparent {
            setWindowBackgroundBlur(panel, radius: 0)
            removeTintBackdrop(window: panel)
            syncGlass(window: panel, backgroundColor: bg, opacity: opacity, cornerRadius: radius)
        } else {
            setWindowBackgroundBlur(panel, radius: isTransparent ? Preferences.shared.windowBlurRadius : 0)
            removeGlass(window: panel)
            syncTintBackdrop(window: panel, backgroundColor: bg, opacity: opacity, cornerRadius: radius)
        }
        // The shadow follows the window's alpha, which just changed shape.
        panel.invalidateShadow()
    }

    /// Hand the window's tinted backdrop the panes painting their own
    /// background, in window coordinates, so the tint is cut away under them
    /// and their margins refilled in their colors (`TintCutout`). An opaque
    /// window has no tint to cut and is left alone.
    static func updateTerminalPaintRegions(in window: NSWindow?, regions: [TerminalPaintRegion]) {
        guard let window else { return }
        if glassSupported, #available(macOS 26.0, *), let glass = existingGlass(in: window) {
            glass.setPaintRegions(regions.map { $0.fromWindow(into: glass) })
        }
        guard let backdrop = existingTintBackdrop(in: window) else { return }
        backdrop.setPaintRegions(regions.map { $0.fromWindow(into: backdrop) })
    }

    /// Install (if needed) and configure the flat tinted backdrop for the
    /// non-glass translucency path. Same placement as the glass view: below the
    /// content view, filling the window including the area under the titlebar.
    private static func syncTintBackdrop(
        window: NSWindow,
        backgroundColor: NSColor,
        opacity: Double,
        cornerRadius: CGFloat?
    ) {
        guard let contentView = window.contentView, let themeFrame = contentView.superview else { return }

        let backdrop = existingTintBackdrop(in: window) ?? {
            let view = MactermTintBackdropView(topOffset: -contentView.safeAreaInsets.top)
            themeFrame.addSubview(view, positioned: .below, relativeTo: contentView)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: themeFrame.topAnchor),
                view.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
                view.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
                view.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
            ])
            return view
        }()

        backdrop.updateTopInset(-contentView.safeAreaInsets.top)
        backdrop.configure(
            backgroundColor: backgroundColor,
            backgroundOpacity: opacity,
            cornerRadius: cornerRadius
        )
    }

    private static func removeTintBackdrop(window: NSWindow) {
        existingTintBackdrop(in: window)?.removeFromSuperview()
    }

    private static func existingTintBackdrop(in window: NSWindow) -> MactermTintBackdropView? {
        guard let themeFrame = window.contentView?.superview else { return nil }
        return themeFrame.subviews.compactMap { $0 as? MactermTintBackdropView }.first
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
    /// titlebar. Installed once per window, then reconfigured in place.
    private static func syncGlass(window: NSWindow, backgroundColor: NSColor, opacity: Double, cornerRadius: CGFloat?) {
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
            cornerRadius: cornerRadius
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
    static func windowCornerRadius(_ window: NSWindow) -> CGFloat? {
        if window.responds(to: Selector(("_cornerRadius"))),
           let radius = window.value(forKey: "_cornerRadius") as? CGFloat
        {
            return radius
        }
        // Older AppKit builds can expose the applied corner only on the theme
        // frame's backing layer. It is still system-owned geometry, not a
        // guessed OS-version constant.
        return window.contentView?.superview?.layer?.cornerRadius
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
