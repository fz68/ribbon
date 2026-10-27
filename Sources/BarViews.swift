import Cocoa

/// Borderless NSButton used for the right cluster controls.
/// NSButton reserves focus-ring padding (alignmentRectInsets top 3.5 / bottom 2.5),
/// which would stretch the 24x24 button to a 24x30 frame. Zeroing the insets keeps
/// the button exactly 24x24 with its background pill and SF Symbol centred.
final class ControlButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // Every ControlButton paints `controlBackground`, so a press only has to
    // swap that one colour: no separate pressed layer or state machine.
    override var isHighlighted: Bool {
        didSet {
            layer?.backgroundColor = NSColor(argb: isHighlighted ? Theme.controlBackgroundPressed : Theme.controlBackground).cgColor
        }
    }
}

/// The transparent full-chip tap target. The chip's pill lives on ChipView's
/// own layer, so the press state is forwarded instead of painted here.
final class ChipTapButton: NSButton {
    var pressChanged: ((Bool) -> Void)?
    override var isHighlighted: Bool {
        didSet { pressChanged?(isHighlighted) }
    }
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

/// The bar container. It keeps the IME indicator pinned to the top or bottom
/// edge of the bar so the line follows the width the system grants (1004 pt
/// full, 680 pt strip) instead of the width this process asked for.
final class BarContainer: NSView {
    /// The 2 pt indicator line along the top or bottom edge.
    weak var line: NSView?

    /// True when the indicator line sits on the top edge instead of the bottom.
    var lineOnTop = false

    override func layout() {
        super.layout()
        positionLine()
    }

    /// Places the indicator line on the configured edge. The height is left
    /// alone, so the line keeps its 2 pt and only the edge changes.
    func positionLine() {
        guard let line = line else { return }
        line.frame = NSRect(x: 0,
                            y: lineOnTop ? max(0, bounds.height - line.frame.height) : 0,
                            width: bounds.width,
                            height: line.frame.height)
    }
}

/// The 2 pt IME indicator line. A single reused CAGradientLayer backs it, so a
/// style change mutates the existing layer's properties instead of allocating a
/// new layer and reassigning the view's backing layer - reassigning `layer` is
/// discouraged once the view is in a window.
final class IndicatorLineView: NSView {
    let gradientLayer = CAGradientLayer()
    override func makeBackingLayer() -> CALayer { gradientLayer }
}

final class ChipView: NSView {
    let stack = NSStackView()

    private let number = NSTextField(labelWithString: "")
    private let button = ChipTapButton()
    private var iconViews: [NSImageView] = []
    private var iconApps: [String] = []
    private var iconGeneration = 0
    private var displayed: Workspace?
    private var widthConstraint: NSLayoutConstraint!

    /// The pill background for the current state. The press handler and update()
    /// share it, so a released press always restores the fill the focus state
    /// calls for instead of a hard-coded dark.
    private func backgroundHex(forPressed pressed: Bool) -> UInt32 {
        if pressed {
            return (displayed?.isFocused ?? false)
                ? Theme.focusedChipBackgroundPressed : Theme.controlBackgroundPressed
        }
        return (displayed?.isFocused ?? false)
                ? Theme.focusedChipBackground : Theme.controlBackground
    }

    init(workspace: Workspace, index: Int, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Layout.cornerRadius
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor(argb: Theme.controlBackground).cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.Layout.microSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Text and colour are filled in by update(), which every chip runs at the
        // end of init, so a fresh chip and a reused one share one styling path.
        number.font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Layout.chipFontSize, weight: .medium)
        number.maximumNumberOfLines = 1
        // Non-wrapping cell, or lineBreakMode is ignored and the name clips.
        number.lineBreakMode = .byTruncatingTail
        number.cell?.truncatesLastVisibleLine = true
        number.cell?.wraps = false
        number.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(number)
        stack.setCustomSpacing(Theme.Layout.chipLabelSpacing, after: number)

        button.applyBarButtonStyle()
        button.target = target
        button.action = action
        addSubview(button)
        // ChipView owns the pill, so the tap target only forwards the press.
        button.pressChanged = { [weak self] pressed in
            guard let self else { return }
            self.layer?.backgroundColor = NSColor(argb: self.backgroundHex(forPressed: pressed)).cgColor
        }

