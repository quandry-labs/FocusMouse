#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="FocusMouse"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
BUILD_MODE="${1:---local}"

if [ "$BUILD_MODE" != "--local" ] && [ "$BUILD_MODE" != "--release" ]; then
    echo "Usage: $0 [--local|--release]" >&2
    exit 64
fi

if [ ! -f "$PROJECT_DIR/Package.swift" ] || [ "$BUILD_DIR" != "$PROJECT_DIR/build" ]; then
    echo "ERROR: Refusing to build from an unexpected project path." >&2
    exit 1
fi

SIGN_IDENTITY="${FOCUSMOUSE_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${FOCUSMOUSE_NOTARY_PROFILE:-}"

if [ "$BUILD_MODE" = "--release" ]; then
    if [ -z "$SIGN_IDENTITY" ] || [ -z "$NOTARY_PROFILE" ]; then
        echo "ERROR: Release builds require FOCUSMOUSE_SIGN_IDENTITY and FOCUSMOUSE_NOTARY_PROFILE." >&2
        exit 1
    fi
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"
swift build -c release --arch arm64
BINARY_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BINARY="$BINARY_DIR/$APP_NAME"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: arm64 release binary was not produced." >&2
    exit 1
fi

ARCHITECTURES="$(lipo -archs "$BINARY")"
if [ "$ARCHITECTURES" != "arm64" ]; then
    echo "ERROR: Expected an arm64-only binary, found: $ARCHITECTURES" >&2
    exit 1
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

if [ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    echo "ERROR: Resources/AppIcon.icns is missing." >&2
    exit 1
fi
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/"

if [ "$BUILD_MODE" = "--release" ]; then
    codesign --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$PROJECT_DIR/FocusMouse.entitlements" \
        "$APP_BUNDLE"
else
    codesign --force \
        --sign - \
        --entitlements "$PROJECT_DIR/FocusMouse.entitlements" \
        "$APP_BUNDLE"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
trap 'rm -rf "$DMG_STAGING"' EXIT
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

diskutil image create from \
    --format UDZO \
    --volumeName "$APP_NAME" \
    "$DMG_STAGING" \
    "$DMG_PATH"

if [ "$BUILD_MODE" = "--release" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
else
    echo "Local ad-hoc build created. It is not suitable for distribution."
fi

echo "App: $APP_BUNDLE"
echo "DMG: $DMG_PATH"
