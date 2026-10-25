import Foundation

internal func runParsingTests(_ t: TestRunner) {
    t.run("AeroSpace.workspaceEntries") { t in
        let basic = AeroSpace.workspaceEntries(Data("1|true\n2|false\n".utf8))
        t.expectEqual(basic.count, 2, "two lines produce two entries")
        if basic.count == 2 {
            t.expectEqual(basic[0].name, "1", "first entry keeps its name")
            t.expectEqual(basic[0].isFocused, true, "first entry is focused")
            t.expectEqual(basic[1].name, "2", "second entry keeps its name")
            t.expectEqual(basic[1].isFocused, false, "second entry is not focused")
        }

        let padded = AeroSpace.workspaceEntries(Data("  dev | TRUE \n".utf8))
        t.expectEqual(padded.count, 1, "a padded line still produces one entry")
        if padded.count == 1 {
            t.expectEqual(padded[0].name, "dev", "the name is trimmed")
            t.expectEqual(padded[0].isFocused, true, "the flag is trimmed and case-folded")
        }

        let broken = AeroSpace.workspaceEntries(Data("no separator\n1|true\n".utf8))
        t.expectEqual(broken.count, 1, "a line without | is skipped")
        if broken.count == 1 {
            t.expectEqual(broken[0].name, "1", "the well formed line survives")
        }

        let nameless = AeroSpace.workspaceEntries(Data("|true\n".utf8))
        t.expectEqual(nameless.count, 0, "an empty name is skipped")

        t.expectEqual(AeroSpace.workspaceEntries(Data()).count, 0, "empty input yields no entries")
        t.expectEqual(AeroSpace.workspaceEntries(Data([0xFF, 0xFE, 0x41])).count, 0,
                      "non-UTF8 bytes yield no entries")
    }

    t.run("AeroSpace.lines") { t in
        t.expectEqual(AeroSpace.lines(Data("a\nb\r\nc\n".utf8)), ["a", "b", "c"],
                      "LF and CRLF both split into lines")
        t.expectEqual(AeroSpace.lines(Data("a\n\n\nb\n".utf8)), ["a", "b"],
                      "blank lines are dropped")
        t.expectEqual(AeroSpace.lines(Data("  a  \n".utf8)), ["a"],
                      "each line is trimmed")
        t.expectEqual(AeroSpace.lines(Data()), [], "empty input yields no lines")
        t.expectEqual(AeroSpace.lines(Data([0xFF, 0xFE, 0x41])), [],
                      "non-UTF8 bytes yield no lines")
    }
}
