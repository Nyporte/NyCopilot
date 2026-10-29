# NyCopilot: a Rust core (crates/) shared by native clients (apps/). Today: the macOS client.
SWIFT := xcrun swift
SWIFT_FLAGS := --disable-sandbox --package-path apps/macos --cache-path apps/macos/.build/cache \
	--config-path apps/macos/.build/config --security-path apps/macos/.build/security
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/apps/macos/.build/module-cache
APP := dist/NyCopilot.app
# Local builds use an ad-hoc signature; pass SIGN_IDENTITY for a stable Apple signing identity.
SIGN_IDENTITY ?= -

.PHONY: build core test test-core test-macos run icon clean

# The optimized core as a static library, then the app bundle that links it.
build: core
	$(SWIFT) build $(SWIFT_FLAGS) -c release
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp apps/macos/.build/release/NyCopilot "$(APP)/Contents/MacOS/NyCopilot"
	cp apps/macos/Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp apps/macos/Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"
	codesign --verify --strict "$(APP)"

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
