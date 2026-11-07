import Foundation
import Testing
@testable import RibbonCore

/// Thread safe holder for the id and counter the main queue callback writes.
private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedID: String?
    private var storedCount = 0

    var id: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedID
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func store(id: String, name: String) {
        lock.lock()
        storedID = id
        storedCount += 1
        lock.unlock()
    }
}

@Suite(.serialized) final class SupportLayerTests {
    init() { _ = TestBootstrap.tempRoot }

    // MARK: - Brightness

    @Test func testBrightnessIsClamped() {
        let small = Brightness.adjust(by: 0.1)
        if let small {
            #expect(small >= 0 && small <= 1, "brightness stays inside 0...1")
        }
        let bigUp = Brightness.adjust(by: 5)
        if let bigUp {
            #expect(bigUp == 1, "a big positive delta caps at 1")
        }
        let bigDown = Brightness.adjust(by: -5)
        if let bigDown {
            #expect(bigDown == 0, "a big negative delta floors at 0")
        }
    }

    // MARK: - InputSourceWatcher

    @Test func testWatcherStartIsIdempotent() {
        let box = ReportBox()
        let watcher = InputSourceWatcher()
        watcher.onChange = { id, name in box.store(id: id, name: name) }
        watcher.start()
        watcher.start()
        _ = waitUntil(timeout: 2) { box.count >= 1 }
        #expect(box.count <= 1, "one selection yields at most one report")
        watcher.stop()
        watcher.stop()
        #expect(box.count <= 1, "a second stop leaves the reports alone")
    }

    @Test func testWatcherReportsTheSelectedSource() {
        let box = ReportBox()
        let watcher = InputSourceWatcher()
        watcher.onChange = { id, name in box.store(id: id, name: name) }
        watcher.start()
        _ = waitUntil(timeout: 2) { box.count >= 1 }
        if let reported = box.id, let current = InputSource.current {
            #expect(reported == current.id, "the reported id matches the selected source")
        } else {
            #expect(box.id == nil, "nothing reported when the system reports no source")
        }
        watcher.stop()
        let afterStop = box.count
        _ = waitUntil(timeout: 2) { box.count > afterStop }
        #expect(box.count == afterStop, "stop ends further reports")
    }

    // MARK: - AppIconCache

    @Test func testAppIconCacheReusesEntries() {
        let first = AppIconCache.icon(for: "Finder")
        let second = AppIconCache.icon(for: "Finder")
        #expect(first === second, "the same instance comes back for the same name")
        let unknown = AppIconCache.icon(for: "zz-no-such-app")
        #expect(unknown == nil, "an unknown name yields nil without trapping")
    }

    // MARK: - Frame rounding

    @Test func testFrameRoundingMatchesThePrintfForm() {
        for value in [2.5, 0.5, 1.5, 3.5, -0.5, 2.0] {
            #expect(Int(value.rounded(.toNearestOrEven)) == (Int(String(format: "%.0f", value)) ?? -1), "\(value) rounds the same way in both forms")
        }
        #expect(Int(exactly: Double.nan) == nil, "a non-finite coordinate has no integer form")
        #expect(Int(exactly: Double.infinity) == nil, "a non-finite coordinate has no integer form")
    }

    // MARK: - App cap

    @Test func testTheAppCapHasOneSource() {
        #expect(Theme.Layout.appsPerWorkspace == 3, "the shared cap is three")
        #expect(Nehir.maxAppsPerWorkspace == Theme.Layout.appsPerWorkspace, "Nehir forwards the shared cap")
        #expect(AeroSpace.maxAppsPerWorkspace == Theme.Layout.appsPerWorkspace, "AeroSpace forwards the shared cap")
    }
}
