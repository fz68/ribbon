import Foundation
import Testing
@testable import RibbonCore

@Suite(.serialized) final class ProcessRunnerTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testProcessRunner() {
        let echo = ProcessRunner.run("/bin/echo", ["hello"])
        #expect(echo.status == 0, "echo exits 0")
        #expect(echo.stdout == Data("hello\n".utf8), "echo output is captured verbatim")
        #expect(echo.timedOut == false, "a fast child does not time out")

        let failing = ProcessRunner.run("/bin/sh", ["-c", "exit 3"])
        #expect(failing.status == 3, "the child's exit status is reported")

        // The timeout case is also the wall clock check: a 0.3s deadline must
        // return quickly, which is what proves the child was killed and reaped
        // instead of being waited on until it finished.
        let started = Date()
        let hanging = ProcessRunner.run("/bin/sh", ["-c", "sleep 5"], timeout: 0.3)
        let elapsed = Date().timeIntervalSince(started)
        #expect(hanging.timedOut, "a child that outlives the deadline is marked timed out")
        #expect(hanging.status != 0, "a killed child has a non-zero status (got \(hanging.status))")
        #expect(hanging.status == 9 || hanging.status == 15,
                "killed by a signal with the real reaped status (got \(hanging.status))")
        // 0.3 + 0.25 (TERM grace) + KILL + fast EOF ~= 0.6s against a 2.0s
        // bound; the read grace only elapses in full when something still
        // holds the pipe.
        #expect(elapsed < 2.0,
                "the timeout case returns well before the child would finish (took \(elapsed)s)")

        // `sleep 20 &` inherits the write end of the pipe, so EOF never arrives
        // even after the shell itself is killed. The run must still return
        // promptly, with the stdout written before the deadline and `timedOut`
        // set.
        let grandchildStarted = Date()
        let grandchild = ProcessRunner.run("/bin/sh", ["-c", "sleep 20 & echo hi; sleep 20"], timeout: 1)
        let grandchildElapsed = Date().timeIntervalSince(grandchildStarted)
        #expect(grandchild.timedOut, "a grandchild holding stdout does not stall the run")
        // worst case 1 + 0.25 + 0.25 + 1.0 (read grace; the grandchild holds
        // the pipe) = 2.5s, plus a ~2ms stop-flag poll, against a 4.0s bound.
        #expect(grandchildElapsed < 4.0,
                "the reader is abandoned when a grandchild holds stdout (took \(grandchildElapsed)s)")
        #expect(grandchild.stdout == Data("hi\n".utf8),
                "output written before the grandchild held the pipe is collected")

        let missing = ProcessRunner.run("/nonexistent/binary", [])
        #expect(missing.status == -1, "a launch failure reports status -1")
        #expect(missing.launchError != nil, "a launch failure reports its error")

        let script = "i=0; while [ $i -lt 20000 ]; do echo 0123456789abcdef; i=$((i+1)); done"
        let large = ProcessRunner.run("/bin/sh", ["-c", script], timeout: 30)
        #expect(large.timedOut == false, "a chatty child does not deadlock the runner")
        #expect(large.stdout.count >= 300000,
                "the whole large output is collected (got \(large.stdout.count) bytes)")
        #expect(large.status == 0, "the chatty child exits 0")

        let mixed = ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err 1>&2"])
        #expect(mixed.stdout == Data("out\n".utf8),
                "stderr never leaks into stdout")
    }

    @Test func testRunDetachedCompletes() {
        let box = Box<ProcessResult>()
        ProcessRunner.runDetached("/bin/echo", ["hi"]) { result in
            box.store(result)
        }

        #expect(waitUntil { box.value != nil },
                "the detached completion runs within the wait window")
        guard let result = box.value else {
            #expect(Bool(false), "the detached completion delivered a result")
            return
        }
        #expect(result.status == 0, "the detached child exits 0")
        #expect(result.stdout == Data("hi\n".utf8), "the detached run captures stdout verbatim")
        #expect(result.timedOut == false, "a fast detached child does not time out")
    }

    @Test func testRunEscalatesToSIGKILL() {
        // The shell ignores SIGTERM, so only the SIGKILL escalation can end it.
        let started = Date()
        let result = ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 5"], timeout: 0.3)
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.timedOut, "a child that ignores SIGTERM still times out")
        #expect(result.status != 0,
                "the SIGKILLed child has a non-zero status (got \(result.status))")
        #expect(result.status == 9, "the SIGKILLed child reports signal 9 (got \(result.status))")
        // TERM is trapped, so: 0.3 + 0.25 + KILL + 1.0 (read grace; the
        // forked sleep survives the shell as an orphan holding the pipe)
        // ~= 1.55s against a 2.0s bound.
        #expect(elapsed < 2.0,
                "terminate then kill returns well before the child would finish (took \(elapsed)s)")
    }

    @Test func testRunAbandonsGrandchildPipe() {
        // `sleep 30 &` inherits the write end of the pipe, so EOF never arrives
        // even after the shell itself exits. The read must be abandoned after
        // the read grace instead of waiting for the grandchild.
        let started = Date()
        let result = ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & exit 0"], timeout: 2)
        let elapsed = Date().timeIntervalSince(started)

        // the child exits fast; only the read grace elapses (~1.0s) because
        // the grandchild holds the pipe, against a 4.0s bound.
        #expect(elapsed < 4.0,
                "the run returns after the read grace instead of hanging (took \(elapsed)s)")
        #expect(result.stdout.isEmpty, "the grandchild writes nothing to stdout")
        #expect(result.timedOut == false, "the shell itself exits before the deadline")
        #expect(result.status == 0, "the shell exits 0")
    }
}
