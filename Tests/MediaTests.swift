import Foundation

internal func runMediaTests(_ t: TestRunner) {
    t.run("Media.parseIsPlaying") { t in
        t.expectEqual(Media.parseIsPlaying(#"{"playbackRate": 1}"#), true,
                      "a rate of 1 is playing")
        t.expectEqual(Media.parseIsPlaying(#"{"playbackRate": 0.5}"#), true,
                      "a fractional rate is playing")
        t.expectEqual(Media.parseIsPlaying(#"{"playbackRate": 0}"#), false,
                      "a zero rate is not playing")
        t.expectEqual(Media.parseIsPlaying(#"{"playbackRate": 0.005}"#), false,
                      "a rate below the 0.01 threshold is not playing")
        t.expectEqual(Media.parseIsPlaying("{}"), false,
                      "JSON without a playback rate is not playing")
        t.expectEqual(Media.parseIsPlaying("not playing"), false,
                      "\"not playing\" beats the playing substring")
        t.expectEqual(Media.parseIsPlaying("Paused"), false, "Paused is not playing")
        t.expectEqual(Media.parseIsPlaying("stopped"), false, "stopped is not playing")
        t.expectEqual(Media.parseIsPlaying("now playing"), true,
                      "plain text that says playing is playing")
        t.expectEqual(Media.parseIsPlaying(""), false, "empty output is not playing")
        t.expectEqual(Media.parseIsPlaying("garbage"), false,
                      "unrecognised output is not playing")
    }

    t.run("MediaCommand.toolArgument") { t in
        t.expectEqual(MediaCommand.playPause.toolArgument, "togglePlayPause",
                      "playPause maps to the helper verb")
        t.expectEqual(MediaCommand.next.toolArgument, "next",
                      "next maps to the helper verb")
        t.expectEqual(MediaCommand.previous.toolArgument, "previous",
                      "previous maps to the helper verb")
    }
}
