SDKROOT := $(shell xcrun --show-sdk-path)
APP := build/Ribbon.app
BIN := build/Ribbon

.PHONY: all run clean

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

clean:
	rm -rf build
