#!/bin/zsh
# Builds "Gamdl Desk.app" next to this script. Usage: ./build.sh  (then drag it to /Applications)
set -euo pipefail
cd "${0:A:h}"
APP="Gamdl Desk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 GamdlDesk.swift -o "$APP/Contents/MacOS/GamdlDesk"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Gamdl Desk</string>
  <key>CFBundleDisplayName</key><string>Gamdl Desk</string>
  <key>CFBundleIdentifier</key><string>local.gamdl.desk</string>
  <key>CFBundleExecutable</key><string>GamdlDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
