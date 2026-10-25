import Foundation
import Testing
@testable import RibbonCore

/// Writes an executable shell script at `path`, reporting whether it was written.
private func writeStub(_ body: String, to path: String) -> Bool {
    FileManager.default.createFile(atPath: path,
                                   contents: Data(("#!/bin/sh\n" + body).utf8),
                                   attributes: [.posixPermissions: 0o755])
}

@Suite(.serialized) final class MediaTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testMediaParseIsPlaying() {
        #expect(Media.parseIsPlaying(#"{"playbackRate": 1}"#) == true,
                "a rate of 1 is playing")
        #expect(Media.parseIsPlaying(#"{"playbackRate": 0.5}"#) == true,
                "a fractional rate is playing")
        #expect(Media.parseIsPlaying(#"{"playbackRate": 0}"#) == false,
                "a zero rate is not playing")
        #expect(Media.parseIsPlaying(#"{"playbackRate": 0.005}"#) == false,
                "a rate below the 0.01 threshold is not playing")
        #expect(Media.parseIsPlaying("{}") == false,
                "JSON without a playback rate is not playing")
        #expect(Media.parseIsPlaying("not playing") == false,
                "\"not playing\" beats the playing substring")
        #expect(Media.parseIsPlaying("Paused") == false, "Paused is not playing")
        #expect(Media.parseIsPlaying("stopped") == false, "stopped is not playing")
        #expect(Media.parseIsPlaying("now playing") == true,
                "plain text that says playing is playing")
        #expect(Media.parseIsPlaying("") == false, "empty output is not playing")
        #expect(Media.parseIsPlaying("garbage") == false,
                "unrecognised output is not playing")
    }

    @Test func testMediaCommandToolArgument() {
        #expect(MediaCommand.playPause.toolArgument == "togglePlayPause",
                "playPause maps to the helper verb")
        #expect(MediaCommand.next.toolArgument == "next",
                "next maps to the helper verb")
        #expect(MediaCommand.previous.toolArgument == "previous",
                "previous maps to the helper verb")
    }

    @Test func testStateParsesPlaying() {
        let saved = Media.toolPath
        defer { Media.toolPath = saved }

        let playing = TestTemp.path("nowplaying-playing-stub")
        let paused = TestTemp.path("nowplaying-paused-stub")
        try? FileManager.default.removeItem(atPath: playing)
        try? FileManager.default.removeItem(atPath: paused)
        #expect(writeStub(#"printf '{"playbackRate": 1}\n'"#, to: playing),
                "the playing stub was written")
        #expect(writeStub(#"printf '{"playbackRate": 0}\n'"#, to: paused),
                "the paused stub was written")

        Media.toolPath = playing
        let playingState = Media.state()
        #expect(playingState?.available == true,
                "a readable helper output reports the state as available")
        #expect(playingState?.isPlaying == true,
                "a playback rate of 1 is playing")

        Media.toolPath = paused
        let pausedState = Media.state()
        #expect(pausedState?.available == true,
                "a readable helper output reports the state as available")
        #expect(pausedState?.isPlaying == false,
                "a playback rate of 0 is not playing")
    }

    @Test func testStateHandlesToolFailure() {
        let saved = Media.toolPath
        defer { Media.toolPath = saved }

        let failing = TestTemp.path("nowplaying-failing-stub")
        let garbage = TestTemp.path("nowplaying-garbage-stub")
        try? FileManager.default.removeItem(atPath: failing)
        try? FileManager.default.removeItem(atPath: garbage)
        #expect(writeStub("exit 1\n", to: failing), "the failing stub was written")
        #expect(writeStub("printf 'garbage\\n'\n", to: garbage),
                "the garbage stub was written")

        Media.toolPath = failing
        let failingState = Media.state()
        #expect(failingState?.available == false,
                "a non-zero helper exit reports the state as unavailable")
        #expect(failingState?.isPlaying == false,
                "a non-zero helper exit reports nothing playing")

        // Garbage stdout is a successful run: the state is available and the
        // unparsable text means nothing is playing.
        Media.toolPath = garbage
        let garbageState = Media.state()
        #expect(garbageState?.available == true,
                "a zero exit with unparsable output is still an available state")
        #expect(garbageState?.isPlaying == false,
                "unparsable output means nothing is playing")
    }

    @Test func testStateWithoutTool() {
        let saved = Media.toolPath
        defer { Media.toolPath = saved }

        Media.toolPath = nil
        #expect(Media.state() == nil, "no helper means no state at all")
    }

    @Test func testCommandInvokesTool() {
        let saved = Media.toolPath
        defer { Media.toolPath = saved }

        let record = TestTemp.path("nowplaying-command-record")
        let stub = TestTemp.path("nowplaying-command-stub")
        try? FileManager.default.removeItem(atPath: record)
        try? FileManager.default.removeItem(atPath: stub)
        let body = """
        printf '%s\\n' "$1" >> "\(record)"
        """
        #expect(writeStub(body, to: stub), "the recording stub was written")

        Media.toolPath = stub
        Media.command(.playPause)

        #expect(waitUntil {
            let text = (try? String(contentsOf: URL(fileURLWithPath: record), encoding: .utf8)) ?? ""
            return text.contains("togglePlayPause")
        }, "the helper is invoked with the transport verb")
    }
}
