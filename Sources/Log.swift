import Foundation
import os

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

/// The functional areas the unified log is split into.
///
/// One category per area, so a Console predicate can isolate a feature without
/// filtering message text. The raw values are the category names that show up
/// in `log stream` and in Console.
enum LogCategory: String {
    /// The opencode service, its event stream, and the agent chip and card.
    case agent
    /// Workspace monitoring and the workspace chips.
    case workspace
    /// Media transport, volume and brightness.
    case media
    /// The clock, the battery, the input source line and the Control Strip.
    case status
}

/// Where the log is written.
///
/// Overridable so tests can redirect it. The default comes from
/// RIBBON_LOG_PATH and falls back to ~/Library/Logs/ribbon.log.
enum Log {
    /// The unified log subsystem.
    ///
    /// A literal on purpose: `Bundle.main.bundleIdentifier` differs under the
    /// test bundle, and the subsystem of a Console predicate must stay stable
    /// across the app and its tests. It equals `CFBundleIdentifier` in
    /// `Resources/Info.plist`.
    static let subsystem = "local.fanzhen.ribbon"

    static var path: String {
        get { sharedLogSink.path }
        set { sharedLogSink.path = newValue }
    }

    // One `static let` per category: a shared logger is cheap and Sendable, and
    // building one per call site would defeat nothing but readability.

    /// The agent subsystem: opencode service discovery, the event stream, and
    /// the chip and card decisions.
    static let agent = os.Logger(subsystem: subsystem, category: LogCategory.agent.rawValue)
    /// Workspace monitoring, the monitor's restart cycle, and the chips.
    static let workspace = os.Logger(subsystem: subsystem, category: LogCategory.workspace.rawValue)
    /// Media transport, volume and brightness.
    static let media = os.Logger(subsystem: subsystem, category: LogCategory.media.rawValue)
    /// The clock, the battery, the input source line and the Control Strip.
    static let status = os.Logger(subsystem: subsystem, category: LogCategory.status.rawValue)
}

/// Writes one line to the log file and to stderr.
func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let data = Data(line.utf8)
    FileHandle.standardError.write(data)
    sharedLogSink.write(data)
}
