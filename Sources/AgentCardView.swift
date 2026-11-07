import Cocoa

/// One cell of the approval card.
///
/// Mirrors ControlButton's zero insets and press swap, with its own resting
/// fill, because the identity cell is amber while the decision cells are dark.
/// (ControlButton is final and hard-codes `controlBackground`, so it cannot be
/// reused directly.)
private final class AgentCardCellButton: NSButton {
    var fill: UInt32 = Theme.controlBackground

    /// NSButton reserves focus-ring padding that would stretch a 56x24 cell.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var isHighlighted: Bool {
        didSet {
            layer?.backgroundColor = NSColor(argb: isHighlighted ? Theme.controlBackgroundPressed : fill).cgColor
        }
    }
}

/// The 224x24 approval card: identity, allow, always, deny.
///
/// It only renders. The controller owns the machine, the timeout tick and the
/// reply call; the four cells report taps through closures. Everything is a
/// plain layer/button change so the Touch Bar's remote rendering never has to
/// animate a window or popover.
final class AgentCardView: NSView {
    /// The card covers four chip-width cells and grows left from the chip's
    /// right edge, so it never changes the bar's layout outside its own frame.
    static let width = Theme.Layout.chipWidth * 4

    /// Tapped the identity cell (jump).
    var onIdentityTap: (() -> Void)?
    /// Tapped one of the three decision cells.
    var onDecision: ((AgentDecision) -> Void)?

    private let identityButton = AgentCardCellButton()
    private let allowButton = AgentCardCellButton()
    private let alwaysButton = AgentCardCellButton()
    private let rejectButton = AgentCardCellButton()
    /// The phase currently painted, so the 10 Hz tick repaints nothing.
    private var rendered: AgentCardMachine.Phase?

    /// Red used for the failed-reply flash; the palette's red entry.
    private static let errorBorder: UInt32 = 0xffff757f

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: AgentCardView.width,
                                 height: Theme.Layout.controlSize))
        wantsLayer = true
        layer?.cornerRadius = Theme.Layout.cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(argb: Theme.agentWaitBorder).cgColor
        // Outer corners round the first and last cell; the middle cells stay
        // square, which is what makes the four cells read as one card.
        layer?.masksToBounds = true

        configure(identityButton, fill: Theme.agentWaitFill, action: #selector(identityTapped))
        configure(allowButton, fill: Theme.controlBackground, action: #selector(allowTapped))
        configure(alwaysButton, fill: Theme.controlBackground, action: #selector(alwaysTapped))
        configure(rejectButton, fill: Theme.controlBackground, action: #selector(rejectTapped))

        identityButton.setAccessibilityLabel("Session")
        allowButton.setAccessibilityLabel("Allow once")
        alwaysButton.setAccessibilityLabel("Always allow")
        rejectButton.setAccessibilityLabel("Deny")

        applyCellTitle(allowButton, "允许", color: Theme.primaryText)
        applyCellTitle(alwaysButton, "总是", color: Theme.primaryText)
        applyCellTitle(rejectButton, "拒绝", color: Theme.primaryText)

        NSLayoutConstraint.activate([
            identityButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            identityButton.topAnchor.constraint(equalTo: topAnchor),
            identityButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            identityButton.widthAnchor.constraint(equalToConstant: Theme.Layout.chipWidth),

            allowButton.leadingAnchor.constraint(equalTo: identityButton.trailingAnchor),
            allowButton.topAnchor.constraint(equalTo: topAnchor),
            allowButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            allowButton.widthAnchor.constraint(equalToConstant: Theme.Layout.chipWidth),

            alwaysButton.leadingAnchor.constraint(equalTo: allowButton.trailingAnchor),
            alwaysButton.topAnchor.constraint(equalTo: topAnchor),
            alwaysButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            alwaysButton.widthAnchor.constraint(equalToConstant: Theme.Layout.chipWidth),

            rejectButton.leadingAnchor.constraint(equalTo: alwaysButton.trailingAnchor),
            rejectButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            rejectButton.topAnchor.constraint(equalTo: topAnchor),
            rejectButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            rejectButton.widthAnchor.constraint(equalToConstant: Theme.Layout.chipWidth),
        ])

        isHidden = true
    }

    /// Paints one machine phase. Idempotent: identical phases touch nothing.
    func apply(_ phase: AgentCardMachine.Phase) {
        guard phase != rendered else { return }
        rendered = phase

        switch phase {
        case .closed:
            isHidden = true
            alphaValue = 1
            return
        case .open(let target, _):
            isHidden = false
            alphaValue = 1
            setCellsEnabled(true)
            layer?.borderColor = NSColor(argb: Theme.agentWaitBorder).cgColor
            applyIdentity(target)
        case .submitting(let target, _):
            isHidden = false
            // The card is in flight: dim it and take every tap away so a second
            // decision cannot race the first.
            alphaValue = 0.6
            setCellsEnabled(false)
            layer?.borderColor = NSColor(argb: Theme.agentWaitBorder).cgColor
            applyIdentity(target)
        case .failed(let target, _, _):
            isHidden = false
            alphaValue = 0.6
            setCellsEnabled(false)
            layer?.borderColor = NSColor(argb: Self.errorBorder).cgColor
            applyIdentity(target)
        }
    }

    // MARK: - Building

    private func configure(_ button: AgentCardCellButton, fill: UInt32, action: Selector) {
        button.applyBarButtonStyle()
        button.fill = fill
        button.layer?.cornerRadius = 0
        button.layer?.backgroundColor = NSColor(argb: fill).cgColor
        button.title = ""
        button.isBordered = false
        button.refusesFirstResponder = true
        button.focusRingType = .none
        // A single line that truncates instead of widening the cell.
        button.cell?.wraps = false
        button.cell?.truncatesLastVisibleLine = true
        button.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func applyCellTitle(_ button: AgentCardCellButton, _ text: String, color: UInt32) {
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.Layout.labelFontSize, weight: .medium),
            .foregroundColor: NSColor(argb: color),
        ])
    }

    private func applyIdentity(_ target: AgentCardTarget) {
        let text = "\(target.shortName) \(target.position)/\(target.total)"
        identityButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.labelFontSize,
                                                   weight: .medium),
            .foregroundColor: NSColor(argb: Theme.focusedChipText),
        ])
    }

    private func setCellsEnabled(_ enabled: Bool) {
        for button in [identityButton, allowButton, alwaysButton, rejectButton] {
            button.isEnabled = enabled
        }
    }

    // MARK: - Taps

    @objc private func identityTapped() {
        onIdentityTap?()
    }

    @objc private func allowTapped() {
        onDecision?(.once)
    }

    @objc private func alwaysTapped() {
        onDecision?(.always)
    }

    @objc private func rejectTapped() {
        onDecision?(.reject)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
