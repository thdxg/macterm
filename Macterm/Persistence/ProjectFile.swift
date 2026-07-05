import Foundation
import Yams

/// A hand-authorable project declaration in the central directory
/// (`~/.config/macterm/projects/*.yaml`) — the successor to the in-repo
/// `.macterm/layout.yaml` (deprecated; see `LayoutFile`). One file per
/// project:
///
///     name: API server           # optional, display only
///     path: devbox:~/dev/api     # required — the project's identity
///     zmxPath: ~/bin/zmx         # optional — explicit remote zmx path
///     tabs:                      # optional — same schema as LayoutFile
///       - run: "npm run dev"
///
/// `path` is scp-style (`ProjectPath`): a plain absolute/`~` path is local,
/// `[user@]host:dir` is remote. Files are matched to projects by canonicalized
/// path, re-resolved on every use — the filename is a cosmetic slug and never
/// identity. `zmxPath` (#104) is the absolute remote zmx path used verbatim
/// when PATH resolution can't find it (only meaningful for remote `path`).
/// Files and the runtime project list are deliberately decoupled: Macterm
/// writes a file only on explicit "Save Layout", and never deletes one.
struct ProjectFile: Codable, Equatable {
    var name: String?
    var path: String
    var zmxPath: String?
    var tabs: [LayoutTab]?

    /// Bridge to the layout types `LayoutBuilder`/`LayoutReconciler` consume.
    /// nil when the file declares no tabs (a bare declaration has no layout to
    /// apply — it must never be planned as "close every tab").
    var layoutFile: LayoutFile? {
        guard let tabs, !tabs.isEmpty else { return nil }
        return LayoutFile(name: name, tabs: tabs)
    }
}

/// Lenient header decode used for path matching: only `name`/`path` are
/// examined, so a schema error inside `tabs:` still identifies which project
/// a file declares (and the full-decode error can then surface on apply
/// instead of the file silently unmatching). Only raw YAML syntax errors
/// defeat this.
struct ProjectFileHeader: Codable, Equatable {
    var name: String?
    var path: String?
}

extension ProjectFile {
    /// Modeline the YAML Language Server reads to attach the project-file JSON
    /// schema, mirroring `LayoutFile.schemaModeline`.
    static let schemaModeline =
        "# yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/project.schema.json"

    static func parse(yaml: String) throws -> ProjectFile {
        do {
            return try YAMLDecoder().decode(ProjectFile.self, from: yaml)
        } catch {
            throw LayoutFileError.parse(underlying: error)
        }
    }

    static func parseHeader(yaml: String) -> ProjectFileHeader? {
        try? YAMLDecoder().decode(ProjectFileHeader.self, from: yaml)
    }

    /// Serialize to YAML text, prefixed with the schema modeline.
    func yaml() throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        return try "\(Self.schemaModeline)\n\(encoder.encode(self))"
    }
}

/// Filename slugs for project files. The slug is presentation only — loading
/// never keys off it — so the rules just optimize for a browsable directory:
/// lowercase (APFS is case-insensitive; "API" and "api" must not fight over
/// one file), whitespace → `_`, unicode letters/digits and `-`/`_` kept,
/// everything else stripped.
enum ProjectSlug {
    static func slug(from name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            let ch = Character(scalar)
            if ch.isWhitespace {
                out.append("_")
            } else if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            }
        }
        return out.isEmpty ? "project" : out
    }

    /// Filename for `slug` with a numeric collision suffix: attempt 1 is
    /// `slug.yaml`, attempt 2 `slug_2.yaml`, and so on.
    static func filename(slug: String, attempt: Int) -> String {
        attempt <= 1 ? "\(slug).yaml" : "\(slug)_\(attempt).yaml"
    }
}
