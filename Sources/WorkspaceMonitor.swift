import Foundation
import Darwin

/// One child-process monitor, shared by the two workspace backends.
final class WorkspaceMonitor: @unchecked Sendable {
    private let label: String
    /// Short tool name for the two `subscribe` log lines, where "nehirctl"
    /// is written as "nehir".
    private let subscribeLabel: String
    private let subscribeArguments: [String]
    private let validatesJSON: Bool
    private let hasIPC: () -> Bool
    private let binary: () -> String?
    private let queue: DispatchQueue
    private let reapQueue: DispatchQueue
    private let log: ThrottledLogger

    private var lastChange: (() -> Void)?
    private var child: Process?
    private var childPipe: Pipe?
    private var restartWork: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var stopping = false
    /// The monitor mode last written to the unified log. The mode lines sit on
    /// the restart path a crash loop drives once a second, so only a change is
    /// news; all state below is guarded by `queue`.
    private var lastEmittedMode: Mode?
    /// When the last subscribe-exit record was written. A crash loop restarts
    /// once a second, so that record is gated to one per minute.
    private var lastSubscribeExitLoggedAt: Date?

    /// How the monitor is watching the backend.
    private enum Mode {
        case subscribe
        case polling
    }

    /// Minimum spacing between subscribe-exit records in the unified log.
    private static let subscribeExitLogInterval: TimeInterval = 60

    init(label: String,
         subscribeLabel: String,
         subscribeArguments: [String],
         validatesJSON: Bool,
         hasIPC: @escaping () -> Bool,
         binary: @escaping () -> String?,
         queue: DispatchQueue,
         reapQueue: DispatchQueue,
         log: ThrottledLogger) {
        self.label = label
        self.subscribeLabel = subscribeLabel
        self.subscribeArguments = subscribeArguments
        self.validatesJSON = validatesJSON
        self.hasIPC = hasIPC
        self.binary = binary
        self.queue = queue
        self.reapQueue = reapQueue
        self.log = log
    }

    func start(onChange: @escaping () -> Void) {
        queue.async {
            self.lastChange = onChange
            self.stopping = false
            self.restartWork?.cancel()
            self.restartWork = nil
            self.begin(onChange)
        }
    }

    func restart() {
        queue.async {
            guard let change = self.lastChange else { return }
            self.stopping = false
            self.restartWork?.cancel()
            self.restartWork = nil
            self.terminateChild()
            let work = DispatchWorkItem { self.begin(change) }
            self.restartWork = work
            self.queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func stop() {
        queue.async {
            self.stopping = true
            self.restartWork?.cancel()
            self.restartWork = nil
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.terminateChild()
        }
    }

    private func begin(_ change: @escaping () -> Void) {
        guard !stopping else { return }
        if hasIPC() {
            startSubscribe(change)
        } else {
            startPolling(change)
        }
    }

    private func startSubscribe(_ change: @escaping () -> Void) {
        guard let binary = binary() else {
            log.emit("\(label) binary not found")
            startPolling(change)
            return
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = subscribeArguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Mutated from the readability handler below. Safe without a lock only
        // because Foundation serializes the invocations of one `FileHandle`'s
        // readability handler, so no two appends or line splits can interleave.
        var buffer = Data()
        // The subscribe handshake is a multi-line pretty-printed envelope, so
        // per-line JSON validation would swallow it; a poke is enough because
        // the refresh path debounces and diffs before rebuilding.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let text = String(data: line, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                    continue
                }
                if self.validatesJSON {
                    // AeroSpace answers with one JSON object per line, so a
                    // valid line is the poke signal there.
                    guard let payload = text.data(using: .utf8),
                          (try? JSONSerialization.jsonObject(with: payload)) != nil else {
                        continue
                    }
                }
                // The line was parsed on the pipe queue, but `stop()` may have
                // run since. `stopping` is owned by `queue`, so the check hops
                // there before the refresh reaches the main thread.
                self.queue.async {
                    guard !self.stopping else { return }
                    DispatchQueue.main.async { change() }
                }
            }
        }
        process.terminationHandler = { finished in
            self.queue.async {
                guard self.child === finished else { return }
                self.child = nil
                self.childPipe = nil
                guard !self.stopping else { return }
                RibbonCore.log("\(self.subscribeLabel) subscribe exited status=\(finished.terminationStatus), restarting")
                // A crash loop reaches this once a second. The file line above
                // still carries every iteration; the unified log gets one
                // record per minute, which is enough to prove the loop.
                let now = Date()
                let due = self.lastSubscribeExitLoggedAt.map {
                    now.timeIntervalSince($0) >= Self.subscribeExitLogInterval
                } ?? true
                if due {
                    self.lastSubscribeExitLoggedAt = now
                    Log.workspace.notice("\(self.subscribeLabel, privacy: .public) subscribe exited status=\(finished.terminationStatus, privacy: .public), restarting")
                }
                self.scheduleRestart(change)
            }
        }
        do {
            try process.run()
        } catch {
            log.emit("\(subscribeLabel) subscribe failed: \(error)")
            Log.workspace.error("\(self.subscribeLabel, privacy: .public) subscribe failed: \(error.localizedDescription, privacy: .private); falling back to polling")
            startPolling(change)
            return
        }
        child = process
        childPipe = pipe
        RibbonCore.log("monitoring via subscribe")
        logModeChange(.subscribe)
    }

    private func startPolling(_ change: @escaping () -> Void) {
        guard !stopping else { return }
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        // The timer fires on main and `stopping` belongs to `queue`, so each tick
        // hops to the serial queue to check liveness before calling out.
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.stopping else { return }
                DispatchQueue.main.async { change() }
            }
        }
        timer.resume()
        pollTimer = timer
        RibbonCore.log("monitoring via polling")
        logModeChange(.polling)
    }

    /// Writes the mode line, and only when the mode actually changed.
    ///
    /// Called on `queue` from the start/restart path, so the comparison and the
    /// assignment are serialized.
    private func logModeChange(_ mode: Mode) {
        guard lastEmittedMode != mode else { return }
        lastEmittedMode = mode
        switch mode {
        case .subscribe: Log.workspace.notice("monitoring via subscribe")
        case .polling: Log.workspace.notice("monitoring via polling")
        }
    }

    private func scheduleRestart(_ change: @escaping () -> Void) {
        restartWork?.cancel()
        let work = DispatchWorkItem { self.begin(change) }
        restartWork = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func terminateChild() {
        guard let process = child else { return }
        // The pid is captured before the child is detached from the state: it is
        // the only handle left once `child` is cleared.
        let pid = process.processIdentifier
        // Clearing the state first makes the termination handler's
        // `child === finished` guard fail, so a child we killed on purpose
        // never schedules a restart.
        child = nil
        childPipe?.fileHandleForReading.readabilityHandler = nil
        childPipe = nil

        // SIGTERM is a single kill(2) syscall, so it stays synchronous on this
        // queue and is delivered before shutdown() can let the app exit.
        if process.isRunning {
            process.terminate()
        }

        // Reap the child, otherwise it stays a zombie until the app exits. The
        // serial queue is held only for the state mutation and the SIGTERM
        // syscall; the bounded wait runs on `reapQueue`, so a workspace tap
        // issued right after a restart is not stuck behind it.
        reapQueue.async {
            let reaped = DispatchGroup()
            reaped.enter()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                reaped.leave()
            }
            if reaped.wait(timeout: .now() + 1) == .timedOut {
                // SIGTERM was ignored: escalate so the child cannot outlive us.
                _ = kill(pid, SIGKILL)
                _ = reaped.wait(timeout: .now() + 1)
            }
        }
    }
}
