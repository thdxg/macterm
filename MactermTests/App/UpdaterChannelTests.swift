import Foundation
@testable import Macterm
import Sparkle
import Testing

/// An update channel is a **wire contract** spanning files that cannot reference
/// each other: the Swift channel name, the `<sparkle:channel>` value the
/// publishing workflow hands `scripts/publish-appcast.sh`, and the preference
/// key that gates it. A rename on one side silently strands that channel's
/// followers — Sparkle just filters out an unrecognized channel and reports "up
/// to date" forever, with no error anywhere. These tests pin the literals, and
/// the version ordering the channels depend on, through the REAL shell helpers
/// and Sparkle's own comparator.
///
/// `Updater` itself isn't instantiated here: constructing it starts Sparkle's
/// machinery (and in a hosted test bundle would fire a real update check), so
/// the tests cover the pure contract rather than the framework bridge.
@MainActor
struct UpdaterChannelTests {
    @Test
    func updater_starts_only_for_distributed_release_builds() {
        let realKey = "real-release-public-key"

        #expect(UpdaterAvailability.shouldStart(
            isDebug: false, isBenchmark: false, publicKey: realKey
        ))
        #expect(!UpdaterAvailability.shouldStart(
            isDebug: true, isBenchmark: false, publicKey: realKey
        ))
        #expect(!UpdaterAvailability.shouldStart(
            isDebug: false, isBenchmark: true, publicKey: realKey
        ))
        #expect(!UpdaterAvailability.shouldStart(
            isDebug: false,
            isBenchmark: false,
            publicKey: UpdaterAvailability.placeholderPublicKey
        ))
        #expect(!UpdaterAvailability.shouldStart(
            isDebug: false, isBenchmark: false, publicKey: nil
        ))
    }

    @Test
    func placeholder_public_key_matches_the_build_and_release_contracts() throws {
        let placeholder = UpdaterAvailability.placeholderPublicKey
        let root = repoRoot()
        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let buildScript = try String(
            contentsOf: root.appendingPathComponent("scripts/build.sh"),
            encoding: .utf8
        )
        let releaseWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        #expect(project.contains("SPARKLE_ED_PUBLIC_KEY: \(placeholder)"))
        #expect(buildScript.contains(
            #"SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-\#(placeholder)}""#
        ))
        #expect(releaseWorkflow.contains(
            "\"$SPARKLE_ED_PUBLIC_KEY\" == \"\(placeholder)\""
        ))
    }

    /// `publish-appcast.sh` no longer hardcodes a channel name — it interpolates
    /// `$CHANNEL`, which its callers supply: `release.yml` leaves it unset (so
    /// the script derives `beta` from `PRERELEASE`) and `release-tip.yml` passes
    /// `tip`. So the wire contract is pinned at those two seams instead of at
    /// the item template.
    @Test
    func channel_names_match_the_workflow_literals() throws {
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/publish-appcast.sh"),
            encoding: .utf8
        )
        // The item template interpolates the channel rather than naming one.
        #expect(script.contains("<sparkle:channel>'\"${CHANNEL}\"'</sparkle:channel>"))
        // …and beta is the script's own default for a prerelease.
        #expect(script.contains("CHANNEL=\"\(betaUpdateChannel)\""))

        let tipWorkflow = try String(
            contentsOf: repoRoot().appendingPathComponent(".github/workflows/release-tip.yml"),
            encoding: .utf8
        )
        #expect(tipWorkflow.contains("CHANNEL: \(tipUpdateChannel)"))
        // A rolling channel MUST replace its items; appending one per commit to
        // main would grow the feed every updater downloads without bound, and
        // leave items naming DMGs the release has since pruned.
        #expect(tipWorkflow.contains("ROLLING: \"true\""))
    }

    /// Sparkle restricts channel names to letters, numbers, dashes,
    /// underscores, and periods. An invalid name is silently ignored.
    @Test(arguments: [betaUpdateChannel, tipUpdateChannel])
    func channel_name_is_a_valid_sparkle_channel(name: String) {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        #expect(!name.isEmpty)
        #expect(name.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    /// With no stored preference the channel comes from the BUILD
    /// (`UpdateChannel.bundleDefault`), and for every build but a tip one that
    /// is stable — so a fresh install of a stable or beta DMG must never see a
    /// prerelease. A wrong default here would push every user onto prereleases
    /// at the next background check.
    @Test
    func update_channel_defaults_to_the_builds_own_channel() throws {
        let defaults = try #require(UserDefaults(suiteName: "macterm.updater-channel-tests.\(UUID().uuidString)"))
        #expect(defaults.string(forKey: Preferences.Keys.updateChannel) == nil)
        // Mirrors Preferences.init's read for an unset key.
        let value = defaults.string(forKey: Preferences.Keys.updateChannel)
            .flatMap(UpdateChannel.init(rawValue:)) ?? UpdateChannel.bundleDefault
        #expect(value == UpdateChannel.bundleDefault)
        // The test bundle is not a tip build, so that resolves to stable — which
        // also proves an absent/unsubstituted Info.plist value can't strand a
        // user on a prerelease channel.
        #expect(value == .stable)
    }

    /// `MactermUpdateChannel` is written by scripts/build.sh from the version
    /// string via `macterm_update_channel`. Only a tip build stamps `tip`;
    /// a beta stamps `stable`, because a beta sorts BELOW the stable release of
    /// the same X.Y.Z and so can never dead-end the way a tip would.
    @Test(arguments: [
        ("1.24.2", "stable"),
        ("1.24.2-beta.3", "stable"),
        ("1.24.2-tip.7", "tip"),
        ("0.0.0", "stable"),
    ])
    func bundle_channel_stamp_is_tip_only_for_tip_builds(version: String, expected: String) throws {
        #expect(try runLibHelper("macterm_update_channel", version) == expected)
        #expect(UpdateChannel(rawValue: expected) != nil)
    }

    /// An unrecognized persisted value (hand-edited defaults, or a case removed
    /// in a later version) must fall back rather than stranding the user on a
    /// channel that no longer exists.
    @Test
    func unknown_persisted_channel_falls_back() {
        #expect((UpdateChannel(rawValue: "nightly") ?? .stable) == .stable)
    }

    @Test
    func selecting_a_channel_round_trips() {
        let prior = Preferences.shared.updateChannel
        defer { Preferences.shared.updateChannel = prior }

        for channel in UpdateChannel.allCases {
            Preferences.shared.updateChannel = channel
            #expect(Preferences.shared.updateChannel == channel)
        }
    }

    /// The picker persists `rawValue`, and `beta`'s raw value doubles as the
    /// Sparkle channel name — so a case rename would silently change both the
    /// stored preference and the wire value.
    @Test
    func channel_raw_values_are_the_persisted_and_wire_contract() {
        #expect(UpdateChannel.stable.rawValue == "stable")
        #expect(UpdateChannel.beta.rawValue == "beta")
        #expect(UpdateChannel.tip.rawValue == "tip")
        #expect(betaUpdateChannel == UpdateChannel.beta.rawValue)
        #expect(tipUpdateChannel == UpdateChannel.tip.rawValue)
        // Three channels ship; adding one needs a publisher passing its CHANNEL
        // and a `sparkle_comparison_version` mapping that orders it.
        #expect(UpdateChannel.allCases.count == 3)
    }

    /// Stable items must carry NO channel element — an item tagged with any
    /// channel is invisible to default updaters, so accidentally channel-tagging
    /// a stable release would silently cut off every user on the default
    /// channel. The script refuses that combination outright.
    @Test
    func publish_script_tags_only_prereleases() throws {
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/publish-appcast.sh"),
            encoding: .utf8
        )
        // A channel on a non-prerelease is a hard error, not a silent tag.
        #expect(script.contains(#"if [[ -n "$CHANNEL" && "$PRERELEASE" != "true" ]]; then"#))
        // The channel element is emitted only when a channel is actually set…
        #expect(script.contains(#"if [[ -n "$CHANNEL" ]]; then"#))
        // …and the item template interpolates it rather than hardcoding it.
        #expect(script.contains("${CHANNEL_LINE}"))
    }

    // MARK: - Version ordering

    /// `sparkle_comparison_version` (scripts/_lib.sh) maps a marketing version
    /// to the 4-component string Sparkle actually ORDERS by. The mapping is
    /// exercised through the real shell helper — a Swift reimplementation here
    /// would pass while the shipped script drifted.
    ///
    /// Why the mapping exists at all: `SUStandardVersionComparator` treats a
    /// `-beta.N` suffix as insignificant, ranking `0.9.0-beta.1 == 0.9.0`. Left
    /// raw, beta→beta and beta→stable updates would silently never appear.
    @Test(arguments: [
        ("1.8.0", "1.8.0.9999"),
        ("0.9.0-beta.1", "0.9.0.1"),
        ("0.9.0-beta.10", "0.9.0.10"),
        ("0.0.0", "0.0.0.9999"),
        // Tip keeps the stable sentinel and appends the commit count, so it
        // sorts ABOVE the stable release it was built on top of.
        ("1.24.2-tip.1", "1.24.2.9999.1"),
        ("1.24.2-tip.42", "1.24.2.9999.42"),
    ])
    func comparison_version_mapping(input: String, expected: String) throws {
        #expect(try runComparisonHelper(input) == expected)
    }

    /// The ordering the whole scheme exists to produce, asserted through
    /// Sparkle's own comparator rather than by eyeballing the strings.
    @Test
    func betas_sort_below_their_stable_and_among_themselves() throws {
        let cmp = SUStandardVersionComparator()
        func version(_ v: String) throws -> String {
            try runComparisonHelper(v)
        }

        // beta 1 < beta 2 < beta 10 < stable 0.9.0 < stable 1.0.0
        let ordered = try [
            version("0.9.0-beta.1"),
            version("0.9.0-beta.2"),
            version("0.9.0-beta.10"),
            version("0.9.0"),
            version("1.0.0"),
        ]
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(
                cmp.compareVersion(lower, toVersion: higher) == .orderedAscending,
                "\(lower) should sort below \(higher)"
            )
        }
    }

    /// The sentinel must not be `.0`: the comparator ranks `0.9.0.0.9 > 0.9.0`,
    /// so padding stable with fewer components than beta inverts the order.
    /// Guards against someone "simplifying" 9999 away.
    @Test
    func stable_sentinel_outranks_every_beta_component() throws {
        let cmp = SUStandardVersionComparator()
        let stable = try runComparisonHelper("0.9.0")
        let highestBeta = try runComparisonHelper("0.9.0-beta.9998")
        #expect(cmp.compareVersion(highestBeta, toVersion: stable) == .orderedAscending)
    }

    /// The ordering the tip channel depends on, asserted through Sparkle's own
    /// comparator rather than by eyeballing the strings.
    ///
    /// A tip build must rank ABOVE the stable release it sits on top of (it is
    /// strictly newer code), and BELOW the next stable — otherwise a tip
    /// follower is offered a downgrade to older code, or never leaves tip.
    @Test
    func tip_sorts_above_its_base_stable_and_below_the_next() throws {
        let cmp = SUStandardVersionComparator()
        func version(_ v: String) throws -> String {
            try runComparisonHelper(v)
        }

        // stable 1.24.2 < tip.1 < tip.2 < tip.10 < stable 1.25.0 < its tip.1
        let ordered = try [
            version("1.24.2"),
            version("1.24.2-tip.1"),
            version("1.24.2-tip.2"),
            version("1.24.2-tip.10"),
            version("1.25.0"),
            version("1.25.0-tip.1"),
        ]
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(
                cmp.compareVersion(lower, toVersion: higher) == .orderedAscending,
                "\(lower) should sort below \(higher)"
            )
        }
    }

    /// The base-bump case, called out separately because it is the one that
    /// makes the whole scheme monotonic: the commit count RESTARTS at 1 under a
    /// higher base, and that restarted count must still outrank a large count
    /// under the previous base. It holds only because X.Y.Z is compared first.
    @Test
    func a_restarted_tip_count_still_outranks_the_previous_base() throws {
        let cmp = SUStandardVersionComparator()
        let old = try runComparisonHelper("1.24.2-tip.9998")
        let new = try runComparisonHelper("1.25.0-tip.1")
        #expect(cmp.compareVersion(old, toVersion: new) == .orderedAscending)
    }

    // MARK: - Tip version derivation

    /// `macterm_tip_version` must pick the newest `vX.Y.Z` tag as its base — and
    /// the two tags it MUST ignore are exactly the ones a naive `git describe`
    /// or `--sort=-v:refname` would hand back: the rolling `tip` tag (which
    /// release-tip.yml force-moves onto HEAD, so it is always the *closest* tag)
    /// and a `vX.Y.Z-beta.N` prerelease. Either would make the version
    /// unparseable by `sparkle_comparison_version` or non-monotonic.
    @Test
    func tip_version_ignores_the_tip_tag_and_beta_tags() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macterm-tip-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lib = repoRoot().appendingPathComponent("scripts/_lib.sh").path
        let script = """
        set -e
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
        export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git init -q -b main .
        git commit -q --allow-empty -m one
        git tag v1.9.0
        git commit -q --allow-empty -m two
        git tag v1.10.0
        git commit -q --allow-empty -m three
        git commit -q --allow-empty -m four
        # Both of these are newer and closer than v1.10.0, and both must lose.
        git tag v1.11.0-beta.1
        git tag -f tip
        source \(lib)
        macterm_tip_version
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let version = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(process.terminationStatus == 0)
        // v1.10.0 (not v1.9.0 — version sort, not lexical) plus the two commits
        // on top of it.
        #expect(version == "1.10.0-tip.2")
        // And the result must round-trip through the comparison mapping.
        #expect(try runComparisonHelper(version) == "1.10.0.9999.2")
    }

    /// Runs the real `sparkle_comparison_version` from scripts/_lib.sh.
    private func runComparisonHelper(_ version: String) throws -> String {
        try runLibHelper("sparkle_comparison_version", version)
    }

    /// Runs a function from the real scripts/_lib.sh, so a test can never pass
    /// against a Swift reimplementation while the shipped script drifts.
    private func runLibHelper(_ function: String, _ argument: String) throws -> String {
        let lib = repoRoot().appendingPathComponent("scripts/_lib.sh").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \(lib); \(function) \(argument)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repoRoot() -> URL {
        // #filePath is <repo>/MactermTests/App/UpdaterChannelTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
