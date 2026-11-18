#!/bin/bash
# Builds "NetScope Pro.app" from the Swift package (release), ad-hoc signed with Hardened Runtime.
# Usage: ./scripts/build_app.sh            → dist/NetScope Pro.app + dist/NetScopePro-macOS.zip
#        SIGN_IDENTITY="Developer ID Application: …" ./scripts/build_app.sh   (optional real signing)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/NetScope Pro.app"
swift build -c release --product NetScopePro
BIN="$(swift build -c release --show-bin-path)/NetScopePro"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NetScopePro"
sed -e 's/$(EXECUTABLE_NAME)/NetScopePro/' -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/fr.netscope.pro/' \
  Sources/NetScopeApp/Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements Sources/NetScopeApp/Resources/NetScopePro.entitlements \
  --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" dist/NetScopePro-macOS.zip
echo "OK : $APP"
