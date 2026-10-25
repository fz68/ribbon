import Foundation

/// What to do with a configuration file that exists but does not decode.
enum MalformedPolicy {
    /// Replace a file that does not decode with the built-in default.
    case overwriteWithDefault
    /// Leave a file that does not decode alone; use the default in memory only.
    case keepFile
}

/// One JSON configuration file: read once into memory, written back atomically.
///
/// The store owns the caching, the file IO and the log lines, so every
/// configuration file behaves the same way apart from its path, its built-in
/// default and its malformed policy.
final class JSONConfigStore<T: Codable> {
    private let path: () -> String
    private let fallback: () -> T
    private let malformed: MalformedPolicy
    private let label: String

    private let lock = NSLock()
    private var cached: T?

    /// - Parameters:
    ///   - path: read on every access, so an injected path is honoured immediately.
    ///   - fallback: the built-in default, used when the file is missing or malformed.
    ///   - malformed: what to do with a file that exists but does not decode.
    ///   - label: the prefix used in the log lines ("ime config", "clock config").
    init(path: @escaping () -> String, fallback: @escaping () -> T,
         malformed: MalformedPolicy, label: String) {
        self.path = path
        self.fallback = fallback
        self.malformed = malformed
        self.label = label
    }

    /// The configuration in use. It is read from disk once and then kept in
    /// memory. A missing or malformed file falls back to the built-in defaults.
    func load() -> T {
        load(createIfMissing: true)
    }

    /// The configuration in use, without ever creating the file: a missing file
    /// yields the built-in default in memory only, and that default is cached so
    /// the next `load()` does not create the file either. `TimeFormat.reload()`
    /// uses this so a refresh cannot bring a deleted `clock.json` back.
    func loadExisting() -> T {
        load(createIfMissing: false)
    }

    private func load(createIfMissing: Bool) -> T {
        // The path is resolved before the lock is taken, so the path getter is
        // never called with the store lock held.
        let path = path()
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            let fresh = fallback()
            if createIfMissing {
                write(fresh, to: path)
                log("\(label) created at \(path)")
            }
            cached = fresh
            return fresh
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            cached = decoded
            return decoded
        } catch {
            log("\(label) malformed (\(error)), using built-in defaults")
            let fresh = fallback()
            if case .overwriteWithDefault = malformed {
                write(fresh, to: path)
            }
            cached = fresh
            return fresh
        }
    }

    /// Stores a configuration and writes it to disk.
    @discardableResult
    func save(_ value: T) -> Bool {
        let path = path()
        lock.lock()
        defer { lock.unlock() }
        let written = write(value, to: path)
        cached = value
        return written
    }

    /// Drops the cached value, so the next `load()` reads the file again.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    /// Writes the value to disk, creating the directory when needed. The caller
    /// must hold `lock`, so a `load()` that creates the file does not re-enter.
    @discardableResult
    private func write(_ value: T, to path: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            log("\(label) encode failed")
            return false
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log("\(label) write failed: \(error)")
            return false
        }
    }
}
