# Untracked

**A menu-bar nag for Toggl Track.** A tiny macOS app that flashes a pulsing red
overlay when you're *not* tracking time — so you stop forgetting to start the
timer.

It reads the Toggl Track desktop app's **local database** (no API token, no
network), waking only when Toggl writes to it (FSEvents). When nothing is
running, it shows an unmissable (but click-through, non-blocking) red nag. When
a timer is running, the nag
disappears and the menu-bar icon goes green.

> Untracked is an independent project. It is **not** affiliated with, endorsed by,
> or supported by Toggl OÜ. "Toggl" and "Toggl Track" are trademarks of Toggl OÜ
> and are used here only to identify the application Untracked works with.

## How it detects tracking (local-only)

The Toggl Track app (`com.toggl.daneel`) keeps a Core Data SQLite store — the
same file its own menu-bar widget reads:

```
~/Library/Group Containers/B227VTMZ94.group.com.toggl.daneel.extensions/production/DatabaseModel.sqlite
```

The **running entry is the single non-deleted row in `ZMANAGEDTIMEENTRY` with a
NULL duration**. We query the live store **read-only, in place** — in WAL mode
readers don't block (or get blocked by) Toggl's writer, and SQLite only reads the
few pages the query needs.
Reading works **without Full Disk Access** (verified).

> ⚠️ This store is private and undocumented. A Toggl app update could rename the
> path or change how "running" is encoded, which would break detection. By
> design that degrades to "data unavailable" (no false nag) — see
> `Sources/TogglLocalStore.swift` to fix the path/query if it ever happens.

## Footprint (event-driven, no polling)

Detection is driven by **FSEvents** watching Toggl's `production/` directory, so
the app wakes only when Toggl actually writes to its DB (start/stop/edit a
timer). A running timer changes nothing on disk, so the app sits idle. FSEvents'
2s latency coalesces the write burst of a single start/stop into one read; a
120s high-tolerance fallback timer (`AppDelegate.swift`) is only a backstop for a
missed event.

The overlay heartbeat is **duty-cycled** (`OverlayController.swift`): a timer
fires a short ~0.7s beat every 8s by default and the overlay is fully static in between,
rather than an always-on animation that recomposites every frame.

Measured: idle CPU ≈ 0%, resident private memory ≈ 18 MB, ~222 KB stripped
binary.

## Why an overlay instead of "flash the title bar"?

