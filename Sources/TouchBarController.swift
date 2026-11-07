import Cocoa
import RibbonBridge

private func loadDFRCloseBox() -> (@convention(c) (Bool) -> Void)? {
    let path = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"
    let opened = dlopen(path, RTLD_NOW)
    // dlerror() has to be read right after the failed dlopen, anything else
    // that touches the dynamic linker can clear the message.
    let failure = opened == nil ? dlerror() : nil
    guard let handle = opened else {
        log("DFRFramework dlopen failed: \(failure.map { String(cString: $0) } ?? "unknown error")")
        return nil
    }
    guard let symbol = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else {
        log("DFRSystemModalShowsCloseBoxWhenFrontMost symbol missing")
        return nil
    }
    return unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)
}

public final class TouchBarController: NSObject, NSTouchBarDelegate {
    let touchBar = NSTouchBar()
    lazy var closeBoxFn: (@convention(c) (Bool) -> Void)? = loadDFRCloseBox()
    let container = BarContainer(frame: NSRect(x: 0, y: 0, width: Theme.Layout.fullWidth, height: Theme.Layout.containerHeight))
    let leftStack = NSStackView()
    let workQueue = DispatchQueue(label: "local.ribbon.refresh")
    /// Picked once at launch; AeroSpace first so existing users never change.
    let workspaceBackend: WorkspaceBackend = WorkspaceBackendFactory.make()
    var workspaces: [Workspace] = []
    var pendingRefresh: DispatchWorkItem?
    var refreshTimer: Timer?
    var didShutdown = false
    let frontAppLabel = NSTextField(labelWithString: "")
    var frontAppName = ""
    let rightStack = NSStackView()
    let batteryLabel = NSTextField(labelWithString: "--%")
    let batteryBoltView = NSImageView()
    /// The transient brightness/volume pill, hidden until a step happens.
    let levelPop = LevelPopView()
    /// Hides `levelPop` after the step has been shown for its full interval.
    var levelPopTimer: Timer?

    // MARK: - Agent chip

    /// The read-only OpenCode agent chip, hidden and zero width until the bridge
    /// reports a live endpoint.
    let agentChip = AgentChipView()
    /// 56 while the bridge is healthy, 0 while it is collapsed.
    var agentChipWidth: NSLayoutConstraint?
    /// Owns the locator, event stream, client and reducer behind the chip.
    var agentBridge: AgentBridge?
    /// Drives the pulse and the hairline at 10 Hz while either animates.
    var agentAnimationTimer: Timer?
    var agentAnimationStart: Date?
    /// Republishes the done state once its three second window expires.
    var agentDoneTimer: Timer?
    /// The last published pair, so identical snapshots touch nothing.
    var agentState: AgentChipState?
    var agentVisible = false
    /// The approval card overlay, added last so it floats above everything.
    let agentCard = AgentCardView()
    /// Locked open/decide/close state for the two-tap approval flow.
    var agentCardMachine = AgentCardMachine()
    /// Drives the card timeout and the error flash while the card is open.
    var agentCardTimer: Timer?
    /// The last published bridge snapshot: the chip tap and the replied race
    /// both read the queue from it.
    var agentSnapshot: AgentSnapshot?
    /// WezTerm CLI lookup for jump-to-pane; its pane list is cached between taps.
    let weztermLocator = WeztermLocator()
    /// Serial background queue for the blocking CLI spawns of a jump.
    let agentJumpQueue = DispatchQueue(label: "local.ribbon.agent-jump")
    let timeLabel = NSTextField(labelWithString: "")
    let volumeQueue = DispatchQueue(label: "local.ribbon.volume")
    /// Refreshes the clock. Formatting only, so it never spawns a process.
    var clockTimer: Timer?
    /// Reads the battery. A percentage changes slowly, so this runs rarely.
    var batteryTimer: Timer?
    var lastBatteryStatus: BatteryState?
    var didLogFirstStatus = false

    // MARK: - Media transport

    /// Media buttons, pinned to the leading edge of the bar.
    let mediaStack = NSStackView()
    lazy var mediaPrevButton: NSButton = makeControlButton(
        symbol: "backward.end.fill", tooltip: "Previous track", action: #selector(mediaPrevious)
    )
    lazy var mediaPlayPauseButton: NSButton = makeControlButton(
        symbol: "playpause", tooltip: "Play / pause", action: #selector(mediaPlayPause)
    )
    lazy var mediaNextButton: NSButton = makeControlButton(
        symbol: "forward.end.fill", tooltip: "Next track", action: #selector(mediaNext)
    )
    let mediaQueue = DispatchQueue(label: "local.ribbon.media")
    var mediaTimer: Timer?
    /// Consecutive polls that found no media session at all.
    var mediaPoll = MediaPollPolicy.initial
    /// nil means "state unknown", which shows the neutral play/pause symbol.
    var mediaIsPlaying: Bool?
    var lastLoggedMediaState: Bool?

    // MARK: - Control Strip toggle

