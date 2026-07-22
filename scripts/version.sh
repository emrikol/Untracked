#!/usr/bin/env bash
# Derive the app's version from the git tag, so a release can't ship stale.
#
# Why this exists: project.yml hardcodes MARKETING_VERSION/CURRENT_PROJECT_VERSION,
# and nothing bumps them. Sparkle decides whether an update exists by comparing
# the appcast item's version against the *installed* CFBundleVersion, so a
# hardcoded "1" means every release looks like version 1 and no client ever
# updates — with a completely green release workflow. Silent, and only
# observable by someone who never gets an update they were never told about.
#
# Usage:
#   scripts/version.sh              -> "<marketing> <build>" on one line
#   scripts/version.sh --marketing  -> e.g. 1.2.3   (CFBundleShortVersionString)
#   scripts/version.sh --build      -> e.g. 1002003 (CFBundleVersion)
#
# Set REQUIRE_TAG=1 to fail unless HEAD is exactly a clean release tag. The
# release workflow uses that; local builds don't, so `./build.sh` still works in
# a repo with no tags at all.
set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; NC='\033[0m'

# --abbrev=0 gives the nearest tag itself rather than a describe string, and the
# v[0-9]* match keeps non-release tags (scratch, notes) out of the answer.
tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)

# Exact = HEAD is that tag, with nothing uncommitted. Both halves matter: a
# dirty tree at a tag is not the thing the tag names.
exact=0
if [[ -n "$tag" ]] \
    && [[ "$(git rev-parse "$tag^{commit}")" == "$(git rev-parse HEAD)" ]] \
    && [[ -z "$(git status --porcelain)" ]]; then
    exact=1
fi

if [[ -z "$tag" ]]; then
    # No release has ever been tagged. 0.0.0 sorts below every real version, so
    # a first release is always an upgrade — which is the safe direction to be
    # wrong in. Defaulting to 1.0 here would make the first 1.0.0 release
    # un-offerable to anyone running a dev build.
    version="0.0.0"
else
    version="${tag#v}"
fi

if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo -e "${RED}✗ tag '$tag' is not vMAJOR.MINOR.PATCH${NC}" >&2
    exit 1
fi
major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"

if [[ "$minor" -gt 999 || "$patch" -gt 999 ]]; then
    echo -e "${RED}✗ minor/patch above 999 breaks the build-number encoding${NC}" >&2
    exit 1
fi

if [[ "${REQUIRE_TAG:-0}" == "1" && "$exact" != "1" ]]; then
    echo -e "${RED}✗ REQUIRE_TAG=1 but HEAD is not a clean release tag${NC}" >&2
    echo "  nearest tag: ${tag:-<none>}; run this from a tagged, clean checkout." >&2
    exit 1
fi

# CFBundleVersion is what Sparkle actually compares, so it must increase with
# every release and must be derivable from the tag alone. Encoding the semver
# digits does both: the same tag always yields the same number, and it survives
# history rewrites. A commit count would not have — this repo's history was
# squashed once already, which would have reset the count to 1.
build=$((major * 1000000 + minor * 1000 + patch))

# Mark anything that isn't a clean tagged build, so a hand-built .app is never
# mistaken for a release — the suffix shows up in About and in bug reports.
#
# It is display only. Sparkle compares CFBundleVersion, and a dev build carries
# the same build number as the tag it sits on, so it is *not* offered that tag's
# release. That is the intended behaviour (a dev build of 1.2.3 already contains
# 1.2.3), but it does mean the marketing suffix cannot be relied on to trigger
# an update — don't read the `-dev` as "Sparkle will treat this as older".
if [[ "$exact" != "1" ]]; then
    version="$version-dev"
fi

case "${1:-}" in
    --marketing) echo "$version" ;;
    --build)     echo "$build" ;;
    "")          echo "$version $build" ;;
    *)
        echo "usage: version.sh [--marketing|--build]" >&2
        exit 2
        ;;
esac
