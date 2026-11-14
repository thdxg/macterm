import AppKit

extension Pane {
    /// Connect the view's callbacks that feed the pane's own state: execution
    /// tracking, titles, search, bells, notifications and project memory.
    /// `ensureNSView` calls this when it makes the view, so the callbacks work
    /// before any window draws the pane. A pane in a `tab new --no-focus` tab,
    /// or in a background tab that a launch warmed, otherwise recorded no
    /// submission and no output, and `pane list` showed its run as idle.
    /// The callbacks that need the window that draws the pane (focus, splits,
    /// zoom, process exit, tab titles, links, the adaptive background, and
    /// `onRunEnded`) stay in `TerminalSurface.configure`.
    func connectViewCallbacks(_ view: GhosttyTerminalNSView) {
        view.onInteraction = { [weak self] in
            self?.recordUserInteraction()
        }
        // Typed input is what zmx moves leadership on, local or remote. The
        // report carries the pane (see `.terminalUserInput`).
        view.onUserInput = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .terminalUserInput, object: id)
        }
        view.onSurfaceSized = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .terminalSurfaceSized, object: id)
        }
        // Order matters: `onInteraction` clears the tracker's in-place start
        // arming that `onCommandSubmitted` sets, and the view calls them in
        // that order. See `GhosttyTerminalNSView.onCommandSubmitted`.
        view.onCommandSubmitted = { [weak self, weak view] hasContent in
            guard let self else { return }
            // Before the tracker leaves the prompt: memory captures the line
            // only while the shell is at its prompt. A mirror sees the same
            // shell; the real pane records for both.
            if !isMirror { ProjectMemory.shared.commandSubmitted(pane: self, view: view) }
            recordCommandSubmission(hasContent: hasContent)
        }
        view.canCarryCommandInput = { [weak self] in self?.allowsInPlaceOutputStart ?? false }
        // The surface half of the passthrough gate. The key responders decline
        // the event first; without this, `isAppShortcut` would still swallow it
        // here. Both consult `KeybindPassthrough` so they can't disagree.
        view.yieldsToProgram = { [weak self] event in
            guard let self else { return false }
            return KeybindPassthrough.yields(event: event, pane: self)
        }
        // Each OSC title is a command-boundary signal that re-reads the
        // foreground process, and — when a real program (not the shell) holds
        // the foreground — becomes the pane's display title.
        view.onTitleChange = { [weak self] title in self?.receiveReportedTitle(title) }
        view.titleProvider = { [weak self] in self?.displayTitle }

        view.copyMode.onLabelChange = { [weak self] label in self?.copyModeLabel = label }

        view.onSearchStart = { [weak self, weak view] needle in
            guard let self else { return }
            // Cmd+F toggles: if the search bar is already open, a second
            // start_search closes it (and returns focus to the terminal),
            // mirroring the close button rather than re-opening.
            if searchState.isVisible {
                guard let view else { return }
                view.endSearch()
                // Closing the search bar is a reshape — route focus through
                // FocusRestoration, not a bare makeFirstResponder (see onClose).
                FocusRestoration.restoreFocus(to: id, finder: { [weak self] in self }, in: view.window)
                return
            }
            if let needle, !needle.isEmpty { searchState.needle = needle }
            searchState.isVisible = true
            searchState.startPublishing { [weak self, weak view] q in
                view?.sendSearchQuery(q)
                // The tick scan must run against the needle the core actually
                // searched, not the live (possibly newer) field text.
                self?.scrollView?.noteSearchNeedle(q)
            }
            if !searchState.needle.isEmpty { searchState.pushNeedle() }
        }
        view.onSearchEnd = { [weak self] in
            guard let self else { return }
            searchState.stopPublishing()
            searchState.isVisible = false
            searchState.needle = ""
            searchState.total = nil
            searchState.selected = nil
            scrollView?.clearSearchTicks()
        }
        view.onSearchTotal = { [weak self] total in
            guard let self else { return }
            searchState.total = total
            if total == nil {
                scrollView?.clearSearchTicks()
            } else {
                scrollView?.refreshSearchTicks()
            }
        }
        view.onSearchSelected = { [weak self] sel in
            self?.searchState.selected = sel
            self?.scrollView?.setSearchSelected(sel)
        }
        view.onDesktopNotification = { [weak self, weak view] title, body in
            guard let self else { return }
            guard !(NSApp.isActive && view?.isFocused == true) else { return }
            NotificationHandler.shared.post(pane: self, title: title, body: body)
        }
        // Unconditional, unlike the notification above: whether the user is
        // looking is decided centrally by `AppState` (which acknowledges a
        // bell in the active tab of the active app on the spot), so the pane's
        // tab and the badge can never disagree about what counts as seen.
        view.onBell = { [weak self] in self?.ringBell() }
        view.onProgressStarted = { [weak self] in
            self?.refreshForegroundProcess()
            self?.markCommandRunning()
        }
        view.onProgressFinished = { [weak self, weak view] failed in
            // Only a live run can end. The REMOVE a program sends after its
            // ERROR finds the pane already `.done` and leaves the red dot up.
            guard let self, executionState == .running else { return }
            refreshForegroundProcess()
            markProgressFinished(failed: failed)
            view?.onRunEnded?()
        }
        view.onLinkHover = { [weak self] url in
            self?.hoverURL = url
        }
        view.onReadOnlyChange = { [weak self] isReadOnly in
            self?.isReadOnly = isReadOnly
        }
        view.onTerminalRender = { [weak view] in
            guard let view else { return }
            AdaptiveTerminalChrome.shared.terminalDidRender(view)
        }
        view.onOutputActivity = { [weak self, weak view] total in
            if let view {
                AdaptiveTerminalChrome.shared.terminalDidOutput(view)
                // A prompt is output: re-read the tty now rather than at the
                // next idle poll, so the bubble is up before the user types.
                PasswordPromptMonitor.shared.viewDidOutput(view)
            }
            guard let self else { return }
            // The single activity source. Output heartbeats fire from the pty
            // IO path regardless of occlusion, so they also reach background
            // tabs, and they carry the row total so the tracker can tell
            // growth from an in-place redraw. Always refresh foreground/raw
            // state first: a running canonical command can switch to a raw TUI
            // while normal polling is paused behind a fully occluded window.
            // The heartbeat is throttled to ~2 Hz, and the tracker preserves
            // foreground/progress authority until that raw transition occurs.
            refreshForegroundProcess()
            markOutputActivity(totalRows: total)
        }
        view.onSnapshotMark = { [weak self] started in
            self?.receiveRemoteSnapshot(started: started)
        }
        view.onRemoteForeground = { [weak self] foreground in
            self?.applyRemoteForeground(foreground)
        }
        view.onRemoteTtyMode = { [weak self] mode in
            self?.remoteLineMode = mode
        }
        view.onBackgroundColorChange = { [weak view] color in
            guard let view else { return }
            AdaptiveTerminalChrome.shared.terminalBackgroundDidChange(color, in: view)
        }
        view.onCommandFinished = { [weak self, weak view] exitCode, durationNs, command in
            guard let self else { return }
            // A command boundary is exactly when the pane's identity changes —
            // the program that just exited (claude, hx) is gone and the shell
            // owns the foreground again. Refresh from the process table HERE
            // rather than waiting for the next poll tick: the adaptive poll
            // slows to 2s when the app is inactive and stops entirely once no
            // window is visible, which is why a finished agent's icon and name
            // used to linger until the user clicked or typed.
            // `notePromptReturned` feeds the naming gate.
            notePromptReturned()
            refreshForegroundProcess()
            // Project memory: off unless the user turned it on, macOS 26+. A
            // mirror parses the same OSC 133;D; only the real pane records.
            if !isMirror {
                ProjectMemory.shared.commandFinished(
                    pane: self, view: view, exitCode: exitCode, durationNs: durationNs, reportedCommand: command
                )
            }
            markCommandFinished()
            view?.onRunEnded?()
            guard !(NSApp.isActive && view?.isFocused == true) else { return }
            let durationSec = Double(durationNs) / 1_000_000_000
            let duration = Self.formatDuration(durationSec)
            let body = if exitCode < 0 {
                String(localized: "Completed in \(duration)")
            } else {
                String(localized: "Exited with code \(Int(exitCode)) (\(duration))")
            }
            NotificationHandler.shared.post(pane: self, title: String(localized: "Command Finished"), body: body)
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            let value = String(format: "%.1f", seconds)
            return String(localized: "\(value)s", comment: "A duration in seconds, as in 4.2s")
        } else if seconds < 3600 {
            let rounded = Int(seconds.rounded())
            let mins = rounded / 60
            let secs = rounded % 60
            return String(localized: "\(mins)m \(secs)s", comment: "A duration in minutes and seconds, as in 3m 20s")
        } else {
            let rounded = Int(seconds.rounded())
            let hours = rounded / 3600
            let mins = (rounded % 3600) / 60
            return String(localized: "\(hours)h \(mins)m", comment: "A duration in hours and minutes, as in 2h 5m")
        }
    }
}
