#!/usr/bin/env bash
#
# Dev hot-swap: build → quit running app → swap binary into the INSTALLED app
# at /Applications → RE-SIGN → relaunch.
#
# Targets the prod install in /Applications so the app you normally launch is
# the one you're testing (no separate build/ copy to get confused with).
#
# The re-sign step is mandatory. Copying a fresh binary into the bundle
# invalidates its signature, so to the Keychain every relaunch looks like a
# brand-new untrusted app — which forces the login-PASSWORD prompt (Touch ID /
# Apple Watch cannot authorize granting a new app identity access to an existing
# Keychain item). Re-signing with the stable Developer ID keeps a constant
# designated requirement: click "Always Allow" once and no future hot-swap
# prompts. (Re-signing locally strips the notarization staple from this install
# until the next ./scripts/build.sh install — that's expected for a dev build.)
#
# Usage:  ./scripts/dev.sh            # release config (default)
#         ./scripts/dev.sh debug      # faster debug build
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="${1:-release}"
APP_BUNDLE="/Applications/ConsoleForge.app"
ENTITLEMENTS="$PROJECT_DIR/ConsoleForge.entitlements"

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

if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: $APP_BUNDLE not found. Install once from ./scripts/build.sh's DMG first." >&2
    exit 1
fi
if [ ! -w "$APP_BUNDLE/Contents/MacOS" ]; then
    echo "ERROR: $APP_BUNDLE is not writable by $(whoami). Reinstall it to your user, or chown it." >&2
    exit 1
fi

echo "Building ($CONFIG)..."
swift build -c "$CONFIG"

# Quit every running ConsoleForge instance gracefully (covers a stray build/ copy
# from an older recipe, not just /Applications). The codesign step below takes a
# beat, which gives graceful termination time to finish before we relaunch.
echo "Quitting running instance(s)..."
osascript -e 'tell application "ConsoleForge" to quit' 2>/dev/null || true

echo "Swapping binary into $APP_BUNDLE..."
cp ".build/$CONFIG/ConsoleForge" "$APP_BUNDLE/Contents/MacOS/ConsoleForge"

# The binary now links @rpath/Sparkle.framework (resolved via the
# @executable_path/../Frameworks rpath baked in by Package.swift). A bundle
# installed before Sparkle was added lacks the framework, so the hot-swapped
# binary would crash on launch. Embed + sign it if it's missing (a full
# ./scripts/build.sh install keeps it current thereafter).
FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$FW" ]; then
    echo "Embedding Sparkle.framework (missing from installed bundle)..."
    SPARKLE_FW="$(find "$PROJECT_DIR/.build/artifacts" \
        -type d -path '*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' 2>/dev/null | head -1)"
    if [ -z "$SPARKLE_FW" ]; then
        echo "ERROR: Sparkle.framework not found in .build/artifacts." >&2
        exit 1
    fi
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_FW" "$FW"
    for comp in \
        "XPCServices/Downloader.xpc" "XPCServices/Installer.xpc" \
        "Autoupdate" "Updater.app" "."; do
        codesign --force --options runtime --preserve-metadata=entitlements \
            --sign "$SIGN_IDENTITY" "$FW/Versions/B/$comp"
    done
fi

echo "Re-signing with: $SIGN_IDENTITY"
codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"

# Reap any instance that didn't take the graceful quit, so `open` launches the
# new binary instead of re-activating a lingering old process.
pkill -f "ConsoleForge.app/Contents/MacOS/ConsoleForge" 2>/dev/null || true

echo "Relaunching..."
# --dev-hotswap tells the app this is a dev relaunch: resume EVERY open tab by
# its own Claude session id (--resume <id>) so each tab's conversation carries
# across the swap without tabs sharing a directory interleaving. A normal
# Finder/Dock launch never carries this arg, so prod restore is unchanged.
open "$APP_BUNDLE" --args --dev-hotswap
echo "Done."
