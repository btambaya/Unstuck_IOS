# iOS ↔ Android Functional Parity Audit — Engineering Report

## Executive Summary

iOS is broadly at functional parity across most surfaces, with several large, isolated holes rather than diffuse drift. Fully clean surfaces (Inbox) and near-clean ones (Insights, Feedback, Notifications) sit alongside three problem areas. **Settings** is the worst: the Areas & Tags management screen is a bare stub with no recolor/rename path wired anywhere, missing the entire CRUD/affordance set Android ships. **Calendar** is next: it matches on layout and Google connect/sync but is missing nearly every real grid interaction (tap-to-create, block-edit sheet, disconnect, recurring template/skip/done handling). **Today** is missing two whole feature cards (live focus-session, in-app nudge) and inverts the row-tap action. **Auth** has a functionally broken sign-up path (no confirmation banner, no already-exists detection). **Voice** carries two real safety/lifecycle gaps (zombie-call on background, silent dead mic). Everything else is mostly cosmetic.

## HIGH-Severity Gaps

| Surface | Behavior | iOS File | Concrete Fix |
|---|---|---|---|
| auth | Successful sign-up shows no confirmation banner ("looks like nothing happened") | `App/Auth/AuthView.swift` + `Sources/UnstuckSync/AuthService.swift` | Make `signUp` return `.needsConfirmation` when there is no active session post-sign-up (`apply()` already maps it to the right copy), or special-case sign-up in `submit()` to set the green success banner on `.ok`. |
| auth | No already-registered-email detection (anti-enumeration) | `Sources/UnstuckSync/AuthService.swift` | Capture the `AuthResponse` (currently discarded via `_ =`); feed `user.identities?.count` / `emailConfirmedAt` / `lastSignInAt` + `currentSession != nil` into the existing `detectSignupAlreadyExists` (in `UnstuckCore/Logic/AuthErrors.swift`) and return `.alreadyExists` / `.error(humanizeAuthError(code:"user_already_exists"))`. |
| today | Live focus-session card (progress ring, 1s elapsed ticker, In focus/Paused label, tap-to-return, inline Pause/Resume) missing | `App/Features/TodayFeature.swift` | Add a `LiveSessionCard` to `list(_:)`. Surface the running/paused `LiveSession` (already read via `LiveSessionStore`/`observeTasksAndBlocks`), render a `TimelineView` ring from `FocusTimer.displayedElapsedSec(live, now)` + `sessionEstimateMin`, tap → `model.router.beginFocus(liveTask)`, and add `pauseFocus`/`resumeFocus` on `AppModel` if absent. |
| today | Quiet in-app nudge card (SLIPPING→open / CAPTURE→promote, ✕ dismiss) entirely absent | `App/Features/TodayFeature.swift` | Port `computeNudges` + `Nudge`/`NudgeKind` model + a published `nudges` collection (gated by `notificationLevel.nudges`, filtered by persisted dismissed-ids), expose `dismissNudge`, and render the first nudge between recap and hero. |
| tasks-list | Tag filtering entirely missing (tap #tag → activeTag → filter banner → narrowed list across all views) | `App/Features/TasksFeature.swift` | Add `activeTag: String?` to `TasksModel`; pass it into `visibleTasks(... activeTag:)` in the `visible` computed property (core fn already accepts it). Make `TaskRowView`'s #tag chips their own tappable Button (not the row's `onOpen`) that sets `activeTag`. Render the dismissible "Filtering by tag #x ✕" banner in the pinned header. |
| calendar | Tap empty grid slot to create a prefilled task (Day + Week) missing | `App/Features/CalendarFeature.swift` | Add a tap gesture to the Day grid (ignore gutter, `x<64`) and each `WeekView` `dayColumn`, snapping `location.y` to nearest 15 min, clamped 00:00–23:45, invoking the quick-create flow prefilled with that date+time (mirror Android `onCreateAt`). Drop the unrelated "+ Block" button. |
| calendar | Tap-a-block edit sheet (reschedule chips / resize 15-90 / unschedule) missing | `App/Features/CalendarFeature.swift` | Build a `CalBlockEditSheet` equivalent, presented on tapping a task block. Add `resizeBlock(block, durationMinutes)` and `unschedule(blockId)` to `AppModel` (neither exists). Use `findFreeSlotsForDate` with `dayStartMin=0`/`dayEndMin=24*60` for reschedule chips; exclude external/Google blocks. |
| calendar | Disconnect Google Calendar (with destructive confirm) missing entirely | `App/Features/CalendarFeature.swift` | Add a "Disconnect" action to `CalendarSyncBar`'s connected state behind a confirmation alert, plus `disconnectCalendar(_:)` on `AppModel` calling the existing-but-unused `CalendarClient.disconnect(connectionId:)`, looping over connected accounts. |
| calendar | Recurring TEMPLATES leak into the unscheduled drag tray | `App/Features/CalendarFeature.swift` | In `CalendarModel.unscheduled()` (line 62) add `&& $0.recurrence == nil` to the filter, so a repeating-task definition never appears as a draggable chip (and can't schedule the template itself). |
| settings | Areas management is a bare stub | `App/Features/TagsAreasFeature.swift` | Rebuild to match Android `AreasContent`: "<n> open" count (tasks where `lifeArea==name && !done && recurrence==nil`), tappable `ColorChip` → palette recolor, inline rename, per-row menu (Rename/Delete), delete-confirm dialog, reject case-insensitive duplicate names on Add, pick color = first-unused + `sortOrder = max+1`. |
| settings | Tags management is a bare stub | `App/Features/TagsAreasFeature.swift` | Rebuild to match Android `TagsContent`: usage count (tasks whose tags contain the name), "#name" display, palette recolor chip, inline rename, per-row menu + delete-confirm dialog, reject case-insensitive duplicates (keep draft on dup), first-unused color + `sortOrder = max+1`. |
| settings | No recolor/rename path for existing area/tag | `App/AppModel.swift` | `AppModel` exposes only full-upsert `saveTag`/`saveLifeArea` + deletes. Add recolor/rename actions (upsert preserving id/sortOrder with new color or name) and wire into the rebuilt rows. |
| onboarding | Treatment-picker selected row is white-on-white (unreadable) in dark mode | `App/Features/OnboardingFeature.swift` | In `treatmentRow(...)`, replace the three hardcoded `.white` foreground colors with `theme.palette.bg` (blurb `theme.palette.bg.opacity(0.85)`), matching Android's `c.bg`, so the selected row contrasts in both themes. |
| assistant | Dictation does not auto-send (no hands-free voice-to-action) | `App/Features/AssistantSheet.swift` | In `toggleMic()`'s `onDone` closure, after `dictating=false`, if the dictated draft is non-blank call `send()` (mirroring Android's `if (input.isNotBlank()) send(input)`). |
| voice | Backgrounding/locking the app leaves a zombie call (mic + socket + comm-mode alive) | `App/Voice/VoiceModeScreen.swift` | `.onDisappear` doesn't fire when the app is backgrounded under a presented `fullScreenCover`. Add a `scenePhase` observer (or `UIApplication.didEnterBackgroundNotification`/`willResignActive`) that calls `session.end()` when phase `!= .active`, tearing down mic/WebSocket/playAndRecord like Android's `ON_STOP`. |

## MEDIUM-Severity Gaps (grouped by surface)

### today
- **Row tap toggles done instead of opening Detail** (`App/Features/TodayFeature.swift`): the row's primary Button calls `model.toggleDone(t)` and there's no way to open task detail from the Today list. Change the primary tap to navigate to the task detail route (Android `onOpen`), and move toggle-done to a leading checkbox / the contextMenu.

### tasks-list
- **Notifications bell + unread badge missing from the shared AppBar** (`App/Chrome.swift`): add a bell button with a coral unread dot when `notifUnread>0` and wire `TasksView`'s AppBar call to open the notifications surface. Shared chrome — also covers Calendar/Collections (see LOW notes), so fixing once closes several gaps.

### calendar
- **Skipped recurring occurrences still render** (`App/Features/CalendarFeature.swift`): filter out skipped blocks in `CalendarModel.blocks(on:)` / `byDate`, e.g. `blocks.filter { $0.date == iso && !$0.skipped }` (Android does `blocksRaw.filter { !it.skipped }`).
- **Completed recurring occurrence shows un-struck** (`App/Features/CalendarFeature.swift`): in `DayGridView.blockCard` (line 736) and `WeekView.weekBlock` (line 349), change `done = bt?.done == true` to `done = b.done || bt?.done == true`, since occurrence completion lives on the block, not the task.

### collections
- **Add-item field lacks autofocus / re-focus** (`App/Features/CollectionsFeature.swift`): add an `@FocusState` bound to the add-item `TextField`; focus it `onAppear` (when `canEdit`) and re-assign `focus = true` at the end of `add()` after clearing the draft, so the keyboard stays up for rapid entry.

### insights
- **Only `sessions` is observed live; tasks/captures/reasonLogs/lifeAreas are one-shot** (`App/Features/AnalyticsFeature.swift`): observe the capture, reason, task and life-area repos too, so interruption bins, pause anatomy, captures-by-kind, the slip detector, calibration scatter and stacked bars stay live and internally consistent (a live session can otherwise join against a stale snapshot).

### settings
- **Sound toggles missing** (`App/Features/SettingsFeature.swift`): `SoundSettingsView` only renders the Ambient SegRow. Add `ToggleRow`s for `soundStartChime`, `soundOverrunBell`, `soundCompletion` (the `SettingsState` properties already exist and persist).
- **"Hide right rail while focusing" toggle missing** (`App/Features/SettingsState.swift`): add the `focusCollapseRail` property + toggle in `FocusSettingsView`, or confirm it's deliberately dropped if the right-rail concept is N/A on the iOS focus layout.

### focus
- **Cockpit Captures rail missing** (`App/Features/FocusFeature.swift`): when `treatment == .cockpit`, render a captures rail from `model.captures` filtered by the focus task id (template id for an occurrence), `.suffix(3)`, listed as "• <body>". Data already exists; the timeline/content just never renders it.
- **Treatment selection not persisted as the new default** (`App/Features/FocusFeature.swift`): `FocusModel.setTreatment` (line 98) only mutates the live session. Have the chip action also set `model.settings.defaultTreatment = t` so the choice seeds future fresh sessions (Android does both `mutateLive` and `updateSettings`).
- **"Save for later" skips the pause-reason prompt** (`App/Features/FocusFeature.swift`): line 351 dismisses immediately and never shows the reason picker even when `focusPauseReasons` is on, so no `ReasonLog` is recorded. Mirror Android: pause, and if `focusPauseReasons` is on show the reasons sheet with an "exit after reason" flag so `dismiss()` runs after the reason is logged; dismiss immediately only when the setting is off.

### assistant
- **Mic-denied / STT-unavailable feedback missing** (`App/Features/AssistantSheet.swift`): `toggleMic()` silently no-ops (`guard voice.sttAvailable else { return }`). Add a `@State note` surfaced in an inline error slot (with an accessibility live-region trait) reading "Mic permission is needed to talk to the assistant." when STT is unavailable / permission denied.
- **`voiceConfigured` over-gates the Talk button** (`App/AppModel.swift:143`): it adds `&& coordinator?.auth.accessToken != nil` that Android lacks, so Talk hides during token-refresh/cold-start even with the proxy URL set. Drop the token check to match Android (or document it as an intentional guard).

### voice
- **Mic-acquisition failure is silent** (`App/Voice/VoiceAudioEngine.swift`): `startCapture`/`ensureStarted` is best-effort and returns silently on `AVAudioSession` activation / `engine.start()` failure, leaving the UI stuck on "Listening…" with a dead mic. Add an `onCaptureError` callback that `VoiceSessionModel` wires to set `note="Couldn't access the microphone — it may be in use by another app."` + `state=.error` and stop the client.

## LOW / Cosmetic Gaps

- **auth** (`AuthView.swift`): empty-email prompt copy diverges — `forgotPassword()` uses a longer curly-quote string; align to "Enter your email first." everywhere.
- **today** (`TodayFeature.swift`): backlog rows lack the amber "Nd" age badge — when `backlogActive`, compute `ageDays` from `t.createdAt` and render an amber capsule (`amberSoft`/`amberInk`) before the estimate (coerce to ≥1d).
- **calendar** (`CalendarFeature.swift`): block fill / external classification and Week-view task-block dimming (`fill.opacity(0.5)`) — verify swatch intensity matches Android's `areaSwatch()`; cosmetic only.
- **calendar** (`CalendarFeature.swift`): connect-failure copy diverges (acceptable since iOS uses `ASWebAuthenticationSession`); align wording only if strict parity desired.
- **collections** (`CollectionsFeature.swift`): item-action reveal uses a persistent trailing ellipsis vs Android's long-press-to-reveal; optionally add `.onLongPressGesture` calling `onReveal`. Reasonable platform adaptation.
- **chrome / shared** (`Chrome.swift`): AppBar lacks the notifications bell + unread badge (and `onMenu`) that Android passes from Calendar/Collections/Tasks. Single shared-chrome fix; tracked as MEDIUM under tasks-list.
- **inbox** (`InboxFeature.swift`): trailing "Done" toolbar button vs Android's leading BACK chevron — functionally equivalent; optionally switch to a leading chevron.
- **inbox** (`InboxFeature.swift`): "from <task>" label uses `.lineLimit(1)` without flexible width vs Android's `weight(1f, fill=false)`; optionally add `.frame(maxWidth:)`. No functional impact.
- **insights** (`AnalyticsFeature.swift`): Report/Deep-dive toggle is local `@State` and resets on re-present; persist via `@SceneStorage`/`@AppStorage` or hoist into the presenting model to match Android's route-persisted flag.
- **insights** (`AnalyticsFeature.swift`): unmatched area color falls back to `ink3`; use `ink4` to match Android `areaColorFor`.
- **insights** (`AnalyticsFeature.swift`): heatmap uses `green.opacity(0.2+0.7*t)` over the card; interpolate `bg2→green` (lerp) instead to match Android's low-intensity cells.
- **settings** (`SettingsFeature.swift`): Accessibility lacks "High contrast" (no iOS analog at all — add `highContrast` property + toggle) and "Keyboard hints" (arguably N/A on touch).
- **settings / notifications** (`NotificationSettingsScreen.swift`): notification level/lead live in a dedicated hub vs Android's Focus section, and render all three blurbs vs one; behaviorally equivalent — presentation divergence only.
- **notifications** (`NotificationSettingsScreen.swift`): reminder-lead options are `[0,5,10,15,30]` (superset); drop `30` to match Android's `[Off,5,10,15]`.
- **onboarding** (`OnboardingFeature.swift`): Welcome step uses `Wordmark(size:28)` instead of the breathing `Orbit(size:88)`; port an Orbit component to UnstuckDesign and center it with vertical padding.
- **onboarding** (`OnboardingFeature.swift`): step content isn't wrapped in a rounded surface card — wrap label + body + footer in a `Radius.lg` (~24) surface card with a `theme.palette.line` border; keep progress dots above.
- **onboarding** (`OnboardingFeature.swift`): picked struggles stored as `Set<String>` (non-deterministic order); store as ordered `[String]` or sort by `struggleOptions` before `completeOnboarding`. Stored-payload-only.
- **focus** (`CaptureTagPicker.swift`): capture tag chips use a generic dot+outline capsule vs Android's filled soft-bg/dark-ink pills, a multi-line field vs single-line, and a different eyebrow/subtitle. Visual only; tag data flow correct.
- **assistant** (`AssistantSheet.swift`): input placeholder stays "Message…" during dictation — make it `assistant.dictating ? "Listening…" : "Message…"`.
- **assistant** (`AssistantSheet.swift`): empty-state hint drops the trailing 'Type or tap the mic.' sentence — add it back now that mic dictation exists.
- **voice** (`VoiceModeScreen.swift`): only `.began` interruptions end the session; optionally also observe `AVAudioSession.routeChangeNotification (.oldDeviceUnavailable)` for headset-removal parity, and verify on-device that another media app's playback raises a `.began` interruption.
- **feedback** (`FeedbackFeature.swift`): disclosure line omits the device model (device is still sent) — append it: `"Sent with v\(AppModel.appVersion) · \(screen) · \(AppModel.deviceModelName)"`.
- **feedback** (`FeedbackFeature.swift`): `screen` is a non-optional String; optionally skip the " · {screen}" segment when blank to mirror Android's nullable `currentScreen`. No data-flow change.