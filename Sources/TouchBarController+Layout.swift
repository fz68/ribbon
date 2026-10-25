import Cocoa

extension TouchBarController {
    // MARK: - Layout diagnostics

    /// Logs the measured layout once after a presentation.
    func scheduleLayoutDump() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.layoutDump) { [weak self] in
            self?.dumpLayout()
        }
    }

    func dumpLayout() {
        container.layoutSubtreeIfNeeded()
        // Keep the indicator line in step with the width the system granted.
        updateIMELine()
        let media = mediaStack.frame
        let left = leftStack.frame
        let app = frontAppLabel.frame
        let right = rightStack.frame
        let gap = right.minX - app.maxX
        let free = right.minX - left.maxX
        var hidden: [String] = []
        if mediaStack.isHidden { hidden.append("media") }
        if frontAppLabel.isHidden { hidden.append("app") }
        if brightnessDownButton.isHidden { hidden.append("brightness") }
        if volumeUpButton.isHidden { hidden.append("volume") }
        let current = InputSource.current
        let appearance = current.map { InputSource.appearance(for: $0.id) }
        let line = imeLine.frame
        log(String(format: "layout mode=%@ width=%.0f media=%.0f@%.0f left=%.0f@%.0f app=%.0f@%.0f right=%.0f@%.0f gap=%.0f free=%.0f hidden=%@ ime=%@ line=%d rainbow=%d color=%@ lineFrame=%.0f,%.0f,%.0f,%.0f",
                  controlStripVisible ? "strip" : "full",
                  container.bounds.width,
                  media.width, media.minX,
                  left.width, left.minX,
                  app.width, app.minX,
                  right.width, right.minX,
                  gap, free,
                  hidden.isEmpty ? "-" : hidden.joined(separator: ","),
                  current?.id ?? "-",
                  (appearance?.show ?? false) ? 1 : 0,
                  (appearance?.rainbow ?? false) ? 1 : 0,
                  appearance?.color?.hexString ?? "-",
                  line.minX, line.minY, line.width, line.height))
    }

    func setupContainer() {
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        setupIndicatorLine()
        setupMediaStack()
        setupChipRow()
        setupAppLabel()
        setupRightCluster()
        // The app label is pinned to the chip row on one side and the right
        // cluster on the other, so both have to exist before it is constrained.
        constrainAppLabel()
    }

    private func setupIndicatorLine() {
        // The IME indicator: a 2 pt line along the very bottom edge of the bar.
        // It is added first, so it sits behind the chips. That is fine: it occupies
        // the bottom 2 pt while the 24 pt chips are centred above it, so the two
        // never overlap and the z-order is irrelevant.
        imeLine.wantsLayer = true
        imeLine.isHidden = true
        imeLine.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(imeLine)
        container.bottomLine = imeLine
        imeLine.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: Theme.Layout.indicatorLineHeight)
    }

    private func setupMediaStack() {
        // Far left: the media transport buttons.
        mediaStack.orientation = .horizontal
        mediaStack.alignment = .centerY
        mediaStack.spacing = Theme.Layout.tightSpacing
        mediaStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mediaStack)
        mediaStack.addArrangedSubview(mediaPrevButton)
        mediaStack.addArrangedSubview(mediaPlayPauseButton)
        mediaStack.addArrangedSubview(mediaNextButton)
        NSLayoutConstraint.activate([
            mediaStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Layout.barMargin),
            mediaStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    private func setupChipRow() {
        // Left: the workspace chip row. It sits right of the media buttons in full mode
        // and moves back to the container edge when the Control Strip hides the media stack.
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = Theme.Layout.tightSpacing
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftStack)
        let leadingToMedia = leftStack.leadingAnchor.constraint(equalTo: mediaStack.trailingAnchor, constant: Theme.Layout.clusterGap)
        let leadingToContainer = leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Layout.barMargin)
        leadingToMedia.isActive = true
        leadingToContainer.isActive = false
        leftStackLeadingToMedia = leadingToMedia
        leftStackLeadingToContainer = leadingToContainer
        NSLayoutConstraint.activate([
            leftStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    private func setupAppLabel() {
        // Current app name: immediately right of the last workspace chip.
        frontAppLabel.font = NSFont.systemFont(ofSize: Theme.Layout.labelFontSize, weight: .medium)
        frontAppLabel.textColor = NSColor(argb: Theme.primaryText)
        frontAppLabel.alignment = .left
        frontAppLabel.maximumNumberOfLines = 1
        frontAppLabel.lineBreakMode = .byTruncatingTail
        frontAppLabel.translatesAutoresizingMaskIntoConstraints = false
        frontAppLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        frontAppLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addSubview(frontAppLabel)
    }

    private func setupRightCluster() {
        // Right: brightness, volume, battery and clock.
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = Theme.Layout.clusterSpacing
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)
        container.addSubview(rightStack)
        NSLayoutConstraint.activate([
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Layout.barMargin),
            rightStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        batteryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.labelFontSize, weight: .medium)
        batteryLabel.textColor = NSColor(argb: Theme.primaryText)
        batteryLabel.alignment = .left
        batteryLabel.maximumNumberOfLines = 1

        let batteryStack = NSStackView(views: [batteryLabel])
        batteryStack.orientation = .horizontal
        batteryStack.alignment = .centerY
        batteryStack.spacing = Theme.Layout.microSpacing
        batteryStack.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.labelFontSize, weight: .medium)
        timeLabel.textColor = NSColor(argb: Theme.primaryText)
        timeLabel.alignment = .right
        timeLabel.maximumNumberOfLines = 1
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        rightStack.addArrangedSubview(brightnessDownButton)
        rightStack.addArrangedSubview(brightnessUpButton)
        rightStack.addArrangedSubview(volumeDownButton)
        rightStack.addArrangedSubview(volumeUpButton)
        rightStack.addArrangedSubview(batteryStack)
        rightStack.addArrangedSubview(timeLabel)
        rightStack.addArrangedSubview(controlStripButton)
    }

    private func constrainAppLabel() {
        // The app label yields before it can reach the right cluster.
        let appLabelTrailing = frontAppLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -Theme.Layout.clusterGap)
        appLabelTrailing.priority = NSLayoutConstraint.Priority(Theme.Layout.appLabelTrailingPriority)
        let zeroWidth = frontAppLabel.widthAnchor.constraint(equalToConstant: 0)
        zeroWidth.isActive = false
        appLabelZeroWidth = zeroWidth
        NSLayoutConstraint.activate([
            frontAppLabel.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: Theme.Layout.clusterGap),
            frontAppLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            frontAppLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.Layout.appLabelMaxWidth),
            appLabelTrailing,
        ])
    }

    func makeControlButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = ControlButton()
        button.applyBarButtonStyle()
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.cornerRadius = Theme.Layout.cornerRadius
        button.layer?.backgroundColor = NSColor(argb: Theme.controlBackground).cgColor
        button.contentTintColor = NSColor(argb: Theme.primaryText)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: Theme.Layout.controlSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: Theme.Layout.controlSize).isActive = true
        if let image = SymbolImage.make(symbol, accessibility: tooltip, logContext: tooltip) {
            button.image = image
            button.imageScaling = .scaleProportionallyDown
        }
        return button
    }
}
