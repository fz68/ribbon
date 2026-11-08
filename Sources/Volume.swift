import Foundation
import os

/// Output volume control through a single AppleScript invocation.
enum Volume {
    /// Points of Interest signposts for the AppleScript call. Kept in release
    /// builds, where a slow `osascript` is exactly what needs measuring.
    private static let signposter = OSSignposter(subsystem: Log.subsystem, category: .pointsOfInterest)

    /// Adds `delta` to the output volume (clamped to 0...100) and returns the new value.
    /// Synchronous: callers must run it off the main thread. Returns nil on failure.
    ///
    /// - Parameter run: the process runner. Injected by tests; the real one by default.
    static func adjust(by delta: Int,
                       run: (String, [String], TimeInterval) -> ProcessResult? = ProcessRunner.run) -> Int? {
        let script = """
        set v to (output volume of (get volume settings)) + (\(delta))
        if v > 100 then set v to 100
        if v < 0 then set v to 0
        set volume output volume v
        return v
        """
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("VolumeAppleScript", id: signpostID)
        let result = run("/usr/bin/osascript", ["-e", script], 5)
        // One classification for the signpost and the guard below: the outcome
        // is what Instruments aggregates per row.
        let text = result.flatMap { String(data: $0.stdout, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.flatMap(Int.init)
        let outcome: String
        if let result {
            if result.timedOut {
                outcome = "timeout"
            } else if result.status != 0 {
                outcome = "status \(result.status)"
            } else if value != nil {
                outcome = "ok"
            } else {
                outcome = "unparsable"
            }
        } else {
            outcome = "no result"
        }
        signposter.endInterval("VolumeAppleScript", interval, "\(outcome, privacy: .public)")
        guard let result, !result.timedOut, result.status == 0, let value else { return nil }
        return min(max(value, 0), 100)
    }
}
