import Cocoa
import Carbon

/// The keyboard input source that is selected right now, plus the per source
/// configuration of the indicator line that runs along the bottom of the bar.
///
/// Everything is read through the public Carbon / HIServices Text Input Sources
/// API. A check costs two property reads on an object the system already keeps
/// in memory, so it never spawns a process.
enum InputSource {
    // MARK: - Palette

    /// The solid colours the user can assign to an input source.
    static let palette: [(name: String, hex: String)] = [
        ("Red", "#FF5F57"),
        ("Orange", "#FF8C42"),
        ("Yellow", "#FFD60A"),
        ("Green", "#4CD964"),
        ("Cyan", "#40C8E0"),
        ("Blue", "#4FA3FF"),
        ("Purple", "#B388FF"),
    ]

    /// The rainbow stops, from the left edge to the right edge.
    static let rainbowHex: [String] = palette.map(\.hex)

    // MARK: - Configuration file

    /// One line configuration: either the fallback for unknown sources or the
    /// entry of one specific source.
    struct Entry: Codable {
        /// The localized name of the source. Only the source entries carry one.
        var name: String?
        /// Whether the indicator line is drawn for this source.
        var line: Bool
        /// The solid colour as "#RRGGBB".
        var color: String
        /// Whether the line is drawn as a rainbow instead of a solid colour.
        var rainbow: Bool
    }

    /// The vertical edge of the bar the indicator line is drawn on.
    enum LinePosition: String {
        case top
        case bottom
    }

    /// The contents of `~/Library/Application Support/Ribbon/ime.json`.
    struct Configuration: Codable {
        /// The fallback used for a source that has no entry of its own.
        var `default`: Entry
        /// The per source entries, keyed by input source id.
        var sources: [String: Entry]
        /// Which edge the indicator line is drawn on: "top" or "bottom".
        ///
        /// Kept as a plain string, so a missing, unknown or wrong-typed value
        /// falls back to the bottom edge instead of failing the whole file.
        var linePosition: String?

        private enum CodingKeys: String, CodingKey {
            case `default`, sources, linePosition
        }

        // The custom decoder below suppresses the synthesized memberwise
        // initializer, so it is spelled out here.
        init(default: Entry, sources: [String: Entry], linePosition: String? = nil) {
            self.`default` = `default`
            self.sources = sources
            self.linePosition = linePosition
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.`default` = try container.decode(Entry.self, forKey: .default)
            self.sources = try container.decode([String: Entry].self, forKey: .sources)
            // try? so a wrong type here cannot fail the whole file
            self.linePosition = try? container.decodeIfPresent(String.self, forKey: .linePosition)
        }
    }

