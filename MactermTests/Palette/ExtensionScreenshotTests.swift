import AppKit
import Foundation
@testable import Macterm
import Testing

/// The screenshots on the cards of Settings → Extensions: their order, where
/// each card reads them from, and the loader that reads each one time.
@MainActor
struct ExtensionScreenshotTests {
    private static let pods = """
    name: Pods
    description: Browse a cluster's pods
    requires: [kubectl]
    nodes: { root: { list: ls, action: { copy: . } } }

    """
    private static let manifest = "name: Kubernetes\ndescription: Browse a cluster\nauthors: [thdxg]\n"
    private static let readme = """
    # Kubernetes

    ![Kubernetes](screenshots/kubernetes.png)

    ![Pods](screenshots/pods.png)

    <img src="screenshots/kubernetes.png">

    ![Gone](screenshots/gone.png)

    """

    /// A fetch that answers from `responses` by URL and counts each read.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        var responses: [String: (Data, Int)] = [:]

        func reads(of url: URL) -> Int {
            lock.withLock { counts[url.absoluteString] ?? 0 }
        }

        var fetch: PaletteRegistry.Fetch {
            { [self] url in
                try await Task.sleep(for: .milliseconds(20))
                return lock.withLock {
                    counts[url.absoluteString, default: 0] += 1
                    return responses[url.absoluteString] ?? (Data(), 404)
                }
            }
        }
    }

    /// A blank PNG of `width` × `height` pixels.
    private static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test
    func a_card_shows_the_screenshots_in_the_order_of_the_readme_then_by_name() {
        let paths = [
            "README.md", "screenshots/pods.png", "screenshots/kubernetes.png", "screenshots/zeta.png",
            "screenshots/alpha.png", "screenshots/old/nested.png", "screenshots/notes.txt", "icon.png",
        ]
        #expect(
            MactermExtension.screenshots(in: paths, readme: Self.readme)
                == ["screenshots/kubernetes.png", "screenshots/pods.png", "screenshots/alpha.png", "screenshots/zeta.png"],
            "README order, each one time, a name in the README with no file left out, then the rest by name"
        )
        #expect(MactermExtension.screenshots(in: paths, readme: nil).first == "screenshots/alpha.png", "no README: by name")
        #expect(MactermExtension.screenshots(in: ["README.md"], readme: Self.readme).isEmpty, "an extension can have none")

        let many = (1 ... 9).map { "screenshots/\($0).png" }
        #expect(MactermExtension.screenshots(in: many, readme: nil).count == MactermExtension.maxScreenshots)
    }

    @Test
    func a_card_reads_the_repository_before_install_and_the_disk_after() throws {
        let files: [PaletteRegistry.File] = [
            .init(path: "README.md", size: 10, executable: false),
            .init(path: "extension.yaml", size: 10, executable: false),
            .init(path: "palettes/pods.yaml", size: 10, executable: false),
            .init(path: "screenshots/pods.png", size: 10, executable: false, sha: "aaa"),
            .init(path: "screenshots/kubernetes.png", size: 10, executable: false, sha: "bbb"),
        ]
        let entry = PaletteRegistry.Entry(
            id: "kubernetes", files: files,
            texts: ["README.md": Self.readme, "extension.yaml": Self.manifest, "palettes/pods.yaml": Self.pods]
        )
        let available = ExtensionGalleryItem.available(entry).screenshots(ref: "main")
        #expect(available.map(\.path) == ["screenshots/kubernetes.png", "screenshots/pods.png"])
        #expect(available.map(\.sha) == ["bbb", "aaa"], "the blob SHA is the key of the cache")
        #expect(available.first?.source == .repository(PaletteRegistry.fileURL(
            ref: "main",
            id: "kubernetes",
            path: "screenshots/kubernetes.png"
        )))

        let config = FileManager.default.temporaryDirectory.appendingPathComponent("macterm-shots-\(UUID().uuidString)", isDirectory: true)
        let store = CustomPaletteStore(configDirectoryURL: config)
        let folder = store.extensionsURL.appendingPathComponent("kubernetes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("screenshots"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("palettes"), withIntermediateDirectories: true)
        try Self.manifest.write(to: folder.appendingPathComponent("extension.yaml"), atomically: true, encoding: .utf8)
        try Self.pods.write(to: folder.appendingPathComponent("palettes/pods.yaml"), atomically: true, encoding: .utf8)
        try Self.readme.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let shot = Self.png(width: 16, height: 10)
        try shot.write(to: folder.appendingPathComponent("screenshots/pods.png"))
        try shot.write(to: folder.appendingPathComponent("screenshots/kubernetes.png"))
        store.reload()

        let installed = try #require(store.installedExtension(id: "kubernetes"))
        let onDisk = ExtensionGalleryItem.installed(installed, registry: entry).screenshots(ref: "main")
        #expect(onDisk.map(\.path) == ["screenshots/kubernetes.png", "screenshots/pods.png"])
        #expect(
            onDisk.first?.source == .file(installed.folder.appendingPathComponent("screenshots/kubernetes.png")),
            "no network once installed"
        )
        #expect(onDisk.first?.sha == ExtensionSource.blobSHA(shot))
    }

    @Test
    func the_loader_reads_each_screenshot_one_time_and_tries_a_failed_read_again() async throws {
        let url = PaletteRegistry.fileURL(ref: "main", id: "kubernetes", path: "screenshots/pods.png")
        let server = Server()
        let loader = ExtensionScreenshotLoader(ref: "main", fetch: server.fetch)
        let screenshot = ExtensionScreenshot(path: "screenshots/pods.png", sha: "aaa", source: .repository(url))

        await #expect(throws: PaletteRegistry.RegistryError.self) { try await loader.data(of: screenshot) }
        server.responses[url.absoluteString] = (Self.png(width: 1600, height: 1000), 200)
        async let first = loader.image(of: screenshot, maxPixelSize: 400)
        async let second = loader.image(of: screenshot, maxPixelSize: 400)
        let images = try await [first, second]
        #expect(server.reads(of: url) == 2, "the failed read is not kept, and two cards at one time share the next")
        #expect(images.allSatisfy { $0.size == NSSize(width: 400, height: 250) }, "decoded at the size of the card")
        #expect(loader.cachedImage(of: screenshot, maxPixelSize: 400) != nil, "a card that shows again draws it at once")

        _ = try await loader.image(of: screenshot, maxPixelSize: 1600)
        #expect(server.reads(of: url) == 2, "another size decodes the same bytes again")

        let renamed = ExtensionScreenshot(path: "screenshots/renamed.png", sha: "aaa", source: .repository(url))
        #expect(loader.cachedImage(of: renamed, maxPixelSize: 400) != nil, "the same bytes are one entry")
        #expect(ExtensionScreenshotLoader.decode(Data("not an image".utf8), maxPixelSize: 100) == nil)
    }
}
