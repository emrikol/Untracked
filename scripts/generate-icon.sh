#!/usr/bin/env bash
# Generate Resources/AppIcon.icns.
#
# Shared because project.yml references the icns as a build input, but it is
# gitignored — so any entry point that runs `xcodegen generate` must produce it
# first or fail on a clean checkout. run-tsan.sh used to skip this and only
# worked if a prior Release build had left one behind.
set -euo pipefail
cd "$(dirname "$0")/.."

ICON_TMP="$(mktemp -d)"
# Registered before the generators run: under `set -e` a failing make-icon or
# iconutil exits before any trailing rm, leaking the temp root on every failure.
trap 'rm -rf "$ICON_TMP"' EXIT

ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
