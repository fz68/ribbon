import Cocoa

/// The colours the bar draws with.
///
/// Every value is an ARGB word, so the alpha channel is the top byte and the
/// colours read the same way in the source as they do on screen.
enum Theme {
    /// Chip border palette (ARGB, 12 entries, Tokyo Night).
    static let chipRainbow: [UInt32] = [
        0xffff007c, 0xffc53b53, 0xffff757f, 0xff41a6b5,
        0xff4fd6be, 0xffc3e88d, 0xffffc777, 0xff9d7cd8,
        0xffff9e64, 0xffbb9af7, 0xff7dcfff, 0xff7aa2f7,
    ]
    /// Control-button and chip background.
    static let controlBackground: UInt32 = 0xff363944
    /// Background of a control or chip while pressed (one step lighter than `controlBackground`).
    static let controlBackgroundPressed: UInt32 = 0xff454b5b
    /// Tint of the charging bolt next to the battery percentage.
    static let batteryChargingTint: UInt32 = 0xffc3e88d
    /// Label text and control tint.
    static let primaryText: UInt32 = 0xffe2e2e3
    /// Border of the focused workspace chip.
    static let focusedChipBorder: UInt32 = 0xffe7c664
    /// Fill of the focused workspace chip.
    static let focusedChipBackground: UInt32 = 0xffe7c664
    /// Name text on the gold fill of the focused chip.
    static let focusedChipText: UInt32 = 0xff1a1b26
    /// Fill of the focused chip while pressed (a step darker gold).
    static let focusedChipBackgroundPressed: UInt32 = 0xffd3b25a
    /// Placeholder chip glyph.
    static let placeholderTint: UInt32 = 0xff6c7086

    /// The pixel metrics the bar lays out with.
    enum Layout {
        /// Width the full bar asks the system for.
        static let fullWidth: CGFloat = 1004
        /// Width the bar asks for in Control Strip mode.
        static let stripWidth: CGFloat = 680
        /// Height of the bar container.
        static let containerHeight: CGFloat = 30
        /// Side length of a control button and of a workspace chip.
        static let controlSize: CGFloat = 24
        /// Height of the IME indicator line.
        static let indicatorLineHeight: CGFloat = 2
        /// Corner radius shared by the control buttons and the chips.
        static let cornerRadius: CGFloat = 6
        // clusterGap and chipInset happen to share the value 8, but they are
        // independent: do not merge them back into one constant.
        /// Inset of the bar's content from the Touch Bar's edges. 0, so the
        /// outermost controls sit flush with the edges.
        static let barMargin: CGFloat = 0
        /// Horizontal gap between two adjacent clusters.
        static let clusterGap: CGFloat = 8
        /// Padding between a chip's own leading edge and its content stack.
        static let chipInset: CGFloat = 8
        /// Spacing inside the media row and the chip row.
        static let tightSpacing: CGFloat = 4
        /// Spacing inside the right cluster.
        static let clusterSpacing: CGFloat = 6
        /// Spacing inside the battery group and the chip icon row.
        static let microSpacing: CGFloat = 2
        /// Gap between a chip's number and its first app icon.
        static let chipLabelSpacing: CGFloat = 6
        /// Fixed width of every workspace chip, so the chips and the app name
        /// keep their positions when apps open or close.
        static let chipWidth: CGFloat = 50
        /// Narrowest a chip may get.
        static let chipMinWidth: CGFloat = 40
        /// Side length of an app icon inside a chip.
        static let iconSize: CGFloat = 12
        /// Cap on the front-app label so it never crowds the right cluster.
        static let appLabelMaxWidth: CGFloat = 160
        /// Priority of the constraint that keeps the app label clear of the right cluster.
        static let appLabelTrailingPriority: Float = 999
        /// Font size of the labels in the right cluster and the app label.
        static let labelFontSize: CGFloat = 12
        /// Fixed width of the battery slot: it holds the percentage ("99%" is the
        /// widest), "F" at full charge, or a number plus a trailing bolt while
        /// charging, so the slot never changes width. 30 pt is the rounded-up
        /// worst case ("99" + gap + bolt = 29.5 pt).
        static let batterySlotWidth: CGFloat = 30
        /// Font size of a chip's workspace number and its placeholder glyph.
        static let chipFontSize: CGFloat = 13
        /// Width of the transient brightness/volume level pill.
        static let levelPopWidth: CGFloat = 90
        /// Height of the transient brightness/volume level pill.
        static let levelPopHeight: CGFloat = 8
    }

    /// The delays and intervals the bar runs on.
    enum Timing {
        /// Debounce between an event and the workspace refresh it triggers.
        static let refreshDebounce: TimeInterval = 0.05
        /// Confirmation refresh after a workspace chip is tapped.
        static let chipConfirmation: TimeInterval = 0.15
        /// Delay from launch before the first presentation.
        static let initialPresent: TimeInterval = 0.3
        /// Delay before re-presenting after a Control Strip mode toggle.
        static let controlStripRePresent: TimeInterval = 0.3
        /// Delay before the one-shot layout diagnostic dump.
        static let layoutDump: TimeInterval = 0.3
        /// Wait before re-reading the frontmost app after presenting.
        static let frontAppRefresh: TimeInterval = 0.5
        /// Wait before re-presenting after a wake.
        static let wakeRepresent: TimeInterval = 1.0
        /// Wait before re-presenting after restarting ControlStrip.
        static let controlStripRestart: TimeInterval = 1.5
        /// Timeout for the ControlStrip restart command.
        static let controlStripTimeout: TimeInterval = 2
        /// Periodic refresh of the workspace list.
        static let workspaceRefresh: TimeInterval = 30
        /// Periodic clock repaint.
        static let clockRefresh: TimeInterval = 30
        /// Periodic battery read.
        static let batteryRefresh: TimeInterval = 300
        /// Media poll while a session is present.
        static let mediaPoll: TimeInterval = 30
        /// Media poll once no session has been seen for a while.
        static let mediaIdlePoll: TimeInterval = 120
        /// Consecutive empty media polls before backing off to `mediaIdlePoll`.
        static let mediaMissThreshold: Int = 2
        /// How long the brightness/volume level pill stays visible.
        static let levelPop: TimeInterval = 1
    }
}
