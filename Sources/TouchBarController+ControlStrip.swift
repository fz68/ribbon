import Cocoa

extension TouchBarController {
    func setAppWithControlStripMode() {
        let domain = "com.apple.touchbar.agent" as CFString
        CFPreferencesSetAppValue("PresentationModeGlobal" as CFString, "appWithControlStrip" as CFString, domain)
        CFPreferencesAppSynchronize(domain)
        log("set PresentationModeGlobal=appWithControlStrip")
        // The menu action runs on the main thread, so the spawn is detached:
        // it must not block the UI while pkill does its work.
        ProcessRunner.runDetached("/usr/bin/pkill", ["ControlStrip"], timeout: Theme.Timing.controlStripTimeout) { result in
            if let error = result.launchError {
                log("pkill ControlStrip failed: \(error)")
            }
        }
        log("pkill ControlStrip requested")
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.controlStripRestart) { [weak self] in
            self?.present()
        }
    }

    // MARK: - Control Strip mode

    /// Whether the bar is currently in Control Strip mode (persisted across launches).
    var controlStripVisible: Bool {
        get { UserDefaults.standard.bool(forKey: Self.controlStripDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.controlStripDefaultsKey) }
    }

    /// Switches between the full width bar and the Control Strip presentation.
    @objc func toggleControlStrip() {
        let next = !controlStripVisible
        controlStripVisible = next
        applyControlStripMode(visible: next)
        log(next ? "control strip on" : "control strip off")
        onControlStripStateChanged?(next)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.settle) { [weak self] in
            self?.present()
        }
    }

    /// Applies the layout of one mode. The container keeps a fixed frame, so the width
    /// is changed on the frame instead of adding a width constraint.
    func applyControlStripMode(visible: Bool) {
        let width: CGFloat = visible ? Theme.Layout.stripWidth : Theme.Layout.fullWidth
        container.frame.size = NSSize(width: width, height: container.frame.height)

        // Strip mode keeps the chips, the battery, the clock and the toggle only.
        mediaStack.isHidden = visible
        frontAppLabel.isHidden = visible
        appLabelZeroWidth?.isActive = visible
        // The old anchor is released before the new one is installed, so the two
        // left edge constraints are never active at the same time.
        if visible {
            leftStackLeadingToMedia?.isActive = false
            leftStackLeadingToContainer?.isActive = true
        } else {
            leftStackLeadingToContainer?.isActive = false
            leftStackLeadingToMedia?.isActive = true
        }
        for button in [brightnessDownButton, brightnessUpButton, volumeDownButton, volumeUpButton] {
            button.isHidden = visible
        }

        updateControlStripButton()
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        // The indicator line follows the width of the bar in both modes.
        updateIMELine()
    }

    /// Keeps the toggle icon and tooltip in sync with the current mode.
    func updateControlStripButton() {
        let show = Self.stripShowSymbol ?? "switch.2"
        let hide = Self.stripHideSymbol ?? show
        let symbol = controlStripVisible ? hide : show
        if let image = SymbolImage.make(symbol, accessibility: "Control Strip", logContext: "Control Strip") {
            controlStripButton.image = image
            controlStripButton.imageScaling = .scaleProportionallyDown
        }
        let action = controlStripVisible ? "Hide Control Strip" : "Show Control Strip"
        controlStripButton.toolTip = action
        controlStripButton.setAccessibilityLabel(action)
    }
}
