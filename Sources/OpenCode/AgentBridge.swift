import Foundation

/// One published state of the agent UI.
///
/// The chip and the card read the same snapshot, so they can never disagree
/// about whether the bridge is alive or what the queue looks like. `triage`
/// carries permissions only: P2's card cannot answer forms.
struct AgentSnapshot: Equatable {
    let chip: AgentChipState
    let visible: Bool
    /// Permission requests only, oldest first, with 1-based positions.
    let triage: [AgentCardTarget]
    /// Where a chip tap jumps when nothing is pending: the most recently touched
    /// busy session, else the most recently touched session. nil only when the
    /// store has no sessions. The card path supplies its own locked target, so
    /// this never carries a permission request.
    let jump: AgentJumpTarget?
}

/// Owns the opencode connection for the agent chip.
///
/// The bridge is the only place that knows about all four P0 pieces: the
/// locator says where the service is, the stream says what changed, the client
/// says what the truth is right now, and the store reduces both into the chip's
/// state. Everything runs on one serial queue, so the store and the published
/// snapshot cannot interleave. There is no AppKit here on purpose: the
/// controller hops the published pair to the main thread.
///
/// Health is measured from any stream activity - heartbeat comments included -
/// not from business events alone: the service keeps an idle connection open
/// with heartbeats, and that connection is proof enough that the chip should
/// stay.
///
/// Callbacks (`onUpdate` on this class, and the locator/stream closures) are set
/// once before `start()` and never mutated afterwards.
///
/// Sendability: every mutable property is touched only from `queue`, and the
/// only things crossing into a `Task` are immutable lets plus the captured
/// client value. Marking the class unchecked states that confinement instead of
/// scattering locks through it.
final class AgentBridge: @unchecked Sendable {
    /// Publishes every recomputed snapshot on the bridge queue. Identical
    /// snapshots can arrive repeatedly (the health tick republishes); the
    /// consumer is expected to ignore them.
    var onUpdate: ((AgentSnapshot) -> Void)?

    private let locator: ServiceLocator
    private let stream: EventStream
    private let session: URLSession
    private let now: () -> Date
    private let queue: DispatchQueue

    private var running = false
    private var endpoint: ServiceEndpoint?
    private var client: OpenCodeClient?
    private var store = AgentSessionStore()
    /// Last stream activity, endpoint change or resync. Liveness is any traffic
    /// on the event connection - a `: heartbeat` comment counts exactly like a
    /// permission event - because the service keeps a healthy connection open
    /// with heartbeats during long quiet stretches. Measuring only business
    /// events hid a healthy chip after a minute without one.
    private var lastContact: Date?
    private var healthTimer: DispatchSourceTimer?
    /// Makes a slow reconcile unable to overwrite a newer one, and a reconcile
    /// for an old endpoint unable to touch the store at all.
    private var reconcileGeneration = 0
    private var loggedReconcileFailure = false

    init(locator: ServiceLocator = ServiceLocator(),
         stream: EventStream = EventStream(),
         session: URLSession = .shared,
         now: @escaping () -> Date = Date.init,
         queue: DispatchQueue = DispatchQueue(label: "local.ribbon.opencode.bridge")) {
        self.locator = locator
        self.stream = stream
        self.session = session
        self.now = now
        self.queue = queue

        locator.onEndpoint = { [weak self] endpoint in
            guard let self else { return }
            self.queue.async { self.handleEndpoint(endpoint) }
        }
        stream.onEvent = { [weak self] event in
            guard let self else { return }
            self.queue.async { self.handleEvent(event) }
        }
        stream.onResync = { [weak self] in
            guard let self else { return }
            self.queue.async { self.handleResync() }
        }
        stream.onActivity = { [weak self] in
            guard let self else { return }
            self.queue.async { self.handleActivity() }
        }
    }

    deinit {
        healthTimer?.cancel()
    }

