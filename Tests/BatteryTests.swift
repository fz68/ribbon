import Foundation

internal func runBatteryTests(_ t: TestRunner) {
    t.run("Battery.isCharging") { t in
        t.expectEqual(Battery.isCharging("AC Power; charging"), true,
                      "an AC Power charging line is charging")
        t.expectEqual(Battery.isCharging("not charging"), false,
                      "not charging is not charging")
        t.expectEqual(Battery.isCharging("discharging"), false,
                      "discharging is not charging")
        t.expectEqual(Battery.isCharging("charged"), false,
                      "charged is not charging")
        t.expectEqual(Battery.isCharging("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 85%; charging; 0:45 remaining"),
                      true, "a real pmset charging block is charging")
        t.expectEqual(Battery.isCharging("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1) 72%; discharging; 3:12 remaining"),
                      false, "a real pmset discharging block is not charging")
        t.expectEqual(Battery.isCharging("finishing charge"), false,
                      "finishing charge is not charging")
        t.expectEqual(Battery.isCharging(""), false, "empty output is not charging")
        t.expectEqual(Battery.isCharging("NOT CHARGING"), false,
                      "the words are matched case-insensitively")
    }
}
