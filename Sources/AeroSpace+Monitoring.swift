import Foundation
import Darwin

extension AeroSpace {
    private static let monitor = WorkspaceMonitor(label: "aerospace",
                                                  subscribeArguments: [
                                                      "subscribe",
                                                      "focused-workspace-changed",
                                                      "window-detected",
                                                      "focused-monitor-changed",
                                                      "focus-changed",
                                                  ],
                                                  validatesJSON: true,
                                                  hasIPC: { hasSubscribe },
                                                  binary: { binary },
                                                  queue: queue,
                                                  reapQueue: reapQueue,
                                                  log: errorLog)

    static func startMonitoring(onChange: @escaping () -> Void) {
        monitor.start(onChange: onChange)
    }

    static func restartMonitoring() {
        monitor.restart()
    }

    static func stopMonitoring() {
        monitor.stop()
    }
}
