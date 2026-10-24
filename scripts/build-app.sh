#!/bin/zsh
# Builds build/GH Switch.app with the gh-switch CLI bundled at Contents/MacOS/gh-switch.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/GH Switch.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/GHSwitch" "$BIN/gh-switch" "$APP/Contents/MacOS/"
codesign --force --sign - "$APP/Contents/MacOS/gh-switch"
codesign --force --sign - "$APP"

echo "Built $APP"
