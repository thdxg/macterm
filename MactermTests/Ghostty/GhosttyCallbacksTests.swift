import AppKit
@testable import Macterm
import Testing

/// Covers the pasteboard resolver that backs Cmd+V / context-menu paste —
/// specifically the image branch that lets a raw clipboard image (a screenshot,
/// "Copy Image") paste into a TUI as a temp-file path. Each test drives a
/// private, uniquely named `NSPasteboard` so it never touches the real
/// system clipboard or races with other tests.
@MainActor
struct GhosttyCallbacksTests {
    /// A fresh, isolated pasteboard for one test. Released on deinit.
    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("macterm.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    /// A real 4×4 PNG, encoded the way the system would put one on the clipboard.
    private func samplePNG() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    /// A real 4×4 TIFF, for exercising the `.tiff`→PNG normalization path.
    private func sampleTIFF() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image.tiffRepresentation!
    }

    @Test
    func plainText_returnsTheString() {
        let pb = makePasteboard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("hello world", forType: .string)

        #expect(GhosttyCallbacks.readPasteboardText(from: pb) == "hello world")
    }

    @Test
    func emptyPasteboard_returnsNil() {
        let pb = makePasteboard()
        #expect(GhosttyCallbacks.readPasteboardText(from: pb) == nil)
        #expect(GhosttyCallbacks.hasPasteboardContent(in: pb) == false)
    }

    @Test
    func image_pastesPathToARealPNGFile() throws {
        let pb = makePasteboard()
        pb.declareTypes([.png], owner: nil)
        pb.setData(samplePNG(), forType: .png)

        let resolved = try #require(GhosttyCallbacks.readPasteboardText(from: pb))
        // The pasted text is a shell-escaped path; unescape spaces to hit disk.
        let path = resolved.replacingOccurrences(of: "\\", with: "")

        #expect(path.hasSuffix(".png"))
        #expect(path.contains("macterm-paste"))
        #expect(FileManager.default.fileExists(atPath: path))
        // The written file must be a decodable image, not just any bytes.
        #expect(NSImage(contentsOfFile: path) != nil)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func tiffOnly_isNormalizedToAPNGFile() throws {
        let pb = makePasteboard()
        // Put a genuine TIFF (no .png type) on the board.
        pb.declareTypes([.tiff], owner: nil)
        pb.setData(sampleTIFF(), forType: .tiff)

        let resolved = try #require(GhosttyCallbacks.readPasteboardText(from: pb))
        let path = resolved.replacingOccurrences(of: "\\", with: "")

        #expect(path.hasSuffix(".png"))
        #expect(NSImage(contentsOfFile: path) != nil)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test
    func text_takesPrecedenceOverImage() {
        let pb = makePasteboard()
        pb.declareTypes([.string, .png], owner: nil)
        pb.setString("real text", forType: .string)
        pb.setData(samplePNG(), forType: .png)

        // Text wins, so normal copy/paste is never rerouted through a temp file.
        #expect(GhosttyCallbacks.readPasteboardText(from: pb) == "real text")
    }

    @Test
    func hasPasteboardContent_isSideEffectFreeForImages() {
        let pb = makePasteboard()
        pb.declareTypes([.png], owner: nil)
        pb.setData(samplePNG(), forType: .png)

        // Reports content present without writing a temp PNG (unlike the resolver).
        #expect(GhosttyCallbacks.hasPasteboardContent(in: pb) == true)
        #expect(GhosttyCallbacks.imagePasteboardPath(pb) != nil)
    }
}
