SDKROOT := $(shell xcrun --show-sdk-path)
APP := build/Ribbon.app
BIN := build/Ribbon
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG := build/Ribbon-$(VERSION).dmg

.PHONY: all run clean dmg

all: $(APP)/Contents/Info.plist $(APP)/Contents/MacOS/Ribbon
	codesign --force --sign - $(APP)

$(BIN): Sources/main.swift Sources/TouchBarController.swift Sources/InputSource.swift Sources/Media.swift Sources/SystemStatus.swift Sources/AeroSpace.swift Sources/Bridging-Header.h
	mkdir -p build
	swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -sdk $(SDKROOT) -import-objc-header Sources/Bridging-Header.h Sources/main.swift Sources/TouchBarController.swift Sources/InputSource.swift Sources/Media.swift Sources/SystemStatus.swift Sources/AeroSpace.swift -o $(BIN) -framework Cocoa

$(APP)/Contents/MacOS/Ribbon: $(BIN)
	mkdir -p $(dir $@)
	cp $(BIN) $@

$(APP)/Contents/Info.plist: Resources/Info.plist
	mkdir -p $(dir $@)
	cp Resources/Info.plist $@

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
