# Untracked — guidance for AI assistants

A macOS menu-bar app that flashes a pulsing overlay when you're **not** tracking time in Toggl, so you stop forgetting to start the timer. User-facing docs are in `README.md`; this file is the agent-facing brief — the non-obvious stuff.

## Core philosophy (non-negotiable)

Priority order: **Energy > Memory > Binary size.**

- **Event-driven, never polling.** Before adding any `Timer`/poll loop, prove no event-driven alternative exists. The only repeating timer is a 120s **fallback** (high tolerance, backstop), and it runs *only while monitoring*. Work-hours boundaries use a single **dated one-shot** timer (`scheduleBoundary`), not polling — plus wake/clock/timezone notifications to re-arm across sleep.
- Detection wakes on **FSEvents** (Toggl DB writes); config + Focus wake on **kqueue** file watches. A running timer changes nothing on disk → app idles.
- **Monitoring is gated** (`updateMonitoring`/`isHardSuppressed`): when paused or outside work hours we **stop the watcher, fallback, and SuppressionMonitor entirely** — nothing reacts to Toggl, lock, or Focus events — and show an off-duty (🌙) icon. `isHardSuppressed` is only paused/work-hours (not away/Focus, which don't gate monitoring — they just hide the overlay while it runs). Never do work when a nag is impossible.
- The heartbeat is **duty-cycled**: a short one-shot beat on a timer, fully static between beats. Do **not** replace it with an always-on `CAAnimation` (that recomposites every frame — measured ~2.4% CPU; the duty-cycle is ~0%).
- Targets: **~0% idle CPU, ~18 MB** private memory (`top` MEM column / phys footprint; RSS ~58 MB is mostly shared AppKit pages). Measured idle: 0 CPU, **0 disk writes, 0 idle wakeups** over minutes — the priority-1 energy metrics are effectively perfect, so keep them there. The ~18 MB floor is irreducible AppKit/Foundation dirty pages (~12 MB) + malloc heap (~5 MB); it is **not** overlay or menu memory, and there is nothing left to reclaim. Don't chase a smaller number by tearing down live infrastructure — it buys nothing and costs latency.
- **Overlay windows are intentionally lazy — do not "optimize" this.** `OverlayController.show()` builds the windows; `hide()`/`teardown()` calls `orderOut` **and** `windows.removeAll()`, so the windows and their CoreAnimation/Metal backing fully deallocate. Idle carries **zero** overlay cost; an active nag adds only ~0.3–0.5 MB **per screen** (the full-screen border's surface lives in WindowServer's IOSurface, not our footprint), all released on hide — verified by profiling. The menu is a few KB, so lazy-loading it saves nothing. The heaviest resource is already allocated only while nagging.

## Build & run

- `./build.sh` (build) or `./build.sh --install` (build → /Applications → launch).
- Toolchain: **XcodeGen** (`project.yml`) → `xcodebuild`. Edit `project.yml`, not the generated `.xcodeproj` (gitignored).
- Signing: team **`3T9RX85H44`**, bundle id `com.emrikol.Untracked`, automatic.
- Release strips symbols (`STRIP_STYLE=all` + `DEPLOYMENT_POSTPROCESSING`) → **~222 KB** (single-arch arm64; verified stripped — zero local symbols, `__text` ≈ 92 KB). An earlier ~118 KB figure here was from the initial commit and went stale as the defensive logic grew; stripping was never the problem. Binary size is the **lowest** priority of the three — don't trade energy or clarity for it.
- The app icon is **generated** by `scripts/make-icon.swift` during `build.sh` (red ECG/heartbeat on a dark rounded square) → `Resources/AppIcon.icns` (gitignored). It must be generated **before** `xcodegen generate` (build.sh ordering handles this).
- `LSUIElement` — menu-bar only, no Dock icon.
- `build.sh` runs **`scripts/check-invariants.sh`** first and fails the build on any violation. It runs the project-specific invariant checks, then **SwiftLint** (`--strict`) and **shellcheck**. Prose rules get forgotten: the snooze deadline shipped with the exact clock-rollback bug the written rule already forbade, which is why the gate exists. To use civil time deliberately, add `// wall-clock: <reason>` on the line or either of the two above it.
- **Static analysis is expected to sit at zero.** The pieces, and what each is for:
  - `SWIFT_STRICT_CONCURRENCY: complete` — the important one. This app's real risk is concurrency (three queues + main thread, cross-thread state guarded by generation tokens), and this makes the compiler verify the confinement instead of trusting comments. UI types are `@MainActor`; `TogglWatcher`/`ConfigStore`/`SuppressionMonitor` are documented `@unchecked Sendable`. **Don't downgrade this to silence a new error — the error is the point.**
  - `SWIFT_TREAT_WARNINGS_AS_ERRORS` — a warning nobody must read is one that accumulates.
  - `.swiftlint.yml` — 232 of 251 rules on, at zero violations. **Mutually exclusive pairs are the thing to understand here**: several rules are direct inverses, and enabling both halves is worse than enabling neither, because no way of writing the code passes. Each pair is resolved toward the option the ecosystem and SwiftFormat already produce (`opening_brace`, `redundant_type_annotation`, `redundant_self`, `no_extension_access_modifier`, `discouraged_object_literal`) — see the block comment above `disabled_rules`. `explicit_enum_raw_value` vs `redundant_string_enum_value` is the exception: both stay on, because they collide on exactly one declaration.
  - **Every `swiftlint:disable` must state a reason** after a dash, and the gate rejects any that doesn't. `superfluous_disable_command` separately proves each one is still load-bearing, so an exemption can't quietly become dead permission. There are six, all narrow: two format specifications (`#RRGGBBAA` parsing, the heartbeat's animation curve), the persisted-raw-value and wire-format annotations, the snooze menu's own durations, and one CoreAnimation `[NSNumber]` bridge.
  - Tuning constants are **named**, not inline — `Timing` in `main.swift`, `Look` in `OverlayController`, and the retry/clamp constants in the stores. They're the energy knobs, so `no_magic_numbers` is on to keep them that way.
  - **When a lint rule refuses to stay satisfied, suspect SwiftFormat first.** Five of its rules silently undo a SwiftLint requirement: `redundantRawValues`, `numberFormatting`, `redundantInternal`, `redundantExtensionACL` and `extensionAccessControl`. All are disabled, and `swiftformat <file> --lint --verbose` names the rule responsible.
  - `.swiftformat` — **pinned in-repo**, and load-bearing: SwiftFormat *produces* the layout SwiftLint *verifies*. Without this file the style depended on whatever editor hook happened to be installed. Several settings exist purely to make the two agree (`wrapConditionalBodies`, `--wrapconditions before-first`, `--funcattributes prev-line`, `--decimalgrouping 3,4`, `--disable wrapMultilineStatementBraces`). **If a layout rule starts failing, the fix is almost always a `.swiftformat` setting, not a `disabled_rules` entry.** Verified idempotent: format twice, lint stays at zero.
  - `./scripts/format.sh` — the only thing that rewrites source: `swiftlint --fix` (semantic) then `swiftformat` (layout, last word). Deliberately not in `build.sh`; a build that rewrites its inputs isn't reproducible, and this project already has a scar from exactly that (see the SwiftFormat gotcha above).
  - `.githooks/pre-commit` — blocks the commit until the gate is clean. Run `./scripts/install-hooks.sh` once per clone to set `core.hooksPath`; a hook that lives only in one `.git/hooks` isn't a gate.
  - `swiftlint analyze` — four extra rules needing a compiler log, so it's **not** in the build. Run periodically: `xcodebuild … clean build > /tmp/c.log && swiftlint analyze --strict --compiler-log-path /tmp/c.log`.
  - `scripts/run-tsan.sh` — Thread Sanitizer, deliberately manual: it needs a human to exercise lock/Focus/pause-resume, and the teardown-and-restart paths (where the generation tokens earn their keep) are the ones worth attention.

## Architecture (Sources/)

| File | Owns |
|------|------|
| `main.swift` | Singleton `flock` guard + entry point only (26 lines) |
| `AppDelegate.swift` | Orchestration, monitoring lifecycle, suppression/grace/pause, menu and status presentation |
| `Notifier.swift` | One-time user notifications |
| `ConfigStore.swift` | Loads/persists/hot-reloads `~/.untracked.json` (kqueue) |
| `TogglLocalStore.swift` | Reads Toggl's SQLite (read-only, in place) → `TrackingState` |
| `TogglWatcher.swift` | FSEvents watcher on Toggl's DB dir → calls back with state |
| `OverlayController.swift` | Borderless click-through overlay windows + duty-cycled heartbeat; `AlertStyle` |
| `Settings.swift` | `Settings` model (Codable, lenient) + hex colour parsing |
| `SuppressionMonitor.swift` | Away (lock/sleep/session) via notifications + Focus/DnD via kqueue file watch |
| `Uptime.swift` | Monotonic clock for measuring durations (never use `Date` for elapsed time) |

State flow: `TogglWatcher`/fallback → `apply(state)` → `evaluateOverlay()` (the single place that decides show/hide/tint). Settings + suppression changes also funnel into `evaluateOverlay()`.

## The two fragile, undocumented dependencies

Both are private files with no API. Both **fail safe**. If Toggl or macOS updates break them, this is where to look.

1. **Toggl running state** — `~/Library/Group Containers/B227VTMZ94.group.com.toggl.daneel.extensions/production/DatabaseModel.sqlite` (the modern `com.toggl.daneel` app's Core Data store, also read by its own widget). **Rule: a running entry is the single non-deleted `ZMANAGEDTIMEENTRY` row with `ZDURATION_CURRENT IS NULL`** (this client does NOT use the API's negative-duration sentinel). We query the live store **read-only, in place** (WAL readers don't block/aren't blocked by Toggl's writer). Fix path/query in `TogglLocalStore.swift`. Failure → `.unavailable` → no nag (and a one-time "may need a fix" notification if Toggl is running).

2. **Focus / Do Not Disturb** — `~/Library/DoNotDisturb/DB/Assertions.json`. **Heuristic: active iff a non-empty `storeAssertionRecords` exists under `data`.** Fix in `SuppressionMonitor.swift`. **Fails open** (can't read → "not in Focus" → still nags), so a break never silently disables the core nag.

## macOS gotchas (learned the hard way)

- **You cannot recolor another app's window chrome** at any privilege level (process isolation + code-signing; root doesn't help). That's why we paint our own click-through overlay instead of "flashing Toggl's title bar."
- **Reading the Toggl group container needs NO Full Disk Access** — verified by launching via `open` (own TCC context, no inherited FDA). Don't add FDA prompts.
- **No usable public Focus API.** `INFocusStatusCenter` exists but needs the Communication-Notifications entitlement + an auth prompt and **cannot be subscribed to** (KVO doesn't work; you'd have to poll). We deliberately use the kqueue file-watch instead — instant, permission-free.
- **SwiftFormat (PostToolUse hook) renames "unused" function params to `_`.** This bit `make-icon.swift` when a local shadowed a param. If a param looks unused, it'll be rewritten — make sure it's actually referenced.
- **`os.Logger` `.info` is not persisted** to the unified log store, so `log show` won't find it. Use `.notice`, or `fputs(..., stderr)` + run the binary directly, when debugging. (The app logs state transitions at `.notice`.)
- `xcodebuild` may abort with a stale `IDESimulatorFoundation`/`DVTDownloads` plugin error after a partial Xcode update — fix with `xcodebuild -runFirstLaunch`.

## Conventions

- **`~/.untracked.json` is the single source of truth** for settings. Menu actions (style, flash toggles) call `config.mutate { … }`, which writes the file and applies via `onChange`. Everything hot-reloads; don't add a parallel `UserDefaults` path (the only `UserDefaults` use is the one-time `initialLoginConfigured` first-run flag).
- Settings decode **leniently** — any missing key keeps its default, so partial configs and forward/backward compat just work. Add new keys with an inline default + a `CodingKeys` case + a `decodeIfPresent` line.
- `evaluateOverlay()` is the one decision point for the overlay. Route new show/hide conditions through it, not through scattered `overlay.show/hide`.
- **Measure durations with `Uptime.now()`, never `Date`.** The app subscribes to `NSSystemClockDidChange`, so backward wall-clock corrections are a normal input. `Date` math turned a 3 s read throttle into 3603 s and a 45 s grace into 3645 s — both computed a delay as `interval - elapsed`, and `elapsed` went negative. Keep a `Date` alongside only when the value is *displayed* ("not tracking for 12m"), or when the deadline genuinely is a wall-clock instant (the work-hours boundary: 9am means 9am).
- **Watch arming is `open()`-result-driven, not `fileExists()`-driven.** Both kqueue watchers (config, Focus) select a target then `open` it — two syscalls, and atomic replace is exactly what unlinks the inode in between. A failed open must fall back (Focus → parent dir) or re-select and retry (config), never return unarmed: that silently kills hot-reload / Focus for the whole generation. Both stay event-driven — do not "fix" this with a retry timer.

## Accepted trade-offs / not done

- Overlay uses `.screenSaver` window level so it shows over full-screen apps; the cost is it can briefly draw over an open menu. Lower to `.statusBar` to flip that.
- Local-only by design: reflects **this Mac's** synced Toggl state. Tracking only on phone with the Mac app closed is invisible to us (acceptable for the forget-at-my-desk use case).
- No tests. Verification has been via standalone `swift` probes (compile a source file + a tiny `main.swift` that prints) — see git history / conversation.
- **First-run Launch-at-Login prompts at most once.** If the service comes back `.requiresApproval`, we persist `initialLoginConfigured` *before* opening the Login Items pane, so a postponed/declined approval doesn't re-seize System Settings on every launch. The menu item is the retry path (and it completes the register→approve handoff in one click). Deliberate: not pushy.
- **`build.sh --install` stages then swaps**, so a failed copy leaves the working install intact. Not covered: if the final same-directory `mv` itself fails, the EXIT trap removes the staged copy and the old bundle is already gone — you'd lose both and have to re-run. Accepted; a same-volume rename failing is vanishingly rare and recovery is one command. Fix would be backup-and-restore in the trap.
- **A failed FSEvents stream setup isn't retried within a monitoring generation.** We still take an authoritative read and keep working off the 120 s fallback, and a pause / work-hours re-gate starts a fresh generation that retries. Accepted: adding a retry path for a rare, self-healing failure isn't worth the complexity.

## House rules

- Don't commit or push without explicit user permission.
- Keep it single-purpose. New features should be config-driven and fail safe.
