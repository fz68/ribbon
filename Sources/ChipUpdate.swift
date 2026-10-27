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

    /// The number of app icons that still fit beside the number in a chip of
    /// `chipWidth`, counting the inset, the label gap and the icon gaps.
    static func iconCountThatFits(chipWidth: CGFloat, nameWidth: CGFloat, iconCount: Int) -> Int {
        let available = chipWidth - Theme.Layout.chipInset * 2 - nameWidth - Theme.Layout.chipLabelSpacing
        var visible = 0
        // Each extra icon costs its width plus one gap, so visible + 1 icons
        // need (visible + 1) * iconSize + visible * microSpacing.
        while visible < iconCount,
              CGFloat(visible + 1) * Theme.Layout.iconSize
                  + CGFloat(visible) * Theme.Layout.microSpacing <= available {
            visible += 1
        }
        return visible
    }

    /// Deterministic djb2 hash of the workspace name, so a chip keeps its
    /// colour across launches and when workspaces are added or removed.
    /// `String.hashValue` is seeded per process, so it cannot be used here.
    static func colorIndex(forName name: String) -> Int {
        var hash: UInt64 = 5381
        for scalar in name.unicodeScalars {
            hash = (hash << 5) &+ hash &+ UInt64(scalar.value)
        }
        return Int(hash % UInt64(Theme.chipRainbow.count))
    }
}
