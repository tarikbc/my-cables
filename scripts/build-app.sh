#!/bin/sh
# Build "build/Cable Lab.app" from this repo and sign it.
#
# The app remembers this repo folder (Info.plist key MyCablesRepo), so it saves results here.
# It signs with your first "Developer ID Application" identity, else your first "Apple Development"
# identity, else ad-hoc. A stable signature keeps a Full Disk Access grant valid across rebuilds.
# Override with CODESIGN_IDENTITY=<hash or name>, or CODESIGN_IDENTITY=- for an ad-hoc signature.
set -eu

cd "$(dirname "$0")/.."
REPO="$(pwd)"
APP="$REPO/build/Cable Lab.app"

swift build -c release --product CableLab
BIN="$(swift build -c release --show-bin-path)/CableLab"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CableLab"

# SwiftPM records the deployment target (14.0) as the SDK version too. AppKit reads that field to pick
# the design, so an "SDK 14" app gets the old flat look and its layout quirks. Record the real SDK.
SDK_VERSION="$(xcrun --show-sdk-version)"
xcrun vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
    -output "$APP/Contents/MacOS/CableLab" "$APP/Contents/MacOS/CableLab"

PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>CableLab</string>
  <key>CFBundleIdentifier</key><string>com.tarikbc.cablelab</string>
  <key>CFBundleName</key><string>Cable Lab</string>
  <key>CFBundleDisplayName</key><string>Cable Lab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>Cable Lab writes and reads one test file on the disk to measure the cable speed.</string>
</dict>
</plist>
EOF
plutil -insert MyCablesRepo -string "$REPO" "$PLIST"

pick() { security find-identity -v -p codesigning | awk -v kind="\"$1" 'index($0, kind) { print $2; exit }'; }
IDENTITY="${CODESIGN_IDENTITY:-$(pick "Developer ID Application")}"
IDENTITY="${IDENTITY:-$(pick "Apple Development")}"
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
