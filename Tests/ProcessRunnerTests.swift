import Foundation

internal func runProcessRunnerTests(_ t: TestRunner) {
    t.run("ProcessRunner") { t in
        let echo = ProcessRunner.run("/bin/echo", ["hello"])
        t.expectEqual(echo.status, 0, "echo exits 0")
        t.expectEqual(echo.stdout, Data("hello\n".utf8), "echo output is captured verbatim")
        t.expectEqual(echo.timedOut, false, "a fast child does not time out")

        let failing = ProcessRunner.run("/bin/sh", ["-c", "exit 3"])
        t.expectEqual(failing.status, 3, "the child's exit status is reported")

        // The timeout case is also the wall clock check: a 0.3s deadline must
        // return quickly, which is what proves the child was killed and reaped
        // instead of being waited on until it finished.
        let started = Date()
        let hanging = ProcessRunner.run("/bin/sh", ["-c", "sleep 5"], timeout: 0.3)
        let elapsed = Date().timeIntervalSince(started)
        t.expect(hanging.timedOut, "a child that outlives the deadline is marked timed out")
        t.expect(hanging.status != 0, "a killed child has a non-zero status (got \(hanging.status))")
        t.expect(elapsed < 2.0,
                 "the timeout case returns well before the child would finish (took \(elapsed)s)")

        // `sleep 20 &` inherits the write end of the pipe, so EOF never arrives
        // even after the shell itself is killed. The run must still return
        // promptly, with the stdout written before the deadline and `timedOut`
        // set.
        let grandchildStarted = Date()
        let grandchild = ProcessRunner.run("/bin/sh", ["-c", "sleep 20 & echo hi; sleep 20"], timeout: 1)
        let grandchildElapsed = Date().timeIntervalSince(grandchildStarted)
        t.expect(grandchild.timedOut, "a grandchild holding stdout does not stall the run")
        t.expect(grandchildElapsed < 4.0,
                 "the reader is abandoned when a grandchild holds stdout (took \(grandchildElapsed)s)")
        t.expectEqual(grandchild.stdout, Data("hi\n".utf8),
                      "output written before the grandchild held the pipe is collected")

        let missing = ProcessRunner.run("/nonexistent/binary", [])
        t.expectEqual(missing.status, -1, "a launch failure reports status -1")
        t.expect(missing.launchError != nil, "a launch failure reports its error")

        let script = "i=0; while [ $i -lt 20000 ]; do echo 0123456789abcdef; i=$((i+1)); done"
        let large = ProcessRunner.run("/bin/sh", ["-c", script], timeout: 10)
        t.expectEqual(large.timedOut, false, "a chatty child does not deadlock the runner")
        t.expect(large.stdout.count >= 300000,
                 "the whole large output is collected (got \(large.stdout.count) bytes)")
        t.expectEqual(large.status, 0, "the chatty child exits 0")

        let mixed = ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err 1>&2"])
        t.expectEqual(mixed.stdout, Data("out\n".utf8),
                      "stderr never leaks into stdout")
    }
}
