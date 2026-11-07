import Cocoa

/// The pure visual description of one chip state.
///
/// Kept apart from the view so the state-to-appearance mapping (including which
/// states animate and which are collapsed) can be tested without AppKit.
struct AgentChipVisual: Equatable {
    /// Pill fill.
    let fill: UInt32
    /// Pill border.
    let border: UInt32
    let textColor: UInt32
    /// The number, `!N`, or nothing.
    let text: String
    /// The small hollow ring drawn for the idle state.
    let showsDot: Bool
    /// Opacity breathes between the pulse floor and 1.
    let pulses: Bool
    /// Two-point bar along the bottom edge that sweeps with progress.
    let hairline: Bool

    static func visual(for state: AgentChipState) -> AgentChipVisual {
        switch state {
        case .off:
            return AgentChipVisual(fill: Theme.controlBackground,
                                   border: Theme.controlBackground,
                                   textColor: Theme.primaryText,
                                   text: "",
                                   showsDot: false,
                                   pulses: false,
                                   hairline: false)
        case .idle:
            // A hollow dot and a dim outline: present, but nothing to report.
            return AgentChipVisual(fill: Theme.controlBackground,
                                   border: Theme.placeholderTint,
                                   textColor: Theme.placeholderTint,
                                   text: "",
                                   showsDot: true,
                                   pulses: false,
                                   hairline: false)
        case .busy(let count):
            // The count uses the border colour, the way a workspace chip's
            // number uses its own border.
            return AgentChipVisual(fill: Theme.controlBackground,
                                   border: Theme.agentBusyBorder,
                                   textColor: Theme.agentBusyBorder,
                                   text: "\(count)",
                                   showsDot: false,
                                   pulses: false,
                                   hairline: true)
        case .awaiting(let count):
            // Amber is light, so the dark focused-chip text stays legible.
            return AgentChipVisual(fill: Theme.agentWaitFill,
                                   border: Theme.agentWaitBorder,
                                   textColor: Theme.focusedChipText,
                                   text: "!\(count)",
                                   showsDot: false,
                                   pulses: true,
                                   hairline: false)
        case .done:
            return AgentChipVisual(fill: Theme.agentDoneFill,
                                   border: Theme.agentDoneFill,
                                   textColor: Theme.focusedChipText,
                                   text: "",
                                   showsDot: false,
                                   pulses: false,
                                   hairline: false)
        }
    }
}

/// The press/long-press decision for the agent chip.
///
/// Split out from the view so tap, long press and the swallowed release are
/// testable without timers or AppKit. The view's timer asks
/// `thresholdReached(at:)`; the release compares the hold duration itself, so a
/// delayed timer can never turn a long hold into a tap.
struct AgentChipPress {
    enum Action: Equatable {
        case none
        case tap
        case longPress
        /// A release that must not also fire a tap: the long press owns it.
        case swallowedRelease
    }

    private let threshold: TimeInterval
    private var pressedAt: Date?
    /// Set when the long press fires; the release and the button action both
    /// consult it.
    private var didLongPress = false

    init(threshold: TimeInterval = Theme.Timing.agentLongPressThreshold) {
        self.threshold = threshold
    }

    /// Aborts an in-flight press without firing anything. Used when the bar is
    /// dismissed mid-press, so no timer or swallow flag survives.
    mutating func cancel() {
        pressedAt = nil
        didLongPress = false
    }

    /// Starts a press. A new press always re-arms the long press.
    mutating func press(at now: Date) -> Action {
        pressedAt = now
        didLongPress = false
        return .none
    }

    /// The chip has been held for the threshold. Fires at most once per press.
    mutating func thresholdReached(at now: Date) -> Action {
        guard let pressedAt, !didLongPress,
              now.timeIntervalSince(pressedAt) >= threshold else {
            return .none
        }
        didLongPress = true
        return .longPress
    }

    /// The finger lifted. A release before the threshold is a tap; a release
    /// after the long press (or after a threshold the timer missed) is
    /// swallowed.
    mutating func release(at now: Date) -> Action {
        guard let pressedAt else { return .none }
        self.pressedAt = nil
        if didLongPress { return .swallowedRelease }
        if now.timeIntervalSince(pressedAt) >= threshold {
            didLongPress = true
            return .swallowedRelease
        }
        return .tap
    }

    /// The button action that follows an inside release. Returns false when a
    /// long press already claimed this press, so the tap handler stays silent.
    mutating func consumeButtonAction() -> Bool {
        guard didLongPress else { return true }
        didLongPress = false
        return false
    }
}

