import Cocoa

/// The approval card's controller wiring: mount, open, decide, close.
///
/// The card is a plain overlay above everything else in the bar. The machine
/// holds the locked request, this file only translates taps, snapshots and the
/// 10 Hz tick into machine calls, and logs every transition for the acceptance
/// runs.
extension TouchBarController {
    // MARK: - Mounting

    /// Mounts the card. Called last from `setupContainer`, so it floats above
    /// the workspace chips and the transient level pill.
    func setupAgentCard() {
        agentCard.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(agentCard)
        agentCard.isHidden = true
        NSLayoutConstraint.activate([
            // The card's right edge is the chip's right edge; its 224 pt grow
            // leftward over the app label and at most three workspace chips.
            agentCard.trailingAnchor.constraint(equalTo: agentChip.trailingAnchor),
            agentCard.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            agentCard.widthAnchor.constraint(equalToConstant: AgentCardView.width),
            agentCard.heightAnchor.constraint(equalToConstant: Theme.Layout.controlSize),
        ])

        agentChip.onTap = { [weak self] in
            self?.handleAgentChipTap()
        }
        agentChip.onLongPress = { [weak self] in
            self?.handleAgentChipLongPress()
        }
        agentCard.onIdentityTap = { [weak self] in
            // The identity cell jumps to the pane hosting the locked session,
            // then closes the card.
            self?.jumpFromAgentCard()
        }
        agentCard.onDecision = { [weak self] decision in
            self?.decideAgentCard(decision)
        }
    }

    // MARK: - Opening

    /// First tap: lock the oldest pending permission and show the card; with
    /// nothing pending, jump to the session that needs attention instead.
    func handleAgentChipTap() {
        // Effective visibility: the menu switch can hide the chip while the
        // bridge still publishes a healthy snapshot.
        guard agentVisible, let snapshot = agentSnapshot else { return }
        guard case .closed = agentCardMachine.phase else { return }
        guard let target = snapshot.triage.first else {
            // Nothing to approve. A waiting form cannot be answered from the
            // bar, so the tap lands on the session holding it; otherwise the
            // usual most-relevant-session jump.
            let jump: AgentJumpTarget?
            if case .awaiting = snapshot.chip {
                jump = snapshot.pendingJump ?? snapshot.jump
            } else {
                jump = snapshot.jump
            }
            if let jump { jumpToAgentTarget(jump) }
            return
        }
        guard agentCardMachine.open(target: target, now: Date()) else { return }
        log("agent card open \(target.shortName) \(target.position)/\(target.total)")
        renderAgentCard()
        startAgentCardTimer()
    }

    /// Second tap: submit the decision against the target locked at open.
    func decideAgentCard(_ decision: AgentDecision) {
        guard let target = agentCardMachine.choose(decision: decision, now: Date()) else { return }
        // The target came out of the machine, never out of the live queue: a
        // decision must not land on a request that shifted under the card.
        log("agent card decide \(decision.rawValue)")
        renderAgentCard()

        guard let bridge = agentBridge else {
            // No bridge means no service; keep the card and flash like a failed
            // reply so the user is not left staring at a dimmed card.
            agentCardMachine.failed(now: Date(), flash: Theme.Timing.agentCardErrorFlash)
            renderAgentCard()
            log("agent card failed")
            return
        }
        bridge.reply(sessionID: target.sessionID,
                     requestID: target.requestID,
                     decision: decision) { [weak self] succeeded in
            DispatchQueue.main.async {
                guard let self else { return }
                if succeeded {
                    // Success closes the card. The next request needs a new chip
                    // tap; the card never reopens by itself.
                    if self.agentCardMachine.submitted(now: Date()) {
                        self.closeAgentCardUI()
                    }
                } else {
                    // Stay open, flash once, no automatic retry. A late failure
                    // for a card that was dismissed or race-closed must not log
                    // a transition that never happened.
                    guard case .submitting = self.agentCardMachine.phase else { return }
                    self.agentCardMachine.failed(now: Date(),
                                                 flash: Theme.Timing.agentCardErrorFlash)
                    self.renderAgentCard()
                    log("agent card failed")
                }
            }
        }
    }

    // MARK: - Snapshots

    /// Reconciles the card with one bridge snapshot.
    ///
    /// `visible` is the effective chip visibility (menu switch AND bridge
    /// health), so disabling the chip also dismisses an open card.
    func syncAgentCard(with snapshot: AgentSnapshot, visible: Bool) {
        guard visible else {
            // The bridge is gone: a permission cannot be answered any more.
            if agentCardMachine.dismiss(now: Date()) {
                log("agent card hidden")
                closeAgentCardUI()
            }
            return
        }
        guard let target = agentCardMachine.target else { return }
        // permission.replied from any terminal removes the request from the
        // queue; the card closes without sending anything.
        guard !snapshot.triage.contains(where: { $0.requestID == target.requestID }) else { return }
        if agentCardMachine.raceReplied(requestID: target.requestID) {
            log("agent card race-closed")
            closeAgentCardUI()
        }
    }

    // MARK: - Jump

