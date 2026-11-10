#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for px in 16 32 128 256 512; do
    swift scripts/make-icon.swift Resources/AppIcon.svg "$ICONSET/icon_${px}x${px}.png" $px
    swift scripts/make-icon.swift Resources/AppIcon.svg "$ICONSET/icon_${px}x${px}@2x.png" $((px * 2))
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