macOS won't let one app recolor another app's window chrome — the title bar is
drawn inside the owning app's own process, and process isolation + code-signing
enforcement block any cross-app rendering (root doesn't help). The legitimate
path is to paint **our own** click-through window on top, which is what this does.

## Alert styles (switchable from the menu)

- **Screen Border** — a pulsing red rim around every display.
  Robust, covers nothing, shows over full-screen apps.
- **Menu Bar Strip** *(default)* — a pulsing red strip over the menu-bar area. If the notch
  occludes the middle, the flanking red is still clear signal.
- **Both**.

## Install

Download the latest `Untracked-X.Y.Z.zip` from
[Releases](https://github.com/emrikol/Untracked/releases), unzip it, and drag
`Untracked.app` to `/Applications`. Builds are signed with a Developer ID and
notarised by Apple, so it opens without a Gatekeeper warning.

No setup needed beyond launching it. Click the menu-bar icon → **Launch at
Login** so it starts with your Mac.

## Updates

Untracked updates itself via [Sparkle](https://sparkle-project.org). Updates are
signed with an EdDSA key and verified before anything is installed.

Checks are **event-driven, like everything else here** — there is no update
timer. Untracked piggybacks on wake-ups it already receives (launch, waking from
sleep, coming back on duty) and checks at most once per six *waking* hours. On a
machine that is asleep or off-duty, nothing happens at all.

Menu → **Check for Updates…** forces a check and, unlike the background one,
tells you when you're already up to date.

## Build

Requires Xcode and, via Homebrew:

```bash
brew install xcodegen swiftlint swiftformat shellcheck
```

All four are required, not optional: `build.sh` runs `scripts/check-invariants.sh`
first and **fails the build** if any of the linters is missing, so a missing tool
can't quietly turn the gate into a no-op.

```bash
./build.sh --install   # build, copy to /Applications, launch
./build.sh             # just build into ./build.noindex
```

The version comes from the newest `vX.Y.Z` git tag — a build from an untagged or
dirty tree is labelled `-dev`. Run `./scripts/install-hooks.sh` once per clone to
enable the pre-commit and pre-push gates.

## Configuration — `~/.untracked.json`

Auto-created with defaults on first run. Edit it (menu → **Edit Config…**) and
changes apply **instantly** — the file is hot-reloaded via a kqueue watcher
(event-driven, zero idle cost). Any key may be omitted; omitted keys use their
default.

This file is parsed as **strict JSON** — no comments, no trailing commas. (A file
that fails to parse is ignored and the previous settings are kept.) The defaults,
safe to copy verbatim:

```json
{
  "alertStyle": "menuBar",
  "flashWhenTracking": true,
  "flashWhenNotTracking": true,
  "trackingColor": "#34C759",
  "notTrackingColor": "#FF3B30",
  "beatPeriodSeconds": 8,
  "borderThickness": 10,
  "gracePeriodSeconds": 45,
  "respectDoNotDisturb": true,
  "workHoursEnabled": false,
  "workDays": "MTWRF",
  "workHours": "09:00-17:00"
}
```

| Key | Meaning |
|-----|---------|
| `alertStyle` | `"menuBar"` \| `"border"` \| `"both"` |
| `flashWhenTracking` | green heartbeat while a timer **is** running |
| `flashWhenNotTracking` | red heartbeat while **not** tracking (the nag) |
| `trackingColor`, `notTrackingColor` | hex `#RRGGBB` or `#RRGGBBAA` (alpha is honoured by every style) |
| `beatPeriodSeconds` | seconds between heartbeats |
| `borderThickness` | px, for the `"border"` style |
| `gracePeriodSeconds` | wait this long after a timer stops before nagging |
| `respectDoNotDisturb` | stay quiet while a Focus/DnD is active |
| `workHoursEnabled` | if `true`, only nag during the window below |
| `workDays` | `M` `T`(Tue) `W` `R`(Thu) `F` `S`(Sat) `U`(Sun) |
| `workHours` | local time, `"HH:MM-HH:MM"` |

Both flashes can also be toggled from the menu (**Flash When Tracking** /
**Flash When Not Tracking**, which write back to this file). Turn off
`flashWhenTracking` for nag-only; turn off both for a silent, icon-only mode.
Invalid colors fall back to red/green rather than breaking.

## Menu

- Live status (tracking / not tracking / paused / quiet reason / "Not tracking for 12m")
- **Open Toggl Track** — focuses the desktop app (falls back to the web timer)
- **Pause / Resume** — silence indefinitely without quitting
- **Snooze** — 10 / 30 / 60 min (e.g. during meetings)
- **Alert Style** — Border / Menu Bar Strip / Both (writes to the JSON config)
- **Flash When Tracking / Not Tracking** — toggles (write to the JSON config)
- **Only Nag During Work Hours** — toggles `workHoursEnabled` (shows the window)
- **Respect Focus / Do Not Disturb** — toggles `respectDoNotDisturb`
- **Edit Config…** — opens `~/.untracked.json`
- **Launch at Login**

## When it stays quiet (no nag)

- **You're away** — screen locked, display asleep, or session switched out.
- **Focus / Do Not Disturb is active** (`respectDoNotDisturb`). *Best-effort:*
  macOS has no usable public Focus API (the official `INFocusStatusCenter` needs
  a Communication-Notifications entitlement + an auth prompt and can't be
  subscribed to — only polled). So this reads `~/Library/DoNotDisturb/DB/Assertions.json`
  via a kqueue watcher (instant, no permissions) and **fails open** — if it
  can't read it, it nags normally.
- **Outside work hours** (`workHoursEnabled`) — and during these it fully idles:
  it stops reading Toggl's DB entirely, shows an off-duty (🌙) menu-bar icon, and
  wakes once at the next work-hours boundary (a single dated timer, plus
  wake/clock notifications — no polling). Zero reads all weekend.
- **Paused** or **snoozed**.
- **Grace period** — for `gracePeriodSeconds` after a timer stops (so normal
  task-switching doesn't trigger a flash).

## Behavior notes

- Only a **definitive "not tracking"** nags. If the DB is missing/unreadable or
  Toggl has never run, the state is **unavailable** and it stays quiet. If that
  happens *while the Toggl app is running* (likely a schema change broke
  detection), it posts a one-time notification rather than failing silently.
- It nags whenever you're not tracking, even if the Toggl app is closed (closed =
  not tracking on this Mac). Pause/snooze/quit if that's not what you want.
- State is read from *this Mac's* synced data — if you track only on your phone
  with the Mac app closed, it can't know. (Acceptable for the "I forget at my
  desk" use case.)
- Launch-at-login is enabled automatically on first run (toggle it off in the menu).

## Knobs

Most tuning is in `~/.untracked.json` (above). Heartbeats use ±40%
tolerance so wake-ups coalesce. Remaining code-level knobs:

- Fallback re-read interval: the 120s `Timer` in `Sources/AppDelegate.swift` (backstop).
- Overlay window level: `.screenSaver` in `Sources/OverlayController.swift`.
  Lower to `.statusBar` if you'd rather it not draw over an open menu — at the
  cost of not showing over full-screen apps.

## Signing

Bundle id `com.emrikol.Untracked`, Team `3T9RX85H44`. Local builds use automatic
signing; release builds are signed with a Developer ID and notarised by the
release workflow. Setting `SIGN_IDENTITY` switches `build.sh` to manual signing
with that identity.

Sparkle ships its nested helpers (two XPC services, `Autoupdate`, `Updater.app`)
ad-hoc signed, and `xcodebuild` — unlike Xcode's Distribute flow — leaves them
that way. Notarisation rejects that, so `scripts/sign-sparkle.sh` re-signs them
inside-out and then re-signs the app; `build.sh` runs it automatically and
verifies the result with `codesign --verify --deep --strict`.

## Support Policy

**This software is provided as-is, with no support.**

- ✅ You may use, modify, and redistribute it under the
  [GNU General Public License, version 2 or later](LICENSE).
- ❌ **No support, bug fixes, or feature requests.**
- ❌ **Issues are disabled** — please don't contact the maintainer for help.
- ❌ **Pull requests are accepted only from collaborators** — others are auto-closed.
- 💡 **To change it, fork it** and adapt it to your needs. The GPL explicitly
  grants you that right.

### Why this policy?

Untracked is a personal project. It reads two private, undocumented files —
Toggl Track's local Core Data store and macOS's Do Not Disturb assertions
database — and either can change without notice in any Toggl or macOS update.
Supporting every combination of the two is beyond its scope. Both dependencies
fail safe (see [SECURITY.md](SECURITY.md)), so a break degrades the app rather
than breaking your machine.

If you redistribute a modified version, please use a **different project name
and branding** to avoid confusion.

## License

[GNU General Public License v2.0 or later](LICENSE) — `GPL-2.0-or-later`.

Untracked is an independent project and is **not** affiliated with, endorsed by,
or supported by Toggl OÜ.
