SDKROOT := $(shell xcrun --show-sdk-path)
APP := build/Ribbon.app
BIN := build/Ribbon
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG := build/Ribbon-$(VERSION).dmg

SOURCES      := $(wildcard Sources/*.swift)
BRIDGING     := Sources/Bridging-Header.h
TEST_SOURCES := $(filter-out Sources/main.swift,$(SOURCES)) $(wildcard Tests/*.swift)
SWIFTBASE    := -swift-version 5 -target arm64-apple-macosx13.0 -sdk $(SDKROOT) -import-objc-header $(BRIDGING)

.PHONY: all run clean dmg test lint FORCE

all: $(APP)/Contents/Info.plist $(APP)/Contents/MacOS/Ribbon
	codesign --force --sign - $(APP)

$(BIN): $(SOURCES) $(BRIDGING) FORCE
	mkdir -p build
	swiftc $(SWIFTBASE) -O $(SOURCES) -o $(BIN) -framework Cocoa

$(APP)/Contents/MacOS/Ribbon: $(BIN)
	mkdir -p $(dir $@)
	cp $(BIN) $@

$(APP)/Contents/Info.plist: Resources/Info.plist
	mkdir -p $(dir $@)
	cp Resources/Info.plist $@

build/RibbonTests: $(TEST_SOURCES) $(BRIDGING) FORCE
	mkdir -p build
	swiftc $(SWIFTBASE) -parse-as-library $(TEST_SOURCES) -o build/RibbonTests -framework Cocoa

test: build/RibbonTests
	./build/RibbonTests

lint:
	swiftc -typecheck -warnings-as-errors $(SWIFTBASE) $(SOURCES)
	swiftc -typecheck -warnings-as-errors $(SWIFTBASE) -parse-as-library $(TEST_SOURCES)

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
	rm -rf build

FORCE:
