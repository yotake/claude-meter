#!/bin/zsh
# Build a universal ClaudeMeter.app and package it for free redistribution.
#
# Two modes, chosen by whether signing credentials are present in the env:
#
#   1. DEVELOPER ID + NOTARIZATION (recommended for public release)
#      Removes the Gatekeeper "unidentified developer" warning. Requires an
#      active Apple Developer Program membership. Set:
#        SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#      and ONE of:
#        NOTARY_PROFILE="claude-meter"          # a notarytool keychain profile
#      or:
#        APPLE_ID="you@example.com" TEAM_ID="TEAMID" APP_PW="app-specific-pw"
#
#      Create the keychain profile once (stores the app-specific password in the
#      login keychain, NOT in this repo):
#        xcrun notarytool store-credentials claude-meter \
#          --apple-id you@example.com --team-id TEAMID --password app-specific-pw
#
#   2. AD-HOC (default, no membership) — local testing / sideloading only.
#      Produces a working app but users get a Gatekeeper warning on first open.
#
# NO secret is ever written to disk by this script: credentials are read from
# the environment / login keychain at run time only.
#
# Requires Command Line Tools only (no Xcode app needed).
# Usage: ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Packaging/Info.plist)
APP=ClaudeMeter.app

# --- Build universal binary -------------------------------------------------
swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create \
    .build/arm64-apple-macosx/release/ClaudeMeter \
    .build/x86_64-apple-macosx/release/ClaudeMeter \
    -output "$APP/Contents/MacOS/ClaudeMeter"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# --- Sign -------------------------------------------------------------------
if [[ -n "${SIGN_ID:-}" ]]; then
    echo "Signing with Developer ID + hardened runtime: $SIGN_ID"
    # Hardened runtime (--options runtime) + secure timestamp are required for
    # notarization. The app is non-sandboxed (it reads ~/.codex and its own
    # Application Support dir), so no extra entitlements are needed.
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" "$APP"
else
    echo "No SIGN_ID set — ad-hoc signing (Gatekeeper will warn users)."
    codesign --force --sign - "$APP"
fi

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/ClaudeMeter")"

# --- Package as a DMG -------------------------------------------------------
mkdir -p dist
DMG="dist/ClaudeMeter-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "ClaudeMeter" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
echo "Packaged: $DMG"

# --- Notarize + staple ------------------------------------------------------
notarize() {
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PW:-}" ]]; then
        xcrun notarytool submit "$DMG" \
            --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" --wait
    else
        return 1
    fi
}

if [[ -n "${SIGN_ID:-}" ]] && notarize; then
    xcrun stapler staple "$DMG"
    echo "Notarized + stapled: $DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" || true
else
    echo "Skipped notarization (no notary credentials, or ad-hoc build)."
    echo "  -> Distribute only for local testing; public users will see a warning."
fi

echo "Done. Release artifact: $DMG"
