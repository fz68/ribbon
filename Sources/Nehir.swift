import Foundation
import Darwin

/// The Nehir window-manager backend.
///
/// Nehir exposes an IPC server that the `nehirctl` CLI speaks to over a Unix
/// socket. The CLI handles socket discovery and auth itself, so Ribbon only
/// ever spawns `nehirctl` and reads its stdout. The binary lives in the two
/// Homebrew prefixes and in user-local dirs, and unlike AeroSpace both `PATH`
/// and those dirs must be searched.
enum Nehir {
    /// The most app icons one workspace chip shows.
    static let maxAppsPerWorkspace = 3

    static let queue = DispatchQueue(label: "local.ribbon.nehir")
    static let reapQueue = DispatchQueue(label: "local.ribbon.nehir.reap", qos: .utility)
    private static let errorLock = NSLock()
    private static let focusMapLock = NSLock()

    /// Chip labels are Nehir display names, but `focus-name` reads numeric
    /// input as a raw workspace ID, so a label like "3" can silently focus the
    /// wrong workspace. The last successful list() rewrites only unambiguous
    /// numeric-ID labels back to their raw IDs; everything else passes through
    /// and Nehir matches it itself.
    static var rawNamesByDisplayName: [String: String] = [:]

    /// Test hook: when non-nil, used instead of the discovered binary.
    static var binaryOverride: String?

    /// Nehir installs into user-local dirs or Homebrew, so both `PATH` and
    /// those directories are searched.
    private static let nehirPrefixes: [String] = [
        "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/bin",
    ]

    /// The `nehirctl` CLI, discovered from the standard install locations.
    static var binary: String? {
        binaryOverride ?? ToolLocator.find("nehirctl", searchPATH: true, prefixes: nehirPrefixes)
    }

    /// One-time probe for IPC availability via `nehirctl ping`.
    static let hasIPC: Bool = {
        guard let binary else { return false }
        let result = ProcessRunner.run(binary, ["ping"], timeout: 3)
        return result.launchError == nil && !result.timedOut && result.status == 0
    }()

    static var lastChange: (() -> Void)?
    static var child: Process?
    static var childPipe: Pipe?
    static var restartWork: DispatchWorkItem?
    static var pollTimer: DispatchSourceTimer?
    static var stopping = false
    private static var lastErrorLog = Date.distantPast

    static func list() -> [Workspace]? {
        guard let binary else {
            logThrottled("nehirctl binary not found")
            return nil
        }
        guard let all = run(binary, [
            "query", "workspaces",
            "--fields", "raw-name,display-name,is-current",
            "--format", "json",
        ]) else {
            return nil
        }
        let entries = workspaceEntries(all)
        guard !entries.isEmpty else { return nil }
        let windows = windowsByWorkspace(binary)
        // A chip label always equals Nehir's effective display name, so
        // passing it through to focus-name resolves - EXCEPT a numeric label,
        // which focus-name reads as a raw workspace ID and can silently focus
        // the wrong workspace. The map rewrites only unambiguous numeric-ID
        // labels; ambiguous ones pass through and Nehir rejects them loudly.
        // The lock replaces a queue hop: list() must never wait behind a
        // focus() call that can hold the queue for a whole CLI timeout.
        var map: [String: String] = [:]
        var seen: Set<String> = []
        var ambiguous: Set<String> = []
        for entry in entries {
            guard Int(entry.rawName) != nil else { continue }
            if !seen.insert(entry.name).inserted { ambiguous.insert(entry.name) }
            map[entry.name] = entry.rawName
        }
        for name in ambiguous { map[name] = nil }
        focusMapLock.lock()
        rawNamesByDisplayName = map
        focusMapLock.unlock()
        return entries.map {
            Workspace(name: $0.name, isFocused: $0.isFocused,
                       apps: windows[$0.rawName] ?? [])
        }
    }

