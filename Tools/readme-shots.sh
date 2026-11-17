#!/bin/bash
# Regenerates the README images in docs/images from the offscreen snapshot harness.
# Needs a running, signed-in Windows Steam (the harness connects read-only) and Python 3 with Pillow.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs/images
SHOTS=$(mktemp -d)
trap 'rm -rf "$SHOTS"' EXIT

swift build --product VaporApp >/dev/null
.build/debug/VaporApp --snapshot "$SHOTS" >/dev/null
mkdir -p "$OUT"
sips -z 256 256 Resources/AppIcon-1024.png --out "$OUT/icon.png" >/dev/null

# source file in the snapshot set → README image
frame() { python3 Tools/frame_screenshot.py "$SHOTS/$1" "$OUT/$2" "${3:-}"; }
frame library.png hero.png
frame detail.png game.png small
frame store.png store.png small
frame community.png community.png small
frame downloads.png downloads.png small
frame onboarding.png onboarding.png small
frame runtimes.png runtimes.png small
ls -la "$OUT"
