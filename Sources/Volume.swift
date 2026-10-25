import Foundation

/// Output volume control through a single AppleScript invocation.
enum Volume {
    /// Adds `delta` to the output volume (clamped to 0...100) and returns the new value.
    /// Synchronous: callers must run it off the main thread. Returns nil on failure.
    static func adjust(by delta: Int) -> Int? {
        let script = """
        set v to (output volume of (get volume settings)) + (\(delta))
        if v > 100 then set v to 100
        if v < 0 then set v to 0
        set volume output volume v
        return v
        """
        let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 5)
        guard !result.timedOut,
              result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(text) else { return nil }
        return min(max(value, 0), 100)
    }
}
