#!/usr/bin/env bash
# Re-sign Sparkle's nested helpers, then the app that contains them.
#
# Sparkle ships its XPC services, Autoupdate and Updater.app **ad-hoc signed**
# (`Authority=(none/adhoc)`), verified by inspection of a real build. Xcode's
# Organizer re-signs them for you during Archive → Distribute; `xcodebuild` does
# NOT. Notarisation rejects ad-hoc-signed nested code, so without this a release
# fails late, at the notary, with a message that doesn't obviously point here.
#
# Order matters and is inside-out: each nested item must be signed before the
# thing that seals it, and the app must be re-signed last because re-signing the
# framework invalidates the app's own seal over it.
#
# Usage: scripts/sign-sparkle.sh <path-to-.app>
set -euo pipefail

APP="${1:?usage: sign-sparkle.sh <path-to-.app>}"
FW="$APP/Contents/Frameworks/Sparkle.framework"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

if [[ ! -d "$FW" ]]; then
    echo "  no Sparkle.framework in $APP — nothing to sign"
    exit 0
fi

# Reuse whatever identity the app was just signed with, rather than hardcoding
# one: the same script then works for local Development builds and for release
# builds signed with Developer ID, without a flag to get wrong.
# Deliberately no `exit` in awk: closing the pipe early sends codesign SIGPIPE,
# which `set -o pipefail` turns into a fatal 141. Read the whole stream instead.
IDENTITY=$(codesign -d --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }')
if [[ -z "$IDENTITY" ]]; then
    echo -e "${RED}✗ could not read the app's signing identity${NC} — is $APP signed?"
    exit 1
fi
echo "  identity: $IDENTITY"

# Newer Sparkle versions may drop or rename these, so missing items are skipped
# rather than fatal — but a *present* one failing to sign is fatal.
sign() {
    local name="$1"; shift          # capture before shift — $1 is gone afterwards
    local target="$FW/$name"
    if [[ ! -e "$target" ]]; then
        echo "    skip (absent): $name"
        return 0
    fi
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@" "$target" >/dev/null 2>&1 \
        || { echo -e "${RED}✗ failed to sign $name${NC}"; return 1; }
    echo "    signed: $name"
}

# Downloader.xpc runs sandboxed; --preserve-metadata=entitlements keeps the
# sandbox entitlement Sparkle ships it with. Signing it without that silently
# drops the sandbox.
sign "Versions/B/XPCServices/Installer.xpc"
sign "Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign "Versions/B/Autoupdate"
sign "Versions/B/Updater.app"

# Finally the framework itself, which seals everything signed above.
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$FW" >/dev/null 2>&1 \
    || { echo -e "${RED}✗ failed to sign Sparkle.framework${NC}"; exit 1; }
echo "    signed: Sparkle.framework"

# The app's seal covered the old framework signature, so it has to be redone.
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
    || { echo -e "${RED}✗ failed to re-sign $APP${NC}"; exit 1; }
echo "    re-signed: $(basename "$APP")"

# Prove it, rather than trusting the exit codes above: --deep walks the nested
# code, --strict rejects the sloppiness the notary would also reject.
if codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1; then
    echo -e "${GREEN}  ✓ signature verifies (deep, strict)${NC}"
else
    echo -e "${RED}✗ deep signature verification failed${NC}"
    codesign --verify --deep --strict --verbose=2 "$APP" || true
    exit 1
fi
