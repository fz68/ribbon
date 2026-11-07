import Foundation
import Testing
@testable import RibbonCore

// MARK: - Fixtures

/// One pane entry shaped exactly like the live `wezterm cli list --format json`
/// output (window_id/tab_id/pane_id numbers, a file:// cwd, is_active). The
/// installed CLI sends no `cmdline`; tests that need the command stage add it,
/// which the tolerant decoder accepts.
private func paneEntry(_ paneID: Int,
                       tabID: Int,
                       cwd: String,
                       active: Bool,
                       windowID: Int = 0,
                       cmdline: [String]? = nil,
                       tty: String = "/dev/ttys004") -> [String: Any] {
    var entry: [String: Any] = [
        "window_id": windowID,
        "tab_id": tabID,
        "pane_id": paneID,
        "workspace": "default",
        "size": ["rows": 41, "cols": 100, "pixel_width": 1800, "pixel_height": 1763, "dpi": 144],
        "title": "zsh",
        "cwd": "file://" + cwd,
        "cursor_x": 5,
        "cursor_y": 35,
        "cursor_shape": "BlinkingBlock",
        "cursor_visibility": "Visible",
        "left_col": 0,
        "top_row": 0,
        "tab_title": "",
        "window_title": "OC",
        "is_active": active,
        "is_zoomed": false,
        "tty_name": tty,
    ]
    if let cmdline { entry["cmdline"] = cmdline }
    return entry
}

private func panesData(_ entries: [[String: Any]]) -> Data {
    (try? JSONSerialization.data(withJSONObject: entries)) ?? Data()
}

