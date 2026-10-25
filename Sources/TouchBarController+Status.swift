import Cocoa

extension TouchBarController {
    // MARK: - Right cluster actions

    @objc func brightnessDown() {
        applyBrightness(delta: -0.1, name: "down")
    }

    @objc func brightnessUp() {
        applyBrightness(delta: 0.1, name: "up")
    }

    /// Brightness calls are fast, so they run straight on the main thread.
    func applyBrightness(delta: Float, name: String) {
        guard let value = Brightness.adjust(by: delta) else {
            log("brightness \(name) unavailable")
            return
        }
        let rounded = (value * 100).rounded() / 100
        log("brightness \(name) -> \(rounded)")
    }

    @objc func volumeDown() {
        applyVolume(delta: -5, name: "down")
    }

    @objc func volumeUp() {
        applyVolume(delta: 5, name: "up")
    }

    /// The AppleScript call blocks, so it runs on a background queue and logs on main.
    func applyVolume(delta: Int, name: String) {
        volumeQueue.async { [weak self] in
            let result = Volume.adjust(by: delta)
            DispatchQueue.main.async {
                guard let self, !self.didShutdown else { return }
                guard let result else {
                    log("volume \(name) unavailable")
                    return
                }
                log("volume \(name) -> \(result)")
            }
        }
    }

    // MARK: - Status (battery + clock)

    /// Repaints the clock label from the active format.
    func refreshClock() {
        updateClock()
    }

    /// Updates the clock text. Pure formatting, so no process is spawned.
    func updateClock() {
        guard !didShutdown else { return }
        // Skip identical text so a 30 s tick that did not change the minute avoids a no-op CA transaction.
        let text = TimeFormat.string(from: Date())
        if timeLabel.stringValue != text {
            timeLabel.stringValue = text
        }
    }

    /// Reads the battery (one `pmset` call) and updates the percentage label.
    /// A battery percentage changes slowly, so this runs at most every 300 s.
    func updateBattery() {
        guard !didShutdown else { return }
        let timeText = TimeFormat.string(from: Date())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = Battery.status()
            DispatchQueue.main.async {
                guard let self, !self.didShutdown else { return }
                self.applyBattery(status)
                if !self.didLogFirstStatus {
                    self.didLogFirstStatus = true
                    let battery = status.map { "\($0.percent)%\($0.charging ? " charging" : "")" } ?? "unknown"
                    log("status time=\(timeText) battery=\(battery)")
                } else if let current = status {
                    let previous = self.lastBatteryStatus
                    if previous?.percent != current.percent || previous?.charging != current.charging {
                        log("battery changed percent=\(current.percent) charging=\(current.charging)")
                    }
                }
                self.lastBatteryStatus = status
            }
        }
    }

    func applyBattery(_ status: BatteryState?) {
        // Skip identical text so an unchanged battery reading avoids a no-op CA transaction.
        guard let status else {
            if batteryLabel.stringValue != "--%" {
                batteryLabel.stringValue = "--%"
            }
            return
        }
        let text = "\(status.percent)%"
        if batteryLabel.stringValue != text {
            batteryLabel.stringValue = text
        }
    }
}
