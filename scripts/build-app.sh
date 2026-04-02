#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="FocusMouse"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64 2>&1

BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    echo "Trying single-arch build..."
    swift build -c release 2>&1
    BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
fi

echo "==> Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Copy entitlements (for reference, not embedded)
cp "$PROJECT_DIR/FocusMouse.entitlements" "$BUILD_DIR/"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Copy app icon
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
else
    echo "WARNING: AppIcon.icns not found. Run: swift scripts/generate-icon.swift . && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns"
fi

echo "==> Ad-hoc signing..."
codesign --force --sign - \
    --entitlements "$PROJECT_DIR/FocusMouse.entitlements" \
    --options runtime \
    "$APP_BUNDLE"

echo "==> App bundle created at: $APP_BUNDLE"

echo "==> Creating DMG..."

# Create a temporary directory for DMG contents
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"

# Copy app to staging
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

# Create Applications symlink for drag-to-install
ln -s /Applications "$DMG_STAGING/Applications"

# Create DMG
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Clean up staging
rm -rf "$DMG_STAGING"

echo ""
echo "==> Build complete!"
echo "    App:  $APP_BUNDLE"
echo "    DMG:  $DMG_PATH"
echo ""
echo "To install:"
echo "    open $DMG_PATH"
echo "    Drag FocusMouse to Applications"
echo ""
echo "Or install directly:"
echo "    cp -R $APP_BUNDLE /Applications/"
