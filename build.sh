#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=CrabBar.app/Contents

# VERSION is the single source of truth; release.sh bumps it.
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

rm -rf CrabBar.app
mkdir -p "$APP/MacOS" "$APP/Resources"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CrabBar</string>
  <key>CFBundleDisplayName</key><string>CrabBar</string>
  <key>CFBundleIdentifier</key><string>com.dorf.crabbar</string>
  <key>CFBundleExecutable</key><string>CrabBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>Claude usage for your menu bar.</string>
</dict></plist>
PLIST

# Regenerate with tools/make_icon.swift if Clawd or the palette changes.
cp AppIcon.icns "$APP/Resources/"

swiftc -O \
  -target arm64-apple-macosx14.0 \
  Sources/Usage.swift Sources/Sessions.swift Sources/Auth.swift Sources/API.swift Sources/Updates.swift Sources/Clawd.swift Sources/ClawdAnims.swift \
  Sources/Design.swift \
  Sources/Popover.swift \
  Sources/SelfTest.swift Sources/main.swift \
  -o "$APP/MacOS/CrabBar"

# Personal project: sign ONLY with a Developer ID cert from the personal team below —
# never any work certs also present in this keychain. Until that cert exists,
# ad-hoc sign (works locally; keychain re-prompts after each rebuild, and Gatekeeper
# blocks it on other Macs). Hardened runtime + timestamp are notarization requirements.
TEAM="23F3TUG54Q"   # personal Apple Developer team (Dor Furman, individual) — never a work team
IDENTITY=""
EXTRA=""
if [ -n "$TEAM" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v t="($TEAM)" '/Developer ID Application/ && index($0, t) {print $2; exit}')
  [ -n "$IDENTITY" ] && EXTRA="--options runtime --timestamp" \
    || echo "warning: no Developer ID cert for team $TEAM; ad-hoc signing"
fi
codesign --force --sign "${IDENTITY:--}" $EXTRA --identifier com.dorf.crabbar CrabBar.app >/dev/null 2>&1 \
  || echo "warning: codesign failed; notifications and launch-at-login may not work"

"$APP/MacOS/CrabBar" --test
echo "built CrabBar.app — open it with: open CrabBar.app"
