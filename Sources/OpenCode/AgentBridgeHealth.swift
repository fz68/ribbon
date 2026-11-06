import Foundation

/// Whether the agent chip should be on the bar at all.
///
/// Split out from the bridge so the two ways the chip disappears - no service
/// registration, or a registration whose service stopped answering - can be
/// pinned without a clock or a network.
enum AgentBridgeHealth {
    /// Visible only while an endpoint exists and it was in contact recently.
    ///
    /// - Parameters:
    ///   - endpoint: whether the locator currently reports a service.
    ///   - lastContact: the last endpoint change, resync or event, if any.
    ///   - now: the instant to evaluate at.
    static func visible(endpoint exists: Bool, lastContact: Date?, now: Date) -> Bool {
        // A registration file alone is not proof: opencode leaves it behind
        // after a crash, so a service that never answers must age out.
        guard exists, let lastContact else { return false }
        return now.timeIntervalSince(lastContact) < Theme.Timing.agentContactWindow
    }
}
