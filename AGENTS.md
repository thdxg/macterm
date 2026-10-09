# Macterm Codebase Guide

A macOS terminal emulator built with SwiftUI and libghostty. It has a project-based sidebar, split panes, persistent zmx sessions, remote (ssh) projects, a quick-terminal overlay, desktop widgets and a control CLI. Since #353, it also has any number of windows on one shared model.

This file is the map. It says what exists, how the parts fit together, and which rules we learned the hard way. Each rule has no backstory. The reason for a rule is in three places. The first is the doc comment on the symbol that the rule names. The second is the PR that introduced the rule. The third is the git history of this file (the revision from before 2026-09 has the full narratives). When you change a rule, change its doc comment too.

## Build & Run

```bash
mise install          # Install tools (gh, swiftformat, swiftlint, xcodegen, xcbeautify)
mise run setup        # Download pre-built GhosttyKit.xcframework + ghostty resources + zmx
mise run run          # Build and launch (debug)
mise run logs         # Stream live logs from the debug app (--release for release app)
mise run format       # Auto-fix formatting with swiftformat
mise run lint         # swiftlint
mise run test         # Run the unit test suite
mise run e2e          # Debug build + end-to-end suite against the real app
mise run bench        # Release build + resource benchmark
mise run build        # Release build + DMG
mise run install      # Copy the built app to /Applications
```

`format`, `lint`, `test`, `e2e` and `bench` show a spinner. They print output only when they fail. **Always pass `--verbose`** (`mise run test --verbose`) to stream the raw output.

Macterm needs macOS 14 or later and Swift 6.0 or later. Liquid glass and some chrome refinements are macOS 26 (Tahoe) features. They are behind `#available` and `WindowAppearance.glassSupported`.

### The terminal core

- **"libghostty" here means `ghostty-internal`**. Upstream marks it "not for external use". `libghostty-vt` (the public library) has no surface API, so it is not a fallback. Treat every `ghostty_*` symbol as a symbol that can change without notice. Pin it, probe it and diff it. Do not assume it.
- `GhosttyKit.xcframework`, `Macterm/Resources/{ghostty,terminfo}` and the bundled `zmx` are artifacts of the `thdxg/ghostty` and `thdxg/zmx` forks. Git ignores them. **Run `mise run setup` in every new checkout, including a git worktree**. Never make a symlink to them from another checkout. The presence check of setup would then never refresh them.
- Both fork releases are **pinned** (`GHOSTTYKIT_TAG` and `ZMX_TAG` in `scripts/setup.sh`). Setup records them in the stamps `.ghosttykit-tag` and `.zmx-tag`, which git ignores. A change of a pin is its own commit that a reviewer can check.
  - A weekly auto-PR changes the GhosttyKit pin (`.github/workflows/bump-ghosttykit.yml`). It needs the `GH_PAT` secret, so that CI runs on it. It attaches an API review from `scripts/ghosttykit-api-diff.sh`. Read the section "renumbered enum constants" in that report. Swift imports enum constants by name, so a new constant in the middle of an enum compiles with no error.
  - `.github/workflows/bump-zmx.yml` does the same for zmx. It attaches the downstream patches that changed, in place of an API review. Nothing compiles against zmx, so End-to-end is the real gate of that PR.
- A pinned tag is **not immutable**. The fork has uploaded assets again under the same tag. If a build behaves differently from an identical commit, compare the sizes of `GhosttyKit.xcframework/*/Headers/ghostty.h` before you suspect your own change. For the same reason, the DerivedData caches of CI have a key that includes the hash of that header. Do not merge the restore step and the save step in `test.yml`. Do not add a `restore-keys` fallback that does not depend on the framework.
- Setup needs the `GHOSTTY_ACTION_OUTPUT_ACTIVITY` ABI (the heartbeat for tab activity). To bisect to a commit from before that requirement, install a GhosttyKit of the same time by hand. Do not run setup.
- If a tree looks stale (a stamp does not match reality), run `rm -rf GhosttyKit.xcframework Macterm/Resources/terminfo && mise run setup`.

## Architecture

```
MactermApp (SwiftUI @main)
  └─ WindowGroup                       one scene, N windows (#353)
       └─ MainWindow  ── WindowState   per window: project, tab per project, sidebar, sheets
            ├─ SidebarContent          List with native selection
            └─ WorkspaceView
                 └─ SplitTreeView      recursive
                      └─ TerminalPane
                           └─ TerminalSurface (NSViewRepresentable)
                                └─ GhosttyTerminalNSView   owned by Pane, not SwiftUI
```

### Pane-owned NSView

A `Pane` owns its `GhosttyTerminalNSView`. `TerminalSurface.makeNSView` returns `pane.ensureNSView()`. This is a cached instance that lives as long as the `Pane`. `dismantleNSView` does nothing. The view dies only through `pane.destroySurface()`. A Ghostty surface is welded to its `NSView` and `CAMetalLayer`. If SwiftUI made the view again when the tree changes shape or you switch tabs, the surface would die. `SurfaceIncubator` is a window that is always invisible. It gives a pane that is off screen a window with a size, so that `createSurface()` can succeed early.

### State

- **`AppState`** is the single `@Observable` root. It is passed with `.environment()`. Every change to a workspace, tab, pane or window goes through it. You can inject `WorkspaceStore` for tests.
- **`ProjectStore`** is the project list (`projects.json`). It is saved on its own.
- **`Workspace`** is the collection of tabs of one project, `AppState.workspaces[projectID]`. The pinned tabs are a sentinel workspace (see Pinned Tabs).
- **`TerminalTab`** is a `SplitNode` tree plus the IDs of the focused pane and the zoomed pane. **`SplitNode`** is `.pane(Pane)` or `.split(SplitBranch)`.
- **`WindowState`** (`Macterm/App/WindowState.swift`) exists once for each window. It holds the project that the window shows and its tab for each project (`activeTabIDs`). It also holds the width and visibility of the sidebar, and the flags of the palette and sheets. Macterm saves it as `WindowSnapshot`.
- **`Preferences`** is an observable wrapper for UserDefaults. Never touch `UserDefaults.standard` in app code. Under tests, `Preferences.defaults` resolves to a side suite that Macterm wipes.

### Windows (#345, #353)

These rules make many windows work over one model:

