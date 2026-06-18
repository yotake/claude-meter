#!/bin/zsh
# Build ClaudeMeter.app (menu bar widget) using only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=ClaudeMeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/ClaudeMeter "$APP/Contents/MacOS/ClaudeMeter"

cp Packaging/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign the bundle. Credentials are entered in-app and stored under
# ~/Library/Application Support/ClaudeMeter/ (no Keychain access).
codesign --force --sign - "$APP"

echo "Built $APP — launch with: open $APP"
