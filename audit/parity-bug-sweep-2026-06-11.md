# iOS Parity Bug-Sweep — Final Report

All 20 findings passed adversarial re-verification. Severities below reflect the verifier's *adjusted* ratings where they differ from the original.

## Summary

**20 verified findings: 1 critical, 6 high, 7 medium, 6 low.** Two of the high findings are the *same* SwiftUI stacked-sheet defect surfaced from different entry points (Inbox-open and notification/deep-link-open) and are merged below, so there are **19 distinct issues**. The dominant risk clusters are the **sync engine** (two concurrency defects that can silently lose or corrupt offline writes) and **auth** (password reset is fully broken on the only flow the app ships). The **voice stack** contributes one real crash path plus several lifecycle/parity nits. Overall read: the data layer and auth must be fixed before any device build ships; the remaining mediums/lows are parity polish that can follow. The recurring root cause across many findings is iOS's narrow `addTask` signature (no `lifeArea`/`firstPhysicalAction` params) forcing mutate-then-resave double-writes, and SwiftUI's single-presenter sheet model where Android uses one nav stack.

---

## Critical

**PKCE forgot-password link logs straight into the app — set-new-password screen never shows**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/AppModel.swift:265-291` (observeAuth) + `:297-313` (handleDeepLink) — *parity*
The client is configured `flowType: .pkce`, so a reset email returns as `unstuck://auth-callback?code=...` with no `type=recovery`; the PKCE exchange emits only `.signedIn`, never `.passwordRecovery`. Both iOS recovery-detection paths are dead for this flow, so a "Forgot password?" link signs the user into the full app and the set-new-password screen is unreachable.
**Fix:** Port Android's amr-probe — in `handleDeepLink`, when `url.host == "auth-callback"` set a one-shot `pendingRecoveryProbe = true`; in `observeAuth`, on the authenticated `.signedIn`/`.initialSession` transition while the probe is set, base64url-decode the access-token JWT and set `pendingPasswordRecovery = true` if `amr` contains an entry with `method == "recovery"`. Clear the probe immediately (one-shot). Keep the existing `.passwordRecovery`/`type=recovery` paths for the implicit flow.

---

## High

