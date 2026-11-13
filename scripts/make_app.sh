#!/bin/sh
# Builds dist/ReelPrep.app (release, ad-hoc signed) from the ReelPrepApp target, plus the reelprep CLI inside it.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product ReelPrepApp
swift build -c release --product reelprep
APP=dist/ReelPrep.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/ReelPrepApp "$APP/Contents/MacOS/ReelPrep"
[ -f assets/AppIcon.icns ] || scripts/make_icon.sh
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/reelprep "$APP/Contents/Helpers/reelprep"  # not in MacOS: "reelprep" and "ReelPrep" are one name on APFS
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ReelPrep</string>
  <key>CFBundleDisplayName</key><string>ReelPrep</string>
  <key>CFBundleIdentifier</key><string>com.reelprep.ReelPrep</string>
  <key>CFBundleExecutable</key><string>ReelPrep</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --deep "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
