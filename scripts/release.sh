#!/bin/zsh
# Builds a release of Takeshot and updates the Sparkle appcast.
#
#   ./scripts/release.sh 0.3.1            (or: make release VERSION=0.3.1)
#
# What it does:
#   1. sets the version in Resources/Info.plist (build number +1)
#   2. builds a universal (Apple Silicon + Intel) app, bundles Sparkle, signs it
#      - with "Developer ID Application" if you have one (needed for OTHER Macs),
#        otherwise with your Apple Development identity (works on THIS Mac only)
#      - notarizes when NOTARY_PROFILE is set (xcrun notarytool store-credentials)
#   3. zips it into release/Takeshot-<version>.zip
#   4. regenerates release/appcast.xml, signing the update with the Sparkle key
#      in your Keychain
#
# Then upload BOTH release/appcast.xml and the zip to the place SUFeedURL points
# at (release.config: DOWNLOAD_URL_PREFIX). Users' apps pick it up automatically.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ -z "$VERSION" ]] && { echo "usage: $0 <version>   e.g. $0 0.3.1"; exit 1; }
[[ -f release.config ]] && source release.config
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-}"
FEED_URL="${FEED_URL:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

APP=Takeshot
PLIST=Resources/Info.plist
OUT=release
BUNDLE="$OUT/build/$APP.app"
SPARKLE=.build/artifacts/sparkle/Sparkle

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $PLIST) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" $PLIST
if [[ -n "$FEED_URL" ]]; then /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" $PLIST; fi
echo "==> $APP $VERSION (build $BUILD)"

# A one-step universal build needs full Xcode; with only the Command Line
# Tools each architecture is built separately and merged with lipo.
echo "==> building Apple Silicon"
swift build -c release 2>&1 | grep -E "error:|Build complete" | tail -3
ARM_BIN=.build/release/$APP
BIN="$OUT/$APP-universal"
mkdir -p "$OUT"
echo "==> building Intel"
# Separate scratch folder: sharing .build between two architectures
# corrupts SwiftPM's build database.
INTEL_BIN=.build-intel/x86_64-apple-macosx/release/$APP
if swift build -c release --triple x86_64-apple-macosx --scratch-path .build-intel 2>&1 | grep -E "error:|Build complete" | tail -3 \
   && [[ -x "$INTEL_BIN" ]]; then
  lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$BIN"
  echo "==> universal: $(lipo -archs "$BIN")"
else
  echo "!!  Intel build failed; this release is Apple Silicon only."
  cp "$ARM_BIN" "$BIN"
fi

SIGN_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
  echo "!!  No Developer ID certificate: this build will only open on Macs that trust your development certificate (i.e. yours)."
fi
[[ -z "$SIGN_ID" ]] && SIGN_ID="-"

rm -rf "$OUT/build"; mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp $PLIST "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
cp Resources/Donation/*.png "$BUNDLE/Contents/Resources/"
cp "$SPARKLE/LICENSE" "$BUNDLE/Contents/Resources/Sparkle-LICENSE.txt"   # MIT notice must ship with the app
cp -R "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$BUNDLE/Contents/Frameworks/"
codesign --force --deep --sign "$SIGN_ID" --options runtime --timestamp "$BUNDLE/Contents/Frameworks/Sparkle.framework" 2>/dev/null \
  || codesign --force --deep --sign "$SIGN_ID" --options runtime --timestamp=none "$BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_ID" --entitlements Resources/$APP.entitlements --options runtime --timestamp "$BUNDLE" 2>/dev/null \
  || codesign --force --sign "$SIGN_ID" --entitlements Resources/$APP.entitlements --options runtime --timestamp=none "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
echo "==> signed with: $SIGN_ID"

ZIP="$OUT/$APP-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"

if [[ -n "$NOTARY_PROFILE" && "$SIGN_ID" == Developer\ ID* ]]; then
  echo "==> notarizing (this takes a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$BUNDLE"
  rm -f "$ZIP"; ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
else
  echo "!!  Not notarized (needs a Developer ID certificate and NOTARY_PROFILE in release.config)."
fi

echo "==> updating appcast"
ARGS=()
[[ -n "$DOWNLOAD_URL_PREFIX" ]] && ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
"$SPARKLE/bin/generate_appcast" "${ARGS[@]}" "$OUT" 2>&1 | tail -2
rm -rf "$OUT/build" "$BIN"

echo
echo "Done:  $ZIP"
echo "       $OUT/appcast.xml"
echo "Upload both to: ${DOWNLOAD_URL_PREFIX:-<set DOWNLOAD_URL_PREFIX in release.config>}"
