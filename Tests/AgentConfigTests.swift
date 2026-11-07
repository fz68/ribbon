import Foundation
import Testing
@testable import RibbonCore

@Suite(.serialized) final class AgentConfigTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testAgentConfigRoundTrip() {
        let path = TestTemp.path("agent-roundtrip.json")
        let previous = AgentConfig.configurationPath
        defer { AgentConfig.configurationPath = previous }
        try? FileManager.default.removeItem(atPath: path)
        AgentConfig.configurationPath = path

        #expect(AgentConfig.current().enabled, "the built-in default is enabled")
        #expect(AgentConfig.setEnabled(false), "the write reports success")

        let object = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        #expect(object?["enabled"] as? Bool == false, "the file holds enabled:false")

        AgentConfig.invalidate()
        #expect(AgentConfig.current().enabled == false, "the file round-trips")

        #expect(AgentConfig.setEnabled(true), "re-enabling writes")
        AgentConfig.invalidate()
        #expect(AgentConfig.current().enabled, "re-enabling round-trips")
    }

    @Test func testMalformedAgentConfigFallsBackToEnabled() {
        let path = TestTemp.path("agent-malformed.json")
        let previous = AgentConfig.configurationPath
        defer { AgentConfig.configurationPath = previous }
        try? Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        AgentConfig.configurationPath = path

        #expect(AgentConfig.current().enabled, "a malformed file uses the default")
        let after = try? String(contentsOfFile: path, encoding: .utf8)
        #expect(after == "not json", "the malformed file is left for hand repair")
    }
}
