import Foundation

/// The window-manager surface Ribbon's Touch Bar consumes: the workspace
/// list, chip focus, and the change stream that schedules a refresh.
protocol WorkspaceBackend {
    func list() -> [Workspace]?
    func focus(_ name: String, completion: ((Bool) -> Void)?)
    func startMonitoring(onChange: @escaping () -> Void)
    func restartMonitoring()
    func stopMonitoring()
}

/// AeroSpace adapter: a thin pass-through over the existing `AeroSpace` enum,
/// whose implementation and tests stay untouched.
struct AeroSpaceBackend: WorkspaceBackend {
    func list() -> [Workspace]? { AeroSpace.list() }
    func focus(_ name: String, completion: ((Bool) -> Void)?) { AeroSpace.focus(name, completion: completion) }
    func startMonitoring(onChange: @escaping () -> Void) { AeroSpace.startMonitoring(onChange: onChange) }
    func restartMonitoring() { AeroSpace.restartMonitoring() }
    func stopMonitoring() { AeroSpace.stopMonitoring() }
}

/// Nehir adapter: same shape, forwarding to the `Nehir` enum.
struct NehirBackend: WorkspaceBackend {
    func list() -> [Workspace]? { Nehir.list() }
    func focus(_ name: String, completion: ((Bool) -> Void)?) { Nehir.focus(name, completion: completion) }
    func startMonitoring(onChange: @escaping () -> Void) { Nehir.startMonitoring(onChange: onChange) }
    func restartMonitoring() { Nehir.restartMonitoring() }
    func stopMonitoring() { Nehir.stopMonitoring() }
}

/// Picks the backend once at launch. A responding AeroSpace wins when both
/// CLIs are installed so existing users never change; a dead AeroSpace daemon
/// falls back to Nehir; with neither found, AeroSpace's placeholder-chip
/// behavior is preserved.
enum WorkspaceBackendFactory {
    /// Test hooks so selection is deterministic on machines with real installs.
    static var aerospaceAvailable: () -> Bool = { AeroSpace.binary != nil && aerospaceDaemonResponds() }
    static var nehirAvailable: () -> Bool = { Nehir.binary != nil }

    /// True when the AeroSpace daemon actually answers. A binary left on disk
    /// after a switch to Nehir must not starve a live Nehir backend.
    static func aerospaceDaemonResponds() -> Bool {
        guard let binary = AeroSpace.binary else { return false }
        let result = ProcessRunner.run(binary, ["list-workspaces", "--all"], timeout: 1)
        return result.launchError == nil && !result.timedOut && result.status == 0
    }

    static func make() -> WorkspaceBackend {
        if aerospaceAvailable() { return AeroSpaceBackend() }
        if nehirAvailable() { return NehirBackend() }
        return AeroSpaceBackend()
    }
}
