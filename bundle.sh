#!/bin/bash
# Builds Vapor.app (release) with the SVG-derived icon and an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product VaporApp
BIN=$(swift build -c release --show-bin-path)
APP=build/Vapor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VaporApp" "$APP/Contents/MacOS/Vapor"
cp -R "$BIN/Vapor_VaporApp.bundle" "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
<<<<<<< repo
# UI strings: Chinese is the source language, English comes from the catalog (see Tools/l10n.sh).
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources" >/dev/null
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
# x86_64 for Wine under Rosetta, arm64 for completeness; no frameworks linked (see Shim/steamhide.m).
clang -arch x86_64 -arch arm64 -dynamiclib -O2 -lobjc -o "$APP/Contents/Resources/libvapor-steamhide.dylib" Shim/steamhide.m
=======
# libvapor-steamhide.dylib and vapor-winwatch.exe, which run alongside Windows Steam.
Shim/build.sh "$APP/Contents/Resources"
>>>>>>> agent
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>CFBundleName</key><string>Vapor</string>
  <key>CFBundleDisplayName</key><string>Vapor</string>
  <key>CFBundleIdentifier</key><string>app.vapor.launcher</string>
  <key>CFBundleExecutable</key><string>Vapor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null
echo "built $APP"
