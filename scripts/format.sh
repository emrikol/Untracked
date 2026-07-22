#!/usr/bin/env bash
# Auto-fix everything that can be auto-fixed.
#
# Order matters. SwiftLint's --fix handles semantic corrections (shorthand
# optional binding, redundant self, toggle_bool …); SwiftFormat owns layout and
# must therefore run LAST so it always has the final word on whitespace.
#
# Deliberately NOT part of build.sh: a build that rewrites its own inputs isn't
# reproducible, and this project already has a scar from exactly that — an editor
# hook silently renamed a parameter to `_` and broke make-icon.swift. Mutation is
# opt-in; build.sh only ever *checks*.
set -euo pipefail
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'; NC='\033[0m'

echo -e "${GREEN}▸${NC} swiftlint --fix (semantic)…"
swiftlint --fix --quiet

echo -e "${GREEN}▸${NC} swiftformat (layout — last word)…"
swiftformat Sources --quiet

echo -e "${GREEN}▸${NC} Verifying…"
./scripts/check-invariants.sh
