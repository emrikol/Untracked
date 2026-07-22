# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

> **Release tooling depends on this file.** `scripts/create-release-tag.sh` and
> the `pre-push` hook both refuse a `vX.Y.Z` tag unless a matching
> `## [X.Y.Z] - YYYY-MM-DD` heading exists here with a real date (not `TBD`),
> and the release workflow extracts that section as the GitHub Release body.

## [Unreleased]

### Added

- Menu-bar nag: a pulsing, click-through overlay whenever a Toggl Track timer
  is not running. Screen-border, menu-bar-strip, or both.
- Event-driven detection via FSEvents on Toggl's local Core Data store, read
  read-only and in place. A 120 s fallback timer runs only while monitoring.
- Hot-reloaded JSON config at `~/.untracked.json` (kqueue watcher, no polling).
- Quiet while away (lock/sleep/session switch), during Focus/Do Not Disturb,
  outside configured work hours, when paused or snoozed, and during the
  post-stop grace period.
- Work-hours gating that fully idles the app — no Toggl reads at all — waking
  once at the next boundary via a single dated one-shot timer.
- Static-analysis gate enforced by `build.sh` and a pre-commit hook: SwiftLint
  (232 of 251 rules, zero violations), SwiftFormat, shellcheck, and
  project-specific invariant checks.
- Automatic updates via Sparkle, checked from events the app already receives
  (launch, wake, resume from off-duty) rather than a repeating timer, and at
  most once per six waking hours. Sparkle's own scheduler stays disabled.
- "Check for Updates…" in the menu for an on-demand check.

### Fixed

- Detection could silently degrade from ~1 s to ~120 s when the FSEvents stream
  stopped delivering: the fallback timer masked it, so the only symptom was a
  nag appearing while a timer was genuinely running. The watcher now notices
  when the backstop — not the stream — is finding state changes, and rebuilds
  the stream.
- Overlay windows were ordered out but not closed on hide, so AppKit's own
  window registry kept them alive until the next time the overlay was shown.
