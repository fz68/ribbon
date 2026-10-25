import Foundation

@main
struct TestMain {
    static func main() {
        let runner = TestRunner()

        // Isolation: every file the tests touch lives under one temp directory.
        // The redirectable paths are saved first so the real ones can be put
        // back before the process exits.
        let tempRoot = TestTemp.makeRoot()
        TestTemp.root = tempRoot

        let originalLogPath = Log.path
        let originalIMEPath = InputSource.configurationPath
        let originalClockPath = TimeFormat.configurationPath

        Log.path = TestTemp.path("ribbon.log")
        InputSource.configurationPath = TestTemp.path("ime.json")
        TimeFormat.configurationPath = TestTemp.path("clock.json")

        runParsingTests(runner)
        runMediaTests(runner)
        runBatteryTests(runner)
        runTimeFormatTests(runner)
        runConfigTests(runner)
        runProcessRunnerTests(runner)
        runLogTests(runner)
        runBarLayoutTests(runner)

        // `finish()` terminates the process, so the cleanup cannot live in a
        // defer block: it has to happen before the summary is printed.
        Log.path = originalLogPath
        InputSource.configurationPath = originalIMEPath
        TimeFormat.configurationPath = originalClockPath
        try? FileManager.default.removeItem(atPath: tempRoot)

        runner.finish()
    }
}
