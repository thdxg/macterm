import AppKit
@testable import Macterm
import Testing

/// Every way the helper can fail must come back as a `Failure`, never as a
/// throw or a crash of the app. Stand-in helpers are shell scripts.
struct AdaptiveIconRendererTests {
    private static let request = AdaptiveIconRequest(
        catalogPath: Bundle.main.url(forResource: "Assets", withExtension: "car")?.path ?? "/nonexistent/Assets.car",
        iconName: "AppIcon",
        appearance: .dark,
        backgroundTop: .init(red: 0.118, green: 0.110, blue: 0.180),
        backgroundBottom: .init(red: 0.098, green: 0.090, blue: 0.141),
        layers: [
            .init(red: 0.231, green: 0.216, blue: 0.322),
            .init(red: 0.769, green: 0.655, blue: 0.906),
            .init(red: 0.878, green: 0.871, blue: 0.957),
            .init(red: 0.878, green: 0.871, blue: 0.957),
        ],
        pixels: 256
    )

    private func helper(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveIconRendererTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("helper")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test
    func aMissingHelperIsAFailure() async {
        let result = await AdaptiveIconRenderer.render(Self.request, helper: URL(fileURLWithPath: "/nonexistent/helper"))
        #expect(result == .failure(.helperMissing))
    }

    @Test
    func aHelperKilledBySignalIsAFailure() async throws {
        let result = try await AdaptiveIconRenderer.render(Self.request, helper: helper("kill -SEGV $$"))
        #expect(result == .failure(.killed(signal: SIGSEGV, message: "")))
    }

    @Test
    func aHelperThatExitsWithAnErrorReportsIt() async throws {
        let result = try await AdaptiveIconRenderer.render(
            Self.request,
            helper: helper("echo 'the icon changed' >&2; exit 5")
        )
        #expect(result == .failure(.exited(code: 5, message: "the icon changed")))
    }

    @Test
    func outputThatIsNoImageIsAFailure() async throws {
        let result = try await AdaptiveIconRenderer.render(Self.request, helper: helper("echo not a png"))
        #expect(result == .failure(.notAnImage))
    }

    /// The run ends at the timeout, although the helper's `sleep` child
    /// keeps the pipes open for 30 s more.
    @Test
    func aHelperThatHangsIsKilled() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await AdaptiveIconRenderer.render(Self.request, helper: helper("sleep 30"), timeout: 0.5)
        #expect(result == .failure(.timedOut))
        #expect(started.duration(to: clock.now) < .seconds(5))
    }

