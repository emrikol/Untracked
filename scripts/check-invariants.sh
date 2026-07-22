#!/usr/bin/env bash
# Build-time gate: project invariants, SwiftLint, and shellcheck.
#
# CLAUDE.md > Conventions carries the *why*; this script enforces the *what*,
# because a rule that lives only in prose is one you have to remember to apply.
# It was written after a snooze deadline shipped carrying the exact clock-
# rollback bug the prose rule already forbade — the rule was written down, and an
# instance of it was added three functions away in the same file anyway.
#
# Fast and grep-based; runs on every build before anything expensive.
set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
fail=0

indent() { while IFS= read -r line; do printf '    %s\n' "$line"; done; }

# --- 1. Durations must be monotonic ----------------------------------------
#
# Civil-clock arithmetic is CORRECT for an absolute wall-clock instant (the 09:00
# work-hours boundary genuinely means 09:00) and for values that are merely
# displayed ("not tracking for 12m"). It is WRONG for measuring elapsed time: the
# app subscribes to NSSystemClockDidChange, so a backward correction is a normal
# input, and `interval - elapsed` explodes once elapsed goes negative.
#
# Both uses are legitimate, so this does not ban the calls — it requires each
# site to declare which it is, via
#     // wall-clock: <reason>
# on the same line or either of the two directly above it (so a longer reason can
# read as a normal comment block). Unmarked sites fail the build.
#
# The marker must carry a real reason. Silencing this with a bare or bogus marker
# is how the rule dies quietly — the reason is the part a reviewer can check.
sources=()
for f in Sources/*.swift; do
    [[ "$f" == "Sources/Uptime.swift" ]] && continue   # the helper itself
    sources+=("$f")
done

offenders=$(awk '
    FNR == 1 { prev1 = ""; prev2 = "" }
    {
        if (($0 ~ /\.timeIntervalSince/ || $0 ~ /Date\(\)\.addingTimeInterval/) &&
            $0 !~ /\/\/ wall-clock:/ && prev1 !~ /\/\/ wall-clock:/ && prev2 !~ /\/\/ wall-clock:/)
            printf "%s:%d:%s\n", FILENAME, FNR, $0
        prev2 = prev1; prev1 = $0
    }
' "${sources[@]}" || true)

if [[ -n "$offenders" ]]; then
    echo -e "${RED}✗ Unjustified civil-clock arithmetic${NC} — use Uptime.now() for durations,"
    echo "  or add '// wall-clock: <reason>' if this really is an absolute instant or a"
    echo "  displayed value (see CLAUDE.md > Conventions):"
    indent <<< "$offenders"
    fail=1
fi

# --- 2. One monotonic clock, not several -----------------------------------
#
# Uptime is tiny; the risk isn't complexity, it's someone re-deriving it inline
# and quietly diverging (different units, or a Date fallback).
strays=$(grep -n 'uptimeNanoseconds' "${sources[@]}" || true)
if [[ -n "$strays" ]]; then
    echo -e "${RED}✗ Monotonic clock re-implemented outside Uptime.swift${NC} — call Uptime.now():"
    indent <<< "$strays"
    fail=1
fi

# --- 3. Every lint exemption must say why ------------------------------------
#
# A `swiftlint:disable` with no reason is indistinguishable from someone silencing
# an inconvenient rule, and it is the usual way a ruleset rots. Require an
# explanation on the same line, after a dash:
#     // swiftlint:disable <rule> - <why>
# `swiftlint:enable` needs nothing; it closes a region rather than opening a hole.
# superfluous_disable_command (enabled) separately proves each one is load-bearing.
undocumented=$(grep -rn 'swiftlint:disable' Sources/ \
    | grep -vE 'swiftlint:disable[a-z:]* [a-z_, ]+ - .{3,}' || true)
if [[ -n "$undocumented" ]]; then
    echo -e "${RED}✗ Undocumented lint exemption${NC} — add ' - <reason>' explaining why:"
    indent <<< "$undocumented"
    fail=1
fi

# --- 4. SwiftLint -----------------------------------------------------------
#
# --strict promotes warnings to errors. The ruleset is curated to sit at zero, so
# anything at all here is a regression. If a rule turns out to be noise, delete it
# from .swiftlint.yml with a reason rather than sprinkling disable comments.
if command -v swiftlint >/dev/null 2>&1; then
    if ! swiftlint lint --strict --quiet; then
        echo -e "${RED}✗ SwiftLint${NC} (see .swiftlint.yml)"
        fail=1
    fi
else
    echo -e "${YELLOW}  ! swiftlint not installed — skipping (brew install swiftlint)${NC}"
fi

# --- 5. SwiftFormat ---------------------------------------------------------
#
# --lint checks without rewriting: a build (or a commit hook) must never mutate
# your working tree behind your back. Run ./scripts/format.sh to fix.
if command -v swiftformat >/dev/null 2>&1; then
    if ! swiftformat Sources --lint --quiet; then
        echo -e "${RED}✗ SwiftFormat${NC} — run ./scripts/format.sh"
        fail=1
    fi
else
    echo -e "${YELLOW}  ! swiftformat not installed — skipping (brew install swiftformat)${NC}"
fi

# --- 6. shellcheck ----------------------------------------------------------
#
# These scripts run `rm -rf` against /Applications and $TMPDIR, so a quoting bug
# here is destructive rather than cosmetic. (shellcheck caught exactly that in an
# earlier revision of this file: an unquoted `ls | grep` that would have split on
# spaces.)
if command -v shellcheck >/dev/null 2>&1; then
    if ! shellcheck build.sh scripts/*.sh; then
        echo -e "${RED}✗ shellcheck${NC}"
        fail=1
    fi
else
    echo -e "${YELLOW}  ! shellcheck not installed — skipping (brew install shellcheck)${NC}"
fi

# --- Not gated here, deliberately ------------------------------------------
#
# Two CLAUDE.md conventions resist static checking, and a heuristic that cries
# wolf is worse than none:
#
#   * "Watch arming is open()-result-driven, not fileExists()-driven" — would mean
#     grepping for fileExists near open(), which is brittle and would miss the
#     shape that actually matters (returning unarmed on failure). Wants a test.
#   * "The 120 s fallback sits outside the event-read throttle" — design intent,
#     not a syntactic pattern. Only a behavioural test can assert it.
#
# SWIFT_STRICT_CONCURRENCY=complete (project.yml) covers the thread-safety half
# of this, and `scripts/run-tsan.sh` covers it at runtime.

if [[ $fail -ne 0 ]]; then
    echo -e "${YELLOW}Gate failed — see CLAUDE.md > Conventions.${NC}"
    exit 1
fi
echo "  invariants + swiftlint + swiftformat + shellcheck OK"
