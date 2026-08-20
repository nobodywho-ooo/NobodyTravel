default: help

PROJECT := NobodyTravel.xcodeproj
SCHEME := NobodyTravel
BUNDLE_ID := com.duarteocarmo.NobodyTravel
SIMULATOR ?= iPhone 17 Pro
DERIVED_DATA := .build

.PHONY: help
help: # Show the available commands.
	@grep -E '^[a-zA-Z0-9-]+:.*#' Makefile | sort | while read -r line; do printf "\033[1;32m$$(echo $$line | cut -f 1 -d':')\033[00m:$$(echo $$line | cut -f 2- -d'#')\n"; done

.PHONY: install
install: # Resolve Swift package dependencies.
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME)

.PHONY: compile
compile: # Build the app for the iOS Simulator.
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED_DATA) build

.PHONY: run-simulator
run-simulator: compile # Install and run the app on a simulator.
	@xcrun simctl boot '$(SIMULATOR)' 2>/dev/null || true
	@open -a Simulator
	xcrun simctl bootstatus '$(SIMULATOR)' -b
	xcrun simctl install '$(SIMULATOR)' '$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/NobodyTravel.app'
	xcrun simctl launch '$(SIMULATOR)' $(BUNDLE_ID)

.PHONY: check
check: # Run Xcode static analysis.
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED_DATA) analyze
