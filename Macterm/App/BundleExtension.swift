import Foundation

extension Bundle {
    static let appResources: Bundle = {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for candidate in candidates {
            guard let candidate else { continue }
            let path = candidate.appendingPathComponent("Macterm_Macterm.bundle")
            if let bundle = Bundle(path: path.path) { return bundle }
        }
        return .module
    }()
}