    /// SIGTERM does nothing to this helper, so SIGKILL ends it.
    @Test
    func aHelperThatIgnoresSIGTERMIsKilled() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveIconRendererTests-\(UUID().uuidString).pid")
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await AdaptiveIconRenderer.render(
            Self.request,
            helper: helper("trap '' TERM; echo $$ > '\(marker.path)'; while :; do sleep 0.1; done"),
            timeout: 0.5
        )
        #expect(result == .failure(.timedOut))
        #expect(started.duration(to: clock.now) < .seconds(5))
        let pid =
            try #require(Int32(String(decoding: Data(contentsOf: marker), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "the helper is still running")
    }

    /// A child of the helper keeps the pipes open after the helper exits.
    /// The run ends at the exit and a bounded read, not when the child ends.
    @Test
    func aChildThatKeepsThePipesOpenDoesNotHoldTheRun() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await AdaptiveIconRenderer.render(Self.request, helper: helper("echo 'gone' >&2; sleep 30 & exit 3"))
        #expect(result == .failure(.exited(code: 3, message: "gone")))
        #expect(started.duration(to: clock.now) < .seconds(5))
    }

    /// One helper runs at a time. A request that waits is replaced by a
    /// newer one, and ends as `.superseded`.
    @MainActor
    @Test
    func theQueueRunsOneHelperAtATimeAndKeepsTheNewestRequest() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveIconRendererTests-\(UUID().uuidString).log")
        let queue = try AdaptiveIconRenderer.Queue(
            helper: helper("echo start >> '\(log.path)'; sleep 0.3; echo end >> '\(log.path)'; exit 1")
        )
        let results = ResultBox()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            for index in 0 ..< 3 {
                queue.render(Self.request) { result in
                    results.values[index] = result
                    if results.values.count == 3 { done.resume() }
                }
            }
        }
        #expect(results.values[0] == .failure(.exited(code: 1, message: "")))
        #expect(results.values[1] == .failure(.superseded))
        #expect(results.values[2] == .failure(.exited(code: 1, message: "")))
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines == ["start", "end", "start", "end"])
    }

    @MainActor
    private final class ResultBox {
        var values: [Int: Result<Data, AdaptiveIconRenderer.Failure>] = [:]
    }

    /// The request reaches the helper as its one argument.
    @Test
    func theRequestIsTheOnlyArgument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveIconRendererTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let argumentFile = directory.appendingPathComponent("argument.json")
        _ = try await AdaptiveIconRenderer.render(
            Self.request,
            helper: helper("[ \"$#\" = 1 ] && printf '%s' \"$1\" > '\(argumentFile.path)'; exit 1")
        )
        let decoded = try JSONDecoder().decode(AdaptiveIconRequest.self, from: Data(contentsOf: argumentFile))
        #expect(decoded == Self.request)
    }

    /// The real helper, against the test host's own compiled icon. Runs only
    /// where the helper can: macOS 26 or later, in a bundle that has it.
    @Test
    func theBundledHelperRendersTheIconOnTheSystemGrid() async throws {
        guard #available(macOS 26, *) else { return }
        try #require(
            FileManager.default.isExecutableFile(atPath: AdaptiveIconRenderer.bundledHelperURL.path),
            "the test host has no Contents/Helpers/macterm-icon-renderer"
        )
        // Each pane gets a pure color of its own, so a pane that takes
        // another layer's fill (IconRendering changed its order) shows. The
        // characters, at the bottom, are violet: the screen check below
        // stays true where they cover it.
        var request = Self.request
        request.layers = [
            .init(red: 0.5, green: 0, blue: 1),
            .init(red: 1, green: 0, blue: 0),
            .init(red: 0, green: 1, blue: 0),
            .init(red: 0, green: 0, blue: 1),
        ]
        let result = await AdaptiveIconRenderer.render(request)
        let png = try result.get()
        let image = try #require(NSBitmapImageRep(data: png))
        // The body fills 824/1024 of the canvas: the corner is empty, and the
        // screen inside the frame is the requested dark violet. (180, 180) is
        // clear of the frame, whose glass macOS 26 draws translucent, and of
        // the panes in the top-left.
        let corner = image.colorAt(x: 4, y: 4)?.alphaComponent ?? 1
        let screen = image.colorAt(x: 180, y: 180)?.usingColorSpace(.sRGB)
        let onGrid = image.pixelsWide == 256 && image.pixelsHigh == 256 && corner < 0.05
        let violet = screen.map { $0.alphaComponent > 0.95 && $0.blueComponent > $0.greenComponent } ?? false
        // One point inside each pane, front to back from the left: blue,
        // green, red.
        let panes = Self.panePoints.map { point, channel in
            image.colorAt(x: point.x, y: point.y)?.usingColorSpace(.sRGB).map { Self.dominant($0) == channel && $0.alphaComponent > 0.5 }
                ?? false
        }
        // A thrown error reaches the CI log in full, where a comment on
        // #expect does not.
        if !(onGrid && violet && !panes.contains(false)) { throw RenderSummary(text: Self.describe(image)) }
    }

    private enum Channel { case red, green, blue }

    /// Front pane (blue), middle pane (green), back pane (red), at 256 px.
    private static let panePoints: [((x: Int, y: Int), Channel)] = [((72, 90), .blue), ((96, 90), .green), ((116, 90), .red)]

    private static func dominant(_ color: NSColor) -> Channel {
        if color.redComponent > color.greenComponent, color.redComponent > color.blueComponent { return .red }
        return color.greenComponent > color.blueComponent ? .green : .blue
    }

    private struct RenderSummary: Error, CustomStringConvertible {
        let text: String
        var description: String { text }
    }

    /// What the render holds, for a failure message: the count and bounds of
    /// the opaque pixels, and the color at a few points.
    private static func describe(_ image: NSBitmapImageRep) -> String {
        var opaque = 0
        var bounds = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in 0 ..< image.pixelsHigh {
            for x in 0 ..< image.pixelsWide where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                opaque += 1
                bounds = (min(bounds.minX, x), min(bounds.minY, y), max(bounds.maxX, x), max(bounds.maxY, y))
            }
        }
        let samples = [(128, 40), (128, 128), (180, 180), (128, 220), (72, 90), (96, 90), (116, 90)].map { x, y -> String in
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "(\(x),\(y)) none" }
            return String(
                format: "(%d,%d) rgba %.2f %.2f %.2f %.2f",
                x,
                y,
                c.redComponent,
                c.greenComponent,
                c.blueComponent,
                c.alphaComponent
            )
        }
        return "\(image.pixelsWide)x\(image.pixelsHigh), \(opaque) opaque pixels in \(bounds), " + samples.joined(separator: "; ")
    }
}

struct AdaptiveIconCacheTests {
    private func makeCache() throws -> (AdaptiveIconCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveIconCacheTests-\(UUID().uuidString)")
        let catalog = directory.appendingPathComponent("Assets.car")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("catalog".utf8).write(to: catalog)
        return (AdaptiveIconCache(directory: directory.appendingPathComponent("cache")), catalog)
    }

    private func request(catalog: URL, appearance: AdaptiveIconRequest.Appearance = .light, red: Double = 0.5) -> AdaptiveIconRequest {
        AdaptiveIconRequest(
            catalogPath: catalog.path,
            iconName: "AppIcon",
            appearance: appearance,
            backgroundTop: .init(red: red, green: 0, blue: 0),
            backgroundBottom: .init(red: 0, green: 0, blue: 0),
            layers: [],
            pixels: 16
        )
    }

    private var png: Data {
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return image.representation(using: .png, properties: [:])!
    }

    @Test
    func anEntryIsReadBackForTheSameRequest() throws {
        let (cache, catalog) = try makeCache()
        let request = request(catalog: catalog)
        #expect(cache.image(for: request) == nil)
        cache.store(png, for: request)
        #expect(cache.image(for: request) != nil)
    }

    @Test
    func anotherRequestOrAChangedCatalogMisses() throws {
        let (cache, catalog) = try makeCache()
        cache.store(png, for: request(catalog: catalog))
        #expect(cache.image(for: request(catalog: catalog, red: 0.6)) == nil)
        try Data("a new catalog, a new size".utf8).write(to: catalog)
        #expect(cache.image(for: request(catalog: catalog)) == nil)
    }

    @Test
    func eachAppearanceKeepsItsOwnEntry() throws {
        let (cache, catalog) = try makeCache()
        cache.store(png, for: request(catalog: catalog, appearance: .light))
        cache.store(png, for: request(catalog: catalog, appearance: .dark))
        #expect(cache.image(for: request(catalog: catalog, appearance: .light)) != nil)
        #expect(cache.image(for: request(catalog: catalog, appearance: .dark)) != nil)
    }
}
