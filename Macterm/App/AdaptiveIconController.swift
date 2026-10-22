import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "AdaptiveIconController")

/// Keeps the Dock icon on what `AdaptiveIcon.decide` asks for: the bundled
/// icon, the user's custom image, or the bundled icon repainted in the theme.
///
/// `GhosttyApp` hands it the config's choice on every load and reload; the
/// theme colors, the system's appearance and icon style and the preference
/// are read again on each `refresh`, which runs on every config change, when
/// the app becomes active (System Settings sends no notice when the icon
/// style changes) and when the preference changes. A refresh whose request is
/// the one already shown or in flight does nothing, so the frequent config
/// notifications cost a few color reads.
///
/// The repainted icon is rendered by `AdaptiveIconRenderer` in a helper
/// process. While a render is in flight the Dock keeps what it shows. A
/// render that fails puts the bundled icon back and turns the adaptive icon
/// off for the rest of the run: a failure there means the private renderer
/// changed under this build, and it will not start working again until the
/// next launch.
@MainActor
final class AdaptiveIconController {
    static let shared = AdaptiveIconController()

    private var configured: GhosttyAppIcon = .bundled
    /// The request shown or in flight, nil while the Dock shows `configured`.
    private var current: AdaptiveIconRequest?
    /// Bumped by every refresh that changes course, so a render that ends
    /// after a newer one began is dropped.
    private var generation = 0
    /// Why the adaptive icon is off for this run, once a render failed.
    private var suspension: AdaptiveIconRenderer.Failure?
    /// The images of this run, one for each appearance, so a light/dark
    /// switch back to a seen request installs at once.
    private var rendered: [AdaptiveIconRequest.Appearance: (request: AdaptiveIconRequest, image: NSImage)] = [:]
    private let cache = AdaptiveIconCache(directory: FileStorage.appSupportDirectory().appendingPathComponent(
        "AdaptiveIcon",
        isDirectory: true
    ))
    /// One helper at a time: a burst of theme changes queues only the last.
    private let renders = AdaptiveIconRenderer.Queue()
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .mactermConfigDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AdaptiveIconController.shared.refresh() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AdaptiveIconController.shared.refresh() }
        })
    }

    /// The ghostty config's `macos-icon` choice, from `GhosttyApp`. The
    /// refresh waits one main-queue turn: the first call comes from inside
    /// `GhosttyApp.init`, and `refresh` reads `GhosttyApp.shared`, which
    /// would deadlock its dispatch_once there.
    func configuredIconDidChange(_ icon: GhosttyAppIcon) {
        configured = icon
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AdaptiveIconController.shared.refresh() }
        }
    }

    func refresh() {
        let iconStyle = CFPreferencesCopyAppValue(AdaptiveIcon.iconStyleKey as CFString, kCFPreferencesAnyApplication) as? String
        let decision = AdaptiveIcon.decide(
            enabled: Preferences.shared.adaptiveIcon,
            supported: AdaptiveIcon.isSupported && suspension == nil,
            configured: configured,
            iconStyle: iconStyle,
            systemScheme: { GhosttyApp.shared.systemScheme }
        )
        guard case let .adaptive(appearance) = decision, let theme = themeColors(),
              let paint = AdaptiveIcon.paint(for: theme), let request = request(for: appearance, paint: paint)
        else {
            showConfigured()
            return
        }
        guard request != current else { return }
        current = request
        generation += 1

        if let seen = rendered[appearance], seen.request == request {
            AppIconPresenter.applyAdaptive(seen.image)
            return
        }
        if let image = cache.image(for: request) {
            remember(image, for: request)
            AppIconPresenter.applyAdaptive(image)
            return
        }
        render(request, generation: generation)
    }

    private func showConfigured() {
        if current != nil {
            generation += 1
            logger.info("adaptive icon off, showing the configured icon")
        }
        current = nil
        AppIconPresenter.apply(configured)
    }

    private func render(_ request: AdaptiveIconRequest, generation: Int) {
        let started = ContinuousClock.now
        renders.render(request) { [self] result in
            guard generation == self.generation else { return }
            switch result {
            case let .success(png):
                guard let image = NSImage(data: png) else { return fail(.notAnImage) }
                remember(image, for: request)
                cache.store(png, for: request)
                AppIconPresenter.applyAdaptive(image)
                let elapsed = started.duration(to: .now)
                logger.info("adaptive icon (\(request.appearance.rawValue, privacy: .public)) rendered in \(elapsed, privacy: .public)")
            case .failure(.superseded):
                // A newer request took this one's place. It says nothing
                // about the helper, so it suspends nothing.
                return
            case let .failure(failure):
                fail(failure)
            }
        }
    }

    private func fail(_ failure: AdaptiveIconRenderer.Failure) {
        suspension = failure
        logger.error("adaptive icon off for this run, keeping the bundled icon: \(failure.description, privacy: .public)")
        showConfigured()
    }

    private func remember(_ image: NSImage, for request: AdaptiveIconRequest) {
        rendered[request.appearance] = (request, image)
    }

    /// The colors the icon is painted from, nil when one cannot be read.
    private func themeColors() -> AdaptiveIcon.ThemeColors? {
        let app = GhosttyApp.shared
        func color(_ color: NSColor?) -> AdaptiveIcon.Color? {
            guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
            return .init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        }
        guard let background = color(app.backgroundColor) else { return nil }
        var palette: [AdaptiveIcon.Color] = []
        for index in 0 ..< 16 {
            guard let entry = color(app.paletteColor(at: index)) else { return nil }
            palette.append(entry)
        }
        return .init(background: background, palette: palette)
    }

    /// The request for this paint, or nil when the bundle has no compiled
    /// catalog to paint.
    private func request(for appearance: AdaptiveIconRequest.Appearance, paint: AdaptiveIcon.Paint) -> AdaptiveIconRequest? {
        guard let catalog = Bundle.main.url(forResource: "Assets", withExtension: "car") else { return nil }
        return AdaptiveIconRequest(
            catalogPath: catalog.path,
            iconName: Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String ?? "AppIcon",
            appearance: appearance,
            backgroundTop: paint.backgroundTop,
            backgroundBottom: paint.backgroundBottom,
            layers: paint.layers,
            pixels: 1024
        )
    }
}

