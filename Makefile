# ItsMeAgain build helpers.
#   make test      – CompanionKit unit tests
#   make build     – Debug build
#   make install   – Release build copied to /Applications (needed for "Open at Login")

PROJECT = ItsMeAgain.xcodeproj
SCHEME  = ItsMeAgain
DERIVED = build/DerivedData

.PHONY: generate build release install test clean

generate:
	xcodegen generate -q

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build

release: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build

install: release
	@if pgrep -x ItsMeAgain >/dev/null; then osascript -e 'quit app "ItsMeAgain"'; sleep 2; fi
	rm -rf /Applications/ItsMeAgain.app
	cp -R $(DERIVED)/Build/Products/Release/ItsMeAgain.app /Applications/
	@echo "Installed /Applications/ItsMeAgain.app"

test:
	cd Packages/CompanionKit && swift test

clean:
	rm -rf build
