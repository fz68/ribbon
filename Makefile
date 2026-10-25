APP      := build/Ribbon.app
BIN      := .build/release/Ribbon
VERSION  := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG      := build/Ribbon-$(VERSION).dmg
PROFDATA := build/RibbonTests.profdata

# Coverage artifacts live next to the debug products; ask SwiftPM where that is.
BIN_DIR  := $(shell swift build --show-bin-path)

.PHONY: all run clean dmg test lint coverage FORCE

all: $(APP)/Contents/Info.plist $(APP)/Contents/MacOS/Ribbon
	codesign --force --sign - $(APP)

# SwiftPM decides what is stale; FORCE just lets the rule run on every make.
$(BIN): FORCE
	swift build -c release

$(APP)/Contents/MacOS/Ribbon: $(BIN)
	mkdir -p $(dir $@)
	cp $(BIN) $@

$(APP)/Contents/Info.plist: Resources/Info.plist
	mkdir -p $(dir $@)
	cp Resources/Info.plist $@

# Serialized on purpose: the tests share a process-global log path.
test:
	swift test --no-parallel

lint:
	swift build -Xswiftc -warnings-as-errors
	swift build --build-tests -Xswiftc -warnings-as-errors

coverage:
	rm -f $(PROFDATA)
	swift test --no-parallel --enable-code-coverage
	xcrun llvm-profdata merge -sparse $(BIN_DIR)/codecov/default.profdata -o $(PROFDATA)
	xcrun llvm-cov report $(BIN_DIR)/RibbonPackageTests.xctest/Contents/MacOS/RibbonPackageTests \
		-instr-profile=$(PROFDATA) Sources Tests

run: all
	-pkill -x Ribbon
	sleep 0.5
	open $(APP)

dmg: all
	rm -rf build/dmg
	mkdir -p build/dmg
	ditto $(APP) build/dmg/Ribbon.app
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Ribbon -srcfolder build/dmg -format UDZO -ov $(DMG)

clean:
	rm -rf build .build

FORCE:
