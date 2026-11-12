import Foundation
@testable import Macterm
import Testing

/// Verifies the ghostty resources Macterm ships in its bundle are complete and
/// laid out correctly — the regression class behind issues #39/#40, where a
/// resources dir missing (or misplaced) `terminfo/` left `TERM=xterm-ghostty`
/// unresolvable and broke key input.
///
/// These assert against `Macterm/Resources/` in the repo (where `setup.sh`
/// extracts the downloaded `ghostty-resources.tar.gz`), i.e. the exact tree
/// folder-referenced into the app bundle. The layout mirrors a real
/// Ghostty.app: `ghostty/{themes,shell-integration}` plus a SIBLING `terminfo/`.
/// On a fresh checkout before `mise run setup`, the dir is absent — tests skip
/// rather than fail so they don't block an unprepared dev environment, but run
/// in CI where setup has happened.
struct BundledResourcesTests {
    /// Repo `Macterm/Resources` dir, located relative to this source file.
    private static let resourcesDir: URL? = {
        // …/MactermTests/Ghostty/BundledResourcesTests.swift → repo root is 3 up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Ghostty
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
        let dir = root.appendingPathComponent("Macterm/Resources")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }()

    private func exists(_ relativePath: String) -> Bool {
        guard let base = Self.resourcesDir else { return false }
        return FileManager.default.fileExists(
            atPath: base.appendingPathComponent(relativePath).path
        )
    }

    /// True once `setup.sh` has populated resources — gate every assertion on
    /// this so a fresh checkout skips instead of failing.
    private var resourcesPresent: Bool { Self.resourcesDir != nil }

    @Test
    func terminfo_is_a_sibling_of_the_ghostty_resources_dir() throws {
        try #require(resourcesPresent, "run `mise run setup` to populate Macterm/Resources")
        // THE load-bearing invariant. GHOSTTY_RESOURCES_DIR points at
        // Resources/ghostty, and libghostty derives TERMINFO as
        // dirname(GHOSTTY_RESOURCES_DIR)/terminfo = Resources/terminfo. So
        // terminfo MUST sit beside ghostty/, never inside it. A flat layout
        // (terminfo under Resources/ghostty/) reintroduces #39/#40.
        #expect(exists("ghostty/shell-integration"), "resources dir Resources/ghostty missing")
        #expect(exists("terminfo"), "terminfo/ must be a sibling of ghostty/ (libghostty derives it via dirname)")
        #expect(!exists("ghostty/terminfo"), "terminfo must NOT live inside ghostty/ — that breaks the dirname derivation")
    }

