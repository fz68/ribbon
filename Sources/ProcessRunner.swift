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

/// Holds the raw `waitpid` status captured by the reap job, or nil while the
/// child has not been reaped yet. Optional so "no status" can never
/// masquerade as a real exit 0.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Int32?

    func store(_ value: Int32) {
        lock.lock()
        raw = value
        lock.unlock()
    }

    var value: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}

/// Decodes Darwin's wait encoding the same way `Process.terminationStatus`
/// does: exit code in the high bits, signal number in the low seven.
private func terminationCode(_ raw: Int32) -> Int32 {
    let sig = raw & 0x7f
    return sig == 0 ? (raw >> 8) & 0xff : sig
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
/// reader is abandoned through a stop flag instead of being leaked; the reader
/// thread closes its own fd once it stops.
enum ProcessRunner {
    /// The workers run concurrently, so one stuck reader never blocks the next run.
    private static let workers = DispatchQueue(label: "local.ribbon.process",
                                               qos: .utility,
                                               attributes: .concurrent)

    /// Shared write-only /dev/null for child stdin/stderr; opened once, never
    /// closed.
    private static let devNullFD: Int32 = open("/dev/null", O_WRONLY)

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
        // Raw fds, not Foundation's Pipe: Pipe's deinit closes its descriptors,
        // which would race both the spawn and the reader thread below.
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            return ProcessResult(status: -1, stdout: Data(), timedOut: false,
                                 launchError: "pipe(2) failed errno=\(errno)")
        }
        let (readFD, writeFD) = (fds[0], fds[1])

        var fileActions: posix_spawn_file_actions_t? = nil
        var attrs: posix_spawnattr_t? = nil
        _ = posix_spawn_file_actions_init(&fileActions)
        _ = posix_spawnattr_init(&attrs)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attrs)
        }
        // stdout is the pipe; stdin and stderr go to /dev/null so stderr can
        // never leak into stdout (several callers parse stdout).
        _ = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
        if devNullFD >= 0 {
            _ = posix_spawn_file_actions_adddup2(&fileActions, devNullFD, STDIN_FILENO)
            _ = posix_spawn_file_actions_adddup2(&fileActions, devNullFD, STDERR_FILENO)
        }
        // Match Foundation: own process group, and no inherited fds beyond the
        // ones dup2'd above.
        _ = posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        guard let cPath = strdup(executable) else {
            close(readFD); close(writeFD)
            return ProcessResult(status: -1, stdout: Data(), timedOut: false,
                                 launchError: "strdup failed for \(executable)")
        }
        var cArgs: [UnsafeMutablePointer<CChar>?] = [cPath]
        cArgs.append(contentsOf: arguments.map { strdup($0) })
        cArgs.append(nil)
        // A nil in the middle would truncate argv at that element.
        if cArgs.dropLast().contains(where: { $0 == nil }) {
            cArgs.forEach { free($0) }
            close(readFD); close(writeFD)
            return ProcessResult(status: -1, stdout: Data(), timedOut: false,
                                 launchError: "strdup failed for an argument")
        }
        var pid: pid_t = 0
        let rc = withUnsafePointer(to: fileActions) { faPtr in
            withUnsafePointer(to: attrs) { attrPtr in
                cArgs.withUnsafeBufferPointer { argvPtr in
                    posix_spawn(&pid, cPath, faPtr, attrPtr,
                                argvPtr.baseAddress, environ)
                }
            }
        }
        cArgs.forEach { free($0) }
        // Drop the parent's write end so the reader sees EOF once the child
        // (and any grandchild holding a dup) is gone.
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            // On Darwin posix_spawn returns the errno itself.
            return ProcessResult(status: -1, stdout: Data(), timedOut: false,
                                 launchError: "posix_spawn errno=\(rc)")
        }

        let status = StatusBox()
        let collector = OutputCollector()
        let stopReading = StopFlag()
        let readFinished = DispatchGroup()
        readFinished.enter()
        // Drain the pipe right away: a child that writes more than the pipe
        // buffer holds would block forever if nobody read. The fd is polled
        // non-blocking so the reader can be abandoned when a grandchild keeps
        // the write end open after the child itself is gone.
        workers.async {
            let fd = readFD
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
            close(fd)
            readFinished.leave()
        }

        let childExited = DispatchGroup()
        childExited.enter()
        workers.async {
            // This job is the only waiter that ever calls waitpid on the
            // child, so the status is captured exactly once and never raced
            // for. EINTR can interrupt the blocking wait, so it is retried.
            var raw: Int32 = 0
            var r: pid_t = -1
            repeat { r = waitpid(pid, &raw, 0) } while r < 0 && errno == EINTR
            if r > 0 { status.store(raw) }
            childExited.leave()
        }

        // `timedOut` means "the child did not finish before the deadline".
        let deadline = DispatchTime.now() + .nanoseconds(Int(timeout * 1_000_000_000))
        var timedOut = false
        if childExited.wait(timeout: deadline) == .timedOut { timedOut = true }

        if timedOut, status.value == nil {
            // Not reaped yet means the pid is still valid - the child is alive
            // or a zombie at worst - so the signal cannot hit a recycled pid.
            _ = kill(pid, SIGTERM)
            if childExited.wait(timeout: .now() + terminationGrace) == .timedOut {
                _ = kill(pid, SIGKILL)
                _ = childExited.wait(timeout: .now() + terminationGrace)
            }
        }

        // The reader is abandoned via the stop flag and then closes its own
        // fd (closing an fd another thread is blocked in `read()` on is not
        // reliable on Darwin).
        if readFinished.wait(timeout: .now() + readGrace) == .timedOut {
            stopReading.set()
            _ = readFinished.wait(timeout: .now() + readGrace)
        }

        // The status is only valid once the child has been reaped; an
        // uncaptured status can never be reported as a real exit 0.
        guard childExited.wait(timeout: .now() + terminationGrace) == .success,
              let raw = status.value else {
            return ProcessResult(status: -1, stdout: collector.snapshot(), timedOut: true,
                                 launchError: nil)
        }
        return ProcessResult(status: terminationCode(raw),
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
