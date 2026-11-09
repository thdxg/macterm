@testable import Macterm
import Testing

struct V1SessionsTests {
    private typealias Proc = V1Sessions.Process

    @Test
    func a_v1_daemon_is_found_by_its_argv() {
        #expect(V1Sessions.daemonSession(argv: ["/A/zmx", "__daemon", "macterm-a", "--", "sh"]) == "macterm-a")
        #expect(V1Sessions.daemonSession(argv: ["zmx", "__daemon", "ctl"]) == "ctl")
        // A v2 session, a client and another program are not v1 daemons.
        #expect(V1Sessions.daemonSession(argv: ["/A/zmx", "__session", "macterm-a", "--", "sh"]) == nil)
        #expect(V1Sessions.daemonSession(argv: ["/A/zmx", "attach", "macterm-a"]) == nil)
        #expect(V1Sessions.daemonSession(argv: ["/bin/other", "__daemon", "macterm-a"]) == nil)
        #expect(V1Sessions.daemonSession(argv: []) == nil)
    }

    @Test
    func the_targets_are_the_named_daemons_and_the_programs_of_their_panes() {
        let processes = [
            // The named daemon, its login shell, and a program in its pty.
            Proc(pid: 10, ppid: 1, sid: 10, argv: ["/A/zmx", "__daemon", "macterm-a", "--", "login"]),
            Proc(pid: 11, ppid: 10, sid: 11, argv: []),
            Proc(pid: 12, ppid: 11, sid: 11, argv: []),
            // A program in the same pty session that was reparented.
            Proc(pid: 13, ppid: 1, sid: 11, argv: []),
            // A child that left the pty session but is still a descendant.
            Proc(pid: 14, ppid: 12, sid: 14, argv: []),
            // A daemon that no pane names, and its shell.
            Proc(pid: 20, ppid: 1, sid: 20, argv: ["/A/zmx", "__daemon", "ctl"]),
            Proc(pid: 21, ppid: 20, sid: 21, argv: []),
            // A v2 session of the same name, and its shell.
            Proc(pid: 30, ppid: 1, sid: 30, argv: ["/A/zmx", "__session", "macterm-a", "--", "sh"]),
            Proc(pid: 31, ppid: 30, sid: 31, argv: []),
        ]
        let targets = V1Sessions.targets(in: processes, names: ["macterm-a", "macterm-gone"])
        #expect(targets.daemons == [10])
        #expect(targets.programs == [11, 12, 13, 14])
    }

    @Test
    func no_named_daemon_gives_no_targets() {
        let processes = [
            Proc(pid: 20, ppid: 1, sid: 20, argv: ["/A/zmx", "__daemon", "ctl"]),
            Proc(pid: 21, ppid: 20, sid: 21, argv: []),
        ]
        #expect(V1Sessions.targets(in: processes, names: ["macterm-a"]) == .init(daemons: [], programs: []))
    }
}
