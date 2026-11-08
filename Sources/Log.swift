import Foundation

/// The file half of the log: a path plus the handle appending to it.
///
/// The lock guards the path and the handle together, so a writer can be
/// redirected to another file while another thread is mid-write.
final class LogFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var storedPath: String

    init(path: String) {
        storedPath = path
    }

    /// The file the sink appends to.
    ///
    /// Assigning a new path closes the cached handle, so the next write opens
    /// the new file lazily at the new location.
    var path: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPath
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedPath = newValue
            closeHandle()
        }
    }

    /// Appends `data` to the log file.
    ///
    /// The directory and the file are created when they are missing. A file
    /// that cannot be opened drops this write silently.
    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        // The user may have deleted the log file. That leaves the open handle
        // pointing at an unlinked inode, so drop it and let the file be recreated.
        if !FileManager.default.fileExists(atPath: storedPath) {
            closeHandle()
        }
        guard let handle = openHandle() else { return }
        // A long-lived handle stays at its own offset, so the seek is what keeps
        // the log appending instead of overwriting itself from byte 0.
        handle.seekToEndOfFile()
        handle.write(data)
    }

    /// Closes the cached handle. The caller must hold `lock`.
    private func closeHandle() {
        handle?.closeFile()
        handle = nil
    }

    /// Opens the log file, creating the directory and the file when needed.
    /// The caller must hold `lock`.
    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let dir = (storedPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: storedPath) {
            FileManager.default.createFile(atPath: storedPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: storedPath) else { return nil }
        self.handle = handle
        return handle
    }
}

/// The process-wide sink behind `log(_:)`.
///
/// Defaults to RIBBON_LOG_PATH when that is set, otherwise
/// ~/Library/Logs/ribbon.log. Assign `Log.path` to redirect it.
private let sharedLogSink = LogFileSink(path: {
    let fallback = NSString(string: "~/Library/Logs/ribbon.log").expandingTildeInPath
    guard let value = ProcessInfo.processInfo.environment["RIBBON_LOG_PATH"], !value.isEmpty else {
        return fallback
    }
    return NSString(string: value).expandingTildeInPath
}())

/// Where the log is written.
///
/// Overridable so tests can redirect it. The default comes from
/// RIBBON_LOG_PATH and falls back to ~/Library/Logs/ribbon.log.
enum Log {
    static var path: String {
        get { sharedLogSink.path }
        set { sharedLogSink.path = newValue }
    }
}

/// Writes one line to the log file and to stderr.
func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let data = Data(line.utf8)
    FileHandle.standardError.write(data)
    sharedLogSink.write(data)
}
