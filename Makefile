CONFIG   := release
EXEC     := Takeshot
APPNAME  := Takeshot.app
DIST     := dist
BUNDLE   := $(DIST)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Screen Recording/Camera/Microphone/Accessibility grants to the
## code signature. An ad-hoc signature ("-") changes on every rebuild, which
## resets those grants and forces re-approval each time. Signing with a stable
## identity - a real Developer ID if present, otherwise a free Apple
## Development certificate - keeps the identity constant across rebuilds so
## the grant sticks. Falls back to ad-hoc only if neither is available.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep -E "Developer ID Application|Apple Development" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

## Sparkle (automatic updates) ships as a binary framework via SwiftPM; it
## has to be copied into the bundle and signed before the app itself.
SPARKLE_FRAMEWORK := .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

.PHONY: all build app run install clean release

all: app

build:
	swift build -c $(CONFIG)

## Assembles a real .app bundle and signs it. TCC (Screen Recording, Camera,
## Microphone, Accessibility) keys grants to the bundle identity, not the raw
## executable.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp .build/$(CONFIG)/$(EXEC) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@cp Resources/Donation/*.png "$(CONTENTS)/Resources/"
	@mkdir -p "$(CONTENTS)/Frameworks"
	@cp -R "$(SPARKLE_FRAMEWORK)" "$(CONTENTS)/Frameworks/"
	@codesign --force --deep --sign "$(SIGN_ID)" --options runtime --timestamp=none "$(CONTENTS)/Frameworks/Sparkle.framework"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Installing to a stable /Applications path (rather than running the app from
## a build directory whose contents get replaced each time) is what makes
## "grants survive rebuilds" actually true in practice.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

clean:
	@rm -rf "$(DIST)" .build

## Builds a universal, signed, zipped release and updates the appcast.
## Usage: make release VERSION=0.3.0   (see scripts/release.sh)
release:
	@./scripts/release.sh "$(VERSION)"
