import Cocoa

/// Borderless NSButton used for the right cluster controls.
/// NSButton reserves focus-ring padding (alignmentRectInsets top 3.5 / bottom 2.5),
/// which would stretch the 24x24 button to a 24x30 frame. Zeroing the insets keeps
/// the button exactly 24x24 with its background pill and SF Symbol centred.
final class ControlButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// The borderless, non-focusable base style every bar button shares. Only the
/// parts the three button builders already set the same way live here; the
/// background, border, corner radius and size stay with each builder.
extension NSButton {
    func applyBarButtonStyle() {
        title = ""
        isBordered = false
        focusRingType = .none
        refusesFirstResponder = true
        translatesAutoresizingMaskIntoConstraints = false
    }
}

/// The bar container. It keeps the IME indicator pinned to the very bottom edge
/// so the line follows the width the system grants (1004 pt full, 680 pt strip)
/// instead of the width this process asked for.
final class BarContainer: NSView {
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

final class ChipView: NSView {
    let stack = NSStackView()

    init(workspace: Workspace, index: Int, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        let color = workspace.isFocused
            ? NSColor(argb: Theme.focusedChipBorder)
            : NSColor(argb: Theme.chipRainbow[(index + 1) % Theme.chipRainbow.count])
        wantsLayer = true
        layer?.cornerRadius = Theme.Layout.cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = color.cgColor
        layer?.backgroundColor = NSColor(argb: Theme.controlBackground).cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.Layout.microSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let number = NSTextField(labelWithString: workspace.name)
        number.font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.chipFontSize, weight: .medium)
        number.textColor = color
        number.maximumNumberOfLines = 1
        stack.addArrangedSubview(number)
        stack.setCustomSpacing(Theme.Layout.chipLabelSpacing, after: number)

        for app in workspace.apps.prefix(AeroSpace.maxAppsPerWorkspace) {
            guard let image = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == app })?.icon
                ?? NSImage(named: NSImage.applicationIconName) else { continue }
            let icon = NSImageView(image: image)
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: Theme.Layout.iconSize).isActive = true
            icon.heightAnchor.constraint(equalToConstant: Theme.Layout.iconSize).isActive = true
            stack.addArrangedSubview(icon)
        }

        let button = NSButton()
        button.applyBarButtonStyle()
        button.tag = index
        button.target = target
        button.action = action
        addSubview(button)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.edgeInset),
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
