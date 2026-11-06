import Foundation
import Testing
@testable import RibbonCore

/// Thread-safe record of every endpoint the locator reported.
private final class EndpointBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ServiceEndpoint?] = []

    var entries: [ServiceEndpoint?] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var last: ServiceEndpoint?? {
        entries.last
    }

    /// The last non-nil endpoint, ignoring a trailing nil.
    var lastEndpoint: ServiceEndpoint? {
        guard let last = last else { return nil }
        return last
    }

    func append(_ endpoint: ServiceEndpoint?) {
        lock.lock()
        stored.append(endpoint)
        lock.unlock()
    }

    func lastIsNil() -> Bool {
        guard let last = last else { return false }
        return last == nil
    }
}

/// Creates a private directory for one locator test.
///
/// A shared root would make every other suite's file writes look like service
/// registration changes.
private func makeDirectory() throws -> String {
    let path = TestTemp.path("opencode-service-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Writes a registration file the way opencode does: a full write, atomically
/// replaced on the next call.
private func writeService(to path: String,
                          port: Int,
                          password: String,
                          version: String? = "2.1.4",
                          pid: Int? = 4242) throws {
    var object: [String: Any] = [
        "id": UUID().uuidString,
        "url": "http://127.0.0.1:\(port)",
        "password": password,
    ]
    if let version { object["version"] = version }
    if let pid { object["pid"] = pid }
    let data = try JSONSerialization.data(withJSONObject: object)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

@Suite(.serialized) final class OpenCodeServiceLocatorTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testLocatorFollowsCreateReplaceAndDelete() throws {
        let directory = try makeDirectory()
        let path = directory + "/service.json"
        let locator = ServiceLocator(path: path)
        let box = EndpointBox()
        locator.onEndpoint = { endpoint in box.append(endpoint) }
        defer { locator.stop() }

        locator.start()
        #expect(waitUntil { box.entries.count >= 1 }, "start reads the file once")
        #expect(box.lastIsNil() == true, "a missing file reports no endpoint")

        try writeService(to: path, port: 11111, password: "pw-one")
        #expect(waitUntil { box.entries.contains { $0?.password == "pw-one" } },
                "a created file is picked up")
        let first = box.entries.compactMap { $0 }.first { $0.password == "pw-one" }
        #expect(first?.url.absoluteString == "http://127.0.0.1:11111",
                "the url is decoded verbatim")
        #expect(first?.version == "2.1.4", "the version is decoded")
        #expect(first?.pid == 4242, "the pid is decoded")

        // opencode replaces the file atomically (rename over the old inode).
        try writeService(to: path, port: 22222, password: "pw-two")
        #expect(waitUntil { box.entries.contains { $0?.password == "pw-two" } },
                "an atomic replace is caught by the directory source")
        #expect(box.entries.compactMap { $0 }.last?.url.absoluteString == "http://127.0.0.1:22222",
                "the replacement endpoint wins")

        try FileManager.default.removeItem(atPath: path)
        #expect(waitUntil { box.lastIsNil() == true }, "a deleted file reports no endpoint")

        // The directory source must keep working after the file is gone.
        try writeService(to: path, port: 33333, password: "pw-three")
        #expect(waitUntil { box.entries.contains { $0?.password == "pw-three" } },
                "a file recreated after a delete is picked up")
    }

    @Test func testLocatorToleratesMissingOptionalFields() throws {
        let directory = try makeDirectory()
        let path = directory + "/service.json"
        try writeService(to: path, port: 44444, password: "pw", version: nil, pid: nil)

        let locator = ServiceLocator(path: path)
        let box = EndpointBox()
        locator.onEndpoint = { endpoint in box.append(endpoint) }
        defer { locator.stop() }
        locator.start()

        #expect(waitUntil { box.entries.contains { $0?.password == "pw" } },
                "a file without optional fields still decodes")
        let endpoint = box.entries.compactMap { $0 }.first { $0.password == "pw" }
        #expect(endpoint?.version == "", "a missing version becomes an empty string")
        #expect(endpoint?.pid == 0, "a missing pid becomes zero")
    }

    @Test func testLocatorReportsNilForUnusableFile() throws {
        let directory = try makeDirectory()
        let path = directory + "/service.json"
        try writeService(to: path, port: 55555, password: "pw-good")

        let locator = ServiceLocator(path: path)
        let box = EndpointBox()
        locator.onEndpoint = { endpoint in box.append(endpoint) }
        defer { locator.stop() }
        locator.start()
        #expect(waitUntil { box.entries.contains { $0?.password == "pw-good" } },
                "the valid file is reported first")

        // A file that exists but does not describe a service is as good as gone.
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        #expect(waitUntil { box.lastIsNil() == true },
                "an undecodable file reports no endpoint")

        // Recover, so the next nil is a fresh transition rather than a repeat.
        try writeService(to: path, port: 55555, password: "pw-good")
        #expect(waitUntil { box.lastEndpoint?.password == "pw-good" },
                "a valid file after a broken one is reported again")

        // A decodable file without a password is also unusable.
        let noPassword = try JSONSerialization.data(withJSONObject: [
            "url": "http://127.0.0.1:66666",
        ])
        try noPassword.write(to: URL(fileURLWithPath: path), options: .atomic)
        #expect(waitUntil { box.lastIsNil() == true },
                "a file without a password reports no endpoint")
    }

    @Test func testLocatorFindsServiceCreatedUnderAMissingDirectory() throws {
        // The opencode state directory does not exist when ribbon starts, so the
        // locator must watch the nearest existing ancestor.
        let base = try makeDirectory()
        let opencodeDirectory = base + "/opencode"
        let path = opencodeDirectory + "/service.json"

        let locator = ServiceLocator(path: path)
        let box = EndpointBox()
        locator.onEndpoint = { endpoint in box.append(endpoint) }
        defer { locator.stop() }
        locator.start()

        #expect(waitUntil { box.entries.count >= 1 }, "the initial read runs")
        #expect(box.lastIsNil() == true, "there is no file yet")

        try FileManager.default.createDirectory(atPath: opencodeDirectory,
                                                withIntermediateDirectories: true)
        try writeService(to: path, port: 77777, password: "pw-late")

        #expect(waitUntil { box.entries.contains { $0?.password == "pw-late" } },
                "the ancestor watcher promotes to the real directory and reads the new file")
        #expect(box.lastEndpoint?.url.absoluteString == "http://127.0.0.1:77777",
                "the discovered endpoint is decoded")
    }

    @Test func testEndpointRejectsUserInfoInTheURL() throws {
        let directory = try makeDirectory()
        let path = directory + "/service.json"
        let withCredentials = try JSONSerialization.data(withJSONObject: [
            "url": "http://user:secret@127.0.0.1:8080",
            "password": "pw",
        ])
        try withCredentials.write(to: URL(fileURLWithPath: path), options: .atomic)
        #expect(ServiceLocator.endpoint(atPath: path) == nil,
                "a URL carrying userinfo is rejected")

        try writeService(to: path, port: 8080, password: "pw")
        #expect(ServiceLocator.endpoint(atPath: path)?.url.absoluteString == "http://127.0.0.1:8080",
                "a clean URL still decodes")
    }

    @Test func testEndpointNeverExposesPassword() {
        let endpoint = ServiceEndpoint(url: URL(string: "http://127.0.0.1:1")!,
                                       password: "top-secret",
                                       version: "2.1.4",
                                       pid: 9)
        #expect(!String(describing: endpoint).contains("top-secret"))
        #expect(!"\(endpoint)".contains("top-secret"))
        #expect(!String(reflecting: endpoint).contains("top-secret"))
    }
}
