#!/bin/bash
# Build KeyHUD.app.
#
# Signs with the "KeyHUD Dev" self-signed identity when it exists (see setup-signing.sh)
# so that Accessibility / Input Monitoring grants survive rebuilds. Falls back to ad-hoc,
# which works but silently revokes those grants on every build.
set -euo pipefail
cd "$(dirname "$0")"

APP="KeyHUD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>        <string>KeyHUD</string>
  <key>CFBundleIdentifier</key>        <string>dev.rose.keyhud</string>
  <key>CFBundleName</key>              <string>KeyHUD</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# Built through SPM so the same sources the tests import are the ones shipped; the .app
# is then assembled around the executable SPM produces.
swift build -c release --product KeyHUDApp
cp "$(swift build -c release --product KeyHUDApp --show-bin-path)/KeyHUDApp" \
   "$APP/Contents/MacOS/KeyHUD"

IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "KeyHUD Dev"; then
  IDENTITY="KeyHUD Dev"
else
  echo "note: signing ad-hoc — run ./setup-signing.sh once to stop losing TCC grants on rebuild"
fi
codesign --force --sign "$IDENTITY" --identifier dev.rose.keyhud "$APP"

echo "built $(pwd)/$APP  (signed with: $IDENTITY)"
