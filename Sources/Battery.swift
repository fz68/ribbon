import Foundation

/// Battery percentage and charging state from `pmset -g batt`.
enum Battery {
    /// Returns the battery percentage and whether the battery is charging, or nil on failure.
    static func status() -> BatteryState? {
        let result = ProcessRunner.run("/usr/bin/pmset", ["-g", "batt"], timeout: 5)
        guard !result.timedOut,
              result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Reads the percentage and the charging state out of `pmset` output.
    /// Pure, so the parsing is testable without spawning `pmset`.
    static func parse(_ text: String) -> BatteryState? {
        guard let range = text.range(of: "[0-9]{1,3}%", options: .regularExpression),
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
