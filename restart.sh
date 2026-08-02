#!/bin/bash
# Rebuild and restart KeyHUD. Safe to run repeatedly: the app is signed with the stable
# "KeyHUD Dev" identity, so Accessibility and Input Monitoring survive each rebuild.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

pkill -f 'KeyHUD.app/Contents/MacOS/KeyHUD' 2>/dev/null && echo "stopped the running instance" || true
sleep 1
open ./KeyHUD.app

sleep 1
if pgrep -f 'KeyHUD.app/Contents/MacOS/KeyHUD' >/dev/null; then
  echo "running — hold ⌘ to check"
else
  echo "FAILED to start"
  exit 1
fi
