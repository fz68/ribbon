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

    /// How many app icons fit next to a label of `labelWidth` inside a chip of
    /// `chipWidth`, capped at `maxIcons`.
    ///
    /// n icons need `chipLabelSpacing + n * iconSize + (n - 1) * microSpacing`
    /// once the label sits at the chip inset; n = 0 needs none of it. The
    /// requirement grows with n, so the answer is the largest n that still fits
    /// the free width, or 0 when even one icon does not.
    static func iconCount(labelWidth: CGFloat, chipWidth: CGFloat, maxIcons: Int) -> Int {
        guard maxIcons > 0 else { return 0 }
        let free = chipWidth - 2 * Theme.Layout.chipInset - labelWidth
        var count = 0
        for n in 1...maxIcons {
            let needed = Theme.Layout.chipLabelSpacing
                + CGFloat(n) * Theme.Layout.iconSize
                + CGFloat(n - 1) * Theme.Layout.microSpacing
            guard needed <= free else { break }
            count = n
        }
        return count
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
