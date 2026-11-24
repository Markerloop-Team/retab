#!/bin/zsh
# Regenerates Resources/AppIcon.icns, docs/icon.png and docs/favicon.png from tools/icon.svg.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/AppIcon.iconset" Resources docs
clang -fobjc-arc -framework Cocoa tools/make_icon.m -o "$WORK/make_icon"
"$WORK/make_icon" tools/icon.svg "$WORK/AppIcon.iconset" docs
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns, docs/icon.png, docs/favicon.png"
