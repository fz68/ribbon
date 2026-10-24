import Cocoa

/// Media transport control for the Touch Bar.
///
/// Transport is driven by the external `nowplaying-cli` helper when it is installed
/// (looked up in the Homebrew prefixes and on PATH). When the helper is missing the
/// transport falls back to the standard media key events, which the system routes to
/// the current media session. No AppleScript, no MediaRemote and no Accessibility
/// permission are involved.
enum Media {
    // MARK: - Tool discovery

    /// Homebrew prefixes that are searched before PATH.
    private static let candidatePaths = [
        "/opt/homebrew/bin/nowplaying-cli",
        "/usr/local/bin/nowplaying-cli",
    ]

    /// The helper path, or nil when the helper is not installed.
    static let toolPath: String? = {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/nowplaying-cli"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }()

    /// Serial queue so transport commands keep their order and never block the UI.
    private static let commandQueue = DispatchQueue(label: "local.ribbon.media")

    private static let logLock = NSLock()
    private static var didLogTool = false
    private static var didLogRaw = false
    private static var didLogMissing = false

    // MARK: - State

    /// Reads the current playback state.
    ///
    /// Returns nil when the state is completely unknown (the helper is not installed),
    /// otherwise a tuple telling whether the state could be read and whether media is
    /// currently playing.
    static func state() -> (available: Bool, isPlaying: Bool)? {
        guard let tool = toolPath else {
            logOnce("media helper not found, falling back to media keys")
            return nil
        }
        logTool(tool)
        guard let raw = capture(tool, ["get-raw"]) else {
            logOnce("media state unavailable")
            return (available: false, isPlaying: false)
        }
        logRaw(raw)
        return (available: true, isPlaying: parseIsPlaying(raw))
    }

    /// Sends a transport command. Supported names: "play-pause", "next", "prev".
    static func command(_ name: String) {
        guard let tool = toolPath else {
            postMediaKey(for: name)
            return
        }
        logTool(tool)
        guard let argument = toolArgument(for: name) else { return }
        commandQueue.async {
            _ = capture(tool, [argument])
        }
    }

    // MARK: - Internals

    /// Maps the internal command names onto the helper's own verbs.
    private static func toolArgument(for name: String) -> String? {
        switch name {
        case "play-pause", "togglePlayPause": return "togglePlayPause"
        case "next": return "next"
        case "prev", "previous": return "previous"
        default: return nil
        }
    }

    /// Interprets the helper output.
    ///
    /// The helper reports a JSON dictionary of the now playing properties, where
    /// `playbackRate` is above zero while media is playing. Plain text output is
    /// scanned for a playing / paused token as a fallback.
    private static func parseIsPlaying(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let rate = object["playbackRate"] as? NSNumber {
                return rate.doubleValue > 0.01
            }
            // A payload without a playback rate means nothing is playing.
            return false
        }
        let lowered = text.lowercased()
        if lowered.contains("not playing") || lowered.contains("stopped") || lowered.contains("paused") {
            return false
        }
        if lowered.contains("playing") {
            return true
        }
        return false
    }

    /// Runs the helper and returns its stdout.
    private static func capture(_ tool: String, _ arguments: [String], timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            box.text = String(data: data, encoding: .utf8) ?? ""
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return box.text
    }

    /// Posts a media key event to the session when the helper is not installed.
    private static func postMediaKey(for name: String) {
        let keyCode: CGKeyCode
        switch name {
        case "play-pause": keyCode = 16 // kVK_Play
        case "next": keyCode = 17 // kVK_Next
        case "prev": keyCode = 18 // kVK_Previous
        default: return
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        log("media key posted code=\(keyCode)")
    }

    private static func logTool(_ tool: String) {
        logLock.lock()
        defer { logLock.unlock() }
        guard !didLogTool else { return }
        didLogTool = true
        log("media tool=\(tool)")
    }

    private static func logRaw(_ raw: String) {
        logLock.lock()
        defer { logLock.unlock() }
        guard !didLogRaw else { return }
        didLogRaw = true
        let flattened = raw
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        log("media raw=\(flattened.isEmpty ? "<empty>" : flattened)")
    }

    private static func logOnce(_ message: String) {
        logLock.lock()
        defer { logLock.unlock() }
        guard !didLogMissing else { return }
        didLogMissing = true
        log(message)
    }
}

/// Mutable box used to hand the captured output out of the reader thread.
private final class OutputBox: @unchecked Sendable {
    var text = ""
}
