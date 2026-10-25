import Foundation
import Darwin

enum AeroSpace {
    /// The most app icons one workspace chip shows.
    static let maxAppsPerWorkspace = 3

    static let queue = DispatchQueue(label: "local.ribbon.aerospace")
    static let reapQueue = DispatchQueue(label: "local.ribbon.aerospace.reap", qos: .utility)
    private static let errorLock = NSLock()

    /// Test hook: when non-nil, used instead of the discovered binary.
    static var binaryOverride: String?

    /// The AeroSpace CLI. Only the two Homebrew prefixes are searched, never
    /// `$PATH`, so the app always drives the install the user set up.
    static var binary: String? { binaryOverride ?? ToolLocator.find("aerospace", searchPATH: false) }

    // Feature probe: `subscribe --help` exits 0 on versions that support events.
    // A launch failure and a timeout both mean "no subscribe".
    static let hasSubscribe: Bool = {
        guard let binary else { return false }
        let result = ProcessRunner.run(binary, ["subscribe", "--help"], timeout: 3)
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
            logThrottled("aerospace binary not found")
            return nil
        }
        // A single call carries the workspace names and the focused flag.
        guard let all = run(binary, ["list-workspaces", "--all", "--format", "%{workspace}|%{workspace-is-focused}"]) else {
            return nil
        }
        let entries = workspaceEntries(all)
        guard !entries.isEmpty else { return nil }
        let windows = windowsByWorkspace(binary)
        return entries.map {
            Workspace(name: $0.name, isFocused: $0.isFocused, apps: windows[$0.name] ?? [])
        }
    }

    /// Parses the `name|isFocused` lines produced by
    /// `list-workspaces --all --format '%{workspace}|%{workspace-is-focused}'`.
    static func workspaceEntries(_ data: Data) -> [(name: String, isFocused: Bool)] {
        var entries: [(name: String, isFocused: Bool)] = []
        for line in lines(data) {
            guard let separator = line.firstIndex(of: "|") else { continue }
            let name = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let flag = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !name.isEmpty else { continue }
            entries.append((name: name, isFocused: flag == "true"))
        }
        return entries
    }

    private static func windowsByWorkspace(_ binary: String) -> [String: [String]] {
        guard let data = run(binary, ["list-windows", "--all", "--format", "%{workspace}|%{app-name}"]) else {
            return [:]
        }
        return windowsByWorkspace(from: data)
    }

    /// Parses the `workspace|app` lines produced by
    /// `list-windows --all --format '%{workspace}|%{app-name}'`.
    ///
    /// Each workspace keeps its apps deduped, sorted, and capped at
    /// `maxAppsPerWorkspace`.
    static func windowsByWorkspace(from data: Data) -> [String: [String]] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: Set<String>] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "|") else { continue }
            let workspace = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let app = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !workspace.isEmpty, !app.isEmpty else { continue }
            result[workspace, default: []].insert(app)
        }
        return result.mapValues { Array($0.sorted().prefix(maxAppsPerWorkspace)) }
    }

    /// Focuses a workspace.
    ///
    /// The completion runs on the main queue and reports whether the command
    /// succeeded, so the caller can undo an optimistic highlight.
    static func focus(_ name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            guard let binary else {
                logThrottled("aerospace binary not found")
                DispatchQueue.main.async { completion?(false) }
                return
            }
            // `run` returns nil when the command timed out, failed to start or
            // exited with a non-zero status.
            let succeeded = run(binary, ["workspace", "--", name]) != nil
            DispatchQueue.main.async { completion?(succeeded) }
        }
    }

    static func run(_ binary: String, _ arguments: [String]) -> Data? {
        let result = ProcessRunner.run(binary, arguments, timeout: 5)
        if result.timedOut {
            logThrottled("aerospace \(arguments.joined(separator: " ")) timed out")
            return nil
        }
        if let error = result.launchError {
            logThrottled("aerospace \(arguments.joined(separator: " ")) failed: \(error)")
            return nil
        }
        guard result.status == 0 else {
            logThrottled("aerospace \(arguments.joined(separator: " ")) exited \(result.status)")
            return nil
        }
        return result.stdout
    }

    static func lines(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    /// Test hook: re-arms the throttle gate, so the next call always writes.
    static func resetLogThrottleForTesting() {
        errorLock.lock()
        lastErrorLog = Date.distantPast
        errorLock.unlock()
    }
}
