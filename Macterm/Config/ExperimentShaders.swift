import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ExperimentShaders")

/// The Settings → Experimental cursor shaders as libghostty loads them: the
/// bundled templates (`Resources/shaders/`) written to Application Support
/// with a header saying how ghostty's framebuffer is encoded.
///
/// A custom shader writes straight into that framebuffer, and nothing in its
/// uniforms says what the framebuffer holds: gamma-encoded Display P3 under
/// macOS's default `alpha-blending = native`, linear under `linear` /
/// `linear-corrected`; config colors treated as P3 under `window-colorspace =
/// display-p3`, converted from sRGB otherwise (`load_color` in ghostty's
/// shaders.metal). The community cursor shaders assume a linear target and
/// draw a visibly darker cursor under the default. The header carries the
/// two answers as `#define`s, read from the user's *stated* config on every
/// regenerate, so a reload after editing either key re-renders the files.
enum ExperimentShaders {
    /// Installed in this order in the overrides: trail beneath glide.
    static let fileNames = ["cursor_trail.glsl", "cursor_glide.glsl"]

    /// How a config color must be written into the framebuffer.
    struct Encoding: Equatable {
        /// `alpha-blending` is `linear` or `linear-corrected`.
        var linearBlending: Bool
        /// `window-colorspace = display-p3`.
        var displayP3: Bool

        /// ghostty's defaults on macOS: `native` blending, `srgb` colorspace.
        static let macOSDefault = Encoding(linearBlending: false, displayP3: false)

        /// Read off the user's raw config text — raw, not the loaded C
        /// config, because the files are regenerated *before* each load.
        /// An unknown value falls back to the default the way ghostty's
        /// parser would reject it.
        static func from(userConfigText: String?) -> Encoding {
            guard let text = userConfigText else { return .macOSDefault }
            let blending = GhosttyConfigText.lastValue(of: "alpha-blending", inConfigText: text)
            let colorspace = GhosttyConfigText.lastValue(of: "window-colorspace", inConfigText: text)
            return Encoding(
                linearBlending: blending == "linear" || blending == "linear-corrected",
                displayP3: colorspace == "display-p3"
            )
        }

        /// The lines prepended to each template. The templates `#ifndef`
        /// both names with the macOS defaults, so a bare bundled file still
        /// compiles for anyone who points ghostty at it directly.
        var header: String {
            "#define MACTERM_LINEAR_BLENDING \(linearBlending ? 1 : 0)\n"
                + "#define MACTERM_DISPLAY_P3 \(displayP3 ? 1 : 0)\n"
        }
    }

    /// A template with the encoding header in front. Pure; the template's
    /// own text is untouched so the shader stays readable in the bundle.
    static func render(template: String, encoding: Encoding) -> String {
        encoding.header + template
    }

    /// The bundle directory holding the templates (`Macterm/Resources/shaders`,
    /// a folder reference in project.yml), or nil when a file is missing — a
    /// broken or partial build, in which case nothing is installed and
    /// `MactermConfig.Experiments` emits no shader line.
    static func bundledDirectory() -> URL? {
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("shaders", isDirectory: true)
        else { return nil }
        let present = fileNames.allSatisfy {
            FileManager.default.isReadableFile(atPath: dir.appendingPathComponent($0).path)
        }
        return present ? dir : nil
    }

    /// Write every rendered template into `directory`, returning its path
    /// for the `custom-shader` lines, or nil when the templates are missing
    /// or a write failed (logged: a half-installed pair would load one
    /// effect and silently drop the other).
    static func install(into directory: URL, encoding: Encoding) -> String? {
        guard let bundled = bundledDirectory() else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in fileNames {
                let template = try String(contentsOf: bundled.appendingPathComponent(name), encoding: .utf8)
                let rendered = render(template: template, encoding: encoding)
                try Data(rendered.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        } catch {
            logger.error("failed to install experiment shaders: \(error, privacy: .public)")
            return nil
        }
        return directory.path
    }
}
