#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexAccountSwitcher"
APP_BUNDLE="$ROOT_DIR/dist/${APP_NAME}.app"
ASSETS_DIR="$ROOT_DIR/dist/assets"
INFO_PLIST_TEMPLATE="$ROOT_DIR/Packaging/Info.plist"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
APP_VERSION="${APP_VERSION:-1.0.2}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-3}"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.XXXXXX")"
ICON_EXPORT_DIR="$TEMP_DIR/exported-icons"
ICONSET_DIR="$TEMP_DIR/AppIcon.iconset"
ICON_FILE="$TEMP_DIR/AppIcon.icns"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

resize_icon() {
    local input_file="$1"
    local output_file="$2"
    local edge_size="$3"

    sips -z "$edge_size" "$edge_size" "$input_file" --out "$output_file" >/dev/null
}

cd "$ROOT_DIR"

swift build -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
APP_BINARY="$BIN_DIR/$APP_NAME"

"$APP_BINARY" --export-icons "$ICON_EXPORT_DIR"

mkdir -p "$ICONSET_DIR"
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_16x16.png" 16
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_16x16@2x.png" 32
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_32x32.png" 32
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_32x32@2x.png" 64
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_128x128.png" 128
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_128x128@2x.png" 256
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_256x256.png" 256
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_256x256@2x.png" 512
resize_icon "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_512x512.png" 512
cp "$ICON_EXPORT_DIR/AppIcon-master.png" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

rm -rf "$APP_BUNDLE" "$ASSETS_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$ASSETS_DIR"

cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST_TEMPLATE" "$APP_BUNDLE/Contents/Info.plist"
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$APP_BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"

cp "$ICON_EXPORT_DIR/AppIcon-master.png" "$ASSETS_DIR/AppIcon-master.png"
cp "$ICON_EXPORT_DIR/MenuBarIcon-template.png" "$ASSETS_DIR/MenuBarIcon-template.png"
cp "$ICON_FILE" "$ASSETS_DIR/AppIcon.icns"

codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE" >/dev/null

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ROOT_DIR/dist/${APP_NAME}.zip"

echo "已生成:"
echo "$APP_BUNDLE"
echo "$ROOT_DIR/dist/${APP_NAME}.zip"
echo "$ASSETS_DIR/AppIcon.icns"
