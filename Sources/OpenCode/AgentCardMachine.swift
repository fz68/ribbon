import Foundation

/// The request a card is showing, captured when the card opens.
///
/// Locking `sessionID` and `requestID` at open time is the whole point: the
/// queue can change under the card (another terminal answers, a new request
/// arrives), and a later decision must still land on the request the user was
/// looking at, never on whatever happens to be first now.
struct AgentCardTarget: Equatable {
    let sessionID: String
    let requestID: String
    let shortName: String
    /// 1-based position in the permission queue, oldest first.
    let position: Int
    /// Size of the permission queue when the card opened.
    let total: Int
    /// Absolute directory the session runs in, used by jump-to-pane. Empty means
    /// unknown (the session had no directory); the jump then degrades to
    /// app-only.
    let directory: String
}

/// Where a chip tap should jump: a session, not a request.
///
/// Kept apart from `AgentCardTarget` so a jump can never be mistaken for a
/// permission the card could answer. An empty `directory` means unknown, and the
/// jump then degrades to activating WezTerm only.
struct AgentJumpTarget: Equatable {
    let sessionID: String
    let shortName: String
    let directory: String
}

/// The approval card's state machine.
///
/// Pure and time-injected: the controller ticks `expire`, `recoverFromFlash`
/// and renders the phase; nothing here reads a clock or a queue. Once `choose`
/// hands back the locked target, the answer is sent with exactly those ids even
/// if the request disappeared from the queue in the meantime.
struct AgentCardMachine {
    enum Phase: Equatable {
        case closed
        case open(AgentCardTarget, openedAt: Date)
        case submitting(AgentCardTarget, decision: AgentDecision)
        case failed(AgentCardTarget, decision: AgentDecision, flashUntil: Date)
    }

    private(set) var phase: Phase = .closed

    /// The request the card holds, whatever the phase; nil when closed.
    var target: AgentCardTarget? {
        switch phase {
        case .closed:
            return nil
        case .open(let target, _):
            return target
        case .submitting(let target, _):
            return target
        case .failed(let target, _, _):
            return target
        }
    }

    /// Opens the card on `target`. Returns false when a card is already showing.
    mutating func open(target: AgentCardTarget, now: Date) -> Bool {
        guard case .closed = phase else { return false }
        phase = .open(target, openedAt: now)
        return true
    }

    /// Hides the card. Returns true when there was a card to hide.
    ///
    /// A submitting card is dismissible too: the service may already have
    /// answered, and the reply completion then finds a closed machine and does
    /// nothing (see `submitted`).
    mutating func dismiss(now: Date) -> Bool {
        guard case .closed = phase else {
            phase = .closed
            return true
        }
        return false
    }

    /// Closes the card because its request was answered elsewhere.
    ///
    /// Only the request the card holds counts: a reply for a different request
    /// must leave the card alone (it may belong to another terminal or to a
    /// request queued behind this one).
    mutating func raceReplied(requestID: String) -> Bool {
        guard let target, target.requestID == requestID else { return false }
        phase = .closed
        return true
    }

    /// Moves to submitting and returns the locked target, or nil when there is
    /// nothing to submit (closed, or a submit is already in flight).
    ///
    /// A failed card may be retried before `recoverFromFlash` runs, so the
    /// decision path never depends on the controller's tick order.
    mutating func choose(decision: AgentDecision, now: Date) -> AgentCardTarget? {
        switch phase {
        case .open(let target, _), .failed(let target, _, _):
            phase = .submitting(target, decision: decision)
            return target
        case .submitting, .closed:
            return nil
        }
    }

    /// The service accepted the reply. Returns true when a submit was in flight.
    mutating func submitted(now: Date) -> Bool {
        guard case .submitting = phase else { return false }
        phase = .closed
        return true
    }

    /// The reply failed: keep the card open, flash it, and do not retry on our
    /// own. The user decides whether to press again.
    mutating func failed(now: Date, flash: TimeInterval) {
        guard case .submitting(let target, let decision) = phase else { return }
        phase = .failed(target, decision: decision,
                        flashUntil: now.addingTimeInterval(flash))
    }

    /// Closes an idle or still-flashing card once its window is over.
    ///
    /// A submit in flight never expires: the card is waiting on the service,
    /// not on the user.
    mutating func expire(now: Date, timeout: TimeInterval) -> Bool {
        switch phase {
        case .closed, .submitting:
            return false
        case .open(_, let openedAt):
            guard now.timeIntervalSince(openedAt) >= timeout else { return false }
            phase = .closed
            return true
        case .failed(_, _, let flashUntil):
            guard now >= flashUntil else { return false }
            phase = .closed
            return true
        }
    }

    /// Ends the error flash and returns the card to the normal open phase.
    ///
    /// The fresh `openedAt` restarts the timeout: the flash time is not charged
    /// against the window the user gets to retry in.
    mutating func recoverFromFlash(now: Date, flash: TimeInterval) {
        guard case .failed(let target, _, let flashUntil) = phase,
              now >= flashUntil else {
            return
        }
        phase = .open(target, openedAt: now)
    }
}
