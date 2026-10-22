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

    @Test
    func aHelperThatHangsIsKilled() async throws {
        let result = try await AdaptiveIconRenderer.render(Self.request, helper: helper("sleep 30"), timeout: 0.5)
        #expect(result == .failure(.timedOut))
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
        let result = await AdaptiveIconRenderer.render(Self.request)
        let png = try result.get()
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide == 256 && image.pixelsHigh == 256)
        // The body fills 824/1024 of the canvas: the corner is empty, and the
        // background just inside the body is the requested dark violet.
        #expect(try #require(image.colorAt(x: 4, y: 4)).alphaComponent < 0.05)
        let inside = try #require(image.colorAt(x: 128, y: 220)?.usingColorSpace(.sRGB))
        #expect(inside.blueComponent > inside.greenComponent, "background at the body's lower middle: \(inside)")
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
