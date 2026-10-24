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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(text) else { return nil }
        return min(max(value, 0), 100)
    }
}

/// Battery percentage and charging state from `pmset -g batt`.
enum Battery {
    /// Returns the battery percentage and whether the battery is charging, or nil on failure.
    static func status() -> (percent: Int, charging: Bool)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "batt"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: "[0-9]{1,3}%", options: .regularExpression),
              let percent = Int(text[range].dropLast()) else { return nil }

        // Compare whole words so "discharging" and "charged" never count as "charging",
        // and "not charging" is not treated as charging either.
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        var charging = false
        for (index, word) in words.enumerated() where word == "charging" {
            if index == 0 || words[index - 1] != "not" {
                charging = true
            }
        }
        return (percent, charging)
    }
}

/// Renders the clock as `10月24 周六 10:39`.
enum TimeFormat {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d EEE HH:mm"
        return formatter
    }()

    /// Weekday names used when the locale emits the full form ("星期六") instead of "周六".
    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func string(from date: Date = Date()) -> String {
        let text = formatter.string(from: date)
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
}
