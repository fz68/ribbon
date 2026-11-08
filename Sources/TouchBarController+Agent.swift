import Cocoa

extension TouchBarController {
    // MARK: - Bridge lifecycle

    /// Starts the OpenCode watch. Safe to call on every present: the bridge is
    /// created once and keeps running.
    func startAgentBridge() {
        // The menu switch is authoritative: a disabled chip must never create a
        // bridge, not even when the bar is presented.
        guard AgentConfig.isEnabled else { return }
        guard agentBridge == nil else { return }
        let bridge = AgentBridge(onUpdate: { [weak self] snapshot in
            // The bridge publishes on its own queue; every view change is a main
            // thread change.
            DispatchQueue.main.async {
                self?.applyAgentUpdate(snapshot: snapshot)
            }
        })
        agentBridge = bridge
        bridge.start()
    }

    /// Stops the watch and the chip's timers.
    func stopAgentBridge() {
        agentBridge?.stop()
        agentBridge = nil
        agentAnimationTimer?.invalidate()
        agentAnimationTimer = nil
        agentAnimationStart = nil
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil
        resetAgentCard()
    }

    /// Asks the bridge to recompute and republish its snapshot.
    ///
    /// Called at the end of the workspace refresh and when the done window
    /// expires, so time-based state changes do not need an event.
    func updateAgentChip() {
        agentBridge?.refresh()
    }

    // MARK: - Rendering

    /// Applies one published snapshot. Main thread only.
    func applyAgentUpdate(snapshot: AgentSnapshot) {
        guard !didShutdown else { return }
        agentSnapshot = snapshot
        // The menu switch is ANDed here, not in the bridge: a disabled chip is
        // collapsed even if a snapshot arrives from a bridge that is shutting
        // down, and the policy stays a pure function.
        let visible = AgentBridgeHealth.visible(enabled: AgentConfig.isEnabled,
                                                bridgeVisible: snapshot.visible)
        // Permissions waiting -> the 0.5s skip; nothing to approve -> the
        // longer 1.2s interrupt hold. Decided per snapshot, applied on the next
        // press.
        agentChip.longPressThreshold = snapshot.triage.isEmpty
            ? Theme.Timing.agentInterruptHold
            : Theme.Timing.agentLongPressThreshold
        // The card is checked on every snapshot, even when the chip pair is
        // unchanged: the queue can change without the chip state changing.
        syncAgentCard(with: snapshot, visible: visible)

        guard snapshot.chip != agentState || visible != agentVisible else { return }
        agentState = snapshot.chip
        agentVisible = visible

        let visual = AgentChipVisual.visual(for: snapshot.chip)
        setAgentChipVisible(visible)
        agentChip.apply(visual)
        // A collapsed chip has nothing to animate, whatever the state says.
        updateAgentAnimation(visible ? visual : AgentChipVisual.visual(for: .off))
        scheduleDoneExpiry(for: snapshot.chip)
        log("agent chip state=\(Self.agentStateName(snapshot.chip)) visible=\(visible ? 1 : 0)")
    }

    /// Applies the menu switch live: no restart, no re-present.
    ///
    /// Disabling stops the bridge and explicitly collapses the chip, so a stale
    /// snapshot cannot bring it back; enabling starts discovery from scratch.
    func applyAgentEnabled(_ enabled: Bool) {
        guard !didShutdown else { return }
        if enabled {
            startAgentBridge()
        } else {
            stopAgentBridge()
            agentSnapshot = nil
            agentState = nil
            agentVisible = false
            setAgentChipVisible(false)
            agentChip.apply(AgentChipVisual.visual(for: .off))
        }
    }

    /// Collapses the chip by width, never by removing it: the level pill is
    /// anchored to its leading edge.
    private func setAgentChipVisible(_ visible: Bool) {
        let collapsed = !visible
        if agentChip.isHidden != collapsed {
            agentChip.isHidden = collapsed
        }
        let width = visible ? Theme.Layout.chipWidth : 0
        guard let constraint = agentChipWidth, constraint.constant != width else { return }
        constraint.constant = width
        container.needsLayout = true
    }

    /// Starts, keeps or stops the single animation timer.
    private func updateAgentAnimation(_ visual: AgentChipVisual) {
        let animates = visual.pulses || visual.hairline
        guard animates else {
            agentAnimationTimer?.invalidate()
            agentAnimationTimer = nil
            agentAnimationStart = nil
            agentChip.animate(elapsed: 0)
            return
        }
        // Continue an existing phase; a state change between two animated states
        // must not make the pulse jump.
        agentChip.animate(elapsed: agentAnimationStart.map { Date().timeIntervalSince($0) } ?? 0)
        guard agentAnimationTimer == nil else { return }
        agentAnimationStart = Date()
        // 10 Hz is the plan's ceiling: enough for a 1.2 s breath and a 2.4 s
        // sweep, and cheap because only layer properties change.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tickAgentAnimation()
        }
        RunLoop.main.add(timer, forMode: .common)
        agentAnimationTimer = timer
    }

    private func tickAgentAnimation() {
        guard let start = agentAnimationStart else { return }
        agentChip.animate(elapsed: Date().timeIntervalSince(start))
    }

    /// `done` is the only state that ends on the clock alone, so it gets one
    /// one-shot republish at the store's own deadline.
    private func scheduleDoneExpiry(for state: AgentChipState) {
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil
        guard case .done = state else { return }
        let timer = Timer(timeInterval: AgentSessionStore.doneDuration, repeats: false) { [weak self] _ in
            self?.agentDoneTimer = nil
            self?.updateAgentChip()
        }
        RunLoop.main.add(timer, forMode: .common)
        agentDoneTimer = timer
    }

    private static func agentStateName(_ state: AgentChipState) -> String {
        switch state {
        case .off: return "off"
        case .idle: return "idle"
        case .busy(let count): return "busy(\(count))"
        case .awaiting(let count): return "awaiting(\(count))"
        case .done: return "done"
        }
    }
}
