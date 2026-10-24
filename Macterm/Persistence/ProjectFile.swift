import Foundation
import Yams

/// A hand-authorable project declaration in the central directory
/// (`~/.config/macterm/projects/*.yaml`) — the one place a project's layout is
/// declared. One file per project:
///
///     name: API server           # optional, display only
///     path: devbox:~/dev/api     # folder-backed project identity
///     zmxPath: ~/bin/zmx         # optional — explicit remote zmx path
///     tabs:                      # optional — same schema as LayoutFile
///       - run: "npm run dev"
///
/// `path` is scp-style (`ProjectPath`): a plain absolute/`~` path is local,
/// `[user@]host:dir` is remote. Files are matched to projects by canonicalized
/// path, re-resolved on every use — the filename is a cosmetic slug and never
/// identity. `zmxPath` (#104) is the absolute remote zmx path used verbatim
/// when PATH resolution can't find it (only meaningful for remote `path`).
/// A project without a folder omits `path` and declares its UUID as `id`.
/// Its layout matches that ID, including after a rename. Relative pane paths
/// resolve from the home folder.
/// Files and the runtime project list are deliberately decoupled: Macterm
/// writes a file only on explicit "Save Layout", and never deletes one.
struct ProjectFile: Codable, Equatable {
    var name: String?
    /// Identity for a project without a folder. Folder-backed files keep
    /// matching by path and do not need this field. Declared second, so a
    /// saved file has it at the top: a hand edit of `tabs:` does not reach it.
    var id: UUID?
    var path: String?
    var zmxPath: String?
    var tabs: [LayoutTab]?

    /// Bridge to the layout types `LayoutBuilder`/`LayoutReconciler` consume.
    /// nil when the file declares no tabs (a bare declaration has no layout to
    /// apply — it must never be planned as "close every tab").
    var layoutFile: LayoutFile? {
        guard let tabs, !tabs.isEmpty else { return nil }
        return LayoutFile(name: name, tabs: tabs)
    }

    /// The project this file declares. nil when it names none: no path, and
    /// no ID or the pinned workspace's. `parse` refuses such a file and
    /// `ProjectFileStore.write` refuses to write one.
    var identity: ProjectFileIdentity? {
        ProjectFileIdentity(path: path, id: id)
    }
}

/// What a layout file declares as its project: the folder of a project with
/// one, else the ID of a project without one. The one value every lookup in
/// `ProjectFileStore` takes, so no caller can pass a path and forget the ID.
enum ProjectFileIdentity: Equatable, CustomStringConvertible {
    case path(String)
    case id(UUID)

    init(_ project: Project) {
        self = project.path.map(Self.path) ?? .id(project.id)
    }

    /// A path wins over an ID. The pinned workspace's ID identifies no
    /// project file.
    init?(path: String?, id: UUID?) {
        if let path {
            self = .path(path)
        } else if let id, id != PinnedTabs.projectID {
            self = .id(id)
        } else {
            return nil
        }
    }

    var description: String {
        switch self {
        case let .path(path): path
        case let .id(id): "id \(id.uuidString)"
        }
    }
}

/// Lenient header decode used for path matching: only `name`/`path`/`id` are
/// examined, so a schema error inside `tabs:` still identifies which project
/// a file declares (and the full-decode error can then surface on apply
/// instead of the file silently unmatching). Only raw YAML syntax errors
/// defeat this.
struct ProjectFileHeader: Codable, Equatable {
    var name: String?
    var path: String?
    var id: UUID?

    /// A folder matches by `path`. A project without one matches only a file
    /// that declares its ID and no path.
    func matches(_ identity: ProjectFileIdentity) -> Bool {
        switch identity {
        case let .path(projectPath): ProjectPath.matches(path, projectPath)
        case let .id(projectID): path == nil && id == projectID
        }
    }
}

/// `id` was an unknown key, which decoding ignored, before projects without a
/// folder. A file with a folder can carry an `id:` that is not a UUID (a note
/// that someone wrote), so a bad value reads as no ID and does not fail the
/// file. A file with no path and a bad ID then fails as a file with no ID.
extension ProjectFile {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        id = try? container.decodeIfPresent(UUID.self, forKey: .id)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        zmxPath = try container.decodeIfPresent(String.self, forKey: .zmxPath)
        tabs = try container.decodeIfPresent([LayoutTab].self, forKey: .tabs)
    }
}

extension ProjectFileHeader {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        id = try? container.decodeIfPresent(UUID.self, forKey: .id)
    }
}

extension ProjectFile {
    /// Modeline the YAML Language Server reads to attach the project-file JSON
    /// schema, so a saved file gets completion/validation in editors with no
    /// per-user setup. Hand-authored files can add the same line.
    static let schemaModeline =
        "# yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/project.schema.json"

    static func parse(yaml: String) throws -> ProjectFile {
        do {
            let file = try YAMLDecoder().decode(ProjectFile.self, from: yaml)
            guard file.identity != nil else {
                throw DecodingError.keyNotFound(
                    CodingKeys.path,
                    .init(
                        codingPath: [],
                        debugDescription: """
                        A project file needs a path or a project ID. \
                        The ID must be a UUID that is not the ID of the pinned tabs.
                        """
                    )
                )
            }
            return file
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

/// Filename slugs for project files. The rules optimize for a browsable
/// directory: lowercase (APFS is case-insensitive; "API" and "api" must not
/// fight over one file), whitespace → `_`, unicode letters/digits and `-`/`_`
/// kept, everything else stripped.
///
/// A single declaration still loads by `path:` alone regardless of filename (a
/// hand-rename survives). But when one directory backs several projects — each
/// declaring the same `path:` — the slug is the tiebreaker that gives each a
/// stable layout-file identity: a project's own file is the path-match whose
/// filename `owns` its slug (see `owns(filename:slug:)`).
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

    /// Whether `filename` is one `slug` produces: `<slug>.yaml`, or a numeric
    /// collision variant `<slug>_N.yaml` (extension and case ignored) — the
    /// inverse of `filename(slug:attempt:)`. Lets a lookup pick a project's own
    /// declaration among several files that share one `path:`.
    static func owns(filename: String, slug: String) -> Bool {
        let base = (filename as NSString).deletingPathExtension.lowercased()
        let slug = slug.lowercased()
        if base == slug { return true }
        guard base.hasPrefix(slug + "_") else { return false }
        return Int(base.dropFirst(slug.count + 1)) != nil
    }
}
