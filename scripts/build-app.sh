#!/bin/bash
# Builds build/GRUZ.app from the SwiftPM package.
#
# Environment:
#   CONFIGURATION  release (default, build/GRUZ.app) or debug (build/debug/GRUZ.app, enables screenshot scenarios)
#   VERSION        version written to Info.plist (default: 1.1.0)
#   BUNDLE_ID      bundle identifier (default: io.github.macolszewski.GRUZ)
#   SIGN_IDENTITY  code signing identity, name or SHA-1 (default: first "Apple Development" identity, else ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.1.0}"
BUNDLE_ID="${BUNDLE_ID:-io.github.macolszewski.GRUZ}"
CONFIGURATION="${CONFIGURATION:-release}"
if [ "$CONFIGURATION" = release ]; then APP="build/GRUZ.app"; else APP="build/$CONFIGURATION/GRUZ.app"; fi

swift build -c "$CONFIGURATION" --product GRUZ
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GRUZ" "$APP/Contents/MacOS/GRUZ"
# Library resources (rule catalog, translations, helpers). Bundle.scannerKit and Bundle.cleanerKit look here.
cp -R "$BIN/GRUZ_ScannerKit.bundle" "$BIN/GRUZ_CleanerKit.bundle" "$APP/Contents/Resources/"
# The app's own translations go into the main bundle, where SwiftUI looks up string literals.
cp -R Sources/GRUZ/Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>GRUZ</string>
    <key>CFBundleDisplayName</key><string>GRUZ</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>GRUZ</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>pl</string>
    </array>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# A stable certificate keeps the Full Disk Access grant across rebuilds; ad-hoc signatures change every build.
# The identity is picked by its SHA-1 hash: names are ambiguous when a certificate was installed twice.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - --timestamp=none "$APP"
    echo "Signed ad-hoc (Full Disk Access must be granted again after each rebuild)"
fi
echo "Built $APP"
