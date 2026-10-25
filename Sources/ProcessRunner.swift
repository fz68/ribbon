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

/// Tells the pipe reader to stop waiting for EOF.
///
/// A blocking `read(2)` cannot be abandoned, so the reader polls a non-blocking
/// fd and checks this flag between polls.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    /// True once the reader has been told to give up.
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Tells the reader to give up.
    func set() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

/// Runs short-lived child processes.
///
/// Every run drains stdout continuously, so a chatty child can never block on a
/// full pipe. Every run is bounded: the child's exit is bounded by `timeout`, a
/// child that hangs is terminated and killed, and it is reaped on every path.
/// Should the post-SIGKILL wait still time out, the OS reaps the child when it
/// finally exits.
///
/// The read is bounded by `timeout` plus a short grace. A grandchild that
/// inherits the write end keeps the pipe open after the child is gone, so the
/// reader is abandoned through a stop flag instead of being leaked; the fd is
/// left to the OS rather than closed from another thread.
enum ProcessRunner {
    /// The workers run concurrently, so one stuck reader never blocks the next run.
    private static let workers = DispatchQueue(label: "local.ribbon.process",
                                               qos: .utility,
                                               attributes: .concurrent)

    /// How long a killed child gets to die after SIGTERM before it is SIGKILLed.
    private static let terminationGrace: TimeInterval = 0.25

    /// How long the reader gets to reach EOF after the child is gone.
    ///
    /// Deliberately larger than `terminationGrace`: the reader runs on a
    /// concurrent `.utility` queue, so abandoning it too eagerly would truncate
    /// the stdout of a healthy child. Only a grandchild holding the write end can
    /// keep the read alive this long.
    private static let readGrace: TimeInterval = 1.0

    /// Runs `executable` and waits for it.
    ///
    /// Blocking: never call this on the main thread. The child's exit is bounded
    /// by `timeout`; when the deadline passes the child is terminated, killed
    /// and reaped, and the result is marked as timed out.
    ///
    /// The read is bounded separately by `timeout` plus `readGrace`. The
    /// read may outlive the child when a grandchild holds the write end, so it
    /// is abandoned - never leaked - once that grace expires.
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
        let stopReading = StopFlag()
        let readFinished = DispatchGroup()
        readFinished.enter()
        // Drain the pipe right away: a child that writes more than the pipe
        // buffer holds would block forever if nobody read. The fd is polled
        // non-blocking so the reader can be abandoned when a grandchild keeps
        // the write end open after the child itself is gone.
        workers.async {
            let fd = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                if stopReading.isSet { break }
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    collector.append(Data(buffer[0..<Int(count)]))
                    continue
                }
                if count == 0 { break }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(2_000)
                    continue
                }
                break
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

        // `timedOut` means "the child did not finish before the deadline".
        let deadline = DispatchTime.now() + .nanoseconds(Int(timeout * 1_000_000_000))
        var timedOut = false
        if childExited.wait(timeout: deadline) == .timedOut { timedOut = true }

        if timedOut, process.isRunning {
            process.terminate()
            if childExited.wait(timeout: .now() + terminationGrace) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = childExited.wait(timeout: .now() + terminationGrace)
            }
        }

        // The read may legitimately outlive the child when a grandchild holds
        // the write end, so it gets its own short grace and is then abandoned
        // via the stop flag rather than by closing the fd from another thread
        // (closing an fd another thread is blocked in `read()` on is not
        // reliable on Darwin).
        if readFinished.wait(timeout: .now() + readGrace) == .timedOut {
            stopReading.set()
            _ = readFinished.wait(timeout: .now() + readGrace)
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
