#!/bin/bash
set -euo pipefail

# ConsoleForge release script
# Builds, signs, notarizes, and optionally publishes a DMG to GitHub Releases.
#
# Usage:
#   ./scripts/build.sh <version>                  # build + sign + notarize
#   ./scripts/build.sh <version> --release         # also create GitHub release
#   ./scripts/build.sh <version> --release --notes "description"
#
# Example:
#   ./scripts/build.sh 0.5.0 --release --notes "Fix tab close crash"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="ConsoleForge"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ENTITLEMENTS="$PROJECT_DIR/ConsoleForge.entitlements"

# Signing & notarization credentials — set these env vars or export them in your shell profile
SIGN_IDENTITY="${DEV_ID_APPLICATION:?Set DEV_ID_APPLICATION env var (e.g. 'Developer ID Application: Your Name (TEAMID)')}"
NOTARY_PROFILE="${NOTARY_PROFILE_NAME:-ConsoleForge Notary}"

# Parse arguments
VERSION="${1:?Usage: build.sh <version> [--release] [--notes \"...\"]}"
shift
DO_RELEASE=false
RELEASE_NOTES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) DO_RELEASE=true; shift ;;
        --notes) RELEASE_NOTES="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DMG_PATH="$BUILD_DIR/$APP_NAME-v$VERSION.dmg"
COMMIT_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
COMMIT_SHORT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"

# ── Preflight: a release must describe code that actually exists on origin ──
# Historically the tag was created against the remote default-branch HEAD (no
# --target), so unpushed local commits shipped in the DMG while every tag
# pointed at a stale commit. Fail fast instead of repeating that drift.
if [ "$DO_RELEASE" = true ]; then
    # Only tracked modifications affect what compiles into the DMG; ignore
    # untracked scratch files (e.g. icon-concepts/) so they don't block a release.
    if [ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)" ]; then
        echo "ERROR: Tracked files have uncommitted changes. Commit or stash before releasing,"
        echo "       otherwise the published tag won't match what's in the DMG."
        exit 1
    fi
    git -C "$PROJECT_DIR" fetch origin --quiet
    if ! git -C "$PROJECT_DIR" merge-base --is-ancestor "$COMMIT_SHA" origin/main; then
        echo "ERROR: HEAD ($COMMIT_SHORT) is not on origin/main."
        echo "       Push before releasing so the tag points to a real remote commit:"
        echo "         git push origin main"
        exit 1
    fi
fi

echo "=== Building $APP_NAME v$VERSION (build $BUILD_NUMBER, commit $COMMIT_SHORT) ==="
echo ""

# ── Step 1: Build release binary ──
cd "$PROJECT_DIR"
swift build -c release 2>&1

BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    exit 1
fi
echo "Binary: $BINARY"

# ── Step 2: Create .app bundle ──
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/consoleforge-tab" "$APP_BUNDLE/Contents/Resources/consoleforge-tab"
cp "$PROJECT_DIR/ConsoleForge/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.thaddaeus.ConsoleForge.auth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>consoleforge</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.thaddaeus.consoleforge.session</string>
            <key>UTTypeDescription</key>
            <string>ConsoleForge Session</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict/>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ── Step 3: Code sign (hardened runtime + timestamp + entitlements) ──
echo ""
echo "Signing with Developer ID..."
codesign --deep --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"

# Verify
codesign --verify --deep --strict "$APP_BUNDLE"
echo "Signature verified."

# Confirm hardened runtime + timestamp
SIGN_INFO=$(codesign -dvv "$APP_BUNDLE" 2>&1)
if ! echo "$SIGN_INFO" | grep -q "flags=.*runtime"; then
    echo "ERROR: Hardened runtime flag not set. Notarization will fail."
    exit 1
fi
if ! echo "$SIGN_INFO" | grep -q "Timestamp="; then
    echo "ERROR: Secure timestamp not set. Notarization will fail."
    exit 1
fi
echo "Hardened runtime + timestamp confirmed."

# ── Step 4: Create DMG ──
echo ""
echo "Creating DMG..."
DMG_TEMP="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_TEMP" "$DMG_PATH"
mkdir -p "$DMG_TEMP"

cp -R "$APP_BUNDLE" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

hdiutil create -volname "$APP_NAME v$VERSION" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null 2>&1

# Unregister the staged app from Launch Services so the about-to-be-deleted path doesn't
# shadow /Applications/ConsoleForge.app and make the app invisible to Shortcuts.app et al.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREGISTER" -u "$DMG_TEMP/$APP_NAME.app" 2>/dev/null || true
rm -rf "$DMG_TEMP"

codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
echo "DMG created and signed."

# ── Step 5: Notarize ──
echo ""
echo "Submitting for notarization..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1

echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "=== Build complete ==="
echo "   DMG: $DMG_PATH"
echo "   Version: $VERSION (build $BUILD_NUMBER)"
echo "   Signed, notarized, stapled."

# ── Step 6: GitHub Release (if --release) ──
if [ "$DO_RELEASE" = true ]; then
    echo ""
    echo "Creating GitHub release v$VERSION..."

    if [ -z "$RELEASE_NOTES" ]; then
        RELEASE_NOTES="ConsoleForge v$VERSION"
    fi
    RELEASE_NOTES="$RELEASE_NOTES"$'\n\n'"Built from commit $COMMIT_SHORT"

    # --target pins the tag to the exact commit that was built, instead of
    # whatever the remote default branch happens to point at.
    gh release create "v$VERSION" "$DMG_PATH" \
        --target "$COMMIT_SHA" \
        --title "$APP_NAME v$VERSION" \
        --notes "$RELEASE_NOTES"

    echo "GitHub release published."
fi
