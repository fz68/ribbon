import Foundation
import Darwin

extension Nehir {
    private static let monitor = WorkspaceMonitor(label: "nehirctl",
                                                  subscribeArguments: [
                                                      "subscribe",
                                                      "workspace-bar,windows-changed",
                                                      "--no-send-initial",
                                                  ],
                                                  validatesJSON: false,
                                                  hasIPC: { hasIPC },
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
