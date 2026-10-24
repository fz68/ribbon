import Cocoa

private let logPath = NSString(string: "~/Library/Logs/ribbon.log").expandingTildeInPath
private let logLock = NSLock()

func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let data = Data(line.utf8)
    logLock.lock()
    defer { logLock.unlock() }
    FileHandle.standardError.write(data)
    let dir = (logPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

private func loadDFRCloseBox() -> (@convention(c) (Bool) -> Void)? {
    let path = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"
    guard let handle = dlopen(path, RTLD_NOW) else {
        log("DFRFramework dlopen failed: \(String(cString: dlerror()))")
        return nil
    }
    guard let symbol = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else {
        log("DFRSystemModalShowsCloseBoxWhenFrontMost symbol missing")
        return nil
    }
    return unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)
}

private let rainbow: [UInt32] = [
    0xffff007c, 0xffc53b53, 0xffff757f, 0xff41a6b5,
    0xff4fd6be, 0xffc3e88d, 0xffffc777, 0xff9d7cd8,
    0xffff9e64, 0xffbb9af7, 0xff7dcfff, 0xff7aa2f7,
]

extension NSColor {
    convenience init(argb: UInt32) {
        self.init(
            srgbRed: CGFloat((argb >> 16) & 0xff) / 255.0,
            green: CGFloat((argb >> 8) & 0xff) / 255.0,
            blue: CGFloat(argb & 0xff) / 255.0,
            alpha: CGFloat((argb >> 24) & 0xff) / 255.0
        )
    }
}

/// Borderless NSButton used for the right cluster controls.
/// NSButton reserves focus-ring padding (alignmentRectInsets top 3.5 / bottom 2.5),
/// which would stretch the 24x24 button to a 24x30 frame. Zeroing the insets keeps
/// the button exactly 24x24 with its background pill and SF Symbol centred.
private final class ControlButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// The bar container. It keeps the IME indicator pinned to the very bottom edge
/// so the line follows the width the system grants (996 pt full, 684 pt strip)
/// instead of the width this process asked for.
private final class BarContainer: NSView {
    /// The 2 pt indicator line along the bottom edge.
    weak var bottomLine: NSView?