    /// Where the per source configuration is stored.
    ///
    /// Assigning a new path drops the cached configuration, so a redirected path
    /// is picked up by the next read.
    static var configurationPath: String {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedConfigurationPath
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            storedConfigurationPath = newValue
            store.invalidate()
        }
    }

    /// The default location of the configuration file.
    private static var storedConfigurationPath = (NSString(string: "~/Library/Application Support/Ribbon/ime.json") as NSString).expandingTildeInPath

    /// Where the per source configuration lived before the app was renamed. It is
    /// only read once, to carry an existing configuration over to the new path.
    /// Overridable so tests can point it at a temporary file.
    static var legacyConfigurationPath = (NSString(string: "~/Library/Application Support/TouchBarBar/ime.json") as NSString).expandingTildeInPath

    private static let stateLock = NSRecursiveLock()
    /// Guards `cachedBuiltInConfiguration` only. It is a leaf lock: never acquire
    /// `stateLock` while holding it. That keeps the config store's `fallback()` call
    /// (which runs under the store lock) from inverting against `stateLock`.
    private static let builtInLock = NSLock()
    private static var cachedBuiltInConfiguration: Configuration?
    /// Set by the first `migrateLegacyConfigurationIfNeeded()` call, so the
    /// legacy file is looked for once per process rather than once per read.
    /// Resettable so tests can re-arm the one-shot migration.
    static var didMigrateLegacyConfiguration = false

    /// The generic store behind the configuration file. The built-in defaults
    /// are rebuilt from the live source list, so a newly installed IME gets an
    /// entry of its own.
    ///
    /// A malformed file is left untouched, so the user can repair it by hand;
    /// the app runs on the built-in defaults meanwhile.
    private static let store = JSONConfigStore<Configuration>(
        path: { configurationPath },
        fallback: { builtInConfiguration() },
        malformed: .keepFile,
        label: "ime config"
    )

    /// The configuration in use. It is read from disk once and then kept in
    /// memory. A missing or malformed file falls back to the built-in defaults.
    static func configuration() -> Configuration {
        migrateLegacyConfigurationIfNeeded()
        return store.load()
    }

    /// Copies the configuration of the pre-rename app to the current path once.
    /// A file that already exists at the current path is never overwritten.
    ///
    /// The store caches the configuration, so the old code only migrated on the
    /// first uncached load. This one-shot flag keeps that behaviour instead of
    /// checking the file system on every appearance lookup.
    private static func migrateLegacyConfigurationIfNeeded() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didMigrateLegacyConfiguration else { return }
        didMigrateLegacyConfiguration = true
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: configurationPath),
              fileManager.fileExists(atPath: legacyConfigurationPath) else { return }
        let destination = URL(fileURLWithPath: configurationPath)
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.copyItem(atPath: legacyConfigurationPath, toPath: configurationPath)
            log("migrated IME config from \(legacyConfigurationPath)")
        } catch {
            log("ime config migration failed: \(error)")
        }
    }

    /// The edge the indicator line is drawn on. A missing or unknown value
    /// falls back to the bottom edge, so a hand edited file that names an
    /// unknown edge still renders the line.
    static var linePosition: LinePosition {
        guard let raw = configuration().linePosition else { return .bottom }
        return LinePosition(rawValue: raw.lowercased()) ?? .bottom
    }

    /// Drops the cached ime.json, so the next read re-reads the file from disk.
    /// The manual refresh calls this, so a hand edited file is picked up
    /// without a relaunch.
    static func invalidateConfiguration() {
        stateLock.lock()
        defer { stateLock.unlock() }
        store.invalidate()
    }

    /// Stores the appearance of one source and writes the file back.
    @discardableResult
    static func setAppearance(id: String, name: String, show: Bool, color: String?, rainbow: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        var config = configuration()
        let previous = config.sources[id]
        config.sources[id] = Entry(
            name: name,
            line: show,
            color: color ?? previous?.color ?? "#4FA3FF",
            rainbow: rainbow
        )
        return store.save(config)
    }

    /// Writes the edge the indicator line is drawn on to `ime.json`.
    @discardableResult
    static func setLinePosition(_ position: LinePosition) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        var config = configuration()
        config.linePosition = position.rawValue
        return store.save(config)
    }

    /// The configuration used before the user customises anything: a plain
    /// keyboard layout shows no line, the Doubao IME gets the rainbow and every
    /// other enabled source gets its own colour so two IMEs never share one.
    ///
    /// The result is cached, because it is read on every appearance lookup.
    static func builtInConfiguration() -> Configuration {
        builtInLock.lock()
        defer { builtInLock.unlock() }
        if let cached = cachedBuiltInConfiguration { return cached }
        let live = liveBuiltInConfiguration()
        cachedBuiltInConfiguration = live
        return live
    }

    /// Drops the cached built-in configuration, so the next read sees the input
    /// sources the system reports right now.
    static func invalidateBuiltInCache() {
        builtInLock.lock()
        defer { builtInLock.unlock() }
        cachedBuiltInConfiguration = nil
    }

    /// The built-in configuration computed from the sources the system lists now.
    private static func liveBuiltInConfiguration() -> Configuration {
        let fallback = Entry(name: nil, line: true, color: "#4FA3FF", rainbow: false)
        var configuration = Configuration(default: fallback, sources: [:])
        // The line is drawn on the bottom edge until the file says otherwise.
        configuration.linePosition = "bottom"
        // Sources that share a localized name are one IME seen through two ids
        // (an ASCII variant and a pinyin variant), so they share a colour too.
        var colourByName: [String: String] = [:]
        var usedColours: [String] = []
        for source in enabledSources {
            if isPlainKeyboardLayout(id: source.id) {
                // Plain English and the other keyboard layouts show no line.
                configuration.sources[source.id] = Entry(name: source.name, line: false,
                                                        color: fallback.color, rainbow: false)
                continue
            }
            if isDoubao(id: source.id, name: source.name) {
                configuration.sources[source.id] = Entry(name: source.name, line: true,
                                                        color: fallback.color, rainbow: true)
                continue
            }
            if colourByName[source.name] == nil {
                let colour = palette[usedColours.count % palette.count].hex
                usedColours.append(colour)
                colourByName[source.name] = colour
            }
            configuration.sources[source.id] = Entry(name: source.name, line: true,
                                                    color: colourByName[source.name] ?? fallback.color,
                                                    rainbow: false)
        }
        return configuration
    }

    // MARK: - Detection

    /// The selected keyboard input source, or nil when the system reports none.
    static var current: InputSourceDescriptor? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
        return InputSourceDescriptor(id: id, name: name)
    }

    /// True when the id belongs to a plain keyboard layout.
    static func isPlainKeyboardLayout(id: String) -> Bool {
        id.hasPrefix("com.apple.keylayout.")
    }

    /// True when the source is the Doubao IME.
    static func isDoubao(id: String, name: String) -> Bool {
        let haystack = "\(id) \(name)".lowercased()
        return haystack.contains("doubao") || haystack.contains("豆包")
    }

    /// Every enabled input source, in the order the system lists them.
    static var enabledSources: [InputSourceDescriptor] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        var result: [InputSourceDescriptor] = []
        for source in list {
            guard boolProperty(source, kTISPropertyInputSourceIsEnabled) else { continue }
            guard let id = stringProperty(source, kTISPropertyInputSourceID) else { continue }
            let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
            result.append(InputSourceDescriptor(id: id, name: name))
        }
        return result
    }

    /// What the bar should draw for a source: the plain keyboard layouts stay
    /// without a line, every other source follows its configured entry.
    static func appearance(for id: String) -> InputSourceAppearance {
        let configuration = configuration()
        let entry = configuration.sources[id] ?? fallbackEntry(for: id, configuration: configuration)
        let show = entry.line && !isPlainKeyboardLayout(id: id)
        return InputSourceAppearance(show: show, color: NSColor(hex: entry.color), rainbow: entry.rainbow)
    }

    /// The entry used for a source that has none of its own. A newly installed
    /// IME follows the built-in rules so it never lands on a foreign colour.
    private static func fallbackEntry(for id: String, configuration: Configuration) -> Entry {
        let live = builtInConfiguration()
        if let entry = live.sources[id] { return entry }
        if isPlainKeyboardLayout(id: id) {
            return Entry(name: nil, line: false, color: configuration.default.color, rainbow: false)
        }
        return configuration.default
    }

    // MARK: - Carbon property helpers

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        return (value as? Bool) == true
    }
}
