import AppKit
import ImageIO

/// One screenshot on the card of an extension in Settings → Extensions: a
/// file in the folder of an installed extension, or a file in Macterm's
/// repository (`PaletteRegistry.fileURL`).
struct ExtensionScreenshot: Hashable, Identifiable {
    enum Source: Hashable {
        case file(URL)
        case repository(URL)
    }

    /// Relative to the folder of the extension (`screenshots/<name>.png`).
    let path: String
    /// Its Git blob SHA, when it is known: the key of the cache. The same
    /// bytes have the same key, so an installed copy and the repository's
    /// version share one entry, and a changed file gets a new one.
    let sha: String
    let source: Source

    var id: String { path }

    var cacheKey: String {
        if !sha.isEmpty { return sha }
        switch source {
        case let .file(url),
             let .repository(url): return url.absoluteString
        }
    }
}

extension ExtensionGalleryItem {
    /// The screenshots that the card shows, in order. An installed
    /// extension shows the files on disk, so that the card needs no
    /// network. One that is not installed shows the repository's files at
    /// `ref`.
    func screenshots(ref: String) -> [ExtensionScreenshot] {
        switch self {
        case let .installed(installed, _):
            installed.screenshots.map { path in
                ExtensionScreenshot(
                    path: path,
                    sha: installed.files[path] ?? "",
                    source: .file(installed.folder.appendingPathComponent(path))
                )
            }
        case let .available(entry):
            MactermExtension.screenshots(in: entry.files.map(\.path), readme: entry.readme).map { path in
                ExtensionScreenshot(
                    path: path,
                    sha: entry.files.first { $0.path == path }?.sha ?? "",
                    source: .repository(PaletteRegistry.fileURL(ref: ref, id: entry.id, path: path))
                )
            }
        }
    }
}

/// Reads the screenshots of the gallery when a card shows them, never
/// before. It reads each file one time for each run of the app, and keeps
/// each image at each size that a view asks for. The key of each entry is
/// the blob SHA of the file, so an entry never goes stale. A read that
/// fails is not kept, and the next view that shows the screenshot tries
/// again. The repository has at most `MactermExtension.maxScreenshots`
/// screenshots for each extension, so the cache has no limit.
@MainActor
final class ExtensionScreenshotLoader {
    private let ref: String
    private let fetch: PaletteRegistry.Fetch
    private var data: [String: Task<Data, Error>] = [:]
    private var decoding: [String: Task<NSImage, Error>] = [:]
    private var images: [String: NSImage] = [:]

    init(ref: String, fetch: @escaping PaletteRegistry.Fetch) {
        self.ref = ref
        self.fetch = fetch
    }

    /// The image of `screenshot` at `maxPixelSize`, when a view read it
    /// before: a view that appears again draws it at once.
    func cachedImage(of screenshot: ExtensionScreenshot, maxPixelSize: Int) -> NSImage? {
        images[Self.imageKey(screenshot, maxPixelSize)]
    }

    /// The image of `screenshot`, decoded so that its longer edge is at
    /// most `maxPixelSize` pixels. The file is read and decoded off the main
    /// thread.
    func image(of screenshot: ExtensionScreenshot, maxPixelSize: Int) async throws -> NSImage {
        let key = Self.imageKey(screenshot, maxPixelSize)
        if let image = images[key] { return image }
        if let task = decoding[key] { return try await task.value }
        let task = Task<NSImage, Error> {
            let bytes = try await data(of: screenshot)
            return try await Task.detached(priority: .userInitiated) {
                guard let image = Self.decode(bytes, maxPixelSize: maxPixelSize) else { throw DecodeError() }
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }.value
        }
        decoding[key] = task
        defer { decoding[key] = nil }
        let image = try await task.value
        images[key] = image
        return image
    }

    /// The bytes of `screenshot`: its file on disk, or its file in the
    /// repository from `raw.githubusercontent.com`, as the registry reads
    /// every other file.
    func data(of screenshot: ExtensionScreenshot) async throws -> Data {
        let key = screenshot.cacheKey
        if let task = data[key] { return try await task.value }
        let fetch = fetch
        let ref = ref
        let task = Task<Data, Error> {
            switch screenshot.source {
            case let .file(url):
                return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            case let .repository(url):
                let (data, status) = try await fetch(url)
                guard status == 200 else { throw PaletteRegistry.RegistryError(status: status, ref: ref) }
                return data
            }
        }
        data[key] = task
        do {
            return try await task.value
        } catch {
            if data[key] == task { data[key] = nil }
            throw error
        }
    }

    /// `data` as an image whose longer edge is at most `maxPixelSize`
    /// pixels: a card draws a screenshot at less than half its size, and a
    /// smaller image costs less memory. nil when `data` is not an image.
    nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func imageKey(_ screenshot: ExtensionScreenshot, _ maxPixelSize: Int) -> String {
        "\(screenshot.cacheKey)@\(maxPixelSize)"
    }

    struct DecodeError: LocalizedError {
        var errorDescription: String? {
            String(localized: "The screenshot is not an image that Macterm can read.")
        }
    }
}
