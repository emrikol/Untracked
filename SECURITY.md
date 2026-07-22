# Security

Untracked reads one local file and paints an overlay. It has **no account, no
API token, and no telemetry**. Its only network use is the Sparkle update check,
which sends the app version, macOS version, and CPU architecture. This document
records the project's security posture.

## Posture

- **No credentials, anywhere.** Detection works by reading Toggl Track's local
  Core Data store **read-only and in place**. There is no login, no API key, and
  no request to Toggl's servers. Nothing to leak.
- **Read-only file access.** The app opens Toggl's SQLite store with
  `SQLITE_OPEN_READONLY` and the two watched files (`~/.untracked.json`,
  `~/Library/DoNotDisturb/DB/Assertions.json`) with `O_EVTONLY`. It writes
  exactly one file: its own config.
- **No Full Disk Access required** — verified. If a future macOS release changes
  that, detection degrades to "unavailable" and the app goes quiet rather than
  prompting for broader permissions.
- **Updates** are **EdDSA-signed** and verified against the public key embedded
  in `Info.plist` (`SUPublicEDKey`); the app itself is **Developer ID-signed and
  notarised**. A compromised update server cannot ship code to you.
- **Transport** — the appcast and every update download use HTTPS with default
  certificate validation. There are no App Transport Security exceptions.
- **Signing** — hardened runtime, with **no** weakening entitlements: no
  `disable-library-validation`, no JIT, no `dlopen`/`exec` of dynamic code.
- **CI/CD** — release secrets run only on owner-pushed tags, every GitHub Action
  is pinned to a commit SHA, and the `pull_request_target` governance job runs
  no pull-request code.

## Two fragile dependencies, both failing safe

Untracked reads two private, undocumented files. Neither has a public API, and
either can change without notice. Both were chosen to fail in the safe
direction:

- **Toggl's Core Data store** — if the path or schema changes, the state becomes
  `unavailable` and the app **stops nagging** rather than nagging falsely.
- **`~/Library/DoNotDisturb/DB/Assertions.json`** — if this becomes unreadable,
  the app **fails open** and keeps nagging. A break here costs you a nag during
  Focus; it never silently disables the feature you installed the app for.

## Documented decisions

- **App Sandbox — not enabled (deferred).** The app ships with Developer ID, not
  through the Mac App Store, where sandboxing isn't required. Sandboxing would
  complicate reading Toggl's group container and Sparkle's installer. It's a
  candidate for a future release.
- **Local-only by design.** Untracked reflects *this Mac's* synced Toggl state.
  Tracking started only on a phone, with the Mac app closed, is invisible to it.
  This is deliberate: it keeps the app credential-free.

## Reporting

This is a personal, **as-is** project with no support. Security issues can be
reported through GitHub's **private vulnerability reporting** on this
repository. There is no guaranteed response time.
