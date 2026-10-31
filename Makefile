# NyCopilot: a Rust core (crates/) shared by native clients (apps/). Today: the macOS client.
SWIFT := xcrun swift
SWIFT_FLAGS := --disable-sandbox --package-path apps/macos --cache-path apps/macos/.build/cache \
	--config-path apps/macos/.build/config --security-path apps/macos/.build/security
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/apps/macos/.build/module-cache
APP := dist/NyCopilot.app
# macOS ties Accessibility and Keychain grants to the app's signing identity. An ad-hoc signature
# changes with every build and silently invalidates them, so sign with a certificate when one exists:
# Developer ID Application (also what distribution needs), else Apple Development. Override with
# SIGN_IDENTITY=… if the chosen certificate has expired.
SIGN_IDENTITY ?= $(or \
	$(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Developer ID Application:/ { print $$2; exit }'), \
	$(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development:/ { print $$2; exit }'), \
	-)

.PHONY: build core test test-core test-macos run icon clean release

# The optimized core as a static library, then the app bundle that links it.
build: core
	$(SWIFT) build $(SWIFT_FLAGS) -c release
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp apps/macos/.build/release/NyCopilot "$(APP)/Contents/MacOS/NyCopilot"
	cp apps/macos/Resources/Info.plist "$(APP)/Contents/Info.plist"
	@if [ -n "$(VERSION)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP)/Contents/Info.plist"; fi
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(APP)/Contents/Info.plist"; fi
	cp apps/macos/Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp -R apps/macos/Resources/en.lproj "$(APP)/Contents/Resources/"
	@# zh-Hans ships once every interface string is wrapped in L(); until then it would mix languages.
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then echo "warning: no signing certificate found; ad-hoc builds lose Accessibility and Keychain access on every rebuild"; fi
	codesign --force --options runtime --entitlements apps/macos/Resources/NyCopilot.entitlements --sign "$(SIGN_IDENTITY)" "$(APP)"
	codesign --verify --strict "$(APP)"
	@codesign -d -r- "$(APP)" 2>&1 | grep designated

core:
	cargo build --release -p ny-ffi

# Core tests use loopback HTTP and temporary databases; macOS tests need no permissions.
test: test-core test-macos

test-core:
	cargo test --workspace

test-macos:
	$(SWIFT) test $(SWIFT_FLAGS)

# Launching the bundle gives Keychain and Accessibility a consistent application identity.
run: build
	open "$(APP)"

# Regenerate the app icon from its vector source.
icon:
	rm -rf .build/AppIcon.iconset
	$(SWIFT) apps/macos/Scripts/make-icon.swift .build/AppIcon.iconset
	iconutil -c icns .build/AppIcon.iconset -o apps/macos/Resources/AppIcon.icns

clean:
	cargo clean
	rm -rf apps/macos/.build dist .build

# A notarized, stapled zip from the current version tag; see scripts/release.sh.
release:
	scripts/release.sh
