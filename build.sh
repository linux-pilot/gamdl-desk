#!/bin/zsh
# Builds "Gamdl Desk.app" (universal: Apple silicon + Intel) next to this script.
# Usage: ./build.sh          then drag the app to /Applications
#        ./build.sh --dmg    also packages "GamdlDesk-<version>.dmg" for a release
set -euo pipefail
cd "${0:A:h}"
APP="Gamdl Desk.app"
VERSION=1.3.0

BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}" --product GamdlDesk
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/GamdlDesk"

# App icon, regenerated only when the logo changes.
ICNS=.build/AppIcon.icns
if [[ ! -f $ICNS || Assets/logo.png -nt $ICNS || scripts/make-icon.swift -nt $ICNS ]]; then
  swift scripts/make-icon.swift Assets/logo.png "$ICNS"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GamdlDesk"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Gamdl Desk</string>
  <key>CFBundleDisplayName</key><string>Gamdl Desk</string>
  <key>CFBundleIdentifier</key><string>local.gamdl.desk</string>
  <key>CFBundleExecutable</key><string>GamdlDesk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if [[ ${1:-} == --dmg ]]; then
  DMG="GamdlDesk-$VERSION.dmg"
  STAGE=.build/dmg
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Gamdl Desk" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
  echo "Packaged $PWD/$DMG"
fi
