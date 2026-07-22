# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

> **Release tooling depends on this file.** `scripts/create-release-tag.sh` and
> the `pre-push` hook both refuse a `vX.Y.Z` tag unless a matching
> `## [X.Y.Z] - YYYY-MM-DD` heading exists here with a real date (not `TBD`),
> and the release workflow extracts that section as the GitHub Release body.

## [Unreleased]

## [0.1.0] - 2026-07-22

First public release. Pre-1.0 on purpose: the two private files it depends on
(Toggl's local database and macOS's Focus assertions) have no API and could
change under it at any time, so the version should say "this is new" until it
has survived contact with other people's machines.

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
- Self-healing detection: if the FSEvents stream stops delivering, the 120 s
  backstop notices it is the one finding state changes and rebuilds the stream,
  rather than silently leaving detection 120 s slow.
