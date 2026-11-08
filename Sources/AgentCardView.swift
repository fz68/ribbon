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

/// The three action cells a card paints, derived from its locked target.
///
/// Pure, so the label rule is testable without AppKit: a permission shows
/// Allow/Always/Deny, an answerable form shows up to three option labels (the raw
/// value stands in for a missing label) and hides the cells it does not need.
struct AgentCardActionCells: Equatable {
    /// The permission cells, left to right.
    static let permissionTitles = ["Allow", "Always", "Deny"]

    /// Titles left to right; always three entries, empty past `count`.
    let titles: [String]
    /// How many of the three cells are shown (3 for a permission).
    let count: Int

    static func cells(for target: AgentCardTarget) -> AgentCardActionCells {
        guard target.isForm else {
            return AgentCardActionCells(titles: permissionTitles, count: permissionTitles.count)
        }
        let shown = min(target.options.count, permissionTitles.count)
        var titles = Array(repeating: "", count: permissionTitles.count)
        for index in 0..<shown {
            let option = target.options[index]
            titles[index] = option.label.isEmpty ? option.value : option.label
        }
        return AgentCardActionCells(titles: titles, count: shown)
    }
}

/// The 224x24 card: identity plus three action cells.
///
/// It only renders. The controller owns the machine, the timeout tick and the
/// reply call; the four cells report taps through closures. Everything is a
/// plain layer/button change so the Touch Bar's remote rendering never has to
/// animate a window or popover.
///
/// The action cells are double duty: for a permission they are the three
/// decisions, for an answerable form they are the option labels. The target the
/// machine locked says which, so a tap always reports the answer the user saw.
final class AgentCardView: NSView {
    /// The card covers four chip-width cells and grows left from the chip's
    /// right edge, so it never changes the bar's layout outside its own frame.
    static let width = Theme.Layout.chipWidth * 4

    /// Tapped the identity cell (jump).
    var onIdentityTap: (() -> Void)?
    /// Tapped one of the three decision cells on a permission card.
    var onDecision: ((AgentDecision) -> Void)?
    /// Tapped one of the option cells on a form card; the value goes on the wire.
    var onOption: ((String) -> Void)?

    private let identityButton = AgentCardCellButton()
    private let actionOne = AgentCardCellButton()
    private let actionTwo = AgentCardCellButton()
    private let actionThree = AgentCardCellButton()
    /// The phase currently painted, so the 10 Hz tick repaints nothing.
    private var rendered: AgentCardMachine.Phase?
    /// The target currently painted; nil while closed. Taps read this so they
    /// answer the target the user is looking at, not a re-derived one.
    private var currentTarget: AgentCardTarget?

