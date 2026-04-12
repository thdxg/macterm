import Foundation

enum FileStorage {
    static func fileURL(filename: String) -> URL {
        appSupportDirectory().appendingPathComponent(filename)
    }

    static func appSupportDirectory() -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        else {
            fatalError("Application Support directory unavailable")
        }
        let dir = appSupport.appendingPathComponent("Macterm", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }
}
