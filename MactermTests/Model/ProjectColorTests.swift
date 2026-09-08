import AppKit
import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectColorTests {
    @Test
    func an_absent_tag_reads_as_no_color() {
        let project = Project(name: "p", path: "/tmp")

        #expect(project.colorName == nil)
        #expect(project.color == nil)
    }

    @Test
    func an_unknown_stored_value_reads_as_no_color() {
        // A hand-edited projects.json — or a tag written by a newer build —
        // must degrade to "untagged", never fail the row's decode or resolve
        // to some other color.
        let project = Project(name: "p", path: "/tmp", colorName: "chartreuse")

        #expect(project.color == nil)
    }

    @Test
    func a_project_decodes_from_json_written_before_color_tags_existed() throws {
        // The colorName key is simply absent in an older projects.json.
        let json = """
        {"id":"\(UUID().uuidString)","name":"legacy","path":"/tmp","sortOrder":0,\
        "createdAt":0}
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))

        #expect(project.name == "legacy")
        #expect(project.color == nil)
    }

    @Test
    func the_tag_round_trips_through_json() throws {
        let project = Project(name: "p", path: "/tmp", colorName: ProjectColor.purple.rawValue)
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        #expect(decoded.color == .purple)
    }

    @Test
    func every_case_renders_a_distinct_color() {
        // The guard that matters, and the one the palette-derived version
        // failed while its test passed: two tags must never RESOLVE to the
        // same color. Checking that the cases mapped to distinct ANSI slots
        // proved nothing — Rose Pine aliases slot 9 onto 1 and 13 onto 5, so
        // "Orange" drew exactly "Red". Compare the resolved values, in a
        // single color space so the comparison is meaningful.
        let colors = ProjectColor.allCases.compactMap {
            NSColor(MactermTheme.color(for: $0)).usingColorSpace(.sRGB)
        }
        #expect(colors.count == ProjectColor.allCases.count)

        let components = colors.map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        #expect(Set(components).count == components.count)
    }

    @Test
    func least_used_hands_out_every_color_before_repeating_one() {
        // "Next free, else least used" is one rule, not two: with each color
        // used once the count is flat, so the tie-break returns to the front
        // of `allCases` and the ninth project reuses the first color.
        var assigned: [ProjectColor?] = []
        for _ in ProjectColor.allCases {
            assigned.append(ProjectColor.leastUsed(among: assigned))
        }

        #expect(Set(assigned.compactMap(\.self)).count == ProjectColor.allCases.count)
        #expect(ProjectColor.leastUsed(among: assigned) == ProjectColor.allCases[0])
    }

    @Test
    func least_used_skips_colors_already_in_use() {
        let existing: [ProjectColor?] = [.red, .orange, nil, .yellow]

        #expect(ProjectColor.leastUsed(among: existing) == .green)
    }

    @Test
    func least_used_breaks_a_tie_deterministically() {
        // Every color used twice except .cyan, which is used once.
        var existing: [ProjectColor?] = ProjectColor.allCases.flatMap { [$0, $0] }
        existing.removeAll { $0 == .cyan }
        existing.append(.cyan)

        #expect(ProjectColor.leastUsed(among: existing) == .cyan)
        // The answer follows the counts, not the order they arrived in —
        // nothing rides on dictionary iteration order.
        #expect(ProjectColor.leastUsed(among: existing.reversed()) == .cyan)
        #expect(ProjectColor.leastUsed(among: existing.shuffled()) == .cyan)
    }

    @Test
    func display_names_are_title_case_and_unique() {
        let names = ProjectColor.allCases.map(\.displayName)

        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.first?.isUppercase == true })
    }
}
