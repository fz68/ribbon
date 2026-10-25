import Foundation
import CoreGraphics

/// Brightness control through the private DisplayServices framework.
/// No Accessibility permission, no AppleScript and no key injection are used.
enum Brightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let api: (get: GetBrightness, set: SetBrightness)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(getSymbol, to: GetBrightness.self),
                unsafeBitCast(setSymbol, to: SetBrightness.self))
    }()

    /// The built-in display, falling back to the main display.
    private static func displayID() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(16, &ids, &count) == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }
        return CGMainDisplayID()
    }

    /// Applies `delta` to the current brightness (clamped to 0...1) and returns the new value.
    /// Returns nil when DisplayServices or its symbols are unavailable, or when a call fails.
    static func adjust(by delta: Float) -> Float? {
        guard let api else { return nil }
        let display = displayID()
        var current: Float = 0
        guard api.get(display, &current) == 0 else { return nil }
        let target = min(max(current + delta, 0), 1)
        guard api.set(display, target) == 0 else { return nil }
        return target
    }
}

/// Output volume control through a single AppleScript invocation.
enum Volume {
    /// Adds `delta` to the output volume (clamped to 0...100) and returns the new value.
    /// Synchronous: callers must run it off the main thread. Returns nil on failure.
    static func adjust(by delta: Int) -> Int? {
        let script = """
        set v to (output volume of (get volume settings)) + (\(delta))
        if v > 100 then set v to 100
        if v < 0 then set v to 0
        set volume output volume v
        return v
        """
        let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 5)
        guard !result.timedOut,
              result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(text) else { return nil }
        return min(max(value, 0), 100)
    }
}

/// Battery percentage and charging state from `pmset -g batt`.
enum Battery {
    /// Returns the battery percentage and whether the battery is charging, or nil on failure.
    static func status() -> BatteryState? {
        let result = ProcessRunner.run("/usr/bin/pmset", ["-g", "batt"], timeout: 5)
        guard !result.timedOut,
              result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8),
              let range = text.range(of: "[0-9]{1,3}%", options: .regularExpression),
              let percent = Int(text[range].dropLast()) else { return nil }
        return BatteryState(percent: percent, charging: isCharging(text))
    }

    /// True when the `pmset` output says the battery is charging.
    static func isCharging(_ text: String) -> Bool {
        // Compare whole words so "discharging" and "charged" never count as "charging",
        // and "not charging" is not treated as charging either.
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        var charging = false
        for (index, word) in words.enumerated() where word == "charging" {
            if index == 0 || words[index - 1] != "not" {
                charging = true
            }
        }
        return charging
    }
}

/// The contents of `~/Library/Application Support/Ribbon/clock.json`: the ICU
/// pattern and the BCP 47 locale the clock uses.
struct ClockConfiguration: Codable {
    /// The ICU date format pattern, for example `M月d EEE HH:mm`.
    var format: String
    /// The BCP 47 identifier of the locale that supplies month and weekday names.
    var locale: String

    /// The built-in pattern. It keeps the `星期` -> `周X` remap pipeline.
    static let builtInFormat = "M月d EEE HH:mm"
    /// The built-in locale.
    static let builtInLocale = "zh_CN"

    init(format: String = ClockConfiguration.builtInFormat,
         locale: String = ClockConfiguration.builtInLocale) {
        self.format = format
        self.locale = locale
    }

    /// Decodes a hand-edited file leniently: a missing or empty key keeps its
    /// default, so `{"format": "HH:mm"}` still works instead of failing whole-file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        let locale = try container.decodeIfPresent(String.self, forKey: .locale) ?? ""
        self.format = format.isEmpty ? ClockConfiguration.builtInFormat : format
        self.locale = locale.isEmpty ? ClockConfiguration.builtInLocale : locale
    }
}