/// The 56x24 agent chip.
///
/// It only renders: the controller owns width, visibility and the single
/// animation timer, and hands in elapsed time. The animation itself is two layer
/// properties (opacity and a hairline frame), so a frame never triggers a layout
/// pass inside the Touch Bar's remote rendering.
final class AgentChipView: NSView {
    /// Full sweep of the busy hairline.
    private static let hairlinePeriod: TimeInterval = 2.4
    private static let hairlineHeight: CGFloat = 2
    /// The hairline never shrinks below a quarter or grows past three quarters
    /// of the chip, so it reads as motion rather than a fill level.
    private static let hairlineMinFraction: CGFloat = 0.25
    private static let hairlineMaxFraction: CGFloat = 0.75
    /// Dim end of the awaiting breath.
    private static let pulseMinOpacity: Float = 0.55

    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let hairline = CALayer()
    /// Full-chip tap target. The chip paints its own pill, so the button only
    /// forwards presses, exactly like the workspace chips.
    private let tapButton = ChipTapButton()
    /// Called on the main thread for a press+release inside the chip that did
    /// not become a long press. Set once by the controller.
    var onTap: (() -> Void)?
    /// Called once when the chip has been held for
    /// `Theme.Timing.agentLongPressThreshold`. Set once by the controller.
    var onLongPress: (() -> Void)?
    /// Hold time for the next press. The controller raises it to
    /// `agentInterruptHold` while no permission is waiting, so an interrupt is a
    /// deliberate 1.2s gesture and a skip stays at 0.5s.
    var longPressThreshold = Theme.Timing.agentLongPressThreshold
    private var press = AgentChipPress()
    private var longPressTimer: Timer?
    private var visual = AgentChipVisual.visual(for: .off)
    private var hairlinePhase: CGFloat = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Theme.Layout.chipWidth,
                                 height: Theme.Layout.controlSize))
        wantsLayer = true
        layer?.cornerRadius = Theme.Layout.cornerRadius
        layer?.borderWidth = 1
        // The hairline sits on the very bottom edge, so it has to be clipped by
        // the pill's rounded corners.
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        label.font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.chipFontSize, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.cell?.wraps = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        dot.wantsLayer = true
        dot.layer?.borderWidth = 1
        dot.layer?.borderColor = NSColor(argb: Theme.placeholderTint).cgColor
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        // A layer, not a subview: it is moved at 10 Hz and a layer avoids a
        // layout pass for every frame of the sweep.
        hairline.backgroundColor = NSColor(argb: Theme.agentBusyBorder).cgColor
        hairline.cornerRadius = 1
        hairline.isHidden = true
        layer?.addSublayer(hairline)

        tapButton.applyBarButtonStyle()
        tapButton.target = self
        tapButton.action = #selector(handleTap)
        // The button action only fires for a release inside; the highlight state
        // also tells us when the press starts, which is what arms the long press.
        tapButton.pressChanged = { [weak self] pressed in
            self?.handlePressChanged(pressed)
        }
        addSubview(tapButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            tapButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tapButton.topAnchor.constraint(equalTo: topAnchor),
            tapButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        apply(visual)
    }

    @objc private func handleTap() {
        // A release after a long press still reaches the button action; the
        // press machine swallows it so the tap does not fire twice.
        guard press.consumeButtonAction() else { return }
        onTap?()
    }

    /// Aborts an in-flight press. Called when the bar is dismissed mid-press:
    /// no timer may outlive it, and the button must not stay highlighted.
    func cancelPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        press.cancel()
        // The didSet of the highlight also reports a release; the machine is
        // already idle, so it produces no action.
        tapButton.isHighlighted = false
    }

    deinit {
        longPressTimer?.invalidate()
    }

    private func handlePressChanged(_ pressed: Bool) {
        if pressed {
            press = AgentChipPress(threshold: longPressThreshold)
            _ = press.press(at: Date())
            longPressTimer?.invalidate()
            let timer = Timer(timeInterval: longPressThreshold,
                              repeats: false) { [weak self] _ in
                guard let self else { return }
                if self.press.thresholdReached(at: Date()) == .longPress {
                    self.onLongPress?()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            longPressTimer = timer
        } else {
            longPressTimer?.invalidate()
            longPressTimer = nil
            _ = press.release(at: Date())
        }
    }

    /// Paints one state. Visibility and width belong to the controller.
    func apply(_ visual: AgentChipVisual) {
        self.visual = visual
        layer?.backgroundColor = NSColor(argb: visual.fill).cgColor
        layer?.borderColor = NSColor(argb: visual.border).cgColor
        label.textColor = NSColor(argb: visual.textColor)
        label.stringValue = visual.text
        dot.isHidden = !visual.showsDot
        hairline.isHidden = !visual.hairline
        hairline.backgroundColor = NSColor(argb: visual.border).cgColor
        if visual.hairline {
            layoutHairline(phase: hairlinePhase)
        } else {
            hairline.frame = .zero
        }
        if !visual.pulses {
            layer?.opacity = 1
        }
    }

    /// Advances the animations for `elapsed` seconds since they started.
    ///
    /// A state that animates nothing only resets the two properties, so the
    /// caller can keep one timer for every state.
    func animate(elapsed: TimeInterval) {
        if visual.pulses {
            let phase = 0.5 - 0.5 * cos(2 * .pi * elapsed / Theme.Timing.agentPulsePeriod)
            layer?.opacity = Self.pulseMinOpacity
                + (1 - Self.pulseMinOpacity) * Float(phase)
        } else {
            layer?.opacity = 1
        }
        if visual.hairline {
            let cycles = elapsed / Self.hairlinePeriod
            let fraction = cycles - floor(cycles)
            // Triangle wave: 0 -> 1 -> 0 over one period.
            let phase = fraction < 0.5 ? fraction * 2 : (1 - fraction) * 2
            layoutHairline(phase: CGFloat(phase))
        }
    }

    override func layout() {
        super.layout()
        if visual.hairline { layoutHairline(phase: hairlinePhase) }
    }

    private func layoutHairline(phase: CGFloat) {
        hairlinePhase = phase
        let fraction = Self.hairlineMinFraction
            + (Self.hairlineMaxFraction - Self.hairlineMinFraction) * phase
        let width = bounds.width * fraction
        hairline.frame = CGRect(x: (bounds.width - width) / 2,
                                y: 0,
                                width: width,
                                height: Self.hairlineHeight)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
