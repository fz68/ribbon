import Cocoa
import Foundation
import Testing
@testable import RibbonCore

/// The modification date of `path`, or nil when the file does not exist.
private func modificationDate(of path: String) -> Date? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    return attributes[.modificationDate] as? Date
}

/// The `sources[id]` object of the configuration file at `path`, or nil when
/// the file is missing or is not the expected JSON shape.
private func decodedSourceEntry(at path: String, id: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
    guard let object = json as? [String: Any] else { return nil }
    guard let sources = object["sources"] as? [String: Any] else { return nil }
    return sources[id] as? [String: Any]
}

@Suite(.serialized) final class ConfigTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testInputSourceConfiguration() {
        let path = TestTemp.path("ime.json")
        try? FileManager.default.removeItem(atPath: path)
        // The redirected path clears the cache, so the write lands in the temp
        // directory instead of the real Application Support file.
        InputSource.configurationPath = path

        let realPath = (NSString(string: "~/Library/Application Support/Ribbon/ime.json") as NSString)
            .expandingTildeInPath
        let realExistedBefore = FileManager.default.fileExists(atPath: realPath)
        let realModifiedBefore = modificationDate(of: realPath)

        let firstWrite = InputSource.setAppearance(id: "com.example.testime",
                                                   name: "Test IME",
                                                   show: true,
                                                   color: "#123456",
                                                   rainbow: true)
        #expect(firstWrite, "the first appearance write reports success")
        #expect(FileManager.default.fileExists(atPath: path),
                "the temp configuration file exists after the write")

        let firstEntry = decodedSourceEntry(at: path, id: "com.example.testime")
        #expect(firstEntry != nil, "the configuration decodes as JSON and holds the entry")
        #expect((firstEntry?["line"] as? Bool) == true, "line is true")
        #expect((firstEntry?["rainbow"] as? Bool) == true, "rainbow is true")
        #expect((firstEntry?["color"] as? String) == "#123456",
                "the exact colour string round-trips")

        let secondWrite = InputSource.setAppearance(id: "com.example.testime",
                                                    name: "Test IME",
                                                    show: true,
                                                    color: "#ABCDEF",
                                                    rainbow: false)
        #expect(secondWrite, "the second appearance write reports success")

        let secondEntry = decodedSourceEntry(at: path, id: "com.example.testime")
        #expect((secondEntry?["rainbow"] as? Bool) == false,
                "the second write turns rainbow off")
        #expect((secondEntry?["color"] as? String) == "#ABCDEF",
                "the second write wins with its own colour")
        #expect((secondEntry?["line"] as? Bool) == true, "line stays true")

        #expect(FileManager.default.fileExists(atPath: realPath) == realExistedBefore,
                "the real ime.json is still in the state it was before the test")
        #expect(modificationDate(of: realPath) == realModifiedBefore,
                "the real ime.json was not touched by the test")
    }

    @Test func testTimeFormatConfiguration() {
        let path = TestTemp.path("clock.json")
        try? FileManager.default.removeItem(atPath: path)
        TimeFormat.configurationPath = path

        TimeFormat.apply(format: "HH:mm", locale: "en_US")
        #expect(FileManager.default.fileExists(atPath: path),
                "the temp clock configuration exists after apply")

        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        #expect(json != nil, "the clock configuration decodes as JSON")
        #expect(json?["format"] as? String == "HH:mm", "the format round-trips")
        #expect(json?["locale"] as? String == "en_US", "the locale round-trips")

        let components = DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 5)
        guard let date = Calendar.current.date(from: components) else {
            #expect(Bool(false), "Calendar.current should build 2026-10-24 09:05")
            return
        }
        #expect(TimeFormat.string(from: date) == "09:05",
                "the new format is live at once (the cache was invalidated)")
    }

    @Test func testCurrentInputSourceIsUsable() {
        // A headless runner may report no selected source; that is not a failure.
        let current = InputSource.current
        #expect(current == nil || current?.id.isEmpty == false,
                "a reported input source has a non-empty id")
        #expect(current == nil || current?.name.isEmpty == false,
                "a reported input source has a non-empty localized name")
    }

    @Test func testRainbowHexMatchesPalette() {
        #expect(InputSource.rainbowHex == InputSource.palette.map(\.hex),
                "the rainbow stops are the palette colours in order")
        #expect(InputSource.rainbowHex == ["#FF5F57", "#FF8C42", "#FFD60A", "#4CD964",
                                           "#40C8E0", "#4FA3FF", "#B388FF"],
                "the palette holds the seven documented hex values")
    }

    @Test func testAppearanceSuppressesPlainKeyboard() {
        let path = TestTemp.path("ime-plain.json")
        try? FileManager.default.removeItem(atPath: path)
        InputSource.configurationPath = path
        InputSource.invalidateBuiltInCache()

        // The built-in rule is id based, so it holds whether or not the system
        // has this layout enabled right now.
        let id = "com.apple.keylayout.US"
        #expect(InputSource.isPlainKeyboardLayout(id: id),
                "the fixture id is a plain keyboard layout")
        let defaultColor = InputSource.builtInConfiguration().default.color
        #expect(defaultColor == "#4FA3FF", "the built-in default colour is the blue palette entry")

        let appearance = InputSource.appearance(for: id)
        #expect(appearance.show == false, "a plain keyboard layout draws no line")
        #expect(appearance.rainbow == false, "a plain keyboard layout is not a rainbow")
        #expect(appearance.color?.hexString == defaultColor,
                "a plain keyboard layout gets the fallback colour")
    }

    @Test func testAppearanceForUnknownSourceUsesDefault() {
        let path = TestTemp.path("ime-unknown.json")
        try? FileManager.default.removeItem(atPath: path)
        InputSource.configurationPath = path
        InputSource.invalidateBuiltInCache()

        let configuration = InputSource.configuration()
        #expect(configuration.default.line == true,
                "the built-in default shows a line for a non-keyboard source")
        #expect(configuration.default.rainbow == false,
                "the built-in default is a solid colour")

        let unknown = "com.example.not-installed.\(UUID().uuidString)"
        #expect(configuration.sources[unknown] == nil, "the fixture id has no entry of its own")

        let appearance = InputSource.appearance(for: unknown)
        #expect(appearance.show == configuration.default.line,
                "an unknown source follows the default line flag")
        #expect(appearance.rainbow == configuration.default.rainbow,
                "an unknown source follows the default rainbow flag")
        #expect(appearance.color?.hexString == configuration.default.color,
                "an unknown source follows the default colour")
    }

    @Test func testAppearanceUsesSavedEntry() {
        let path = TestTemp.path("ime-saved.json")
        try? FileManager.default.removeItem(atPath: path)
        InputSource.configurationPath = path

        let id = "com.example.savedime"
        #expect(InputSource.setAppearance(id: id, name: "Saved IME",
                                          show: true, color: "#123456", rainbow: true),
                "the appearance write reports success")

        let saved = InputSource.appearance(for: id)
        #expect(saved.show == true, "the saved line flag is used")
        #expect(saved.rainbow == true, "the saved rainbow flag is used")
        #expect(saved.color?.hexString == "#123456", "the saved colour is used")

        #expect(InputSource.setAppearance(id: id, name: "Saved IME",
                                          show: false, color: nil, rainbow: false),
                "the second appearance write reports success")
        let updated = InputSource.appearance(for: id)
        #expect(updated.show == false, "the updated line flag is used")
        #expect(updated.rainbow == false, "the updated rainbow flag is used")
        #expect(updated.color?.hexString == "#123456",
                "a nil colour keeps the previously saved colour")
    }

    @Test func testInvalidateBuiltInCacheKeepsDefaults() {
        InputSource.invalidateBuiltInCache()
        let first = InputSource.builtInConfiguration()
        InputSource.invalidateBuiltInCache()
        let second = InputSource.builtInConfiguration()

        #expect(first.default.name == second.default.name, "the default name is unchanged")
        #expect(first.default.line == second.default.line, "the default line flag is unchanged")
        #expect(first.default.color == second.default.color, "the default colour is unchanged")
        #expect(first.default.rainbow == second.default.rainbow,
                "the default rainbow flag is unchanged")
        #expect(first.sources.keys.sorted() == second.sources.keys.sorted(),
                "the rebuilt configuration holds the same source ids")

        var identical = true
        for (id, entry) in first.sources {
            guard let other = second.sources[id] else {
                identical = false
                continue
            }
            if other.name != entry.name || other.line != entry.line
                || other.color != entry.color || other.rainbow != entry.rainbow {
                identical = false
            }
        }
        #expect(identical, "every rebuilt source entry matches the cached one")
    }

    @Test func testLegacyConfigurationMigration() {
        let savedConfigurationPath = InputSource.configurationPath
        let savedLegacyPath = InputSource.legacyConfigurationPath
        let savedDidMigrate = InputSource.didMigrateLegacyConfiguration
        defer {
            InputSource.configurationPath = savedConfigurationPath
            InputSource.legacyConfigurationPath = savedLegacyPath
            InputSource.didMigrateLegacyConfiguration = savedDidMigrate
        }

        let legacyJSON = """
        {"default":{"line":true,"color":"#123456","rainbow":true},"sources":{"com.example.legacy":{"name":"Legacy IME","line":true,"color":"#123456","rainbow":false}}}
        """
        let existingJSON = """
        {"default":{"line":false,"color":"#ABCDEF","rainbow":false},"sources":{"com.example.existing":{"name":"Existing IME","line":true,"color":"#ABCDEF","rainbow":false}}}
        """

        // A missing destination is filled from the legacy file.
        let legacy = TestTemp.path("legacy-ime-migrate.json")
        let destination = TestTemp.path("ime-migrate-destination.json")
        try? FileManager.default.removeItem(atPath: legacy)
        try? FileManager.default.removeItem(atPath: destination)
        #expect(FileManager.default.createFile(atPath: legacy, contents: Data(legacyJSON.utf8)),
                "the legacy configuration was written")

        InputSource.configurationPath = destination
        InputSource.legacyConfigurationPath = legacy
        InputSource.didMigrateLegacyConfiguration = false
        _ = InputSource.configuration()

        let migrated = (try? Data(contentsOf: URL(fileURLWithPath: destination))) ?? Data()
        #expect(!migrated.isEmpty, "the migration created the destination file")
        #expect(migrated == Data(legacyJSON.utf8),
                "the destination is byte-identical to the legacy configuration")

        // An existing destination is never overwritten.
        let legacy2 = TestTemp.path("legacy-ime-migrate-second.json")
        let destination2 = TestTemp.path("ime-migrate-existing.json")
        try? FileManager.default.removeItem(atPath: legacy2)
        try? FileManager.default.removeItem(atPath: destination2)
        #expect(FileManager.default.createFile(atPath: legacy2, contents: Data(legacyJSON.utf8)),
                "the second legacy configuration was written")
        #expect(FileManager.default.createFile(atPath: destination2, contents: Data(existingJSON.utf8)),
                "the existing configuration was written")

        InputSource.configurationPath = destination2
        InputSource.legacyConfigurationPath = legacy2
        InputSource.didMigrateLegacyConfiguration = false
        _ = InputSource.configuration()

        let unchanged = (try? Data(contentsOf: URL(fileURLWithPath: destination2))) ?? Data()
        #expect(unchanged == Data(existingJSON.utf8),
                "an existing configuration is not overwritten by the migration")
    }
}
