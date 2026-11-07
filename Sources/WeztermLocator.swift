import Foundation

/// One WezTerm pane as `wezterm cli list --format json` reports it.
///
/// Only the fields the jump needs are kept. `cmdline` is decoded as an array of
/// argv strings, as a single string, or absent (the installed 2024 build omits
/// it entirely); an empty command line never matches the opencode stage.
struct WeztermPane: Equatable {
    let paneID: Int
    let tabID: Int
    /// The pane's working directory as a plain path (the CLI sends a file URL).
    let cwd: String
    let isActive: Bool
    let cmdline: [String]

    /// Decodes the CLI's JSON array. Entries without pane/tab ids are skipped;
    /// every other field is optional.
    static func decode(_ data: Data) -> [WeztermPane]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let entries = object as? [[String: Any]] else {
            return nil
        }
        return entries.compactMap { entry in
            guard let paneID = entry["pane_id"] as? Int,
                  let tabID = entry["tab_id"] as? Int else {
                return nil
            }
            return WeztermPane(paneID: paneID,
                               tabID: tabID,
                               cwd: cwdPath(entry["cwd"] as? String ?? ""),
                               isActive: entry["is_active"] as? Bool ?? false,
                               cmdline: cmdline(entry["cmdline"]))
        }
    }

    /// The CLI sends `file:///Users/...`; tolerate a plain path as well.
    ///
    /// `URL.path` percent-decodes ("My%20Project" -> "My Project"); if URL
    /// parsing rejects the string, the literal scheme is stripped so a raw URI
    /// can never be compared against a plain path.
    private static func cwdPath(_ raw: String) -> String {
        guard raw.hasPrefix("file://") else { return raw }
        if let url = URL(string: raw) { return url.path }
        return String(raw.dropFirst("file://".count))
    }

    private static func cmdline(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array }
        if let line = value as? String, !line.isEmpty { return [line] }
        return []
    }
}

/// Finds and drives the WezTerm CLI for jump-to-pane.
///
/// Every method blocks while it spawns the CLI; callers run the locator on a
/// background queue. Work is serialized on the locator's own queue and the pane
/// list is cached for a couple of seconds, so a card tap followed by a chip tap
/// does not pay for two listings.
///
/// Sendability: the mutable caches are touched only on `queue`, the log throttle
/// only under `errorLock`; the injected closures are called from that queue.
final class WeztermLocator: @unchecked Sendable {
    typealias Runner = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessResult

    /// Rungs tried after `$PATH`.
    ///
    /// Measured on the installed WezTerm: the Homebrew link is the real path and
    /// the app bundle ships the CLI as `Contents/MacOS/wezterm`, not
    /// `Contents/MacOS/cli`, so the bundle executable is the last resort for
    /// installs without the Homebrew link.
    static let fallbackBinaries = [
        "/opt/homebrew/bin/wezterm",
        "/Applications/WezTerm.app/Contents/MacOS/cli",
        "/Applications/WezTerm.app/Contents/MacOS/wezterm",
    ]

    /// How long a parsed pane list stays valid.
    static let cacheLifetime: TimeInterval = 2
    /// Bound for one CLI run: a 3s child timeout plus the kill/read grace
    /// ProcessRunner adds, so a wedged mux cannot hold a jump for long.
    static let cliTimeout: TimeInterval = 3

    private let runner: Runner
    private let isExecutable: (String) -> Bool
    private let onPath: () -> String?
    private let now: () -> Date

    private let queue = DispatchQueue(label: "local.ribbon.wezterm")
    private var resolvedBinary: String?
    private var cachedPanes: (panes: [WeztermPane], at: Date)?

    private let errorLock = NSLock()
    private var lastErrorLog = Date.distantPast

    init(runner: @escaping Runner = WeztermLocator.runProcess,
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         onPath: @escaping () -> String? = { ToolLocator.find("wezterm", searchPATH: true) },
         now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.isExecutable = isExecutable
        self.onPath = onPath
        self.now = now
    }

    /// The first rung that exists, resolved once and then kept.
    static func resolveBinary(isExecutable: (String) -> Bool,
                              onPath: () -> String?) -> String? {
        if let path = onPath(), isExecutable(path) {
            return path
        }
        return fallbackBinaries.first(where: isExecutable)
    }

    // MARK: - Matching

