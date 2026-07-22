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
# Version comes from the git tag, never from project.yml. The values there are
# a fallback for someone opening the generated project in Xcode directly;
# command-line settings below take precedence over them. See scripts/version.sh
# for why a hardcoded CURRENT_PROJECT_VERSION silently breaks every update.
#
# Command substitution, not `read < <(...)`: process substitution runs in a
# subshell whose exit status `set -e` never sees, so a rejected tag would leave
# both variables empty and build anyway.
VERSION_LINE=$(scripts/version.sh)
read -r MARKETING_VERSION CURRENT_PROJECT_VERSION <<<"$VERSION_LINE"
echo -e "${GREEN}▸${NC} Version: $MARKETING_VERSION (build $CURRENT_PROJECT_VERSION)"
# Build into a ".noindex"-suffixed dir so Spotlight ignores the whole tree — this
# is the mechanism macOS honors reliably (it's how Xcode hides DerivedData). It
# keeps the build copy of the .app from showing up in Spotlight/Finder next to
# the real /Applications install. (The older ".metadata_never_index" marker file
# is flaky in subfolders on modern macOS/APFS — don't rely on it here.)
BUILD_DIR="build.noindex"

# Signing: automatic locally, explicit in CI.
#
# Automatic signing needs an Xcode account to resolve a profile, which a CI
# runner does not have — it only has a Developer ID cert imported into a
# temporary keychain. Setting SIGN_IDENTITY switches to manual signing with that
# identity. Left unset, nothing changes for local builds.
SIGN_ARGS=(CODE_SIGN_STYLE=Automatic)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_ARGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
        # Automatic signing supplies a profile; manual signing must be told
        # there isn't one, or xcodebuild goes looking for it and fails.
        PROVISIONING_PROFILE_SPECIFIER=""
    )
    echo -e "${GREEN}▸${NC} Signing identity: $SIGN_IDENTITY"
fi

xcodebuild -project Untracked.xcodeproj \
    -scheme Untracked \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    "${SIGN_ARGS[@]}" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
    -quiet

APP="$BUILD_DIR/Build/Products/Release/Untracked.app"

# Read the version back out of the bundle rather than trusting that the build
# settings landed. This is the whole point of task #9: the failure mode is a
# perfectly green build that ships the wrong CFBundleVersion, which nobody can
# see until an update silently fails to be offered. Verify at the only place
# that is authoritative — the plist Sparkle will actually read.
BUILT_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
if [[ "$BUILT_SHORT" != "$MARKETING_VERSION" || "$BUILT_BUILD" != "$CURRENT_PROJECT_VERSION" ]]; then
    echo -e "\033[0;31m✗ version did not reach the bundle\033[0m"
    echo "  expected: $MARKETING_VERSION ($CURRENT_PROJECT_VERSION)"
    echo "  in bundle: $BUILT_SHORT ($BUILT_BUILD)"
    exit 1
fi

# xcodebuild leaves Sparkle's nested helpers ad-hoc signed, which notarisation
# rejects. Must run after xcodebuild (the framework is copied in during the
# build) and before anything ships the bundle.
echo -e "${GREEN}▸${NC} Signing Sparkle helpers…"
scripts/sign-sparkle.sh "$APP"

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
