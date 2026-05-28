# Handover — unstuck_ios

Living doc for resuming the iOS build across sessions. Update it as
phases land. Newest status at the top.

## Where things stand (2026-05-28)

**Phase P0 (Foundation) + first slice of UnstuckCore: DONE.**

- Repo initialized; SwiftPM package `UnstuckKit` builds and tests
  standalone (no Xcode project / signing needed yet).
- `UnstuckCore` domain layer + the first, most test-covered logic ports
  are complete and green: **66 tests, 98% line / 94% region coverage**
  (`TZ=UTC swift test --enable-code-coverage`).
- CI runs the suite + prints coverage on every push/PR.

### What exists

```
Package.swift                      # UnstuckKit; product: UnstuckCore
Sources/UnstuckCore/
  Models/Enums.swift               # Priority, FocusState, CalBlockKind, CaptureTag, …
  Models/Supporting.swift          # Objective, Comment, Recurrence (tagged-union Codable),
                                   #   TagRow, CollectionItem, ItemCollection
  Models/TaskItem.swift            # the task entity (web `Task`)
  Models/Entities.swift            # Session, CalBlock, ReasonLog, Capture,
                                   #   CalendarConnection, ExternalEvent, LiveSession
  Support/Time.swift               # Time.parseMillis / startOfDayMillis; Clock.todayISO/dateISO
  Logic/UUID.swift                 # newUUID(), isUUID()             ← lib/uuid.ts
  Logic/CalBlockKind.swift         # blockKind/isTaskBlock/…         ← lib/cal-block-kind.ts
  Logic/TaskBucket.swift           # isCompletedToday/isCreatedToday ← lib/task-bucket.ts
  Logic/VisibleTasks.swift         # visibleTasks/matchesArea/isSlipping/… ← lib/visible-tasks.ts
  Logic/PickStartNext.swift        # pickStartNext/pickUpNext        ← lib/pick-start-next.ts
Tests/UnstuckCoreTests/            # VisibleTasksTests is a 1:1 port of lib/visible-tasks.test.ts
.github/workflows/ci.yml
```

### Key conventions (don't break these)

- **Web → Swift renames:** `Task`→`TaskItem`, `Collection`→`ItemCollection`.
  Everything else keeps web names; logic keeps web function names.
- **Time:** timestamps are ISO strings; date math is LOCAL
  (`Calendar.current` / `TimeZone.current`) exactly like JS `Date`; ISO
  strings compared lexicographically (`<`) to match `localeCompare`.
  `EpochMillis = Double` everywhere `now` is passed.
- **Determinism:** run tests with `TZ=UTC` (CI does). The ported web
  cases mix a fixed `NOW` (May 21) with the real `todayDateIso()`; this
  is intentional and only stays consistent under a fixed TZ.
- **Stable sort:** `visibleTasks` partitions open-before-done by hand
  because Swift's `sort` isn't guaranteed stable (the web relies on V8's
  stable sort).

## Next up

**Finish UnstuckCore logic ports** (task #29 — same package, add files +
mirrored tests, keep each commit green):

1. `Recurrence` logic ← `lib/recurrence.ts` + `recurrence.test.ts`
   (⚠ 8-week HORIZON materialization, regen future-only, weekday 0=Sun).
2. `FreeSlots` ← `lib/free-slots.ts` + `free-slots.test.ts`.
3. `FocusTimer` (pure state/derivations) ← `lib/use-focus-timer.ts` +
   `use-focus-timer.test.ts` (states, `priorAccumulatedSec`, overrun).
4. `Analytics` ← `lib/analytics.ts` + `analytics.test.ts`.
5. `AuthErrors` (`humanizeAuthError`) ← `lib/auth-helpers.ts` +
   `auth-helpers.test.ts`.
6. `GoogleSyncMapping` ← `lib/sync/google-sync.ts` + `google-sync.test.ts`.
7. `bumpMoveCount` + `completedAt` first-flip rules ← `lib/use-tasks.ts`
   (+ `task-completion.test.ts`).

Then **P1** (task #30): add `UnstuckData` (GRDB + outbox) and
`UnstuckSync` (supabase-swift auth + Hydrator/RealtimeMirror/
WriteThrough/OutboxFlusher/SyncCoordinator). This adds external SPM deps
(GRDB.swift, supabase-swift) to `Package.swift`. Snake_case ↔ camelCase
mapping for PostgREST happens in UnstuckSync (keyDecodingStrategy or
explicit CodingKeys) — Core models stay as-is.

Full roadmap + rationale: the build plan at
`~/.claude/plans/streamed-juggling-book.md` (in the agent's plan dir).

## Repo / backend facts

- Remote: `github.com/btambaya/Unstuck_IOS.git`, branch `main`.
- Web app (port source + executable spec): `../unstuck`
  (`github.com/btambaya/Unstuck.git`).
- Supabase project ref: `uaxfteluwctrlgwmmfzi`; schema migrations 001–013
  live in `../unstuck/supabase/`. iOS backend additions (014–016 + push
  Edge Functions) will also land in `../unstuck/supabase/`.
- Planned bundle id `tech.csalliance.unstuck`; App Group
  `group.tech.csalliance.unstuck`.
- Note: `~/Desktop/.git` is a stray repo (remote `focus-app.git`); this
  repo's own `.git` overrides it inside `unstuck_ios/`.

## How to verify

```sh
cd unstuck_ios
TZ=UTC swift test --enable-code-coverage     # 66 tests, all green
```
