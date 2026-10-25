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

    override func layout() {
        super.layout()
        updateBottomLine()
    }

    private func updateBottomLine() {
        guard let line = bottomLine else { return }
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: line.frame.height)
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
    private let button = NSButton()
    private var iconViews: [NSImageView] = []
    private var iconApps: [String] = []
    private var iconGeneration = 0
    private var displayed: Workspace?
    private var widthConstraint: NSLayoutConstraint!

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
        stack.addArrangedSubview(number)
        stack.setCustomSpacing(Theme.Layout.chipLabelSpacing, after: number)

        button.applyBarButtonStyle()
        button.target = target
        button.action = action
        addSubview(button)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.chipInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Width is content driven. update() writes this constraint's constant
        // instead of adding and dropping a width constraint on every rebuild.
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.isActive = true
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

        let color = workspace.isFocused
            ? NSColor(argb: Theme.focusedChipBorder)
            : NSColor(argb: Theme.chipRainbow[(index + 1) % Theme.chipRainbow.count])
        layer?.borderColor = color.cgColor
        number.textColor = color

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

        displayed = workspace
        widthConstraint.constant = ChipUpdate.chipWidth(forContentWidth: stack.fittingSize.width)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
