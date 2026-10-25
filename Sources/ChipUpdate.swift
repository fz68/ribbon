import Foundation

/// The pure per-refresh decisions ChipView.update makes, extracted so tests
/// can pin the chip-reuse transitions without an AppKit host.
enum ChipUpdate {
    /// What update() should do for one chip.
    enum Plan: Equatable {
        /// Workspace and icon-cache generation are unchanged - touch nothing.
        case skip
        /// Restyle border and number text; rebuild the icon views as well when
        /// `reconcileIcons` is true.
        case restyle(reconcileIcons: Bool)
    }

    /// Decides how to bring a chip from (displayed, iconApps, iconGeneration)
    /// to `workspace`.
    ///
    /// - Parameters:
    ///   - apps: `workspace.apps` already truncated to
    ///     `AeroSpace.maxAppsPerWorkspace`, matching what the icon row shows.
    static func plan(
        workspace: Workspace,
        displayed: Workspace?,
        apps: [String],
        iconApps: [String],
        iconGeneration: Int,
        iconCacheGeneration: Int
    ) -> Plan {
        if workspace == displayed && iconGeneration == iconCacheGeneration {
            return .skip
        }
        return .restyle(reconcileIcons: apps != iconApps || iconGeneration != iconCacheGeneration)
    }

    /// The chip width for a measured stack width: content plus padding,
    /// clamped to the narrowest and widest chip metrics.
    static func chipWidth(forContentWidth contentWidth: CGFloat) -> CGFloat {
        max(Theme.Layout.chipMinWidth,
            min(Theme.Layout.chipMaxWidth, contentWidth + Theme.Layout.chipWidthPadding))
    }
}
