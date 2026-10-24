import Foundation

struct Workspace: Equatable {
    let name: String
    let isFocused: Bool
    let apps: [String]
}

enum AeroSpace {
    private static let candidatePaths = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    private static let queue = DispatchQueue(label: "local.ribbon.aerospace")
    private static let errorLock = NSLock()

    private static let binary: String? = candidatePaths.first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    // Feature probe: `subscribe --help` exits 0 on versions that support events.
    private static let hasSubscribe: Bool = {
        guard let binary else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["subscribe", "--help"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    private static var lastChange: (() -> Void)?
    private static var child: Process?
    private static var childPipe: Pipe?
    private static var restartWork: DispatchWorkItem?
    private static var pollTimer: DispatchSourceTimer?
    private static var stopping = false
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
    private static func workspaceEntries(_ data: Data) -> [(name: String, isFocused: Bool)] {
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
        guard let data = run(binary, ["list-windows", "--all", "--format", "%{workspace}|%{app-name}"]),
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }
        var result: [String: Set<String>] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "|") else { continue }
            let workspace = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let app = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !workspace.isEmpty, !app.isEmpty else { continue }
            result[workspace, default: []].insert(app)
        }
        return result.mapValues { Array($0.sorted().prefix(3)) }
    }

    static func focus(_ name: String) {
        queue.async {
            guard let binary else {
                logThrottled("aerospace binary not found")
                return
            }
            _ = run(binary, ["workspace", name])
        }
    }

    static func startMonitoring(onChange: @escaping () -> Void) {
        queue.async {
            lastChange = onChange
            stopping = false
            restartWork?.cancel()
            restartWork = nil
            begin(onChange)
        }
    }

    static func restartMonitoring() {
        queue.async {
            guard let change = lastChange else { return }
            stopping = false
            restartWork?.cancel()
            restartWork = nil
            terminateChild()
            let work = DispatchWorkItem { begin(change) }
            restartWork = work
            queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    static func stopMonitoring() {
        queue.async {
            stopping = true
            restartWork?.cancel()
            restartWork = nil
            pollTimer?.cancel()
            pollTimer = nil
            terminateChild()
        }
    }

    private static func begin(_ change: @escaping () -> Void) {
        guard !stopping else { return }
        if hasSubscribe {
            startSubscribe(change)
        } else {
            startPolling(change)
        }
    }

    private static func startSubscribe(_ change: @escaping () -> Void) {
        guard let binary else {
            logThrottled("aerospace binary not found")
            startPolling(change)
            return
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "subscribe",
            "focused-workspace-changed",
            "window-detected",
            "focused-monitor-changed",
            "focus-changed",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let text = String(data: line, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces), !text.isEmpty,
                    let payload = text.data(using: .utf8),
                    (try? JSONSerialization.jsonObject(with: payload)) != nil else {
                    continue
                }
                DispatchQueue.main.async { change() }
            }
        }
        process.terminationHandler = { finished in
            queue.async {
                guard child === finished else { return }
                child = nil
                childPipe = nil
                guard !stopping else { return }
                log("aerospace subscribe exited status=\(finished.terminationStatus), restarting")
                scheduleRestart(change)
            }
        }
        do {
            try process.run()
        } catch {
            logThrottled("aerospace subscribe failed: \(error)")
            startPolling(change)
            return
        }
        child = process
        childPipe = pipe
        log("monitoring via subscribe")
    }

    private static func startPolling(_ change: @escaping () -> Void) {
        guard !stopping else { return }
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { change() }
        timer.resume()
        pollTimer = timer
        log("monitoring via polling")
    }

    private static func scheduleRestart(_ change: @escaping () -> Void) {
        restartWork?.cancel()
        let work = DispatchWorkItem { begin(change) }
        restartWork = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private static func terminateChild() {
        guard let process = child else { return }
        child = nil
        childPipe?.fileHandleForReading.readabilityHandler = nil
        childPipe = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private static func run(_ binary: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logThrottled("aerospace \(arguments.joined(separator: " ")) failed: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logThrottled("aerospace \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
            return nil
        }
        return data
    }

    private static func lines(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func logThrottled(_ message: String) {
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
