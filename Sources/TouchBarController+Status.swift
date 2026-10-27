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
        showLevel(Double(value))
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
                self.showLevel(Double(result) / 100)
                log("volume \(name) -> \(result)")
            }
        }
    }

    /// Flashes the centred level pill and re-arms its auto-hide timer. Both
    /// callers already run on the main thread.
    func showLevel(_ level: Double) {
        levelPop.show(level: CGFloat(level))
        levelPopTimer?.invalidate()
        let timer = Timer(timeInterval: Theme.Timing.levelPop, repeats: false) { [weak self] _ in
            self?.levelPop.isHidden = true
        }
        RunLoop.main.add(timer, forMode: .common)
        levelPopTimer = timer
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
        // A full battery reads "F" instead of "100%". Otherwise the label shows
        // the number; while charging the bolt follows it and the "%" sign is
        // dropped ("60" + bolt), so the fixed-width slot never changes. A nil
        // status means "unknown": "--%" and no bolt.
        let charging = status?.charging ?? false
        batteryBoltView.isHidden = !charging
        // Skip identical text so an unchanged battery reading avoids a no-op CA transaction.
        let text: String
        if let status {
            text = status.percent == 100 ? "F" : (charging ? "\(status.percent)" : "\(status.percent)%")
        } else {
            text = "--%"
        }
        if batteryLabel.stringValue != text {
            batteryLabel.stringValue = text
        }
    }
}
