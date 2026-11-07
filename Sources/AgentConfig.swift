import Foundation

/// The user's switch for the OpenCode agent chip.
struct AgentConfiguration: Codable, Equatable {
    /// False removes the chip entirely and stops the bridge.
    var enabled: Bool

    /// On by default: the chip hides itself while no service file exists, so a
    /// fresh install with no opencode running looks exactly as before.
    static let `default` = AgentConfiguration(enabled: true)
}

/// `agent.json`: the one switch that decides whether the chip exists at all.
///
/// Same pattern as `clock.json` and `ime.json`: a small JSON file in the app's
/// Application Support directory, read once and written atomically.
enum AgentConfig {
    /// Where the agent configuration is stored.
    ///
    /// Assigning a new path drops the cache, so a redirected path is picked up
    /// by the next read.
    static var configurationPath: String {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedPath
        }
        set {
            stateLock.lock()
            storedPath = newValue
            store.invalidate()
            stateLock.unlock()
        }
    }

    private static var storedPath = (NSString(string: "~/Library/Application Support/Ribbon/agent.json") as NSString)
        .expandingTildeInPath
    private static let stateLock = NSRecursiveLock()

    /// A file that does not decode is left alone, so a hand edit is never
    /// overwritten; the chip runs on the built-in default meanwhile.
    private static let store = JSONConfigStore<AgentConfiguration>(
        path: { configurationPath },
        fallback: { .default },
        malformed: .keepFile,
        label: "agent config"
    )

    static func current() -> AgentConfiguration {
        store.load()
    }

    /// Whether the chip is enabled. The controller reads this on every start and
    /// every publish, so a menu toggle takes effect without a restart.
    static var isEnabled: Bool {
        current().enabled
    }

    /// Writes the switch and returns whether the file was written.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        store.save(AgentConfiguration(enabled: enabled))
    }

    /// Drops the cached value so the next read comes from disk.
    static func invalidate() {
        store.invalidate()
    }
}
