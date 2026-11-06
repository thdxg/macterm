import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "TTYCommand")

/// A command run under a pseudo-terminal of its own, so that a program which
/// asks on its tty (ssh for a password or a host key, scp through it) can
/// be answered from a sheet instead of failing with no tty.
///
/// The background operations of a remote project run ssh with `BatchMode`,
/// which turns every prompt into a refusal: right for a poll that nobody
/// watches, wrong for an install the user just clicked (#699). This runs
/// the command with one end of a pty as its controlling terminal,
/// reads the other end on the main queue, and hands each chunk to `onOutput`;
/// the owner looks for a prompt at the tail (`SSHPrompt.detect`) and
/// answers with `write`. A Touch ID key needs nothing here: its dialog is
/// the key provider's own.
///
/// `posix_spawn`, never `fork`, because the app has threads. `SETSID` makes
/// the child a session leader, and the first tty a session leader opens is
/// its controlling terminal, so the program's end is opened in the child by
/// a file action, without `O_NOCTTY`.
@MainActor
final class TTYCommand {
    private var ptyFD: Int32 = -1
    private(set) var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var pendingBytes = Data()

    /// Everything the command printed, as text. A secret the owner wrote is
    /// never here: the program turned echo off before it asked.
    private(set) var output = ""

    enum Failure: Error {
        case noTerminal
        case spawn(Int32)
    }

    deinit {
        if ptyFD >= 0 { close(ptyFD) }
    }

    /// Starts `argv`, resolved through `/usr/bin/env` like every background
    /// operation of a remote project, so the user's `ssh` on PATH is the
    /// one that runs. `onOutput` gets each chunk as it arrives, after it was
    /// appended to `output`.
    func start(argv: [String], onOutput: @escaping @MainActor (String) -> Void) throws {
        precondition(pid == 0, "a TTYCommand runs once")
        ptyFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard ptyFD >= 0, grantpt(ptyFD) == 0, unlockpt(ptyFD) == 0,
              let terminalPath = ptsname(ptyFD).map({ String(cString: $0) })
        else {
            if ptyFD >= 0 { close(ptyFD)
                ptyFD = -1
            }
            throw Failure.noTerminal
        }
        // A size, so a program that asks gets one instead of 0×0.
        var size = winsize(ws_row: 24, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(ptyFD, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, terminalPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addclose(&actions, ptyFD)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let fullArgv = ["/usr/bin/env"] + argv
        var cArgv: [UnsafeMutablePointer<CChar>?] = fullArgv.map { strdup($0) }
        cArgv.append(nil)
        defer { cArgv.forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, "/usr/bin/env", &actions, &attributes, &cArgv, environ)
        guard rc == 0 else {
            close(ptyFD)
            ptyFD = -1
            throw Failure.spawn(rc)
        }
        pid = child
        logger.info("started pid \(child, privacy: .public): \(argv.first ?? "", privacy: .public)")

        let source = DispatchSource.makeReadSource(fileDescriptor: ptyFD, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(ptyFD, &buffer, buffer.count)
            if n > 0 {
                pendingBytes.append(contentsOf: buffer[0 ..< n])
                flushBytes(final: false)
                let text = output
                onOutput(text)
            } else if n == 0 || errno != EAGAIN {
                // EOF, or EIO when the program's end closed: the program is done
                // with its terminal.
                readSource?.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            flushBytes(final: true)
            if ptyFD >= 0 { close(ptyFD) }
            ptyFD = -1
        }
        readSource = source
        source.resume()

        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(child, &status, 0)
            let code: Int32 = if (status & 0x7F) == 0 { (status >> 8) & 0xFF } else { 128 + (status & 0x7F) }
            exitStatus = code
            exitSource?.cancel()
            // The last output may still be in the pty; the read source
            // delivers it before EOF cancels it.
            for waiter in exitWaiters {
                waiter.resume(returning: code)
            }
            exitWaiters = []
            logger.info("pid \(child, privacy: .public) exited \(code, privacy: .public)")
        }
        exitSource = exit
        exit.resume()
    }

    /// Decodes what arrived. A chunk can end inside a UTF-8 sequence, so
    /// the tail that does not decode waits for the next chunk; at the end,
    /// what is left decodes with replacement.
    private func flushBytes(final: Bool) {
        var cut = pendingBytes.count
        if !final {
            // Back off at most three bytes to the start of an unfinished
            // multibyte character.
            var i = pendingBytes.count - 1
            var steps = 0
            while i >= 0, steps < 3, pendingBytes[i] & 0xC0 == 0x80 {
                i -= 1
                steps += 1
            }
            if i >= 0, pendingBytes[i] & 0x80 != 0 {
                let lead = pendingBytes[i]
                let needed = lead & 0xE0 == 0xC0 ? 2 : lead & 0xF0 == 0xE0 ? 3 : lead & 0xF8 == 0xF0 ? 4 : 1
                if pendingBytes.count - i < needed { cut = i }
            }
        }
        guard cut > 0 else { return }
        output += String(decoding: pendingBytes.prefix(cut), as: UTF8.self)
        pendingBytes.removeFirst(cut)
    }

    /// Answers a prompt: `text` and a newline go to the program's tty.
    func write(_ text: String) {
        guard ptyFD >= 0 else { return }
        let line = text + "\n"
        let data = Array(line.utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(ptyFD, base + offset, buffer.count - offset)
            }
            if n <= 0 { break }
            offset += n
        }
    }

    /// Stops the program: SIGTERM, and SIGKILL a second later if it stays.
    func terminate() {
        guard pid > 0, exitStatus == nil else { return }
        kill(pid, SIGTERM)
        let child = pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, exitStatus == nil else { return }
            kill(child, SIGKILL)
        }
    }

    /// The exit code, once the program exits (a signal reads as 128 plus
    /// its number).
    func waitForExit() async -> Int32 {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { continuation in
            exitWaiters.append(continuation)
        }
    }
}