/// Renders the clock as `10月24 周六 10:39` by default. The pattern and locale
/// come from `~/Library/Application Support/Ribbon/clock.json`.
enum TimeFormat {
    /// Where the clock configuration is stored.
    ///
    /// Assigning a new path drops the cached configuration and the cached
    /// formatter, so a redirected path is picked up by the next read.
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
            cachedFormatter = nil
        }
    }

    /// The default location of the clock configuration file.
    private static var storedConfigurationPath = (NSString(string: "~/Library/Application Support/Ribbon/clock.json") as NSString).expandingTildeInPath

    /// Weekday names used when the locale emits the full form ("星期六") instead of "周六".
    /// They only apply to the built-in pattern, never to a custom one.
    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    private static let stateLock = NSRecursiveLock()
    private static var cachedFormatter: DateFormatter?

    /// The generic store behind the configuration file. A file that does not
    /// decode is left alone, so a hand edit is never overwritten.
    private static let store = JSONConfigStore<ClockConfiguration>(
        path: { configurationPath },
        fallback: { ClockConfiguration() },
        malformed: .keepFile,
        label: "clock config"
    )

    static func string(from date: Date = Date()) -> String {
        let (configuration, formatter) = activeRenderer()
        let text = formatter.string(from: date)
        // The 星期 -> 周X remap is part of the built-in shape. A custom pattern is
        // rendered verbatim, so "EEEE" may legitimately produce 星期六.
        guard configuration.format == ClockConfiguration.builtInFormat else { return text }
        return abbreviateWeekday(text, date: date)
    }

    /// Remaps the full weekday form ("星期六") onto the short one ("周六").
    static func abbreviateWeekday(_ text: String, date: Date) -> String {
        // zh_CN abbreviates the weekday ("周六"). Should a locale or ICU build emit the
        // full form ("星期六"), fall back to the manual map so the shape stays exact.
        guard text.contains("星期") else { return text }
        let parts = Calendar.current.dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        let index = max(0, min(weekdayNames.count - 1, (parts.weekday ?? 1) - 1))
        return String(format: "%d月%d %@ %02d:%02d",
                      parts.month ?? 0,
                      parts.day ?? 0,
                      weekdayNames[index],
                      parts.hour ?? 0,
                      parts.minute ?? 0)
    }

    /// Writes a picked format to disk and makes it the active one at once.
    /// The file is written first, but the in-memory configuration follows even
    /// when the write fails, so the menu and the bar always agree.
    static func apply(format: String, locale: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let configuration = ClockConfiguration(format: format, locale: locale)
        store.save(configuration)
        cachedFormatter = makeFormatter(configuration)
        log("clock config updated format=\(configuration.format) locale=\(configuration.locale)")
    }

    /// The configuration in use, loaded from disk (and created when missing) on
    /// the first call exactly like the render path does.
    static func currentConfiguration() -> ClockConfiguration {
        activeRenderer().configuration
    }

    /// Re-reads the file for the status menu "Refresh" item, then rebuilds the
    /// formatter. A malformed file is left untouched and the built-in defaults
    /// are used in memory until the next format is picked. A missing file is not
    /// created; the built-in defaults are used in memory alone.
    static func reload() {
        stateLock.lock()
        defer { stateLock.unlock() }
        store.invalidate()
        cachedFormatter = nil
        let configuration = store.loadExisting()
        cachedFormatter = makeFormatter(configuration)
        log("clock config reloaded format=\(configuration.format) locale=\(configuration.locale)")
    }

    /// The configuration and formatter in use. The store keeps the configuration
    /// in memory; the formatter is rebuilt whenever it was invalidated.
    private static func activeRenderer() -> (configuration: ClockConfiguration, formatter: DateFormatter) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let configuration = store.load()
        if let formatter = cachedFormatter {
            return (configuration, formatter)
        }
        let formatter = makeFormatter(configuration)
        cachedFormatter = formatter
        return (configuration, formatter)
    }

    /// Builds the formatter for a configuration. The locale is set before the
    /// pattern so a locale-dependent token is resolved with the right locale.
    static func makeFormatter(_ configuration: ClockConfiguration) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: configuration.locale)
        formatter.dateFormat = configuration.format
        return formatter
    }
}
