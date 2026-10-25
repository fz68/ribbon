import Foundation

/// Guards the log file and its open handle.
private let logLock = NSLock()

/// The file the log is written to.
///
/// Defaults to RIBBON_LOG_PATH when that is set, otherwise
/// ~/Library/Logs/ribbon.log. Assign `Log.path` to redirect it.
private var logPath: String = {
    let fallback = NSString(string: "~/Library/Logs/ribbon.log").expandingTildeInPath
    guard let value = ProcessInfo.processInfo.environment["RIBBON_LOG_PATH"], !value.isEmpty else {
        return fallback
    }
    return NSString(string: value).expandingTildeInPath
}()

/// The open handle for `logPath`. It is reopened when the file goes missing.
private var logHandle: FileHandle?

/// Where the log is written.
///
/// Overridable so tests can redirect it. The default comes from
/// RIBBON_LOG_PATH and falls back to ~/Library/Logs/ribbon.log.
enum Log {
    static var path: String {
        get {
            logLock.lock()
            defer { logLock.unlock() }
            return logPath
        }
        set {
            logLock.lock()
            defer { logLock.unlock() }
            logPath = newValue
            closeLogHandle()
        }
    }
}

/// Closes the cached handle. The caller must hold `logLock`.
private func closeLogHandle() {
    logHandle?.closeFile()
    logHandle = nil
}

/// Opens the log file, creating the directory and the file when needed.
/// The caller must hold `logLock`.
private func openLogHandle() -> FileHandle? {
    if let handle = logHandle { return handle }
    let dir = (logPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: logPath) else { return nil }
    logHandle = handle
    return handle
}

/// Writes one line to the log file and to stderr.
func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let data = Data(line.utf8)
    logLock.lock()
    defer { logLock.unlock() }
    FileHandle.standardError.write(data)
    // The user may have deleted the log file. That leaves the open handle
    // pointing at an unlinked inode, so drop it and let the file be recreated.
    if !FileManager.default.fileExists(atPath: logPath) {
        closeLogHandle()
    }
    guard let handle = openLogHandle() else { return }
    // A long-lived handle stays at its own offset, so the seek is what keeps
    // the log appending instead of overwriting itself from byte 0.
    handle.seekToEndOfFile()
    handle.write(data)
}
