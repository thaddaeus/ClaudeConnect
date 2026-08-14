#!/usr/bin/env bash
#
# Beta channel: build + sign "/Applications/ConsoleForge Beta.app" and relaunch it.
#
# This is the fast iteration loop. It exists so testing a change no longer costs a
# production interruption: it NEVER quits, pkills, or writes to
# /Applications/ConsoleForge.app, so Tadd's real sessions keep running while beta
# is rebuilt underneath them.
#
# NO NOTARIZATION. Gatekeeper only blocks bundles carrying the
# com.apple.quarantine xattr, which is set on download — a locally built app never
# has it. So beta is build + sign, seconds instead of the notarytool --wait minutes.
#
# SIGNING IS STILL REQUIRED, for a different reason: a stable Developer ID keeps
# the codesign designated requirement constant, so the Keychain treats each rebuild
# as the same app. Skip it and every relaunch looks like a brand-new untrusted app,
# which forces the login-PASSWORD prompt (Touch ID can't authorize a new identity
# against an existing item). Click "Always Allow" once and rebuilds stay quiet.
#
# Beta diverges from production in five places, all of them load-bearing:
#   * bundle id       com.thaddaeus.ConsoleForge.beta  (LaunchServices/Dock identity)
#   * app name        ConsoleForge Beta                (distinct Dock entry)
#   * support dir     ~/Library/Application Support/ConsoleForge Beta
#   * Keychain        com.thaddaeus.ConsoleForge.beta
#   * Sparkle         no feed, checks off — a beta that self-updated would replace
#                     itself with the shipping release mid-test
# The last three are decided in-app off the bundle id (see AppChannel.swift); this
# script only has to stamp the id and leave the Sparkle keys out.
#
# Usage:  ./scripts/beta.sh              # release build, relaunch beta
#         ./scripts/beta.sh debug        # faster debug build
#         ./scripts/beta.sh --no-launch  # build + install, don't open the app
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="release"
DO_LAUNCH=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release) CONFIG="$1"; shift ;;
        --no-launch) DO_LAUNCH=false; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

APP_NAME="ConsoleForge Beta"
BUNDLE_ID="com.thaddaeus.ConsoleForge.beta"
APP_BUNDLE="/Applications/$APP_NAME.app"
# The executable keeps the SPM product name; only the bundle is renamed. That also
# makes the process path a precise kill target that cannot match production's.
EXEC_NAME="ConsoleForge"
BETA_EXEC_PATH="$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
ENTITLEMENTS="$PROJECT_DIR/ConsoleForge.entitlements"
PROD_BUNDLE="/Applications/ConsoleForge.app"

# Hard stop rather than a comment: every destructive step below is aimed at
# $APP_BUNDLE, so if that path ever resolved to production this script would
# become the exact thing it was written to avoid.
if [ "$APP_BUNDLE" = "$PROD_BUNDLE" ]; then
    echo "ERROR: beta bundle path resolves to the production install. Refusing to continue." >&2
    exit 1
fi

# Resolve the Developer ID Application identity: prefer the env var the release
# script uses; otherwise discover it from the login keychain.
SIGN_IDENTITY="${DEV_ID_APPLICATION:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" \
        | head -1 \
        | sed -E 's/.*"(.*)"/\1/')
fi
if [ -z "$SIGN_IDENTITY" ]; then
    echo "ERROR: No Developer ID Application identity found. Set DEV_ID_APPLICATION or install the cert." >&2
    exit 1
fi

VERSION="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
VERSION="${VERSION#v}-beta"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
COMMIT_SHORT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"

echo "=== $APP_NAME $VERSION ($CONFIG, build $BUILD_NUMBER, commit $COMMIT_SHORT) ==="

# ── Build ──
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/$EXEC_NAME"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY" >&2
    exit 1
fi

# ── Quit ONLY the beta instance ──
# Identified by beta's full executable path, so production's
# ".../ConsoleForge.app/Contents/MacOS/ConsoleForge" can never match: grep -F
# means the paths are compared literally, and production's is not a substring of
# beta's. `ps` rather than `pgrep` because pgrep does not reliably see GUI app
# processes from every shell — and a false "not running" here would make the
# graceful quit be skipped.
beta_pids() {
    ps -Ao pid=,args= | grep -F "$BETA_EXEC_PATH" | grep -v grep | awk '{print $1}'
}

