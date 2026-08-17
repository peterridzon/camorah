#!/usr/bin/env bash
#
# Builds Orah Live Studio.app.
#
# There is no Xcode on this machine, only Command Line Tools, so the bundle is
# assembled by hand around the SwiftPM binary. That is the whole trick: a macOS
# app is a directory with a known shape and an Info.plist.
#
#   ./build-app.sh              release build → ./build/Orah Live Studio.app
#   ./build-app.sh --debug      faster build, for iterating
#   ./build-app.sh --run        build, then launch it
#
set -euo pipefail

CONFIG=release
RUN=0
VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG=debug; shift ;;
    --run)   RUN=1; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

APP_NAME="4idesk"
# Unchanged on purpose. macOS ties the Local Network permission to the
# bundle identifier, and losing it means the app silently finds no
# cameras until someone re-grants it. The name on the window is not
# worth that.
BUNDLE_ID="co.orah.control"
OUT="$HERE/build"
APP="$OUT/$APP_NAME.app"

echo "building ($CONFIG)…"
swift build -c "$CONFIG" --product OrahControl 2>&1 \
  | grep -vE "could not determine XCTest|xcrun: error" || true

BINARY="$HERE/.build/$CONFIG/OrahControl"
[ -x "$BINARY" ] || { echo "build produced no binary"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# The icon. Without it the Dock shows a blank sheet of paper, which reads as
# "something failed to build" even when nothing did.
mkdir -p "$APP/Contents/Resources"
cp "$HERE/Resources/4idesk.icns" "$APP/Contents/Resources/" 2>/dev/null || true

# ── Info.plist ────────────────────────────────────────────────────────────────
#
# NSLocalNetworkUsageDescription and NSBonjourServices are not optional here:
# without them macOS silently returns nothing from Bonjour, and the app looks
# like it simply cannot find any cameras.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>           <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>             <string>4idesk</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.video</string>

    <key>NSLocalNetworkUsageDescription</key>
    <string>Orah Control finds cameras and recording nodes on this network, and controls them.</string>

    <key>NSBonjourServices</key>
    <array>
        <string>_vscamera._tcp</string>
        <string>_orahnode._tcp</string>
    </array>

    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Cameras and nodes are plain HTTP on the local network; there is no
             certificate to validate on a device with no name and no CA. -->
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
</dict>
</plist>
PLIST

# ── Icon ──────────────────────────────────────────────────────────────────────
if [ -f "$HERE/Resources/AppIcon.icns" ]; then
  cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
    "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

# An ad-hoc signature is enough to run locally and keeps macOS from complaining
# about a damaged bundle on every launch.
codesign --force --deep --sign - "$APP" 2>/dev/null \
  && echo "signed (ad-hoc)" \
  || echo "not signed — it will still run, Gatekeeper may ask once"

SIZE=$(du -sh "$APP" | cut -f1)
echo ""
echo "  $APP"
echo "  version $VERSION ($BUILD_NUMBER), $SIZE"
echo ""
echo "  ffmpeg and mediamtx must be on PATH for the switcher to run:"
command -v ffmpeg   >/dev/null && echo "    ffmpeg   $(command -v ffmpeg)"   || echo "    ffmpeg   MISSING"
command -v mediamtx >/dev/null && echo "    mediamtx $(command -v mediamtx)" || echo "    mediamtx MISSING"

if [ "$RUN" -eq 1 ]; then
  echo ""
  echo "launching…"
  open "$APP"
fi
