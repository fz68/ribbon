import Foundation
import Testing
@testable import RibbonCore

/// A tiny configuration payload, so the store is exercised with real JSON.
private struct Prefs: Codable, Equatable {
    var on: Bool
    var name: String
}

/// The text of the file at `path`, or nil when it cannot be read.
private func readText(at path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// Writes `text` to `path`, reporting whether the write succeeded.
private func writeText(_ text: String, to path: String) -> Bool {
    (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
}

@Suite(.serialized) final class JSONConfigStoreTests {
    private let fallback = Prefs(on: false, name: "default")

    init() { _ = TestBootstrap.tempRoot }

    @Test func testJSONConfigStoreLoadCreatesMissingFile() {
        let path = TestTemp.path("store-create.json")
        try? FileManager.default.removeItem(atPath: path)
        let store = JSONConfigStore<Prefs>(path: { path },
                                           fallback: { self.fallback },
                                           malformed: .keepFile,
                                           label: "test config")

        #expect(store.load() == fallback,
                "a missing file loads the built-in default")
        #expect(FileManager.default.fileExists(atPath: path),
                "load creates the file")
        let text = readText(at: path)
        #expect(text != nil, "the created file is readable")
        #expect(text?.contains("\"default\"") == true,
                "the created file holds the default value")
    }

    @Test func testJSONConfigStoreSaveAndCaching() {
        let path = TestTemp.path("store-cache.json")
        try? FileManager.default.removeItem(atPath: path)
        let store = JSONConfigStore<Prefs>(path: { path },
                                           fallback: { self.fallback },
                                           malformed: .keepFile,
                                           label: "test config")

        #expect(store.load() == fallback, "the store starts on the default")
        let saved = Prefs(on: true, name: "saved")
        #expect(store.save(saved), "save reports success")

        let external = "{\"on\": false, \"name\": \"external\"}"
        #expect(writeText(external, to: path),
                "the external write replaced the file")
        #expect(store.load() == saved,
                "load returns the cached value, not the file")

        store.invalidate()
        #expect(store.load() == Prefs(on: false, name: "external"),
                "load re-reads the file after invalidate")
    }

    @Test func testJSONConfigStoreMalformedKeepFile() {
        let path = TestTemp.path("store-keep.json")
        #expect(writeText("not-json{", to: path),
                "the malformed file was written")
        let store = JSONConfigStore<Prefs>(path: { path },
                                           fallback: { self.fallback },
                                           malformed: .keepFile,
                                           label: "test config")

        #expect(store.load() == fallback,
                "a malformed file loads the built-in default")
        #expect(readText(at: path)?.contains("not-json{") == true,
                "keepFile leaves the malformed file untouched")
    }

    @Test func testJSONConfigStoreMalformedOverwriteWithDefault() {
        let path = TestTemp.path("store-overwrite.json")
        #expect(writeText("not-json{", to: path),
                "the malformed file was written")
        let store = JSONConfigStore<Prefs>(path: { path },
                                           fallback: { self.fallback },
                                           malformed: .overwriteWithDefault,
                                           label: "test config")

        #expect(store.load() == fallback,
                "a malformed file loads the built-in default")
        let text = readText(at: path)
        #expect(text?.contains("\"default\"") == true,
                "overwriteWithDefault replaces the malformed file")
    }

    @Test func testJSONConfigStoreLoadExistingNeverCreates() {
        let path = TestTemp.path("store-existing.json")
        try? FileManager.default.removeItem(atPath: path)
        let store = JSONConfigStore<Prefs>(path: { path },
                                           fallback: { self.fallback },
                                           malformed: .keepFile,
                                           label: "test config")

        #expect(store.loadExisting() == fallback,
                "a missing file loads the built-in default")
        #expect(!FileManager.default.fileExists(atPath: path),
                "loadExisting does not create the file")

        #expect(store.load() == fallback,
                "the cached default is kept on the next load")
        #expect(!FileManager.default.fileExists(atPath: path),
                "a later load does not create the file either")
    }

    @Test func testSaveFailsOnUnencodableValue() {
        let path = TestTemp.path("store-inf.json")
        try? FileManager.default.removeItem(atPath: path)
        let store = JSONConfigStore<Double>(path: { path },
                                            fallback: { 0 },
                                            malformed: .keepFile,
                                            label: "test config")

        #expect(!store.save(.infinity),
                "an unencodable value makes save report failure")
        #expect(!FileManager.default.fileExists(atPath: path),
                "the failed save writes no file")
    }

    @Test func testSaveFailsWhenPathIsDirectory() {
        let path = TestTemp.path("store-dir.json")
        try? FileManager.default.removeItem(atPath: path)
        let fixtureMade = (try? FileManager.default.createDirectory(atPath: path,
                                                                    withIntermediateDirectories: true)) != nil
        #expect(fixtureMade, "the directory fixture was created at the store path")
        #expect(FileManager.default.fileExists(atPath: path),
                "the directory still exists before the save")

        let store = JSONConfigStore<Double>(path: { path },
                                            fallback: { 0 },
                                            malformed: .keepFile,
                                            label: "test config")
        #expect(!store.save(1.0),
                "a path that is a directory makes save report failure")
    }
}
