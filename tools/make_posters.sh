#!/bin/zsh
# Draws the posters in docs/press from tools/poster.m: the panel as Retab draws it, made-up data.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
clang -fobjc-arc -Wno-unused-function -F/System/Library/PrivateFrameworks \
  -framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement \
  -framework QuartzCore -framework CoreImage -framework SkyLight tools/poster.m -o "$WORK/poster"
mkdir -p docs/press
"$WORK/poster" docs/press
echo "Wrote docs/press"