    override var frame: NSRect {
        didSet { updateBottomLine() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateBottomLine()
    }

    override func layout() {
        super.layout()
        updateBottomLine()
    }

    private func updateBottomLine() {
        guard let line = bottomLine else { return }
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: line.frame.height)
    }
}

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private let touchBar = NSTouchBar()
    private var isPresented = false
    private lazy var closeBoxFn: (@convention(c) (Bool) -> Void)? = loadDFRCloseBox()
    private let container = BarContainer(frame: NSRect(x: 0, y: 0, width: 1004, height: 30))
    private let leftStack = NSStackView()
    private let workQueue = DispatchQueue(label: "local.ribbon.refresh")
    private var workspaces: [Workspace] = []
    private var pendingRefresh: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var didShutdown = false
    private let frontAppLabel = NSTextField(labelWithString: "")
    private var frontAppName = ""
    private let rightStack = NSStackView()
    private let batteryLabel = NSTextField(labelWithString: "--%")
    private let timeLabel = NSTextField(labelWithString: "")
    private let volumeQueue = DispatchQueue(label: "local.ribbon.volume")
    /// Refreshes the clock. Formatting only, so it never spawns a process.
    private var clockTimer: Timer?
    /// Reads the battery. A percentage changes slowly, so this runs rarely.
    private var batteryTimer: Timer?
    private var lastBatteryStatus: (percent: Int, charging: Bool)?
    private var didLogFirstStatus = false

    // MARK: - Media transport

    /// Media buttons, pinned to the leading edge of the bar.
    private let mediaStack = NSStackView()
    private lazy var mediaPrevButton: NSButton = makeControlButton(
        symbol: "backward.end.fill", tooltip: "Previous track", action: #selector(mediaPrevious)
    )
    private lazy var mediaPlayPauseButton: NSButton = makeControlButton(
        symbol: "playpause", tooltip: "Play / pause", action: #selector(mediaPlayPause)
    )
    private lazy var mediaNextButton: NSButton = makeControlButton(
        symbol: "forward.end.fill", tooltip: "Next track", action: #selector(mediaNext)
    )
    private let mediaQueue = DispatchQueue(label: "local.ribbon.media")
    private var mediaTimer: Timer?
    /// Consecutive polls that found no media session at all.
    private var mediaMissCount = 0
    /// nil means "state unknown", which shows the neutral play/pause symbol.
    private var mediaIsPlaying: Bool?
    private var lastLoggedMediaState: Bool?

    // MARK: - Control Strip toggle

    private static let controlStripDefaultsKey = "controlStripVisible"
    /// SF Symbols that can stand for the Control Strip toggle.
    private static let availableStripSymbols: [String] = ["sidebar.right", "sidebar.squares.right", "switch.2"]
        .filter { NSImage(systemSymbolName: $0, accessibilityDescription: $0) != nil }
    /// Symbol shown while the Control Strip is hidden (the next tap shows it).
    private static let stripShowSymbol: String? = {
        let available = availableStripSymbols
        return available.first(where: { $0 == "sidebar.squares.right" })
            ?? available.first(where: { $0 == "sidebar.right" })
            ?? available.first
    }()
    /// Symbol shown while the Control Strip is visible (the next tap hides it).
    private static let stripHideSymbol: String? = {
        let available = availableStripSymbols
        let show = stripShowSymbol
        return available.first(where: { $0 == "sidebar.right" && $0 != show })
            ?? available.first(where: { $0 != show })
            ?? available.first
    }()
    private lazy var controlStripButton: NSButton = makeControlButton(
        symbol: Self.stripShowSymbol ?? "switch.2",
        tooltip: "Show Control Strip",
        action: #selector(toggleControlStrip)
    )
    /// Chip row anchor: right of the media stack in full mode, at the container edge in strip mode.
    private var leftStackLeadingToMedia: NSLayoutConstraint?
    private var leftStackLeadingToContainer: NSLayoutConstraint?
    /// Collapses the (hidden) app label so it does not reserve width in strip mode.
    private var appLabelZeroWidth: NSLayoutConstraint?
    private lazy var brightnessDownButton: NSButton = makeControlButton(
        symbol: "sun.min", tooltip: "Brightness down", action: #selector(brightnessDown)
    )
    private lazy var brightnessUpButton: NSButton = makeControlButton(
        symbol: "sun.max", tooltip: "Brightness up", action: #selector(brightnessUp)
    )
    private lazy var volumeDownButton: NSButton = makeControlButton(
        symbol: "speaker.wave.1", tooltip: "Volume down", action: #selector(volumeDown)
    )
    private lazy var volumeUpButton: NSButton = makeControlButton(
        symbol: "speaker.wave.3", tooltip: "Volume up", action: #selector(volumeUp)
    )
    /// Called whenever the Control Strip mode changes, so the status menu can follow.
    var onControlStripStateChanged: ((Bool) -> Void)?

    // MARK: - Input method indicator

    /// The indicator line along the very bottom edge of the bar. It is 2 pt tall
    /// and sits in the 3 pt of slack under the 24 pt chips, so it costs no
    /// horizontal space and never overlaps a control.
    private let imeLine = NSView(frame: NSRect(x: 0, y: 0, width: 1004, height: 2))
    /// Watches the selected keyboard input source.
    private let imeWatcher = InputSourceWatcher()
    /// Called whenever the selected input source changes, so the status menu can follow.
    var onInputSourceChanged: ((String, String) -> Void)?

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [NSTouchBarItem.Identifier("local.ribbon.main"), .flexibleSpace]
        setupContainer()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        updateFrontApp()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        AeroSpace.startMonitoring { [weak self] in
            self?.scheduleRefresh()
        }
        scheduleRefresh()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.scheduleRefresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        updateClock()
        updateBattery()
        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock
        let battery = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
        RunLoop.main.add(battery, forMode: .common)
        batteryTimer = battery

        // Watch the selected keyboard input source and draw the indicator line.
        imeWatcher.onChange = { [weak self] id, name in
            self?.handleInputSourceChange(id: id, name: name)
        }
        imeWatcher.start()
        updateIMELine()
        logIMESource(prefix: "ime source ->")

        // Restore the persisted Control Strip mode before the bar is presented.
        applyControlStripMode(visible: controlStripVisible)
        log("control strip symbols=\(Self.availableStripSymbols.joined(separator: ","))")

        pollMediaState()
    }

    func present() {
        if let fn = closeBoxFn {
            fn(false)
        } else {
            log("close-box control unavailable, presenting anyway")
        }
        let placement: Int64 = controlStripVisible ? 0 : 1
        NSTouchBar.presentSystemModalTouchBar(touchBar, placement: placement, systemTrayItemIdentifier: nil)
        log("presented placement=\(placement)")
        isPresented = true
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateFrontApp()
        }
        scheduleRefresh()
        scheduleLayoutDump()
    }

    func dismiss() {
        NSTouchBar.dismissSystemModalTouchBar(touchBar)
        log("dismissed")
        isPresented = false
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        mediaTimer?.invalidate()
        mediaTimer = nil
        imeWatcher.stop()
        AeroSpace.stopMonitoring()
        dismiss()
        log("shutting down")
    }

    func setAppWithControlStripMode() {
        let domain = "com.apple.touchbar.agent" as CFString
        CFPreferencesSetAppValue("PresentationModeGlobal" as CFString, "appWithControlStrip" as CFString, domain)
        CFPreferencesAppSynchronize(domain)
        log("set PresentationModeGlobal=appWithControlStrip")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["ControlStrip"]
        do {
            try task.run()
            log("pkill ControlStrip spawned")
        } catch {
            log("pkill ControlStrip failed: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.present()
        }
    }

    /// Applies the layout of one mode. The container keeps a fixed frame, so the width
    /// is changed on the frame instead of adding a width constraint.
    private func applyControlStripMode(visible: Bool) {
        let width: CGFloat = visible ? 680 : 1004
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
    private func updateControlStripButton() {
        let show = Self.stripShowSymbol ?? "switch.2"
        let hide = Self.stripHideSymbol ?? show
        let symbol = controlStripVisible ? hide : show
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Control Strip") {
            controlStripButton.image = image
            controlStripButton.imageScaling = .scaleProportionallyDown
        } else {
            log("SF Symbol unavailable: \(symbol) (Control Strip)")
        }
        let action = controlStripVisible ? "Hide Control Strip" : "Show Control Strip"
        controlStripButton.toolTip = action
        controlStripButton.setAccessibilityLabel(action)
    }

    // MARK: - Input method indicator

    /// Redraws the indicator line from the current input source.
    func refreshInputSourceIndicator() {
        updateIMELine()
    }

    /// Updates the indicator line: its width follows the container and its look
    /// follows the configured entry of the selected source.
    private func updateIMELine() {
        guard let current = InputSource.current else {
            imeLine.isHidden = true
            return
        }
        let appearance = InputSource.appearance(for: current.id)
        imeLine.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: 2)
        imeLine.isHidden = !appearance.show
        if appearance.show {
            applyIMELineStyle(color: appearance.color, rainbow: appearance.rainbow)
        }
    }

    /// Paints the line: a solid colour or a horizontal rainbow gradient.
    /// No animation runs, the line is static so it costs nothing.
    private func applyIMELineStyle(color: NSColor?, rainbow: Bool) {
        if rainbow {
            let gradient = CAGradientLayer()
            gradient.colors = InputSource.rainbowHex.compactMap { NSColor(hex: $0)?.cgColor }
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.masksToBounds = true
            imeLine.layer = gradient
        } else {
            let solid = CALayer()
            solid.backgroundColor = color?.cgColor
            solid.masksToBounds = true
            imeLine.layer = solid
        }
    }

    /// Called when the selected input source changed.
    private func handleInputSourceChange(id: String, name: String) {
        updateIMELine()
        logIMESource(prefix: "ime changed ->")
        onInputSourceChanged?(id, name)
    }

    /// Logs the current source and what the line shows for it.
    private func logIMESource(prefix: String) {
        guard let current = InputSource.current else {
            log("\(prefix) none")
            return
        }
        let appearance = InputSource.appearance(for: current.id)
        let style: String
        if !appearance.show {
            style = "none"
        } else if appearance.rainbow {
            style = "rainbow"
        } else {
            style = appearance.color?.hexString ?? "-"
        }
        log("\(prefix) \(current.id) (\(current.name)) line=\(style)")
    }

    // MARK: - Media transport

    @objc private func mediaPrevious() {
        Media.command("prev")
        log("media prev")
    }

    @objc private func mediaNext() {
        Media.command("next")
        log("media next")
    }

    @objc private func mediaPlayPause() {
        Media.command("play-pause")
        // Flip optimistically, the poll corrects it a moment later.
        setMediaIcon(playing: !(mediaIsPlaying ?? false))
        log("media play-pause")
    }

    /// Polls the playback state off the main thread and updates the icon on main.
    private func pollMediaState() {
        guard !didShutdown else { return }
        mediaQueue.async { [weak self] in
            guard let self else { return }
            let state = Media.state()
            DispatchQueue.main.async {
                guard !self.didShutdown else { return }
                guard let state else {
                    self.setMediaIcon(playing: nil)
                    self.finishMediaPoll(available: false)
                    return
                }
                self.setMediaIcon(playing: state.available ? state.isPlaying : nil)
                self.finishMediaPoll(available: state.available)
                if state.available, state.isPlaying != self.lastLoggedMediaState {
                    self.lastLoggedMediaState = state.isPlaying
                    log("media state playing=\(state.isPlaying)")
                }
            }
        }
    }

    /// Media poll interval: 30 s normally, 120 s once the last two polls found
    /// no media session at all.
    private var mediaPollInterval: TimeInterval {
        mediaMissCount >= 2 ? 120 : 30
    }

    /// Updates the backoff counter and schedules the next poll.
    private func finishMediaPoll(available: Bool) {
        mediaMissCount = available ? 0 : mediaMissCount + 1
        scheduleMediaPoll()
    }

    /// Schedules the next media poll with the current interval.
    private func scheduleMediaPoll() {
        mediaTimer?.invalidate()
        guard !didShutdown else { return }
        let timer = Timer(timeInterval: mediaPollInterval, repeats: false) { [weak self] _ in
            self?.pollMediaState()
        }
        RunLoop.main.add(timer, forMode: .common)
        mediaTimer = timer
    }

    /// Shows the play, pause or neutral symbol. nil means the state is unknown.
    private func setMediaIcon(playing: Bool?) {
        guard mediaIsPlaying != playing else { return }
        mediaIsPlaying = playing
        let symbol: String
        switch playing {
        case .some(true): symbol = "pause.fill"
        case .some(false): symbol = "play.fill"
        case .none: symbol = "playpause"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Play / pause") {
            mediaPlayPauseButton.image = image
            mediaPlayPauseButton.imageScaling = .scaleProportionallyDown
        } else {
            log("SF Symbol unavailable: \(symbol) (play/pause)")
        }
    }

    // MARK: - Layout diagnostics

    /// Logs the measured layout once after a presentation.
    private func scheduleLayoutDump() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.dumpLayout()
        }
    }

    private func dumpLayout() {
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

    func refreshNow() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard !didShutdown else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = AeroSpace.list()
            DispatchQueue.main.async {
                guard let result else {
                    if self.workspaces.isEmpty {
                        self.rebuildChips()
                    }
                    return
                }
                guard result != self.workspaces else { return }
                self.workspaces = result
                let names = result.map(\.name).joined(separator: ",")
                let focused = result.first(where: \.isFocused)?.name ?? ""
                log("workspaces=[\(names)] focused=\(focused) apps=[\(result.map { "\($0.name):\($0.apps.joined(separator: "/"))" }.joined(separator: " "))]")
                self.rebuildChips()
            }
        }
    }

    private func scheduleRefresh() {
        guard !didShutdown else { return }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshNow()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func setupContainer() {
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        // The IME indicator: a 2 pt line along the very bottom edge of the bar.
        // It is added last so it draws over the rest of the container.
        imeLine.wantsLayer = true
        imeLine.isHidden = true
        imeLine.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(imeLine)
        container.bottomLine = imeLine
        imeLine.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: 2)

        // Far left: the media transport buttons.
        mediaStack.orientation = .horizontal
        mediaStack.alignment = .centerY
        mediaStack.spacing = 4
        mediaStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mediaStack)
        mediaStack.addArrangedSubview(mediaPrevButton)
        mediaStack.addArrangedSubview(mediaPlayPauseButton)
        mediaStack.addArrangedSubview(mediaNextButton)
        NSLayoutConstraint.activate([
            mediaStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            mediaStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // Left: the workspace chip row. It sits right of the media buttons in full mode
        // and moves back to the container edge when the Control Strip hides the media stack.
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 4
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftStack)
        let leadingToMedia = leftStack.leadingAnchor.constraint(equalTo: mediaStack.trailingAnchor, constant: 8)
        let leadingToContainer = leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8)
        leadingToMedia.isActive = true
        leadingToContainer.isActive = false
        leftStackLeadingToMedia = leadingToMedia
        leftStackLeadingToContainer = leadingToContainer
        NSLayoutConstraint.activate([
            leftStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // Current app name: immediately right of the last workspace chip.
        frontAppLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        frontAppLabel.textColor = NSColor(argb: 0xffe2e2e3)
        frontAppLabel.alignment = .left
        frontAppLabel.maximumNumberOfLines = 1
        frontAppLabel.lineBreakMode = .byTruncatingTail
        frontAppLabel.translatesAutoresizingMaskIntoConstraints = false
        frontAppLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        frontAppLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addSubview(frontAppLabel)

        // Right: brightness, volume, battery and clock.
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 6
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)
        container.addSubview(rightStack)
        NSLayoutConstraint.activate([
            rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // The app label yields before it can reach the right cluster.
        let appLabelTrailing = frontAppLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8)
        appLabelTrailing.priority = NSLayoutConstraint.Priority(999)
        let zeroWidth = frontAppLabel.widthAnchor.constraint(equalToConstant: 0)
        zeroWidth.isActive = false
        appLabelZeroWidth = zeroWidth
        NSLayoutConstraint.activate([
            frontAppLabel.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: 8),
            frontAppLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            frontAppLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            appLabelTrailing,
        ])

        batteryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        batteryLabel.textColor = NSColor(argb: 0xffe2e2e3)
        batteryLabel.alignment = .left
        batteryLabel.maximumNumberOfLines = 1

        let batteryStack = NSStackView(views: [batteryLabel])
        batteryStack.orientation = .horizontal
        batteryStack.alignment = .centerY
        batteryStack.spacing = 2
        batteryStack.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = NSColor(argb: 0xffe2e2e3)
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

    private func makeControlButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = ControlButton()
        button.title = ""
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor(argb: 0xff363944).cgColor
        button.contentTintColor = NSColor(argb: 0xffe2e2e3)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.image = image
            button.imageScaling = .scaleProportionallyDown
        } else {
            log("SF Symbol unavailable: \(symbol) (\(tooltip))")
        }
        return button
    }

    private func rebuildChips() {
        for view in leftStack.arrangedSubviews {
            leftStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !workspaces.isEmpty else {
            leftStack.addArrangedSubview(makePlaceholderChip())
            return
        }
        for (index, workspace) in workspaces.enumerated() {
            leftStack.addArrangedSubview(makeChip(workspace, index: index))
        }
    }

    private func makeChip(_ workspace: Workspace, index: Int) -> ChipView {
        let chip = ChipView(
            workspace: workspace,
            index: index,
            target: self,
            action: #selector(chipTapped(_:))
        )
        chip.widthAnchor.constraint(
            equalToConstant: max(40, min(88, chip.stack.fittingSize.width + 16))
        ).isActive = true
        chip.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return chip
    }

    private func makePlaceholderChip() -> NSButton {
        let grey = NSColor(argb: 0xff6c7086)
        let title = NSAttributedString(string: "?", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: grey,
        ])
        let button = NSButton(title: "?", target: self, action: #selector(refreshTapped))
        button.attributedTitle = title
        button.isBordered = false
        button.wantsLayer = true
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        button.layer?.borderColor = grey.cgColor
        button.layer?.backgroundColor = NSColor(argb: 0xff363944).cgColor
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard workspaces.indices.contains(sender.tag) else { return }
        let name = workspaces[sender.tag].name
        log("click workspace \(name)")
        workspaces = workspaces.map { Workspace(name: $0.name, isFocused: $0.name == name, apps: $0.apps) }
        rebuildChips()
        AeroSpace.focus(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scheduleRefresh()
        }
    }

    @objc private func refreshTapped() {
        refreshNow()
    }

    @objc private func handleWake(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.present()
            AeroSpace.restartMonitoring()
            log("wake re-present")
        }
    }

    @objc private func frontAppChanged(_ notification: Notification) {
        updateFrontApp(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func updateFrontApp(_ app: NSRunningApplication? = nil) {
        guard !didShutdown else { return }
        guard let app = app ?? NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let name = app.localizedName, !name.isEmpty,
              name != frontAppName else { return }
        frontAppName = name
        frontAppLabel.stringValue = name
        log("front app=\(name)")
    }

    // MARK: - Right cluster actions

    @objc private func brightnessDown() {
        applyBrightness(delta: -0.1, name: "down")
    }

    @objc private func brightnessUp() {
        applyBrightness(delta: 0.1, name: "up")
    }

    /// Brightness calls are fast, so they run straight on the main thread.
    private func applyBrightness(delta: Float, name: String) {
        guard let value = Brightness.adjust(by: delta) else {
            log("brightness \(name) unavailable")
            return
        }
        let rounded = (value * 100).rounded() / 100
        log("brightness \(name) -> \(rounded)")
    }

    @objc private func volumeDown() {
        applyVolume(delta: -5, name: "down")
    }

    @objc private func volumeUp() {
        applyVolume(delta: 5, name: "up")
    }

    /// The AppleScript call blocks, so it runs on a background queue and logs on main.
    private func applyVolume(delta: Int, name: String) {
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

    /// Updates the clock text. Pure formatting, so no process is spawned.
    private func updateClock() {
        guard !didShutdown else { return }
        timeLabel.stringValue = TimeFormat.string(from: Date())
    }

    /// Reads the battery (one `pmset` call) and updates the percentage label.
    /// A battery percentage changes slowly, so this runs at most every 300 s.
    private func updateBattery() {
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

    private func applyBattery(_ status: (percent: Int, charging: Bool)?) {
        guard let status else {
            batteryLabel.stringValue = "--%"
            return
        }
        batteryLabel.stringValue = "\(status.percent)%"
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == NSTouchBarItem.Identifier("local.ribbon.main") else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = container
        return item
    }
}

private final class ChipView: NSView {
    let stack = NSStackView()

    init(workspace: Workspace, index: Int, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        let color = workspace.isFocused
            ? NSColor(argb: 0xffe7c664)
            : NSColor(argb: rainbow[(index + 1) % rainbow.count])
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = color.cgColor
        layer?.backgroundColor = NSColor(argb: 0xff363944).cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let number = NSTextField(labelWithString: workspace.name)
        number.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        number.textColor = color
        number.maximumNumberOfLines = 1
        stack.addArrangedSubview(number)
        stack.setCustomSpacing(6, after: number)

        for app in workspace.apps.prefix(3) {
            guard let image = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == app })?.icon
                ?? NSImage(named: NSImage.applicationIconName) else { continue }
            let icon = NSImageView(image: image)
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 12).isActive = true
            stack.addArrangedSubview(icon)
        }

        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.tag = index
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
