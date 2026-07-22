#!/usr/bin/env bash
# Point git at the version-controlled hooks in .githooks/.
# Run once per clone: ./scripts/install-hooks.sh
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
echo "✓ core.hooksPath = .githooks  (pre-commit gate + pre-push changelog check active)"
