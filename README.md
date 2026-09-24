# unstuck — iOS

Native SwiftUI app for **unstuck**, an external executive-function layer
for ADHD. The goal is a **1:1 behavioral replica of the Android app**
(`../unstuck_android`) — Android is the reference client; the
authoritative spec is
[`unstuck_android/docs/ios-rebuild-spec/`](../unstuck_android/docs/ios-rebuild-spec/)
(15 sections — where any doc disagrees with Android, follow Android) —
plus the iOS-native surfaces (push notifications, home/lock widgets,
Live Activities / Dynamic Island, iOS Focus Filter). It shares the
Supabase backend (project `uaxfteluwctrlgwmmfzi`) that lives in the web
repo ([github.com/btambaya/Unstuck](https://github.com/btambaya/Unstuck)).

> Status: **working build, near Android parity.** Full data + sync +
> design foundation (`UnstuckCore` / `UnstuckData` / `UnstuckSync` /
> `UnstuckDesign` / `UnstuckShared`, **250 tests**); the app + widget
> extension build and launch on the iOS simulator. All feature surfaces
> (Today, Tasks, Focus, Calendar, Lists/Collections + sharing, Settings,
> Insights, Onboarding, Command palette) and native surfaces (push,
> Start Next widget, Focus Live Activity / Dynamic Island, Focus Filter)
> are wired; the spec-§10 notification subsystem (reminder scheduler,
> Notification Center, levels, action routing) and the audit-driven sync
> hardening (poison-pill outbox, per-row FIFO, sign-out drain +
> push-token unregister, scenePhase/BG-refresh sync triggers, Google
> pull reconcile, privacy manifest) landed 2026-06-09. The assistant
> (agentic chat + realtime voice, rebuilt to the web cockpit on 2026-08-02)
> became the AI gateway on 2026-09-02: cross-device memory (`profile_facts`),
> the same 56 tools and honest harness as the web, a gateway card on Today
> with a first-run interview, Settings → Assistant & privacy → "What Unstuck
> remembers" (Settings is slim since 2026-09-24: Account, Notifications &
> calls, Assistant & privacy, People, Appearance), and "Unstuck
> calls you" (CallKit + VoIP push, calls booked by voice, text, or the task
> editor). Talk's audio engine restarts on iOS configuration changes as of
> build 52 (it used to die 100 ms in on real devices). Sharing is ONE Share
> screen for tasks and lists (2026-09-17, unified sharing v1): People /
> Someone new (email — shared at once or invited) / Share a link, "Can edit"
> or "Can view", honest result lines, "Hand over to…" for assigning a task,
> and a push on a task shared with you opens that task. Remaining gaps: the
> on-device call validation and the manual
> deploy/capability steps — see [`handover.md`](handover.md) for the honest list.

## Architecture

A thin Xcode app target (added in a later phase) + local Swift package
(`UnstuckKit`, this repo root) split into layers so the logic builds and
tests with no Xcode project or code signing:

| Module | Role | Status |
|---|---|---|
| `UnstuckCore` | Pure domain models + full logic layer incl. reminder planning + calendar-pull reconcile (no UI/Supabase) | ✅ done + tested (204 tests) |
| `UnstuckData` | GRDB local store + outbox + live session | ✅ done + tested (16 tests) |
| `UnstuckSync` | supabase-swift wiring + offline-first sync engine (flusher hardening tested via a gateway fake) | ✅ done (22 tests; networked paths runtime-validated in-app) |
| `UnstuckDesign` | Brand-v2 oklch tokens + Theme + SwiftUI components | ✅ done (8 tests) |
| `UnstuckShared` | App-Group snapshot + Live Activity attributes + Focus Filter flag | ✅ done |
| App `App/Features/*` + `App/Notifications/*` | Today, Tasks (+recurrence), Focus (+treatments/reasons/captures), Calendar (+Google connect/pull/push), Lists/Collections (+sharing), Tags & Areas, Insights, Settings, Onboarding, Command palette, reminder scheduler + Notification Center | ✅ built |
| `Widgets/` | Start Next widget + Focus Live Activity / Dynamic Island | ✅ builds |

**Offline-first**: a local store drives the UI; Supabase is canonical.
The sync engine is the port of the Android engine specced in
[`02-sync-engine.md`](../unstuck_android/docs/ios-rebuild-spec/02-sync-engine.md):
hydrate = server-canonical replace-per-table (preserving external
`g_` blocks + locally-pending optimistic blocks), realtime mirror,
write-through + outbox for offline mutations (dependency-ordered,
per-row FIFO, FAIL_CAP poison pill). Sign-out drains the outbox,
unregisters the device push token, and clears everything local.

