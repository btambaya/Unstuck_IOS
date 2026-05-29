# Handover — unstuck_ios

Living doc for resuming the iOS build across sessions. Update it as
phases land. Newest status at the top.

## Where things stand (2026-05-29)

**Foundation + 7 feature slices + push-registration vertical + the
notification DB backend are in; app builds for iOS simulator.** Surfaces
wired end-to-end through the live store (repository → ValueObservation →
UnstuckCore logic → SwiftUI → WriteThrough):
- **Tasks** (P2): live list + view-filter chips (visibleTasks) + create +
  done-toggle (applyCompletion).
- **Today** (P2): Start Next + Up Next (pickStartNext/pickUpNext).
- **Focus** (P3 core): live timer on FocusTimer + LiveSessionStore +
  Session writeback.
- **Collections** (P5): live lists + new-list + detail add-item.
- **Calendar** (P4, read): cal_blocks agenda grouped by date.
- **Settings** (P6): account + sign-out + app info.
- **Push registration** (#33): PushAppDelegate → PushClient →
  register-push-token → device_tokens.

- **Native surfaces** (#33): `UnstuckShared` App-Group store; Start Next
  home/lock **widget** + **Focus Live Activity / Dynamic Island** (widget
  extension, builds); **LiveActivityController** driven by the focus timer;
  **WorkFocusFilter** SetFocusFilterIntent + Tasks reconcile;
  **paused-too-long** local notification.
- **Analytics** (P6): Swift Charts over UnstuckCore.Analytics (Settings → Insights).

Backend (in `../unstuck`): migrations 014–016 **applied** to the live
project; Edge Functions register-push-token + send-session-recap /
send-paused-checkin / send-morning-brief + `_shared/apns.ts` (ES256)
**written + committed** (not deployed); cron in `supabase/manual/`.

## Manual steps (outside the agent's authorization)
1. Deploy the functions:
   `supabase functions deploy register-push-token send-session-recap send-paused-checkin send-morning-brief`
2. Set secrets: `supabase secrets set APNS_AUTH_KEY=… APNS_KEY_ID=… APNS_TEAM_ID=… APNS_BUNDLE_ID=tech.csalliance.unstuck CRON_SECRET=…`
3. Put the Supabase anon key in `App/Secrets.xcconfig` (else the app shows the setup screen).
4. Target capabilities (signing): Push, Time-Sensitive, App Groups
   `group.tech.csalliance.unstuck`, Live Activities.
5. Enable pg_cron + pg_net, set the cron config, then run `supabase/manual/notification_cron.sql`.
6. Register an HTTPS Universal-Link redirect on the existing web Google OAuth
   client + ship the AASA for the calendar connect flow.

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
- Green: **210 tests** (174 Core + 15 Data + 13 Sync + 8 Design); ~97%
  line cov on Core. The app + widget extension build for the iOS simulator
  (`xcodebuild … BUILD SUCCEEDED`).
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

All P2–P6 feature surfaces are built + building: **Tasks** (list + filters
+ create/edit + recurrence editor + cal_blocks bucketing), **Today**
(Start Next/Up Next), **Focus** (timer + 3 treatments + pause reasons +
captures + Live Activity + paused-checkin), **Calendar** (agenda + Google
connect via ASWebAuthenticationSession + pull/ingest), **Collections**
(live + pin), **Tags & Areas** management, **Analytics** (Swift Charts),
**Settings**, **Onboarding**, **Command palette**, + native surfaces
(push, widget, Dynamic Island, Focus Filter).

The step-3 polish is now DONE too: Calendar **block-time create**,
**schedule-to-slot**, and **push task blocks to Google**; **session-recap**
+ **paused-checkin** wired; **onboarding → user_preferences** sync;
**ambient audio** + **slip-mode**; **Live-Activity APNs push-token**
backstop.

What genuinely remains:
- **Drag-to-schedule day-grid** (the agenda is a list + tap-to-schedule
  today; a draggable time-grid is the remaining UI build).
- Edit/patch/delete an existing Google-pushed block (insert is wired; the
  patch/delete round-trip on later edits isn't).
- Server-side Live-Activity push + the send-* calls only matter once the
  Edge Functions are deployed (manual steps below).
- The **manual deploy/capability/secret steps** (functions deploy, APNs p8,
  anon key in Secrets.xcconfig, Apple capabilities, Universal-Link redirect,
  cron) — see "Manual steps" above.

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
