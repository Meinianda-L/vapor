#!/bin/bash
# Regenerates the README images: docs/images (English UI) and docs/images/zh-CN (Chinese UI).
# Renders through the app bundle's snapshot harness, so run ./bundle.sh first. Needs a running, signed-in
# Windows Steam (the harness connects to it read-only) and Python 3 with Pillow.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Vapor.app/Contents/MacOS/Vapor
[ -x "$APP" ] || { echo "build/Vapor.app is missing; run ./bundle.sh first" >&2; exit 1; }

shoot() {   # <language> <output dir>
    local shots
    shots=$(mktemp -d)
    "$APP" --snapshot "$shots" -AppleLanguages "($1)" >/dev/null
    mkdir -p "$2"
    frame() { python3 Tools/frame_screenshot.py "$shots/$1" "$2/$3" "${4:-}"; }
    frame library.png "$2" hero.png
    frame detail.png "$2" game.png small
    frame store.png "$2" store.png small
    frame community.png "$2" community.png small
    frame downloads.png "$2" downloads.png small
    frame onboarding.png "$2" onboarding.png small
    frame runtimes.png "$2" runtimes.png small
    rm -rf "$shots"
}

shoot en docs/images
shoot zh-Hans docs/images/zh-CN
sips -z 256 256 Resources/AppIcon-1024.png --out docs/images/icon.png >/dev/null
ls -la docs/images docs/images/zh-CN
