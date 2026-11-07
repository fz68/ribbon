import Foundation

/// One WezTerm pane as `wezterm cli list --format json` reports it.
///
/// Only the fields the jump needs are kept. `cmdline` is decoded as an array of
/// argv strings, as a single string, or absent (the installed 2024 build omits
/// it entirely); an empty command line never matches the opencode stage.
///
/// `tty_name` arrives as `/dev/ttys004` and is kept in the bare `ttys004` form
/// so it can be compared with the names `ps` prints. It is empty when the build
/// omits the field, which only disables the tty stage for that pane.
struct WeztermPane: Equatable {
    let paneID: Int
    let tabID: Int
    /// The pane's working directory as a plain path (the CLI sends a file URL).
    let cwd: String
    let isActive: Bool
    let cmdline: [String]
    /// The pane's terminal device without the `/dev/` prefix, or "" when unknown.
    let tty: String

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
                               cmdline: cmdline(entry["cmdline"]),
                               tty: normalizeTTY(entry["tty_name"] as? String ?? ""))
        }
    }

    /// Reduces a terminal device to its bare name.
    ///
    /// WezTerm reports `/dev/ttys004`; `ps` reports `ttys004`. Stripping the
    /// device prefix on both sides is what lets the two lists meet. Blank input
    /// stays blank, and `ps`' no-terminal placeholder (`??`) is dropped so it
    /// can never match a pane.
    static func normalizeTTY(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let bare = trimmed.hasPrefix("/dev/") ? String(trimmed.dropFirst("/dev/".count)) : trimmed
        if bare == "??" || bare == "?" || bare == "-" { return "" }
        return bare
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
/// list plus the opencode tty set are cached together for a couple of seconds,
/// so a card tap followed by a chip tap does not pay for two listings.
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

    /// The process list behind the tty stage. `tty=` drops the header and gives
    /// the device name first, which is what the parser keys on.
    static let psExecutable = "/bin/ps"
    static let psArguments = ["-axo", "tty=,command="]
    /// Same bound as the CLI run: a wedged `ps` must not hold a jump.
    static let psTimeout: TimeInterval = 3

    private let runner: Runner
    /// The process-list runner, injectable so tests never spawn `ps`.
    private let processRunner: Runner
    private let isExecutable: (String) -> Bool
    private let onPath: () -> String?
    private let now: () -> Date

    private let queue = DispatchQueue(label: "local.ribbon.wezterm")
    private var resolvedBinary: String?
    private var cachedPanes: (panes: [WeztermPane], opencodeTties: Set<String>, at: Date)?

    private let errorLock = NSLock()
    private var lastErrorLog = Date.distantPast

    init(runner: @escaping Runner = WeztermLocator.runProcess,
         processRunner: @escaping Runner = WeztermLocator.runProcess,
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         onPath: @escaping () -> String? = { ToolLocator.find("wezterm", searchPATH: true) },
         now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.processRunner = processRunner
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
    /// lowest pane id wins.
    ///
    /// The "runs opencode" stage has two doors, because not every WezTerm build
    /// can answer the same way. The `cmdline` field is absent on the installed
    /// build, so that door is empty there; the tty door exists for exactly that
    /// case. A pane runs opencode when its `tty_name` hosts an interactive
    /// `opencode` process, as collected by `opencodeTties(fromProcessList:)`.
    /// Matching either door is enough, and both are ranked above the plain
    /// directory fallback so a silent zsh pane in the same directory cannot win
    /// just by being active.
    ///
    /// `is_active` is per tab: several windows can each have an active pane, so
    /// the ladder may pick a background window's pane. The JSON carries no
    /// window-focus flag, and that ambiguity is accepted.
    ///
    /// An exact session-to-pane mapping built from a `tui.session.select` hint
    /// remains future work: the live payload has not been observed, so matching
    /// stays directory-based for now.
    static func match(directory: String,
                      in panes: [WeztermPane],
                      opencodeTties: Set<String> = []) -> WeztermPane? {
        guard !directory.isEmpty else { return nil }
        let target = normalizePath(directory)
        guard !target.isEmpty else { return nil }
        let sameDirectory = panes.filter { normalizePath($0.cwd) == target }
        let runsOpencode = sameDirectory.filter { pane in
            runsOpencodeByCmdline(pane) || runsOpencodeOnTTY(pane, opencodeTties: opencodeTties)
        }
        return best(runsOpencode) ?? best(sameDirectory)
    }

    /// The original door: the pane's command line names the opencode binary.
    private static func runsOpencodeByCmdline(_ pane: WeztermPane) -> Bool {
        pane.cmdline.contains { ($0 as NSString).lastPathComponent == "opencode" }
    }

    /// The door that works without `cmdline`: the pane's tty hosts opencode.
    ///
    /// An unknown tty (the field is missing, or `ps` reported no terminal)
    /// never matches, so a missing `tty_name` only costs this stage its vote.
    private static func runsOpencodeOnTTY(_ pane: WeztermPane,
                                          opencodeTties: Set<String>) -> Bool {
        !pane.tty.isEmpty && opencodeTties.contains(pane.tty)
    }

    /// Parses `ps -axo tty=,command=` output into the terminals hosting opencode.
    ///
    /// A row qualifies only when its command's executable is exactly `opencode`
    /// and the row has a real tty. Both halves matter: the shared daemon
    /// (`opencode serve --service`) has no tty and must not qualify, and a
    /// command whose path merely contains "opencode" (an editor, a grep) is not
    /// the binary. Rows are shaped `ttys004  opencode -c`, or
    /// `??       /path/opencode serve --service` for a process with no
    /// controlling terminal.
    static func opencodeTties(fromProcessList output: String) -> Set<String> {
        var tties: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1,
                                    omittingEmptySubsequences: true,
                                    whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let tty = WeztermPane.normalizeTTY(String(fields[0]))
            guard !tty.isEmpty else { continue }
            let command = fields[1]
            guard let executable = command.split(whereSeparator: \.isWhitespace).first else {
                continue
            }
            guard (String(executable) as NSString).lastPathComponent == "opencode" else {
                continue
            }
            tties.insert(tty)
        }
        return tties
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
    /// The pane list and the opencode tty set are one cache entry: they are
    /// collected together because the ladder needs both. Blocking: spawns the
    /// CLI (and `ps`) on the locator queue.
    func locatePane(directory: String) -> WeztermPane? {
        queue.sync {
            if let cached = cachedPanes,
               now().timeIntervalSince(cached.at) < Self.cacheLifetime {
                return Self.match(directory: directory,
                                  in: cached.panes,
                                  opencodeTties: cached.opencodeTties)
            }
            guard let panes = listPanes() else { return nil }
            let tties = collectOpencodeTties()
            cachedPanes = (panes, tties, now())
            return Self.match(directory: directory, in: panes, opencodeTties: tties)
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

    /// The ttys hosting an interactive opencode, best effort.
    ///
    /// A failed or timed-out `ps` yields the empty set rather than failing the
    /// jump: the ladder then degrades to the directory fallback, which is what
    /// it did before this stage existed.
    private func collectOpencodeTties() -> Set<String> {
        let result = processRunner(Self.psExecutable, Self.psArguments, Self.psTimeout)
        if result.timedOut {
            logThrottled("ps timed out")
            return []
        }
        if let error = result.launchError {
            logThrottled("ps failed: \(error)")
            return []
        }
        guard result.status == 0 else {
            logThrottled("ps exit \(result.status)")
            return []
        }
        guard let output = String(data: result.stdout, encoding: .utf8) else { return [] }
        return Self.opencodeTties(fromProcessList: output)
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
