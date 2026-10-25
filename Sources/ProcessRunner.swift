import Foundation
import Darwin

/// The outcome of a child process that ran under `ProcessRunner`.
struct ProcessResult {
    /// The child's exit status. Non-zero when the child failed or was killed.
    let status: Int32
    /// Everything the child wrote to stdout.
    let stdout: Data
    /// True when the child did not finish before the deadline and was killed.
    let timedOut: Bool
    /// The error from `Process.run()` when the child could not be started; nil when it actually ran.
    let launchError: String?
}

/// Collects stdout while the child runs.
///
/// The reader thread owns the pipe and the caller only ever sees a consistent
/// snapshot, so an abandoned reader can never tear the result.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    /// Appends a chunk the reader has taken off the pipe.
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(chunk)
    }

    /// A consistent copy of everything collected so far.
    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

/// Runs short-lived child processes.
///
/// Every run drains stdout continuously, so a chatty child can never block on a
/// full pipe. Every run is bounded: a child that hangs is terminated and killed,
/// and is reaped on every path. Should the post-SIGKILL wait still time out, the
/// OS reaps the child when it finally exits.
enum ProcessRunner {
    /// The workers run concurrently, so one stuck reader never blocks the next run.
    private static let workers = DispatchQueue(label: "local.ribbon.process",
                                               qos: .utility,
                                               attributes: .concurrent)

    /// How long a killed child gets to die after SIGTERM before it is SIGKILLed.
    private static let terminationGrace: TimeInterval = 0.25

    /// Runs `executable` and waits for it.
    ///
    /// Blocking: never call this on the main thread. The read and the exit are
    /// both bounded by `timeout`; when the deadline passes the child is
    /// terminated, killed and reaped, and the result is marked as timed out.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr stays out of stdout: several callers parse stdout.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: Data(), timedOut: false,
                                 launchError: String(describing: error))
        }

        let collector = OutputCollector()
        let readFinished = DispatchGroup()
        readFinished.enter()
        // Drain the pipe right away: a child that writes more than the pipe
        // buffer holds would block forever if nobody read.
        workers.async {
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collector.append(chunk)
            }
            readFinished.leave()
        }

        let childExited = DispatchGroup()
        childExited.enter()
        // waitUntilExit() is the reap. It runs on its own thread so the caller
        // can bound it instead of blocking forever.
        workers.async {
            process.waitUntilExit()
            childExited.leave()
        }

        // One deadline covers the child's exit and the end of the read: a child
        // that leaves a grandchild holding stdout keeps the pipe open forever,
        // so a timeout on the child alone would not be enough.
        let deadline = DispatchTime.now() + .nanoseconds(Int(timeout * 1_000_000_000))
        var timedOut = false
        if readFinished.wait(timeout: deadline) == .timedOut { timedOut = true }
        if childExited.wait(timeout: deadline) == .timedOut { timedOut = true }

        if timedOut, process.isRunning {
            process.terminate()
            if childExited.wait(timeout: .now() + terminationGrace) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = childExited.wait(timeout: .now() + terminationGrace)
            }
        }

        // The status is only valid once the child has been reaped.
        guard childExited.wait(timeout: .now() + terminationGrace) == .success else {
            return ProcessResult(status: -1, stdout: collector.snapshot(), timedOut: true,
                                 launchError: nil)
        }
        return ProcessResult(status: process.terminationStatus,
                             stdout: collector.snapshot(),
                             timedOut: timedOut,
                             launchError: nil)
    }

    /// Runs `executable` without blocking the caller.
    ///
    /// Safe from the main thread: the run happens on a background queue, so the
    /// child is still drained, bounded and reaped.
    ///
    /// The completion runs on the worker queue once the run has finished, so it
    /// may call `log()` directly.
    static func runDetached(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5,
                            completion: ((ProcessResult) -> Void)? = nil) {
        workers.async {
            let result = run(executable, arguments, timeout: timeout)
            completion?(result)
        }
    }
}
