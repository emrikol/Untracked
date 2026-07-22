#!/usr/bin/env bash
# The one supported way to cut a release: validates everything the release
# workflow assumes, then creates the annotated tag that triggers it.
#
# Why this exists rather than a bare `git tag`: the pre-push hook only catches
# a missing/TBD/malformed CHANGELOG entry — it can't catch a non-increasing
# version, a dirty tree, the wrong branch, or a duplicate tag, because by the
# time a hook sees the ref it's already created. Catching those here, before
# the tag exists, is the only point where "undo" is still free.
#
# Usage: scripts/create-release-tag.sh <X.Y.Z>   (a leading 'v' is accepted)
set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

die() {
    echo -e "${RED}✗ $*${NC}" >&2
    exit 1
}

indent() { while IFS= read -r line; do printf '  %s\n' "$line"; done; }

[[ $# -eq 1 ]] || die "usage: scripts/create-release-tag.sh <X.Y.Z>"

# Accept a leading 'v' so `create-release-tag.sh 1.2.3` and `...v1.2.3` both
# work — the tag itself always gets the 'v', CHANGELOG headings never do.
raw="$1"
version="${raw#v}"

if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    die "'$raw' is not MAJOR.MINOR.PATCH (e.g. 1.2.3)"
fi
new_minor="${BASH_REMATCH[2]}"; new_patch="${BASH_REMATCH[3]}"
tag="v$version"

# Same limit scripts/version.sh enforces: CFBundleVersion encodes the semver
# digits as major*1e6 + minor*1e3 + patch, so a minor or patch of 1000+ would
# collide with the next major/minor's range instead of failing loudly.
if [[ "$new_minor" -gt 999 || "$new_patch" -gt 999 ]]; then
    die "minor/patch above 999 breaks the build-number encoding (see scripts/version.sh)"
fi

# --- working tree / branch / duplicate-tag guards ---------------------------
#
# All three are here rather than left to `git tag` because each failure is
# cheap to explain now and confusing to debug from git's own error text.
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty — commit or stash first"

branch=$(git rev-parse --abbrev-ref HEAD)
[[ "$branch" == "main" ]] || die "not on main (currently on '$branch') — releases are cut from main"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 && die "tag $tag already exists locally"

# Best-effort: an unreachable remote shouldn't block a release, but an actual
# collision on origin must, since pushing would then fail (or worse, diverge).
#
# The assignment lives in the `if` condition on purpose. Written as a bare
# `remote_tags=$(...)` followed by `remote_status=$?`, `set -e` aborts the whole
# script the moment git fails and the status is never read — so "best-effort"
# became "exits 128 with a raw git error". That is not hypothetical: this repo
# had no `origin` at all while the release tooling was being written, which is
# exactly the state a first release starts from. A condition context suppresses
# `set -e` for the command; nothing else here does.
#
# stderr goes to its own temp file rather than being folded in with 2>&1: on the
# success path this variable is tested for emptiness, and any stray git progress
# output would read as "a tag exists on origin" and block the release.
remote_err=$(mktemp)
trap 'rm -f "$remote_err"' EXIT
if remote_tags=$(git ls-remote --tags origin "refs/tags/$tag" 2>"$remote_err"); then
    [[ -z "$remote_tags" ]] || die "tag $tag already exists on origin"
else
    echo -e "${YELLOW}  (couldn't reach origin to check for a duplicate tag — continuing)${NC}"
    # Show git's reason rather than swallowing it: "no origin configured" and
    # "the network is down" want very different responses from whoever ran this.
    [[ ! -s "$remote_err" ]] || indent < "$remote_err"
fi

# --- version must move strictly forward -------------------------------------
#
# Per-component numeric comparison, not `sort -V`: sort -V's ordering of
# unusual inputs (leading zeros, differing segment counts) isn't something
# this script wants to depend on for a check whose whole job is correctness.
version_cmp() {
    # Echoes -1/0/1 for how $1 compares to $2, numeric per dot-separated part.
    local -a a b
    IFS='.' read -r -a a <<<"$1"
    IFS='.' read -r -a b <<<"$2"
    local i
    for i in 0 1 2; do
        local ai=${a[i]:-0} bi=${b[i]:-0}
        if ((10#$ai > 10#$bi)); then
            echo 1
            return
        fi
        if ((10#$ai < 10#$bi)); then
            echo -1
            return
        fi
    done
    echo 0
}

newest="0.0.0" # matches scripts/version.sh's own "no tags yet" default
while IFS= read -r existing; do
    [[ -n "$existing" ]] || continue
    candidate="${existing#v}"
    [[ "$(version_cmp "$candidate" "$newest")" == "1" ]] && newest="$candidate"
done < <(git tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)

[[ "$(version_cmp "$version" "$newest")" == "1" ]] \
    || die "$version is not greater than the newest existing tag (v$newest)"

# --- CHANGELOG: identical rules to .githooks/pre-push -----------------------
#
# Duplicating the three checks rather than sourcing the hook: the hook reads
# refs off stdin in a loop and isn't meant to be called as a library. Keeping
# both in sync is the cost; CLAUDE.md's admonition on CHANGELOG.md is the
# reminder to pay it if one changes.
today=$(date +%Y-%m-%d)

changelog_has_heading() { grep -q "## \[$version\]" CHANGELOG.md; }
changelog_is_tbd() { grep -q "## \[$version\] - TBD" CHANGELOG.md; }
changelog_has_valid_date() {
    grep -qE "## \[$version\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" CHANGELOG.md
}

if ! changelog_has_heading; then
    # No section for this version yet. Before failing, check whether
    # [Unreleased] already holds the content that section should contain —
    # that's the common case (finishing a release right after the work that
    # goes in it), and retyping it by hand is pure friction.
    unreleased_body=$(awk '
        /^## \[Unreleased\]$/ { flag = 1; next }
        /^## \[/ { flag = 0 }
        flag
    ' CHANGELOG.md | sed '/^[[:space:]]*$/d')

    if [[ -z "$unreleased_body" ]]; then
        die "no CHANGELOG entry for $version — add '## [$version] - $today' to CHANGELOG.md"
    fi

    echo -e "${YELLOW}No '## [$version]' section, but [Unreleased] has content:${NC}"
    echo "  --------------------------------------------------------------"
    indent <<<"$unreleased_body"
    echo "  --------------------------------------------------------------"
    echo "This would rewrite '## [Unreleased]' into '## [$version] - $today'"
    echo "and add a fresh empty '## [Unreleased]' above it."

    # Never edit without an explicit yes — and never mistake a non-interactive
    # run (CI, a piped input) for one. -t 0 is the only reliable signal.
    if [[ ! -t 0 ]]; then
        die "no CHANGELOG entry for $version, and stdin isn't a terminal to confirm the rewrite"
    fi
    read -r -p "Rewrite CHANGELOG.md accordingly? [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || die "aborted — CHANGELOG.md not modified"

    tmp=$(mktemp)
    awk -v ver="$version" -v today="$today" '
        { print }
        /^## \[Unreleased\]$/ && !done {
            print ""
            print "## [" ver "] - " today
            done = 1
        }
    ' CHANGELOG.md >"$tmp"
    mv "$tmp" CHANGELOG.md

    git add CHANGELOG.md
    git commit -m "Prepare CHANGELOG for v$version" --quiet
    echo -e "${GREEN}  ✓ CHANGELOG.md rewritten and committed${NC}"
fi

changelog_is_tbd && die "CHANGELOG entry for $version still says TBD — set a real date"
changelog_has_valid_date || die "CHANGELOG entry for $version has no valid date (expected YYYY-MM-DD)"

echo -e "${GREEN}  ✓ CHANGELOG validated for $version${NC}"

# --- tag ---------------------------------------------------------------------
#
# Annotated (not lightweight): it carries a message, a tagger, and a date, all
# of which the release workflow / GitHub release can use. The message is the
# CHANGELOG section itself, so the tag and the release notes can never drift.
section_body=$(awk -v ver="$version" '
    $0 ~ ("^## \\[" ver "\\]") { flag = 1; next }
    /^## \[/ { flag = 0 }
    flag
' CHANGELOG.md)

tag_message=$(printf '%s\n\n%s\n' "$tag" "$section_body")
# --cleanup=verbatim: git's default (strip) treats any line starting with '#'
# as a commentary line and deletes it — which is every Markdown heading in a
# CHANGELOG body ("### Added"). Caught by actually inspecting the tag object,
# not by shellcheck or a dry read of this script.
git tag -a "$tag" -m "$tag_message" --cleanup=verbatim
echo -e "${GREEN}✓ Created annotated tag $tag${NC}"

# --- summary -------------------------------------------------------------
#
# Never push here: house rule is no push without explicit permission, and
# pushing the tag is what fires the release workflow. Print the exact command
# instead of running it.
echo
echo "Not pushed. When ready:"
echo "  git push origin main && git push origin $tag"
echo
echo "scripts/version.sh will produce, once this tag is pushed and checked out:"
scripts/version.sh