    /// Applies the ladder to an already decoded list.
    ///
    /// First panes running opencode in the session's directory, then any pane in
    /// that directory. An empty directory never matches: there is nothing to
    /// look up. Within a stage the active pane wins; with no active pane the
    /// lowest pane id wins. The cmdline stage is vacuous on WezTerm builds that
    /// omit `cmdline`; the directory fallback still lands on the opencode pane
    /// as long as it is the active pane in that directory.
    ///
    /// `is_active` is per tab: several windows can each have an active pane, so
    /// the ladder may pick a background window's pane. The JSON carries no
    /// window-focus flag, and that ambiguity is accepted.
    static func match(directory: String, in panes: [WeztermPane]) -> WeztermPane? {
        guard !directory.isEmpty else { return nil }
        let target = normalizePath(directory)
        guard !target.isEmpty else { return nil }
        let sameDirectory = panes.filter { normalizePath($0.cwd) == target }
        let runsOpencode = sameDirectory.filter { pane in
            pane.cmdline.contains { ($0 as NSString).lastPathComponent == "opencode" }
        }
        return best(runsOpencode) ?? best(sameDirectory)
    }

    /// Active panes first, then the smallest pane id.
    private static func best(_ panes: [WeztermPane]) -> WeztermPane? {
        panes.min { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.paneID < rhs.paneID
        }
    }

    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Lookup

    /// Lists the panes once per `cacheLifetime` and applies the ladder.
    ///
    /// Blocking: spawns the CLI on the locator queue.
    func locatePane(directory: String) -> WeztermPane? {
        queue.sync {
            if let cached = cachedPanes,
               now().timeIntervalSince(cached.at) < Self.cacheLifetime {
                return Self.match(directory: directory, in: cached.panes)
            }
            guard let panes = listPanes() else { return nil }
            cachedPanes = (panes, now())
            return Self.match(directory: directory, in: panes)
        }
    }

    /// Brings the pane's tab and pane forward.
    ///
    /// Best effort: a pane that died between the list and this call makes the
    /// CLI exit non-zero, which is logged and otherwise ignored. A failed tab
    /// activation stops the sequence; there is no point focusing a pane in a tab
    /// that could not be brought forward.
    func activate(pane: WeztermPane) {
        queue.sync {
            guard let binary = binaryPath() else {
                logThrottled("wezterm cli not found")
                return
            }
            guard runCLI(binary, ["cli", "activate-tab", "--tab-id", String(pane.tabID)],
                         label: "activate-tab") else {
                return
            }
            runCLI(binary, ["cli", "activate-pane", "--pane-id", String(pane.paneID)],
                   label: "activate-pane")
        }
    }

    // MARK: - Plumbing

    private func listPanes() -> [WeztermPane]? {
        guard let binary = binaryPath() else {
            logThrottled("wezterm cli not found")
            return nil
        }
        let result = runner(binary, ["cli", "list", "--format", "json"], Self.cliTimeout)
        if result.timedOut {
            logThrottled("wezterm cli list timed out")
            return nil
        }
        if let error = result.launchError {
            logThrottled("wezterm cli list failed: \(error)")
            return nil
        }
        guard result.status == 0 else {
            logThrottled("wezterm cli list exit \(result.status)")
            return nil
        }
        return WeztermPane.decode(result.stdout)
    }

    private func binaryPath() -> String? {
        if let resolvedBinary { return resolvedBinary }
        guard let found = Self.resolveBinary(isExecutable: isExecutable, onPath: onPath) else {
            return nil
        }
        resolvedBinary = found
        return found
    }

    /// Returns whether the CLI call succeeded, so a failed tab activation can
    /// stop before the pane step.
    @discardableResult
    private func runCLI(_ binary: String, _ arguments: [String], label: String) -> Bool {
        let result = runner(binary, arguments, Self.cliTimeout)
        if result.timedOut {
            logThrottled("wezterm cli \(label) timed out")
            return false
        }
        if let error = result.launchError {
            logThrottled("wezterm cli \(label) failed: \(error)")
            return false
        }
        guard result.status == 0 else {
            logThrottled("wezterm cli \(label) exit \(result.status)")
            return false
        }
        return true
    }

    /// One error line per minute, so a wedged CLI tapped repeatedly cannot fill
    /// the log.
    private func logThrottled(_ message: String) {
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

    private static func runProcess(_ executable: String,
                                   _ arguments: [String],
                                   _ timeout: TimeInterval) -> ProcessResult {
        ProcessRunner.run(executable, arguments, timeout: timeout)
    }
}