- **The registry is keyed by `NSWindow`** (`AppState.windows`, a weak-keyed `NSMapTable`). SwiftUI makes a view and its `@State` more than one time for each real window, so the view cannot own the identity. The first `WindowState` that someone proposes for an `NSWindow` wins (`canonicalWindowState`). Register when the window attaches to the `NSWindow`. Never register in `onAppear`. Never stamp the SwiftUI window identifier.
- **There is one teardown entry**. `AppState.windowDidClose` clears every table that is for one window. A new table for one window must hang off it. Key it weakly by the window. Never key it by `ObjectIdentifier`, because Swift uses an address again.
- **App-wide values mirror the key window**. `noteKeyWindow` pushes `AppState.activeProjectID`, `Workspace.activeTabID`, `sidebarVisible`, `isCommandPaletteVisible` and similar values from the `WindowState` of the key window, and into it. Anything that you *render* for one window must read `WindowState`. It must never read the mirror. Something that happens *to* a project (a click on a notification, CLI `pane focus`) goes through `revealProject`. That function brings forward a window that already shows the project.
- **The real panes of a tab render in one window. Other windows on that tab render a mirror**. `tabOwners` is sticky (`reconcileWindowViews` settles it). A window that is not the owner gets a *shadow* tab of `Pane(mirroring:)` panes. They are connected to the same zmx sessions. Macterm builds the shadow tab again when the `shapeSignature` of the real tab changes. `WorkspaceView` maps the focus, zoom, split and click of a mirror onto the real tab by the position in the tree (`counterpartPaneID`). The pinned workspace has **no tab selection for each window**. Every path that reads `activeTabIDs` skips the sentinel.
- **Session leadership**. Only one zmx client is the leader. Its size sets the size of the pty. The other clients render dimmed. `AppState.sessionLeaders` tracks the leader. An APC claim tells zmx (`ZmxLeadership.claimSequence`, a wire contract with the zmx fork). Leadership follows the tab of the key window as a whole (`claimLeadershipForKeyWindow`). Macterm asserts the records again. It never trusts them. It sends the claim only when leadership moves, synchronously. It records the claim only if zmx received it. It never sends the claim on focus for remote panes. A window that is not the key window and whose tab has only panes that are not leaders renders `MirroredTabNotice` and not panes. The key window always renders its panes. After that, the first responder is restored through `FocusRestoration.restoreFocusWhenAttached`. It finds the window from the own view of the pane.
- **Closing and quitting**. Only the **last visible** terminal window hides when you close it (`AppDelegate.hidesInsteadOfClosing`). Every other window really closes. A quit freezes the window list (`unregisterWindow` does nothing under `AppTerminationState.isTerminating`). Without this, each window that closes would save a snapshot again with one window fewer. `restoreWindows` gives the first saved entry to the own window of the scene. It opens the others with `applicationOpenUntitledFile`. It fronts the saved key window last.
- **`AppDelegate.isTerminalWindowCandidate` answers "Is this the terminal window?"** Do not use `!(window is NSPanel)`. The function excludes marker subclasses (`QuickTerminalPanel`, `SurfaceIncubatorWindow`). Send any new auxiliary window through it. It is a heuristic. Use it only before `didBecomeMain` has cached the real pointer.
- **Macterm activates the app for a window that opens from the quick terminal while the app is inactive** (`QuickTerminalService.panelDidResignKey` → `AppDelegate.activateForKeyHandoff`). The panel does not activate the app, and it takes keys while another app is frontmost. If you type ⌘, or ⌘N into it, Settings or a new window becomes key in an inactive app. That window is dimmed and you cannot type in it. Macterm watches the handoff for one run-loop turn (the new window becomes key synchronously when the panel resigns). It forces the activation with `ignoringOtherApps: true`. That one activation skips `reopenIfNeeded`. Without this, a terminal window that is hidden comes to the front over the window that the keystroke asked for.
- **A launch that does not front the app builds no window (#241)**. This is how macOS opens apps again at login. `AppDelegate.repairMissingWindow` polls for about 3 seconds. Only if no candidate window exists, it calls `applicationOpenUntitledFile` (activation alone does nothing). The condition is "no window at all". `requestInitialWindow` debounces the call. Without these, one launch opens two windows.
- `AppDelegate.reopenIfNeeded` (the Dock click that brings the app to the front again) uses an `NSWorkspace.didActivateApplicationNotification` observer. `applicationShouldHandleReopen` is not reliable through `@NSApplicationDelegateAdaptor`. Observers that you install in `didFinishLaunching` miss window notifications at launch. On launches from the Dock or Finder, `didBecomeMain` can fire before `didFinishLaunching`.
- **Full screen is native, and fn+F belongs to AppKit**. The `toggle_fullscreen` action of ghostty (⌃⌘F and ⌘↩ by default) toggles the own window of the pane through `toggleFullScreen(_:)` (`GhosttyCallbacks`). This is the same path as the automatic Enter Full Screen menu item of AppKit. That item carries fn+F of macOS. Leave that item alone. Do not set `NSFullScreenMenuItemEverywhere` to false. Do not change its shortcut. Ghostty.app lost fn+F when it rewrote the shortcut of its full-screen item (ghostty-org/ghostty#1389). Macterm does not honor `macos-non-native-fullscreen`. The panel of the quick terminal cannot go full screen.

### Hotkeys

`HotkeyAction` and `HotkeyRegistry` hold the bindings. The defaults are in `Hotkeys.swift`. Overrides are at `macterm.hotkey.<action_id>`. `KeyRouter` installs one `NSEvent.addLocalMonitorForEvents`. It dispatches through the ordered `KeyResponder` chain in `Responders.swift`. `isAppShortcut` in `GhosttyTerminalNSView` lets registered shortcuts pass the terminal.

**Passthrough (#209)**. An action can opt in with the suffix `.passthrough`. Then Macterm gives the chord to the program in the focused pane when the name of that program is in `Preferences.passthroughPrograms`. `KeybindPassthrough` owns the policy. Both key paths (the responders *and* `isAppShortcut`) read it. Remote panes never yield. We tried two times to infer the condition (tty raw mode, "not a shell"), and both failed. Read the doc comment of the type before you try again.

**Global keybinds**. An action can opt in with the suffix `.global`. It has a column in Settings → Keymaps next to passthrough. Macterm then registers the chord as a Carbon `RegisterEventHotKey`, so it fires while another app is frontmost. This is the `global:` prefix of Ghostty. `GlobalHotkeys` owns every registration in the process, including the registration of the quick terminal (`HotkeyAction.isAlwaysGlobal`). `sync` reconciles the registrations after each rebind and each change of a flag. It leaves a chord that did not change alone. We use Carbon and not a CGEvent tap, because Carbon needs no Accessibility grant. The system also reports a chord that it will not give us (`eventHotKeyExistsErr`). The row then says so. Otherwise, a chord would do nothing anywhere, in silence.
**One owner:** Carbon consumes a registered hot key, so the local monitor never sees that keyDown. `KeyRouter` yields exactly the chords that Carbon *holds* (`yieldsToCarbon`). This states the rule that nothing fires two times. It also lets a chord that Carbon *refused* work as a plain local keybind. Two results are deliberate. A global chord always runs its app-level `AppCommand`, so it no longer reaches the own splits of the responder of the quick terminal. And Macterm refuses global together with passthrough on one action, so that it does not defeat passthrough in silence. A chord that fires brings a window to the front first (`AppDelegate.showWindow`). The exception is the toggle of the quick terminal, because its panel does not activate the app.

**Non-Latin layouts**. Some keys type no ASCII (Cyrillic, Greek, Hebrew, Arabic and others). A ⌘ chord on such a key gets its name from the Command key map of the layout: `HotkeyRegistry.commandKeyCharacter`. This is the QWERTY Latin letter that those layouts type under ⌘. That one name serves all three matchers:

1. The bindings of Macterm (`eventToken`).
2. The carve-out of `isAppShortcut` for system keys (⌘Q, ⌘H, ⌘M and ⌘,).
3. libghostty. `performKeyEquivalent` gives it the name as the text of the key.

libghostty resolves a unicode binding such as `super+c` from the text before it uses the unshifted codepoint. Under a Cyrillic layout that codepoint is `с`. Without the text, ⌘C and ⌘V matched nothing. The three matchers must agree. If they do not, the raw default bindings of ghostty (`super+q=quit`, `super+w=close_surface`) take chords that Macterm or the menu bar owns. A key that types ASCII keeps its own character. Dvorak, AZERTY and every other Latin layout are unchanged.

### Tab naming and activity

- The automatic title of a tab is the name of the foreground process (`ProcessInspector.runningProcessName`, the kernel `comm`). If there is none, it is the login shell (from `getpwuid`). `customTitle` overrides it. There is no switch for this (`macterm.tabs.autoName` is a retired key). The polling also serves busy-close and execution tracking.
- `AppState` polls in an adaptive way (`PollCadence` and `refreshAllForegroundProcesses`). It polls every 250 ms in a burst after any `.terminalPollEvent`. It polls every 1 s when the app is active and idle. It polls every 2 s when the app is inactive. It stops when nothing is on the screen.
- **The `GHOSTTY_ACTION_OUTPUT_ACTIVITY` heartbeat is the only source of activity**. It fires also while the pane is occluded. The scrollbar action in the render path does not. Completion edges (OSC 133;D and foreground transitions) rebase the row baseline. Then the late heartbeat of a fast command never starts it again as activity. `TerminalExecutionTracker` has the rules for when output that does not grow counts as work (foregrounds of AI agents after a real Return).
- **An OSC 9;4 progress ERROR ends the run as a failure**. The done dot of the tab turns red (`MactermTheme.failure`, palette 1, tooltip "Failed"). The outcome is `Pane.completionFailed`. This flag has a meaning only while the state is `.done`.
  - `executionState`'s `didSet` clears the flag each time that the state leaves `.done`. Every path that acknowledges a run therefore clears red in the same way as it clears green.
  - The code sets the flag *before* `.done` publishes. The poll that the publish wakes can save or acknowledge at once, in the same call.
  - Never add a fourth `TerminalExecutionState`. The guards of the tracker compare against `.done`.
  - REMOVE and PAUSE end a run as a success. Macterm drops a report that finds the pane not `.running`. For this reason SET → ERROR → REMOVE stays red.
  - Within a tab, running wins over failed, and failed wins over done.
  - It persists as `PaneSnapshot.completionFailed` next to `needsAttention`. It never replaces `needsAttention`.
  - The `state` of the CLI stays `done`. The percentage is never shown.
- OSC 0 and OSC 2 titles are **gated by provenance** (`Pane.receiveReportedTitle`). Macterm adopts one as `programTitle` only while the foreground is a real program. It pins the title to that pid. The title expires when the program loses the foreground. Macterm discards titles that a prompt sets (nushell, Starship). It never persists titles.
- **Macterm throttles a title report before it costs anything** (`TitleReportThrottle`, one for each pane, pure and tested).
  - The lookup of provenance and the refresh of the foreground that a title triggers cost about 100 µs of syscalls. These are `KERN_PROCARGS2` three times, and `open` and `tcgetattr` on the tty.
  - A zmx session that replays scrollback with many prompts at launch reports one title for each prompt. 150k of them froze the main thread for 14 seconds. The control socket did not answer.
  - Macterm evaluates the first title after a quiet window (`PollCadence.fastInterval`, 250 ms) at once. It holds the other titles of the window. The newest title wins. It flushes once at the end of the window. Nothing is dropped. A title is at most 250 ms late. Macterm judges it against the foreground that holds the pane at that time, which the next tick of the poll would have seen anyway.
  - `receiveReportedTitle(_:programPID:)` is the core with no throttle. The tests drive it. `destroySurface` cancels a flush that waits, and it resets the window.
- **Remote panes** have no local pid. Their name comes from OSC titles (`Pane.receiveRemoteReportedTitle`) and from `RemoteForegroundResolver`.
  - `RemoteForegroundResolver` runs one BatchMode ssh for each host about every 3 seconds. It covers the frontmost project and any pane with a boundary request or a title that waits for confirmation. The ssh runs the POSIX probe in `RemoteSpawn.foregroundProbeScript`.
  - The probe also returns the verdicts of the host about idle and about the shell (`/etc/shells`). It returns the foreground command line. This is the fallback of argv for the agent logo, as `KERN_PROCARGS2` is on the local Mac. It also gives the name of a `comm` that a version names.
  - A title that arrives while the pane is running (OSC 133, activity, progress) is shown at once. A title that arrives at a prompt that OSC 133;D announced is discarded. **Any other title is held until a probe that was sent after it sees a program in front** (`RemoteTitleConfirmation`). This is how an agent that is idle between turns keeps its title.
  - The sample of the probe is behind the host by one round trip. Never trust the sample alone. When an agent quits, the title of the shell prompt arrives while the sample still says the agent.
  - The title of a run that outlives the run stays up, not confirmed, until the probe that the end of the run requests. The last sample does not matter. This stops flicker between turns. Four events take the title down: OSC 133;D, an answer from the shell, a teardown, and a probe that cannot answer. A probe cannot answer when the host is not reachable, when authentication is refused, when the session is missing, or when Background SSH is off.
  - The revision that the code records at dispatch (`consumeRemoteProbeRequest`) decides which answers count. A timestamp does not decide it, because `ForegroundSample.sampledAt` is the time of first sight.
  - Every new held title voids the probe that is in flight. Never let a second title skip that. If it does, a probe that was sent while the program ran vouches for the title of the shell that replaced the program.
  - A title that waits wakes the poll again (`Pane.defaultRemoteTitleRetryDelay`, bounded). When every window is hidden, the poll is paused.
  - Both pipelines publish one value, `Pane.foregroundSample`. Policies such as `ForegroundPolicy.needsConfirmClose` are pure functions over it. Every busy-close guard reads `Pane.needsConfirmClose`. It never reads `needsConfirmQuit` of libghostty directly, because for a remote pane that only sees the `ssh` client.
- The whole remote probe pipeline is behind `Preferences.backgroundSSHConnections` (Settings → General → Remote Projects). This is the kill switch for hosts that need Touch ID (#272). A probe that the host refuses to authenticate suspends the probes of that host for the run.
- **`bell-features = attention` has two halves.**
  - `GHOSTTY_ACTION_RING_BELL` handles the app-level parts in `GhosttyCallbacks.ringBell`: the beep, `bell-audio-path` and `NSApp.requestUserAttention`. It also flags the pane that rings (`Pane.ringBell`). `title` and `border` are UI for each tab that Macterm does not implement.
  - The Dock badge is the second half. `BellBadge.label` is the pure rule from the count to the label (nil without `attention` or with nothing that rings, capped at `99+`). `BellBadge.apply` is the one AppKit write. `AppState.syncDockBadge` joins the two.
  - The badge counts **tabs**, not the windows of ghostty, because the user goes to a tab and looks at it.
  - The badge is DERIVED. Code never writes it from the ring. For this reason, a config reload that drops `attention` clears a badge that is already up, and no code path needs to know about clearing.
  - Acknowledgment follows the existing verdict of Macterm, "looking at the active tab". It does not follow the rule of ghostty about the next keypress. The badge therefore cannot disagree with the sidebar. A bell in the active tab of the active app is seen the moment that it rings. Everything else clears in the same way as the completion dot: tab selection, pane focus or interaction, the app that comes forward, and surface teardown.
  - Each change of the flag posts `.terminalBellStateDidChange`, so clearing is derived again with no extra work.

### Password prompts (Settings → Password Manager)

A pane that asks for a password gets a native `NSPopover` at the cursor (`PasswordBubble`). The bubble shows **Autofill** when Macterm saved a password for that prompt. It shows **Save Password?** after a password that the user typed worked. `PasswordPromptMonitor` (`Macterm/App/`) does all of this. The pure rules are in `Macterm/Model/PasswordPrompt.swift`.

- **Detection uses the tty, not the screen**. The rule is canonical mode with echo off (`ProcessInspector.terminalIsReadingPassword`). Ghostty and iTerm2 use the same rule.
  - Macterm reads the tty of the **zmx session** (`ZmxForegroundResolver.daemonTTYPath`). The check of libghostty sees the pty of the `zmx attach` client, and `cfmakeraw` keeps that pty raw for ever. Under zmx, `GHOSTTY_ACTION_SECURE_INPUT` never fires.
  - The same reading also drives `macos-auto-secure-input` (`GhosttyTerminalNSView.detectedPasswordInput`, combined with OR with `passwordInput` of libghostty). The lock badge for each pane is off by default (`macos-secure-input-indication = false` in the defaults layer), because the bubble marks the prompt.
  - Macterm reads the tty in three cases:
    1. On the output heartbeat of the pane (`viewDidOutput`), because a prompt is output.
    2. On every key that the user types into the pane (`viewDidType`). `keyDown` reports it **at the send point, as the text that the tty receives**. This is the committed text of the IME. Nothing is reported during a composition. Nothing legible is reported for an option-as-alt chord. A chord that `isAppShortcut` or the ⌃\ swallow ate is never reported. A program on the own pty of the surface has therefore already ended its read when Macterm reports the Return. An example is the ssh of a remote project. A line end belongs to the prompt that was up when the line went out.
    3. On a timer: every 1 s, with tolerance, for the focused pane while it is idle. Every 150 ms only while some pane is in a *timed* phase (`sighted`, `verifying`). A pane that is parked at a prompt or at an offer that nobody answered costs only the slow cadence.
  - `pane run` and `pane key` feed the same capture (`viewDidSendText` and `viewDidSendKey`). This is how the e2e suite answers prompts. The monitor fences off its own autofill typing (`isInjecting`).
  - Everything that the monitor reads or drives goes through `PasswordPromptMonitor.Probes`. `PasswordPromptMonitorStateTests` therefore runs the whole machine without a surface.
  - A sighting must hold for 200 ms, unless the user types at it. A script that drops echo to read a reply of the terminal is not a prompt.
  - Prompts on a remote host *inside* ssh are invisible, because the local ssh client is raw. The own ssh login of a remote project is not invisible, because ssh asks on the pty of the surface.
- **The identity is the command and the prompt line** (`PasswordEntryID`). The command is the foreground command, named by the **real path of its executable** (`ProcessInspector.passwordAsker`: `proc_pidpath` and argv without argv[0]). The prompt line is the last viewport line that is not empty.
  - Never use argv[0]. A process sets it for itself. `exec -a ssh ./fake prod` would collect the password that Macterm saved for the real ssh.
  - `runningCommand` (the capture of `run:` for a layout) still uses argv. Do not change it.
  - The prompt line separates the two passwords of `ssh -J bastion prod`.
  - There are three exceptions. `sudo …` is filed under `sudo` (one login password). Key passphrases are filed under the prompt alone. The pane of a remote project is filed under `ssh user@host`.
  - **Those two shared entries answer only a program that the user cannot have replaced** (`PasswordAsker.isProtected` and `ProcessInspector.isProtectedExecutable`). The executable and every directory above it must belong to root, and we must not be able to write them. This is true of `/usr/bin`. It is false of Homebrew and `~`.
  - Anything else with the name `sudo` is filed under its own full command. A passphrase that a program asks for, and that someone can replace, is filed under the path of that program. Without this rule, a `~/bin/sudo` earlier in PATH that prints `Password:` would get the autofill of the login password.
  - A shell that *runs a script* is a program for `passwordAsker` (`isIdleShellInvocation`). A prompt inside `./deploy.sh` is therefore filed under `/bin/sh ./deploy.sh`.
  - The idle shell itself (`read -s`) is `.shell`. It is filed by the prompt alone.
  - A foreground that Macterm cannot read is `.unknown`. It is never `.shell`. The prompt stays `sighted` and Macterm tries again. A key that the user types in the meantime taints the capture (`confirmTyping`).
  - When Macterm shows an entry, it shortens a resolved program path to its name. It drops the options that the ssh wrapper of Macterm injected (`SSHWrapper.userArguments`). The exception is a program that is named `sudo`. It keeps its path, so that it cannot pass for the real one. Matching never shortens.
  - The Details editor files through `declaredEntryID`. It trusts what the user typed.
  - **`Preferences.passwordManagerEnabled` is the master switch**. Macterm stores it under the old key "Offer to save", so an old "off" stays off. When it is off, `step` drops the pane to idle with its offers at every observation. Nothing is captured, offered or autofilled. `detectedPasswordInput` still follows the tty.
- **Macterm offers to save only on evidence** (`PasswordSubmissionJudge`).
  - These events mean failure: a failure line within `failureWindow` (3) lines of the prompt.
  - These events mean success. One is a prompt that is up again after the settle window. Another is an OSC 133 exit with **any** code. Another is output that is not a failure. The last is a tty that leaves line mode (`ICANON` off). A remote project login shows only the last event. zmx then draws the screen again from the top, and nothing is drawn below the prompt.
  - Silence for more than 12 s saves nothing.
  - Two things are deliberately not rejections. One is the exit code, because it judges the command (`sudo grep -q` exits with 1 when it accepted the password). The other is the identical prompt again with no failure line (git over HTTPS asks one time for each connection).
  - Typed keys go through `PasswordLineCapture` (DEL and ⌃H, ⌃U and ⌃W edit the line, and arrows and escape taint it). It gets them from `keyDown` before libghostty, and from `surfaceDidPasteText`.
  - Offers queue (`ssh -J` gives two). Macterm shows one at a time when no prompt is up. An offer expires after `offerLifetime` (15 minutes). Only a command that *the own shell of the pane* runs drops an offer (`foregroundProcessIsShell`). A bare Return keeps the offers. Anything that the user types into the remote shell of ssh keeps them too.
  - If a keychain write fails, the offer stays up with the error (`Offer.problem`). Macterm does not lose the secret.
  - A keystroke at a prompt while a submission is still `verifying` settles the verdict at once (`settle`). A fast retype after a rejection is therefore not captured without its first characters.
  - Failure lines count only within `failureWindow` (3) lines of the prompt. A MOTD that says "denied" is a successful login.
  - Macterm never offers prompts for one-time codes (`isOneTimeCode`).
- **Storage is the login keychain** (`KeychainPasswordStore`, service `<bundle id>.passwords`, metadata as JSON in `kSecAttrGeneric`).
  - The data-protection keychain needs an entitlement for a provisioning profile. A self-signed app cannot have it. Touch ID is therefore the gate of the app (`PasswordAuthenticator`, `.deviceOwnerAuthentication`). The default is once for each app launch. A screen lock, sleep or a switch of user also ends it. Macterm never persists it, because a lock while Macterm is quit leaves no reliable trace. The other option is every time.
  - A debug build with an ad-hoc signature gets a keychain dialog on a read.
  - Tests, `MACTERM_BENCHMARK=1` and any launch with `MACTERM_BENCHMARK_DATA_DIR` use `InMemoryPasswordStore` (`PasswordVault.isHermetic`). A **debug** build under that condition skips Touch ID. The only passwords that such a run holds are passwords that it captured itself. The e2e suite autofills with nobody at the keyboard.
- **Autofill types and never pastes** (`GhosttyTerminalNSView.sendSecret`: the text path without the evidence of a command submission, then Return). It checks the tty again after authentication. It clears a line that the user half typed with ⌃U first.
  - A refused autofill turns the next sighting into "Saved Password Did Not Work". A typed password that then works is offered as an update.
- **The bubble never keeps the key**. It has the behavior `.applicationDefined`. Every button gives the key back to the window of the terminal (`PasswordBubble.returnKey`). It does this only when the popover or nothing holds the key. It never takes the key from another window of ours.
  - The anchor is `cursorCellRect()` (the IME point of libghostty).
  - **Return is the primary button, and Escape dismisses**. Both go through the key path of the terminal (`viewWillSendKey` consumes them). They work only while the user typed nothing since the bubble appeared (`Tracker.typedSinceBubble`). `PasswordBubble.show` resets it when it reports new *content*. A new anchor after the cursor scrolled away and back does not reset it. The first character gives both keys back. A password or a command that the user types under the bubble therefore submits as usual.
  - The bubble draws no key hints.
  - A parked AeroSpace window (off screen) makes AppKit push the popover onto the visible screen. This is not an error of the anchor.
- **On demand** (`PasswordPaletteScope`, the Password Manager of the palette) types any saved entry that the user selects. It types into the focused pane of the active tab (`PasswordPromptMonitor.fillOnDemand`). It needs no prompt match and **no confirmation**. The selection is the authorization. Touch ID still gates the read.
  - The tty decides only Return (`OnDemandPasswordFill` over `TerminalLineMode`).
  - At a verified read (canonical, echo off), Macterm presses ⌃U first, then types the password, then presses Return. It judges the result as an autofill. Its `Submission.id` is the entry that the user *selected*. A rejection therefore marks that entry, and Macterm offers nothing that was typed for saving.
  - At any other place, Macterm types the password with no Return. Examples: ssh or tmux that relays a remote prompt, the line editor of a shell, and a line that echoes. Remote `sudo` is the reason that this feature exists. A wrong selection then never runs, and it never reaches a history. The user submits it or clears it.
  - If a verified read is gone after authentication, Macterm types nothing.
  - **An entry with an empty prompt is only for on-demand use** (`PasswordEntryID.isOnDemandOnly`). Detection never reads an empty prompt line, so nothing ever autofills it. Its keychain account is `<command> — on demand`.
  - The screen is also an action that you can bind (`HotkeyAction.passwordManager`). It has no keybind by default, because ⌥⌘F belongs to Autofill. It is in the View menu. It toggles the palette on that screen (`AppState.toggleCommandPalette(scope:)`). While the palette is up, the app responder stands aside, so `PaletteResponder` answers that chord itself.
  - You add entries from the `+` of Settings, or from the Add rows of the palette. Both use `PasswordEditorSheet`, which Details… shares. `MainWindow` presents the copy of the palette from `WindowState.passwordEditor`. The sheet **requires a command**. Only detection creates entries with only a prompt (key passphrases, `read -s`). You can edit them as they are. You never create them, and you never make them by hand.
- **`pane password` (DEBUG only)** reads the phase, prompt, command and bubble of a pane. It never reads a secret. `--answer accept|dismiss|autofill` presses the buttons of the bubble. `e2e/test_passwords.py` drives the whole flow with it against a `stty -echo; read` script.
- **Never** add a CLI verb, an App Intent or a log line that carries a secret. Any process in a pane can call `macterm`.
  - Autofill Password is an `AppCommand` (default ⌥⌘F). Its action is nil unless the focused pane is at a saved prompt. As for every chord with a nil action, `isAppShortcut` then swallows it in `keyDown`. It does nothing, and it does not reach libghostty (which has no default on `super+alt+f`).

### Search (`Macterm/Search/`)

**Every search in the app goes through one engine**. This covers the palette and its screens. It covers the lists in Settings (Keymaps, saved passwords). It also covers the path mode of the palette. The path mode completes and does not search, but it uses the engine in the same way. Do not add a matcher of your own. The palette of a plugin must use the engine too.

- **The ranking is the ranking of fzf** (`SearchScoring`, its `FuzzyMatchV2` and its constants).
  - The letters of a query must be a subsequence. The score has bonuses for word starts, path components and camelCase humps (Macterm reads them from the unfolded text). Consecutive runs carry the bonus of their first character. Gaps have penalties.
  - Whitespace splits the query into terms. All terms must match, in any field of a record (`split right` is the same as `right split`). A later field costs `SearchIndex.fieldPenalty` for each position. A match in a title therefore beats the same match in a subtitle.
  - Ties go to the shorter title, then to the order of the list. `SearchIndex.rank`, `Search.rank` and every palette list through `rankedByScore()` sort in the same way.
  - There is one deliberate difference from fzf: no clamp at zero. A score stays a true maximum across a long gap.
- **Lists in Settings rank too** (`Search.rank`). They never only filter. Fuzzy matching admits letters that are spread across words. In a list that stays in its own order, such a row looks the same as a strong match.
- **Macterm prepares text one time** (`SearchText`).
  - It folds case and diacritics for scalars. For ASCII it does not use Foundation. A combining mark, as in a decomposed `é`, folds away. It neither breaks a run nor starts a word.
  - It stores a bonus for each scalar and a 64-bit character mask. It also stores offsets back to the original string for highlighting (`PaletteItem.highlights`, which the row draws in semibold).
- **The engine is built for long lists** (`SearchIndex`).
  - The mask rejects with one AND. A forward scan rejects the rest before any scoring.
  - The DP runs only over the window that a match can occupy. It uses two rows at a time in buffers that Macterm uses again (`SearchScratch`).
  - Preparation and matching split across cores above `parallelThreshold`.
  - `search(limit:)` keeps only the best K, in order.
  - `SearchSession` searches only the last matches when a keystroke only narrows the query (`SearchQuery.narrows`). Files and the listing of an extension search through it. Each one prepares the text one time, when its rows arrive.
  - We measured 100k paths in an optimized build: about 45 ms to prepare and 2 to 5 ms for each search.
  - `Search` is the shortcut for a short list that you build at the moment of use.
- `SearchEngineTests` pins the ranking on the own command titles of the app. It also makes sure that top-K, the parallel path and session narrowing give the same answers as the plain path. Change the scoring only when you mean to change those tests.

### Tab switcher previews (#344)

When you hold the Recent Tab chord, `TabSwitcherOverlay` shows one card for each tab in the cycle (`AppState.tabCycleOrder`, limited by `Preferences.recentTabCandidates`). Each card is a mosaic of `PanePreview`s.

- The cards are **live**. `beginLivePreviews` sets `GhosttyTerminalNSView.rendersForPreview`. `syncOcclusion` then reports the pane as visible, and libghostty wakes its renderer. Macterm samples at 5 Hz until `commitTabCycle` runs `endLivePreviews`. Every exit from a cycle goes through it, so no renderer stays awake.
- `PanePreview.frameID` skips a new sample of a pane whose IOSurface did not change. Macterm draws the thumbnail through a provider that does not copy. This keeps a hold at about 7% CPU, in place of 30%.
- Hover never scrolls the rows (`HoverSelectionTracker`, shared with the palette).
- Do not bring back a foreground copy-poll or a renderer that uses text as a stand-in. We removed both when we could sample panes that are off screen.

### Remote Projects (#104)

A remote project is a project whose `path` is an scp-style `[user@]host:dir` (`ProjectPath` parses it). Each pane is a persistent zmx session **on the host**.

- The surface command is `ssh -t host 'sh -c '\''…'\'''` (`RemoteSpawn.paneCommand`). There is no local zmx wrapper.
- When you quit, Macterm disconnects the pane. When you start Macterm again, it connects the pane to its session by the `sessionName` that Macterm persisted.
- The ssh of the pane is interactive (prompts render in the pane).
- Background operations use `BatchMode=yes -o ConnectTimeout=5`. They run the `ssh` that PATH resolves, through `/usr/bin/env` (the same client as the pane). They kill through `ZmxClient.killRemoteSession`.

These rules for the spawn script come from tests against a real host:

- **Depend only on inputs that Macterm controls**. Never source `/etc/profile` or `~/.profile`, in any form. A `~/.profile` that ends in `exec zsh` took over the pane in three different ways. The environment of the user takes effect inside the zmx session, where their login shell starts in the normal way. `remote_scripts_never_source_profiles` enforces this.
- Ship the script as `sh -c '<script without single quotes>'`. Use `sh -c`, not `sh -lc`, because dash rejects `-l`. Add a fallback PATH (`~/bin`, `~/.local/bin`, `~/.cargo/bin`, `/usr/local/bin`, `/opt/homebrew/bin`). `Project.zmxPath` bypasses PATH completely.
- On a failure (no zmx, `cd` fails), print a `macterm:` diagnostic and drop to `${SHELL:-/bin/sh}`. A bare exit fires `closeSurface`, and the pane vanishes with no clue.
- **The host settles TERM, and the script never touches a TERM that resolves**. This includes a TERM that the user pinned to a simpler value with `SetEnv`. The script replaces only a TERM that does not resolve. It uses `xterm-ghostty` if the host has it. If not, it uses `xterm-256color`.
  - The script exports `COLORTERM=truecolor`, `TERM_PROGRAM=ghostty` and the `TERM_PROGRAM_VERSION` of libghostty itself. TERM is the only variable that ssh carries through a channel that a server cannot refuse. Programs depend on these variables. Claude Code sends OSC 9;4 progress (the status dot of an agent) only to Ghostty 1.2.0 or later.
- `RemoteTerminfo` installs our bundled `xterm-ghostty` entry (`infocmp -x | ssh … tic -x -`). It runs off the critical path. It depends on the own ghostty flag `ssh-terminfo` of the user (off by default upstream). It never caches to disk. It logs stderr only on a failure.

**Dropped connections heal by themselves (#281).**

- `AppState.reconnectDroppedRemotePanes` starts the surface of a dropped pane again in place (`destroySurface`, then `requestSurfaceReattach`, never `killPersistentSession`).
- `AppState.handleProcessExit` classifies a remote exit. It asks the host if the session survived. It **never uses the exit code**, which is always 0 on macOS.
- Only triggers cause a new connection (wake, activation, project selection), with the backoff of `RemoteReconnectPolicy`. There is no timer and no verb for the user to connect again.
- `Pane.ensureNSView` passes `command` only on the first surface build. A new start therefore never types a `run:` of a layout again.

**Macterm reaps remote orphans by an ownership stamp**. `AppState.sweepOrphanSessions` (throttled for each host) stamps `macterm.owner=<installationID>` on the sessions that our panes claim. It lists the sessions. It kills only the `macterm-*` sessions that have zero clients and carry **our** stamp (`ZmxReaper.orphans`). The labels of zmx are in memory, and you can set them only on live sessions. A session that became an orphan before the stamp is therefore spared for ever. `zmx ls --where` is not implemented, and it gives no error. Never filter on the host. Both reapers skip everything when `WorkspaceStore.loadFailed`.

### Session daemons and macOS attribution (#419)

macOS attributes work that needs privacy permission (Local Network, TCC) to the *responsible process* of a process. The value is fixed when the process starts, and the process inherits it from its parent.

- Because of this, the whole tree of a pane belonged to the Macterm that created its session. It belonged to nothing after that Macterm quit. Every process that survives becomes responsible for itself. A new start of Macterm that connects again over the zmx socket never attributes it again, because a connect is not a fork.
- From then on, macOS judged each pane program by its own identity. For anything that Apple did not sign, this meant `EHOSTUNREACH` on the local subnet, with no prompt.
- The fix is in the zmx fork (downstream patch 0004, `daemonize.zig`). On macOS, the session daemon starts itself again with `POSIX_SPAWN_SETEXEC` and `responsibility_spawnattrs_setdisclaim`. It is its own responsible process from the first instant. Every program in the session belongs to **it** for the whole life of the session, whatever happens to the app.

- **The daemon has the signature of the app itself** (`scripts/embed-zmx.sh`). It uses the certificate of the app *and* the bundle identifier of the app. The certificate is the release certificate in CI, and it is ad-hoc on your Mac.
  - macOS identifies a responsible process by the identifier in its code signature. With the identifier of Macterm, the daemon resolves to the name of Macterm, its usage descriptions and its existing grants for Local Network and TCC. One grant covers the app and every pane.
  - Any other identifier names a second thing and needs a second grant. Examples: the `zmx` of the release download, which the linker signed, and a separate "Macterm Sessions". We tried the second one. The prompt only said "zmx", because a bare binary has no LaunchServices record that gives it a name.
  - Xcode never signs a Mach-O again when it copies it into `Resources/`. An ad-hoc daemon would be a new identity at every update.
  - `build.sh` refuses a release bundle whose zmx is ad-hoc or is not `com.thdxg.macterm`. `BundledResourcesTests` pins the identifier on the zmx of the built bundle. A change in a build phase therefore cannot turn every pane prompt into a prompt for "zmx" in silence.
- Full Disk Access follows the same attribution. The programs of the daemon satisfy the own TCC requirement of the app (identifier and certificate). They inherit its FDA grant, and this stays true after the first new start.
- You cannot change responsibility afterwards (`responsibility_set_*` needs a private entitlement). The disclaim exists only as a spawn attribute. This is why the daemon starts itself again in place, and why the fork has no flag for it. The responsible root must *stay* a zmx process. A trampoline that ran the shell with exec would keep the pid, but the identity that macOS evaluates would become the identity of the shell.
- A session that an older build created keeps its old attribution until you create it again. The fix takes effect for each session.
- To measure, use `responsibility_get_pid_responsible_for_pid` (a probe in C of ten lines). A Local Network prompt that nobody *answered* denies everything under that responsible process, also platform binaries. A subnet that looks dead can be a dialog that waits.

### Pinned Tabs

Pinned tabs belong to no project. The sidebar shows them above the projects. They are a **sentinel workspace** (`workspaces[PinnedTabs.projectID]`). Its ID is a fixed UUID that is not a `ProjectStore` row, so the iteration over projects never sees it. Each pinned tab is a `PinnedTabRecord`: a durable declaration (`LayoutTab`) and, while it is loaded, a live `TerminalTab`. All the logic is in `AppState+PinnedTabs.swift`.

- Pin and Unpin are `moveTab`s. They never kill anything. `syncPinnedRecordsWithWorkspace` pins a tab that was born in the pinned workspace.
- **Closing a pinned tab is an unload. It is never a removal**. The sessions end. The record stays as a dimmed row. When Macterm starts again, it starts the tab again at once. Unpin is the path for removal.
  - The same unload happens when the own sessions of a tab die (`paneProcessExited`).
  - `unloadProject` uses the same dimmed row through `AppState.unloadedProjectIDs` (only in memory, cleared in the `didSet` of `activeProjectID`).
- The persistence has two layers.
  - The live state is in the `pinned` section of `workspaces_v3.json`.
  - The declaration is in `~/.config/macterm/pinned.yaml`. It is next to `widgets.yaml`. The location comes from `ProjectFileStore.configDirectoryURL`, and the custom store of a test keeps it inside its own directory.
  - The file is a `ProjectFile` whose reserved `path: <pinned>` is the marker. It has no IDs for entries. Macterm matches entries back by name, then by the exact layout, then by position (`PinnedLayoutMatcher`).
  - `AppState` tracks its own last write. It absorbs external edits before each write. A file that does not parse suspends the auto-writes with an alert.
  - A file that is absent or empty means "no input". It never means "remove everything".
- **`pinned.yaml` moved up from `projects/`, and the old place still works.**
  - At launch, Macterm moves an existing `projects/pinned.yaml` up (`PinnedLayoutStore.migrateLegacyFile`).
  - If it cannot move the file, or if nothing has moved it yet, every read and write uses the old file in place (`PinnedLayoutStore.fileURL`). If both files exist, the new one wins.
  - The listing of projects still skips the reserved name in `projects/`.
  - To retire the old location, drop `legacyDirectoryURL` and the fallback. This is #446. Until then, do not remove either of them.
- At launch, every record materializes. `materializeRestoredPinnedTabs` asks `zmx ls` which sessions survived. A session that is dead starts again from the declaration. The declaration refreshes at pin time, when the pinned foreground changes (debounced), and at quit. It never refreshes at unload.
- Sidebar drag: the pinned rows and the tab lists share one `.dropDestination` at the level of the ForEach. It drives the native insertion line. Rows have no destinations of their own. A target on a row kills the line and swallows clicks. `PinTabDropZone` above the List makes the first pin possible by drag. `--project pinned` addresses the workspace over the CLI.
- **No project may have the name `Pinned`** (any case, padding ignored). `ControlHandler.resolveProject` reads it as this workspace before any project, so such a project cannot be reached by name.
  - `PinnedTabs.reservesName` is the one test that every naming path applies. A typed name is refused where the user typed it. These paths are CLI `project create --name` and `project rename`, the notice of the sidebar rename, the New Project intent, and the remote sheet.
  - A name that nobody chose (the own name of a folder) becomes `Pinned 2` in `ProjectStore.create`. `ProjectStore.rename` refuses it outright.
  - Projects that got their names before the rule keep their names.

### Desktop widgets

Desktop widgets are terminals on the desktop (`DesktopWidget`, `AppState+DesktopWidgets.swift`, `DesktopWidgetWindows`, Settings → Widgets). Each one is one pane. Its zmx session persists in the same way as the session of a pinned tab. A panel of our own draws it, in the shape of a system widget. The grammar for users is in `website/docs/pages/45-desktop-widgets.md`.

- **A widget is not WidgetKit, and it cannot be.**
  - A WidgetKit widget is an archived SwiftUI snapshot that another process renders. It has no NSView and no text input. Its budget of refreshes is minutes.
  - chronod also purges the descriptors of any widget extension that has no Apple team in its signature. It logs `Requested to add extension, but purging instead because we shouldn't cache it`. We measured this with ad-hoc builds and self-signed builds, against a control with a Team ID.
  - Widgets therefore never appear in the Edit Widgets gallery of the desktop. You create them from Macterm (File menu, palette, `+` of Settings, `widget new`).
- **The metrics are measured, not guessed** (`DesktopWidgetMetrics`, `DesktopWidgetGrid`).
  - chronod logs the `CHSWidgetMetricsSpecification` of the host (`log show --predicate 'process == "chronod"'`, the entries with `cornerRadius`). The edges are 164, 344 and 704 pt. The continuous corner is 27.88 pt.
  - These edges are all spans of one module (164 pt cells, 16 pt gaps, a pitch of 180 pt). The size of a widget is therefore a `DesktopWidgetSpan`. There are no presets.
  - A new widget is `DesktopWidgetSpan.initial` (3×3). Macterm puts it at the exact middle of the screen (`DesktopWidgetGrid.centered`). It is off the lattice until its first move or resize. The lattice cell that is nearest to the middle can be half a pitch away. When the middle is taken, Macterm uses the nearest free cell of the default lattice.
  - **There is no grid for the whole screen**. Notification Center stores its widgets as groups, each with its own origin. It logs `Writing desktop widget placement storage to disk: … groups: [{origin: (18.0, 25.0), items: [<col, row, size>…]}]`.
  - Every move and resize therefore ends in `DesktopWidgetGrid.snap`. It snaps onto the lattice of the nearest widget within one pitch. This includes the system widgets. Macterm reads them from the window list (`NativeDesktopWidgets`). The window of a widget is the widget plus 8 pt of shadow. The placement file itself is in a protected container.
  - Read EVERY window, not only the windows on the screen. Notification Center reports its widgets as off screen when windows cover the desktop.
  - Accept only real widget windows. They are windows of the host, at the level of the desktop icons plus 2. They have a visible alpha and whole cells in each direction.
  - Notification Center also keeps a window with no title and alpha 0, one level below. We saw it at 464×824 after we dragged widgets around. When we read it as a widget, it blocked empty cells and pulled the widgets of Macterm onto its lattice.
  - If no widget is near, Macterm uses the default lattice of the screen at the corner inset that macOS uses (26, 33).
  - The result is the nearest cell and span, kept on the screen. If it overlaps, Macterm moves it to the nearest free cell. System widgets count as occupied.
  - `column` and `row` in `widgets.yaml` are on the default lattice. The snap after Macterm applies them pulls a widget back onto the lattice of its neighbor.
  - Measure again when a macOS release looks different.
- **Locked by default. One widget is edited at a time**. `AppState.editingDesktopWidgetID` is the single edit slot. It is only in memory, so every launch comes up locked.
  - A locked widget behaves like a system widget. `canBecomeKey` is false. `DesktopWidgetShieldView` takes every mouse event and turns a press into a widget drag. The wheel is included. Over mouse reporting or alternate scroll, the wheel is input.
  - The terminal gets no focused pane (`focusedPaneID: nil`). The one pane of a widget is always the focused pane of its tab. When we passed that through, every locked widget showed a solid cursor.
  - Editing has four parts. The first is the own edge resize of the widget. The second is the outline in the accent color. The third is a Done button. The fourth is a drag from the margin only. `DesktopWidgetResize` does the resize. It uses the outer 7 pt band of the margin and 20 pt corners. The cursors come from a tracking area with `.activeAlways`. Inside the terminal, a drag selects.
  - We do not use `.resizable` of AppKit. Its resize area for a borderless window is a sliver, and its hover cursor never showed.
  - Every drag waits for a threshold of 4 pt before `performDrag`. A jitter of a click must not move a widget. Then the code polls for the release and snaps the widget.
  - The CLI can still type into a locked widget.
- **An edited widget has no shadow**. The shadow and the rim of a KEY window come from the rectangle of the window, not from its alpha. That put a dark square behind the rounded corners. In an A/B test, the square was gone with `hasShadow = false`. The style mask and `invalidateShadow` did not change it.
- **The panel lives where system widgets live.**
  - Its level is `desktopIconWindow + 1`. It has `.canJoinAllSpaces`, `.stationary` and `.ignoresCycle`. It is borderless and `.nonactivatingPanel`. When you type into a widget, the frontmost app stays in front.
  - The quick terminal shares the key handoff through `panelDidResignKey`.
  - It is an `NSPanel`, so `isTerminalWindowCandidate` already excludes it. AeroSpace does not manage it.
  - A modal that a widget raises (`DesktopWidgetRemoval`) must activate the app first (`AppDelegate.activateWithoutReopen`). In an app that is inactive, the modal never comes forward and blocks, and nobody sees it.
- **The appearance is `WindowAppearance.syncDesktopWidget`**. The window is never opaque, because the rounded backdrop is the shape. Glass and tint are at the corner of the widget.
  - **The shape of the window is the `_cornerMask` of `DesktopWidgetPanel`**. It is the continuous corner of the widget as an image of nine parts. When we left the window server to derive the shape from the alpha, it made a coarse, jagged region with wider corners. With glass off, the CGS blur filled that region. The result was a blurred desktop around every corner, and the radius was visibly lost. Glass hid this, because it draws its material inside the curve. In an A/B test against a flat backdrop, the halo and the rim were gone with the mask.
- **There are two layers of persistence, as for pinned tabs.**
  - The snapshot (`WorkspacesFile.desktopWidgets`, schema v7) carries the session identity.
  - `~/.config/macterm/widgets.yaml` is the declaration (`WidgetLayoutStore`, schema `assets/widgets.schema.json`: keep them in sync). It has `name`, `size`, the grid `column` and `row`, and `display`. `display` is the name of the screen. Macterm always writes it, because the primary display changes with what the user plugs in. In an entry that someone wrote by hand, no `display` means the primary one. It also has the recipe for a new start, `cwd` and `run`. Macterm captures it from the live pane with the pinned rule that an idle capture never clears `run:`.
  - The file follows the rules of `pinned.yaml`:
    - Macterm writes it again after every change and at quit.
    - It absorbs external edits first (baseline of the exact text).
    - It has no IDs (`WidgetLayoutMatcher`: name, then content, then position).
    - It is authoritative for membership at launch.
    - An absent file is no input.
    - A file that does not parse suspends the writes behind an alert.
    - Macterm honors the removal of a running widget at launch only. The entry of that widget stays out of every write from then on (`unlistedDesktopWidgetIDs`). Macterm judges it against the widgets that our last write listed, so that a widget created since then is not taken for a removal. If it did not do this, the next write put the entry straight back.
  - The reconcile at launch adopts the size and the cell of an entry only where they DIFFER from the own declaration of the widget. The cell in the file is on the default lattice, and it cannot express a widget that joined the lattice of a neighbor. When Macterm derived an unchanged entry again, it moved the widget off its neighbor at every launch.
  - The reconcile also saves no snapshot. It runs before any window registers, and `windows` would be written as absent.
  - The capture of the recipe (`refreshDesktopWidgetRecipes`) drops a foreground that it saw while `Pane.isShellAtPrompt`. That is a prompt hook, and Macterm was typing it into the next new shell.
  - Macterm draws restored widgets only after `materializeRestoredDesktopWidgets` asks zmx which sessions survived. A widget that is dead starts again from its recipe. If a surface attached first, it would get the empty shell that zmx upserts.
- **Widgets follow the displays in the way of Notification Center** (`DesktopWidgetPlacement`). We measured this from its logs when we went from a 3008×1692 display to a 1920×1243 display.
  - Notification Center keeps the layout of the system widgets for each display *and* for each resolution. On a display for which it has no layout, it PROJECTS the latest layout, with the same offsets from the visible top-left. It saves nothing.
  - The `placements` of a widget therefore record where the user put it (creation, a settle, a declaration). The key is the display name plus the resolution of the whole frame, so that the Dock does not make a new key. `topLeft` is where the widget is now. Macterm never records a projection.
  - `desktopScreensDidChange` and the restore at launch both go through `placeForCurrentScreens`. `DesktopWidgetWindows` calls `desktopScreensDidChange` 1 second after the notification for the screen parameters stops firing. A connect posts it several times, and Notification Center moves its own widgets in the meantime.
  - `placeForCurrentScreens` uses the display that the widget was last put on, or else the primary display. It uses exact placements first. Then it uses projections, clamped onto the screen. A projection that would land on another widget moves to a free cell.
  - Macterm never shrinks the span to fit. That would lose its size for the large display.
  - `widgets.yaml` declares the latest *placement*, not `topLeft`. If it declared `topLeft`, a quit on the laptop would write the cell of the laptop. The next launch on the external display would adopt it.
  - Not verified live: what Notification Center does with widgets that do not fit, and if it anchors any of them to the right edge. Ours clamp.
- **Widget panes live outside every workspace**, like the panes of the quick terminal.
  - Their sessions are claims of the reaper (`desktopWidgetSessionNames`). They are bound in `session list`. They are rows in the quit prompt for the case with no persistence. The pane verbs address them through a bare `--session` (`ControlHandler.widgetTarget`).
  - When the shell of a widget exits, the widget starts again in a new session (`desktopWidgetShellExited`). It does not close.

### First-run seed

`FirstRunSeed` (pure) and `AppState.seedFirstRunIfNeeded` seed a fresh install with one project (the home directory) and one pinned "Welcome" tab. Each one runs `macterm tutor <topic>` as its `run:`.

- It runs after `restoreSelection`.
- `Preferences.hasSeededFirstRun` is written on the first launch that can answer, seeded or not. The exception is `.postpone` on `WorkspaceStore.loadFailed`.
- It is off (postponed, not skipped) under `MACTERM_BENCHMARK=1`. The harnesses look like fresh installs, and they do not isolate the defaults domain.
- The seeded `run:` is bare words, so that it tokenizes in the same way in every login shell.

### Project color tags

`Project.colorName` tints glyphs that the row already draws (the project icon, the icons of the tab rows, including agent logos and status glyphs).

- **No stripes. No glyph means no tag. No indicator in the titlebar**. We tried each alternative and rejected it.
- The colors are fixed system colors (`MactermTheme.color(for:)`). They are deliberately not derived from the ghostty palette.
- The picker is `.pickerStyle(.palette)` (`ProjectColorMenu`). It is the only menu form that renders.
- Macterm stores the color as a String, so that an unknown value becomes untagged.
- `iconStyle` wraps both arms in `AnyShapeStyle`. Without it, `tagColor ?? .secondary` coerces to `Color.secondary` in silence and restyles every untagged row.
- `Preferences.autoAssignProjectColors` (default off) is read only at creation, through a closure that you can inject on `ProjectStore`.

### Finder Services

**Services → New Macterm Project Here** is an `NSServices` entry in the plist plus `FinderServiceProvider` (`Macterm/App/FinderServices.swift`). The `NSMessage` in the plist and the `@objc` selector are a contract at run time that nothing checks. `FinderServicesTests` reads the plist back. A request can arrive before the app restores its state. The provider therefore queues requests until `attach`, and then defers through `AppState.performWhenRestored`. Use that hook for any external request at launch.

**Opening a folder or a file WITH Macterm** arrives at `AppDelegate.application(_:open:)`. The ways are Open With in Finder, a drop on the Dock icon, and `open -a Macterm <path>`. `DocumentOpenRequest` (`Macterm/App/OpenFolder.swift`) splits the request.

- Folders go to `FinderServiceProvider.open(paths:)`. This always makes a **new** project, never a tab.
- Files go to `FinderServiceProvider.openTextFiles` (see Text files below).
- A cold launch therefore uses the queue and defer from above for both.

`CFBundleDocumentTypes` has three entries. **All have `LSHandlerRank: Alternate`**, so Macterm is never a default opener until the user selects it with Get Info → Change All.

1. `public.directory` (the entry of Ghostty).
2. `public.text`.
3. A list of extensions for text that macOS does not type as text (`go`, `rs`, `ts`, which it takes for video). The Info.plist of Zed makes the same split.

Unlike Ghostty, Macterm does not declare scripts and executables. A script that you open with Macterm is edited and not run. `OpenFolderTests` reads the plist back for this contract.

**Text files (Settings → General → Text Files)** open in the terminal editor of the user (`AppState+TextFiles.swift`). Ghostty has no equivalent. Upstream declined the detection of `file:line` and a link that you can configure (discussions #11378 and #9546). This feature is therefore our own.

- **A ⌘-click goes to the pane first** (`GhosttyTerminalNSView.onOpenLink`). This is only for the `.unknown` kind of the link regex. It is never for OSC 8 or for opens by a keybind.
  - `FileLink` splits `:line[:col]` off. The regex of libghostty keeps it, and `foo.swift:42` even parses as a URL scheme. `FileLink` resolves the path against the cwd of the real pane.
  - Anything that is not an existing local file goes to the system opener, unchanged. So does every remote pane.
  - An existing file goes to its **default app, and Macterm drops the line**, because you cannot tell another app a line. The exception is that the default app is Macterm (`TextFileOpening.isDefaultApp`, by bundle id). Then the editor opens directly and keeps the line.
  - A click in a mirror acts on the real pane (`editorAnchor`). A click in the quick terminal splits the panel. A click in a desktop widget goes the Finder way.
- **The editor is `$VISUAL`, if not `$EDITOR`, if not `vi`**. This is the order of git. Macterm has no setting of its own, deliberately. The variable is where a user already names their editor.
  - **Macterm types the command. It does not start the editor with a spawn** (`TextFileEditor`). The variable and the PATH of the editor are in the shell rc of the user, and no process outside the shell can read them.
  - The typed line is a fixed ` exec sh -c '…'`. It parses in the same way in nu, fish, zsh and bash (no `'` or `\` inside). The file and the line go in the environment of the new pane (`MACTERM_EDITOR_FILE` and `MACTERM_EDITOR_LINE`). No path is ever escaped into shell grammar.
  - `exec` makes the pane close when the user quits the editor. If the editor is missing, the line waits for Return instead.
  - Macterm passes the line as `+N`. This is the one syntax that every terminal editor shares.
- **The placement** is `Preferences.textFilePlacement`. It is a split (automatic axis, `SplitDirection.auto`) next to the pane that was clicked or the focused pane of the project. It can also be a new tab.
  - The exception is the pinned workspace. It always splits. A tab that is born there would be pinned, and when you quit the editor, it would leave a dimmed row.
  - A file from Finder goes to `TextFileProject.project`. This is the deepest local project that contains it. If there is none, it is the active local project. If there is none, it is the first local project. If there is none, it is a new project for its folder. It never goes to a remote project.

**A folder that you drop on the sidebar** opens in the same way (`SidebarFolderDropTarget`, `Macterm/Views/SidebarFolderDrop.swift`, through `AppState.openProjects`, which the Finder service shares). Macterm selects it in the window where you dropped it.

- It is an AppKit view over the whole sidebar. It is registered only for `.fileURL`, and it is transparent to `hitTest`.
- AppKit picks a drag destination by the registered type. It does not ask `hitTest`. Clicks and scrolls therefore still reach the outline below it. So do the drags of tabs, projects and panes in the app, because none of them carries a file URL. No SwiftUI destination could have caught a drag from Finder there.
- The feedback is the `+` of the cursor alone.
- A drop on a pane is still the paste of a path by `GhosttyTerminalNSView`.

**SwiftUI answers that same event by opening a second window. The `handlesExternalEvents(matching:)` of the scene stops it.**

- If you leave it alone, an event for open documents gets a new `WindowGroup` window on top of the project that the delegate just selected. Then there are two windows on one tab, a dimmed mirror in front and `MirroredTabNotice` behind. It also happens when we remove our delegate method, so this is the handling of SwiftUI and not ours.
- Macterm emits no external events of its own (no URL scheme, no Handoff). The group therefore declares a condition that nothing ever matches.
- The set must be **non-empty**. `[]` means "handles no external events at all". It also silences `applicationOpenUntitledFile`. That is the only call that reliably builds a `WindowGroup` window. We measured New Window, `window new` and the repair of #241 as dead under `[]` and alive under a condition that never matches.

### Dock menu

When you right-click the Dock tile, you see **New Window**, **New Tab**, **New Project…** and **Toggle Quick Terminal**. This is the set of Ghostty. `AppDelegate.applicationDockMenu` builds it (`Macterm/App/DockMenu.swift`). `@NSApplicationDelegateAdaptor` does forward this one, and we verified it live.

- The items are `AppCommand`s. They run through `AppCommand.action(in:)`. The Dock is therefore a fourth renderer of that list, and not a second set of handlers.
- Macterm builds the menu again at each right-click with `autoenablesItems` off (enabled means that the action is not nil). The menu is nil until `MainWindow` gives the delegate its state objects.
- `DockMenu.Preparation` is what the Dock adds. A selection arrives from outside the app, and it does not activate the app.
  - New Tab and New Project… call `showWindow()` first (the last window, which is hidden, or the state with no window of #241).
  - New Window activates the app and lets the command make its own window.
  - Toggle Quick Terminal prepares **nothing**. The panel does not activate the app, by design.
- Macterm resolves the action *after* the preparation, because fronting a window is what makes `activeProjectID` the right project.
- `DockMenu.Preparation` is now the shared table for **"invoked from outside the app"**. App Intents run through the same `AppDelegate.performExternalCommand`, and they do not decide again. For this reason the table has `.toggleCommandPalette`, which you cannot reach from the Dock menu itself.

### App Intents (Shortcuts, Spotlight)

`Macterm/Intents/` has thirteen intents. They mirror the surface of Ghostty (`macos/Sources/Features/App Intents/`) in the model of Macterm. The intents for projects and tabs are **New Project**, **New Tab**, **Focus Project/Tab/Pane** and **Close Tab**. The intents for panes are **Run Command in Pane**, **Send Key**, **Get Pane Contents** and **Get Pane Details**. The other intents are **Toggle Quick Terminal**, **Open Command Palette** and **Invoke Keybind**. The grammar for users is in `website/docs/pages/85-shortcuts.md`. `AppIntents.framework` is an SDK dependency in `project.yml`. The `appintentsmetadataprocessor` of the build writes `Contents/Resources/Metadata.appintents/extract.actionsdata`.

- **Translate and delegate only**, as `ControlHandler` does. Resolve what an entity names. Then call the same `AppState` and `ProjectStore` methods that the UI calls. The own resolution of `ControlHandler` is deliberately *not* shared. It speaks selector strings (name, index from 1, UUID), but the identity of an entity is exact. `IntentTargets` therefore does lookups by UUID and by session, and the CLI is untouched.
- **`MactermIntentHost`** is the only way for an intent to reach the app. The system makes the instances of intents, so you cannot hand anything in. `AppDelegate.installResponders` attaches it. The readiness waits on `AppState.performWhenRestored`. Running a shortcut *starts* the app, so `perform()` can arrive before the restore. The wait is a bounded sleep-poll (`readinessTimeout`). A launch that does not front a window may never install responders (#241), and a hang would wedge the shortcut with no error.
- **Entities are tokens, not handles**. `MactermPaneEntity.id` is the zmx **session name**. It is not `Pane.id`. Pane UUIDs are new at every restore. A saved shortcut that used one would break at the first new start, *in silence*, while the pane that it names is visibly still there. Tab IDs and project IDs are persisted, so they are fine. Every lookup can answer `.notFound`.
- **The ghostty key `macos-shortcuts` of the user** (`ask`, `allow` or `deny`, default `ask`) controls every `perform()`. `IntentPermissionGate` does this, in front of the readiness wait.
  - Macterm reads the key live from the loaded config (`GhosttyApp.shortcutsAccess` → `ShortcutsAccess.resolve`, in the shape of `MacosHidden`). The raw values are the tag names of ghostty. The key has no Settings UI.
  - `ask` remembers the answer only for the run. `.allow` is the grant that stays. Ghostty instead persists an Allow for ever under one UserDefaults key, and it does not remember a Deny at all.
  - Under `MACTERM_BENCHMARK=1`, it resolves to allow with no modal. The harnesses drive the app with nobody at the keyboard. This is also the reason why Macterm skips the notification prompt. An explicit `deny` still denies.
- **`MactermKeybind` repeats the cases and titles of `HotkeyAction`, because it must**. `appintentsmetadataprocessor` reads `caseDisplayRepresentations` from the source, and it rejects a computed dictionary ("must be a dictionary"). `MactermIntentsTests` pins the set of cases against `HotkeyAction.allCases`. It pins every label against its `AppCommand.title`. A new keybind therefore fails a test. It does not go missing from the picker in silence. The same constraint applies to any future `AppEnum`.
- **Statics must be `let`** under `SWIFT_STRICT_CONCURRENCY: complete` (`title`, `description`, `defaultQuery`, `supportedModes`). `supportedModes` is behind `#if compiler(>=6.2)`, like Ghostty. `supportedContentTypes:` of `IntentFile` exists only on macOS 15. Use `supportedTypeIdentifiers:`. Do not gate an intent away from the floor of macOS 14.
- **`linkd` indexes the intents of an app only after the app was started from a stable location.**
  - A bundle in `/private/tmp` fails registration outright (`Could not create application record … -10814`).
  - A bundle that you copied to `~/Applications` but never started logs `is not trusted for binding, skipping`.
  - Start it one time, and the audit proceeds (`Checking … extract.actionsdata` → `Collating specified bundles`).
  - This is not a problem of the signature. We reproduced it in the same way with an ad-hoc signature and with a self-signed certificate that has the shape of a release certificate.
  - To see this, run `log show --predicate 'process == "linkd"'`.

### Control CLI (`macterm`)

A bundled CLI controls the app over `<App Support>/control.sock` (target `MactermCLI`, and `PRODUCT_MODULE_NAME` must stay `MactermCLI`). Xcode copies it to `Contents/Resources/bin/macterm`. Every pane gets it in `PATH`, together with `MACTERM_SOCKET` and `MACTERM_SESSION`. The full grammar is in `website/docs/pages/80-cli.md`.

The verbs:

- `status`
- `project list/create/select/rename/remove`
- `tab list/new/select/move/rename/close/merge`
- `pane list/inspect/dump/split/focus/close/run/key/zoom/resize-split/mirror`
- `grid RxC`
- `session list/info/kill`
- `window list/new/focus/close`
- `widget list/new/set/edit/done/remove`
- `layout apply/save`
- `palette list` (the palette files of the extensions, read again each time, with the error of each one). The hidden `palette exec` is the runner of a `run:` action (`CustomPaletteLaunch`).
- `tutor`
- `ssh` (offline, the `+ssh` of ghostty natively through `SSHWrapper`)
- `skills` (offline, the agent skills below)

Rules:

- **Wire protocol** (`ControlProtocol.swift`, compiled into both targets). One request is one JSON line that ends with a newline, for each connection: `{v, id, command, args}`, with `noun.verb` commands. The responses are `{ok, data}` or `{ok:false, error:{code, message, action?}}`. The codes are in snake_case (`not_found`, `busy`, `no_surface`, `starting`, `ambiguous`).
  - The `v` of a request is the minimum version of the server that it needs. Ordinary requests stay at v1. `focus` needs v2. The handler rejects newer versions before dispatch.
  - Apps of v1 that shipped earlier ignore `v`. The CLI must therefore check newer requests against the version in the response of the server before it sends any mutation. A new version number alone cannot stop an older app from ignoring `--no-focus` in silence.
- **Server** (`ControlSocketServer`). A dedicated thread polls a non-blocking listen fd. The dispatch of each connection hops to `@MainActor`. The server starts in `applicationDidFinishLaunching`. The handler attaches in `installResponders` (early requests get `starting`). The socket has mode 0600 in a directory with mode 0700, for the same user only.
- **Handler** (`ControlHandler`). It translates and delegates only. It resolves selectors (name, UUID, index from 1). It calls the same `AppState`, `ProjectStore` and `ZmxClient` methods that the UI uses. Close verbs return a typed `busy` error, and they do not stage dialogs. A session selector with no `--project` resolves in the project that holds the session (`MACTERM_SESSION` arrives in the same way). A pane in the background can therefore still reach itself while the user looks at another project.
- **Client.**
  - Discovery order: `--socket`, then `MACTERM_SOCKET` (a hint, and the client falls through when it is stale), then the paths in App Support for each flavor.
  - stdout has output only on success. The exit code is 0 for ok, 1 for an error of the app, 2 for not reachable.
  - **Targeting trap:** a `--socket` that is not pinned, from a debug harness, can hit the live app of the developer. An untargeted `pane run` then types into their focused pane.
  - `pane run` therefore types as given only what follows `--`. Before `--`, its own flags parse at any place, and plain words are typed. Any other word with a leading dash fails validation, and Macterm sends nothing.
  - Its text is one `.allUnrecognized` array that Macterm splits at the `--` by hand. A second array with `.postTerminator` fails the validation of ArgumentParser in debug builds.
  - `ssh` keeps `.captureForPassthrough`. It mirrors the own argv of ssh. It answers a leading `-h` or `--help` itself (`startsWithHelpFlag`).
- **Agent skills** (`macterm skills`). There are four Agent Skills (panes, workspace, sub-agents, palettes). They are `SKILL.md` files in the format of agentskills.io. They teach coding agents this CLI.
  - They are compiled into the binary from `Macterm/Control/AgentSkills/` (shared with the CLI target, like `ControlProtocol`). The CLI prints them offline: every skill after a header about the install, or one skill as it is. Agents install them themselves.
  - Agents load one skill at a time, so each skill embeds `AgentSkills.groundRules`.
  - We ran every example against a hermetic instance before it shipped. Keep it that way.
  - `AgentSkillsTests` runs every `macterm …` line in them against the tree of `--experimental-dump-help` of the bundled CLI. If you rename a verb or a flag, a test fails until the skills follow.
- **`tab new --no-focus` and `pane split --no-focus`** send the optional `ControlArgs.focus = false` (absent means true).
  - Creation skips the selection at the mutation of the model. It never selects and then restores. The history of tabs and panes and the selections of windows stay untouched. A split with no focus keeps the zoom. An empty workspace adopts its first tab with no history, because there is no selection to keep.
  - `AppState.createTab` and `splitPane` incubate only children that no window renders (this includes panes that zoom hides). Visible splits then start at their real size.
  - Every warm goes through `warmPane`: project selection, the restore of pinned tabs and the creation by the CLI. The `incubatePane` that you can inject supplies the surface. One exit closure reads `pane.projectID` at the time of the exit, so that moving a tab cannot strand it.
  - A creation in the background keeps the marker of a project that is unloaded. `isTabUnloaded` dims only the tabs that still have no surface views. It does not dim the tab that just started.
  - If you split a tab that you unloaded explicitly, Macterm starts its existing panes too. A row that is not dimmed therefore never hides a source that stopped. Other tabs stay stopped.
  - The view slot is not observed, so the warm stays synchronous with the structural redraw. A window that is ordered out still mounts new children (E2E pins this). Children that zoom hides do need incubation.
  - Remote tabs get `project.zmxPath` before the warm. A split stamps the whole target tab before any panes that are unloaded revive. The new sibling inherits the path of the source.
  - The start is asynchronous. It is not a promise that the shell prompt is ready when the CLI returns.
- `pane run` types through the paste path (`sendText`). `--no-submit` withholds the newline and keeps the evidence of a submission armed. `pane key <chord>` uses the key-encoding path (`sendKey`) and **bypasses `keyDown`**, so the interceptions of `keyDown` do not apply. A bare printable key must carry `.text`, or it encodes to nothing. `pane resize` exists only under `#if DEBUG`.

### Ghostty config pipeline

In automatic mode, Macterm delegates the user layer to `ghostty_config_load_default_files`. Settings can append custom files. `GhosttyApp.loadConfig` loads `macterm-defaults.conf`, then the user files, then `macterm-overrides.conf` (the last one wins). It regenerates both private files (`MactermConfig.regenerate()`) before every load, because the overrides depend on the content of the user. `GhosttyConfigSource` is the seam for raw text, for keys that the C API cannot expose.

**Ghostty keys that Macterm applies to its own behavior** have no Settings UI.

- `macos-shortcuts` (App Intents).
- `tab-inherit-working-directory` and `split-inherit-working-directory`. `false` means the project directory. In a project-based terminal, this is the "default working directory" of ghostty. `AppState.newTabInheritsWorkingDirectory` is the read that you can inject.
- `macos-hidden`.
- `macos-icon`.
- `focus-follows-mouse`. Macterm reads it live on each pointer move. It moves focus only away from another pane.

**When the default of Macterm departs from the default of ghostty, the departure is a line in `macterm-defaults.conf`**. The place is `MactermConfig.defaultsBody`. `MactermConfigTests` pins it: `tab-inherit-working-directory = false` and `macos-secure-input-indication = false`. It is never a fallback in `Preferences`. The user can then override it in the same way as any other key.

**Wheel scrolling belongs to libghostty on every path**. `GhosttyTerminalNSView.scrollWheel` forwards events exactly as Ghostty.app does (2× precise deltas, momentum phase). `SurfaceScrollView` only draws the scroller. It turns scroller drags into `scroll_to_row` and, under smooth scrolling, into the sub-row remainder (see Animations). We removed the row accumulator in the style of iTerm2 from #102, with its Scroll speed slider. `mouse-scroll-multiplier` therefore means the same thing here as in Ghostty. Do not bring back a wheel path on the side of Macterm.

Overrides that Macterm must lock. The `smooth-scroll`, `smooth-cursor` and `cursor-trail` lines from `MactermConfig.Animations` come in addition (see Animations).

- `background-default-transparent = true`. This is a fork patch. The renderer skips the default background, so that `WindowAppearance` composites the translucency itself.
- `background-opacity = <Preferences.windowOpacity>`. This is the real value, so that the `background-opacity-cells` of the user works.
- `background-blur = 0`. Macterm calls the CGS blur SPI.
- `env = GHOSTTY_BIN_DIR=<bundle>/Contents/Resources/ssh-bridge`. This folder holds our `ghostty` shim that relays `+ssh` to `macterm ssh`. Keep it out of any folder in the PATH of the pane.
- `shell-integration-features`, emitted again with the flags of the user plus `no-path` (`ShellIntegrationFeatures.overrideValue`, #75). You cannot write the key bare.

The state of the UI of Macterm lives in `Preferences`. It never touches this pipeline.

**Custom app icon**. Macterm honors `macos-icon = custom` and `macos-custom-icon` with the semantics of Ghostty.

- `GhosttyApp.applyAppIcon` runs after every load and reload. It reads both keys from the *loaded* config, so a `config-file` include counts. It uses `configCString`. The C getter of libghostty returns enums as their tag name, and it returns `?[:0]const u8` as a bare C string, not as a `ghostty_string_s`. This is the reason why that getter is different from `configString`.
- It passes the keys to the pure function `GhosttyAppIcon.resolve` (`.bundled` or `.custom(URL)`). With no path, it uses `~/.config/ghostty/Ghostty.icns` of Ghostty. A path that is still relative after the expansion of `~` is invalid, because the cwd of a GUI app is not predictable.
- The one AppKit write is `AppIconPresenter.apply`. It sets `NSApp.applicationIconImage`. For a file that is missing, that it cannot read or that it cannot decode, it assigns nil. This restores the icon of the bundle.
- Every other `macos-icon` value is artwork of the Ghostty brand that we do not ship. We deliberately do not mirror the Dock-tile plugin of Ghostty.
- Hermetic caveat: `loadConfig` disables the user layer under `MACTERM_BENCHMARK=1`. To verify, use a throwaway `HOME`, `XDG_CONFIG_HOME` and `ZMX_DIR` plus `MACTERM_BENCHMARK_DATA_DIR`, and **no** `MACTERM_BENCHMARK`.

**`macos-hidden`**. `never` and `always` of ghostty map to `.regular` and `.accessory` through `MacosHidden`. This is a pure function with tests. The raw values are the own tag names of ghostty, so a rename of a case breaks the wire.

- `AppDelegate.applyActivationPolicy` applies it after `GhosttyApp.shared` at launch, and again on `.mactermConfigDidChange`. It skips AppKit when the policy already agrees. This is what makes the observer safe, although the observer fires too often.
- Read it as an **enum** (`configEnum`, a bare `[*:0]const u8`). Never read it through `configString`. The `ghostty_string_s` of that function leaves `len` at 0. This is the reason why `GhosttyColorSpace` went to raw text.
- Accessory mode is deliberately narrower than that of Ghostty.app, which builds no window. Macterm still builds one, because `MainWindow.onAppear` installs the responders and attaches the control handler.
- Every explicit request for a window (`window new`, `window focus`, `revealProject`) calls `MacosHidden.activateForWindowRequest`. It forces the activation with `ignoringOtherApps: true`. We measured that cooperative activation **refuses**, in silence, a plain `activate()` and an activate from another process.
- An accessory app has no menu bar. Settings, Quit, About and Check for Updates therefore lose their only route. Keybinds are not affected (`KeyRouter` handles them, not the menu bar).

**Process locale (#370)**. `ghostty_init` calls `setlocale(LC_ALL, "")`. Under any locale with a comma as the decimal separator, the rendering of toolbar glyphs in SwiftUI asserts inside CoreUI on macOS 27. The result is SIGTRAP, with nothing on stderr. `ProcessLocale.pinNumericToC()` runs right after `ghostty_init`. It touches only `LC_NUMERIC`. To reproduce, unset `LANG` (a launch from the Dock). `OS_ACTIVITY_DT_MODE=enable ACTIVITY_LOG_STDERR=1` shows the text of the assertion.

### Bundled ghostty resources

The bundle mirrors Ghostty.app. `Contents/Resources/ghostty/{themes,shell-integration}` is there, with the compiled terminfo at the **sibling** `Contents/Resources/terminfo/`.

- `GhosttyApp.resolveResources()` sets `GHOSTTY_RESOURCES_DIR` from our own candidates. It ignores any value that it inherits.
- **Never set `TERMINFO` ourselves**. libghostty overwrites it with `dirname(GHOSTTY_RESOURCES_DIR)/terminfo`. The terminfo must therefore be a sibling of `ghostty/` (#39 and #40).
- The tree uses the hashed layout of macOS (`terminfo/78/xterm-ghostty`).
- `BundledResourcesTests` asserts all of this. It skips before setup has run.

### Animations (Settings → Animations)

This is the motion pane. It is directly under Appearance in the sidebar of Settings. It has five toggles. **Smooth scrolling** and **Animate splits** ship **on**. **Snap to whole row** and the two cursor effects are opt-in. The pane was Settings → Experimental until the first two toggles graduated. Anything that is still settling in belongs here too, off by default, until it graduates.

- **Smooth scrolling** is fork patch 0005 (`.github/downstream/0005-smooth-scroll.patch`). It is behind the fork key `smooth-scroll`. The toggle writes the key into the overrides through `MactermConfig.Animations` (`Preferences.smoothScrolling`, default on). The default of the ghostty key itself stays off.
  - `scrollCallback` of libghostty already accumulates precise trackpad deltas in pixels, and it commits whole rows. With the key on, the patch does these things:
    1. It keeps the sub-row remainder on `Screen.viewport_pixel_offset`.
    2. It captures the rows that scrolling reveals as the `RenderState` overscan of upstream (ghostty-org/ghostty#14400, the first step of the own smooth scrolling of upstream). The `beginShiftedUpdate` of the fork sets the request: `overscan.above` rows at the top, or one row below (fork PR 16).
    3. It shifts the grid by a `scroll_offset` uniform. It clips to the visible grid, which it sizes from `grid_size × cell_size`. **It never sizes it from the bottom and right of `grid_padding`**. They hold the leftover that Macterm measured at the last resize, and they go stale after the growth from the incubator to the pane.
  - Any move of the viewport by rows goes through `Screen.scroll`, which zeroes the remainder.
  - Macterm has no part in the routing of a *wheel* event. Every event reaches libghostty untouched (#393). This is exactly why the gate is a ghostty key and not a read of `Preferences`.
  - The alternate screen has no scrollback. There, the key animates a program that scrolls a region of its screen by rows. The cases are DECSTBM or DECSLRM with SU or SD, or IND or RI at the margin, which is what `less` does. The renderer draws the new content of the region, shifted by the scrolled distance, and eases it home in about a quarter of a second. The rows that scrolled out slide away as ghost rows (fork PR 11). It is in 0005 since fork PR 14, because a sync dropped it. A program that repaints every row still moves by rows.
  - **A resize moves the viewport by pixels too** (fork PR 9).
    - A grid comes only in whole rows. The leftover height of a viewport grows while you resize a pane, until it is a full row and the viewport takes one. At that instant everything on the screen jumps by one cell, because the new row comes from the scrollback at the top.
    - With the key on, the renderer gives that leftover to the render state (`RenderState.Geometry`). It adds to the remainder that a gesture left. The grid is drawn lower by that distance, with the row above partly revealed.
    - A divider drag and every split animation therefore slide the content and do not step it. The cost is a partial row at the top of any pane whose height is not a whole number of cells. It is a scrollback row. After a clear, it is the old prompt line.
    - That row selects like any other row (`RenderState.Shift.rowsAboveAt`, fork PR 17). Selection resolves the pointer to a pin. A coordinate of the viewport cannot go above the first row of the viewport, and it clamped a press there to the row below.
    - The two offsets add up. This is why more than one row can be revealed above, and why `scroll_offset` carries the leftover in `.z`. The shifted grid draws onto it, so the clip extends by it.
  - **A drag of the scroller is the one exception**. `scroll_to_row` lands on whole rows, and `Screen.scroll` zeroes the remainder on the way. `SurfaceScrollView` sends the row. Then it gives the sub-row leftover to the core as a synthetic precision scroll (`GhosttyTerminalNSView.applySubRowScrollOffset`).
    - It can aim, because `ScrollAccumulator` mirrors `Surface.mouse.pending_scroll_y`. You cannot read that value over the C API. But `scrollCallback` is its only producer, and Macterm is the only caller of `ghostty_surface_mouse_scroll`. If we mirror every delta that we send, we reproduce it.
    - The size of the nudge lands the accumulator exactly on the remainder that we want. That remainder is under one cell, so it commits no row of its own. If the aim is wrong, the cost is at most one row of offset until the next update of the drag.
    - The multiplier that it divides out is the `mouse-scroll-multiplier` of the user. Macterm reads it from raw config text (`MouseScrollMultiplier`), because the key is a Zig struct that has no shape in C.
    - Macterm skips this with the toggle off, and when there is no scrollback to drag through.
  - **The render state enforces two rules. We found each one when we measured frames** (see `RenderState.resolveShift` in the fork).
    1. Macterm validates the remainder of the gesture *on its own* before it adds the resize leftover. A remainder that has no row to reveal is dropped, and the leftover still shifts the grid. If we validated the sum instead, a scroll that is pinned at the bottom made the content bob on every event. The bob was up to the height of the leftover. The remainder cycles through one cell while row after row fails to commit.
    2. The render state measures the leftover *against the row count of the terminal* (`Geometry.terminal_height`). The renderer never measures it against its own grid. The size of the renderer and the rows of the terminal change on different threads. A frame that fell between the two drew the grid one whole cell off. Every divider drag showed this as a slide and then a snap back.
  - **Anything that turns a pixel into a row takes the shift from the render state** (`RenderState.resolveShift`, fork PR 13).
    - This covers the hit test of the surface (selection, clicks, links), mouse reports and the IME point. They subtract exactly the shift that a frame draws, validation included.
    - A copy of the arithmetic in `Surface.posToViewport` skipped those checks. It put the pointer one row off in every place where they drop the shift (#433). The pointer was below the row at the bottom of the scrollback after a scroll. It was above the row in a pane without scrollback, on the alternate screen and at the top of the history.
    - The offsets of an animation of a region scroll are state of the renderer for each region. The renderer therefore publishes them (`RenderState.RegionShifts`, fork PR 15), and the same three consumers undo them. They use the offsets of the frame that the layer shows. Its contents change on the main thread, where hit tests run, so neither the drawing of a frame nor its presentation decides. They add every region scroll that the terminal did since that frame was drawn.
    - A click lands on the row that is drawn under the pointer. This is also true for a click during the ease of a quarter of a second, or in the middle of momentum. A click on a row that the region scrolled out of resolves to the edge row of the region.
  - **The overscan of upstream leaves the cursor out of the rows that it reveals**. `cursor.viewport` is null there, and `renderer/cursor.zig` draws no cursor without it. The cursor of the prompt therefore vanished from the row that a scroll reveals at the bottom, until the fork added `cursor.captured`. The renderer and the style gate read it instead. Links still come back in viewport rows. We found both problems only when we diffed rendered frames against the previous build. The unit tests passed.
- **Snap to whole row** is fork patch 0011 (`.github/downstream/0011-smooth-scroll-rows.patch`). It is behind the fork key `smooth-scroll-rows`. This is a mode of `smooth-scroll`. `MactermConfig.Animations` writes it only together with `smooth-scroll` (`Preferences.snapScrollToRow`, default off). The toggle is indented under Smooth scrolling, and it is disabled without it.
  - Scrolling moves the viewport by whole rows, and each move slides into place. The region scrolls of `less` already animate in this way. The viewport therefore never rests between rows.
  - The input accumulates as it does without smooth scrolling. Macterm never draws its sub-row remainder.
  - Macterm draws each row that the viewport really moves from where it was (`Surface.rowScrollOffset` puts the distance in `Screen.viewport_pixel_offset`). The renderer decays the offset on the time constant of 45 ms of the region animation (`decayViewportScroll`, under the terminal lock on update wakes).
  - The motion is the own offset of the terminal. The hit test, the selection, the cursor and the IME point follow it with no copy.
  - When you scroll back, the content rows are drawn up. `resolveShift` therefore reveals as many rows below as the offset spans (`scroll_offset.w` tells the clip of the shaders).
  - At rest, the leftover height stays padding. The geometry gets no terminal height, so only whole rows show. A resize steps one row at a time, as it does in `less`.
  - It is a feature of the fork, because every wheel event reaches libghostty untouched (#393). We tried a settle in Swift after the gesture first. It missed smooth-wheel input with no phases (Logi Options+ posts precise deltas with no gesture phases).
  - `SurfaceScrollView` sends no sub-row offset for a scroller drag in this mode.
- **Animate splits** (`Preferences.animatedSplits`, default on) swaps the recursive `SplitTreeView` for `AnimatedSplitView`. It renders the tree of the tab **flat**.
  - `SplitLayout` (pure, tested) resolves every pane and divider to an absolute rect. One ZStack that is keyed by the pane ID lays them out. Any change of the tree is then frames that move on stable identities, and SwiftUI animates it. The recursive view cannot do this, because nesting a leaf again changes its structural identity.
  - `SplitRootView` is the switch. Both call sites (`WorkspaceView`, the quick terminal) go through it.
  - We verified each of these rules live:
    - **A platform view moves only by its frame**. `.scaleEffect` and the transitions `.scale` and `.move` leave an NSView where it is. A new pane therefore grows out of the seam of its split from a frame of zero length. It is locked to the edge of the sibling that shrinks.
    - **Nothing crosses another pane**. Backgrounds are transparent, so an overlap is text through text. An empty new pane is invisible anyway.
    - **A closing pane is a ghost**. `Pane.destroySurface` takes a snapshot of the last frame (`Pane.closingSnapshot`, only while the toggle is on) *with no background fill*. An opaque ghost flashed to full opacity in a translucent window. The snapshot is clipped to the strip that the sibling did not yet reclaim.
    - The direction is the **own outer edge** of the pane in the split. The pane at the right or bottom slides right or down. The pane at the left or top slides left or up.
    - **The code reads from the new layout what the strip closes onto. It never reads it from the old tree** (`SplitLayout.closingSeam`). When one sibling reclaims the strip, that is the own edge of the branch. But the rebalance of auto-tiling moves *both* neighbors of a pane in the middle. If the strip collapsed to the edge of the branch, it dragged the dead divider back across the pane above it.
    - **A divider that outlives its branch travels to that same seam** (`AnimatedSplitView.MergingDivider`). It does not blink out. The two dividers on each side of a pane that closed cover the same distance from opposite sides and merge. This is the close read backwards from a split. In a split, the new divider is born on the seam that it peels off.
    - **The dim of the split that is not focused is a value, not a branch** (`SplitLeafView.isSplitDimmed` drives an opacity, always mounted). A view that comes and goes cannot cross-fade with the slide. It also popped one shade darker at the instant that a pane arrived.
    - The animation is keyed to the structure plus the zoom plus `TerminalTab.animatedResizeGeneration`. It is never keyed to ratios. A divider drag and `pane resize-split` of the CLI therefore land at once. Resize Split Left, Right, Up and Down bump the generation together with their ratio change, so they slide.
    - Each animation of an arriving pane or a ghost starts from its own `onAppear`, in the same frame as the sibling. A deferral of one turn made the seam visibly out of sync.
  - Zoom keeps the tiles that are hidden mounted at opacity 0 (`GhosttyTerminalNSView.hiddenInLayout` makes their renderers sleep). It removes the dividers. Their grab bands are NSViews, and they would catch drags through the zoomed pane.
  - Every animation frame resizes the surfaces that move. This is the same path as a divider drag. Reduce Motion disables the animation.
  - **The curve is a spring, which we define by its settling time** (`SplitAnimation.curve`). SwiftUI drives a spring itself, frame by frame, so each frame reaches the surfaces as a resize. A timing curve (`easeOut`) is bridged to Core Animation for the frame of a representable. The view gets its size one time, the layer is stretched, and the program sees two SIGWINCHs for each split.
  - A spring that we named by its perceptual duration (`.smooth`) kept settling for about 250 ms after that duration, one pixel in each frame. Each frame was a pty resize and a full redraw.
  - libghostty applies those resizes behind its own coalesce timer (upstream: a fixed 25 ms, and fork patch 0010 tracks frames). The grid therefore steps at that cadence, not at the cadence of SwiftUI.
- **Smooth cursor** is fork patch 0008 (`.github/downstream/0008-smooth-cursor.patch`). It is behind the fork key `smooth-cursor`. `MactermConfig.Animations` writes it into the overrides (`Preferences.smoothCursor`, default off).
  - The renderer owns the motion (`CursorGlide` in `generic.zig` of the fork).
  - Macterm still adds the sprite of the focused cursor (block, bar or underline), at alpha 0. The uniforms of a custom shader then keep naming its cell.
  - Macterm eases the rect itself into the uniforms of the cell in every frame that it draws. The ease is 140 ms, ease-out cubic. It retargets in the middle of a glide from where the rect is drawn.
  - The **shader for the cell background fills the rect by exact box coverage**, under the text. The **text shader colors each glyph pixel as cursor text by that same coverage** (`cursor_glide_text`). This replaces the recolor of the whole cell by the vertex shader under `cursor_pos`. The code leaves `cursor_pos` unset.
  - This makes a glyph that the cursor is halfway across two-toned. It also lets the own background of a highlighted cell show through the part that is not covered. A custom shader could not do these two things. It sees one composited frame in which ghostty already painted the destination glyph in cursor-text color. It cannot tell a glyph from a cell background.
  - The rect is in grid pixels. It therefore rides a smooth scroll with the rows. It takes the shift of an animation of a region scroll that its cell is in.
  - The draws come from the display link of the vsync. The animation timer of 8 ms is skipped on macOS whenever a display link exists. `animationWake` keeps the display link running while the glide is in flight. It stops the display link when the glide lands. `smooth cursor landed after N frames` in the debug log is the measured frame rate.
  - A reshape of the grid, a change of font or a toggle of the key snaps the cursor to its cell.
  - Programs that paint their own cursor cell still move that paint by cells, under the terminal cursor that glides. Examples are the theme style `ui.cursor` of Helix and its secondary cursors.
  - The previous implementation was a custom shader that glided a block over the composited frame, plus an override `cursor-opacity = 0`. Both are gone.
- **Cursor trail** is fork patch 0009 (`.github/downstream/0009-cursor-trail.patch`). It is behind the fork key `cursor-trail`. `MactermConfig.Animations` writes it (`Preferences.cursorTrail`, default off).
  - It uses the same `CursorGlide` motion. The code tracks the glide whenever either key is on.
  - Under the trail, the streak (`CursorGlide.trail`) goes into the uniforms next to the rect. The streak is an axis-aligned box with the size of the drawn rect. It is swept from a tail to the head, where the cursor is drawn. The tail sets out halfway through the move. The streak fades as the move completes. A move of less than 1.5 cell heights leaves nothing, so typing does not leave a streak.
  - The background shader paints the streak in the cursor color under the text, beneath the own fill of the cursor.
  - With the trail alone, the sprite stays the cursor, and only the streak is drawn.
  - The trail replaced the last bundled custom shader. For this reason `AnimationShaders`, `Resources/shaders/` and the install of the encoding header are gone.
  - libghostty animates any loaded custom shader without a stop while the pane is focused. It wakes a draw every 8 ms. The display link never pauses. At an idle shell prompt, it renders the whole frame again and post-processes it at the refresh rate of the display. The cost of the trail was therefore permanent. The version in the renderer costs about 140 ms after a move, and nothing in any other case. Its head is the drawn rect of the glide, not the cell of the cursor.
  - Macterm ships no custom shader now. The own `custom-shader` lines of the user are untouched.

### Adaptive terminal background

`AdaptiveTerminalBackground` infers the background of a TUI from the BGRA8 IOSurface of libghostty. It fails closed if the format changes. It can also take OSC 11 directly.

- **Macterm presents a report over the inference. It never writes the report into the inference** (`AdaptiveTerminalChrome.reportedCandidate`). libghostty reports an OSC 111 reset as a change *to the configured color*. A report that reset the stabilizer left the stale sampled color as the fallback. The `:theme` of Helix then left a hole of tint over the bare shell after you quit, until the config reload of a new surface.
- The report carries the alpha at which the renderer paints cells (`reportedPaintAlpha`: the window opacity under `background-opacity-cells`, if not opaque). It is never a bare 1.
- The alpha floor derives from the window opacity (`minimumPaintedAlpha`). Painted cells arrive premultiplied at `background-opacity`.
- A color that is translucent gets no fill for the pane. The window tint is **cut out from under its whole pane**. Its margin is **filled again in its own color**. `TintCutout` does this, with a `TerminalPaintRegion` for each pane.
  - The paint, which Macterm walks along the edges by alpha through `paintedUnitBounds`, stays bare.
  - The `window-padding` around it, which nothing painted, gets the color of the pane at the window opacity, on a sibling layer. In a split, the window keeps the configured theme. When Macterm cut out only the paint, it framed every TUI in that theme.
- The tint therefore lives in a view that you can mask. It never lives in `NSWindow.backgroundColor` or `NSGlassEffectView.tintColor`. The tint does not depend on the key status. Colors are read in the color space of the renderer (`GhosttyColorSpace`).
- `AdaptiveTerminalInferenceGate` freezes the inference while `ghostty_surface_has_selection` is true. It protects a confirmed color from repaints that have no output heartbeat within 1.5 s. This is for adoption only, never for clearing.
- The winning color must also span 0.80 of the sampled grid **on each axis** (`minimumBackgroundExtent`). This keeps a slide or an image from tinting the window again.
- **A region follows the visibility of the pane, not its frame** (`AdaptiveTerminalChrome.paintRegion`). A pane that zoom hides keeps its frame, its color and its sampled paint at opacity 0. Its hole showed the bare material inside the zoomed pane. `hiddenInLayout` drops the region at once. It restores the region only after the split animation faded the pane back in (`layoutVisibilityDidChange`).
- The quick terminal is outside the tint of the whole window.

## Layout

- `Macterm/App/`
  - `PaletteHotkeys`: the chords of extensions, by palette id under `macterm.hotkey.palette.<id>`. The `.passthrough` and `.global` flags are beside them. A Carbon id for each process starts at `carbonIDBase`. It gives one answer to `MainAppResponder`, `PaletteResponder` and `isAppShortcut`. A row under Palettes in Keymaps has the key `palette:<id>`.
  - `HotkeyBinding`: an action or a palette. `GlobalHotkeys` registers it, and `KeybindPassthrough` gates it. The chord of a palette therefore gets Global and Pass to TUI in the same way as the chord of an action.
  - `AppState` (with `AppState+PinnedTabs`, `AppState+FirstRun`, `AppState+QuickTerminal` and `AppState+DesktopWidgets`).
  - `WindowState`.
  - `Preferences`.
  - `Hotkeys`, `KeyRouter`, `Responders` and `KeybindPassthrough`.
  - `AppCommand`, `AppCommandActions` and `AppCommandMenu`: the single source of truth for the actions that a user can invoke. The palette, the menus and Settings render from `AppCommand.allCases`.
  - `FocusRestoration`.
  - `Updater` (Sparkle).
  - `AppInfo`.
  - `FirstRunSeed`.
  - `Tutorial`.
  - `FinderServices` and `OpenFolder`.
  - `AppState+TextFiles`.
  - `DockMenu`.
  - `BellBadge` (with `AppState+BellBadge`).
  - `PasswordPromptMonitor`.
  - `BenchmarkControl`.
  - `ExceptionReporting`.
  - `EnvironmentSetup`.
  - `Notifications` and `NotificationHandler`.
  - `PollCadence`.
  - `RecencyStack`.
  - `TabIndexChord`.
- `Macterm/Views/`
  - `MainWindow`.
  - `Sidebar` (with `SidebarOverlay`, `SidebarPresentationState` and `SidebarFolderDrop`).
  - `SplitTreeView`, and `AnimatedSplitView` with `SplitLayout`.
  - `TerminalPane` and `TerminalSurface`.
  - `PaneDragDrop`.
  - `CommandPalette`.
  - `TabSwitcherOverlay` and `TabSwitcherToolbarItem`.
  - `QuickTerminal` (`NSPanel` and a Carbon global hotkey).
  - `DesktopWidgetWindows`.
  - `SurfaceIncubator`.
  - `QuitConfirmation`.
  - `NewRemoteProjectSheet`.
  - `ProjectColorMenu`.
  - `SearchBar`.
  - `Toast`.
  - `PasswordBubble`.
  - `PaletteScreenshot`. This is Capture Palette Screenshot. It takes the screen around the palette. `WindowState.paletteAnchor`, an invisible view under the palette, marks the place. `MactermExtension.screenshotRect` frames it. ScreenCaptureKit captures it. The glass of the palette shows what is behind it, and a render of a view cannot draw that. The capture needs Screen Recording, and it asks the first time. `PaletteResponder` answers its chord while the palette is up. If you run it in any other way, it opens the palette and captures the first screen.
  - `ToolbarMenu`: the right-click menu of the toolbar. It is a local mouse monitor, because AppKit consumes a right-click in the titlebar before `NSView.menu`.
  - `WindowAppearance`: opacity, blur, liquid glass, the private titlebar tree and the CGS blur SPI.
  - `Terminal/`: `GhosttyTerminalNSView` (surface, keyboard, mouse, IME), `SurfaceScrollView` (overlay scrollbar) with `ScrollAccumulator`, `PanePreview`, `SearchTickOverlay` and `TerminalCommandSubmission`.
- `Macterm/Ghostty/`: `GhosttyApp` (init, config, tick), `GhosttyCallbacks`, `GhosttyResources`, `ThemeResolver` (`light:X,dark:Y` splits, #38), `Theme` (all UI colors), `AdaptiveTerminalBackground` and `AdaptiveTerminalChrome`.
- `Macterm/Model/`: `SplitNode` and `Pane`, `Workspace` and `TerminalTab`, `Project`, `ProjectPath`, `ProjectColor`, `PinnedTabs`, `DesktopWidget`, `ForegroundSample`, `TerminalExecutionTracker`, `TerminalSearchState` and `AgentIcon`. It also has `PasswordPrompt` (entry identity, line capture, submission judge). It also has `FileLink` with `TextFileEditor` (links `path:line` that the user clicked, and the typed editor line).
- `Macterm/Persistence/`: `WorkspacePersistence` (snapshots, `WorkspaceStore`), `ProjectStore`, `FileStorage`, `ProjectFile` and `ProjectFileStore` (`~/.config/macterm/projects/`), `LayoutBuilder`, `LayoutSerializer` and `LayoutReconciler`, `LayoutFile` (only in memory), `PinnedLayoutStore`, `WidgetLayoutStore`, and `PasswordStore` (Keychain and `PasswordVault`).
- `Macterm/System/`
  - `ProcessInspector` (foreground pid → `runningCommand`, `runningShell` and `runningProcessName`).
  - `ZmxClient`, `ZmxForegroundResolver`.
  - `RemoteSpawn`, `RemoteForegroundResolver`, `RemoteReconnectPolicy`, `RemoteTerminfo`.
  - `SSHWrapper` (shared with the CLI target).
  - `ProcessLocale`, `FullDiskAccess`, `SecureInput`.
  - `NativeDesktopWidgets`: the frames of the system desktop widgets, from the window list.
  - `PasswordAuthenticator`.
  - `ObjCExceptionCatcher`: a trampoline with `@try` and `@catch`. AppKit raises ObjC exceptions that Swift cannot catch.
  - `GitWorktrees`: the Worktrees menu of the sidebar. It reads the worktrees of a project from the metadata files of git. It never runs git. A Mac without the Command Line Tools shows an install dialog for `/usr/bin/git`.
- `Macterm/Config/`: `MactermConfig` (with `Animations`), `GhosttyConfigSource`, `GhosttyConfigText`, `ShellIntegrationFeatures`, `GhosttyColorSpace`, `MouseScrollMultiplier` and `MacosHidden`.
- `Macterm/Settings/`
  - `SettingsView`: the panes and `PinnedSidebar`. Keymaps is one grouped block. Passthrough Programs is above it. The search is at its top. There is one row for the column headers. A small gray label divides each `AppCommand.Category`.
  - `ProjectsSettings`, `WidgetsSettings`.
  - `ExtensionsSettings` (Settings → Extensions).
    - It is one grid of `ExtensionGalleryItem` cards that you can search by name. It has the installed extensions and the extensions of `PaletteRegistry` that are not installed yet. Each card shows the own name and description of the extension.
    - Each card has one button. **Install** installs at once, with no sheet. A book button next to it opens the folder of the extension on GitHub (`PaletteRegistry.folderURL`). **Installed** moves the extension to the Trash (`CustomPaletteStore.uninstall`).
    - Installed extensions come first, and each group is in order of name or of search rank. A menu next to the search field filters the grid to **All**, **Installed** or **Not Installed** (`ExtensionGalleryItem.Filter`).
    - The built-in screens are not extensions, and they have no card. There is no switch for on and off. To remove an extension, uninstall it.
  - `PasswordsSettings`.
- `Macterm/Control/`: `ControlProtocol` (shared with the CLI), `ControlSocketServer`, `ControlHandler`, and `AgentSkills/` (the text of `macterm skills`, shared with the CLI).
- `Macterm/Intents/`: the surface of App Intents. `MactermIntentHost` and `IntentTargets` (`IntentHost.swift`), `IntentPermission`, `MactermIntentError`, `Entities`, `ProjectIntents`, `TabIntents`, `PaneIntents`, `CommandIntents` and `MactermShortcuts` (`AppShortcutsProvider`).
- `Macterm/Palette/`: `PaletteEngine` with `CommandSource`, `ProjectSource` and `DirectorySource`.
  - **`Custom/`** has extensions. Users and the docs use the name "extension" for what the code calls custom palettes.
    - `CustomPaletteFile` is the YAML model. It is validated into `CustomPalette`. A palette has named nodes. Each node has written `items:`, a `list:` or both (items first, and shown at once). Every row has an `enter:` or an `action:`, and an optional `alt:` for ⌥↩. The `alt:` is wired to `PaletteItem.alt`.
    - `CustomPaletteRows` turns the output of a command (JSON, NDJSON or plain lines) into rows by dotted paths. It is pure.
    - `CustomPaletteStore` reads the palettes of the installed extensions (`~/.config/macterm/extensions/<id>/palettes/*.yaml`) again at every open of the palette, by mtime. Palettes come only from extensions: Macterm does not read `~/.config/macterm/palettes/`, which earlier versions read, and does not convert its files. The `authors:` of an extension are optional, so a user can write an extension for themselves. `CustomPaletteFileTests` requires them for each extension in the repository. A file that fails keeps its error. Its row stays normal, with a warning glyph before the chevron (`PaletteItem.warning`). When you enter it, the screen shows the error as its `failure`. ⌘R reads the file again.
    - `CustomPaletteRunner` has a timeout of 30 s. Exports and `MACTERM_PROJECT_DIR` and `MACTERM_PROJECT_NAME` go in the environment. Macterm NEVER substitutes selections into the text of a command. It probes `requires:` only after a listing fails, to name the program that is missing.
    - `CustomPaletteLaunch` (shared with the CLI).
    - `PaletteRegistry` holds the extensions that anyone can install.
      - They are in `extensions/<id>/` at the root of the repo. Each folder has `extension.yaml`, a `README.md`, and its capabilities. `extension.yaml` has `name`, `description`, the optional `icon`, and `authors:` as GitHub usernames (`ExtensionManifest`, schema `assets/extension.schema.json`). For now, the capabilities are palettes: any number of `palettes/*.yaml`, each with its own name and description.
      - `CustomPaletteFileTests` holds each palette to the validator plus a description and `requires:`. It holds each extension to text only, and to at most 6 files `screenshots/*.png` of exactly `MactermExtension.screenshotPixelSize` (1600×1000).
      - Macterm lists them with one request to the Git Trees API at `main` for every build. Extensions have no version that is tied to the app. `MACTERM_PALETTE_REF` points a debug build at another branch.
      - Macterm downloads their text from `raw.githubusercontent.com`, which is outside the hourly limit of the API. What Install writes is therefore exactly what Macterm validated.
      - Each extension runs through the validator of this build. An extension that uses something newer says so, and you cannot install it.
      - Macterm reads them every time that Settings → Extensions opens. It caches them for one hour (a failure is not cached). There is no Refresh button. It never reads them in the background.
      - Install stages the whole folder next to `~/.config/macterm/extensions/<id>/`, and renames it into place. It keeps executables executable. It never replaces a palette with that id.
      - `ExtensionGalleryItem` merges the installed and the available extensions into the grid of Settings.
    - `CustomPaletteStore.extensions` lists an installed extension (`InstalledExtension`: manifest, palette ids, the first problem). Each of its palettes is an entry like the entry of a file. The id is `<extension>/<stem>` (`MactermExtension.paletteID`), so it never meets the id of a file or of another extension. Its commands get its folder as `MACTERM_EXTENSION_DIR`, a reserved export.
    - `CustomPaletteAvailability` and `CustomPaletteConditions` implement `when:`. This is a check command on the palette or on a menu item. It runs in the background each time that the row is shown. Distinct commands run one time. The limit is 10 s. A check that fails mutes the row with its reason. The palette panel holds the verdicts of the root list for each window and for each open, never longer. The own check of a palette gates its root screen, so its keybind says why and does not list.
    - **Commands follow the model of mise, not the model of the shell of the user**. They are POSIX `sh -o errexit -c`, or the interpreter that a first-line `#!` names (written to a temp file and run with exec). A palette therefore means the same thing for everyone who gets it.
      - They still start from the login shell (`-l -c`), because the PATH of the user lives only there. They go through one fixed line, `CustomPaletteScript.trampoline`. It parses in the same way in nu, fish, zsh and bash. The command is in `MACTERM_PALETTE_COMMAND`.
      - **Macterm never types a local `run:` action**. The command rides in the env of the new pane (first surface build only). The surface puts `macterm palette exec <shell> <flags> --` after the wrapper of zmx, in front of the launch that ghostty resolved.
      - The runner runs the command through the shell of the user as `-i -l -c`. It is interactive, so exports that only `.zshrc` has count. It takes the terminal back with `tcsetpgrp`. zsh and bash leave it in their own process group. The login shell that we ran with exec then hung. Then it runs the launch with exec, untouched. Shell integration, `login(1)` and history are exactly the same as in a plain pane.
      - Macterm still types the `run:` of a remote project, because ssh carries no env.
    - The grammar for users is in `website/docs/pages/35-extensions.md`. A complete Kubernetes palette is in the cookbook. `CustomPaletteFileTests` reads every palette file with a caption in the docs back through the validator. An example that stops reading therefore fails a test.
  - **`Scopes/`**
    - `PaletteScope` holds the alternate screens of the palette: a placeholder and its own sections. It also has `loading`, `failure`, `retry`, and a lifecycle `activate` and `deactivate`, for a screen whose listing takes time.
      - It is a class for each screen. Its `PaletteFrame` keeps it for as long as the frame is on `WindowState.paletteStack`.
      - Macterm draws a row of pills that float above the panel, outside its glass (`PaletteBreadcrumb`). The row is always laid out, and it is empty on the root. The first pill is therefore an insertion like every other pill. It blurs in where it lands, and it does not ride the own insertion of the row. The anchor of the panel already allows for the row, so the panel never moves or grows. Macterm empties it at every close.
      - The panel appears and vanishes in one frame. A view inside the window cannot get the fade at window level. It cannot get the blur of the backdrop either. The panel of the quick terminal gets both for free. A transition that we drew in its place read as a slower fade.
      - The breadcrumb and each pill come and go through `PaletteMotion`. This is `blurReplace` of SwiftUI on an ease-out of 120 ms. Reduce Motion lands them in one frame.
      - The pill of a frame is `PaletteScopeID.pill`, unless the row that opened it names a pill.
      - An `AppCommand` opens a screen through `paletteScope`. This makes its palette row enter the screen in place, with the glyph of the pill and a chevron.
      - Each such command can have a keybind and toggles its screen. `PaletteResponder` answers those chords while the palette is up, when the app responder stands aside.
    - `PasswordPaletteScope`.
    - `WorktreesPaletteScope`: the linked worktrees of the active project from `GitWorktrees.list`, without the main one. It shows the branch over the path that is relative to the root. A new tab opens in one.
    - `FilesPaletteScope`: the files and directories of the active local project.
      - `FileIndex.scan` walks a level at a time, so that the cap of 20k cuts the deepest level, never the top. It skips hidden directories and the directories for dependencies and builds. It lists a linked directory, and it never enters it.
      - Macterm indexes one time on `activate`, off the main actor. The search is by name or by part of a path. It shows 50 rows.
      - Enter opens a split next to the focused pane (a tab in that directory when the project has none). A directory opens as a shell there. A file opens in the terminal editor.
      - `PaletteItem.alt` of the row opens it with the default app, with ⌥↩ or ⌥-click. The subtitle is swapped while Option is down, to show the alt action. There are no ⌥↩ caps, because the held key implies them. Macterm decides from the event of Return or the click. It never decides from the flag that it tracks.
      - `PaletteEventMonitor` watches Option and Backspace with local monitors. The field editor takes Backspace before `onKeyPress` sees it. A Backspace pops a screen only on a fresh press that does not repeat, at an empty field.
    - `CustomPaletteScope`: one `CustomPaletteTarget` (palette, node, accumulated exports, pill) for each frame. A listing lists one time on `activate` and filters the rows that it cached. `run` actions land in a new tab or split with the exports in the env of the pane. The `copy:` and `open:` text of a written item is literal. In a listing, it resolves for each row.
    - Built-in scopes stay in Swift. Their listings are reads in process, and a shell command could only approximate them.
    - Every scope is an `AppCommand` in `Category.palettes`. It is declared first in `allCases`. Palettes is therefore the first command section of the default state of the palette (after Recent projects), and the first section of Keymaps. `toggleCommandPalette` sits with them there. `PaletteScopeTests` pins that each scope has a command with the same title that you can bind.
    - Worktrees is not available outside the top of a repository (`GitWorktrees.isRepository`) and for a remote project. It is disabled in the menu and muted in the palette. Its chord shows a toast that says why, and it does not reach the terminal. This is `AppCommand.unavailableNotice`, the hook for any command whose unavailability is news.
    - Matching is the matching of `Macterm/Search/`.
- `Macterm/Search/`: `SearchText` (prepared, folded text), `SearchScoring` (the scoring of fzf and the positions of highlights), and `SearchIndex` with `SearchSession` and `Search` (the engine, see Search).
- `CLI/`: the `macterm` binary. `MactermCommand` (the ArgumentParser tree), `ControlClient`, `Output`, `SSHCommand`, `TutorCommand`, `SkillsCommand`, `WidgetCommand`, and `PaletteCommand` (`palette list`, and the hidden runner `palette exec`).
- `scripts/`: `setup.sh`, `build.sh`, `_lib.sh` (version mapping, update channel), `publish-appcast.sh` and `benchmark.py` with `_harness.py` (`MactermHarness`, shared with e2e). It also has `e2e.sh`, `ghosttykit-api-diff.sh`, `ghostty-shim.sh` and `record-demos/` (the demo clips of the website).
- `e2e/` is the pytest suite. `website/` has the docs site (`docs/pages/*.md`) and the Caddyfile that serves the update feed.

## Tests

### Unit (`MactermTests/`)

There is one `XxxTests.swift` for each production type. It mirrors the source path. The tests use `@testable import Macterm` and `@MainActor`.

- Swift Testing suites run in parallel. Anything that touches shared state (preferences, stores) is injected. Tests that need `AppState` or `WorkspaceStore` inject a file in a temp directory.
- Helpers are in `Support/`: the DSL `TreeBuilder` (`H(pane("a"), V(pane("b"), pane("c")))`), `TreeRenderer` and `LayoutFixture`.
- The coverage targets the model, persistence, palette and hotkey logic, and pure helpers. Nothing unit-tests SwiftUI views and the bindings of libghostty.
- A wait that polls for a condition must sleep. Do not use `Task.yield()` in a loop with a fixed count.

### End-to-end (`e2e/`)

The suite starts the real Debug app in a hermetic way through `MactermHarness`. It uses a throwaway `$HOME`, `MACTERM_BENCHMARK_DATA_DIR` and `ZMX_DIR`. The socket directory of zmx is per user. Without the override, a hermetic instance would share sessions with the real Macterm of the developer. The suite asserts through the CLI (`pane dump` and others read the live state of libghostty).

Conventions:

- There is one app instance for each session. Keep it the **active app** before every test (`_active_app` in `conftest.py`: `lsappinfo front`, taken again through the `activate` hook of the bench). That hook forces activation, because the cooperative request is refused once another app holds the front).
  - The password monitor watches only the focused pane of the key window. It runs no timer while the app is inactive.
  - A test that starts an instance of its own (`open -n` fronts it) leaves the shared instance behind Finder when it kills its own. This is what timed out both tests of `test_passwords.py` on CI.
- Use the `fresh_tab` fixture. Never change the initial pane.
- Every wait is a poll with a deadline.
- Type commands as `/bin/sh -c "…"` with no single quotes (the login shell of CI is bash 3.2).
- Target panes explicitly.
- Prove that something ran with markers that you assemble at run time (`printf started-%s <nonce>`). No signal for idle or running is independent of the environment.
- CI runs it as `Test / End-to-end`. A failure uploads `e2e-diagnostics`.

### Benchmarks

`mise run bench` and `.github/workflows/benchmark.yml` measure the delta of CPU time, RSS and wakeups across `focused`, `workload-focused` and `workload-unfocused`. Darwin notifications drive them (`BenchmarkControl`, `MACTERM_BENCHMARK=1`, which also skips the notification prompt, Sparkle and the first-run seed).

- PR runs compare against a pooled median of the last 10 runs on main.
- A cell gets a flag only beyond ±25% and a noise floor.
- The label `benchmark:regression` or `benchmark:improvement` needs at least 2 corroborating cells, and one of them under a workload state (`should_label`).
- The writes of labels and comments are in `benchmark-report.yml`. The token of a PR from a fork is read-only.

### Demo recordings

`scripts/record-demos/record-demos.sh` records the eleven clips that the landing page plays. It drives the **installed** app with synthetic keystrokes. For demos 8 and 9, it also drives the pointer. Whatever runs it therefore needs Accessibility and Screen Recording. It also needs ffmpeg, and podman for demos 5 and 10 (it starts the podman machine itself).

Masters land in `$MACTERM_DEMOS_OUT` (default `~/Desktop/macterm-demos`). Only `record-demos.sh web` writes into the repo. It encodes the finished clips again to 1400×792 with CRF 26, and a poster of the first frame, in `assets/demo/`. `website/public/assets` serves them as `/assets/demo/…`.

The script has these rules. We learned each one with the real app:

- **You place the window. The script refuses to record until the rect matches** (1600×870 at 1330,411, captured with a margin of 40 pt). This place keeps the frame clear of two things. One is the desktop widgets in the columns at the top left. The other is the desktop icons in the corner at the top right. Every clip then lines up. `quick-prefs` places the panel of the quick terminal at the same frame. The frame of the panel is computed again from the prefs at each show, so a move with AX never stays. If you move the window, you must run `quick-prefs` again and start the app again.
- **Wait for a shell prompt. Never wait for a delay**. Every command that the script types polls `pane dump` until the pane shows a prompt. A remote pane starts blank, because the shell printed its prompt before zmx had a client. The wait therefore nudges it with Ctrl-L until a prompt appears. Never nudge a pane that is at a password prompt. The Ctrl-L becomes part of the password.
- **The tab switcher needs a HELD modifier**. The overlay lives exactly as long as the modifier of the recent-tab chord is down (`commitTabCycle` fires on the flags-changed event when the modifier drops). System Events cannot hold a modifier across statements. `hold.js` posts the key events at the level of CGEvent from osascript. The script reads the chord from `macterm.hotkey.recent_tab` at run time. It does not assume it.
- **The script records the quick terminal with the window parked off screen, not closed**. The panel does not activate the app. With no window at all, Macterm cannot be the frontmost app. Every keystroke that is meant for the panel then lands in whatever app is in front. `qt_ready` refuses to type unless the panel is up *and* Macterm is frontmost. Finder renames files with stray keystrokes.
- **`guard_repo` restores only the files that a demo opens** (`AGENTS.md`), in the checkout of the macterm *project* (`shown_repo`). This is the checkout in which its panes open files. It does not have to be the checkout that the script runs from. Helix saves automatically on loss of focus, so a keystroke that lands in an editor pane is written to disk. A blanket list reverts unrelated work as a side effect.
- **Cleanup matches by path, never by name**. Demo 3 opens `~/dev/macterm/website/docs`. It removes only the project and the layout file that point there. If it removed "the project with the name website", it nearly took a project of the developer.
- **Programs that interrupt themselves get an instruction not to**. opencode (demos 2 and 6) runs with `OPENCODE_DISABLE_AUTOUPDATE=1`. Without it, an update dialog lands over the TUI in the middle of a take.
- **Demos 5 and 10 build their own host.**
  - It is a podman container with sshd, vim and zmx (compiled from source, because the fork ships only binaries for macOS). It is published on 127.0.0.1:2222. A marked `Host demo-box` block is put at the start of `~/.ssh/config` (`HostName localhost`, which is what the password prompt of ssh names).
  - It takes a key and a password. The block decides which one the pane uses. The own checks of the recorder always force the key (`rssh`).
  - It refuses to record unless the alias answers with the own marker of the image. A collision of names can therefore never point a recording at a real machine. The teardown removes the project, the container and the config block.
- **Desktop demos check that the frame is empty** (`region_clear`, over the window list of `windows.swift`). They record the cursor (`CAPTURE_CURSOR=1`, moved by `mouse.js` on an eased arc, because a pointer that jumps looks fake). An EXIT trap restores the state of Finder that they change, however the run ends.
- **Demo 8 drops a dummy `~/Desktop/starfield` on the Dock tile.**
  - `dockdrop` aims for the x of the tile while the Dock that hides automatically is still below the screen. It wiggles on the edge until the Dock slides up. Then it reads the tile again under magnification.
  - A desktop with Stacks or a sort order ignores the position of the folder. The take therefore switches both off in `DesktopViewSettings` of Finder. Finder restarts to read them.
- **Demo 9 records the widgets of the desktop as they are**. Nothing is created or moved for the take. The frame is the full height below the menu bar, with the desktop icons hidden (`CreateDesktop`). The btop widget is reset to a shell, edited from its right-click menu, and dragged out and back. btop needs at least 80×24 cells. At a font of 16 pt, a widget that runs it needs 4×4 grid cells or more.
- **Demo 11 writes its own extension into the real extensions folder.**
  - The installed app reads `~/.config/macterm/extensions/` again at every open of the palette. There is no throwaway config to point it at.
  - The take writes the extension `macterm-demo-git`, with a marker in the first line of its `extension.yaml`. It refuses to touch a folder with that name that has no marker. It refuses to record next to another palette with the name Git (when you type `git`, the selection must land on its row). The EXIT trap removes the folder only when it carries the marker.
  - Its commands are POSIX sh, like the commands of every palette, whatever the login shell is. The file is therefore written one time (its listing needs jq).
  - The script first runs the listing of the commits one time, off camera. It runs it in the way that the palette runs it: through the login shell, into `sh`.
  - The palette has no CLI view, so its steps take beats. The script waits for the Diff split through `pane dump`.
- **Demo 10 is `ssh demo-box` from a local shell.**
  - The script types the password with `pane key`. `pane run` pastes, and ssh reads the markers for a bracketed paste as password.
  - The ssh-terminfo wrapper of Macterm would open a second password prompt, off screen. The recorder therefore installs the entry over the key, and it lists the host in `~/Library/Caches/macterm/ssh-terminfo` for the take.
  - Autofill wants Touch ID one time for each unlock. `pw_rehearse` spends it off camera on the prompt of a local script. Someone must be at the keyboard.
  - Macterm keeps its list of saved passwords in memory. A retake therefore first opens Settings → Password Manager (`vault_reload`), which reads the keychain again. The script removes the keychain entries of the demo afterwards.

## Releasing

Macterm updates itself with Sparkle. `SUFeedURL` is `https://macterm.thdxg.dev/appcast.xml`. `website/Caddyfile` serves it straight from the `gh-pages` branch, which is a store and not a site. A build that a pushed tag starts releases through `release.yml`.

Secrets:

- `SPARKLE_ED_PUBLIC_KEY` and `SPARKLE_ED_PRIVATE_KEY`.
- `HOMEBREW_TAP_PAT`.
- `MACTERM_SIGNING_CERT_P12` and `MACTERM_SIGNING_CERT_P12_PASSWORD`. This is a stable self-signed certificate. It keeps TCC grants across updates. **Back up the private key and the certificate**. If you lose either one, users are stranded.

The release notes come from the generator of GitHub (`.github/release.yml`). A person chooses the version number. The `/release` skill walks through the ceremony. The recipe for the certificate is in the history of this file.

- **There are three Sparkle channels and one feed**. A prerelease item carries `<sparkle:channel>beta|tip</sparkle:channel>`. Settings → Updates → Channel opts in (`Preferences.updateChannel`, the raw values are the wire names). A channel on an item that is not a prerelease is a hard error in `publish-appcast.sh`. Homebrew stays stable-only.
- **Read the prerelease flag live** (the job `flag`, through `gh release view`). Never read it from `github.event.release.prerelease`. The payload is frozen at dispatch, and an edit does not fire the event again. Job outputs are strings. Compare with `== 'false'`.
- **Version ordering** (`sparkle_comparison_version` in `_lib.sh`):
  - `0.9.0-beta.1` becomes `0.9.0.1`.
  - Stable `1.8.0` becomes `1.8.0.9999`.
  - Tip `1.24.2-tip.7` becomes `1.24.2.9999.7`.
  - `build.sh` and `publish-appcast.sh` must both use it.
  - `macterm_tip_version` filters tags to `^v[0-9]+\.[0-9]+\.[0-9]+$`, because the rolling `tip` tag breaks `git describe`.
- **Tip channel** (`release-tip.yml`).
  - Every commit on main for which CI *passed* (Test success and Checks polled) publishes to ONE permanent prerelease that Macterm edits in place.
  - The rolling `tip` tag moves **last**, as the commit point.
  - The build job is in one concurrency group with `cancel-in-progress: true`. A newer commit that passed the gate replaces an older build. The setting is at job level, so that a commit that is red, or that only changes docs, cannot cancel a good build. The gate skips a commit when a newer commit already passed Test and Checks, because Test runs finish out of order.
  - There is one tip item in the appcast. Macterm keeps the newest 3 DMGs.
  - The check for staleness asks if the `tip` tag is an ancestor of the built commit. It never compares against HEAD of main.
  - **Macterm never builds a version again that is already in the appcast**. A run whose tag push failed has shipped everything else. A re-run for the same commit would `--clobber` the DMG with new bytes, while `publish-appcast.sh` keeps the old signature for the equal version. The build job therefore first reads `appcast.xml` from the gh-pages branch. If the version is there, it only moves the tag.
  - `build.sh` bakes `MactermUpdateChannel` into `Info.plist`. A tip build that you install by hand therefore uses the tip channel by default. Beta stamps `stable`.
- `release.yml` skips itself for `ref_name == 'tip'`. Keep GitHub Pages enabled on `gh-pages` until the installs that are pinned to the old feed at `thdxg.github.io` have moved.

## Conventions

### Writing style

- **Write all text that you generate in ASD-STE100 style** (Simplified Technical English). This includes documentation, the website, README and CONTRIBUTING, Settings text, CLI output, error messages, code comments, commit messages and PR descriptions.
- Use the `asd-ste100` skill (https://github.com/danyuchn/asd-ste100-skill, MIT, kept in `.claude/skills/asd-ste100/`). Run its linter on the Markdown that you write: `python3 .claude/skills/asd-ste100/scripts/ste-lint.py <file>`.
- Use **Strict** mode for procedures, error messages, CLI output, Settings captions and agent skills. Use **STE-flavored** mode for README, docs prose and PR text.
- Follow `WRITING.md` for Macterm terms and the words to use. It is the project glossary.
- The skill has no copy of the official dictionary of ASD. It checks sentence structure, not approved words. Do not claim that text complies with the dictionary.
- Keep every fact, condition and hedge. Do not change a product term, a command, a key name, a file path or a code identifier to make a sentence simpler.

### Code style

- SwiftFormat and SwiftLint are enforced. Run `mise run format`, `lint` and `test` before you commit. swiftformat owns trailing commas. Never write `static weak var` (the two tools fight).
- Use `@MainActor @Observable` on all state classes. Do not use `@Published` or `ObservableObject`. Inject through `@Environment(AppState.self)`.
- Use `os.Logger` only, with one `private let logger = Logger(subsystem: appBundleID, category: "TypeName")` for each file. **Every interpolation is `.public`**. View the logs with `mise run logs`.

### Commits and PRs

- **Never add a `Co-Authored-By: Claude` trailer or any AI sign-off.**
- Subject lines say why. Split independent changes into separate commits.
- **PRs merge by squash only**. The PR title is the squash subject. If there is a conflict, merge `main` into the branch. Never rebase.
- Edit `AGENTS.md`. `CLAUDE.md` is a symlink to it.

### UI principles

- **Use native SwiftUI and AppKit components only**. Accept a native limitation. Do not mimic the behavior.
- All colors come from `MactermTheme`. Fixed system colors are allowed only for identity labels (`ProjectColor`, `AgentIcon.brandColor`).
- Put APIs that exist only on Tahoe behind `#available(macOS 26.0, *)`. For controls, also use `WindowAppearance.glassSupported`.
- Settings text: section headers are Title Case. Controls are in sentence case. Buttons are Title Case. Descriptions use `.settingsCaption()`. `AppCommand` titles are Title Case.
- **Controls on a row that a hover reveals change values, not the structure of the view. Never use `.onHover`.**
  - The new-tab button of `SidebarProjectHeader` is one `isRevealed` Bool. It drives padding, opacity and hit testing. An `if/else` in the label of a `List` row tears the row down and corrupts the reuse of `NSTableView`.
  - Hover comes from an `NSTrackingArea` (`RowHoverTracker`, `.activeInActiveApp`). We retired `.onHover` three times, because of lag and exits that leaked.
- With stacked `.dropDestination`s, only the first one that you apply wins.
- The closure of `.contextMenu(forSelectionType:)` in the sidebar runs one time for each open of the menu. It never runs on a redraw of a row (we measured it). A cheap read such as `GitWorktrees.list` therefore belongs there. Inside it, `.disabled` on a `Menu` is dropped. The item then renders enabled over an empty submenu. A disabled submenu must therefore be a disabled `Button` (`SidebarContent.worktreesMenu`).
- **Anything that takes mouse input over a pane needs an AppKit view**. `GhosttyTerminalNSView` wins the hit test. SwiftUI gestures over a pane therefore never see the press. `PaneDragSource` and `ResizeDragBand` are `NSViewRepresentable`s. They forward what they do not own to `viewBeneath`. `NSHostingView` swallows hit tests even with `allowsHitTesting(false)`. Override `hitTest`.

### Terminal surface rules

- Never tear down the NSView from a SwiftUI path.
- `pane.destroySurface()` kills the shell. Call it only when a pane is closed for good, or for a remote reconnect, which never kills the session.
- `createSurface()` needs a frame that is not zero, and a window. `TerminalSurface` waits until it is attached. `Pane.command`, `shell` and `env` map to `initial_input`, `command` and `env_vars` of libghostty. Macterm passes them on the first build only.
- The `closeSurface` callback is asynchronous. Guard against a double close.
- The handoff of the first responder goes through `FocusRestoration`. A bare `makeFirstResponder` races with the attachment of the window.
- Any encoded key counts as typing for libghostty (it clears the selection and scrolls to the bottom). Do not send control sequences on focus.
- **Every resize of a surface goes through `GhosttyTerminalNSView.applySurfaceSize`, gated by `SurfaceSizeGate`**. A grid under 8×2 cells is refused, and the surface keeps its last size. libghostty reflows the scrollback into any grid that you give it. A grid with two columns shreds every line, and it leaves the content above the viewport when the pane grows back. Such a grid can come from the first frame of a split animation. It can come from a window that shrinks to the width of the sidebar. It can also come from a container that collapses in the middle of a tab switch. Ghostty.app never meets this, because its window cannot get that small.

### Persistence

- Workspaces are in `~/Library/Application Support/<display name>/workspaces_v3.json` (schema v6, written as v7 only while desktop widgets exist). Projects are in `projects.json`. The wrapper configs are next to them. Debug builds use `Macterm Debug/`, and the Debug bundle is `Macterm Debug.app` (`PRODUCT_MODULE_NAME` stays `Macterm`). Write the space wherever you name the bundle by path.
- `Pane` IDs are new at every restore. The session identity (`sessionID` and `sessionName`, stored exactly as given) is what connects a pane to its session again.
  - Only an explicit Apply Layout applies a declared layout (palette, menu, Settings row, `layout apply`). When you select a project or start Macterm again, Macterm never reads it. The snapshot restores, and a project without a snapshot gets the default workspace.
- **A directory is not an identity**. `ProjectStore.create` always appends a new project. `findOrCreate` exists only for callers that must be idempotent (the benchmark).
- Project declarations are YAML in `~/.config/macterm/projects/`. All build flavors share them. They look at the `$HOME` env first, through `ProjectPath.currentHome`.
  - `name:` is for display only. `path:` is the identity (scp-style, with `~` when Macterm writes it). `tabs:` is optional.
  - The schema is `assets/project.schema.json`. Keep them in sync.
  - Only an explicit Save Layout and the editor of the user write a file. Only Settings → Projects → Layouts → Remove deletes it.
  - Matching is by the canonical `path:`. The slug of the name of the project breaks a tie when one directory backs several projects (`ProjectSlug.owns`). Macterm surfaces duplicates. It never deletes them.
- `save` records `run:` as the live foreground command (`ProcessInspector.runningCommand`, for a remote project through the probe cache). It records `shell:` only for a shell that is not the default. `apply` (`LayoutReconciler`) matches by the same `(run, cwd)`. Files that do not parse surface `LayoutFileError`. An empty `tabs:` is a bare declaration.
- v1.22.0 removed the `.macterm/layout.yaml` in the repo. `LayoutFile` has no form on disk. Do not add helpers to load or serialize it.
- **The tab of the quick terminal persists too** (`WorkspacesFile.quickTerminal`, an optional section with deliberately no change of the schema version, see its doc comment).
  - `AppState` adopts `QuickTerminalService.shared.splitState` one time (`adoptQuickTerminal`, which you can inject at init for tests). It takes a snapshot of it in every `saveWorkspaces`. It hands the tab back in `restoreSelection` before the sweep for orphans. It counts the sessions of the tab as claims for the reaper. The panes connect only when the panel is shown for the first time, so until then they have zero clients.
  - `QuickTerminalSplitState` reports its own splits and closes through `onStructureChange`, because it owns no `AppState`. Macterm refuses a restore after the panel was shown in this run.
  - Results: a quit kills nothing and confirms nothing while zmx is bundled. The confirmation returns, with the quick terminal included, only when zmx is not available. A close of a pane in the panel is still the one permanent kill.
- Settings → Projects duplicates the alerts for layout, unload and remove. Keep them gated on `AppState.DialogHost`, so that a confirmation that the palette raises does not also open Settings.

### Adding a new feature

**A feature request starts with the question "does ghostty already do this?" The answer goes to the user before you write any code**. The config surface of libghostty is large. An implementation in Macterm of something that a ghostty key already expresses is a second answer. It disagrees with the first, and the user must find it. #393 deleted the scroll-speed slider and the whole wheel path of Macterm after someone tried `mouse-scroll-multiplier`. It also deleted two Settings controls that `tab-inherit-working-directory` and `macos-shortcuts` had answered all along. Read the config reference of ghostty and `ghostty.h` first. Then choose one of these:

- **A ghostty key covers it**. Read the key live from the loaded config (see the config pipeline) and add **no Settings UI**. Where the default of Macterm must be different from the default of ghostty, that departure is a line in `MactermConfig.defaultsBody`. It is never a fallback in `Preferences`. Naming the key can be the whole answer. Say so, and do not build.
- **Ghostty can express it as a custom shader or a fork patch**. Prefer that to a reimplementation in Swift. Land it in Settings → Animations first, off by default.
- **It is a concept of Macterm itself** (projects, tabs for each project, the sidebar, layouts, windows, the CLI, sessions). Build it here and follow *Adding a new setting*.

### Extensions are a compatibility promise

Every build reads the extensions of the repository on `main`, and anyone can have installed any of them. **An app update must therefore never break an extension that worked.**

- The extension format only grows. It includes `extension.yaml` (`ExtensionManifest`), palette files (`CustomPaletteFile`, `assets/palette.schema.json`), the environment that their commands get (`MACTERM_EXTENSION_DIR`, `MACTERM_PROJECT_*`, exports) and how commands run. Add keys and capabilities. Never remove one, never rename one, and never change what an existing one means.
- A key that a build does not know is an error *in that build* (`no such key`). This is how an extension that uses something newer reads as "needs a newer Macterm", and not as something that half works in silence.
- `CustomPaletteFileTests` reads every extension in the repo on every PR. A change that breaks one fails CI.

### Adding a new action

1. Add an `AppCommand` case (a title in Title Case, a category, and a linked `HotkeyAction` if you can rebind it). The palette, the menus and Settings use it.
2. If you can bind it, add the `HotkeyAction` to `Hotkeys.swift` with its default, **and the matching `MactermKeybind` case and label**. The picker of App Intents repeats them, and `MactermIntentsTests` fails until they match.
3. Handle it in the right `KeyResponder` in `Responders.swift`.
4. Add a `HotkeysTests` case for new behavior of parsing or display.

### Adding a new setting

Macterm-side settings go through `Preferences`. Settings that have the shape of ghostty (theme, font, palette) belong in the ghostty config of the user. Do not add UI for them.

1. Add a `Preferences` property with a `didSet` that writes UserDefaults.
2. Only if libghostty must be forced: add `notifyConfigChanged()` in `didSet` and a line in `MactermConfig.regenerate()`.
3. Add UI to the matching pane in `Macterm/Settings/`. A new pane also needs a `SettingsPane` case and a line in `SettingsView.detail`.

### Windows and sidebars, AppKit reach-throughs

- **Settings window**. `PinnedSidebar` locks the sidebar (it sets min and max thickness of the `NSSplitViewItem` to the same value, and `canCollapse = false`). A `DividerShield` over the divider also locks it. SwiftUI resets the column metrics on events that have no hook, so both layers are load-bearing. If you replace the delegate of the split view, the app crashes. The empty `NSToolbar` (`.unified`) gives the window its roomier titlebar.
- **The width of the sidebar of the main window** is persisted for each window (`WindowSnapshot.sidebarWidth`, default `Preferences.defaultSidebarWidth`).
  - `WindowAppearance.restoreSidebarWidth` restores it through `NSSplitView.setPosition`. It tries again across run-loop ticks until the split view exists. The autosave key of SwiftUI has a runtime address in it, which you can never read back, and `navigationSplitViewColumnWidth(ideal:)` is ignored.
  - `pinSidebarAutosaveName` gives the split view a stable name. `pruneChurnedAutosaveKeys` sweeps the old keys (it matches the marker `(unknown context at $`, and it is skipped under tests).
  - A sidebar that is collapsed is left alone. `forgetSidebarWidthRestore` clears the slot of a window that closed.
- **The frame of the main window** is persisted for each window too (`WindowSnapshot.frame`, the `frameDescriptor` string of AppKit). Macterm records it on every move and resize outside full screen. `WindowAppearance.restoreFrame` restores it through `setFrame(from:)` (#496).
  - The frame autosave of the `WindowGroup` of SwiftUI uses the content type of the scene as the key. That prints a private type (`AppColorScheme`) as `(unknown context at $ADDR)`. It therefore wrote a new `NSWindow Frame …` key at every launch and never read one back.
  - A stable name is not the fix. We measured it with `AppColorScheme` made internal: every window of the group writes the one key `AppWindow-1`. SwiftUI therefore keeps one frame for each group (the window that moved last), and the other windows that Macterm restores open at the default size. The key also still changes each time that the modifiers of the scene closure change.
  - `disownFrameAutosave` clears the autosave name of the window at attach (one owner). `pruneChurnedAutosaveKeys` sweeps both families of stale keys.
  - Macterm centers a restored frame on the main screen at its saved size when it has less than 60 pt on any screen. An example is the corner of a hidden workspace of a window manager.
- **Never leave persistent window state to an autosave of SwiftUI**. We measured every one of them (sidebar column, window frame). Each one uses a key with a runtime address, so it resets in silence at every launch and update. A stable key in `WindowSnapshot` is the rule.
- The spacing and the blur of the overlay sidebar are separate layers. The transparent `safeAreaBar` reserves the space of the titlebar. `SidebarTopBlurBar` stays above the rows and is not interactive.

## Known Limitations

- **Local sessions do not keep running after a restart of the Mac. Remote sessions do**. Every pane (workspace, pinned, quick terminal) persists through zmx. It connects again after a quit.
- **Remote projects need zmx installed on the host in advance**. Set `zmxPath` if the resolution through PATH fails. There is no install flow yet.
- **Remote orphan reaping reaches only the sessions that this installation stamped.**
- **A second window on the same tab shows a mirror**. It is dimmed where the pty has the size of the other view. You cannot declare `pane mirror` panes in layouts, so Save Layout and Apply Layout split one into two sessions.
- **Adaptive background inference depends on the private renderer layout of ghostty** (BGRA8 IOSurface). It fails closed. Selections that a program renders (helix, or vim under mouse capture) remain a gap that we have not closed.
- **Developer ID does not sign Macterm**. On first launch, you need `xattr -cr /Applications/Macterm.app`, or Homebrew. The stable self-signed certificate keeps TCC grants across updates.
- **`macos-hidden = always` costs the menu bar**. Settings, Quit, About and Check for Updates have no route while it is on. Set the own preferences of Macterm before you switch it on.
- **Pane IDs are not stable across restarts.**
- **Desktop widgets are not in the widget gallery of the system**. See Desktop widgets. They also do not take the monochrome look of the system while an app is in front.
- **Macterm detects password prompts only where it can read the tty that prompts**. This means local panes and the own ssh login of a remote project. It does not see `sudo` on a remote host, or anything behind an `ssh` that you typed by hand. It does not see prompts in raw mode that draw their own `*` mask either.
