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

    /// The helper path, or nil when the helper is not installed.
    static var toolPath: String? = ToolLocator.find("nowplaying-cli", searchPATH: true)

    /// Serial queue so transport commands keep their order and never block the UI.
    private static let commandQueue = DispatchQueue(label: "local.ribbon.media.command")

    private static let logLock = NSLock()
    private static var didLogTool = false
    private static var didLogRaw = false
    private static var didLogMissing = false

    // MARK: - State

    /// Reads the current playback state.
    ///
    /// Returns nil when the state is completely unknown (the helper is not installed),
    /// otherwise a value telling whether the state could be read and whether media is
    /// currently playing.
    static func state() -> MediaState? {
        guard let tool = toolPath else {
            logOnce("media helper not found, falling back to media keys")
            return nil
        }
        logTool(tool)
        guard let raw = capture(tool, ["get-raw"]) else {
            logOnce("media state unavailable")
            return MediaState(available: false, isPlaying: false)
        }
        logRaw(raw)
        return MediaState(available: true, isPlaying: parseIsPlaying(raw))
    }

    /// Sends a transport command through the helper, or as a media key when the
    /// helper is not installed.
    static func command(_ command: MediaCommand) {
        guard let tool = toolPath else {
            postMediaKey(for: command)
            return
        }
        logTool(tool)
        commandQueue.async {
            _ = capture(tool, [command.toolArgument])
        }
    }

    // MARK: - Internals

    /// Interprets the helper output.
    ///
    /// The helper reports a JSON dictionary of the now playing properties, where
    /// `playbackRate` is above zero while media is playing. Plain text output is
    /// scanned for a playing / paused token as a fallback.
    static func parseIsPlaying(_ raw: String) -> Bool {
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
        let result = ProcessRunner.run(tool, arguments, timeout: timeout)
        guard !result.timedOut, result.status == 0 else { return nil }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    /// Posts a media key event to the session when the helper is not installed.
    private static func postMediaKey(for command: MediaCommand) {
        let keyCode: CGKeyCode
        switch command {
        case .playPause: keyCode = 16 // kVK_Play
        case .next: keyCode = 17 // kVK_Next
        case .previous: keyCode = 18 // kVK_Previous
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
