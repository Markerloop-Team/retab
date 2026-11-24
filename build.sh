#!/bin/zsh
# Builds Retab.app next to this script. Needs only the Xcode Command Line Tools (clang).
set -euo pipefail
cd "$(dirname "$0")"
APP=Retab.app
VERSION="$(cat VERSION)"   # the one place the version lives
rm -rf "$APP"   # start clean, so nothing from an older build rides along
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=14.0 \
  -F/System/Library/PrivateFrameworks \
  -framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement -framework QuartzCore -framework SkyLight \
  Sources/main.m -o "$APP/Contents/MacOS/Retab"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Retab</string>
  <key>CFBundleIdentifier</key><string>app.retab.mac</string>
  <key>CFBundleExecutable</key><string>Retab</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
# Signed with the local "Retab Dev" certificate when this Mac has one (tools/make_cert.sh makes it):
# macOS then sees every rebuild as the same app, and its permissions stay. Without the certificate
# the signature is ad-hoc — enough to run, but permissions have to be granted again after each build.
KEYCHAIN="$HOME/Library/Keychains/retab-dev.keychain-db"
if [[ -f "$KEYCHAIN" ]]; then
  security unlock-keychain -p retab-dev "$KEYCHAIN"   # it is locked again after a restart
  codesign --force --sign "Retab Dev" --keychain "$KEYCHAIN" --identifier app.retab.mac "$APP"
  codesign --verify "$APP"
else
  codesign --force --sign - --identifier app.retab.mac "$APP"
fi
echo "Built $PWD/$APP"
