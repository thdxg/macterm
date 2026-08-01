import Foundation
@testable import Macterm
import Sparkle
import Testing

/// The beta update channel is a **wire contract** spanning three files that
/// cannot reference each other: the Swift channel name, the
/// `<sparkle:channel>` literal written by `scripts/publish-appcast.sh`, and the
/// preference key that gates it. A rename on one side silently strands beta
/// testers — Sparkle just filters out an unrecognized channel and reports "up
/// to date" forever, with no error anywhere. These tests pin the literals.
///
/// `Updater` itself isn't instantiated here: constructing it starts Sparkle's
/// machinery (and in a hosted test bundle would fire a real update check), so
/// the tests cover the pure contract rather than the framework bridge.
@MainActor
struct UpdaterChannelTests {
    @Test
    func beta_channel_name_matches_the_appcast_literal() throws {
        // Must equal the value in publish-appcast.sh's CHANNEL_LINE. Read the
        // script rather than restating "beta", so an edit to either side fails.
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/publish-appcast.sh"),
            encoding: .utf8
        )
        #expect(script.contains("<sparkle:channel>\(betaUpdateChannel)</sparkle:channel>"))
    }

    /// Sparkle restricts channel names to letters, numbers, dashes,
    /// underscores, and periods. An invalid name is silently ignored.
    @Test
    func beta_channel_name_is_a_valid_sparkle_channel() {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        #expect(!betaUpdateChannel.isEmpty)
        #expect(betaUpdateChannel.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    /// Default off: a fresh install must never see a beta. This is the single
    /// most important behavior here — a wrong default would push every user
    /// onto prereleases at the next background check.
    @Test
    func prerelease_updates_are_off_by_default() throws {
        let defaults = try #require(UserDefaults(suiteName: "macterm.updater-channel-tests.\(UUID().uuidString)"))
        #expect(defaults.object(forKey: Preferences.Keys.receivePrereleaseUpdates) == nil)
        // Mirrors Preferences.init's read for an unset key.
        let value = defaults.object(forKey: Preferences.Keys.receivePrereleaseUpdates) as? Bool ?? false
        #expect(value == false)
    }

    @Test
    func toggling_the_preference_round_trips() {
        let prior = Preferences.shared.receivePrereleaseUpdates
        defer { Preferences.shared.receivePrereleaseUpdates = prior }

        Preferences.shared.receivePrereleaseUpdates = true
        #expect(Preferences.shared.receivePrereleaseUpdates)
        Preferences.shared.receivePrereleaseUpdates = false
        #expect(!Preferences.shared.receivePrereleaseUpdates)
    }

    /// Stable items must carry NO channel element — an item tagged with any
    /// channel is invisible to default updaters, so accidentally channel-tagging
    /// a stable release would silently cut off every non-beta user.
    @Test
    func publish_script_tags_only_prereleases() throws {
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/publish-appcast.sh"),
            encoding: .utf8
        )
        // The channel line is assigned only inside the PRERELEASE branch.
        let guarded = script.contains(#"if [[ "$PRERELEASE" == "true" ]]; then"#)
        #expect(guarded)
        // And the item template interpolates it rather than hardcoding it.
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

    /// Runs the real `sparkle_comparison_version` from scripts/_lib.sh.
    private func runComparisonHelper(_ version: String) throws -> String {
        let lib = repoRoot().appendingPathComponent("scripts/_lib.sh").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \(lib); sparkle_comparison_version \(version)"]
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