    @Test
    func terminfo_contains_xterm_ghostty_entry() throws {
        try #require(resourcesPresent, "run `mise run setup` to populate Macterm/Resources")
        // macOS ncurses reads a hashed layout: the first letter of the entry is
        // its hex ASCII code, so xterm-ghostty lives under terminfo/78/ (x=0x78),
        // NOT terminfo/x/. This is the exact entry whose absence broke #39/#40.
        #expect(
            exists("terminfo/78/xterm-ghostty"),
            "compiled xterm-ghostty entry missing from terminfo tree"
        )
    }

    @Test
    func shell_integration_ships_for_every_supported_shell() throws {
        try #require(resourcesPresent, "run `mise run setup` to populate Macterm/Resources")
        for shell in ["bash", "zsh", "fish", "elvish", "nushell"] {
            #expect(
                exists("ghostty/shell-integration/\(shell)"),
                "ghostty/shell-integration/\(shell) missing — libghostty reads this at runtime"
            )
        }
    }

    @Test @MainActor
    func themes_are_bundled() throws {
        try #require(resourcesPresent, "run `mise run setup` to populate Macterm/Resources")
        // The theme that the defaults layer names must ship, or a fresh install
        // starts with ghostty's built-in colors. The bundled themes are
        // upstream's iTerm2-Color-Schemes names, spaces and all.
        let line = try #require(MactermConfig.defaults.first { $0.line.hasPrefix("theme = ") }?.line)
        let theme = line.dropFirst("theme = ".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        #expect(exists("ghostty/themes/\(theme)"), "default theme \(theme) is not bundled")
    }

    /// The build key that the app reads from the names of its server files
    /// (`ServerBuilds.bundledKey`) is the key of the server that setup
    /// installed (`.server-key`).
    @Test
    func the_bundled_server_key_is_the_installed_build() {
        guard let resourcesDir = Self.resourcesDir else { return }
        let stamp = resourcesDir
            .deletingLastPathComponent() // Macterm
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(".server-key")
        guard let key = try? String(contentsOf: stamp, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return }
        #expect(ServerBuilds.bundledKey == key, "the bundle's server files are not build \(key) — run `mise run setup`")
    }

    /// The zmx inside the built bundle must be signed as the app itself. Each
    /// session daemon disclaims the app at spawn and is the *responsible
    /// process* for every program in its session, and macOS identifies a
    /// responsible process by its code signature's identifier: with the app's,
    /// the daemon resolves to Macterm's name, usage descriptions and existing
    /// Local Network / TCC grants (#419). Zig's linker signs the build
    /// only as `zmx`, and Xcode never re-signs a Mach-O it copies into
    /// Resources/, so `scripts/embed-zmx.sh` does it — this pins that a build
    /// phase edit can't silently turn every pane prompt into one for "zmx".
    /// Read from the test host's own bundle, which is the built app.
    @Test
    func bundled_zmx_is_signed_as_the_app() throws {
        let zmx = try #require(
            Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "zmx"),
            "zmx/zmx missing from the built bundle — run `mise run setup`"
        )
        let appID = try #require(Bundle.main.bundleIdentifier)
        let signature = try Self.run("/usr/bin/codesign", ["--display", "--verbose", zmx.path])
        #expect(signature.status == 0, "codesign could not read zmx: \(signature.output)")
        #expect(
            signature.output.contains("Identifier=\(appID)\n"),
            "zmx is not signed as \(appID):\n\(signature.output)"
        )
    }

    /// The MIT licence of zmx needs its notice with every copy of the server.
    @Test
    func bundled_zmx_ships_its_licence_notice() throws {
        let license = try #require(
            Bundle.main.url(forResource: "LICENSE", withExtension: nil, subdirectory: "zmx"),
            "zmx/LICENSE missing from the built bundle — see scripts/embed-zmx.sh"
        )
        let text = try String(contentsOf: license, encoding: .utf8)
        #expect(text.contains("Permission is hereby granted"))
        #expect(text.contains("Eric Bower"))
    }

    /// The app carries a gzip server build for every host target, named for
    /// the bundled build key, for an install on a host with no download. The
    /// macOS one is the bundled zmx itself, so it has the signature that
    /// `bundled_zmx_is_signed_as_the_app` pins. Each Linux one is an ELF
    /// binary for the machine that its name says.
    @Test
    func server_builds_ship_for_every_host_target() throws {
        let key = try #require(ServerBuilds.bundledKey, "no server build in the bundle — run `mise run setup`")
        let zmx = try #require(Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "zmx"))
        let bundledZmx = try Data(contentsOf: zmx)
        for target in ZmxHostTarget.allCases {
            let check: (Data) -> Bool = switch target {
            case .macOS: { $0 == bundledZmx }
            case .linuxX86_64: { Self.isELF($0, machine: 62) }
            case .linuxAarch64: { Self.isELF($0, machine: 183) }
            }
            let name = "macterm-\(key)-\(target.rawValue)"
            let url = try #require(
                Bundle.main.url(forResource: name, withExtension: "gz", subdirectory: "server"),
                "server/\(name).gz missing from the built bundle — run `mise run setup`"
            )
            let binary = try Self.gunzip(url)
            #expect(check(binary), "server/\(name).gz is not the build for \(target)")
        }
    }

    /// True for an ELF file whose `e_machine` (little endian, offset 18) is
    /// `machine`: 62 is x86_64, 183 is aarch64.
    private static func isELF(_ data: Data, machine: UInt16) -> Bool {
        guard data.count > 20, data.prefix(4) == Data([0x7F, 0x45, 0x4C, 0x46]) else { return false }
        let index = data.startIndex
        return UInt16(data[index + 18]) | UInt16(data[index + 19]) << 8 == machine
    }

    private static func gunzip(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "gzip could not read \(url.lastPathComponent)")
        return data
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