**Inbox / notification deep-link opens nothing — dismiss() + present a second sheet in the same runloop tick** *(merges the two stacked-sheet findings)*
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/Features/InboxFeature.swift:198-202` (openTask); also `NotificationCenterScreen.swift:84-90` (tapAction/openTask) — *ui*
`InboxView` is a `.sheet(item: $router.activeSheet)`; `openTask` calls `dismiss()` then synchronously sets `router.detailTask` (a *separate* `.sheet` on the same `MainTabScaffold`). SwiftUI can't reliably present a second sheet from one presenter mid-dismiss, so tapping a task link from the Inbox or a notification frequently opens nothing. Android avoids it via a single nav stack (`pop(); push(Route.Detail)`).
**Fix:** Don't set the scaffold-level sheet while the inner sheet is dismissing. Either have `routeDeepLink` clear `router.activeSheet = nil` and defer the `detailTask` set to the inbox sheet's `onDismiss` (or hop a runloop), or restructure task detail as a `NavigationStack` push within one presentation context like Android. Apply the same fix to `NotificationCenterScreen.openTask`/`tapAction`.

**OutboxFlusher.flush has no drain serialization — concurrent drains interleave via actor reentrancy**
`Sources/UnstuckSync/OutboxFlusher.swift:52-121` — *concurrency*
`flush()` is reachable from four overlapping triggers; Swift actors are reentrant across `await`, so while Task A is suspended in `await apply(op1)` (before `markDone`), Task B re-reads `box.pending()`, re-applies the same op, and both race the shared `failCounts`. The per-pass `blockedRows` set is task-local, defeating the last-writer-wins guarantee Android protects with a `Mutex`.
**Fix:** Serialize drains — chain through a stored in-flight `Task` (await any in-flight drain before starting a new one), or an `isDraining` gate reset via `defer` on every exit/throw. Prefer the task-chaining approach so the bounded sign-out drain can't early-return and let `clearAll()` wipe un-flushed ops.

**Cancelled drain (sign-out 5s timeout / BG-task stop) is mis-counted as an op failure and burns the poison-pill cap**
`Sources/UnstuckSync/OutboxFlusher.swift:96-117` (generic catch) — *concurrency*
The single generic `catch` treats `CancellationError`/`URLError(.cancelled)` like a server rejection: it bumps `failCounts` toward `failCap=5`, after which the op *and its FK dependents* are permanently dropped. A user on a slow connection repeatedly signing out (or a repeatedly-killed BG task) can poison-drop a valid op and lose it forever. Android rethrows `CancellationException` to abort without burning the cap. Nothing checks `Task.isCancelled`, so the loop also keeps iterating post-cancel.
**Fix:** At the top of the catch, `if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }` (and/or `try Task.checkCancellation()` at the loop head) so cancellation aborts without touching `failCounts`/`blockedRows`.

**scheduleTaskAt recurrence branch can leave the chosen date with NO block (coversChosen ignores plan.toDelete)**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/AppModel.swift:513` (scheduleTaskAt, recurrence branch) — *logic*
`coversChosen` counts an existing block on the chosen date even when the regen plan is about to delete it. For an off-pattern existing block on date D, `toUpsert` has nothing for D but `existing.contains{date==D}` is true → the guarantee-upsert is skipped → the delete runs → D ends with no `cal_block`. The recurring task silently vanishes from the very date the user just scheduled it to, despite the "Scheduled" confirmation.
**Fix:** Exclude about-to-be-deleted blocks, matching Android: `let deleting = Set(plan.toDelete); let coversChosen = existing.contains { $0.date == iso && !deleting.contains($0.id) } || plan.toUpsert.contains { $0.date == iso }`.

**STT engine.start() failure leaks the installed tap → next dictation crashes AVAudioEngine**
`App/Voice/VoiceController.swift:91-101` (stopListening; tap install at :69, start at :73) — *crash*
`begin()` installs a mic tap, then calls `try engine.start()`. On a throw (mic contended, session/route race), the catch calls `stopListening()`, which only removes the tap inside `if engine.isRunning` — false after a failed start, so the tap leaks. The next `installTap` on an already-tapped bus is a fatal `AVAudioEngine` precondition and crashes the app.
**Fix:** Remove the tap unconditionally: `if engine.isRunning { engine.stop() }; engine.inputNode.removeTap(onBus: 0)` (`removeTap` is a safe no-op when none is installed).

---

## Medium

**Today list drops completed-today tasks and occurrences instead of keeping them as struck-through wins**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/Features/TodayFeature.swift:71-75` (TodayModel.rows) — *parity*
`rows` returns only `visibleTasks(.today)`, whose bucket hard-filters `!t.done`, so a Today task or recurring occurrence disappears the instant it's completed. Android re-adds today's completions as wins (sorted last) until tomorrow, matching the web list.
**Fix:** In the today branch, append `all.filter { !isTemplate($0) } + projectOccurrences(all, blocks, Clock.todayISO())` filtered to `isCompletedToday($0, now:) && !todayOpen.contains{ $0.id == it.id }`, after the open rows (closed last).

**Start-Next hero task is duplicated in the Today list, and the focused task isn't excluded from the suggestion**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/Features/TodayFeature.swift:68` (startNext) + `:71-75` (rows) — *parity*
`rows` doesn't subtract `startNext?.id` (so the hero task renders again as a plain row — a visible duplicate), `pickStartNext` is called with `liveTaskId: nil` (so an actively-focused task is still suggested), and the area filter is ignored. Android subtracts both ids and scopes by area.
**Fix:** Pass the live session's `taskId` into `pickStartNext` (read from `liveStore`), pass the active area filter, and in `rows` filter out `it.id == startNext?.id` and the live task id, matching `TodayScreen.kt:126/136`.

