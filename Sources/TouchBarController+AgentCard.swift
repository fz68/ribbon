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
        // The Accessibility actions reach the two halves of the long press
        // directly, so a VoiceOver user never has to hold a Touch Bar button.
        agentChip.onSkipToNextApproval = { [weak self] in
            self?.advanceAgentCard()
        }
        agentChip.onInterruptSession = { [weak self] in
            self?.interruptAgentSession()
        }
        agentCard.onIdentityTap = { [weak self] in
            // The identity cell jumps to the pane hosting the locked session,
            // then closes the card.
            self?.jumpFromAgentCard()
        }
        agentCard.onDecision = { [weak self] decision in
            self?.decideAgentCard(decision)
        }
        agentCard.onOption = { [weak self] value in
            self?.answerAgentCardForm(option: value)
        }
    }

    // MARK: - Opening

    /// First tap: lock the oldest pending permission and show the card; with no
    /// permission waiting, open on the oldest answerable form. With neither,
    /// jump to the session that needs attention instead.
    func handleAgentChipTap() {
        // Effective visibility: the menu switch can hide the chip while the
        // bridge still publishes a healthy snapshot.
        guard agentVisible, let snapshot = agentSnapshot else { return }
        guard case .closed = agentCardMachine.phase else { return }
        // Permissions outrank forms: the card answers exactly one queue, and a
        // permission is the older, blocking kind of wait.
        if let target = snapshot.triage.first ?? snapshot.formTriage.first {
            openAgentCard(target)
            return
        }
        // Nothing answerable. A form that needs the terminal keeps today's
        // behaviour: the tap lands on the session holding it; otherwise the
        // usual most-relevant-session jump.
        let jump: AgentJumpTarget?
        if case .awaiting = snapshot.chip {
            jump = snapshot.pendingJump ?? snapshot.jump
        } else {
            jump = snapshot.jump
        }
        if let jump { jumpToAgentTarget(jump) }
    }

    /// Locks `target` into the machine and shows the card.
    private func openAgentCard(_ target: AgentCardTarget) {
        guard agentCardMachine.open(target: target, now: Date()) else { return }
        log("agent card open \(target.shortName) \(target.position)/\(target.total)")
        renderAgentCard()
        // Discrete transition only: the card just appeared, nothing polls here.
        announce(target.accessibilityIdentity, element: agentCard)
        startAgentCardTimer()
    }

    /// Second tap on a decision cell: submit the decision against the target
    /// locked at open.
    func decideAgentCard(_ decision: AgentDecision) {
        guard let target = agentCardMachine.choose(decision: decision, now: Date()) else { return }
        // The target came out of the machine, never out of the live queue: a
        // decision must not land on a request that shifted under the card.
        log("agent card decide \(decision.rawValue)")
        submitAgentCard { bridge, completion in
            bridge.reply(sessionID: target.sessionID,
                         requestID: target.requestID,
                         decision: decision,
                         completion: completion)
        }
    }

    /// Tap on an option cell of a form card: send that option for the field the
    /// card locked at open.
    ///
    /// The option value itself is deliberately never logged: it is form content.
    func answerAgentCardForm(option: String) {
        guard let target = agentCardMachine.choose(option: option, now: Date()),
              let fieldKey = target.fieldKey else { return }
        log("agent card form \(target.shortName) \(target.position)/\(target.total)")
        submitAgentCard { bridge, completion in
            bridge.replyForm(sessionID: target.sessionID,
                             formID: target.requestID,
                             fieldKey: fieldKey,
                             value: option,
                             completion: completion)
        }
    }

    /// Shared submit plumbing for both card kinds.
    ///
    /// The machine is already `.submitting` when this runs; success announces the
    /// outcome and closes the card, failure leaves it open for one flash and no
    /// automatic retry. A late completion for a card that was dismissed or
    /// race-closed is ignored, announcement included.
    private func submitAgentCard(send: @escaping (AgentBridge,
                                                  @escaping (Bool) -> Void) -> Void) {
        renderAgentCard()

        guard let bridge = agentBridge else {
            // No bridge means no service; keep the card and flash like a failed
            // reply so the user is not left staring at a dimmed card.
            failAgentCard()
            return
        }
        send(bridge) { [weak self] succeeded in
            DispatchQueue.main.async {
                guard let self else { return }
                if succeeded {
                    // Read the accepted answer before `submitted` closes the
                    // phase; that is the only moment it is still there, which is
                    // also why a repeated completion announces nothing.
                    let confirmation = self.agentCardMachine.submittingAnswer?.successAnnouncement
                    // Success closes the card. The next request needs a new chip
                    // tap; the card never reopens by itself.
                    if self.agentCardMachine.submitted(now: Date()) {
                        // Discrete transition only: one submission, one sentence,
                        // posted on the card before it is hidden.
                        if let confirmation {
                            self.announce(confirmation, element: self.agentCard)
                        }
                        self.closeAgentCardUI()
                    }
                } else {
                    // Stay open, flash once, no automatic retry.
                    guard case .submitting = self.agentCardMachine.phase else { return }
                    self.failAgentCard()
                }
            }
        }
    }

    /// Flashes a failed reply and announces it once.
    ///
    /// Both callers sit on the failure side of a submit, and the machine's
    /// `failed` only leaves `.submitting`, so this is the transition into
    /// `.failed` and nothing else. The 10 Hz tick's `recoverFromFlash` only
    /// leaves that phase, so it can never re-announce.
    private func failAgentCard() {
        agentCardMachine.failed(now: Date(), flash: Theme.Timing.agentCardErrorFlash)
        renderAgentCard()
        log("agent card failed")
        announce("Reply failed. Choose again.", element: agentCard)
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
        // permission.replied / form.replied from any terminal removes the entry
        // from its queue; the card closes without sending anything. Both queues
        // are checked because the card answers either kind of wait.
        let stillQueued = snapshot.triage.contains { $0.requestID == target.requestID }
            || snapshot.formTriage.contains { $0.requestID == target.requestID }
        guard !stillQueued else { return }
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
                if #available(macOS 14, *) { Self.activateWezTerm() }
            }
        }
    }

    /// Brings WezTerm to the front.
    ///
    /// The bundle id is the installed app's. If activation is refused, fall back
    /// to asking the workspace to open the bundle, which also launches it.
    @available(macOS 14, *)
    private static func activateWezTerm() {
        let bundleID = "com.github.wez.wezterm"
        let options: NSApplication.ActivationOptions = [.activateAllWindows]
        let activated = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
            .map { app -> Bool in
                // The source-aware variant is the supported call on the OS
                // this app runs on; the old one covers the 13.0 floor.
                return app.activate(from: .current, options: options)
                    || app.activate(options: options)
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
        interruptAgentSession()
    }

    /// Interrupts the newest busy session; a no-op when nothing is interruptible.
    ///
    /// This is the tail of the 1.2 s hold, and the target of the chip's
    /// "Interrupt session" Accessibility action, so the guards are repeated here
    /// instead of relying on a press having happened.
    func interruptAgentSession() {
        // Interrupt never targets a form holder: the target is the newest BUSY
        // session, so with only a form waiting this is a no-op.
        guard !didShutdown, agentVisible, let snapshot = agentSnapshot,
              let target = snapshot.interrupt else { return }
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
        // Discrete transition only: a long press or an AX action moved the card.
        announce(next.accessibilityIdentity, element: agentCard)
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
        // WCAG 2.2.1 (Timing Adjustable): the five second window is not enough
        // to hear and answer the card under VoiceOver, and a card that closes on
        // its own is a time limit the user cannot turn off or extend. So while
        // VoiceOver is running the auto-expire is suppressed; every other close
        // path (submitted, race-replied, explicit dismiss, skip) still applies.
        // `expire` ignores `.submitting` anyway, so a suppressed tick cannot
        // extend a submit in flight either. `NSWorkspace.isVoiceOverEnabled`
        // (macOS 10.13+) is the documented, permission-free signal; it is a
        // plain cached property read, so the 10 Hz tick's cost is unchanged.
        if !NSWorkspace.shared.isVoiceOverEnabled,
           agentCardMachine.expire(now: now, timeout: Theme.Timing.agentCardTimeout) {
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
