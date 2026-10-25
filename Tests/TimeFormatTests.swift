import Foundation
import Testing
@testable import RibbonCore

/// Mirrors the private weekday table in `Sources/ClockFormat.swift`. The test
/// derives the expected day name from `Calendar.current` instead of hardcoding
/// one, so it stays correct in any time zone and on any calendar.
private let expectedWeekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

@Suite(.serialized) final class TimeFormatTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testTimeFormatAbbreviateWeekday() {
        let components = DateComponents(year: 2026, month: 10, day: 24, hour: 10, minute: 39)
        guard let date = Calendar.current.date(from: components) else {
            #expect(Bool(false), "Calendar.current should build 2026-10-24 10:39")
            return
        }

        let untouched = "10月24 周六 10:39"
        #expect(TimeFormat.abbreviateWeekday(untouched, date: date) == untouched,
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
        #expect(!rewritten.contains("星期"),
                "the rewritten text contains no 星期 (got \(rewritten))")
        #expect(rewritten == expected,
                "the rewritten text is the short weekday form")
    }

    @Test func testTimeFormatMakeFormatter() {
        let components = DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 5)
        guard let date = Calendar.current.date(from: components) else {
            #expect(Bool(false), "Calendar.current should build 2026-10-24 09:05")
            return
        }

        let time = TimeFormat.makeFormatter(ClockConfiguration(format: "HH:mm", locale: "en_US"))
        #expect(time.string(from: date) == "09:05",
                "HH:mm zero-pads the hour and the minute")

        let year = TimeFormat.makeFormatter(ClockConfiguration(format: "yyyy", locale: "en_US"))
        #expect(year.string(from: date) == "2026", "yyyy renders the calendar year")
    }

    @Test func testClockConfigurationLenientDecode() {
        let decoder = JSONDecoder()

        guard let empty = try? decoder.decode(ClockConfiguration.self, from: Data("{}".utf8)) else {
            #expect(Bool(false), "{} decodes to the built-in clock configuration")
            return
        }
        let defaults = ClockConfiguration()
        #expect(empty.format == defaults.format, "a missing format keeps the built-in pattern")
        #expect(empty.locale == defaults.locale, "a missing locale keeps the built-in locale")
        #expect(empty.format == ClockConfiguration.builtInFormat,
                "the built-in pattern is M月d EEE HH:mm")
        #expect(empty.locale == ClockConfiguration.builtInLocale,
                "the built-in locale is zh_CN")

        guard let partial = try? decoder.decode(ClockConfiguration.self,
                                                from: Data("{\"format\":\"HH:mm\"}".utf8)) else {
            #expect(Bool(false), "a partial file decodes leniently")
            return
        }
        #expect(partial.format == "HH:mm", "the provided format is used")
        #expect(partial.locale == defaults.locale, "the missing locale keeps the built-in locale")

        guard let blank = try? decoder.decode(ClockConfiguration.self,
                                              from: Data("{\"format\":\"\",\"locale\":\"\"}".utf8)) else {
            #expect(Bool(false), "a file with empty strings decodes leniently")
            return
        }
        #expect(blank.format == defaults.format, "an empty format falls back to the built-in pattern")
        #expect(blank.locale == defaults.locale, "an empty locale falls back to the built-in locale")
    }

    @Test func testStringUsesBuiltinFormat() {
        let path = TestTemp.path("clock.json")
        try? FileManager.default.removeItem(atPath: path)
        TimeFormat.configurationPath = path
        // `reload` uses `loadExisting`, so the deleted file is not recreated and
        // the built-in configuration is the one in memory.
        TimeFormat.reload()

        let configuration = TimeFormat.currentConfiguration()
        #expect(configuration.format == ClockConfiguration.builtInFormat,
                "the built-in pattern is active when the file is missing")
        #expect(configuration.locale == ClockConfiguration.builtInLocale,
                "the built-in locale is active when the file is missing")

        let components = DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 5)
        guard let date = Calendar.current.date(from: components) else {
            #expect(Bool(false), "Calendar.current should build 2026-10-24 09:05")
            return
        }

        let calendar = Calendar.current
        let parts = calendar.dateComponents([.month, .day], from: date)
        let weekday = calendar.component(.weekday, from: date)
        let nameIndex = max(0, min(expectedWeekdayNames.count - 1, weekday - 1))
        let dayName = expectedWeekdayNames[nameIndex]
        let text = TimeFormat.string(from: date)

        #expect(text.contains("10月24"), "the pattern renders M月d as 10月24 (got \(text))")
        #expect(text.contains(dayName), "the pattern renders EEE as the short weekday (got \(text))")
        #expect(text.contains("09:05"), "the pattern renders HH:mm zero padded (got \(text))")
        #expect(text == "\(parts.month ?? 0)月\(parts.day ?? 0) \(dayName) 09:05",
                "the built-in pattern lays the date before the zero padded time (got \(text))")
    }

    @Test func testReloadDropsDeletedFile() {
        let path = TestTemp.path("clock.json")
        try? FileManager.default.removeItem(atPath: path)
        TimeFormat.configurationPath = path

        TimeFormat.apply(format: "yyyy", locale: "en_US")
        let applied = TimeFormat.currentConfiguration()
        #expect(applied.format == "yyyy", "apply makes the picked format active at once")
        #expect(applied.locale == "en_US", "apply makes the picked locale active at once")
        #expect(FileManager.default.fileExists(atPath: path),
                "apply writes the configuration file")

        try? FileManager.default.removeItem(atPath: path)
        #expect(!FileManager.default.fileExists(atPath: path),
                "the configuration file is gone before the reload")

        TimeFormat.reload()
        let reverted = TimeFormat.currentConfiguration()
        #expect(reverted.format == ClockConfiguration.builtInFormat,
                "reload falls back to the built-in pattern after the file is deleted")
        #expect(reverted.locale == ClockConfiguration.builtInLocale,
                "reload falls back to the built-in locale after the file is deleted")
        #expect(!FileManager.default.fileExists(atPath: path),
                "reload does not recreate a deleted clock.json")
    }
}
