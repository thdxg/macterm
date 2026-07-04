import Foundation
@testable import Macterm
import Testing

struct ProjectPathTests {
    // MARK: - Local

    @Test
    func absolute_path_is_local() {
        #expect(ProjectPath.parse("/Users/me/dev/api") == .local("/Users/me/dev/api"))
    }

    @Test
    func tilde_path_is_local() {
        #expect(ProjectPath.parse("~/dev/api") == .local("~/dev/api"))
        #expect(ProjectPath.parse("~") == .local("~"))
    }

    @Test
    func colon_after_first_slash_is_local() {
        // A colon inside a directory name doesn't make the path remote —
        // scp's rule only looks before the first slash.
        #expect(ProjectPath.parse("/data/backups:old") == .local("/data/backups:old"))
    }

    @Test
    func relative_and_empty_paths_are_invalid() {
        #expect(ProjectPath.parse("foo/bar") == nil)
        #expect(ProjectPath.parse("") == nil)
        #expect(ProjectPath.parse("   ") == nil)
    }

    // MARK: - Remote

    @Test
    func host_and_directory_is_remote() {
        #expect(ProjectPath.parse("devbox:~/dev/api")
            == .remote(user: nil, host: "devbox", directory: "~/dev/api"))
    }

    @Test
    func user_host_directory_is_remote() {
        #expect(ProjectPath.parse("deploy@10.0.0.5:/srv/app")
            == .remote(user: "deploy", host: "10.0.0.5", directory: "/srv/app"))
    }

    @Test
    func remote_directory_may_be_relative_to_remote_home() {
        #expect(ProjectPath.parse("devbox:work/api")
            == .remote(user: nil, host: "devbox", directory: "work/api"))
    }

    @Test
    func empty_host_user_or_directory_is_invalid() {
        #expect(ProjectPath.parse("devbox:") == nil)
        #expect(ProjectPath.parse(":~/dev") == nil)
        #expect(ProjectPath.parse("@devbox:~/dev") == nil)
        #expect(ProjectPath.parse("user@:~/dev") == nil)
    }

    @Test
    func surrounding_whitespace_is_trimmed() {
        #expect(ProjectPath.parse("  /a/b  ") == .local("/a/b"))
    }

    // MARK: - Canonicalization

    @Test
    func canonical_expands_tilde() {
        let home = NSHomeDirectory()
        #expect(ProjectPath.canonicalLocal("~/dev") == "\(home)/dev")
    }

    @Test
    func canonical_strips_trailing_slash_and_dot_segments() {
        #expect(ProjectPath.canonicalLocal("/a/b/") == "/a/b")
        #expect(ProjectPath.canonicalLocal("/a/b/../c/./d") == "/a/c/d")
        #expect(ProjectPath.canonicalLocal("/") == "/")
    }

    @Test
    func canonical_does_not_resolve_symlinks() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("projectpath-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        // The link path stays the link path — distinct from the target.
        #expect(ProjectPath.canonicalLocal(link.path).hasSuffix("/link"))
    }

    // MARK: - Matching

    @Test
    func local_paths_match_canonically() {
        #expect(ProjectPath.matches("/a/b/", "/a/b"))
        #expect(ProjectPath.matches("~/dev", NSHomeDirectory() + "/dev"))
        #expect(!ProjectPath.matches("/a/b", "/a/c"))
    }

    @Test
    func remote_paths_match_structurally() {
        #expect(ProjectPath.matches("devbox:~/dev", "devbox:~/dev"))
        #expect(!ProjectPath.matches("devbox:~/dev", "other:~/dev"))
        #expect(!ProjectPath.matches("devbox:~/dev", "me@devbox:~/dev"))
    }

    @Test
    func local_never_matches_remote_or_invalid() {
        #expect(!ProjectPath.matches("/a/b", "host:/a/b"))
        #expect(!ProjectPath.matches("foo/bar", "foo/bar"))
    }
}