        // The content cap is 999, not required: it still wins over the label's
        // defaultLow compression so long names truncate, but it yields to the
        // required 12 pt icon widths when a crowded chip hits its 40 pt floor.
        let contentTrailing = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Layout.chipInset)
        contentTrailing.priority = NSLayoutConstraint.Priority(Theme.Layout.appLabelTrailingPriority)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.chipInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Caps the content stack so an over-long name truncates with an
            // ellipsis inside the 88 pt chip instead of spilling and clipping.
            contentTrailing,
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Width is content driven. update() writes this constraint's constant
        // instead of adding and dropping a width constraint on every rebuild.
        // The wanted width yields to crowding: when the chip row outgrows the bar,
        // chips compress (long names truncate) instead of overlapping the right
        // cluster. The floor and cap below stay required, so a chip never leaves
        // 40...88 pt.
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.priority = NSLayoutConstraint.Priority(750)
        widthConstraint.isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Layout.chipMinWidth).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: Theme.Layout.chipMaxWidth).isActive = true
        heightAnchor.constraint(equalToConstant: Theme.Layout.controlSize).isActive = true

        update(workspace: workspace, index: index)
    }

    /// Applies a workspace to this chip in place.
    ///
    /// A rebuild used to tear down every chip's NSView tree and constraints on
    /// each workspace change or chip tap. Mutating the existing views keeps
    /// `button.tag` equal to the chip's position in `workspaces` (the tap handler
    /// reads it as an index) and avoids the allocation churn; an unchanged chip
    /// returns early, so repeated identical refreshes touch nothing. A bump of
    /// `AppIconCache.generation` also re-runs the icon refresh even when the app
    /// list is unchanged, because the cache drops every image on app launch and
    /// terminate.
    func update(workspace: Workspace, index: Int) {
        // The tap handler reads this tag as an index into `workspaces`.
        // Written before the early-out so the tag is correct on every call.
        button.tag = index

        let apps = Array(workspace.apps.prefix(AeroSpace.maxAppsPerWorkspace))
        // A generation bump only invalidates icons, yet the wider early-out
        // re-runs the restyle below; it is idempotent and cheap by design.
        let plan = ChipUpdate.plan(
            workspace: workspace,
            displayed: displayed,
            apps: apps,
            iconApps: iconApps,
            iconGeneration: iconGeneration,
            iconCacheGeneration: AppIconCache.generation
        )
        guard case .restyle(let reconcileIcons) = plan else { return }

        // backgroundHex reads `displayed`, so record the new workspace before
        // the restyle paints its fill.
        displayed = workspace

        let color = workspace.isFocused
            ? NSColor(argb: Theme.focusedChipBorder)
            : NSColor(argb: Theme.chipRainbow[ChipUpdate.colorIndex(forName: workspace.name)])
        layer?.borderColor = color.cgColor
        number.textColor = workspace.isFocused
            ? NSColor(argb: Theme.focusedChipText)
            : color
        layer?.backgroundColor = NSColor(argb: backgroundHex(forPressed: false)).cgColor

        if number.stringValue != workspace.name {
            number.stringValue = workspace.name
        }

        if reconcileIcons {
            for icon in iconViews {
                stack.removeArrangedSubview(icon)
                icon.removeFromSuperview()
            }
            iconViews = []
            for app in apps {
                guard let image = AppIconCache.icon(for: app)
                    ?? NSImage(named: NSImage.applicationIconName) else { continue }
                let icon = NSImageView(image: image)
                icon.imageScaling = .scaleProportionallyDown
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: Theme.Layout.iconSize).isActive = true
                icon.heightAnchor.constraint(equalToConstant: Theme.Layout.iconSize).isActive = true
                stack.addArrangedSubview(icon)
                iconViews.append(icon)
            }
            iconApps = apps
            iconGeneration = AppIconCache.generation
            // Re-adding arranged subviews resets the spacing after the number.
            stack.setCustomSpacing(Theme.Layout.chipLabelSpacing, after: number)
        }

        // Measure with the chip parked at its cap first: the trailing content
        // constraint then reads an over-long name as "cap it" instead of echoing
        // back whatever width crowding last squeezed the chip to.
        widthConstraint.constant = Theme.Layout.chipMaxWidth
        let contentWidth = stack.fittingSize.width
        widthConstraint.constant = ChipUpdate.chipWidth(forContentWidth: contentWidth)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The transient pill centred over the bar that shows the new brightness or
/// volume level after a step. Frames are manual: the size is fixed, so Auto
/// Layout has nothing to do inside.
final class LevelPopView: NSView {
    private let fillView = NSView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.Layout.levelPopWidth, height: Theme.Layout.levelPopHeight))
        wantsLayer = true
        layer?.backgroundColor = NSColor(argb: Theme.controlBackground).cgColor
        layer?.cornerRadius = Theme.Layout.levelPopHeight / 2
        layer?.masksToBounds = true
        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor(argb: Theme.primaryText).cgColor
        fillView.layer?.cornerRadius = (Theme.Layout.levelPopHeight - 3) / 2
        addSubview(fillView)
        isHidden = true
    }

    /// `level` is 0...1 and is clamped; the fill keeps a 2 pt nub at zero so
    /// the pill still reads as "at minimum" rather than empty.
    func show(level: CGFloat) {
        let inset: CGFloat = 1.5
        let maxWidth = bounds.width - inset * 2
        fillView.frame = NSRect(x: inset,
                                y: inset,
                                width: max(2, maxWidth * min(max(level, 0), 1)),
                                height: bounds.height - inset * 2)
        isHidden = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
