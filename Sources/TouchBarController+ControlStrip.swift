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

    /// Identifiers for the current mode.
    ///
    /// Full mode omits the trailing flexible space so the system grants the
    /// item the entire canvas (measured 1004pt); the flexible space claimed the
    /// last few points. Control-strip mode keeps it because the system reserves
    /// the right edge for the strip.
    var itemIdentifiers: [NSTouchBarItem.Identifier] {
        let main = NSTouchBarItem.Identifier("local.ribbon.main")
        return BarLayout(visible: controlStripVisible) == .strip ? [main, .flexibleSpace] : [main]
    }

    /// Switches between the full width bar and the Control Strip presentation.
    @objc func toggleControlStrip() {
        let next = !controlStripVisible
        controlStripVisible = next
        applyControlStripMode(BarLayout(visible: next))
        // The identifiers differ per mode, so the next present uses the new list.
        touchBar.defaultItemIdentifiers = itemIdentifiers
        log(next ? "control strip on" : "control strip off")
        onControlStripStateChanged?(next)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.controlStripRePresent) { [weak self] in
            self?.present()
        }
    }

    /// Applies the layout of one mode. The container keeps a fixed frame, so the width
    /// is changed on the frame instead of adding a width constraint.
    func applyControlStripMode(_ layout: BarLayout) {
        container.frame.size = NSSize(width: layout.width, height: container.frame.height)

        // Strip mode keeps the chips, the battery, the clock and the toggle only.
        mediaStack.isHidden = layout.hidesMediaCluster
        frontAppLabel.isHidden = layout.hidesAppLabel
        appLabelZeroWidth?.isActive = layout.collapsesAppLabel
        // The old anchor is released before the new one is installed, so the two
        // left edge constraints are never active at the same time.
        switch layout.chipRowAnchor {
        case .media:
            leftStackLeadingToContainer?.isActive = false
            leftStackLeadingToMedia?.isActive = true
        case .container:
            leftStackLeadingToMedia?.isActive = false
            leftStackLeadingToContainer?.isActive = true
        }
        for button in [brightnessDownButton, brightnessUpButton, volumeDownButton, volumeUpButton] {
            button.isHidden = layout.hidesSystemKeys
        }

        updateControlStripButton(layout)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        // The indicator line follows the width of the bar in both modes.
        updateIMELine()
    }

    /// Keeps the toggle icon and tooltip in sync with the current mode.
    func updateControlStripButton(_ layout: BarLayout) {
        let visible = layout == .strip
        let show = Self.stripShowSymbol ?? "switch.2"
        let hide = Self.stripHideSymbol ?? show
        let symbol = visible ? hide : show
        if let image = SymbolImage.make(symbol, accessibility: "Control Strip", logContext: "Control Strip") {
            controlStripButton.image = image
            controlStripButton.imageScaling = .scaleProportionallyDown
        }
        let action = visible ? "Hide Control Strip" : "Show Control Strip"
        controlStripButton.toolTip = action
        controlStripButton.setAccessibilityLabel(action)
    }
}