**One freshness owner.** Realtime is an optimisation, never the
correctness path: `postgres_changes` has no replay and a channel can
report `SUBSCRIBED` while delivering nothing. `UnstuckSync/
FreshnessOwner.swift` is the single component that answers "am I in
step?"; realtime, the app lifecycle, an `NWPathMonitor` and a 60s floor
interval all REPORT to it and nothing else schedules a refresh. It
coalesces overlapping triggers into one in-flight pull, runs the
cursor-based catch-up (`CatchUpPuller` + the `sync_cursors` high-water
marks — a delta read per table plus a paged id sweep for deletions,
never clobbering a pending local write), keeps the full hydrate for cold
start, and detects a deaf-but-"healthy" channel two ways (silence, and a
catch-up finding a change realtime never delivered) — rebuilding the
subscriptions and counting it in `FreshnessStats`.

### Name mappings (web → Swift)

To avoid clashing with Swift standard types, two domain types are renamed:

- web `Task` → `TaskItem` (Swift Concurrency owns `Task`)
- web `Collection` → `ItemCollection` (stdlib owns `Collection`)

All other types keep their web names. Logic ports keep the shared
function names (`pickStartNext`, `visibleTasks`, `isSlipping`, … — the
same names Android's `:core` uses) and mirror the web's `lib/*.test.ts`
cases / Android's `:core` JUnit parity suite as XCTest so behavior stays
in lockstep across all three clients.

## Requirements

- Xcode 26.3+ / Swift 6.2 (Swift tools 6.0)
- iOS 17+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to generate the app project

## The app

The iOS app target is generated from [`project.yml`](project.yml) (the
`.xcodeproj` is gitignored). Generate + build:

```sh
xcodegen generate
xcodebuild -project Unstuck.xcodeproj -scheme Unstuck \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

App sources live in [`App/`](App): `UnstuckApp` (composition root) →
`AppModel` (builds the store + `SyncCoordinator`, observes auth) →
`RootView` → `MainTabScaffold` (Today · Tasks · [+FAB] · Calendar · Lists).
The +FAB creates whatever surface you're on — New task on Today/Tasks/Calendar,
New collection on the Collections grid, and inside a collection it focuses that
collection's inline add field. The decision is `AppRouter.fabAction`.
Config comes from `App/Config.xcconfig` (committed; `SUPABASE_HOST`) +
`App/Secrets.xcconfig` (gitignored; `SUPABASE_ANON_KEY`). Until those are
set the app launches to a setup screen.

## Build & test

```sh
# Run the full logic test suite with coverage (TZ=UTC = deterministic
# date/bucket math, matching the web CI).
TZ=UTC swift test --enable-code-coverage

# Coverage report for the package sources:
BIN=$(swift build --show-bin-path)
xcrun llvm-cov report \
  "$BIN/UnstuckKitPackageTests.xctest/Contents/MacOS/UnstuckKitPackageTests" \
  -instr-profile "$BIN/codecov/default.profdata" \
  -ignore-filename-regex='Tests|\.build'
```

CI (`.github/workflows/ci.yml`) runs the same on every push/PR.

## Siri / App Intents

OS-level voice control + queries live in [`App/Intents/`](App/Intents) (plus the
widget-button intents in [`Widgets/WidgetIntents.swift`](Widgets/WidgetIntents.swift)).
`UnstuckShortcuts` (`AppShortcutsProvider`) declares ~10 zero-setup Siri phrases;
no Siri entitlement is required for App-Shortcut intents.

- **Reads** (hands-free, no app launch) speak from the App-Group `UnstuckSnapshot`
  the app writes on launch / foreground / background / BG-refresh: "how many
  tasks left", "what's next", "what's on today".
- **Writes** (hands-free) enqueue a `PendingWrite` to the App Group; the app
  applies them via its normal mutators in `AppModel.drainSiriWriteQueue()` on next
  run (eventual consistency — lands in seconds, else on next launch). Covers
  create task, capture, complete (TaskEntity), add-to-list (CollectionEntity).
- **Open-app** intents (Start focus, Open today, Ask Unstuck) stash a route in the
  App Group consumed on `scenePhase=.active` — the same hand-off `WorkFocusFilter`
  uses, since a background `perform()` can't drive SwiftUI navigation.
- **Ask Unstuck** bridges freeform requests to the in-app Qwen assistant (Apple's
  Siri has no third-party task domain).

The bridge is the App Group (`UnstuckShared/AppGroup.swift`): App Intents run in a
separate process and can't touch the app-private GRDB store or Keychain session,
so all read/write goes through the shared snapshot + write-queue.

## Backend & spec

The shared Supabase backend lives in the **web** repo under
`unstuck/supabase/` (migrations + Edge Functions). iOS-specific backend
additions (push tokens, notification scheduling, APNs) land there too —
this repo consumes them.

The **behavioral** spec lives in the **Android** repo:
[`unstuck_android/docs/ios-rebuild-spec/`](../unstuck_android/docs/ios-rebuild-spec/)
— 15 sections covering data model, sync engine, every surface,
notifications, and backend contracts, generated from the live Android
Kotlin. Android is the reference client; consult the spec (and the
Android sources at `../unstuck_android`, read-only) before changing
sync or feature behavior here.