**Per-session URLSession never invalidated — leaks an operation queue per voice call**
`App/Voice/VoiceRealtimeClient.swift:59-64` (session) / `:111-121` (stop) — *lifecycle*
A fresh per-instance `URLSession` is built for every voice session; `stop()` only cancels the socket and never invalidates the session, so each ended call leaks the session + its internal operation queue for the process lifetime. Android deliberately shares one static OkHttp client.
**Fix:** Either share a single static `URLSession` across clients (mirroring Android), or call `session.invalidateAndCancel()` in `stop()` after cancelling the socket.

**onOpen() fired eagerly before the WebSocket handshake completes**
`App/Voice/VoiceRealtimeClient.swift:104-108` (start) / `:136-146` (onOpen) — *parity*
`start()` calls `t.resume()` then synchronously runs `onOpen()`, which sets `_open=true`, opens the mic, starts playback, and pushes `.listening` before the upgrade succeeds. On an unreachable proxy or rejected token the full audio stack spins up needlessly and the user briefly sees "Listening…", and `interrupt()` (gated on `_open`) can send `response.cancel` before the socket exists. Android only runs this in OkHttp's post-handshake `onOpen`.
**Fix:** Adopt `URLSessionWebSocketDelegate` and move the `onOpen()` body into `urlSession(_:webSocketTask:didOpenWithProtocol:)` so audio/state start only after the handshake opens.

**Feedback/Assistant bubble shows on the Calendar tab (Android hides it there)**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/Features/CalendarFeature.swift:115` (`.feedbackBubble()`) — *parity*
The coral bubble overlays the calendar grid bottom-trailing, exactly where the drag-to-schedule gesture lives; Android gates the bubble with `tab != "calendar"`.
**Fix:** Remove `.feedbackBubble()` from `CalendarView` (keep it on Today/Tasks/Collections), or gate the modifier on `router.tab != .calendar`.

**Device-local personal content not scrubbed on a non-button sign-out — cross-account leak**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/AppModel.swift:265-291` (observeAuth) vs `:327-343` (signOut) — *security*
The UserDefaults scrub (assistant chat history, `archivedCaptureIds`, `NotificationLog`, `NotificationPrefs`, reminders) lives only in the imperative `signOut()`/`deleteAccount()`. Any sign-out not routed through that button — server-side revocation, refresh failure, password-change-elsewhere — wipes the GRDB DB but leaves the prior user's personal content in UserDefaults for the next account on the device. Android scrubs reactively on any `isSignOut`.
**Fix:** Move the scrub into `observeAuth` on a real session→nil transition (run the same `NotificationLog.clear` / `NotificationPrefs.clearUserContent` / `archivedCaptureIds=[]` / `AssistantModel.scrubPersisted` + `_assistant?.clear` / reminder cancel). Keep it idempotent so the button path isn't harmed.

**First task's firstPhysicalAction can be lost via a double unordered write race**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/AppModel.swift:99-108` (completeOnboarding) — *concurrency* (verifier-adjusted high→medium)
The onboarding first task is written twice — `addTask` (no action) then a mutate-and-resave with the action set — each spawning an independent unstructured `Task`. `WriteThrough.upsertTask` is unconditional last-write-wins by execution order, so an inverted resume order can clobber `firstPhysicalAction` locally and in the synced outbox payload. Android builds the complete task in one `addTask` call.
**Fix:** Build the first task with `firstPhysicalAction` in one shot — widen `addTask` (add `lifeArea`/`firstPhysicalAction` params, mirroring Android) or construct the `TaskItem` directly and call `saveTask` once. Never issue two `saveTask` calls for the same id. *(This also resolves the onboarding life-area and promoteCapture double-write lows below.)*

---

## Low

