# Handover — unstuck_ios

Living doc for resuming the iOS build across sessions. Update it as
phases land. Newest status at the top.

**Parity frame (don't lose this):** the ANDROID app
(`../unstuck_android`) is the reference client — NOT the web app. The
authoritative spec is
`../unstuck_android/docs/ios-rebuild-spec/` (15 sections, generated from
the live Android Kotlin): *"Android is the reference client … where this
doc and the old discarded iOS app disagree, follow Android."* The web
repo (`../unstuck`) is only the backend home (migrations + Edge
Functions) and the historical port source for `UnstuckCore` logic names.

## Where things stand (2026-06-11, later) — reported-bug fixes + Insights; TestFlight still blocked

Three real-testing bugs (reported on Android, fixed across all 3 platforms — web is
live on Cloudflare, Android shipped as **v0.4.47/vc60** to the 2 testers) are now in
the iOS code too, plus the Insights change:

1. **Recurring tasks confined to the Recurring view + per-day occurrences.**
   `Sources/UnstuckCore/Logic/VisibleTasks.swift` — occurrences appear only in Today
   (today-dated) + the single next per template in Upcoming; All/Backlog/Later/Completed
   use non-templates only.
2. **Cross-device sync fix.** `Sources/UnstuckSync/Hydrator.swift` `pruneStaleTaskOps()`
   drops queued `tasks` ops the server already supersedes (strictly newer `updatedAt`),
   called BEFORE `flusher.flush` in `SyncCoordinator.syncNow()` + the sign-in `handle`
   path — stops a stale offline `done=false` from clobbering a web completion.
3. **Start-Next hero.** `Sources/UnstuckCore/Logic/PickStartNext.swift` `pickTodayHero()`:
   next scheduled today → else shortest estimate → else nil + `TodayFeature.swift`
   `BacklogPointerCard` (never pulls from backlog). 5 new tests in `OccurrencesTests.swift`.
4. **Insights from the first session.** `App/Features/AnalyticsFeature.swift` — `enoughData`
   now `!wSessions.isEmpty`; new `hasDots` gate for estimate-hit %; `ThresholdNote` reworded
   (dropped its count param); `Sources/UnstuckCore/Logic/Analytics.swift` `REAL_DATA_THRESHOLD`
   5→3 (qualitative insights floor only). `swift build` + Xcode `Unstuck` scheme build green.

**iOS is NOT on TestFlight yet — the only blocker is a credential.** The app archives,
but uploading needs one of: (a) an **App Store Connect API key from the team** (a `.p8`
+ Key ID + Issuer ID — App Store Connect → Users and Access → Integrations → Keys) so
`xcodebuild archive`/`-exportArchive` + upload can run non-interactively (there is no
`.p8` in `~/.appstoreconnect/private_keys/` and no `fastlane` set up); or (b) a **one-time
manual Xcode upload** (sign into team `M9ULD6M5Z3`, Product → Archive → Distribute →
TestFlight — see `HANDOFF-TESTFLIGHT.md`). The app record for `io.unstucknow.app`
must already exist in that team's App Store Connect. User asked (2026-06-11) for iOS on
TestFlight for themselves + Sven; pending this. Voice realtime still needs on-device audio
validation + the real `VOICE_PROXY_URL` in `App/Secrets.xcconfig`.

## Where things stand (2026-06-11) — parity bug-sweep + fixes

A 31-agent adversarial review of the whole 2026-06-10 parity build (9 area
reviewers diffing each fresh surface against Android, every finding re-verified
by a second agent) found **20 real bugs** — report in
`audit/parity-bug-sweep-2026-06-11.md`. **All 19 distinct issues are now fixed**
(2 commits; 258 unit tests + the assistant/settings XCUITests green):

- **Critical:** PKCE forgot-password was fully broken (the SDK emits `.signedIn`,
  not `.passwordRecovery`, and the callback has no `type=recovery`) — ported
  Android's one-shot JWT `amr`-probe (`AppModel.isRecoverySession`) so the reset
  link routes to SetNewPasswordView. *(The earlier handover note claiming the
  `.passwordRecovery` event was reliable was wrong — corrected.)*
- **Highs:** OutboxFlusher had no drain serialization (actor reentrancy) + miscounted
  cancelled drains as failures (poison-dropping valid offline writes) — now chains
  drains + re-throws on cancellation; `scheduleTaskAt` could drop a just-scheduled
  recurring task (coversChosen ignored `plan.toDelete`); Inbox/notification "Open"
  silently no-op'd (two sheets from one host) — deferred via `router.pendingDeepLink`
  flushed on the host's `onDismiss`; STT `engine.start()` failure leaked the tap →
  crash on next dictation.
- **Mediums/lows:** Today completed-wins + Start-Next dedup/live/area; widened
  `addTask` (kills four mutate-then-resave double-writes); reactive sign-out scrub
  (cross-account leak); voice — handshake-gated `onOpen` via URLSessionWebSocketDelegate,
  session `invalidateAndCancel` on stop, `flushPlayback` no longer drops barge-in mic
  audio, VoiceController off-lock; no bubble on Calendar; uppercase capture tag.

The voice realtime stack still needs ON-DEVICE audio validation + the real
VOICE_PROXY_URL in Secrets.xcconfig (the sim can't exercise it).

## Where things stand (2026-06-10) — Android-parity build-out

A focused pass closing the big parity gaps the 14-agent iOS↔Android audit
flagged. iOS was substantially behind; this brought data/sync/recurring/
settings/account/inbox/auth/onboarding/assistant to parity. `swift test`
stays green (258) and the `Unstuck` scheme builds clean after each step.

- **Recurring tasks (phases 0+2+4a).** A task with `recurrence` is a hidden
  TEMPLATE; per-occurrence state (`done`/`skipped`/`completedAt`) lives on the
  fronting `cal_block` (migration 033), projected at read time into synthetic
  one-day rows. `CalBlock` carries the 3 fields (model + `DbRowCodec` tolerant
  decode + a GRDB v2 migration). `Occurrences.swift` (isTemplate /
  projectOccurrences / occurrenceBlockFor / taskForBlock); `VisibleTasks` gains
  a `Recurring` view + composes occurrences into every other view;
  `PickStartNext` excludes templates. UI: the **Recurring pill**, per-day
  Mark-done/Skip-this-day routing (occurrence id = block id → writes the block,
  never the series), occurrence→template editor guard (no phantom task), and
  focus-on-occurrence routing (`LiveSession.occurrenceBlockId` → session runs
  on the template, completion marks the day's block; captures attach to the
  template). Today rows show ↻ + a skip menu. `OccurrencesTests` (7).
- **Sync hardening (phase 1).** `upsertCapture` carries `dependsOn=sessionId`;
  `OutboxFlusher` holds a child op (cal_block→tasks, capture→sessions) until
  its FK parent exists LOCALLY (a live-session capture has no pending session
  op yet — the old filter poison-dropped it); `deleteSession/Capture/ReasonLog`
  added; `Hydrator.hydrateCollections` preserves unsynced optimistic
  collections. (Google calendar push was already done at the AppModel layer.)
- **Settings depth + account mgmt (phase 3).** Device-local `SettingsState`
  (UserDefaults) + Focus/Sound/Accessibility/Interface sub-screens — NO dead
  toggles (theme→`.preferredColorScheme` at root; focusDefaultMin→new-task
  estimate; focusOverrunMin→overrun grace; defaultTreatment→fresh session;
  focusSoftExit→"← Out" leaves the session running/resumable; focusPauseReasons;
  reduceMotion→focus ring; ambient→focus loop). Account: display name / change
  password (reauth-gated) / delete account (type-to-confirm) / export / sign
  out, on a new `AuthService` backbone (changePassword/updateDisplayName/
  deleteAccount/reauthenticate/hasPassword). Omitted (no iOS seam / dead on
  Android too): chime/bell/completion sounds, largerType/highContrast/accent/
  density.
- **Capture Inbox.** `promoteCapture`/`archive`/`unarchive`/`discard` (archive
  = device-local UserDefaults id set, NOT a DB column), `observeCaptures`,
  `InboxView` (open + Archived toggle, per-row Promote/Open/Done/Discard),
  reached from a tray icon in the Today header (Android's access point).
- **Auth: forgot-password + recovery.** AuthView gains a "Forgot your
  password?" link (sends a RESET link, not a sign-in link). Recovery is
  detected via the `.passwordRecovery` event (PKCE flow has no type=recovery in
  the URL) + a URL fast-path; `RootView` shows `SetNewPasswordView` until
  consumed. Plus the iOS **`track-login`** client (LoginTrackerClient, fired on
  the authed transition, throttled 12h/user).
- **5-step onboarding.** Welcome → areas → struggles → first task → focus
  treatment; `completeOnboarding` seeds picked areas (only when empty), the
  first task, and the default treatment.
- **In-app Assistant (text).** `AssistantClient` (the `assistant` edge-fn
  transport) + `AssistantModel` (agentic turn loop ≤5 iterations, the 11-tool
  dispatcher mapped to the offline-first AppModel methods, compact context
  builder, UserDefaults history windowed to 40, scrubbed on sign-out/delete).
  The floating bubble is now a dual Assistant | Feedback sheet. The `assistant`
  edge fn returns `not_configured` until `QWEN_API_KEY` is set on prod (handled
  gracefully).
- **Voice assistant (now DONE).** `App/Voice/`: VoiceRealtimeClient
  (URLSessionWebSocketTask → the CF proxy; the exact DashScope realtime
  protocol, args cross the Task boundary as a Sendable JSON string),
  VoiceAudioEngine (AVAudioEngine 16k capture / 24k playback + voice-processing
  AEC for full-duplex barge-in), VoiceController (on-device SFSpeechRecognizer
  STT + AVSpeechSynthesizer TTS). VoiceModeScreen + VoiceSessionModel orchestrate
  the realtime "Talk" mode (orb / captions / Interrupt / End, ends on an
  AVAudioSession interruption); the chat bubble gains a Talk button (gated on
  `voiceConfigured`), an on-device dictation mic, and a read-aloud toggle. Tool
  calls reuse the text dispatcher (`runVoiceTool`). Config: `VOICE_PROXY_URL` via
  Config/Secrets.xcconfig + Info.plist; `AuthService.accessToken`. Fixed: the
  floating bubble was occluded by the bottom nav (raised to 96pt). XCUITests
  (testAssistantBubble / testSettingsSubScreens) pass on the iPhone 17 sim.
  **TODO (not code):** put the real `wss://unstuck-voice-proxy.<subdomain>.workers.dev`
  in Secrets.xcconfig, and validate audio (levels/echo/barge-in) ON A DEVICE —
  the sim can't.
- **Server.** `send-session-recap` APNS push is now a silent banner
  (`sound:false`, Calm by default) — deployed.

Remaining parity gaps: none of substance — only minor Insights/notification-
thread polish + the on-device voice validation noted above.

## Where things stand (2026-06-09, later) — tri-platform audit: sync hardening pass

A 114-agent tri-platform review
(`../unstuck/audit/tri-platform-review-2026-06-09.md`) found the iOS
sync engine had regressed every documented Android outbox lesson, plus a
cluster of smaller spec divergences. All iOS findings from that audit
are now fixed in this pass:

- **Lowercase uids (was CRITICAL):** `AuthService.currentUserId`,
  `FeedbackClient`, and `SyncCoordinator.handle` now lowercase
  `UUID.uuidString` — Foundation uppercases it while every server uuid
  is lowercase, which broke ALL collection ownership/membership checks
  (owners saw their own lists as shared) and routed offline edits to the
  no-outbox RPC path. The stored `prevUserId` is lowercased on read too.
- **Outbox cross-account leak (was CRITICAL):** `wipeSyncedTables()` →
  `AppDatabase.clearAll()`, which now also clears `outbox` +
  `live_session` on sign-out/user-switch (a kept outbox was replayed
  stamped with the NEXT user's id). `SyncDecision.shouldWipeCache` wipes
  iff the user actually changed (a same-user `SIGNED_IN` re-auth no
  longer clobbers pending edits + the live session);
  `SyncDecisionsTests` re-pinned to the spec behavior.
- **Pre-signout drain + push unregister:**
  `SyncCoordinator.signOutAndUnregister(deviceId:)` drains the outbox
  (bounded 5 s, guarded on the live user), deletes this device's
  `device_tokens`/`live_activity_tokens` rows while the JWT is still
  valid (`PushClient.unregister`), then signs out. `AppModel.signOut`
  also wipes the notification log + per-task reminder overrides and
  cancels all scheduled reminders + the paused check-in; the APNs token
  re-registers on the next authenticated transition.
- **OutboxFlusher = the Android port (spec §1.2/§1.4):** FAIL_CAP=5
  poison pill + orphan-drop of dependents, `blockedRows` per-row FIFO
  after a failure (an older retried upsert can never clobber a newer
  one), and a mid-drain live-user re-check. The drain now runs against a
  `SyncGatewayProtocol` seam; `OutboxFlusherTests` script failures
  through a fake gateway over a real GRDB outbox.
- **Sync triggers beyond auth events (spec §5):** debounced post-write
  flush kick (1.5 s after every `WriteThrough` enqueue), `syncNow()`
  (flush → hydrate → calendar pull) on scenePhase `.active`, and a
  chained `BGAppRefreshTask` (`io.unstucknow.app.refresh`, 30-min
  best-effort, Info.plist `UIBackgroundModes: fetch`) that also rebuilds
  the Start-Next widget snapshot. Offline edits no longer wait for an
  app relaunch.
- **§1.6 external-block guards:** `g_`/external cal_blocks are never
  enqueued to Postgres (`WriteThrough.upsertCalBlock` early-returns),
  never pushed/patched/deleted on Google, aren't draggable and have no
  Delete context menu in the day grid. Every delete cancels the row's
  still-queued upserts (`OutboxStore.cancelPendingUpserts`) so a
  held-back upsert can't resurrect a deleted row (§1.8). Task blocks now
  push to Google's `"primary"` calendar (not
  `selectedCalendarIds.first`, which can 403 on read-only calendars).
- **Hydrate preserves localPending (§1.3):** `hydrateCalBlocks` re-adds
  unsynced optimistic TASK blocks (pending cal_blocks upserts in the
  outbox) so a transiently-failed flush can't wipe a just-scheduled
  block off the UI.
- **Google pull reconciled (Android `pullCalendar` port):**
  `reconcileCalendarPull` (pure, in `UnstuckCore`, unit-tested) filters
  the app's own pushed events + all-day events and drops in-window
  external blocks Google no longer returns; window is [-7d, +30d]; runs
  from the sign-in pipeline, `syncNow()`, and the manual Sync button.
- **Push registration:** explicit `platform: "ios"` in the
  register-push-token body, and `apnsEnvironment` is `sandbox` for
  DEBUG builds (dev devices carry sandbox tokens — registering them as
  production made every server push silently fail).
- **Release blocker cleared:** `App/PrivacyInfo.xcprivacy` added
  (required-reason `UserDefaults` CA92.1 + the nutrition-label
  data-collection entries), bundled into BOTH the app and the widget
  target via `project.yml`.
- **Smaller fixes:** Google OAuth `state` echo is validated against the
  minted state (`GoogleConnectController`); the full-PII data export now
  writes to a swept staging dir with `.completeFileProtection` and is
  deleted when the share sheet finishes; Today/Calendar observe
  life_areas + sessions in the same tracked GRDB snapshot (area renames
  / realtime sessions refresh the pills + week-focused stat).
- **Tests: `TZ=UTC swift test` → 250 / 0** (204 Core + 16 Data + 22
  Sync + 8 Design). New: `ReminderPlanTests`,
  `CalendarPullReconcileTests`, `OutboxFlusherTests`, plus an
  `AppDatabase.clearAll` coverage test in `SyncStoreTests`.

### Genuinely remaining gaps (the honest list)

- **Backend:** server pushes to iOS still carry only the APNs alert —
  no `kind`/`deepLink` custom keys (the client reads them when present
  and falls back to Today). `notification_preferences.timezone` is a
  known cross-platform backend gap tracked in the audit.
- **Documented divergence (spec §5.5):** the paused check-in's server
  allow-check runs at *arm* time, not fire time (iOS local
  notifications can't run code before display).
- **Android assistant + voice "Talk" bubble:** not in the 15-section
  spec and not ported to iOS yet (Android-only for now).
- **Today recap "Just now" card** (spec 05, 6h expiry) isn't built;
  Settings teal/error-red micro-styling still pending. (The Calendar
  Month heatmap and the 7-column per-hour Week grid, previously listed
  as open, ARE built now.)
- **BG sync is best-effort** — `BGAppRefreshTask` has no guaranteed
  cadence on iOS; the scenePhase trigger covers the common path.
- **Manual/credential steps** (see "Manual steps" below): APNs p8
  secrets, signing team + capabilities, the Google Cloud Console HTTPS
  redirect + AASA for calendar connect, cron SQL.

## Where things stand (2026-06-09) — spec §10 notifications subsystem

Implemented `ios-rebuild-spec/10-notifications.md` end-to-end:

- **Pure decision logic** (`UnstuckCore/Logic/Notifications.swift`, unit-
  tested in `ReminderPlanTests`): `NotificationLevel` (Calm/Balanced/Coach
  with the verbatim blurbs + derived gates), `planReminders` (LEAD/ATSTART/
  DRIFTED over the 48h horizon, per-task lead overrides, done-task skip,
  external-event lead-only), `upcomingReminders`, `relFuture`/`relPast`,
  `notificationAccent`.
- **ReminderScheduler** (`App/Notifications/`): GRDB observation over
  blocks + tasks + live_session → UNCalendarNotificationTrigger requests
  with the `unstuck.rem.<tag>:<blockId>` identifier scheme and prev−now
  stale cancellation; re-syncs on foreground/BG-refresh (syncNow) and on
  settings change. **Gotcha-8 inversion:** iOS can't re-check at fire time,
  so completing a task or starting Focus on it cancels its pending
  ATSTART/DRIFTED via the same observation.
- **Actions + routing:** `UNNotificationCategory` Start/Reschedule (A2/A4)
  and Resume/Snooze/End (paused check-in); `didReceive` routes action ids +
  `data.deepLink` through `PushActionHub` → AppModel (buffered across cold
  launches); background one-tap Reschedule ports `ScheduleCommands`
  (next-free-slot + moveCount bump + 8s "Rescheduled" confirmation).
- **Notification Center** (bell on Today, unread badge): Upcoming (live,
  48h, ≤20) + Recent (60-entry `NotificationLog` persisted to UserDefaults,
  fed from willPresent/didReceive + a delivered-notifications sweep).
- **Level mirror:** Settings → Notifications writes the level device-
  locally and mirrors `morning_brief_enabled`/`paused_checkin_enabled` to
  `notification_preferences` (`PreferencesClient.setNotificationLevel`),
  best-effort, only on change. Global reminder lead + per-task "Remind me"
  chips (Default/Off/5/10/15m) in the task editor.
- **Sign-out hygiene:** log + overrides wiped, scheduled reminders +
  paused check-in cancelled, APNs token unregistered while the JWT is
  valid (`SyncCoordinator.signOutAndUnregister`); token re-registers on
  the next authenticated transition.
- **Documented divergence (spec §5.5):** the paused check-in is a plain
  14-min `UNTimeIntervalNotificationTrigger` pre-armed at pause time and
  cancelled on resume/end; the server `send-paused-checkin` allow-check
  runs at *arm* time (AppModel.requestPausedCheckin cancels on deny), not
  at fire time — iOS local notifications can't run code before display.
  Server pushes to iOS currently carry only the APNs alert (no
  `kind`/`deepLink` custom keys yet — backend gap); the client reads them
  when present and falls back to Today.

## Where things stand (2026-06-06) — aligned to current Android (shared collections + accountability + feedback)

The iOS app predated Android's shared-collections / accountability /
feedback feature set. This pass aligned sync + orchestration + the
highest-value UI with the **current** Android (the 2026-06-09 audit
later found and fixed the remaining engine-level divergences — see the
sections above):

- **Sync layer (UnstuckSync)** — `CollectionShareClient` (share/unshare/
  cancelInvite/leave/listMembers via the `share-collection` edge fn; atomic
  item RPCs `collection_add_item`/`_update_item`/`_remove_item`/
  `_set_item_flag`/`_set_item_promotion`; `updateCollectionFields`
  metadata-only UPDATE; `collection-task-done`); `FeedbackClient` (one-way
  insert to `feedback`, platform `ios`). `DbRowCodec.TaskRow` gained
  `source_collection_id`/`source_item_id`/`due_at` (explicit-null);
  `CollectionRow` gained `archived` + decode-only `ownerId` (from `user_id`).
  `Hydrator.hydrateCollections(userId:)` joins `collection_members` →
  members[]/myRole. `RealtimeMirror` subscribes collections WITHOUT the
  user_id filter (shared rows arrive via RLS, members/myRole preserved) +
  a `collection_members` channel that re-hydrates. `AuthService` exposes
  `currentEmail`/`currentUserName`. `WriteThrough.deleteCollection`.
- **Orchestration (App/AppModel+Collections.swift)** — `isShared`/`isOwner`/
  `canEdit` (uid-guarded routing), `mutateCollection`/`mutateCollectionItem`
  (own → outbox upsert, shared → optimistic local + atomic RPC), collection
  + item CRUD, `moveItemToTask(SELF/LOOP)` + `markItemPromoted`, `toggleDone`
  + `finishFocus` with the `collection-task-done` hook, sharing proxies,
  `sendFeedback`.
- **UI (Phase 4)** — in-app **feedback bubble** + composer (MainTabScaffold);
  **Collections** rebuilt 1:1 (overview grid w/ SHARED badge + Archived
  filter + search; detail rename/recolor/archive/delete/leave; item rows
  done/pin/move-to-task/remove + accountability chips; move-to-task chooser
  + by-time picker; share sheet); **Focus** "Done" now accumulates
  totalFocused + marks complete + fires the shared-task notification.
- **Tests:** `TZ=UTC swift test` → **217 / 0** (DbRowCodecTests +5 for the
  new columns + sharing fields). App target builds for the simulator.

UI remaining-parity pass (these surface items are DONE — the engine +
notification gaps they didn't cover are the 2026-06-09 sections above):
Focus **overrun check-in** (+10 / in-the-
zone / Stop here); Today **notifications-off banner** (UNUserNotificationCenter
+ didBecomeActive) and **Start-Next** firstPhysicalAction headline + "Pick
another"; Calendar **Week view** (Mon-anchored ‹/Today/› nav + Focus-planned/
busiest/lightest rollup + per-day drill-in); **Settings** account email + real
**data export** (JSON backup via share sheet) + **deleteTag cascade**;
**command palette** Go-to-tab nav actions; **Insights deep-dive** (Report/Deep
dive toggle → interruption histogram, re-entry distribution, time-of-day
heatmap, pause anatomy, slip detector). Plus a `greenInk` palette token.

Verified runtime: the **full app (with the WidgetKit extension) installs +
launches** on the iPhone 17 simulator — a missing `CFBundleExecutable` in
`Widgets/Info.plist` (GENERATE_INFOPLIST_FILE=NO) had silently blocked install
on any device; now fixed. `TZ=UTC swift test` = 217/0.

Smaller deltas still open as of this pass: Settings teal/error-red
micro-styling and the Today recap "Just now" card. (Calendar Month view
and the full per-hour week grid, listed open here originally, have since
landed — see "Genuinely remaining gaps" at the top for the current
list.)

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

Backend (in `../unstuck`): migrations 014–016 **applied**; Edge Functions
register-push-token + send-session-recap / send-paused-checkin /
send-morning-brief (+ `_shared/apns.ts` ES256) **DEPLOYED + ACTIVE** on
project uaxfteluwctrlgwmmfzi; cron in `supabase/manual/`. register-push-token
+ send-paused-checkin work now; send-session-recap's in-app card works (push
needs APNs secrets); send-morning-brief needs APNs secrets + CRON_SECRET + cron.

## Manual steps (need your credentials)
1. ✅ Functions deployed (done by the agent).
2. Set secrets so the push side fires: `supabase secrets set APNS_AUTH_KEY=… APNS_KEY_ID=… APNS_TEAM_ID=… APNS_BUNDLE_ID=io.unstucknow.app CRON_SECRET=…` (needs your Apple p8 key).
3. Put the Supabase anon key in `App/Secrets.xcconfig` (else the app shows the setup screen).
4. Target capabilities (signing): Push, Time-Sensitive, App Groups
   `group.io.unstucknow.app`, Live Activities.
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
  Bundle id `io.unstucknow.app`, `unstuck://` scheme.

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

## Next up (historical)

This is the original build-plan status against the old web-parity plan —
for what's actually open NOW, see "Genuinely remaining gaps" at the top.

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

The remaining-in-reach items are now DONE too: the **drag-to-schedule day
grid** (draggable unscheduled tray + drop-to-time + drag-to-reschedule),
and **Google patch/delete/move** of pushed blocks. The app was
feature-complete against that (web-parity) plan; the Android-parity
deltas that remained are tracked in the dated sections above.

The credential-gated work is **work only you can do** (see "Manual steps" above):
deploy the Edge Functions + APNs p8/`CRON_SECRET` secrets, put the anon
key in `App/Secrets.xcconfig`, enable the Apple capabilities under a
signing team, register the Universal-Link redirect + ship the AASA, and
run `supabase/manual/notification_cron.sql`. After those, everything —
sync, push, widgets, Live Activities, Focus Filter, Google two-way sync —
is live.

--- (completed) earlier "next up": UnstuckDesign + Xcode app shell ---
Reference for whoever picks up the design polish:
- `UnstuckDesign` SPM target: brand-v2 tokens (cream/ink/indigo/coral +
  dark palette, the AA coralDeep CTA), Geist/Instrument Serif/IBM Plex
  Mono fonts, a `Theme` `@Environment`, and core components (Btn/Chip/
  Pill/Card/AreaDot/Avatar/SectionLabel/Wordmark/bottom-sheet). Port from
  `../unstuck/app/globals.css` + `components/ui/*`. SwiftUI compiles under
  SPM for macOS, so cross-platform views can have lightweight tests/previews.
- Xcode app project (`io.unstucknow.app`, App Group
  `group.io.unstucknow.app`, entitlements: Push/Time-Sensitive/Live
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
- **Reference client:** the Android app at `../unstuck_android`; the
  authoritative behavioral spec is
  `../unstuck_android/docs/ios-rebuild-spec/` (15 sections). Where any
  doc disagrees with Android, follow Android.
- Web app (backend home + original `lib/*` port source for the
  UnstuckCore logic names): `../unstuck`
  (`github.com/btambaya/Unstuck.git`).
- Supabase project ref: `uaxfteluwctrlgwmmfzi`; schema migrations 001–013
  live in `../unstuck/supabase/`. iOS backend additions (014–016 + push
  Edge Functions) will also land in `../unstuck/supabase/`.
- Planned bundle id `io.unstucknow.app`; App Group
  `group.io.unstucknow.app`.
- Note: `~/Desktop/.git` is a stray repo (remote `focus-app.git`); this
  repo's own `.git` overrides it inside `unstuck_ios/`.

## How to verify

```sh
cd unstuck_ios
TZ=UTC swift test --enable-code-coverage     # 250 tests, all green (204 Core + 16 Data + 22 Sync + 8 Design)
xcodegen generate && xcodebuild -project Unstuck.xcodeproj -scheme Unstuck \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO   # app + widget
```
