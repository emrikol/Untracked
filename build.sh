#!/usr/bin/env bash
# Build (and optionally install) Untracked.
#   ./build.sh            -> build Release into ./build.noindex
#   ./build.sh --install  -> build, copy to /Applications, launch
set -euo pipefail
cd "$(dirname "$0")"

GREEN='\033[0;32m'; NC='\033[0m'

# Fail fast, before spending time on icon generation and xcodebuild.
echo -e "${GREEN}▸${NC} Checking invariants…"
scripts/check-invariants.sh

echo -e "${GREEN}▸${NC} Generating app icon…"
scripts/generate-icon.sh

echo -e "${GREEN}▸${NC} Generating Xcode project (xcodegen)…"
xcodegen generate

echo -e "${GREEN}▸${NC} Building Release…"
# Build into a ".noindex"-suffixed dir so Spotlight ignores the whole tree — this
# is the mechanism macOS honors reliably (it's how Xcode hides DerivedData). It
# keeps the build copy of the .app from showing up in Spotlight/Finder next to
# the real /Applications install. (The older ".metadata_never_index" marker file
# is flaky in subfolders on modern macOS/APFS — don't rely on it here.)
BUILD_DIR="build.noindex"
xcodebuild -project Untracked.xcodeproj \
    -scheme Untracked \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Automatic \
    -quiet

APP="$BUILD_DIR/Build/Products/Release/Untracked.app"
echo -e "${GREEN}▸${NC} Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo -e "${GREEN}▸${NC} Installing to /Applications…"
    DEST_APP="/Applications/Untracked.app"
    STAGED_APP="/Applications/.Untracked.app.staged.$$"
    rm -rf "$STAGED_APP"
    trap 'rm -rf "$STAGED_APP"' EXIT

    # Complete the fallible cross-filesystem copy before retiring the working app.
    # The final move stays within /Applications and is therefore a rename.
    cp -R "$APP" "$STAGED_APP"
    osascript -e 'tell application "Untracked" to quit' 2>/dev/null || true
    rm -rf "$DEST_APP"
    mv "$STAGED_APP" "$DEST_APP"
    trap - EXIT
    echo -e "${GREEN}▸${NC} Launching…"
    open "$DEST_APP"
    echo -e "${GREEN}✓${NC} Running in the menu bar. Click the icon → Launch at Login to keep it running."
fi