**Onboarding first task is not tagged with the user's life area**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/AppModel.swift:101` — *parity* (medium→low)
iOS `addTask` has no `lifeArea` param, so the first task is created `lifeArea = nil`; Android files it under `pickedAreas.firstOrNull()`. **Fix:** Thread the first *picked* area (preserve picked order, not `Set` iteration order) into the single `addTask` call. *(Folds into the widened-`addTask` fix above.)*

**Onboarding first-task estimate differs from Android (25 vs 15 min)**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/AppModel.swift:101` — *parity*
iOS uses `settings.focusDefaultMin` (defaults 25); Android hardcodes `estimateMin = 15` to match the "Small is good" copy. **Fix:** Hardcode `15` for the onboarding first task.

**promoteCapture writes the new task twice (nil life area, then "Work")**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/AppModel+Captures.swift:62-71` — *logic*
`addTask` saves once with `lifeArea = nil`, then a mutate-and-resave writes `"Work"` — a redundant double upsert/outbox enqueue with a brief "—" window. Android passes `lifeArea = "Work"` into one `addTask`. **Fix:** Use the widened `addTask(... lifeArea: "Work" ...)` and return the task with no second `saveTask`. *(Folds into the widened-`addTask` fix above.)*

**Capture tag badge renders lowercase on iOS vs uppercase on Android**
`/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/Features/InboxFeature.swift:147` — *parity* (medium→low)
`CaptureTag` rawValues are lowercase and `UFont.mono` applies no case transform, so the bold mono chip shows "follow-up"/"idea"; Android renders the enum constant name uppercased. **Fix:** `Text(cap.tag.rawValue.uppercased())` (rawValue already uses `-`, no replace needed).

**Per-session voice barge-in drops part of the user's mic audio (flushPlayback clears the capture buffer)**
`App/Voice/VoiceAudioEngine.swift:157` — *parity*
`flushPlayback()` (the barge-in path) calls `pending.removeAll()`, but `pending` is the *capture* accumulator, discarding up to ~100ms of just-spoken leading audio. Android's `flushPlayback()` touches only playback state. **Fix:** Remove the `pending.removeAll()` from `flushPlayback()`; clear capture state only on session teardown if ever needed.

**VoiceController.request/task mutated off-lock in begin() while stopListening() reads them under lock**
`App/Voice/VoiceController.swift:65,75` (begin) vs `:91-101` (stopListening) — *concurrency*
`begin()` assigns `request`/`task` without the `lock` that `stopListening()` uses to read/write them, and the two run on different completion threads — a data race under the file's own locking contract (crash risk low, but real). **Fix:** Take `lock` around the `request`/`task` assignments in `begin()`.

---

## Recommended fix order (before a device build)

1. **PKCE password recovery** (critical) — password reset is completely broken on the shipping flow; amr-probe port.
2. **OutboxFlusher drain serialization + cancellation rethrow** (two highs, same file) — silent loss/corruption of offline writes; fix together.
3. **scheduleTaskAt `coversChosen`** (high) — silent disappearance of a just-scheduled recurring task; one-line guard.
4. **Stacked-sheet deep-link** (high, merged) — Inbox/notification "Open" silently does nothing; fix `routeDeepLink` defer + apply to NotificationCenter.
5. **STT tap leak** (high) — hard crash on the next dictation after a contended `start()`; one-line unconditional `removeTap`.
6. **Non-button sign-out scrub** (medium, security) — cross-account personal-content leak; move scrub into `observeAuth`.
7. **Widen `addTask`** (one change clearing the firstPhysicalAction race + onboarding life-area + promoteCapture double-write).
8. **Today-list parity pair** — completed-today wins + Start-Next duplicate/live/area exclusion.
9. **Voice lifecycle/parity batch** — URLSession invalidation, handshake-gated `onOpen`, `flushPlayback` capture-clear, `VoiceController` off-lock.
10. **Cosmetic parity** — Calendar bubble, onboarding 15-min estimate, uppercase capture tag.