/// The last adaptive icon of each appearance, on disk, so a launch shows the
/// theme's icon at once instead of the bundled icon for the length of a
/// render. An entry counts only for the same request from the same build: the
/// stamp names the app's build and the catalog's size and date, so an update
/// that changes the icon renders again.
struct AdaptiveIconCache {
    let directory: URL

    private struct Entry: Codable, Equatable {
        var request: AdaptiveIconRequest
        var stamp: String
    }

    func image(for request: AdaptiveIconRequest) -> NSImage? {
        guard let data = try? Data(contentsOf: entryURL(request.appearance)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry == Entry(request: request, stamp: Self.stamp(catalogPath: request.catalogPath)),
              let png = try? Data(contentsOf: imageURL(request.appearance)),
              let image = NSImage(data: png), image.isValid
        else { return nil }
        return image
    }

    func store(_ png: Data, for request: AdaptiveIconRequest) {
        let entry = Entry(request: request, stamp: Self.stamp(catalogPath: request.catalogPath))
        guard let json = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: imageURL(request.appearance), options: .atomic)
            try json.write(to: entryURL(request.appearance), options: .atomic)
        } catch {
            logger.warning("cannot keep the adaptive icon on disk: \(EnglishErrorText.describe(error), privacy: .public)")
        }
    }

    static func stamp(catalogPath: String) -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let attributes = try? FileManager.default.attributesOfItem(atPath: catalogPath)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(build) \(size) \(date)"
    }

    private func entryURL(_ appearance: AdaptiveIconRequest.Appearance) -> URL {
        directory.appendingPathComponent("\(appearance.rawValue).json")
    }

    private func imageURL(_ appearance: AdaptiveIconRequest.Appearance) -> URL {
        directory.appendingPathComponent("\(appearance.rawValue).png")
    }
}