    static let controlStripDefaultsKey = "controlStripVisible"
    /// SF Symbols that can stand for the Control Strip toggle.
    static let availableStripSymbols: [String] = ["sidebar.right", "sidebar.squares.right", "switch.2"]
        .filter { SymbolImage.exists($0) }
    /// Symbol shown while the Control Strip is hidden (the next tap shows it).
    static let stripShowSymbol: String? = {
        let available = availableStripSymbols
        return available.first(where: { $0 == "sidebar.squares.right" })
            ?? available.first(where: { $0 == "sidebar.right" })
            ?? available.first
    }()
    /// Symbol shown while the Control Strip is visible (the next tap hides it).
    static let stripHideSymbol: String? = {
        let available = availableStripSymbols
        let show = stripShowSymbol
        return available.first(where: { $0 == "sidebar.right" && $0 != show })
            ?? available.first(where: { $0 != show })
            ?? available.first
    }()
    lazy var controlStripButton: NSButton = makeControlButton(
        symbol: Self.stripShowSymbol ?? "switch.2",
        tooltip: "Show Control Strip",
        action: #selector(toggleControlStrip)
    )
    /// Chip row anchor: right of the media stack in full mode, at the container edge in strip mode.
    var leftStackLeadingToMedia: NSLayoutConstraint?
    var leftStackLeadingToContainer: NSLayoutConstraint?
    /// Collapses the (hidden) app label so it does not reserve width in strip mode.
    var appLabelZeroWidth: NSLayoutConstraint?
    lazy var brightnessDownButton: NSButton = makeControlButton(
        symbol: "sun.min", tooltip: "Brightness down", action: #selector(brightnessDown)
    )
    lazy var brightnessUpButton: NSButton = makeControlButton(
        symbol: "sun.max", tooltip: "Brightness up", action: #selector(brightnessUp)
    )
    lazy var volumeDownButton: NSButton = makeControlButton(
        symbol: "speaker.wave.1", tooltip: "Volume down", action: #selector(volumeDown)
    )
    lazy var volumeUpButton: NSButton = makeControlButton(
        symbol: "speaker.wave.3", tooltip: "Volume up", action: #selector(volumeUp)
    )
    /// Called whenever the Control Strip mode changes, so the status menu can follow.
    var onControlStripStateChanged: ((Bool) -> Void)?

    // MARK: - Input method indicator

    /// The indicator line along the very bottom edge of the bar. It is 2 pt tall
    /// and sits in the 3 pt of slack under the 24 pt chips, so it costs no
    /// horizontal space and never overlaps a control.
    let imeLine = IndicatorLineView(frame: NSRect(x: 0, y: 0, width: Theme.Layout.fullWidth, height: Theme.Layout.indicatorLineHeight))
    /// Watches the selected keyboard input source.
    let imeWatcher = InputSourceWatcher()
    /// Called whenever the selected input source changes, so the status menu can follow.
    var onInputSourceChanged: ((String, String) -> Void)?

    public override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = itemIdentifiers
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
        workspaceBackend.startMonitoring { [weak self] in
            self?.scheduleRefresh()
        }
        scheduleRefresh()
        startTimers()
        updateClock()
        updateBattery()

        // Watch the selected keyboard input source and draw the indicator line.
        imeWatcher.onChange = { [weak self] id, name in
            self?.handleInputSourceChange(id: id, name: name)
        }
        imeWatcher.start()
        updateIMELine()
        logIMESource(prefix: "ime source ->")

        // Restore the persisted Control Strip mode before the bar is presented.
        applyControlStripMode(BarLayout(visible: controlStripVisible))
        log("control strip symbols=\(Self.availableStripSymbols.joined(separator: ","))")

        pollMediaState()
    }

    /// Installs the repeating workspace-refresh, clock and battery timers on the main runloop.
    private func startTimers() {
        let timer = Timer(timeInterval: Theme.Timing.workspaceRefresh, repeats: true) { [weak self] _ in
            self?.scheduleRefresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        let clock = Timer(timeInterval: Theme.Timing.clockRefresh, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock
        let battery = Timer(timeInterval: Theme.Timing.batteryRefresh, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
        RunLoop.main.add(battery, forMode: .common)
        batteryTimer = battery
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
        // The bridge is started after the bar is on screen, so discovery, the
        // first event connection and the reconcile are never on the launch path.
        startAgentBridge()
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.frontAppRefresh) { [weak self] in
            self?.updateFrontApp()
        }
        scheduleRefresh()
        scheduleLayoutDump()
    }

    func dismiss() {
        resetPressedAppearances()
        NSTouchBar.dismissSystemModalTouchBar(touchBar)
        log("dismissed")
    }

    /// A bar dismissed mid-press never sees the release, so a button can be left
    /// in its pressed colour. Reset every pill before the bar goes away, and
    /// abort any agent-chip press so its long-press timer cannot fire after the
    /// bar is gone.
    func resetPressedAppearances() {
        agentChip.cancelPress()
        for button in [mediaPrevButton, mediaPlayPauseButton, mediaNextButton,
                       brightnessDownButton, brightnessUpButton,
                       volumeDownButton, volumeUpButton, controlStripButton] {
            button.layer?.backgroundColor = NSColor(argb: Theme.controlBackground).cgColor
        }
    }

    public func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pendingRefresh?.cancel()
        pendingRefresh = nil
        stopTimers()
        mediaTimer?.invalidate()
        mediaTimer = nil
        stopAgentBridge()
        levelPopTimer?.invalidate()
        levelPopTimer = nil
        imeWatcher.stop()
        workspaceBackend.stopMonitoring()
        dismiss()
        log("shutting down")
    }

    /// Invalidates the timers `startTimers` installed on the main runloop.
    private func stopTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    func refreshNow() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard !didShutdown else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = workspaceBackend.list()
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
        // The agent chip has its own connection and clock; it is refreshed after
        // the workspace path (and outside its early returns) so a slow or empty
        // workspace list cannot delay or skip it.
        updateAgentChip()
    }

    func scheduleRefresh() {
        guard !didShutdown else { return }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshNow()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.refreshDebounce, execute: work)
    }

    @objc private func handleWake(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.wakeRepresent) { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.present()
            workspaceBackend.restartMonitoring()
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

    public func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == NSTouchBarItem.Identifier("local.ribbon.main") else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = container
        return item
    }
}
