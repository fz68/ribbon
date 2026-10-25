import Foundation
import Testing
@testable import RibbonCore

/// Creates `path` (and its parents), reporting whether it now exists.
private func makeDirectory(_ path: String) -> Bool {
    (try? FileManager.default.createDirectory(atPath: path,
                                              withIntermediateDirectories: true)) != nil
}

/// Creates an executable stub at `path`, reporting whether it was written.
private func makeExecutable(_ path: String) -> Bool {
    FileManager.default.createFile(atPath: path,
                                   contents: Data("#!/bin/sh\n".utf8),
                                   attributes: [.posixPermissions: 0o755])
}

@Suite(.serialized) final class ToolLocatorTests {
    init() { _ = TestBootstrap.tempRoot }

    @Test func testToolLocatorFindPrefixes() {
        let binA = TestTemp.path("bin-a")
        let binB = TestTemp.path("bin-b")
        #expect(makeDirectory(binA), "bin-a was created")
        #expect(makeDirectory(binB), "bin-b was created")
        #expect(makeExecutable("\(binA)/tool"), "bin-a/tool was created")

        #expect(ToolLocator.find("tool", searchPATH: false, prefixes: [binA, binB])
                == "\(binA)/tool",
                "the tool is found in the first prefix")
    }

    @Test func testToolLocatorFindPrefersTheFirstPrefix() {
        let binA = TestTemp.path("bin-a")
        let binB = TestTemp.path("bin-b")
        #expect(makeDirectory(binA), "bin-a was created")
        #expect(makeDirectory(binB), "bin-b was created")
        #expect(makeExecutable("\(binA)/tool"), "bin-a/tool was created")
        #expect(makeExecutable("\(binB)/tool"), "bin-b/tool was created")

        #expect(ToolLocator.find("tool", searchPATH: false, prefixes: [binA, binB])
                == "\(binA)/tool",
                "the earlier prefix wins")
        #expect(ToolLocator.find("tool", searchPATH: false, prefixes: [binB, binA])
                == "\(binB)/tool",
                "the prefix order decides the result")
    }

    @Test func testToolLocatorFindSkipsNonExecutables() {
        let binA = TestTemp.path("bin-a")
        let binB = TestTemp.path("bin-b")
        #expect(makeDirectory(binA), "bin-a was created")
        #expect(makeDirectory(binB), "bin-b was created")
        let plain = "\(binA)/plain"
        #expect(FileManager.default.createFile(atPath: plain,
                                              contents: Data("plain\n".utf8),
                                              attributes: [.posixPermissions: 0o644]),
                "bin-a/plain was created")

        #expect(ToolLocator.find("plain", searchPATH: false, prefixes: [binA]) == nil,
                "a non-executable file is not found")
        #expect(ToolLocator.find("missing", searchPATH: false, prefixes: [binA, binB]) == nil,
                "a missing tool is not found")
    }

    @Test func testFindSearchesPATH() {
        let binA = TestTemp.path("path-bin-a")
        let binB = TestTemp.path("path-bin-b")
        #expect(makeDirectory(binA), "path-bin-a was created")
        #expect(makeDirectory(binB), "path-bin-b was created")
        #expect(makeExecutable("\(binA)/path-tool"), "path-bin-a/path-tool was created")
        #expect(makeExecutable("\(binA)/dual-tool"), "path-bin-a/dual-tool was created")
        #expect(makeExecutable("\(binB)/dual-tool"), "path-bin-b/dual-tool was created")

        #expect(ToolLocator.find("path-tool", searchPATH: true, prefixes: [],
                                 environment: ["PATH": binA]) == "\(binA)/path-tool",
                "the tool is found in the injected PATH")

        #expect(ToolLocator.find("path-tool", searchPATH: true, prefixes: [],
                                 environment: ["PATH": ""]) == nil,
                "an empty PATH finds nothing")

        #expect(ToolLocator.find("path-tool", searchPATH: true, prefixes: [],
                                 environment: ["PATH": "\(binB):\(binA)"]) == "\(binA)/path-tool",
                "a directory without the tool is skipped")

        #expect(ToolLocator.find("dual-tool", searchPATH: true, prefixes: [],
                                 environment: ["PATH": "\(binB):\(binA)"]) == "\(binB)/dual-tool",
                "the first PATH entry wins")
    }
}