    /// Starts watching the service and the health clock.
    ///
    /// Called after the first successful present, so launch cost is not on the
    /// path to a visible bar.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.startHealthTimer()
            self.locator.start()
            self.publish()
        }
    }

    /// Stops the watch and drops the endpoint. Session state is cleared so a
    /// later start cannot show counts from the old service.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.healthTimer?.cancel()
            self.healthTimer = nil
            self.stream.stop()
            self.locator.stop()
            self.endpoint = nil
            self.client = nil
            self.lastContact = nil
            self.store = AgentSessionStore()
            self.reconcileGeneration += 1
            self.onUpdate?(AgentSnapshot(chip: .off, visible: false, triage: [], jump: nil))
        }
    }

    /// Recomputes and republishes the current state.
    ///
    /// Needed for the time-based `done` window, which expires without any event,
    /// and for the periodic workspace refresh.
    func refresh() {
        queue.async { [weak self] in
            self?.publish()
        }
    }

    /// Sends one decision for the request the card locked, reporting the
    /// outcome on the bridge queue.
    ///
    /// The ids are passed in rather than looked up again: by the time the
    /// request lands, the queue may already have moved on, and the user
    /// answered the request the card showed.
    func reply(sessionID: String, requestID: String, decision: AgentDecision,
               completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, let client = self.client else {
                completion(false)
                return
            }
            let queue = self.queue
            // The completion is not Sendable; the task only hands it back to the
            // bridge queue, so wrapping it states that confinement.
            let result = SendableCompletion(run: completion)
            Task {
                let succeeded: Bool
                do {
                    try await client.replyPermission(sessionID: sessionID,
                                                     requestID: requestID,
                                                     decision: decision)
                    succeeded = true
                } catch {
                    succeeded = false
                }
                queue.async { result.run(succeeded) }
            }
        }
    }

    // MARK: - Inputs

    private func handleEndpoint(_ endpoint: ServiceEndpoint?) {
        guard running else { return }
        self.endpoint = endpoint
        lastContact = now()
        if let endpoint {
            client = OpenCodeClient(endpoint: endpoint, session: session)
            stream.update(endpoint: endpoint)
        } else {
            // The service is gone: stop the stream and forget its sessions so a
            // restart cannot briefly show the old counts.
            client = nil
            stream.stop()
            store = AgentSessionStore()
            reconcileGeneration += 1
        }
        publish()
    }

    private func handleResync() {
        guard running else { return }
        lastContact = now()
        scheduleReconcile()
        publish()
    }

    private func handleEvent(_ event: AgentEvent) {
        guard running else { return }
        lastContact = now()
        store.apply(event, now: now())
        publish()
    }

    /// Any line on the stream, including a `: heartbeat` comment.
    ///
    /// This is the contact that keeps the chip visible between business events;
    /// the stream throttles the callback, so no extra filtering is needed here.
    /// Publishing makes a chip that already aged out reappear promptly instead
    /// of waiting for the next health tick.
    private func handleActivity() {
        guard running else { return }
        lastContact = now()
        publish()
    }

    // MARK: - Reconciliation

    private func scheduleReconcile() {
        guard let client else { return }
        reconcileGeneration += 1
        let generation = reconcileGeneration
        let clock = now
        let queue = self.queue
        Task { [weak self] in
            let snapshot = await Self.snapshot(for: client, pendingTime: clock())
            queue.async { [weak self] in
                self?.apply(snapshot, generation: generation)
            }
        }
    }

    /// One reconciliation fetch: active set, session page, then pending
    /// permissions per listed session.
    ///
    /// A failed active/list fetch fails the whole reconcile. A failed pending
    /// fetch only makes the pending set non-authoritative, because sessions and
    /// busy flags are still worth applying.
    private static func snapshot(for client: OpenCodeClient, pendingTime: Date) async -> Snapshot? {
        do {
            let active = try await client.activeSessionIDs()
            let listed = try await client.listSessions()
            var pendingByID: [String: [PendingRequest]]? = [:]
            for session in listed {
                do {
                    pendingByID?[session.id] = try await client.pendingRequests(sessionID: session.id,
                                                                               now: pendingTime)
                } catch {
                    pendingByID = nil
                    break
                }
            }
            return Snapshot(active: active, listed: listed, pendingByID: pendingByID)
        } catch {
            return nil
        }
    }

    private func apply(_ snapshot: Snapshot?, generation: Int) {
        guard running, generation == reconcileGeneration else { return }
        guard let snapshot else {
            if !loggedReconcileFailure {
                // Deliberately no error text: it can carry the request URL, and
                // the only actionable fact is that the fetch failed.
                log("opencode reconcile failed; keeping the current chip state")
                loggedReconcileFailure = true
            }
            return
        }
        loggedReconcileFailure = false
        let now = self.now()
        let sessions = AgentReconciler.sessions(activeIDs: snapshot.active,
                                                listedSessions: snapshot.listed,
                                                pendingByID: snapshot.pendingByID,
                                                previous: store,
                                                now: now)
        store.replaceAll(sessions: sessions,
                         now: now,
                         pendingIsAuthoritative: snapshot.pendingByID != nil)
        publish()
    }

    // MARK: - Publishing

    private func startHealthTimer() {
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Theme.Timing.agentHealthCheck,
                       repeating: Theme.Timing.agentHealthCheck)
        timer.setEventHandler { [weak self] in
            self?.publish()
        }
        timer.resume()
        healthTimer = timer
    }

    private func publish() {
        let now = self.now()
        let snapshot = AgentSnapshot(
            chip: store.chip(now: now),
            visible: AgentBridgeHealth.visible(endpoint: endpoint != nil,
                                               lastContact: lastContact,
                                               now: now),
            triage: store.triageList,
            jump: store.jumpTarget
        )
        onUpdate?(snapshot)
    }

    private struct Snapshot {
        let active: Set<String>
        let listed: [SessionSummary]
        let pendingByID: [String: [PendingRequest]]?
    }
}

/// Carries an escaping completion across a `Task` boundary.
///
/// The closure is not Sendable but only ever runs on the bridge queue; the
/// wrapper states that confinement instead of forcing it into a `@Sendable`
/// parameter the call sites would have to satisfy.
private struct SendableCompletion<Value>: @unchecked Sendable {
    let run: (Value) -> Void
}
