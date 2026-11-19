#!/bin/zsh
# Builds "Gamdl Desk.app" next to this script. Usage: ./build.sh  (then drag it to /Applications)
set -euo pipefail
cd "${0:A:h}"
APP="Gamdl Desk.app"

swift build -c release --product GamdlDesk
BIN="$(swift build -c release --show-bin-path)/GamdlDesk"

# App icon, regenerated only when the logo changes.
ICNS=.build/AppIcon.icns
if [[ ! -f $ICNS || Assets/logo.png -nt $ICNS || scripts/make-icon.swift -nt $ICNS ]]; then
  swift scripts/make-icon.swift Assets/logo.png "$ICNS"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GamdlDesk"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Gamdl Desk</string>
  <key>CFBundleDisplayName</key><string>Gamdl Desk</string>
  <key>CFBundleIdentifier</key><string>local.gamdl.desk</string>
  <key>CFBundleExecutable</key><string>GamdlDesk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
