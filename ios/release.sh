#!/usr/bin/env bash
# Archive, export and upload BlueLyrics for iPhone and iPad to App Store Connect.
# Usage: ./release.sh <build-number>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
BUILD="${1:?usage: ./release.sh <build-number>}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
APP_ID="6809355924"          # App Store Connect app record shared with the Mac and tvOS apps
API_KEY="93ZTYF69FA"         # AuthKey_93ZTYF69FA.p8 in ~/.private_keys
API_ISSUER="b26420cc-1ab6-4fad-8249-d64601361045"
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD/" project.yml
xcodegen generate >/dev/null
ARCHIVE="build/BlueLyricsiOS.xcarchive"; rm -rf "$ARCHIVE" build/export
"$XCODEBUILD" -project BlueLyricsiOS.xcodeproj -scheme BlueLyricsiOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath build/DerivedData archive 2>&1 \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
"$XCODEBUILD" -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions.plist -exportPath build/export 2>&1 \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
IPA="build/export/BlueLyrics.ipa"; ls -l "$IPA"
/usr/bin/xcrun altool --upload-app -t ios -f "$IPA" --apple-id "$APP_ID" --apiKey "$API_KEY" --apiIssuer "$API_ISSUER" 2>&1 | grep -E "UPLOAD|error|Error" || true
echo "uploaded build $BUILD"
