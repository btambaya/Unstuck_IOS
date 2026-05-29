# unstuck — iOS

Native SwiftUI app for **unstuck**, an external executive-function layer
for ADHD. This is the iOS sibling of the web app
([github.com/btambaya/Unstuck](https://github.com/btambaya/Unstuck)) and
shares its Supabase backend (project `uaxfteluwctrlgwmmfzi`). The goal is
**full feature parity with the web app** plus native surfaces (push
notifications, home/lock widgets, Live Activities / Dynamic Island, iOS
Focus Filter).

> Status: **working build.** Full data + sync + design foundation
> (`UnstuckCore` / `UnstuckData` / `UnstuckSync` / `UnstuckDesign` /
> `UnstuckShared`, 210 tests); the app + widget extension build for the
> iOS simulator; feature surfaces (Today, Tasks, Focus, Calendar, Lists,
> Settings, Insights) + native surfaces (push, Start Next widget, Focus
> Live Activity / Dynamic Island, Focus Filter, paused-checkin) are wired;
> the notification DB backend (migrations 014–016) is applied + the push
> Edge Functions are written. Remaining = feature polish + the manual
> deploy/capability steps — see [`handover.md`](handover.md).

## Architecture

A thin Xcode app target (added in a later phase) + local Swift package
(`UnstuckKit`, this repo root) split into layers so the logic builds and
tests with no Xcode project or code signing:

| Module | Role | Status |
|---|---|---|
| `UnstuckCore` | Pure domain models + full logic layer (no UI/Supabase) | ✅ done + tested (174 tests) |
| `UnstuckData` | GRDB local store + outbox + live session | ✅ done + tested (15 tests) |
| `UnstuckSync` | supabase-swift wiring + offline-first sync engine | ✅ done (13 tests; networked paths runtime-validated in-app) |
| `UnstuckDesign` | Brand-v2 oklch tokens + Theme + SwiftUI components | ✅ done (8 tests) |
| `UnstuckShared` | App-Group snapshot + Live Activity attributes + Focus Filter flag | ✅ done |
| App `App/Features/*` | SwiftUI surfaces (Today, Tasks, Focus, Calendar, Lists, Settings, Insights) | 🔨 in progress |
| `Widgets/` | Start Next widget + Focus Live Activity / Dynamic Island | ✅ builds |

**Offline-first**: a local store drives the UI; Supabase is canonical.
The sync engine mirrors the web's `lib/sync/*` contract (hydrate =
server-canonical replace-per-table; realtime mirror; write-through +
outbox for offline mutations).

### Name mappings (web → Swift)

To avoid clashing with Swift standard types, two domain types are renamed:

- web `Task` → `TaskItem` (Swift Concurrency owns `Task`)
- web `Collection` → `ItemCollection` (stdlib owns `Collection`)

All other types keep their web names. Logic ports keep the web function
names (`pickStartNext`, `visibleTasks`, `isSlipping`, …) and mirror the
web's `lib/*.test.ts` cases as XCTest so behavior stays in lockstep.

## Requirements

- Xcode 26.3+ / Swift 6.2 (Swift tools 6.0)
- iOS 17+ deployment target
- [XcodeGen](https://github.com/yonohub/XcodeGen) (`brew install xcodegen`) to generate the app project

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

## Backend

The shared Supabase backend lives in the **web** repo under
`unstuck/supabase/` (migrations + Edge Functions). iOS-specific backend
additions (push tokens, notification scheduling, APNs) land there too —
this repo consumes them.
