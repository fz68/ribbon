import Cocoa

internal func runBarLayoutTests(_ t: TestRunner) {
    t.run("BarLayout.modes") { t in
        t.expectEqual(BarLayout.full.width, Theme.Layout.fullWidth,
                      "full keeps the full width")
        t.expectEqual(BarLayout.strip.width, Theme.Layout.stripWidth,
                      "strip keeps the strip width")

        t.expect(!BarLayout.full.hidesMediaCluster, "full shows the media cluster")
        t.expect(!BarLayout.full.hidesAppLabel, "full shows the app label")
        t.expect(!BarLayout.full.collapsesAppLabel, "full does not collapse the app label")
        t.expect(!BarLayout.full.hidesSystemKeys, "full shows the system keys")
        t.expectEqual(BarLayout.full.chipRowAnchor, BarLayout.ChipRowAnchor.media,
                      "full anchors the chips to the media row")

        t.expect(BarLayout.strip.hidesMediaCluster, "strip hides the media cluster")
        t.expect(BarLayout.strip.hidesAppLabel, "strip hides the app label")
        t.expect(BarLayout.strip.collapsesAppLabel, "strip collapses the app label")
        t.expect(BarLayout.strip.hidesSystemKeys, "strip hides the system keys")
        t.expectEqual(BarLayout.strip.chipRowAnchor, BarLayout.ChipRowAnchor.container,
                      "strip anchors the chips to the container")
    }

    t.run("BarLayout.init(visible:)") { t in
        t.expectEqual(BarLayout(visible: true), BarLayout.strip,
                      "visible maps to the strip layout")
        t.expectEqual(BarLayout(visible: false), BarLayout.full,
                      "hidden maps to the full layout")
    }
}
