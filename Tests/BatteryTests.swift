import Foundation
import Testing
@testable import RibbonCore

@Suite(.serialized) final class BatteryTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testBatteryIsCharging() {
        #expect(Battery.isCharging("AC Power; charging") == true,
                "an AC Power charging line is charging")
        #expect(Battery.isCharging("not charging") == false,
                "not charging is not charging")
        #expect(Battery.isCharging("discharging") == false,
                "discharging is not charging")
        #expect(Battery.isCharging("charged") == false,
                "charged is not charging")
        #expect(Battery.isCharging("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 85%; charging; 0:45 remaining")
                == true, "a real pmset charging block is charging")
        #expect(Battery.isCharging("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1) 72%; discharging; 3:12 remaining")
                == false, "a real pmset discharging block is not charging")
        #expect(Battery.isCharging("finishing charge") == false,
                "finishing charge is not charging")
        #expect(Battery.isCharging("") == false, "empty output is not charging")
        #expect(Battery.isCharging("NOT CHARGING") == false,
                "the words are matched case-insensitively")
    }

    @Test func testStatusParsesPmsetOutput() {
        let discharging = """
        Now drawing from 'Battery Power'
         -InternalBattery-0 (id=4653155)	85%; discharging; 3:44 remaining present: true
        """
        let dischargingState = Battery.parse(discharging)
        #expect(dischargingState?.percent == 85, "the percentage is read from the pmset line")
        #expect(dischargingState?.charging == false, "a discharging battery is not charging")

        let charging = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=4653155)	97%; charging; 0:15 remaining present: true
        """
        let chargingState = Battery.parse(charging)
        #expect(chargingState?.percent == 97, "the charging percentage is read")
        #expect(chargingState?.charging == true, "a charging battery is charging")

        #expect(Battery.parse("Now drawing from 'AC Power'\nno battery attached") == nil,
                "output without a percentage yields no state")
        #expect(Battery.parse("") == nil, "empty output yields no state")
    }
}
