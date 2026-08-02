import Foundation
@testable import Macterm

/// Decodes a bare `tabs:` fixture into a `LayoutFile`.
///
/// A layout has no standalone on-disk form — it's the `tabs:` of a central
/// project file — so fixtures are parsed through `ProjectFile` and unwrapped
/// via `layoutFile`, keeping these tests on the exact decode path the app uses.
/// The synthetic `path:` only satisfies the required field; nothing reads it.
enum LayoutFixture {
    static func parse(_ yaml: String) throws -> LayoutFile {
        let file = try ProjectFile.parse(yaml: "path: /fixture\n" + yaml)
        guard let layout = file.layoutFile else { throw LayoutFileError.noTabs }
        return layout
    }
}
