#!/usr/bin/env bash
# Build, sign and package BlueLyrics for the Mac App Store without Xcode.
# Usage: ./release.sh <build-number>   -> dist/BlueLyrics-<version>-<build>.pkg
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
BUILD="${1:?build number}"
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
DIST="Apple Distribution: Philip Wright (2PV5B37GLP)"
INST="3rd Party Mac Developer Installer: Philip Wright (2PV5B37GLP)"
PROFILE="$HOME/Library/BlueLyrics-signing/BlueLyrics_Mac_App_Store.provisionprofile"
swift build -c release 2>&1 | grep -E "error|Build complete"
APP="dist/BlueLyrics.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BlueLyrics "$APP/Contents/MacOS/"
cp -R Resources/. "$APP/Contents/Resources/"
cp ../assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
sed -e 's/\$(EXECUTABLE_NAME)/BlueLyrics/; s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.blueguard.bluelyrics/' -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD/" Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
for key in LSApplicationCategoryType LSMinimumSystemVersion CFBundleIconFile; do plutil -extract "$key" raw "$APP/Contents/Info.plist" >/dev/null || { echo "missing $key"; exit 1; }; done
codesign --force --timestamp --options runtime --sign "$DIST" --entitlements dist/store.entitlements "$APP" 2>&1 | grep -v "replacing existing" || true
codesign --verify --deep --strict "$APP"
PKG="dist/BlueLyrics-$VERSION-$BUILD.pkg"; rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$INST" "$PKG" >/dev/null
echo "$PKG"
