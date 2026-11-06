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
    /// False collapses the chip to zero width.
    let visible: Bool

    static func visual(for state: AgentChipState) -> AgentChipVisual {
        switch state {
        case .off:
            return AgentChipVisual(fill: Theme.controlBackground,
                                   border: Theme.controlBackground,
                                   textColor: Theme.primaryText,
                                   text: "",
                                   showsDot: false,
                                   pulses: false,
                                   hairline: false,
                                   visible: false)
        case .idle:
            // A hollow dot and a dim outline: present, but nothing to report.
            return AgentChipVisual(fill: Theme.controlBackground,
                                   border: Theme.placeholderTint,
                                   textColor: Theme.placeholderTint,
                                   text: "",
                                   showsDot: true,
                                   pulses: false,
                                   hairline: false,
                                   visible: true)
        case .busy(let count):
            // The count uses the border colour, the way a workspace chip's
            // number uses its own border.
            return AgentChipVisual(fill: Theme.controlBackground,
                                   border: Theme.agentBusyBorder,
                                   textColor: Theme.agentBusyBorder,
                                   text: "\(count)",
                                   showsDot: false,
                                   pulses: false,
                                   hairline: true,
                                   visible: true)
        case .awaiting(let count):
            // Amber is light, so the dark focused-chip text stays legible.
            return AgentChipVisual(fill: Theme.agentWaitFill,
                                   border: Theme.agentWaitBorder,
                                   textColor: Theme.focusedChipText,
                                   text: "!\(count)",
                                   showsDot: false,
                                   pulses: true,
                                   hairline: false,
                                   visible: true)
        case .done:
            return AgentChipVisual(fill: Theme.agentDoneFill,
                                   border: Theme.agentDoneFill,
                                   textColor: Theme.focusedChipText,
                                   text: "",
                                   showsDot: false,
                                   pulses: false,
                                   hairline: false,
                                   visible: true)
        }
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

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
        ])

        apply(visual)
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
