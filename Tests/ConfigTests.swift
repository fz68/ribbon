import Foundation

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

internal func runConfigTests(_ t: TestRunner) {
    t.run("InputSource.configuration") { t in
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
        t.expect(firstWrite, "the first appearance write reports success")
        t.expect(FileManager.default.fileExists(atPath: path),
                 "the temp configuration file exists after the write")

        let firstEntry = decodedSourceEntry(at: path, id: "com.example.testime")
        t.expect(firstEntry != nil, "the configuration decodes as JSON and holds the entry")
        t.expect((firstEntry?["line"] as? Bool) == true, "line is true")
        t.expect((firstEntry?["rainbow"] as? Bool) == true, "rainbow is true")
        t.expect((firstEntry?["color"] as? String) == "#123456",
                 "the exact colour string round-trips")

        let secondWrite = InputSource.setAppearance(id: "com.example.testime",
                                                    name: "Test IME",
                                                    show: true,
                                                    color: "#ABCDEF",
                                                    rainbow: false)
        t.expect(secondWrite, "the second appearance write reports success")

        let secondEntry = decodedSourceEntry(at: path, id: "com.example.testime")
        t.expect((secondEntry?["rainbow"] as? Bool) == false,
                 "the second write turns rainbow off")
        t.expect((secondEntry?["color"] as? String) == "#ABCDEF",
                 "the second write wins with its own colour")
        t.expect((secondEntry?["line"] as? Bool) == true, "line stays true")

        t.expectEqual(FileManager.default.fileExists(atPath: realPath), realExistedBefore,
                      "the real ime.json is still in the state it was before the test")
        t.expectEqual(modificationDate(of: realPath), realModifiedBefore,
                      "the real ime.json was not touched by the test")
    }

    t.run("TimeFormat.configuration") { t in
        let path = TestTemp.path("clock.json")
        try? FileManager.default.removeItem(atPath: path)
        TimeFormat.configurationPath = path

        TimeFormat.apply(format: "HH:mm", locale: "en_US")
        t.expect(FileManager.default.fileExists(atPath: path),
                 "the temp clock configuration exists after apply")

        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        t.expect(json != nil, "the clock configuration decodes as JSON")
        t.expectEqual(json?["format"] as? String, "HH:mm", "the format round-trips")
        t.expectEqual(json?["locale"] as? String, "en_US", "the locale round-trips")

        let components = DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 5)
        guard let date = Calendar.current.date(from: components) else {
            t.expect(false, "Calendar.current should build 2026-10-24 09:05")
            return
        }
        t.expectEqual(TimeFormat.string(from: date), "09:05",
                      "the new format is live at once (the cache was invalidated)")
    }
}
