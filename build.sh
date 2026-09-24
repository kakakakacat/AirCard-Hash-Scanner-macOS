#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="AirCard Wallet Tool"
APP_DIR="build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BIN_DIR="${RESOURCES_DIR}/bin"
ICON_MASTER="Assets/AirCardWalletToolIcon.png"
ICONSET_DIR="build/AirCardWalletTool.iconset"

echo "==> [1/5] Building USB and AirTraffic helpers"
make clean
make all

echo "==> [2/5] Creating app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$BIN_DIR"

cat > "${CONTENTS_DIR}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>AirCardWalletTool</string>
    <key>CFBundleIdentifier</key><string>com.kakakakacat.aircard-wallet-tool</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>AirCard Wallet Tool</string>
    <key>CFBundleDisplayName</key><string>AirCard Wallet Tool</string>
    <key>CFBundleIconFile</key><string>AirCardWalletTool</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

cp build/device_helper build/airtraffic_host "$BIN_DIR/"
cp wallet_scanner.py apply_card_skin.py card_assets.py "$RESOURCES_DIR/"

if [[ ! -f "$ICON_MASTER" ]]; then
    echo "Missing icon master: $ICON_MASTER" >&2
    exit 1
fi
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$ICON_MASTER" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$ICON_MASTER" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AirCardWalletTool.icns"

echo "==> [3/5] Compiling universal SwiftUI application"
SWIFT_SDK="${SWIFT_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -sdk "$SWIFT_SDK" -O -parse-as-library -target arm64-apple-macosx14.0 \
    AirCardApp.swift -o build/AirCardWalletTool-arm64
swiftc -sdk "$SWIFT_SDK" -O -parse-as-library -target x86_64-apple-macosx14.0 \
    AirCardApp.swift -o build/AirCardWalletTool-x86_64
lipo -create -output "${MACOS_DIR}/AirCardWalletTool" \
    build/AirCardWalletTool-arm64 build/AirCardWalletTool-x86_64

echo "==> [4/5] Signing app bundle"
chmod -R 755 "$APP_DIR"
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"

echo "==> [5/5] Creating DMG"
DMG_ROOT="$(mktemp -d /tmp/aircard-hash-scanner.XXXXXX)"
trap 'rm -rf "$DMG_ROOT"' EXIT
cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
cp "$RESOURCES_DIR/AirCardWalletTool.icns" "$DMG_ROOT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$DMG_ROOT"
fi
rm -f build/AirCard-Wallet-Tool.dmg
hdiutil create -volname "AirCard Wallet Tool" -srcfolder "$DMG_ROOT" \
    -ov -format UDZO build/AirCard-Wallet-Tool.dmg

echo "Built build/AirCard-Wallet-Tool.dmg"
