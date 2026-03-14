#!/bin/bash
set -euo pipefail

# ClaudeConnect build script
# Creates a proper .app bundle from the SPM project

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="ClaudeConnect"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

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
cp "$SCRIPT_DIR/claude-connect-tab" "$APP_BUNDLE/Contents/Resources/claude-connect-tab"

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
    <string>com.thaddaeus.ClaudeConnect</string>
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
</dict>
</plist>
PLIST

# Ad-hoc code sign (required for modern macOS)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "Warning: Code signing failed (app will still work locally)"

echo ""
echo "✅ Built: $APP_BUNDLE"
echo "   Version: $VERSION (build $BUILD_NUMBER)"
echo ""
echo "To install:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
echo ""
echo "To install CLI tool:"
echo "  mkdir -p ~/.local/bin"
echo "  cp \"$APP_BUNDLE/Contents/Resources/claude-connect-tab\" ~/.local/bin/"
echo "  chmod +x ~/.local/bin/claude-connect-tab"
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

echo "📦 Distribution DMG: $DMG_PATH"
echo "   Upload this to GitHub Releases"
