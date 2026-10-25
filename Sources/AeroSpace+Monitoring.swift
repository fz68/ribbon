import Foundation
import Darwin

extension AeroSpace {
    static func startMonitoring(onChange: @escaping () -> Void) {
        queue.async {
            lastChange = onChange
            stopping = false
            restartWork?.cancel()
            restartWork = nil
            begin(onChange)
        }
    }

    static func restartMonitoring() {
        queue.async {
            guard let change = lastChange else { return }
            stopping = false
            restartWork?.cancel()
            restartWork = nil
            terminateChild()
            let work = DispatchWorkItem { begin(change) }
            restartWork = work
            queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    static func stopMonitoring() {
        queue.async {
            stopping = true
            restartWork?.cancel()
            restartWork = nil
            pollTimer?.cancel()
            pollTimer = nil
            terminateChild()
        }
    }

    private static func begin(_ change: @escaping () -> Void) {
        guard !stopping else { return }
        if hasSubscribe {
            startSubscribe(change)
        } else {
            startPolling(change)
        }
    }

    private static func startSubscribe(_ change: @escaping () -> Void) {
        guard let binary else {
            logThrottled("aerospace binary not found")
            startPolling(change)
            return
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "subscribe",
            "focused-workspace-changed",
            "window-detected",
            "focused-monitor-changed",
            "focus-changed",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
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
                    .trimmingCharacters(in: .whitespaces), !text.isEmpty,
                    let payload = text.data(using: .utf8),
                    (try? JSONSerialization.jsonObject(with: payload)) != nil else {
                    continue
                }
                DispatchQueue.main.async { change() }
            }
        }
        process.terminationHandler = { finished in
            queue.async {
                guard child === finished else { return }
                child = nil
                childPipe = nil
                guard !stopping else { return }
                log("aerospace subscribe exited status=\(finished.terminationStatus), restarting")
                scheduleRestart(change)
            }
        }
        do {
            try process.run()
        } catch {
            logThrottled("aerospace subscribe failed: \(error)")
            startPolling(change)
            return
        }
        child = process
        childPipe = pipe
        log("monitoring via subscribe")
    }

    private static func startPolling(_ change: @escaping () -> Void) {
        guard !stopping else { return }
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { change() }
        timer.resume()
        pollTimer = timer
        log("monitoring via polling")
    }

    private static func scheduleRestart(_ change: @escaping () -> Void) {
        restartWork?.cancel()
        let work = DispatchWorkItem { begin(change) }
        restartWork = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private static func terminateChild() {
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
