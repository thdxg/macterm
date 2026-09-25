import Foundation
import Testing

/// The `macterm` binary the build copied into the test host's bundle
/// (`Contents/Resources/bin/macterm`), run as a child process. The CLI's own
/// code — argument parsing, help, the offline verbs — lives in the
/// `MactermCLI` target, out of reach of `@testable import`, so tests pin it by
/// running the real binary.
enum BundledCLI {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `macterm` with `arguments` until it exits. `environment`, when
    /// given, replaces the inherited one.
    static func run(_ arguments: [String], environment: [String: String]? = nil) throws -> Result {
        let binary = try #require(
            Bundle.main.url(forResource: "macterm", withExtension: nil, subdirectory: "bin"),
            "bin/macterm missing from the built bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain both pipes before waiting, or a full pipe deadlocks the child.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }
}
