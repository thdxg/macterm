import Foundation

enum FileStorage {
    static func fileURL(filename: String) -> URL {
        appSupportDirectory().appendingPathComponent(filename)
    }

    static func appSupportDirectory() -> URL {
        // The benchmark harness (scripts/benchmark.py) points this at a
        // throwaway directory so a benchmark run can't read or pollute the
        // real app data. An env override is required because
        // `.applicationSupportDirectory` resolves via the user record, not
        // `$HOME` — a temp `$HOME` doesn't isolate it.
        if let benchDir = ProcessInfo.processInfo.environment["MACTERM_BENCHMARK_DATA_DIR"],
           !benchDir.isEmpty
        {
            let dir = URL(fileURLWithPath: benchDir, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return dir
        }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        else {
            fatalError("Application Support directory unavailable")
        }
        let dir = appSupport.appendingPathComponent(appDisplayName, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }
}
