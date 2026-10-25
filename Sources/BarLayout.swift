import Cocoa

/// The layout of one of the bar's two presentations.
///
/// The Control Strip mode used to be a bare `Bool` that was read inline at every
/// layout decision. This type turns that policy into data: each stored property
/// is one of those decisions, so the two modes are described side by side by the
/// `full` and `strip` constants instead of by branches scattered through the
/// controller.
struct BarLayout: Equatable {
    /// Which cluster the left stack is pinned to at the leading edge.
    enum ChipRowAnchor: Equatable {
        /// Pin to the media row, which the full bar shows.
        case media
        /// Pin to the chip container, which is what the strip keeps.
        case container
    }

    /// Width the container's frame is set to.
    let width: CGFloat
    /// Whether the media row (app icons, title, transport controls) is hidden.
    let hidesMediaCluster: Bool
    /// Whether the front-app label is hidden.
    let hidesAppLabel: Bool
    /// Whether the constraint that collapses the app label to zero width is active.
    let collapsesAppLabel: Bool
    /// Whether the brightness and volume buttons are hidden.
    let hidesSystemKeys: Bool
    /// Which constraint anchors the left stack's leading edge.
    let chipRowAnchor: ChipRowAnchor

    /// The full width bar: every cluster visible, anchored to the media row.
    static let full = BarLayout(width: Theme.Layout.fullWidth, hidesMediaCluster: false,
        hidesAppLabel: false, collapsesAppLabel: false, hidesSystemKeys: false,
        chipRowAnchor: .media)

    /// The Control Strip presentation: chips, battery, clock and toggle only.
    static let strip = BarLayout(width: Theme.Layout.stripWidth, hidesMediaCluster: true,
        hidesAppLabel: true, collapsesAppLabel: true, hidesSystemKeys: true,
        chipRowAnchor: .container)
}

extension BarLayout {
    /// Maps the persisted Control Strip flag onto its layout.
    init(visible: Bool) { self = visible ? .strip : .full }
}