if [ -n "$(beta_pids)" ]; then
    echo "Quitting the running $APP_NAME (production is left alone)..."
    # Gated on actually running: `tell application id ... to quit` would LAUNCH a
    # stopped app just to quit it.
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        [ -z "$(beta_pids)" ] && break
        sleep 0.25
    done
    # Reap anything that ignored the quit, one pid at a time — `pkill -f` would
    # take a pattern, and this takes only pids already proven to be beta's.
    for pid in $(beta_pids); do
        kill -9 "$pid" 2>/dev/null || true
    done
fi

# ── Assemble the bundle ──
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
# Copy beside the target then rename over it: a running executable cannot be
# written in place (ETXTBSY), and rename works regardless, so a beta that somehow
# outlived the quit above costs a stale window rather than a failed build.
cp "$BINARY" "$BETA_EXEC_PATH.new"
mv -f "$BETA_EXEC_PATH.new" "$BETA_EXEC_PATH"
cp "$PROJECT_DIR/scripts/consoleforge-tab" "$APP_BUNDLE/Contents/Resources/consoleforge-tab"
cp "$PROJECT_DIR/scripts/consoleforge-chrome-mcp" "$APP_BUNDLE/Contents/Resources/consoleforge-chrome-mcp"
# Tinted icon so beta is tellable from production at a glance in the Dock; falls
# back to the production icon if the tinted one hasn't been generated.
if [ -f "$PROJECT_DIR/ConsoleForge/Assets/AppIconBeta.icns" ]; then
    cp "$PROJECT_DIR/ConsoleForge/Assets/AppIconBeta.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    cp "$PROJECT_DIR/ConsoleForge/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Sparkle.framework — the binary links @rpath/Sparkle.framework and Package.swift
# bakes in an @executable_path/../Frameworks rpath, so it must be present even
# though beta never checks for updates.
FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$FW" ]; then
    echo "Embedding Sparkle.framework..."
    SPARKLE_FW="$(find "$PROJECT_DIR/.build/artifacts" \
        -type d -path '*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' 2>/dev/null | head -1)"
    if [ -z "$SPARKLE_FW" ]; then
        echo "ERROR: Sparkle.framework not found in .build/artifacts. Run 'swift build' first." >&2
        exit 1
    fi
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    # -R preserves the framework's Versions/Current symlinks (required for a valid bundle).
    cp -R "$SPARKLE_FW" "$FW"
fi

# NOTE: no SUFeedURL and no SUPublicEDKey. Their absence is half of the
# self-update muzzle; the other half is AppChannel.isProduction gating
# SPUStandardUpdaterController's `startingUpdater:` so no check ever runs.
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$EXEC_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
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
    <key>NSLocalNetworkUsageDescription</key>
    <string>ConsoleForge runs your sessions and their browsers, which reach development servers on your local network or over a VPN. Without this, those addresses are treated as remote and fail.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>ConsoleForge listens for your wake phrase so you can talk to a session instead of typing. Audio is transcribed on this Mac and never leaves it.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>ConsoleForge transcribes your speech on-device to send it to the active session.</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>LSEnvironment</key>
    <dict>
        <key>OBJC_DISABLE_INITIALIZE_FORK_SAFETY</key>
        <string>YES</string>
    </dict>
    <!-- Required, not optional: SidebarView builds the sidebar's drag payload
         type with UTType(exportedAs:), which the app must declare. Sharing the
         identifier with production is harmless — it names a pasteboard payload,
         not a file type, so there is nothing for LaunchServices to arbitrate. -->
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

# NOTE: no CFBundleURLTypes. Production claims the "consoleforge" URL scheme; a
# second bundle claiming it too makes which app receives a given URL a coin flip,
# and production has to keep winning.

# ── Sign (inner to outer; never --deep, it corrupts the XPC signatures) ──
echo "Signing with: $SIGN_IDENTITY"
codesign --force --options runtime --preserve-metadata=entitlements \
    --sign "$SIGN_IDENTITY" "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --preserve-metadata=entitlements \
    --sign "$SIGN_IDENTITY" "$FW/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$FW/Versions/B/Autoupdate"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$FW/Versions/B/Updater.app"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$FW"
codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

# Register with Launch Services so the Dock, `open`, and `open -b` see the new
# bundle immediately instead of on the next login.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREGISTER" -f "$APP_BUNDLE" 2>/dev/null || true

echo "Installed + signed: $APP_BUNDLE"

if [ "$DO_LAUNCH" = true ]; then
    echo "Launching $APP_NAME..."
    # --dev-hotswap resumes every open tab by its own Claude session id, so a
    # rebuild continues each conversation instead of starting them over.
    open "$APP_BUNDLE" --args --dev-hotswap
fi
echo "Done."
