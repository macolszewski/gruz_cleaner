#!/bin/bash
# Regenerates the screenshots in docs/images from fictional demo data (DemoScan).
#
# Builds a debug app under its own bundle identifier, so its window state and settings never mix
# with a real installation, then launches each screenshot scenario in English (and the main
# window in Polish) and captures the window. The demo model never scans or removes anything.
# Needs Screen Recording permission for the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="docs/images"
BUNDLE_ID="io.github.macolszewski.GRUZ.screenshots"
CONFIGURATION=debug BUNDLE_ID="$BUNDLE_ID" ./scripts/build-app.sh >/dev/null
APP="build/debug/GRUZ.app"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; pkill -f "$APP/Contents/MacOS/GRUZ" 2>/dev/null || true' EXIT

# Prints "<window id> <width> <height>" for every normal window of the app, largest first.
cat > "$WORK/windows.swift" <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
// Height filter: menu bar extras are layer 0 windows too.
let windows = list.filter { ($0["kCGWindowOwnerPID"] as? Int) == pid && ($0["kCGWindowLayer"] as? Int) == 0
    && ($0["kCGWindowBounds"] as! [String: Double])["Height"]! > 100 }
for w in windows.sorted(by: { ($0["kCGWindowBounds"] as! [String: Double])["Width"]! > ($1["kCGWindowBounds"] as! [String: Double])["Width"]! }) {
    let b = w["kCGWindowBounds"] as! [String: Double]
    print(w["kCGWindowNumber"]!, Int(b["Width"]!), Int(b["Height"]!))
}
SWIFT
swiftc -o "$WORK/windows" "$WORK/windows.swift"

capture() { # scenario language output [window: main|smallest]
    local scenario="$1" language="$2" output="$3" which="${4:-main}"
    "$APP/Contents/MacOS/GRUZ" -GRUZScreenshot "$scenario" -AppleLanguages "($language)" 2>/dev/null &
    local pid=$!
    local id=""
    for _ in $(seq 1 50); do
        perl -e 'select(undef, undef, undef, 0.2)'
        if [ "$which" = main ]; then id="$("$WORK/windows" "$pid" | awk 'NR == 1 { print $1 }')"
        else id="$("$WORK/windows" "$pid" | awk '{ last = $1 } END { print last }')"; fi
        [ -n "$id" ] && [ "$("$WORK/windows" "$pid" | wc -l)" -ge "$([ "$which" = main ] && echo 1 || echo 2)" ] && break
    done
    perl -e 'select(undef, undef, undef, 1.5)' # let animations, sheets and window resizing settle
    if [ "$which" != main ]; then id="$("$WORK/windows" "$pid" | awk '{ last = $1 } END { print last }')"; fi
    screencapture -x -o -l "$id" "$WORK/shot.png"
    # Scale large windows down for the docs; never scale small ones up.
    if [ "$(sips -g pixelWidth "$WORK/shot.png" | awk '/pixelWidth/ { print $2 }')" -gt 1600 ]; then
        sips -Z 1600 "$WORK/shot.png" --out "$OUT/$output" >/dev/null
    else
        cp "$WORK/shot.png" "$OUT/$output"
    fi
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    echo "Wrote $OUT/$output"
}

capture main en main.png
capture review en review.png
capture projects en projects.png
capture growth en growth.png
capture settings en settings.png smallest
capture main pl main-pl.png
