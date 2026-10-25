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

    /// The contents of `~/Library/Application Support/Ribbon/ime.json`.
    struct Configuration: Codable {
        /// The fallback used for a source that has no entry of its own.
        var `default`: Entry
        /// The per source entries, keyed by input source id.
        var sources: [String: Entry]
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
    private static let legacyConfigurationPath = (NSString(string: "~/Library/Application Support/TouchBarBar/ime.json") as NSString).expandingTildeInPath

    private static let stateLock = NSRecursiveLock()
    /// Guards `cachedBuiltInConfiguration` only. It is a leaf lock: never acquire
    /// `stateLock` while holding it. That keeps the config store's `fallback()` call
    /// (which runs under the store lock) from inverting against `stateLock`.
    private static let builtInLock = NSLock()
    private static var cachedBuiltInConfiguration: Configuration?
    /// Set by the first `migrateLegacyConfigurationIfNeeded()` call, so the
    /// legacy file is looked for once per process rather than once per read.
    private static var didMigrateLegacyConfiguration = false

    /// The generic store behind the configuration file. The built-in defaults
    /// are rebuilt from the live source list, so a newly installed IME gets an
    /// entry of its own.
    private static let store = JSONConfigStore<Configuration>(
        path: { configurationPath },
        fallback: { builtInConfiguration() },
        malformed: .overwriteWithDefault,
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

/// Watches the selected keyboard input source and reports every change.
///
/// The Carbon notification is the preferred signal, but it is not delivered on
/// every macOS release, so a one second poll runs next to it and takes over
/// when the notification stays silent. Both paths are cheap: they read two
/// properties of an object the system already keeps in memory and never spawn
/// a process.
final class InputSourceWatcher {
    /// Called on the main thread whenever the selected source changes.
    var onChange: ((_ id: String, _ name: String) -> Void)?

    private var lastID: String?
    private var pendingChange: InputSourceDescriptor?
    private var pollTimer: Timer?
    private var lastNotificationAt: Date?
    private var loggedNotificationDelivered = false
    private var loggedNotificationMissing = false
    private var isRunning = false

    /// Starts watching. Must be called on the main thread.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerNotification()
        lastID = InputSource.current?.id
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        log("ime watcher started notification=registered poll=1s")
    }

    /// Stops watching and removes the Carbon observer.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        let context = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDistributedCenter(), context, nil, nil)
    }

    /// Registers the Carbon notification. It is the preferred signal but it is
    /// not delivered everywhere, so the poll stays in place as the fallback.
    private func registerNotification() {
        guard let name = kTISNotifySelectedKeyboardInputSourceChanged else {
            log("ime notification unavailable, poll only")
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            context,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let watcher = Unmanaged<InputSourceWatcher>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    watcher.handleNotification()
                }
            },
            name,
            nil,
            .deliverImmediately
        )

        // The enabled set changes when an IME is installed or removed, which can
        // reassign the round-robin palette colours without the selection moving.
        if let enabled = kTISNotifyEnabledKeyboardInputSourcesChanged {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDistributedCenter(),
                context,
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let watcher = Unmanaged<InputSourceWatcher>.fromOpaque(observer).takeUnretainedValue()
                    DispatchQueue.main.async {
                        watcher.handleEnabledSourcesChanged()
                    }
                },
                enabled,
                nil,
                .deliverImmediately
            )
        }
    }

    /// The enabled set changes when an IME is installed or removed, which can
    /// reassign the round-robin palette colours without the selection moving.
    private func handleEnabledSourcesChanged() {
        InputSource.invalidateBuiltInCache()
        guard let current = InputSource.current else { return }
        onChange?(current.id, current.name)
    }

    private func handleNotification() {
        lastNotificationAt = Date()
        if !loggedNotificationDelivered {
            loggedNotificationDelivered = true
            log("ime notification delivered")
        }
        checkForChange()
    }

    private func poll() {
        checkForChange()
    }

    /// Looks for a new source and reports it once the Carbon notification had
    /// its chance to arrive, so a delivered notification is not counted twice.
    private func checkForChange() {
        guard let current = InputSource.current else { return }
        guard current.id != lastID else { return }
        pendingChange = current
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.commitPendingChange()
        }
    }

    private func commitPendingChange() {
        guard let current = pendingChange else { return }
        pendingChange = nil
        guard current.id != lastID else { return }
        lastID = current.id
        if lastNotificationAt == nil, !loggedNotificationMissing {
            loggedNotificationMissing = true
            log("ime notification unusable, 1s poll in use")
        }
        // The source list may have changed with the selection, so the built-in
        // configuration has to be rebuilt to see a newly installed IME.
        InputSource.invalidateBuiltInCache()
        onChange?(current.id, current.name)
    }
}

extension NSColor {
    /// Builds a colour from a "#RRGGBB" string. Returns nil for malformed input.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }

    /// The "#RRGGBB" form of the colour, used in the log.
    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int(round(redComponent * 255)),
               Int(round(greenComponent * 255)),
               Int(round(blueComponent * 255)))
    }
}