/// Thread-safe stand-in for the `wezterm` binary.
private final class RunnerStub: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(executable: String, arguments: [String])] = []
    private let stdout: Data
    /// When set, every call returns this instead of the scripted success, so a
    /// failing CLI can be tested.
    private let failure: ProcessResult?

    init(stdout: Data, failure: ProcessResult? = nil) {
        self.stdout = stdout
        self.failure = failure
    }

    var calls: [(executable: String, arguments: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var callCount: Int { calls.count }

    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessResult {
        lock.lock()
        stored.append((executable, arguments))
        lock.unlock()
        if let failure { return failure }
        return ProcessResult(status: 0, stdout: stdout, timedOut: false, launchError: nil)
    }
}

/// Stand-in for the `ps -axo tty=,command=` run: no opencode on any tty.
private let noOpencodeProcesses: WeztermLocator.Runner = { _, _, _ in
    ProcessResult(status: 0, stdout: Data(), timedOut: false, launchError: nil)
}

/// Stand-in for the `ps` run that returns a scripted process list.
private func processList(_ output: String) -> WeztermLocator.Runner {
    { _, _, _ in
        ProcessResult(status: 0, stdout: Data(output.utf8), timedOut: false, launchError: nil)
    }
}

@Suite(.serialized) final class WeztermLocatorTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testDecodeMatchesTheLivePaneShape() throws {
        let data = panesData([
            paneEntry(5, tabID: 3, cwd: "/Users/fanzhen/myprojects/ribbon", active: true),
        ])
        let panes = try #require(WeztermPane.decode(data))

        #expect(panes.count == 1, "the live shape decodes")
        #expect(panes[0].paneID == 5, "pane_id is a number")
        #expect(panes[0].tabID == 3, "tab_id is a number")
        #expect(panes[0].cwd == "/Users/fanzhen/myprojects/ribbon",
                "the file:// cwd is decoded to a plain path")
        #expect(panes[0].isActive, "is_active decodes")
        #expect(panes[0].cmdline.isEmpty, "the installed CLI omits cmdline")
        #expect(panes[0].tty == "ttys004", "the /dev/ prefix is stripped off tty_name")
    }

    @Test func testDecodeToleratesMissingAndStringCmdline() throws {
        let data = panesData([
            paneEntry(1, tabID: 1, cwd: "/x", active: false, cmdline: ["opencode"]),
            ["pane_id": 2, "tab_id": 2, "cwd": "file:///x", "cmdline": "opencode"] as [String: Any],
            ["tab_id": 3, "cwd": "file:///x"] as [String: Any],
        ])
        let panes = try #require(WeztermPane.decode(data))
        #expect(panes.count == 2, "an entry without a pane id is skipped")
        #expect(panes[0].cmdline == ["opencode"], "an array cmdline decodes")
        #expect(panes[1].cmdline == ["opencode"], "a string cmdline decodes")
    }

    @Test func testCmdlineAndDirectoryMatchWins() throws {
        let data = panesData([
            paneEntry(10, tabID: 2, cwd: "/Users/x/repo", active: true, cmdline: ["zsh"]),
            paneEntry(5, tabID: 1, cwd: "/Users/x/repo", active: false,
                      cmdline: ["/opt/homebrew/bin/opencode"]),
            paneEntry(7, tabID: 1, cwd: "/Users/x/other", active: true, cmdline: ["opencode"]),
        ])
        let panes = try #require(WeztermPane.decode(data))

        let match = try #require(WeztermLocator.match(directory: "/Users/x/repo", in: panes))
        #expect(match.paneID == 5, "cmdline mentions opencode in the session directory")
    }

    @Test func testActivePaneWinsTheTie() throws {
        let data = panesData([
            paneEntry(5, tabID: 1, cwd: "/Users/x/repo", active: false,
                      cmdline: ["opencode"]),
            paneEntry(6, tabID: 1, cwd: "/Users/x/repo", active: true,
                      cmdline: ["opencode"]),
        ])
        let panes = try #require(WeztermPane.decode(data))

        let match = try #require(WeztermLocator.match(directory: "/Users/x/repo", in: panes))
        #expect(match.paneID == 6, "the active pane wins among equal candidates")
    }

    @Test func testSmallestPaneIDWinsWithoutAnActivePane() throws {
        let data = panesData([
            paneEntry(9, tabID: 1, cwd: "/Users/x/repo", active: false,
                      cmdline: ["opencode"]),
            paneEntry(7, tabID: 1, cwd: "/Users/x/repo", active: false,
                      cmdline: ["opencode"]),
        ])
        let panes = try #require(WeztermPane.decode(data))

        let match = try #require(WeztermLocator.match(directory: "/Users/x/repo", in: panes))
        #expect(match.paneID == 7, "the smallest pane id breaks a full tie")
    }

    @Test func testDirectoryOnlyFallback() throws {
        // No cmdline at all, which is the live case: the directory filter and
        // the active tiebreak still find the pane.
        let data = panesData([
            paneEntry(10, tabID: 3, cwd: "/Users/x/repo", active: false),
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: true),
            paneEntry(13, tabID: 8, cwd: "/Users/x/other", active: true),
        ])
        let panes = try #require(WeztermPane.decode(data))

        let match = try #require(WeztermLocator.match(directory: "/Users/x/repo", in: panes))
        #expect(match.paneID == 5, "the active pane in the directory wins the fallback")
    }

    @Test func testNoMatchingDirectoryIsNil() throws {
        let data = panesData([
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: true),
        ])
        let panes = try #require(WeztermPane.decode(data))
        #expect(WeztermLocator.match(directory: "/Users/x/somewhere-else", in: panes) == nil,
                "no pane in the directory means app-only")
    }

    @Test func testTrailingSlashAndDotSegmentsNormalize() throws {
        let data = panesData([
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: true),
        ])
        let panes = try #require(WeztermPane.decode(data))
        #expect(WeztermLocator.match(directory: "/Users/x/repo/", in: panes)?.paneID == 5,
                "a trailing slash still matches")
        #expect(WeztermLocator.match(directory: "/Users/x/repo/./", in: panes)?.paneID == 5,
                "dot segments are standardized")
    }

    @Test func testPaneListIsCachedForTwoSeconds() throws {
        let stdout = panesData([
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: true),
        ])
        let runner = RunnerStub(stdout: stdout)
        let clock = Box<Date>(Date(timeIntervalSince1970: 1_800_000_000))
        let locator = WeztermLocator(runner: runner.run,
                                     processRunner: noOpencodeProcesses,
                                     isExecutable: { _ in true },
                                     onPath: { "/fake/wezterm" },
                                     now: { clock.value! })

        #expect(locator.locatePane(directory: "/Users/x/repo")?.paneID == 5)
        #expect(locator.locatePane(directory: "/Users/x/repo")?.paneID == 5)
        #expect(runner.callCount == 1, "two immediate lookups share one listing")
        #expect(runner.calls.first?.arguments == ["cli", "list", "--format", "json"],
                "the listing uses the JSON format")

        clock.store(clock.value!.addingTimeInterval(3))
        #expect(locator.locatePane(directory: "/Users/x/repo")?.paneID == 5)
        #expect(runner.callCount == 2, "the cache expires after two seconds")
    }

    @Test func testEmptyDirectoryNeverMatches() throws {
        let data = panesData([
            paneEntry(5, tabID: 1, cwd: "", active: true),
        ])
        let panes = try #require(WeztermPane.decode(data))
        #expect(WeztermLocator.match(directory: "", in: panes) == nil,
                "an unknown directory must never jump anywhere")
    }

    @Test func testPercentEncodedAndCJKCWDMatch() throws {
        let data = panesData([
            paneEntry(5, tabID: 1, cwd: "/Users/x/My%20Project", active: true),
            paneEntry(6, tabID: 2, cwd: "/Users/x/%E4%BB%A3%E7%A0%81", active: true),
        ])
        let panes = try #require(WeztermPane.decode(data))

        #expect(WeztermLocator.match(directory: "/Users/x/My Project", in: panes)?.paneID == 5,
                "a percent-encoded cwd matches the plain path")
        #expect(WeztermLocator.match(directory: "/Users/x/代码", in: panes)?.paneID == 6,
                "a percent-encoded CJK path matches the decoded directory")
    }

    @Test func testCmdlineMatchingUsesTheLastPathComponent() throws {
        let data = panesData([
            paneEntry(5, tabID: 1, cwd: "/Users/x/repo", active: true,
                      cmdline: ["/Users/x/opencode-notes/zsh"]),
            paneEntry(6, tabID: 1, cwd: "/Users/x/repo", active: false,
                      cmdline: ["/usr/local/bin/opencode"]),
        ])
        let panes = try #require(WeztermPane.decode(data))

        let match = try #require(WeztermLocator.match(directory: "/Users/x/repo", in: panes))
        #expect(match.paneID == 6, "a path containing opencode is not the opencode binary")
    }

    // MARK: - tty stage

    @Test func testTTYHostingOpencodeOutranksAPlainPane() throws {
        // The live build sends no cmdline, so this is the rung that has to
        // carry the jump: the active pane is a plain zsh in the same directory.
        let data = panesData([
            paneEntry(10, tabID: 3, cwd: "/Users/x/repo", active: true, tty: "/dev/ttys000"),
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: false, tty: "/dev/ttys004"),
        ])
        let panes = try #require(WeztermPane.decode(data))

        let match = try #require(WeztermLocator.match(directory: "/Users/x/repo",
                                                      in: panes,
                                                      opencodeTties: ["ttys004"]))
        #expect(match.paneID == 5, "the pane whose tty hosts opencode wins")
    }

    @Test func testDaemonWithoutATtyDoesNotQualify() throws {
        let ps = """
        ??       /Users/fanzhen/.opencode/bin/opencode serve --service
        ??       /bin/zsh -c ps -axo tty=,command= | grep -i opencode
        ttys009  grep -i opencode
        ttys000  -zsh
        """
        let tties = WeztermLocator.opencodeTties(fromProcessList: ps)
        #expect(tties.isEmpty, "a ttyless daemon and grep rows never qualify")

        let data = panesData([
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: false, tty: "/dev/ttys004"),
            paneEntry(10, tabID: 3, cwd: "/Users/x/repo", active: true, tty: "/dev/ttys000"),
        ])
        let panes = try #require(WeztermPane.decode(data))

        let match = try #require(WeztermLocator.match(directory: "/Users/x/repo",
                                                      in: panes,
                                                      opencodeTties: tties))
        #expect(match.paneID == 10, "with no qualifying tty the directory ladder decides")
    }

    @Test func testTTYNormalizationAcceptsBothForms() throws {
        #expect(WeztermPane.normalizeTTY("/dev/ttys012") == "ttys012",
                "WezTerm's device path is reduced to the bare name")
        #expect(WeztermPane.normalizeTTY("ttys012") == "ttys012",
                "ps' bare name is already normalized")
        #expect(WeztermPane.normalizeTTY("??") == "", "a no-terminal marker normalizes to nothing")

        // ps prints the bare name, the pane reports the device path: they meet.
        let tties = WeztermLocator.opencodeTties(fromProcessList: "ttys008  opencode -c\n")
        #expect(tties == ["ttys008"], "the interactive TUI's tty is collected")

        let data = panesData([
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: false, tty: "/dev/ttys008"),
        ])
        let panes = try #require(WeztermPane.decode(data))
        #expect(WeztermLocator.match(directory: "/Users/x/repo",
                                    in: panes,
                                    opencodeTties: tties)?.paneID == 5,
                "the two spellings compare equal")
    }

    @Test func testTTYSetIsCachedWithThePaneList() throws {
        let stdout = panesData([
            paneEntry(10, tabID: 3, cwd: "/Users/x/repo", active: true, tty: "/dev/ttys000"),
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: false, tty: "/dev/ttys004"),
        ])
        let runner = RunnerStub(stdout: stdout)
        let psRunner = RunnerStub(stdout: Data("ttys004  opencode -c\n".utf8))
        let clock = Box<Date>(Date(timeIntervalSince1970: 1_800_000_000))
        let locator = WeztermLocator(runner: runner.run,
                                     processRunner: psRunner.run,
                                     isExecutable: { _ in true },
                                     onPath: { "/fake/wezterm" },
                                     now: { clock.value! })

        #expect(locator.locatePane(directory: "/Users/x/repo")?.paneID == 5,
                "the tty stage picks the opencode pane")
        #expect(locator.locatePane(directory: "/Users/x/repo")?.paneID == 5)
        #expect(psRunner.callCount == 1, "the tty set rides the pane list's cache entry")
        #expect(psRunner.calls.first?.executable == WeztermLocator.psExecutable)
        #expect(psRunner.calls.first?.arguments == WeztermLocator.psArguments,
                "the process list uses the documented ps invocation")

        clock.store(clock.value!.addingTimeInterval(3))
        #expect(locator.locatePane(directory: "/Users/x/repo")?.paneID == 5)
        #expect(psRunner.callCount == 2, "the tty set is refreshed with the pane list")
    }

    @Test func testFailedProcessListFallsBackToTheDirectoryLadder() throws {
        let stdout = panesData([
            paneEntry(10, tabID: 3, cwd: "/Users/x/repo", active: true, tty: "/dev/ttys000"),
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: false, tty: "/dev/ttys004"),
        ])
        let psRunner = RunnerStub(stdout: Data(),
                                  failure: ProcessResult(status: 1, stdout: Data(),
                                                         timedOut: false, launchError: nil))
        let locator = WeztermLocator(runner: RunnerStub(stdout: stdout).run,
                                     processRunner: psRunner.run,
                                     isExecutable: { _ in true },
                                     onPath: { "/fake/wezterm" })

        #expect(locator.locatePane(directory: "/Users/x/repo")?.paneID == 10,
                "a failed ps degrades to the plain directory fallback")
    }

    @Test func testActivateSendsTabThenPane() throws {
        let stdout = panesData([
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: true),
        ])
        let runner = RunnerStub(stdout: stdout)
        let locator = WeztermLocator(runner: runner.run,
                                     processRunner: noOpencodeProcesses,
                                     isExecutable: { _ in true },
                                     onPath: { "/fake/wezterm" })
        let pane = try #require(WeztermPane.decode(stdout)?.first)

        locator.activate(pane: pane)

        #expect(runner.calls.map { $0.arguments } == [
            ["cli", "activate-tab", "--tab-id", "3"],
            ["cli", "activate-pane", "--pane-id", "5"],
        ], "the tab is activated first, then the pane")
    }

    @Test func testFailedTabActivationSkipsThePane() throws {
        let stdout = panesData([
            paneEntry(5, tabID: 3, cwd: "/Users/x/repo", active: true),
        ])
        let runner = RunnerStub(stdout: stdout,
                                failure: ProcessResult(status: 1, stdout: Data(),
                                                       timedOut: false, launchError: nil))
        let locator = WeztermLocator(runner: runner.run,
                                     processRunner: noOpencodeProcesses,
                                     isExecutable: { _ in true },
                                     onPath: { "/fake/wezterm" })
        let pane = try #require(WeztermPane.decode(stdout)?.first)

        locator.activate(pane: pane)

        #expect(runner.calls.count == 1, "a failed tab activation stops the sequence")
        #expect(runner.calls.first?.arguments == ["cli", "activate-tab", "--tab-id", "3"])
    }

    @Test func testFailedListIsNotCached() {
        let runner = RunnerStub(stdout: Data(),
                                failure: ProcessResult(status: 1, stdout: Data(),
                                                       timedOut: false, launchError: nil))
        let clock = Box<Date>(Date(timeIntervalSince1970: 1_800_000_000))
        let locator = WeztermLocator(runner: runner.run,
                                     processRunner: noOpencodeProcesses,
                                     isExecutable: { _ in true },
                                     onPath: { "/fake/wezterm" },
                                     now: { clock.value! })

        #expect(locator.locatePane(directory: "/Users/x/repo") == nil,
                "a failed listing yields no pane")
        #expect(locator.locatePane(directory: "/Users/x/repo") == nil)
        #expect(runner.callCount == 2, "a failed listing is never cached")
    }

    @Test func testTimedOutListIsNotCached() {
        let runner = RunnerStub(stdout: Data(),
                                failure: ProcessResult(status: -1, stdout: Data(),
                                                       timedOut: true, launchError: nil))
        let clock = Box<Date>(Date(timeIntervalSince1970: 1_800_000_000))
        let locator = WeztermLocator(runner: runner.run,
                                     processRunner: noOpencodeProcesses,
                                     isExecutable: { _ in true },
                                     onPath: { "/fake/wezterm" },
                                     now: { clock.value! })

        #expect(locator.locatePane(directory: "/Users/x/repo") == nil,
                "a timed-out listing yields no pane")
        #expect(locator.locatePane(directory: "/Users/x/repo") == nil)
        #expect(runner.callCount == 2, "a timeout is not cached either")
    }

    @Test func testBinaryLadder() {
        let path = WeztermLocator.resolveBinary(isExecutable: { _ in true },
                                                onPath: { "/custom/wezterm" })
        #expect(path == "/custom/wezterm", "the PATH hit is the first rung")

        let borkedPATH = WeztermLocator.resolveBinary(
            isExecutable: { $0 == "/opt/homebrew/bin/wezterm" },
            onPath: { "/missing/wezterm" })
        #expect(borkedPATH == "/opt/homebrew/bin/wezterm",
                "a missing PATH hit falls through to Homebrew")

        let brew = WeztermLocator.resolveBinary(
            isExecutable: { $0 == "/opt/homebrew/bin/wezterm" },
            onPath: { nil })
        #expect(brew == "/opt/homebrew/bin/wezterm", "the Homebrew rung is used")

        let bundleCLI = WeztermLocator.resolveBinary(
            isExecutable: { $0 == "/Applications/WezTerm.app/Contents/MacOS/cli" },
            onPath: { nil })
        #expect(bundleCLI == "/Applications/WezTerm.app/Contents/MacOS/cli",
                "the documented bundle cli rung is used when present")

        let bundleExecutable = WeztermLocator.resolveBinary(
            isExecutable: { $0 == "/Applications/WezTerm.app/Contents/MacOS/wezterm" },
            onPath: { nil })
        #expect(bundleExecutable == "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                "the app executable is the last resort (the live app has no cli file)")

        #expect(WeztermLocator.resolveBinary(isExecutable: { _ in false },
                                             onPath: { nil }) == nil,
                "no rung means no CLI")
    }
}
