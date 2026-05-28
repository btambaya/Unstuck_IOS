# Handover — unstuck_ios

Living doc for resuming the iOS build across sessions. Update it as
phases land. Newest status at the top.

## Where things stand (2026-05-29)

**P0 (Foundation) + UnstuckCore (full logic layer) + UnstuckData (local
store): DONE.** UnstuckSync (the other half of P1) is next.

- Repo initialized; SwiftPM package `UnstuckKit` builds and tests
  standalone (no Xcode project / signing needed yet).
- `UnstuckCore` is **complete**: domain models + ALL pure-logic ports
  from the web `lib/*`.
- `UnstuckData` is **done**: GRDB (7.10.0, pinned in Package.resolved)
  local store — `AppDatabase` (migrator + in-memory/on-disk factories),
  GRDB conformances for all 8 synced Core models (JSON columns for
  arrays/Codable, raw strings for enums), `OutboxStore` (FIFO +
  dependency-ordered `nextFlushable`), `LiveSessionStore` (single-row
  device-local), `TaskRepository` (CRUD + `observeAll` ValueObservation).
- Green: **189 tests** (174 Core + 15 Data); ~97% line cov on Core.
  `TZ=UTC swift test --enable-code-coverage`.
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
  Support/CivilDate.swift          # JS Date(y,m,d) local arithmetic + getDay (0=Sun)
  Logic/UUID.swift                 # newUUID(), isUUID()             ← lib/uuid.ts
  Logic/CalBlockKind.swift         # blockKind/isTaskBlock/…         ← lib/cal-block-kind.ts
  Logic/TaskBucket.swift           # isCompletedToday/isCreatedToday ← lib/task-bucket.ts
  Logic/VisibleTasks.swift         # visibleTasks/matchesArea/isSlipping/… ← lib/visible-tasks.ts
  Logic/PickStartNext.swift        # pickStartNext/pickUpNext        ← lib/pick-start-next.ts
  Logic/Recurrence.swift           # materialize/regenerate/label     ← lib/recurrence.ts
  Logic/FreeSlots.swift            # findFreeSlots/findConflicts/…    ← lib/free-slots.ts
  Logic/FocusTimer.swift           # pure timer reducers + derivations← lib/use-focus-timer.ts
  Logic/Analytics.swift            # all chart/insight derivations    ← lib/analytics.ts
  Logic/AuthErrors.swift           # humanizeAuthError/nextSafePath   ← lib/auth-helpers.ts
  Logic/GoogleSyncMapping.swift    # externalEventToBlock/…           ← lib/sync/google-sync.ts
  Logic/TaskMutations.swift        # completedAt stamp + bumpMoveCount← lib/use-tasks.ts
Tests/UnstuckCoreTests/            # 1:1 ports of the web *.test.ts where they exist
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

**P1 second half — UnstuckSync** (task #30). UnstuckData is done; add the
sync engine. Repositories for the remaining 7 entities follow
`TaskRepository` verbatim (mechanical) — add as features need them.

- `UnstuckSync`: depends on **supabase-swift** (~v2.46) + UnstuckData +
  UnstuckCore. SupabaseClientProvider, AuthService (PKCE + `unstuck://`
  deep links + Google app sign-in), Hydrator (server-canonical
  replace-per-table, preserve local `g_*` external blocks), RealtimeMirror
  (postgres_changes per table; skip calendar_connections), WriteThrough +
  OutboxFlusher (dependency ordering: cal_block op `dependsOn` task.id),
  SyncCoordinator (authStateChanges → hydrate→subscribe→autosync; cache
  wipe rules). Snake_case ↔ camelCase: use `keyDecodingStrategy =
  .convertFromSnakeCase` (or explicit CodingKeys) in the Sync layer —
  Core models stay as-is. Reuse the Core logic (uuid gate, mappings).

Port references (read-only in `../unstuck`): `lib/sync/bridge.ts`,
`lib/sync/hydrate.ts`, `lib/sync/realtime.ts`,
`lib/supabase/bootstrap-listener.tsx`, `lib/sync/calendar-sync.ts`,
`lib/use-sync-status.ts`, `lib/storage-keys.ts` (synced-vs-device split).

Tests to add in P1: outbox FIFO + dependency ordering; hydrate
replace-per-table (only successful tables replaced; failed left intact);
external-block preservation.

Then UI (task #31): `UnstuckDesign` + the Xcode app project + the
SwiftPM packages wired in; then features (P2–P6, task #32); then backend
+ native surfaces (task #33).

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
TZ=UTC swift test --enable-code-coverage     # 174 tests, all green, ~97% line cov
```
