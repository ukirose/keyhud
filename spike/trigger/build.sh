#!/bin/bash
# Build the spike as a real .app bundle.
#
# TCC (Accessibility, Input Monitoring) grants attach to a code signature, not to a
# path. A bare binary run from a shell inherits the *terminal's* identity, so the
# grant ends up on the terminal — too broad, and it silently fails when the terminal
# was denied earlier. An app bundle with its own bundle id gets its own row in
# System Settings, which is also what the shipping product needs.
set -euo pipefail
cd "$(dirname "$0")"

APP="TriggerSpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>       <string>TriggerSpike</string>
  <key>CFBundleIdentifier</key>       <string>dev.rose.keyhud.triggerspike</string>
  <key>CFBundleName</key>             <string>TriggerSpike</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key>   <string>13.0</string>
  <key>LSUIElement</key>              <true/>
</dict>
</plist>
PLIST

swiftc -O -o "$APP/Contents/MacOS/TriggerSpike" main.swift \
  -framework IOKit -framework CoreGraphics -framework Foundation -framework Cocoa

# Ad-hoc signature. Stable enough for a spike; note that rebuilding changes the
# cdhash, which can invalidate an existing TCC grant and require re-approval.
codesign --force --sign - --identifier dev.rose.keyhud.triggerspike "$APP"

echo "built $(pwd)/$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true