    /// Parses the JSON produced by
    /// `query workspaces --fields raw-name,display-name,is-current --format json`.
    ///
    /// We request `is-current` because it is the interaction monitor's active
    /// workspace - the chip-highlight semantics - while Nehir's `is-focused`
    /// can be true for zero workspaces. Unrequested keys are absent from each
    /// item, so values fall back defensively: the chip name uses `displayName`
    /// when non-empty, else the canonical `rawName`.
    static func workspaceEntries(_ data: Data) -> [(name: String, rawName: String, isFocused: Bool)] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (top["ok"] as? Bool) == true,
              let result = top["result"] as? [String: Any],
              let payload = result["payload"] as? [String: Any],
              let items = payload["workspaces"] as? [[String: Any]]
        else { return [] }
        var entries: [(name: String, rawName: String, isFocused: Bool)] = []
        for item in items {
            guard let rawName = item["rawName"] as? String, !rawName.isEmpty else { continue }
            let display = item["displayName"] as? String
            let name = display.flatMap { $0.isEmpty ? nil : $0 } ?? rawName
            entries.append((name: name, rawName: rawName,
                            isFocused: item["isCurrent"] as? Bool ?? false))
        }
        return entries
    }

    private static func windowsByWorkspace(_ binary: String) -> [String: [String]] {
        guard let data = run(binary, [
            "query", "windows",
            "--fields", "workspace,app",
            "--format", "json",
        ]) else {
            return [:]
        }
        return windowsByWorkspace(from: data)
    }

    /// Parses the JSON produced by
    /// `query windows --fields workspace,app --format json`.
    ///
    /// Each workspace keeps its apps deduped, sorted, and capped at
    /// `maxAppsPerWorkspace`. A row is skipped when its `workspace.rawName` is
    /// missing, or when `app` is absent, which happens when Nehir does not
    /// know the app name.
    static func windowsByWorkspace(from data: Data) -> [String: [String]] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (top["ok"] as? Bool) == true,
              let result = top["result"] as? [String: Any],
              let payload = result["payload"] as? [String: Any],
              let items = payload["windows"] as? [[String: Any]]
        else { return [:] }
        var grouped: [String: Set<String>] = [:]
        for item in items {
            guard let workspace = item["workspace"] as? [String: Any],
                  let rawName = workspace["rawName"] as? String, !rawName.isEmpty,
                  let app = item["app"] as? [String: Any],
                  let name = app["name"] as? String, !name.isEmpty
            else { continue }
            grouped[rawName, default: []].insert(name)
        }
        return grouped.mapValues { Array($0.sorted().prefix(maxAppsPerWorkspace)) }
    }

    /// Focuses a workspace by name.
    ///
    /// The completion runs on the main queue and reports whether the command
    /// succeeded, so the caller can undo an optimistic highlight.
    static func focus(_ name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            guard let binary else {
                logThrottled("nehirctl binary not found")
                DispatchQueue.main.async { completion?(false) }
                return
            }
            // Resolve the chip label through the map built by the last
            // successful list(); on a cold start the label passes through and
            // Nehir does a display-name match itself.
            focusMapLock.lock()
            let target = rawNamesByDisplayName[name]
            focusMapLock.unlock()
            let succeeded = run(binary, ["workspace", "focus-name", target ?? name]) != nil
            DispatchQueue.main.async { completion?(succeeded) }
        }
    }

    static func run(_ binary: String, _ arguments: [String]) -> Data? {
        let result = ProcessRunner.run(binary, arguments, timeout: 5)
        if result.timedOut {
            logThrottled("nehirctl \(arguments.joined(separator: " ")) timed out")
            return nil
        }
        if let error = result.launchError {
            logThrottled("nehirctl \(arguments.joined(separator: " ")) failed: \(error)")
            return nil
        }
        guard result.status == 0 else {
            logThrottled("nehirctl \(arguments.joined(separator: " ")) exited \(result.status)")
            return nil
        }
        return result.stdout
    }

    static func logThrottled(_ message: String) {
        errorLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastErrorLog) >= 60 else {
            errorLock.unlock()
            return
        }
        lastErrorLog = now
        errorLock.unlock()
        log(message)
    }
}
