import Foundation

internal func runMediaPollPolicyTests(_ t: TestRunner) {
    t.run("MediaPollPolicy.initial") { t in
        t.expectEqual(MediaPollPolicy.initial.missCount, 0,
                      "the initial policy has no misses")
    }

    t.run("MediaPollPolicy.interval") { t in
        t.expectEqual(MediaPollPolicy(missCount: 0).interval, Theme.Timing.mediaPoll,
                      "no misses poll at the normal interval")
        t.expectEqual(MediaPollPolicy(missCount: 1).interval, Theme.Timing.mediaPoll,
                      "one miss still polls at the normal interval")
        t.expectEqual(MediaPollPolicy(missCount: 2).interval, Theme.Timing.mediaIdlePoll,
                      "two misses back off to the idle interval")
        t.expectEqual(MediaPollPolicy(missCount: 3).interval, Theme.Timing.mediaIdlePoll,
                      "the idle interval is kept past the threshold")
    }

    t.run("MediaPollPolicy.recording") { t in
        t.expectEqual(MediaPollPolicy.initial.recording(available: false).missCount, 1,
                      "a miss increments the count")
        t.expectEqual(MediaPollPolicy(missCount: 3).recording(available: true).missCount, 0,
                      "a hit resets the count")
        let afterMisses = MediaPollPolicy.initial
            .recording(available: false)
            .recording(available: false)
        t.expectEqual(afterMisses.missCount, 2, "two misses in a row count twice")
        t.expectEqual(afterMisses.recording(available: true).interval, Theme.Timing.mediaPoll,
                      "a hit after two misses polls at the normal interval again")
    }
}
