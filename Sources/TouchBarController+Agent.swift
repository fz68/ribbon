import Cocoa

extension TouchBarController {
    // MARK: - Bridge lifecycle

    /// Starts the OpenCode watch. Safe to call on every present: the bridge is
    /// created once and keeps running.
    func startAgentBridge() {
        guard agentBridge == nil else { return }
        let bridge = AgentBridge()
        bridge.onUpdate = { [weak self] state, visible in
            // The bridge publishes on its own queue; every view change is a main
            // thread change.
            DispatchQueue.main.async {
                self?.applyAgentUpdate(state: state, visible: visible)
            }
        }
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
    func applyAgentUpdate(state: AgentChipState, visible: Bool) {
        guard !didShutdown else { return }
        // Idempotent: an unchanged pair must not repaint, relayout or restart a
        // timer. The bridge republishes the same state on every health tick.
        guard state != agentState || visible != agentVisible else { return }
        agentState = state
        agentVisible = visible

        let visual = AgentChipVisual.visual(for: state)
        setAgentChipVisible(visible)
        agentChip.apply(visual)
        // A collapsed chip has nothing to animate, whatever the state says.
        updateAgentAnimation(visible ? visual : AgentChipVisual.visual(for: .off))
        scheduleDoneExpiry(for: state)
        log("agent chip state=\(Self.agentStateName(state)) visible=\(visible ? 1 : 0)")
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
