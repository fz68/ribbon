import Foundation
import Testing
@testable import RibbonCore

@Suite(.serialized) final class MediaPollPolicyTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testMediaPollPolicyInitial() {
        #expect(MediaPollPolicy.initial.missCount == 0,
                "the initial policy has no misses")
    }

    @Test func testMediaPollPolicyInterval() {
        #expect(MediaPollPolicy(missCount: 0).interval == Theme.Timing.mediaPoll,
                "no misses poll at the normal interval")
        #expect(MediaPollPolicy(missCount: 1).interval == Theme.Timing.mediaPoll,
                "one miss still polls at the normal interval")
        #expect(MediaPollPolicy(missCount: 2).interval == Theme.Timing.mediaIdlePoll,
                "two misses back off to the idle interval")
        #expect(MediaPollPolicy(missCount: 3).interval == Theme.Timing.mediaIdlePoll,
                "the idle interval is kept past the threshold")
    }

    @Test func testMediaPollPolicyRecording() {
        #expect(MediaPollPolicy.initial.recording(available: false).missCount == 1,
                "a miss increments the count")
        #expect(MediaPollPolicy(missCount: 3).recording(available: true).missCount == 0,
                "a hit resets the count")
        let afterMisses = MediaPollPolicy.initial
            .recording(available: false)
            .recording(available: false)
        #expect(afterMisses.missCount == 2, "two misses in a row count twice")
        #expect(afterMisses.recording(available: true).interval == Theme.Timing.mediaPoll,
                "a hit after two misses polls at the normal interval again")
    }
}
