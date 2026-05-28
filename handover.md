# Handover — unstuck_ios

Living doc for resuming the iOS build across sessions. Update it as
phases land. Newest status at the top.

## Where things stand (2026-05-29)

**P0 + P1 (Core/Data/Sync) + UnstuckDesign + the Xcode app shell: DONE.**
The app **builds for the iOS simulator** (`xcodebuild … BUILD SUCCEEDED`),
wiring the whole stack together. Feature screens (P2–P6, task #32) next.

- `UnstuckDesign`: exact oklch→sRGB converter (unit-tested), the full
  brand-v2 palette (light+dark) + `UTheme` env, fonts, and components
  (Mark/Wordmark/AreaDot/UButton/Chip/Card/SectionLabel).
- App (`App/`, generated via XcodeGen from `project.yml`): UnstuckApp →
  AppModel (builds AppDatabase + SyncCoordinator from Config.xcconfig,
  observes auth) → RootView → MainTabScaffold (5-item bar + coral FAB) +
  AuthView + feature stubs. `.onOpenURL` → `auth.handleCallback`.
  Bundle id `tech.csalliance.unstuck`, `unstuck://` scheme.

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
- `UnstuckSync` is **done** (supabase-swift 2.46.0, pinned): DbRowCodec
  (PostgREST snake_case↔camelCase boundary, explicit-null clearing, uuid
  filtering), SupabaseClientProvider (PKCE), SyncGateway (CRUD + user_id
  injection), AuthService (email/OTP/Google/deep-link/sign-out), Hydrator
  (per-table server-canonical replace + external-block preservation),
  RealtimeMirror (postgres_changes per table; calendar_connections
  excluded), OutboxFlusher (dependency-ordered drain), WriteThrough
  (optimistic local + outbox), SyncCoordinator (auth-state → wipe/flush/
  hydrate/subscribe), CalendarClient (calendar-sync Edge Function). API
  verified against supabase-swift v2.46.0 source.
- Green: **202 tests** (174 Core + 15 Data + 13 Sync); ~97% line cov on
  Core. `TZ=UTC swift test --enable-code-coverage`.
- CI runs the suite + prints coverage on every push/PR.

  Note: the networked sync pieces compile + mirror the web contract but
  are runtime-validated only once wired into the Xcode app against the
  live Supabase project (no headless integration test here). The pure
  pieces (codec, cache-wipe decision, external-block merge, outbox
  ordering) ARE unit-tested.

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

**Feature screens (P2–P6, task #32)** — build the real surfaces on the
shell, each reading the local GRDB store via a repository +
`ValueObservation` and writing via `coordinator.write` (WriteThrough):
1. **Tasks** (P2): list with All/Today/Backlog/Upcoming/Later/Completed
   (use `UnstuckCore.visibleTasks`), create/edit sheet, recurrence editor
   (`materializeOccurrences`/`regenerateForTask`), slip mode, move-count.
2. **Today** (P2): Start Next (`pickStartNext`) + Up Next + today's plan.
3. **Focus** (P3): timer (`FocusTimer` + `LiveSessionStore`), 3 treatments,
   pause reasons → reason_logs, mid-session captures, re-entry.
4. **Calendar** (P4): day/week/month + block-time + drag; Google connect
   via `coordinator.calendar` + ASWebAuthenticationSession (HTTPS
   Universal-Link redirect) + pull/push.
5. **Collections / Areas / Tags / Captures** (P5).
6. **Analytics (Swift Charts ← UnstuckCore.Analytics) / Settings /
   Onboarding / Command palette** (P6).

Add the per-entity repositories as needed (copy `TaskRepository`). Wire
real Supabase creds into `App/Secrets.xcconfig` to exercise sync on device.

--- (completed) earlier "next up": UnstuckDesign + Xcode app shell ---
Reference for whoever picks up the design polish:
- `UnstuckDesign` SPM target: brand-v2 tokens (cream/ink/indigo/coral +
  dark palette, the AA coralDeep CTA), Geist/Instrument Serif/IBM Plex
  Mono fonts, a `Theme` `@Environment`, and core components (Btn/Chip/
  Pill/Card/AreaDot/Avatar/SectionLabel/Wordmark/bottom-sheet). Port from
  `../unstuck/app/globals.css` + `components/ui/*`. SwiftUI compiles under
  SPM for macOS, so cross-platform views can have lightweight tests/previews.
- Xcode app project (`tech.csalliance.unstuck`, App Group
  `group.tech.csalliance.unstuck`, entitlements: Push/Time-Sensitive/Live
  Activities; `unstuck://` scheme + Associated Domains; `.xcconfig` for
  SUPABASE_URL/ANON_KEY) referencing the local `UnstuckKit` package.
  RootView → Auth / Onboarding / MainTabScaffold (5 tabs + center FAB +
  `@Observable AppRouter`); `.onOpenURL` → `auth.handleCallback(url:)` and
  calendar redirect. Instantiate `SyncCoordinator(provider:db:)` at launch
  and call `.start()`.

Wiring notes for the app:
- `SyncConfig(url:anonKey:authRedirectURL:)` from the xcconfig; build a
  `SupabaseClientProvider`, an `AppDatabase.make(path:)` (App-Group
  container path), then `SyncCoordinator`.
- Repositories for the remaining entities follow `TaskRepository`
  verbatim (mechanical) — add as features need them.
- The Google-calendar consent (ASWebAuthenticationSession) lives in the
  calendar feature: `calendar.authorize(redirectUri:)` → present consent
  → capture the HTTPS Universal-Link redirect's `?code=` → `calendar
  .connectGoogle(code:redirectUri:state:)`.

Then features (P2–P6, task #32) and backend + native surfaces (task #33).

Port references (read-only in `../unstuck`): `lib/sync/*`,
`lib/supabase/bootstrap-listener.tsx`, `lib/sync/calendar-sync.ts`,
`lib/storage-keys.ts`, `app/globals.css`, `components/**`.

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
TZ=UTC swift test --enable-code-coverage     # 210 tests, all green (logic/data/sync/design)
xcodegen generate && xcodebuild -project Unstuck.xcodeproj -scheme Unstuck \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO   # app shell
```
