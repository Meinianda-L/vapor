#!/bin/bash
# Builds VaporBoost.dylib (universal) and the headless test harness.
set -euo pipefail
cd "$(dirname "$0")"
FW=(-framework Foundation -framework Metal -framework MetalFX -framework QuartzCore)
clang -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc -O2 -Wall "${FW[@]}" -o VaporBoost.dylib VaporBoost.m
swiftc -O test/harness.swift -o test/harness
swiftc -O -target x86_64-apple-macos14 test/harness.swift -o test/harness_x86
swiftc -O test/offscreen_check.swift -o test/offscreen_check
lipo -info VaporBoost.dylib
