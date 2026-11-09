import Darwin
import Foundation
@testable import Macterm

/// An sshd of this user on a free port of 127.0.0.1, with its own host key,
/// a key for the client, and an ssh config that names it `box`.
struct LocalSSHD {
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") }

    let directory: URL
    let port: UInt16
    let process: Process

    var configFile: URL { directory.appendingPathComponent("ssh_config") }
    var logFile: URL { directory.appendingPathComponent("sshd.log") }

    var configuration: SSHConnections.Configuration {
        SSHConnections.Configuration(
            ssh: ["/usr/bin/ssh"],
            options: ["-F", configFile.path],
            controlDirectory: directory.appendingPathComponent("cm"),
            askpass: nil
        )
    }

    /// `sshdOptions` are more lines of the sshd config (`SetEnv HOME=…`).
    init(passphrase: String = "", sshdOptions: [String] = []) throws {
        // A short path: control sockets live under it.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mt-sshd-\(UInt32.random(in: 0 ... .max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.keygen(directory.appendingPathComponent("host_key").path, passphrase: "")
        try Self.keygen(directory.appendingPathComponent("user_key").path, passphrase: passphrase)
        let authorized = directory.appendingPathComponent("authorized_keys")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("user_key.pub"), to: authorized)
        port = try Self.freePort()

        let sshdConfig = directory.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(directory.path)/host_key
        AuthorizedKeysFile \(authorized.path)
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        PidFile \(directory.path)/sshd.pid
        LogLevel INFO
        \(sshdOptions.joined(separator: "\n"))
        """.write(to: sshdConfig, atomically: true, encoding: .utf8)
        try """
        Host box
          HostName 127.0.0.1
          Port \(port)
          IdentityFile \(directory.path)/user_key
          IdentitiesOnly yes
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
          LogLevel ERROR

        """.write(to: directory.appendingPathComponent("ssh_config"), atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-f", sshdConfig.path, "-E", directory.appendingPathComponent("sshd.log").path]
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !((try? String(contentsOf: directory.appendingPathComponent("sshd.log"), encoding: .utf8))?
            .contains("Server listening") ?? false)
        {
            guard Date() < deadline, process.isRunning else { throw CocoaError(.fileReadUnknown) }
            usleep(50000)
        }
    }

    func addToConfig(_ line: String) throws {
        let text = try String(contentsOf: configFile, encoding: .utf8)
        try (text.replacingOccurrences(of: "Host box\n", with: "Host box\n  \(line)\n"))
            .write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// A ControlMaster that the user started, outside Macterm.
    func startUsersOwnControl(controlPath: String) throws -> Process {
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = ["-F", configFile.path, "-M", "-N", "-S", controlPath, "box"]
        ssh.standardInput = FileHandle.nullDevice
        try ssh.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: controlPath) {
            guard Date() < deadline, ssh.isRunning else { throw CocoaError(.fileReadUnknown) }
            usleep(50000)
        }
        return ssh
    }

    func acceptedLogins() -> Int {
        let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        return log.components(separatedBy: "\n").count { $0.contains("Accepted publickey") }
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func keygen(_ path: String, passphrase: String) throws {
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", passphrase, "-f", path]
        try keygen.run()
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw CocoaError(.fileWriteUnknown) }
        return UInt16(bigEndian: address.sin_port)
    }
}
