#!/usr/bin/env bash
# Run Untracked under Thread Sanitizer.
#
# Why this exists: the app's real risk is concurrency — an FSEvents queue, two
# kqueue queues, and the main thread, with cross-thread state guarded by
# hand-rolled generation tokens. SWIFT_STRICT_CONCURRENCY=complete proves the
# *static* half of that; TSan is the only thing that observes the actual
# interleavings at runtime.
#
# This is deliberately manual: TSan needs the app to be *exercised*, and the
# interesting transitions are physical (lock the screen, toggle a Focus mode,
# start/stop a Toggl timer, cross a work-hours boundary). It is not part of
# build.sh — it's a debug build, roughly 5-10x slower, and it wants a human.
#
# Usage:  ./scripts/run-tsan.sh          # build + run in the foreground
#         ./scripts/run-tsan.sh --build  # build only
set -euo pipefail
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'; NC='\033[0m'
BUILD_DIR="build-tsan.noindex"   # .noindex keeps it out of Spotlight, as with build.noindex

echo -e "${GREEN}▸${NC} Generating app icon…"
scripts/generate-icon.sh

echo -e "${GREEN}▸${NC} Generating Xcode project…"
xcodegen generate

echo -e "${GREEN}▸${NC} Building Debug + TSan…"
# Strict concurrency stays on; TSan needs a non-stripped Debug build to symbolicate.
xcodebuild -project Untracked.xcodeproj \
    -scheme Untracked \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -enableThreadSanitizer YES \
    CODE_SIGN_STYLE=Automatic \
    DEPLOYMENT_POSTPROCESSING=NO \
    STRIP_INSTALLED_PRODUCT=NO \
    -quiet

APP="$BUILD_DIR/Build/Products/Debug/Untracked.app"
BIN="$APP/Contents/MacOS/Untracked"
echo -e "${GREEN}▸${NC} Built: $APP"

if [[ "${1:-}" == "--build" ]]; then
    exit 0
fi

# Quit any running copy first: the flock singleton guard would otherwise make
# this instance exit(0) immediately and you'd think TSan found nothing.
osascript -e 'tell application "Untracked" to quit' 2>/dev/null || true

cat <<'NOTE'

  Running in the foreground. Reports print here (halt_on_error=0, so it keeps
  going and collects everything). Exercise the concurrent paths:

    - start and stop a Toggl timer          (FSEvents queue -> main)
    - edit ~/.untracked.json           (config kqueue -> main)
    - toggle a Focus mode                   (Focus kqueue -> main)
    - lock the screen / let the display sleep
    - Pause and Resume from the menu        (tears down and restarts watchers)
    - snooze, then cancel

  The teardown/restart paths are the ones worth the most attention: that is
  where the generation tokens do their work. Ctrl-C when done.

NOTE

# halt_on_error=0 keeps running past the first report so one session finds more
# than one race; second_deadlock_stack gives both sides of a lock-order report.
TSAN_OPTIONS="halt_on_error=0:second_deadlock_stack=1" exec "$BIN"