    /// Identity-cell tap: jump to the session the card locked, then close.
    func jumpFromAgentCard() {
        guard let target = agentCardMachine.target else { return }
        performAgentJump(directory: target.directory)
        dismissAgentCard(reason: "jumped")
    }

    /// Chip-tap jump target; used when nothing is pending.
    func jumpToAgentTarget(_ target: AgentJumpTarget) {
        performAgentJump(directory: target.directory)
    }

    /// Looks up and activates the WezTerm pane for `directory`.
    ///
    /// The CLI spawns block, so lookup and activation run on the jump queue;
    /// only the app activation and the log line hop to main. The directory is
    /// never logged: it can contain private project names.
    private func performAgentJump(directory: String) {
        agentJumpQueue.async { [weak self] in
            guard let self else { return }
            let pane = self.weztermLocator.locatePane(directory: directory)
            if let pane { self.weztermLocator.activate(pane: pane) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didShutdown else { return }
                if let pane {
                    log("agent jump pane=\(pane.paneID) tab=\(pane.tabID)")
                } else {
                    log("agent jump app-only")
                }
                Self.activateWezTerm()
            }
        }
    }

    /// Brings WezTerm to the front.
    ///
    /// The bundle id is the installed app's. If activation is refused, fall back
    /// to asking the workspace to open the bundle, which also launches it.
    private static func activateWezTerm() {
        let bundleID = "com.github.wez.wezterm"
        let options: NSApplication.ActivationOptions = [.activateAllWindows]
        let activated = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
            .map { app -> Bool in
                if #available(macOS 14.0, *) {
                    // The source-aware variant is the supported call on the OS
                    // this app runs on; the old one covers the 13.0 floor.
                    return app.activate(from: .current, options: options)
                }
                return app.activate(options: options)
            } ?? false
        guard !activated else { return }

        log("agent jump activation refused")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            log("agent jump wezterm app not found")
            return
        }
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                log("agent jump open failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Long press

    /// Long press: skip to the next pending permission, or interrupt the busy
    /// session when nothing is waiting for approval.
    func handleAgentChipLongPress() {
        // A press can outlive the bar (dismissal cancels the chip's timer, but a
        // stray callback must still not interrupt anything).
        guard !didShutdown, container.window != nil else { return }
        guard agentVisible, let snapshot = agentSnapshot else { return }
        if !snapshot.triage.isEmpty {
            advanceAgentCard()
            return
        }
        // Interrupt never targets a form holder: the target is the newest BUSY
        // session, so with only a form waiting this is a no-op.
        guard let target = snapshot.interrupt else { return }
        log("agent interrupt \(target.sessionID.prefix(8))")
        agentBridge?.interrupt(sessionID: target.sessionID)
    }

    /// Moves the card to the next request and restarts its timeout.
    ///
    /// The card is re-opened rather than mutated: `open` creates a fresh
    /// `openedAt`, which is what resets the five second window. A submit in
    /// flight is left alone.
    func advanceAgentCard() {
        guard let snapshot = agentSnapshot else { return }
        if case .submitting = agentCardMachine.phase { return }
        guard let index = AgentCardMachine.nextIndex(after: agentCardMachine.target?.requestID,
                                                     in: snapshot.triage) else { return }
        let next = snapshot.triage[index]
        _ = agentCardMachine.dismiss(now: Date())
        guard agentCardMachine.open(target: next, now: Date()) else { return }
        log("agent card open \(next.shortName) \(next.position)/\(next.total)")
        renderAgentCard()
        startAgentCardTimer()
    }

    // MARK: - Tick and dismissal

    /// Runs at 10 Hz while the card is visible: flash recovery, timeout, repaint.
    func tickAgentCard() {
        let now = Date()
        // Recover before expiring. A failed card past its flash returns to the
        // normal open phase with a fresh timeout; expiring first would close the
        // card at the end of the flash instead of letting the user retry.
        agentCardMachine.recoverFromFlash(now: now, flash: Theme.Timing.agentCardErrorFlash)
        if agentCardMachine.expire(now: now, timeout: Theme.Timing.agentCardTimeout) {
            log("agent card timeout")
            closeAgentCardUI()
            return
        }
        renderAgentCard()
    }

    /// Hides the card for a reason that is not a submitted decision.
    func dismissAgentCard(reason: String) {
        guard agentCardMachine.dismiss(now: Date()) else { return }
        log("agent card \(reason)")
        closeAgentCardUI()
    }

    /// Clears the card on bridge teardown.
    func resetAgentCard() {
        agentCardTimer?.invalidate()
        agentCardTimer = nil
        agentCardMachine = AgentCardMachine()
        agentCard.apply(.closed)
    }

    // MARK: - Helpers

    func renderAgentCard() {
        agentCard.apply(agentCardMachine.phase)
    }

    private func startAgentCardTimer() {
        guard agentCardTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tickAgentCard()
        }
        RunLoop.main.add(timer, forMode: .common)
        agentCardTimer = timer
    }

    private func closeAgentCardUI() {
        agentCardTimer?.invalidate()
        agentCardTimer = nil
        agentCard.apply(.closed)
    }
}
