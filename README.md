# unstuck — iOS

Native SwiftUI app for **unstuck**, an external executive-function layer
for ADHD. This is the iOS sibling of the web app
([github.com/btambaya/Unstuck](https://github.com/btambaya/Unstuck)) and
shares its Supabase backend (project `uaxfteluwctrlgwmmfzi`). The goal is
**full feature parity with the web app** plus native surfaces (push
notifications, home/lock widgets, Live Activities / Dynamic Island, iOS
Focus Filter).

> Status: **early build.** `UnstuckCore` (domain models + the full
> pure-logic layer ported from the web `lib/*`) is complete and tested —
> 174 tests, ~97% line coverage. Data/sync, UI, and native surfaces are
> next — see [`handover.md`](handover.md) for the live state.

## Architecture

A thin Xcode app target (added in a later phase) + local Swift package
(`UnstuckKit`, this repo root) split into layers so the logic builds and
tests with no Xcode project or code signing:

| Module | Role | Status |
|---|---|---|
| `UnstuckCore` | Pure domain models + full logic layer (no UI/Supabase) | ✅ done + tested (174 tests) |
| `UnstuckData` | GRDB local store + outbox | ⏳ planned |
| `UnstuckSync` | supabase-swift wiring + offline-first sync engine | ⏳ planned |
| `UnstuckDesign` | Brand-v2 tokens + SwiftUI components | ⏳ planned |
| `UnstuckShared` | App-Group snapshot shared with widgets/Live Activity | ⏳ planned |
| `UnstuckFeatures` | SwiftUI feature modules (the ~41 screens) | ⏳ planned |

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
