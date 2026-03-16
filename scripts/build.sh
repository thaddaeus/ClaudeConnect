#!/bin/bash
set -euo pipefail

# ConsoleForge build script
# Creates a signed, notarized .app bundle and DMG from the SPM project

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="ConsoleForge"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

SIGN_IDENTITY="${DEV_ID_APPLICATION:?Set DEV_ID_APPLICATION env var (e.g. 'Developer ID Application: Your Name (TEAMID)')}"
NOTARY_PROFILE="${NOTARY_PROFILE_NAME:?Set NOTARY_PROFILE_NAME env var (e.g. 'MyApp-Notary')}"
ENTITLEMENTS="$PROJECT_DIR/ConsoleForge.entitlements"

echo "Building $APP_NAME v$VERSION (build $BUILD_NUMBER)..."

# Build release binary
cd "$PROJECT_DIR"
swift build -c release 2>&1

BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    exit 1
fi

echo "Binary built: $BINARY"

# Create .app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy CLI tool into Resources for easy installation
cp "$SCRIPT_DIR/consoleforge-tab" "$APP_BUNDLE/Contents/Resources/consoleforge-tab"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.thaddaeus.ConsoleForge</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>LSEnvironment</key>
    <dict>
        <key>OBJC_DISABLE_INITIALIZE_FORK_SAFETY</key>
        <string>YES</string>
    </dict>
</dict>
</plist>
PLIST

# Code sign with Developer ID
echo ""
echo "Signing with Developer ID..."
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
echo "Signed."

# Verify signature
codesign --verify --deep --strict "$APP_BUNDLE"
echo "Signature verified."

echo ""
echo "Built: $APP_BUNDLE"
echo "   Version: $VERSION (build $BUILD_NUMBER)"
echo ""
echo "To install:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
echo ""
echo "To install CLI tool:"
echo "  mkdir -p ~/.local/bin"
echo "  cp \"$APP_BUNDLE/Contents/Resources/consoleforge-tab\" ~/.local/bin/"
echo "  chmod +x ~/.local/bin/consoleforge-tab"
echo ""

# Create DMG for distribution
DMG_PATH="$BUILD_DIR/$APP_NAME-v$VERSION.dmg"
DMG_TEMP="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_TEMP" "$DMG_PATH"
mkdir -p "$DMG_TEMP"

# Stage app and Applications symlink for drag-to-install
cp -R "$APP_BUNDLE" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

# Create DMG
hdiutil create -volname "$APP_NAME v$VERSION" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null 2>&1

rm -rf "$DMG_TEMP"

# Sign the DMG
codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
echo "DMG signed."

# Notarize
echo ""
echo "Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1

# Staple the notarization ticket
echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Distribution DMG: $DMG_PATH"
echo "   Signed, notarized, and ready for distribution."
echo "   Upload this to GitHub Releases."