    /// Red used for the failed-reply flash; the palette's red entry.
    private static let errorBorder: UInt32 = Theme.agentCardErrorBorder

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
        configure(actionOne, fill: Theme.controlBackground, action: #selector(allowTapped))
        configure(actionTwo, fill: Theme.controlBackground, action: #selector(alwaysTapped))
        configure(actionThree, fill: Theme.controlBackground, action: #selector(rejectTapped))

        NSLayoutConstraint.activate([
            identityButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            identityButton.topAnchor.constraint(equalTo: topAnchor),
            identityButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            identityButton.widthAnchor.constraint(equalToConstant: Theme.Layout.chipWidth),

            actionOne.leadingAnchor.constraint(equalTo: identityButton.trailingAnchor),
            actionOne.topAnchor.constraint(equalTo: topAnchor),
            actionOne.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionOne.widthAnchor.constraint(equalToConstant: Theme.Layout.chipWidth),

            actionTwo.leadingAnchor.constraint(equalTo: actionOne.trailingAnchor),
            actionTwo.topAnchor.constraint(equalTo: topAnchor),
            actionTwo.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionTwo.widthAnchor.constraint(equalToConstant: Theme.Layout.chipWidth),

            actionThree.leadingAnchor.constraint(equalTo: actionTwo.trailingAnchor),
            actionThree.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionThree.topAnchor.constraint(equalTo: topAnchor),
            actionThree.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionThree.widthAnchor.constraint(equalToConstant: Theme.Layout.chipWidth),
        ])

        isHidden = true
    }

    /// Paints one machine phase. Idempotent: identical phases touch nothing.
    func apply(_ phase: AgentCardMachine.Phase) {
        guard phase != rendered else { return }
        rendered = phase

        switch phase {
        case .closed:
            currentTarget = nil
            isHidden = true
            alphaValue = 1
            setAccessibilityValue(nil)
            return
        case .open(let target, _):
            currentTarget = target
            isHidden = false
            alphaValue = 1
            setAccessibilityValue(nil)
            layer?.borderColor = NSColor(argb: Theme.agentWaitBorder).cgColor
            applyIdentity(target)
            applyActionCells(target, enabled: true)
        case .submitting(let target, _):
            currentTarget = target
            isHidden = false
            // The card is in flight: dim it and take every tap away so a second
            // answer cannot race the first.
            alphaValue = 0.6
            setAccessibilityValue(nil)
            layer?.borderColor = NSColor(argb: Theme.agentWaitBorder).cgColor
            applyIdentity(target)
            applyActionCells(target, enabled: false)
        case .failed(let target, _, _):
            currentTarget = target
            isHidden = false
            alphaValue = 0.6
            // The red flash is invisible to VoiceOver, so the phase is spoken.
            setAccessibilityValue("Reply failed")
            layer?.borderColor = NSColor(argb: Self.errorBorder).cgColor
            applyIdentity(target)
            applyActionCells(target, enabled: false)
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
        // A single line that truncates instead of widening the cell. Form
        // option labels are short; the tail is what gets dropped.
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
        button.setAccessibilityLabel(text)
    }

    private func applyIdentity(_ target: AgentCardTarget) {
        let text = "\(target.shortName) \(target.position)/\(target.total)"
        identityButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.labelFontSize,
                                                   weight: .medium),
            .foregroundColor: NSColor(argb: Theme.focusedChipText),
        ])
        // The visible title stays the compact "1/3" form; only the spoken label
        // spells it out.
        identityButton.setAccessibilityLabel(target.accessibilityIdentity)
        identityButton.setAccessibilityHelp("Jump to the terminal session")
    }

    /// Paints the three action cells for `target` and gates their taps.
    ///
    /// A form with fewer than three options hides the surplus cells; they keep
    /// their constraints so the identity cell and the card width never move.
    private func applyActionCells(_ target: AgentCardTarget, enabled: Bool) {
        let cells = AgentCardActionCells.cells(for: target)
        for (index, button) in actionButtons.enumerated() {
            let shown = index < cells.count
            button.isHidden = !shown
            button.isEnabled = enabled && shown
            applyCellTitle(button, cells.titles[index], color: Theme.primaryText)
        }
        identityButton.isEnabled = enabled
    }

    private var actionButtons: [AgentCardCellButton] {
        [actionOne, actionTwo, actionThree]
    }

    // MARK: - Taps

    @objc private func identityTapped() {
        onIdentityTap?()
    }

    @objc private func allowTapped() {
        actionCellTapped(0, decision: .once)
    }

    @objc private func alwaysTapped() {
        actionCellTapped(1, decision: .always)
    }

    @objc private func rejectTapped() {
        actionCellTapped(2, decision: .reject)
    }

    /// Reports the tapped cell as whatever this card is: an option value for a
    /// form, a decision for a permission.
    private func actionCellTapped(_ index: Int, decision: AgentDecision) {
        guard let target = currentTarget,
              index < AgentCardActionCells.cells(for: target).count else { return }
        if target.isForm {
            guard index < target.options.count else { return }
            onOption?(target.options[index].value)
        } else {
            onDecision?(decision)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
