import Foundation

/// Mirrors the private weekday table in `Sources/ClockFormat.swift`. The test
/// derives the expected day name from `Calendar.current` instead of hardcoding
/// one, so it stays correct in any time zone and on any calendar.
private let expectedWeekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

internal func runTimeFormatTests(_ t: TestRunner) {
    t.run("TimeFormat.abbreviateWeekday") { t in
        let components = DateComponents(year: 2026, month: 10, day: 24, hour: 10, minute: 39)
        guard let date = Calendar.current.date(from: components) else {
            t.expect(false, "Calendar.current should build 2026-10-24 10:39")
            return
        }

        let untouched = "10月24 周六 10:39"
        t.expectEqual(TimeFormat.abbreviateWeekday(untouched, date: date), untouched,
                      "text without 星期 is returned unchanged")

        let calendar = Calendar.current
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let weekday = calendar.component(.weekday, from: date)
        let nameIndex = max(0, min(expectedWeekdayNames.count - 1, weekday - 1))
        let dayName = expectedWeekdayNames[nameIndex]
        let expected = String(format: "%d月%d %@ %02d:%02d",
                              parts.month ?? 0,
                              parts.day ?? 0,
                              dayName,
                              parts.hour ?? 0,
                              parts.minute ?? 0)

        let rewritten = TimeFormat.abbreviateWeekday("10月24 星期六 10:39", date: date)
        t.expect(!rewritten.contains("星期"),
                 "the rewritten text contains no 星期 (got \(rewritten))")
        t.expectEqual(rewritten, expected,
                      "the rewritten text is the short weekday form")
    }

    t.run("TimeFormat.makeFormatter") { t in
        let components = DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 5)
        guard let date = Calendar.current.date(from: components) else {
            t.expect(false, "Calendar.current should build 2026-10-24 09:05")
            return
        }

        let time = TimeFormat.makeFormatter(ClockConfiguration(format: "HH:mm", locale: "en_US"))
        t.expectEqual(time.string(from: date), "09:05",
                      "HH:mm zero-pads the hour and the minute")

        let year = TimeFormat.makeFormatter(ClockConfiguration(format: "yyyy", locale: "en_US"))
        t.expectEqual(year.string(from: date), "2026", "yyyy renders the calendar year")
    }
}
