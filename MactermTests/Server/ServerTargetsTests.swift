import Foundation
@testable import Macterm
import Testing

@MainActor
struct ServerTargetsTests {
    // MARK: - The host's target

    @Test(arguments: [
        ("Linux", "x86_64", ZmxHostTarget.linuxX86_64),
        ("Linux", "amd64", .linuxX86_64),
        ("Linux", "aarch64", .linuxAarch64),
        ("Linux", "arm64", .linuxAarch64),
        ("Linux", "ARM64", .linuxAarch64),
        ("Darwin", "arm64", .macOS),
        ("Darwin", "x86_64", .macOS),
    ])
    func a_known_host_maps_to_its_asset(system: String, machine: String, target: ZmxHostTarget) {
        #expect(ZmxHostTarget.detect(system: system + "\n", machine: machine + "\n") == target)
    }

    @Test(arguments: [
        ("Linux", "i686"), ("Linux", "riscv64"), ("Linux", "armv7l"), ("FreeBSD", "amd64"), ("OpenBSD", "amd64"),
        ("", "x86_64"), ("Linux", ""),
    ])
    func a_host_with_no_build_maps_to_nothing(system: String, machine: String) {
        #expect(ZmxHostTarget.detect(system: system, machine: machine) == nil)
    }


    // MARK: - zmx version

    @Test
    func a_fork_version_carries_its_release_tag() {
        let output = "zmx\t\t0.8.1+thdxg.build-2026-11-06-abcdef1\nghostty_vt\t1.3.2\nsocket_dir\t/tmp/zmx\n"
        #expect(ZmxVersion.parse(output) == ZmxVersion(upstream: "0.8.1", forkTag: "build-2026-11-06-abcdef1"))
        #expect(ZmxVersion.parse(output)?.isFork == true)
    }

    /// The format of the pinned 1.0.1 build's `zmx version`.
    @Test
    func a_fork_build_on_zmx_1_0_carries_its_release_tag() {
        let output = """
        zmx\t\t1.0.1+thdxg.build-2026-11-07-2d98540
        ghostty_vt\tghostty-1.4.1-dev-5UdBC-9XmgVchRr0CfxYzSRUiww0EdU1WAR3WwtMsqql
        socket_dir\t/var/folders/ld/T/zmx-501
        log_dir\t\t/Users/demo/.local/state/zmx/logs
        """
        #expect(ZmxVersion.parse(output) == ZmxVersion(upstream: "1.0.1", forkTag: "build-2026-11-07-2d98540"))
    }

    @Test
    func an_upstream_version_has_no_tag() {
        #expect(ZmxVersion.parse("zmx\t\t0.8.1\nghostty_vt\t1.3.2\n") == ZmxVersion(upstream: "0.8.1", forkTag: nil))
        #expect(ZmxVersion.parse("0.6.0") == ZmxVersion(upstream: "0.6.0", forkTag: nil))
        #expect(ZmxVersion.parse("zmx 1.0.0") == ZmxVersion(upstream: "1.0.0", forkTag: nil))
    }

    @Test(arguments: ["", "zmx", "zmx\t\t", "command not found", "zmx\t\t0.8.1 beta", "0.8.1+thdxg."])
    func anything_else_is_not_a_version(output: String) {
        #expect(ZmxVersion.parse(output) == nil)
    }

    @Test
    func the_bundled_key_is_the_one_in_the_name_of_the_macos_build() {
        let names = ["macterm-0123abcd-universal-macos.gz", "macterm-0123abcd-x86_64-linux.gz", "README"]
        #expect(ServerBuilds.key(in: names) == "0123abcd")
        // None, two, or a name that is not one word: no key.
        #expect(ServerBuilds.key(in: ["macterm-0123abcd-x86_64-linux.gz"]) == nil)
        #expect(ServerBuilds.key(in: names + ["macterm-ffff-universal-macos.gz"]) == nil)
        #expect(ServerBuilds.key(in: ["macterm-a b-universal-macos.gz"]) == nil)
    }

}
