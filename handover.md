# Handover — unstuck_ios

Living doc for resuming the iOS build across sessions. Update it as
phases land. Newest status at the top.

- Ship: 1.1.1 (71) uploaded to TestFlight (delivery 680be3e7) — tools v2 + the voice guard's tool-backed rule (ok: from a tool that changes something, not reads or navigation), 2026-09-20.

- Ship: 1.1.1 (72) uploaded to TestFlight — the calls build-out (iOS half) on top of build 71; the backend (migration 072, send-call, call-outcome) is live in prod. 2026-09-20.

- Ship: 1.1.1 (73) uploaded to TestFlight — a promised action is a claim + the voice CALLS rule (see the entry below). 2026-09-20.

- Ship: 1.1.1 (74) uploaded to TestFlight — the tiered echo verdict (your words are no longer deleted as "echo" after a reply ends) + the corrective forces the tool call. 2026-09-20.

- Ship: 1.1.1 (75) uploaded to TestFlight — the three harness fixes from Zubair's evening call (the call is handed today's facts; the completed view is dated; a swallowed create is re-asked). The VOICE MODEL is now OpenAI gpt-realtime-2.1-mini via the proxy (no app change). 2026-09-20.

- Ship: 1.1.1 (76) uploaded to TestFlight — task lines carry their creation date; a rate-limited reply is retried after the bucket's reset and says so instead of going silent; the insights "week" window says when it is only a day old. 2026-09-21.

- Ship: 1.1.1 (77) uploaded to TestFlight — calls greet once (the primer no longer quotes the opening); carry_to_tomorrow leaves a done task alone; a one-word answer is never dropped as echo. 2026-09-21.

- Ship: 1.1.1 (78) uploaded to TestFlight — the pre-beta audit fixes: the "busy" message is actually shown, provider errors are plain words, calls ask for the microphone, a failure mid-call ends the call, declined-call notices are silent, travel re-pushes the timezone, and Settings can clear the Assistant history. 2026-09-22.

- Ship: 1.1.1 (79) uploaded to TestFlight — the recurrence + duplicate fixes from the audit: the series anchors on the next LIVE occurrence, the horizon is topped up, duplicate task creation is refused, estimates/durations are clamped, complete_occurrence has the done-guard. 2026-09-22.

- Ship: 1.1.1 (80) uploaded to TestFlight — the token diet: voice tool schemas compacted (~36 % off the block, no tool or value removed) and a route change no longer re-uploads the whole session. 2026-09-22.

- Ship: 1.1.1 (81) uploaded to TestFlight (delivery d3874e6a) — the 20 P0/P1 fixes from the pre-launch audit (C1–C20, see the entry below); backend migration 075 + seven edge functions + the voice-proxy Worker deployed first. 2026-09-23.

- Ship: 1.1.1 (82) uploaded to TestFlight (delivery 1ed15995) — three fixes the web/Android audits found on iOS too: a repeating task's day starts focus at zero, calls ring about tasks not yet synced here, Google connect disclosure. 2026-09-23.

- Ship: 1.1.1 (83) uploaded to TestFlight (delivery 06ef3e9c) — a reply cut on air is truncated to what the user heard (conversation.item.truncate), so 'carry on' resumes the same point. Server: missed calls re-ring every 5 min, 4 rings (migration 076). 2026-09-23.

- Ship: 1.1.1 (84) uploaded (delivery d6602f1b) — list items: tap strikes out, swipe left Delete, swipe right Pin/To task, hold edits; Google reconnect is a plain card (never 'invalid_grant (400)'). 2026-09-23.

- Ship: 1.1.1 (85) uploaded (delivery f1ff0fe0) — STAGE 2, same id for same day (C21): deterministic occurrence ids, insert-if-absent, rules A/B/G/H, serialised top-up after a good pull; every minted occurrence mirrored to Google after a confirmed insert (Ahmad: 'every day, everywhere'). 2026-09-23.

- Ship: 1.1.1 (86) uploaded (delivery 020de96f) — THE BETA BUILD: audit P2 batches 1–5 (C23 C24 C25 C26 C28 C29 C30 C31 C35 C36 C37 C38 C39 C41 C42 C43 C44 C46 C47) + Gregorian stored dates. 2026-09-23.









## Bottom bar: the + sits in the row (branch tabbar/ios, 2026-09-24) — not shipped yet

Ahmad: "Can the plus just be on same line as everything". The coral + was a 56-pt square lifted 28 pt above the bar
(it covered the last row scrolled under it); it is now the middle one of FIVE equal slots — Today · Tasks · + ·
Calendar · Collections — a flat 44×44, 13-pt rounded coral square (white SF "plus" 20 pt semibold, no shadow),
centred on the tab cells (icon pill + label) so it reads as one line. Same as Android's BottomNavBar.kt.

- **One baseline.** Every tab icon draws in the same 24×22 box (`BottomNavBar.iconBox`): the taller
  `square.stack.3d.up` used to make the Collections cell taller, so its label sat ~3 pt below the others. Labels are
  held to one line (`minimumScaleFactor(0.8)`), so a wrapped label can't knock a cell off the row.
- **Unchanged:** `onFab` / `fabAction`, the VoiceOver label (`fabLabel`), the tour's `new-task` anchor (now hugging
  the 44-pt square), the hairline, bar colour, safe area, the active pill, theme coral. Only the 44×44 square takes
  taps (the rest of its slot is dead, as the old gap was).
- **Left alone on purpose:** every tab root still pads 96 pt at the bottom ("clear the floating bottom nav"), and the
  assistant launcher's 96 pt is matched to it. The bar is now 60.3 pt (was 63.7 + the 28-pt lift), so a list scrolled
  to its end shows ~36 pt of empty space above the bar. Trimming it (to ~68–72) moves the launcher — Ahmad's call.
- `tourTarget` reads a new `\.tourAnchorsEnabled` environment switch (default on, never set by the app): only
  off-screen snapshots turn it off, because ImageRenderer paints a yellow placeholder for the UIKit anchor view.
- Test: `FabActionTests.testThePlusSitsInTheTabRow` renders the bar (ImageRenderer, 3x, 430 pt, light + dark, Today
  + Collections active) and checks from the pixels: + is 44 pt, horizontally centred, centred on the cells, no coral
  above the hairline, the four label tops within 1 pt. It fails on the old bar. PNGs only when `UNSTUCK_RENDER_DIR`
  is set (`TEST_RUNNER_UNSTUCK_RENDER_DIR=…` on xcodebuild).

## Every N weeks (branch nweeks/ios, 2026-09-24) — not shipped yet

Zubair asked for "every two weeks on Thursdays"; Ahmad approved it the same morning (week = ISO Monday; UI chips
Every week · 2 · 3 · 4 weeks, the assistant up to 8; "Starts" chips shown; moving days keeps the rhythm; Schedule on a
series re-anchors). Normative spec: every-n-weeks-spec.md (scratchpad of that run); shared vectors
`unstuck/lib/recurrence-vectors.json` → `Tests/UnstuckCoreTests/RecurrenceVectors.generated.swift`.

- **Model + codec.** `Recurrence.everyNWeeks(interval:daysOfWeek:anchor:until:)` =
  `{"kind":"everyNWeeks","interval":2,"daysOfWeek":[4],"anchor":"2026-09-21"}`. Strict decode (§2): integral interval
  ≥ 1 (2.0 ok; "2", true, 2.5 no), anchor a real strict YYYY-MM-DD (`strictEpochDay`, never `LocalDate.parse`), days
  all integral numbers; anything else → the unknown sentinel (never a throw). Old builds (≤ b92) read it as the
  sentinel and write that back whole — migration 081 (web/backend) keeps the stored rule.
- **The rule (Recurrence.swift).** Week index = whole weeks between Mondays in EPOCH DAYS from civil fields
  (`civilEpochDay`, pure integer math) — never instants, never the ISO week number. `isRuleDay`, `seriesAnchor`,
  `nextRuleDate`, `startsChips`, `recurrenceEditAnchor` (§5), `reanchoredForSchedule`, `weeklyRule` (N 1 → weekly),
  `occurrenceReach` over the 7N cycle, labels ("Repeats every 2 weeks on Thu"). `recurrenceEditStart` returns TODAY
  + 56 days for an N-week rule (E1/E2). Top-up/regenerate/Google/analytics need nothing else (blocks carry no rule).
- **Writers.** Create sheet: Weekly → weeks chips + "Starts" chips (`createSeriesStart`): the FIRST chip is scheduled
  from the WHEN day, exactly as weekly (an off-pattern day keeps its one-off — web and Android do the same); a LATER
  chip is scheduled on its own day, so the schedule step never re-anchors away from the picked week. Task editor:
  same rows; day toggles keep N and the stored weeks; the Schedule seed is a date the rule has.
  `AppModel.scheduleTaskAt` re-anchors an N-week series on an off-week day (row written first, then blocks).
- **Assistant.** `set_task_recurrence.intervalWeeks` (1–8, omitted = keep N, 1 = weekly); errors per §7.2; the ok
  line names the rhythm, the next two live on-rule dates ("— next Thu 24 Sep (today), then Thu 8 Oct") and a change
  ("— every week now; it was every 2 weeks"). `schedule_task`: off-week guard (refused once, nearest rule dates up to
  7N days away, then a one-off) except on a FIRST placement, which re-anchors. Receipt reads the rhythm from the
  result. Voice REPEATS rule = `prompts.voiceRepeatsRule`. `ToolRegistry.caps` now reports `recurrence_interval`.
- **Patterns** skip every-N-weeks templates (no "still on for Sunday?" on an off week).
- **Readers are total for ANY stored rule** (review, same day): readers accept any integral interval ≥ 1, so
  nothing computes an unclamped 7N or scans 7N days — `nextRuleDate` is computed directly (was a 7N-day scan: a
  million-week rule froze the editor), `floorMod` is `m < 0 ? m + n : m` (the old `(a % n + n) % n` trapped for N near
  Int.max, in materialize → the launch top-up), `occurrenceReach`/`nearestRuleDates` clamp the cycle, `startsChips`
  makes at most 8. A non-string `until` under everyNWeeks decodes to the sentinel instead of throwing (the hydrate
  drops a row that throws).
- Tests: `EveryNWeeksVectorTests` (all §9 tables, materialize in UTC + New York + Auckland, the b92 codec as a
  fixed point), `EveryNWeeksReviewTests` (direct next date = a day-by-day scan over 12 700 rules; huge intervals;
  malformed until; the create sheet never re-anchors the picked week; §9.1 in Havana/Beirut/Santiago/Chatham, where
  DST starts AT midnight on V10's own Sundays), `SeriesOffWeekTests`, receipts, DbRowCodec; app
  `EveryNWeeksExecutorTests` (X1–X9 + E2/E3 through the executor), voice compaction keeps "every 2–8 weeks".

- **Cross-platform agreement (same day; web 17181ed is canonical where the spec is silent).** Mirrored the web
  review's three fixes: an assistant FIRST placement writes the re-anchored task row before ANY block (and not at all
  when that day's occurrence is already done); a same-N edit counts the "Starts" chips on the EDITED days
  (`startsBase`, web's helper); the off-week guard judges the week without `until` (iOS already did — now pinned).
  Plus: a no-repeat/daily/monthly task whose only blocks are past starts its weeks from TODAY (`startsBase` → a block
  counts only when it is ahead); every writer stores a Monday anchor (`weeklyRule`/`mondayIso`, the editor's until
  path too); the `set_task_recurrence` ok line is how · at · until · rhythm change · next dates · done note (web and
  Android's order). Vectors: the new `startsBase` list, editAnchor past-block/Monday cases and X10–X16 (hand-ported
  into `EveryNWeeksExecutorTests`; the app target can't read the SwiftPM vector file).

- **Cross-platform verification (same day).** A random differential harness (390 rules, 150 anchors/chips, 250 edits,
  220 top-ups, 350 repeat edits, UTC and New York) ran the same inputs through web, iOS and Android. Fixed on iOS to
  match web (canonical) and the spec: `regenerateForTask` keeps the HISTORY RULE (spec §5 — a future occurrence done or
  skipped is never deleted or rewritten open; a day settled that way gets no second open one; iOS used to delete them,
  and a time change re-opened a day done early); the create sheet always places the WHEN day (a later "Starts" chip
  only moves week one — `createSeriesStart` → picked day, `scheduleTaskAt(reanchor: false)`); `startsChips` is empty
  below N = 2; the context and task lines say `repeatsEveryWeeks` / " · repeats every N weeks" (web and Android did).
  Vectors: E4 (the history rule) and a startsChips N = 1 case.

## Today week pill: always shown (2026-09-24) — not shipped yet

Ahmad's iPhone Today had no pill ("Where is the insight button??"): it hid at 0 focused, and it is Today's only way
into Insights. `UnstuckCore.weekPill(tasks:blocks:sessions:now:)` (PeriodFacts.swift) → `WeekPill`: focus this week
→ "This week · 2h 5m focused →"; else Mon/Tue with this week EMPTY (no focus, nothing done) and focus last week →
"Last week · … focused →" (opens Insights on last week); else done this week → "3 done this week →"; else "Your week
→". Numbers are periodFacts over the Insights "This week" window (same cut), so the pill and the page agree. The view
(TodayFeature `weekPill`) keeps the capsule, ink2/ink runs and the coral dot. Tests: `WeekPillTests` (the shared
`weekPill` vectors P1–P10 from web's period-review-vectors.json, plus the three states, early week, local zone).

## Zubair's morning call fixes (branch zubair/ios, 2026-09-24) — not shipped yet

From prod assistant_turns, session 1cbfac75 (07:01–07:03 UTC). Web did its half in the same run (commits cbad570, d7441b7).

- **Tool calls hold every create (BargeIn header §7).** The reply said "One moment." and called set_task_recurrence;
  its done asked for his second turn BEFORE the tool's output went back, the model answered without it ("I tried to
  cancel the repeat, but it didn't go through" over an ok) and the continuation's own create was refused. Now
  `.toolStarted` puts a hold on (`continuationOwed`): no turn ask, no 2.5 s fallback, no minutes notice, no
  integrity corrective (`shouldCorrect(toolsPending:)`) until every output is back AND the calling reply is done;
  then ONE `.continueAfterTools` create answers the outputs and any turn that waited (its hold since they spoke still
  applies). A failing tool sends its error output and releases the same way; a tool still out after 10 s
  (`toolTimeoutMs`) gets `VoiceRealtimeClient.toolTimeoutOutput` (`.expireTools`, sent under the lock the tool Task
  claims its call with — the output is always on the wire before the create) and its late result is dropped; a done
  that never comes is released by the same clock. Hold-to-talk: a release while a tool runs commits only
  (`.commitInput`). The old 120 ms `scheduleContinue` timer is gone. Talk and calls share the client, so both get it.
  Tests: BargeInTests 31a–i (31a replays 07:02:44–50), VoiceToolHoldTests (the real client, real frames).
- **The opening said twice.** Not a logging bug: the model spoke "Morning. Want to walk through today?" as two message
  items in one response (two transcript rows, same response id; 96 output audio tokens where the line takes ~48 at
  that session's rate) — the build-77 primer fix made it rarer, not impossible. `RepeatedSpeechFilter` holds a later
  item's audio/caption while its words are still an earlier item's word for word; the first new word plays everything
  held; a whole repeat is dropped and `conversation.item.delete`d at the done (event id `evt_repeat_delete_N`, its
  refusal swallowed). The proxy still logs what the model generated (two rows + a "client discarded item" row).
- **Tools (as web).** `set_task_recurrence` kind none on a task that doesn't repeat → `ok: "X" already doesn't repeat —
  nothing to change`; `schedule_task` into the task's exact live slot (strict H:MM[:SS], never for a Later task) →
  `ok: "X" is already on <date> at <HH:MM> — nothing to change`, no write, still anchors a set_task_recurrence after it.
  Receipts: an ok ending `NOTHING_TO_CHANGE` gets no card; kind none reads "Repeat removed". Voice prompt carries web's
  REPEATS_RULE verbatim (unsupported repeats said first, offered as a question).
- **Open (review, same day) — the no-tool variant still asks twice.** The 50.333 create was also a second ask for
  "I'll just leave it in only for today.": that segment's speech had ended before the 48.106 create (so the reply
  heard it), but its transcript landed just after the create and re-opened the turn (`since > sent` at
  response.created). With a tool call it now rides on the one continuation; with NO tool the same timing still sends
  a second `response.create` at the reply's done (probed against this branch: `creates(done) == 1`,
  `pendingCreate == true`). It fires whenever the last segment of a multi-segment turn is transcribed more than
  `turnHoldMs` after its speech_stopped — 2 of the 3 multi-segment turns in this call were. Fix idea: a final
  transcript for a segment whose `stoppedAt` precedes an in-flight / answering turn ask is already answered (caption
  it, don't re-open the turn, don't cancel that reply); keep notice creates out of it. Needs its own review.

## James's assistant reports + analytics alignment (branch polish/ios, 2026-09-24) — not shipped yet

Same behaviour is being built on web and Android the same night; keep the wording in step.

- **Wrong date (A1).** `schedule_task` refuses a WEEKLY series on a day it doesn't repeat on (James's Saturday park run
  landed on Sunday 20 Sep): `rejectOffSeriesDay` (UnstuckCore/Logic/SeriesWeekday.swift) names the nearest real days in
  plain words ("Saturday 19 September (2026-09-19) or Saturday 26 September …"); nothing is written. The SAME call made
  again in the turn/voice session (`TurnScratch.offDayRefused`) is the model confirming a one-off the user asked for —
  it goes through and the ok-result says "— a one-off on Sunday 20 September; the series stays on Saturday". A day
  that already holds one of the task's occurrences (a one-off moved there earlier) is not checked — retiming it goes
  straight through, as on web and Android.
  `set_task_recurrence` weekly refuses when the slot placed EARLIER THIS TURN (create_task/schedule_task with a date,
  `scratch.placedBlocks`) is on a day the new days don't include (`rejectOffSeriesPlacement`) — the create-on-Sunday-then-
  weekly-Saturday variant that started the series a week late. create_task itself never makes a series, so it has no check.
- **Receipts (A2).** "Undo all" is the turn that JUST finished only (`AssistantModel.undoAllTarget(_:nowMs:)`, Android's
  rule: newest displayed turn with receipts, no user message after it, landed ≤ 15 min ago, still has an Undo) and asks
  first, naming every change (alert in AssistantSheet). A commit keeps the LIVE copy of older turns
  (`mergeCommitted`), so an Undo tapped mid-turn stays used. Confirm-first is enforced in CODE:
  `AssistantHarness.confirmFirstRefusal` runs before any registry `confirmFirst` tool (delete_task, delete_list,
  leave_list, delete_area, delete_tag, cancel_focus) and refuses unless the user's latest message asks for it by name,
  points at what the assistant just named ("delete it"), asks sweepingly ("delete all my done tasks"), or is a yes to the
  assistant's previous delete question (`ConfirmFirst.allows`, UnstuckCore/Logic/ConfirmFirst.swift). A yes is a short
  answer that starts with one ("I'll do it on Friday" / "please add milk" are not), it answers the thing the QUESTION
  named (not another name earlier in the reply), and a message that opens with a no ("No, leave it") asks only for
  what it names. TEXT harness only — the voice path (Talk + calls, `runVoiceTool`) is not gated yet.
- **Analytics (B), picked rules, all three apps:** an area outside the user's list is its own series by name
  (`areaSeries`/`weekdayAreaBars`, web's rule; "No area" only when some session has none); repeating series sort kept →
  due → name; the voice review flag clears only on `.createResponse`/`.commitAndRespond` (already so since 5316fe2, now
  pinned with the echo test); a runaway's START for golden hours + interruptions = completedAt − what it really ran,
  weighted by its counted length (`realSessionStartMs`, Android's rule; callers now pass RAW sessions to `goldenHours`
  and `interruptionBins`, which run the D1 filter themselves; a capture "before the start" lands in bin 0 like web and
  Android); "All time" starts at the earliest task created / task DONE / counted session end (a reopened task's old
  completion no longer counts); `get_insights` minutes are floor((sec+30)/60) written 45m / 2h / 1h 5m (Focus, median,
  Planned).

## AI-consent gate (branch launch/ai-consent-ios, 2026-09-24) — not shipped yet

**Why:** Apple guideline 5.1.2(i) — disclose and get explicit permission before personal data goes to a third-party AI.
Until now only small print in the memory screens said "our AI provider". Shared contract with the web (same copy, keys, version):

- **Storage:** Supabase auth `user_metadata { ai_consent_at: <ISO>, ai_consent_version: "2026-09-24" }` via
  `auth.update(user: UserAttributes(data:))` (`AuthService.setAIConsent`; off sends `ai_consent_at: null`, which GoTrue deletes).
  It counts only while the version matches `AIConsent.version` (bump it on a provider change → everyone is asked again).
  Device copy: `AIConsentStore` (UserDefaults `unstuck.aiConsent`, `{userId, record, pending}`), wiped at sign-out. Merge rule
  (`AIConsent.merge`): a change made here that hasn't landed wins and is re-sent; the session saved at launch only fills an empty
  copy; a fresh read (`GET /user` at launch, sign-in, each foreground ≤1/min, and before every ask) replaces it.
- **The one gate:** `AppModel.withAIConsent(action, from: host) { … }`. Granted → runs now. Otherwise one quick account read
  (≤1.5 s), then the sheet (`AIConsentSheet`, AssistantSheet.swift) from the surface that asked (`.aiConsentSheet(host)` on
  AssistantSheet / TodayView / CallSettingsView / CallMeSection / Settings › Interface / MainTabScaffold). Agree runs the action
  once the sheet is gone; "Not now" (or swipe) skips it and the surface shows `AIConsent.decline(action).note`.
  An ask whose sheet never comes up (the panel closed during the read, or its surface was busy presenting) is dropped after
  2 s (`presentAIConsentAsk`) — otherwise it would silence every later gate until relaunch; a sheet torn down under its
  surface (deep link / tour closing the panel) counts as "Not now" (`aiConsentSheetGone`). A fresh read that started before
  a change made here never overwrites it (`aiConsentPushGen`).
- **Gated:** assistant send + chips + dictation auto-send, Talk (sheet button + Today's mic), Siri "Ask Unstuck" (prompt waits in
  the composer), Calls master switch on, proactive calls on, test call, a task's "Call me about this". Backstops: `AssistantModel.send`
  (error `consent`, nothing sent), `tourAsk` (canned answers), `VoiceSessionModel.start`, the call launcher.
- **Calls:** app open with Calls on for the account (this phone's switch AND a proactive call or a live booked call) and no OK
  → asked once per launch; "Not now" turns Calls off (switch + proactive, account-wide) and an alert says so. An incoming call
  without the OK is declined on receipt (`CallEnvironment.hasAIConsent`, after the calls-off rule) with a quiet notification
  carrying the notes; a fallback-B tap is declined the same way. A call that passes the receipt rules re-reads the OK while it
  rings (`CallEnvironment.callWillRing`), so one turned off on the web / another phone is caught at the answer: the launcher
  refuses (`CallEndReason.noAIConsent` → outcome done, note "no AI consent", a normal alert with the way back on).
  Messages queued behind a running turn are dropped unsent if sharing is turned off meanwhile (`AssistantModel.drainQueue`).
- **Settings › Interface › "AI data sharing":** shows On/Off; off = clear + Calls off; on = the sheet.
- **Not done:** no server-side enforcement (older builds must keep working) — follow-up. Android needs the same gate.
  UI tests boot with the OK granted (`UITEST_AI_CONSENT=0` boots without it).

## App-confirm links (build 88) — shipped 2026-09-23

**Why** (owner decision 2026-09-23, "Proper fix in the apps"): an app sign-up's email carried Supabase's own link, which ends
at `unstuck://auth-callback?code=…`. A phone opens that; a COMPUTER can't — dead end. Shared contract with web + Android:

- **Requests:** sign-up and magic link now pass redirect **`unstuck://auth-confirm`** (exact string, `AppConfirmLink.redirectTo`,
  on the Supabase allow list). iOS has no sign-up "resend" button, so there is no third request here. **Password reset keeps
  `unstuck://auth-callback`** (PKCE `?code` + the JWT `amr` recovery probe) and Google sign-in is untouched.
- **Email link:** the templates (other agent) turn that redirect into
  `https://unstucknow.io/auth/app-confirm/?token_hash=<hash>&type=<signup|magiclink>`. The AASA claims `/auth/app-confirm` and
  `/auth/app-confirm/*` for M9ULD6M5Z3.io.unstucknow.app (existing `applinks:unstucknow.io` entitlement; NOT `/auth/confirm`).
  On a computer the same URL is a web page: "confirmed — open the app".
- **In the app:** the Universal Link arrives through `onContinueUserActivity` → `AppModel.handleDeepLink` → `AppConfirmLink.parse`
  (UnstuckCore: path with/without trailing slash, hash 1…1024 chars, type signup|magiclink|email, extra params ignored; an error
  redirect `#error_code=otp_expired` = "used"; `unstuck://auth-confirm?token_hash=…` accepted too, and `unstuck://auth-confirm?code=…`
  — what an old template would produce — is exchanged like auth-callback). Signed out → "Checking your link…" on the sign-in
  screen → `AuthService.verifyEmailLink` = `auth.verifyOTP(tokenHash:type:)` (no PKCE verifier needed) → the SDK emits `.signedIn`
  → observeAuth + SyncCoordinator land it exactly like an auth-callback exchange (hydrate, onboarding gate, push). Failure →
  the sign-in banner: used/expired ("already been used or has expired … just sign in"), incomplete, or network ("tap the link
  again"); the wait is capped at 20 s, never a hang. A cold launch stashes the URL and replays it at the end of `start()`.
- **Already signed in when a link lands:** the link is NOT used (verifying would replace the session with whichever account it
  belongs to); an "Already signed in" alert says sign out first, then tap it again. For contrast, the OLD auth-callback path has
  no such guard: it exchanges whenever this phone holds the PKCE verifier (i.e. the email was asked for on this phone) and the
  session is replaced in place (SyncCoordinator parks + wipes the old user's cache; AppModel's device-local scrub does NOT run);
  with no matching verifier it fails silently. Left as is.
- **Also in this branch — sign-up with an already-registered email** (owner, 2026-09-23): GoTrue answers 200, no session, no
  email sent, user `identities: []`. supabase-swift decodes that as `AuthResponse.user` with `identities == []` (checked in the
  SDK source + `SignUpResponseTests` through the SDK's own decoder); nil identities never counts. The sign-up screen now says
  "An account with this email already exists. Sign in instead." with **Sign in instead** (keeps email + password) and
  **Forgot password?** right under it, instead of the dead-end "check your email".
- **Device test (new build):** (1) sign up with a real inbox in the app → tap the email ON THE PHONE → the app opens signed in
  (onboarding). (2) Sign up again with another inbox, open that email ON A COMPUTER → the web page says confirmed / open the app;
  then sign in in the app with the password. (3) Tap the phone link a second time while signed in → "Already signed in" alert;
  sign out and tap it → "already been used … just sign in". (4) An email from an OLDER build (auth-callback link) still opens the
  app signed in. (5) Forgot password still opens "Set a new password". (6) Sign up with an address that already has an account →
  the "already exists" line + Sign in instead / Forgot password. Never use made-up addresses on prod; delete test accounts after.

## Where things stand (2026-09-23, late night) — build 88: sign-up links that work anywhere; UI tests green again

- **Web W16 root fix (live 20:15):** prod templates 01 (sign-up) + 02 (magic link) branch on RedirectTo —
  `unstuck://auth-callback` (every build ≤ 87) → Supabase's ConfirmationURL, unchanged; `unstuck://auth-confirm` (build 88+,
  Android vc104+) → https://unstucknow.io/auth/app-confirm/?token_hash=…&type=…; anything else (the web) → /auth/confirm/?token_hash=….
  Password reset untouched. Plan/rollback: unstuck/supabase/email-templates/TOKENHASH-SWITCH.md. Ahmad's real sign-up test passed
  (confirmed on first click, "You're in"; re-opened link → carried on signed in).
- **Build 88:** signUp + signInWithOTP pass `unstuck://auth-confirm`; the AASA claims /auth/app-confirm(/*) (Apple CDN already
  serving it); the link is verified in-app with verifyOTP(tokenHash:type:). Signed in as someone else → "Already signed in" alert,
  the link is not used. Sign-up with an already-registered email → "An account with this email already exists. Sign in instead."
  with Sign in instead / Forgot password?. See "App-confirm links (build 88)" below for the device test.
- **UI tests:** the 4 b87 failures were stale tests (list rows are Buttons since b84; the Share picker moved in b59; the assistant
  sheet was never actually dismissed) — fixed, no app bugs. `-only-testing:UnstuckUITests` on build 88 = 22 run, 0 failures.
  OPEN (test infra): in ONE xcodebuild run of app unit tests THEN UI tests on the same simulator, every demo-boot UI test opened on
  the tour welcome (77 failures; results kept at scratchpad/results/b88all-combined-run.xcresult). Each suite alone is green. Run the
  two targets separately until that's understood.
- **Web (unstuck main):** the sign-up page now says "already registered" (supabase-js 2.106 drops the user from no-session sign-ups;
  lib/supabase/signup-tell.ts reads the identity count off the wire; upgrading to ≥ 2.117 is the long-term fix).

## Where things stand (2026-09-23, night) — build 87: daily voice minutes

- **Ahmad's decision** (DECISIONS.md "Voice minutes"): ONE allowance for Talk AND assistant calls, 10 min per user per LOCAL day
  (notification_preferences.timezone); the team (Ahmad's and Zubair's accounts + the App Review demo) gets 60. Out of minutes →
  a call does not ring and a quiet "Call skipped" bell card is written; one spoken warning at a minute left.
- **Where it is enforced:** the voice-proxy Worker (unstuck `workers/voice-proxy`) + migration 077 (`voice_usage` ledger,
  `voice_allowances`, RPCs `voice_seconds_remaining` / `record_voice_seconds`, `dispatch_calls` skip). The Worker sends
  `{"type":"unstuck.voice_budget","remaining_ms":…,"warn":…}` frames, charges every two minutes and at close, and hangs up 1008
  when the minutes run out; a connect with none left is refused (Android gets the 429 it already maps).
- **iOS client:** VoiceModeScreen shows "N min left today" (counted down between the proxy's figures); BargeIn/VoiceRealtimeClient
  speak the one warning without breaking turn-taking; the daily-limit close ends a call normally and reads as the minutes even
  with no close code; NotificationCenterScreen shows the skipped-call card.
- **Tests:** 1270 package tests green; app unit tests green (bar the known CrashBreadcrumbs order flake). A FULL run including
  UITests showed 4 UI-test failures in screens b87 does not touch (collections detail open, calendar Next day, share People card) —
  the ship loop had only been running `-only-testing:UnstuckAppTests`; triage on branch fix/ui-tests.
- **Also live tonight (backend):** migration 078 — push tokens carry the auth session (`device_tokens.session_id`); every sender
  reads `live_device_tokens`, so a remote sign-out / password change stops pushes and calls to that phone. Clients can no longer
  INSERT/UPDATE device_tokens directly (registration goes through `register-push-token`; the client DELETE on sign-out still works).
- **Device checks for Ahmad:** Talk shows the minutes line; the spoken warning at 1 min; a 0-minute account is refused in plain
  words; a scheduled call with no minutes left doesn't ring and leaves the bell card; sign out everywhere on web → a test call
  must not ring on the phone.

## Where things stand (2026-09-23, evening) — build 86: the beta build (audit P2 batches 1–5 + Gregorian dates)

Ahmad: "work on 1 to 5, then I will do all that's required to start beta testing by end of day". Six groups, each implemented → adversarially reviewed → fixed up (results: audit/prelaunch-2026-09-22/p2-batch-results.json; evidence: p2-batch-input.json). Merge conflicts were resolved by hand:
- **Sign-out warning.** privacy's `AppModel.unsyncedSignOutWarning` is kept and fed `max(quarantinedSyncCount, stuckChanges)` from C28; sync's second alert is dropped.
- **Notification actions.** They carry focus's session ids (C38) plus life's `runsInBackground` and background-time flush (C31).
- **Task delete.** It is life's one-transaction `WriteThrough.deleteTask` returning the removed blocks, and each block goes through `forgetDeletedBlock`: mirror gate, Google pushes/backlog, Google delete of the row as deleted, pending-insert abandon, reminder cancel. google's read-back of the blocks after the delete would have found none.

What each batch did:
- **Sync (C28, C29, C30).**
  - C28: a Today card says "N changes couldn't be saved — only on this phone" with Try again and Discard. The quarantine is released once per build. Name-clash 23505s adopt the server row. Capture bodies are clamped. Dates and times are validated before writing.
  - C29: sessions and reason_logs page by the server's updated_at. The id sweep also takes rows the server has that this device lacks, and stamp-different rows with no queued write.
  - C30: RealtimeHealPolicy rebuilds channels that never subscribed or survived a socket drop, with 5 s→300 s back-off. `connect()` is called only when the socket is down.
- **Lifecycle (C23, C31).** Deleting a task cascades locally (blocks, captures) in one transaction and cancels reminders. Background time now wraps the flush, the lock-screen actions (Reschedule, End) and cold launches from a notification action.
- **Privacy (C35, C36).** Sign-out scrubs notifications, the widget, the Live Activity, assistant threads and App Group keys, and wipes before announcing the change of user. It unregisters the APNs and VoIP tokens. A push for a signed-out user is dropped; a VoIP push is still reported to CallKit, then ended. C36 is partial: device_tokens isn't tied to the auth session on the server — backend follow-up.
- **Focus (C37, C38, C39, C43, C44).** Actions from outside the Focus screen keep it in sync. Check-in actions carry their session id. Time in the pause-reason dialog doesn't count. An overlong session is capped with a discard option. Captures from sessions that write no Session row get a real task id.
- **Google (C24, C25, C26).** A Google write-back backlog survives offline and relaunch. Deletes remove the event of the row as it was deleted. Pull fixes for paging, all-day and cancelled events. Disconnect reports a failure.
- **Voice (C41, C42, C46, C47).** On-device speech hands back audio focus (.notifyOthersOnDeactivation), with no orphaned hot mic. The CallKit call owns the audio. Turn-taking fixes preserve the build-83 truncate and the echo verdict. Limit and close messages are plain words. Still open: a wrap-up warning before the 15-minute cap needs a product decision.
- **Gregorian dates.** New `Time.calendar` (Gregorian, keeping the device's zone, locale and week start) replaces Calendar.current at 59 sites. A Buddhist/Japanese calendar phone used to store "2569-…"/"0008-…".

Tests: 1016 app (plus the known CrashBreadcrumbs order flake) and 1270 package tests, all green.

DEVICE CHECKS — the full lists are in p2-batch-results.json, under device_checks per group:
- An offline launch, then a web edit, arrives live.
- Delete a scheduled task and lock at once: no reminder fires, and its Google event is gone.
- Sign-out leaves no old notifications, and no calls reach the signed-out phone.
- Focus Resume/End from the lock screen keeps one Session.
- Music resumes after dictation.

## Where things stand (2026-09-23, afternoon) — builds 84 + 85: list-item gestures, the reconnect card, stage 2

- **Build 84** (Ahmad's screenshots). Collection items now use one gesture per job, replacing the "…" icon bar: TAP strikes the item out, SWIPE LEFT shows Delete, SWIPE RIGHT shows Pin/Unpin and "To task", HOLD edits. All four are also exposed as VoiceOver actions. The Google reconnect state is a plain card ("Google Calendar stopped syncing"; copy in GoogleConnectCopy.reauthTitle/reauthBody) and never shows the raw lastError. Android vc102 carries the same two changes.
- **Build 85: stage 2, "same id for same day" (C21).** Spec: `audit/parity-2026-09-23/deterministic-occurrence-ids.md`. Ahmad's four answers are in DECISIONS.md. Step 0 was verified on prod with temporary users (stage2-check.mjs, 15/15).
  - `occurrenceId` is UUIDv5(task|date), with the shared §1.5 vectors.
  - New outbox kinds `insert` / `insert_or_retime`. `WriteThrough.insertCalBlockIfAbsent` does the local check, the save and the enqueue in one transaction. The gateway gained `insertIfAbsent` (POST on_conflict=id, ignore-duplicates, return=representation) and `retimeIfOpen` (PATCH filtered on id/date/done=false/skipped=false). Request shapes are pinned by a URLProtocol stub.
  - Rules A/B/B′ are in regenerateForTask (keepIds, toRetime), recurrenceTopUp and recurrenceChosenDateAction/Write.
  - Rule G (`InsertMirrorGate`): Google gets a row only after a confirmed insert, checked again at dispatch time. All Google calls run on one serial chain, deletes first.
  - Rule H: a user's mint that the server ignored becomes a conditional retime.
  - The top-up is serialised and gated by `RecurrenceTopUpGate`: it runs only after a successful cal_blocks read of under 1000 rows, once per local day per user, and again on a time-zone change. The time-zone and day observers pull first.
  - Owner call "every day, everywhere": every minted occurrence is mirrored to Google. Plan deletes go through unscheduleAwaiting, so they also remove the Google event. Its whole-table read was removed (the reviewer's O(n·m) finding).
  - Tests: 915 app tests (plus the known CrashBreadcrumbs order flake) and 1199 package tests green.
  - DEVICE CHECKS (Google path never run on a device): a new daily series with Google connected gets exactly one event per day, appearing gradually; "Never" deletes the future events; two devices produce one row per tail day; a midnight or time-zone change runs the top-up after the pull.
- **Build tooling:** SwiftPM and xcodebuild picked up /usr/local/bin/git (x86_64, dead without Rosetta). Put /usr/bin first in PATH for swift test / xcodebuild.

## Where things stand (2026-09-23, late morning) — build 83: the interrupted reply is truncated; missed calls ring back

Ahmad's morning feedback, all iOS:
- **"When the AI gets interrupted it drops the thread and starts again."** Confirmed in Zubair's session 94011b35 at 05:05:56–05:06:17 UTC. He talked over a reply that had already finished GENERATING, then said "Carry on", and the model opened a new topic. The cause: no client ever sent `conversation.item.truncate`, so the server kept the whole unheard reply and the model believed it had said all of it.
  - Now every real cut-off of audio on air sends the truncate with the milliseconds actually heard. That covers talk-over (by words or by voice energy), the Interrupt button and a hold-to-talk press. Echo, a restored blip, a "thinking" reply and a fully played reply send nothing.
  - How it works: the truncate is a pure command in BargeIn, `AudioTruncation.plan`, which works out the milliseconds and never goes past what was received. `PlaybackLedger` in VoiceAudioEngine maps the player's timeline to each audio delta's item_id. The truncate is sent after the cancel and before the flush. A refused truncate is logged, not shown as an error.
  - Calls use the same client, so they get the fix too. The proxy already passes the event through unchanged.
  - Device log lines: "voice truncate at N ms of M ms" and "voice truncate skipped".
  - Not yet ported: web and Android have the same gap, so it goes into the parity work.
- **Missed morning check-in.** Zubair's 08:00 call rang, re-rang once at 08:05 (the phone confirmed it arrived) and stopped: 072's one-retry rule working as written. Ahmad's choice was every 5 min, 4 rings. Migration 076 changes dispatch_calls (redefined from its live body) and call-outcome/retry.ts to MAX_CALL_RETRIES = 3.
  - A call-back is only booked if it rings before 23:00 in the user's timezone.
  - Only a row still 'calling' is re-booked.
  - No client change: the apps read only the retry flag.
- **"Google hasn't verified this app".** This needs Ahmad's action in Google Cloud Console: support email set to support@, publish, and sensitive-scope verification. It is not code.
- support@unstucknow.io now exists, which closes C20.

906 app tests green.

## Where things stand (2026-09-23, morning) — build 82: three fixes from the web/Android audits

Overnight the web and Android apps were brought level with build 81, then each got its own pre-launch audit, and all of their P0/P1 findings were fixed and shipped (web 841cd8c; Android vc101). Everything is in `audit/parity-2026-09-23/`: RESUME.md, DECISIONS.md, web-audit/ and android-audit/. Three of those bugs were also present on iOS:
- **Focus prior** (web W10 / Android A13). A day of a repeating task, or the series template, used to seed the timer with the series' LIFETIME totalFocused. The session opened over its estimate, and the over-time prompt and the coach fired at once. There is now one rule, `FocusModel.seededPriorSec(task:isOccurrence:partnerShared:)`: 0 for a series day or template, and the task's own total for a plain task. The assistant's start_focus uses it too. The task sheet reads "Not started" for an untouched day.
- **Stale call drop** (Android A6). `AppCallEnvironment.anchorIsLive` returned false when the anchored task or block was not in the local store yet (made on web or Android and not synced). The call ended silently as stale. It now rings with the payload's own label, and is retired only for what this phone knows is over: done, skipped, or a delete still queued in the outbox.
- **Google disclosure** (web W14 / Android A19). Connect and Reconnect now show an alert first: each task you schedule becomes an event on your main Google Calendar. No toggle; the owner's call is in DECISIONS.md.

888 app tests green.

Still for Ahmad: stage 2, same id for same day (`audit/parity-2026-09-23/deterministic-occurrence-ids.md` §6 has 4 questions, and §5 needs a staging check).

## Where things stand (2026-09-23) — build 81: the 20 pre-launch fixes

A read-only audit of every section (audit/prelaunch-2026-09-22/REPORT.md, 112
issues: 1 P0, 19 P1, 74 P2, 18 P3) → a design + an independent critique per
P0/P1 (fix-design/designs.json; Ahmad's calls in fix-design/DECISIONS.md) →
10 file-grouped branches, each implemented, adversarially reviewed and fixed
up (fix-impl/results.json has every summary, deviation and residual) → merged
on integrate/b81 (only rec × done conflicted: setRecurrence and
set_task_recurrence, resolved by hand) → main.

What changed, by area (the audit ids are in the code comments):
- Recurrence (C1 P0, C7, C4). topUpRecurrenceHorizon is TAIL-ONLY now
  (recurrenceTopUp): it only extends past the series' last block, at the
  series' own time (a 56-day vote, not the next open block's) and, for
  monthly, its own day; it never re-adds a deleted, moved or unscheduled
  occurrence and never deletes. Recurrence edits start from
  recurrenceEditStart, so an edit can't rebuild a series at a one-off moved
  time. schedule_task moves the occurrence on the TARGET date; a placement
  onto an empty future sets the series time. unschedule_task on a repeating
  task REFUSES and tells the model to ask: stop the series
  (set_task_recurrence none) or skip one day (Ahmad). Turning a repeat on
  with no timed block refuses and the editor opens "Start repeating" (a
  Schedule sheet) instead of inventing 09:00. One clamp (5–1440 min) at the
  write-through boundary + occurrenceBlock.
- Completion (C3, C5, C6). A template is never ticked: Mark done / the
  assistant's complete_task tick TODAY's occurrence; a repeat turned on
  reopens a done template; "Never" carries a ticked today onto the task.
  toggleDone flips the STORED row, not the caller's copy; the assistant reads
  the store, not stale scratch copies. Server: shared_task_set_done refuses
  a partner/assignee tick on a repeating series ('recurring_series'); iOS
  hides that tick.
- Sync (C8, C9). The catch-up pull re-reads collection memberships (a list
  shared while backgrounded is picked up); quarantined outbox ops no longer
  get overwritten by a hydrate; sign-out drains with a bound.
- Calendar + reminders (C18, C2). Google sync surfaces its failures; the
  connections mirror is ordered with connect/disconnect; reminders skip done
  and skipped occurrences.
- Tags/areas (C19). Rename/delete carries every task (and the Today/Tasks
  area filters) along; a taken name is refused.
- Calls (C12, C13, C16). Default call hours 06:00–23:00 (Android + server;
  end minute excluded — refusals name 22:59). request_call / update_call /
  the Call-me editor refuse a time this phone would decline and the model
  ASKS for another. Mic permission is requested even after onboarding on
  another device. A killed-app VoIP launch boots AppModel (bootApp →
  startWithoutScene) and the outcome reporter holds background time.
- Voice token (C14 + iOS half of C15). Talk start, reconnect and the call
  launcher force a refresh when the JWT has < 16 min left
  (voiceTokenMinValidity, tied to the proxy's MAX_SESSION_MS = 15 min); a
  401 dial gets one redial (5 s grace, ≤ 20 s dead air).
- Sharing (C10, C11). Server-backed Block / Unblock / Remove-from-my-list /
  Report (the old device-local People block list is dropped); 'not_in_circle'
  maps to "not connected yet". Removing a person also ends list sharing BOTH
  ways (migration 075 §5, one helper shared with the block sever).
- Backend (unstuck repo dbec3fd + f1b0c8d, all deployed 2026-09-23): 075
  applied (verified: 9 fns, user_blocks, 3 guards, the C3 refusal); edge
  fns share-task, circle-invite, share-collection, share-notify,
  report-notify, support, beta-signup; voice-proxy counts a reply at the
  upstream response.created (C17) and treats an expired token mid-session as
  'error' not 'capped' (C15), with a per-session ceiling and the new
  SUPABASE_SERVICE_ROLE_KEY Worker secret. Zubair's two series the old bug
  ended ("Arabic Class", "Project Check-in") were reopened on prod (Ahmad's OK).
- C20: team alerts go to TEAM_INBOX (default support@unstucknow.io) —
  still bouncing until Ahmad creates that mailbox in M365.

Tests: 875 app tests (only the known CrashBreadcrumbs order flake; passes
alone), `swift test` 1158 green, backend vitest 2820 green, functions
typecheck ok, 075 PGlite harness all checks (incl. the everyday invite link).

Needs a DEVICE (not provable from the CLI): C16 — swipe the app away, lock,
ring a test call, answer AND decline, watch syslog; C13 — fresh install on an
account with a web-booked call gets the mic prompt; C14 — answer a call after
> 1 h suspended, no 401; a Talk session > 15 min.

Residuals kept on purpose (in fix-impl/results.json): deleting the LAST
occurrence inside the 56-day window comes back at the next top-up (needs a
removal record); two devices can still mint the same tail date (C21 —
deterministic occurrence ids, decide before Android/web get a top-up); the
1000-row cal_blocks hydrate cap is a latent precondition of the tail rule;
consent-first sharing by email (071 §5d-f) waits for all platforms.

Parity: Ahmad lifted the iOS-only rule (2026-09-23). Gap reports:
audit/parity-2026-09-23/android-gap.md and web-gap.md.

## Where things stand (2026-09-22, afternoon) — build 80: the token diet

Why it matters more than it sounds: a realtime reply re-reads the whole
session prefix EVERY time, and the tool schemas are ~75 % of it. That prefix
is what fills the account's tokens-per-minute bucket, so it decides how many
replies a conversation gets before the assistant goes quiet — which is what
both testers actually hit. Cheaper prefix = longer conversations AND lower
cost, without touching the tier.

- `App/Features/VoiceToolCompaction.swift` (new) — the voice/call tool lists
  are compacted at runtime: a tool description keeps its capped first
  sentence; a parameter description goes when an `enum` already states the
  values, or when it merely restates the parameter name ("name: The task's
  title"); it is KEPT, shortened, when it carries a format, default, unit or
  permitted value ("local 'YYYY-MM-DD HH:MM'", "defaults to today", "0 = off")
  — those change what the model sends. Every tool, parameter, type, enum and
  required flag survives, asserted field by field against the real registry.
  Measured 35.5 KB → ~22.7 KB, about 36 % off the schema block.
  Wired in `AssistantModel.voiceTools()` / `callTools()`.
  NOT done in `scripts/gen-tool-registry.mjs` on purpose: that generator also
  writes the web, Android and server copies, and iOS is the only platform
  being changed right now. Port it there when those catch up.
- `VoiceRealtimeClient` — a route change sends ONLY `turn_detection`, not the
  whole `session.update`. It was re-uploading the instructions and all 70 tool
  schemas, ~11k tokens, and invalidating the cached prefix, on every headset
  plug, unplug or CallKit speaker toggle. Both the proxy and the OpenAI
  adapter already supported a partial update.
- Both new files were added to the pbxproj BY HAND (xcodegen is broken on this
  machine); `plutil -lint` passes.

759 tests green bar the known CrashBreadcrumbs simulator flake.

Not taken from the audit's token-diet list: trimming the state snapshot for
voice (tasks 60 → 20, week → today+tomorrow). It would save a further
~1,500 tokens but it changes what the model can see without a tool call, so
it wants a real conversation to validate rather than a unit test.

## Where things stand (2026-09-22, later) — build 79: the recurrence + duplicate bugs

The P1 data findings from the pre-beta audit, all of which Zubair hit:

- `recurrenceAnchor(taskId:blocks:todayIso:)` (UnstuckCore/Recurrence.swift) —
  THE anchor a recurrence change regenerates from: the earliest LIVE block at
  or after today, falling back to the latest past one, ignoring timeless
  blocks. `regenerateForTask` deletes every future block that doesn't match
  the anchor's date|time, and the assistant was passing
  `blocks.first(where:)` — an arbitrary block in SQLite rowid order, often a
  done occurrence at another time — while the UI passed the earliest block of
  any kind, i.e. history. "Make Office every Monday at 11" therefore deleted
  the Monday 11:00 block and rebuilt the series at the old time. That is how
  one tester got four "Office" tasks, one of them timeless, and an empty next
  Monday. Both call sites now use it (`AssistantTools.set_task_recurrence`,
  `AppModel.saveTaskWithRecurrence`).
- `AppModel.topUpRecurrenceHorizon()` — run after hydrate, on a day change and
  on a time-zone change. `RECURRENCE_HORIZON_DAYS` is 56 and only user edits
  ever regenerated, so 8 weeks after the last edit a repeating task had no
  future occurrence at all: gone from Today, Upcoming and the calendar,
  surviving only as one overdue row in Backlog. ADDITIONS ONLY — honouring the
  plan's deletions in a background pass would silently undo hand-moved
  occurrences.
- `create_task` refuses a same-name open task created in the last ten minutes
  (`recentDuplicateTask`) and points at schedule_task/update_task instead. The
  context's task list is now NEWEST first: the repository orders by createdAt
  ascending, so past 60 open tasks the model saw the 60 OLDEST and could not
  see what it had just made — which is why a nudge to "call the right tool
  now" made it create another.
- `clampEstimateMin` / `clampDurationMin` at every entry point, and in
  `regenerateForTask`'s minted blocks. The server's CHECKs are 1…1440 and
  5…1440; an out-of-range row was accepted locally, refused on flush, retried
  five times and quarantined — living on that one phone for ever with the user
  never told.
- `complete_occurrence` refuses a one-off task that is already done, the guard
  `complete_task` has had all along (the receipt's Undo would reopen it).

752 tests green bar the known CrashBreadcrumbs simulator flake.

Left from the audit, deliberately not done: the unpaginated `fetchAllRaw`
(latent — the heaviest account today is 186 blocks against a 1,000-row cap),
the 60-second full replace of `cal_blocks`, `Calendar.current` honouring a
non-Gregorian device calendar, and the assistant-tool hot paths that re-read
the whole store per row.

## Where things stand (2026-09-22) — build 78: the pre-beta audit

Five parallel read-only audits before letting strangers in (account/privacy,
voice/calls/cost, data/sync, platform/App Store, backend). The full findings
are in the session; what this build changes, and what is still open:

**Fixed here (iOS):**
- `VoiceModeScreen` — a note set while the session stays LIVE is now rendered
  under the status line. The one message written for a rate-limited reply was
  never displayed (it only rendered in the `.error` state), so the orb kept
  pulsing and the user heard nothing. That is what "it just went quiet" was.
- `VoiceRealtimeClient.friendlyError` — the user gets plain words; the
  provider's text names the model and the organisation, which reads as broken
  and contradicts the scope guardrail. Raw text goes to the device log.
- `VoiceRealtimeClient.describe(_ event:)` — the barge-in log no longer prints
  the event's description, which carried the user's transcript as `.public`
  and travelled in any sysdiagnose a tester sends.
- `CallSettingsView` — the microphone is requested when Calls is switched on
  and before a test call. A call answered from the lock screen can never show
  that prompt, so a user who never opened Talk failed EVERY call.
- `RealtimeCallVoiceLauncher` — a provider failure mid-call ends the call
  instead of leaving dead air on a live phone call.
- `CallNotification.quiet` — "outside your hours" / "calls are off" notices
  are silent and passive. They were time-sensitive with a sound, i.e. built to
  break through Do Not Disturb, so the 3am guard woke people at 3am.
- `AppModel` — `NSSystemTimeZoneDidChange` re-pushes the timezone. The server
  anchors calls and briefs to it, so travel rang on the old zone's clock.
- Settings › Interface — "Clear Assistant history" (`delete_my_assistant_turns`).

**Fixed here (backend / proxy, unstuck repo ce0e273):** per-user daily voice
budget (20 sessions, 150 replies) in the database, migration 074 (90-day
prune + the user delete), and the privacy policy corrected to name the United
States and to state what is stored and for how long.

**Still open, Ahmad's:** OpenAI credit for Tier 3; ZeptoMail SPF + DKIM in
Cloudflare DNS (there is no DKIM record at all today and SPF authorises only
Microsoft, so real users' mail is unauthenticated); Supabase Pro for backups
(free plan, PITR off, zero backups exist); the Time-Sensitive Notifications
capability in the Apple portal plus regenerated profiles (the app sets that
interruption level in five places without the entitlement, so iOS downgrades
it — do NOT add it to `Unstuck.entitlements` before the portal has it or the
archive will fail); Google OAuth consent screen published; App Privacy label
and age rating; the policy's legal review.

**Still open, code (P1, next):** recurring tasks stop after 8 weeks (no
horizon top-up); `set_task_recurrence` anchors on an arbitrary block and
rebuilds the series at the wrong time (Zubair's four "Office" tasks);
`create_task` has no duplicate guard; `complete_occurrence` is missing the
done-guard; unclamped estimates produce rows that never sync; the unpaginated
hydrate (latent — the heaviest account today is 186 blocks against a 1,000
cap); the 60-second full replace of `cal_blocks`.

## Where things stand (2026-09-21, evening) — build 77: Zubair's day on the new model

`assistant_turns` for zyzkazaure@gmail.com, 21 Sep (5 sessions: Talk 04:04, text
chat 04:48 on qwen-plus, morning call 07:01, after-block call 09:01, evening
call 18:01). Reads were right every time and the evening call opened from the
day context (build 75) with no tool call. What went wrong:

1. **Rate limit, three sessions** (Talk, morning call at "reflect that across
   all events", evening call at "No, undo that" / "Have you reversed it?"):
   `response.done failed rate_limit_exceeded`, ~11k tokens per reply on his
   prompt, 40k TPM → 3–4 replies a minute. Ahmad's OpenAI tier.
2. **Every call greeted him twice.** Measured through the proxy: the call
   instructions quote the opening AND the primer quoted it → two message
   items in one response, every time; a primer that only points at the
   instructions → once. `RealtimeCallVoiceLauncher.primer(opening:)` no
   longer quotes it (tests updated).
3. **carry_to_tomorrow moved a DONE task** ("moved 4 — Project Check-in, …",
   ticked at noon on the task, not the block). The executor now excludes
   blocks whose task is done (`testCarryToTomorrowLeavesADoneTaskAlone`).
4. **"Morning." dropped as echo** of "Morning. Want to walk through today?"
   → the call stalled until "Hello?". `BargeIn`: a one-word utterance is
   never judged echo by its words (later pieces of an echo-judged segment
   still are) — test 27a.
5. **Transcriber guessed the language**: "兩點鐘" (two o'clock), "不服不服",
   "다음?" → discarded as no words. Proxy adapter pins
   `transcription.language = 'en'` (deployed c9424c8).
6. After-block call misheard "It went well" as "You weren't well" → offered
   to reschedule. No code change.
7. Text chat (qwen-plus) invented "recurring tasks appear as they get
   closer" instead of calling `get_schedule(next_week)` — the text model is
   still Qwen; switching it is a secrets change (LLM_*), Ahmad's call.
No undo tool exists for carry_to_tomorrow (the model must move each back).

## Where things stand (2026-09-21) — build 76: Ahmad's first session on the new model

`assistant_turns` 2026-09-20 23:46–23:48 (gpt-realtime-2.1-mini): the model
read insights for "how was my last week", listed the (now dated) completed
tasks, and when asked for "the ones I created last week and completed" said
honestly that the list did not show creation dates. Then the session "went
silent" — two causes stacked:

- **The log went blind, not the session.** Every long session's log stopped
  at 48 rows with no close row (the proxy inserted each row separately; the
  free Cloudflare plan allows 50 subrequests per connection). Fixed in the
  Worker: rows are batched per session (`makeTurnLogger`, stamped at
  capture, one key set per row, `waitUntil` on the flush). Unstuck commits
  6086dc1 + follow-up.
- **The rate limit is what he heard.** Reproduced through the live proxy:
  the OpenAI org is tier 1 (40k TPM for this model); each reply ~9k tokens
  (the 70 tool schemas); the 4th reply in a minute fails with
  `response.done status=failed / rate_limit_exceeded`, then the bucket
  refills at ~1 reply per 13 s. The client treated a failed reply as nothing
  to say. Only Ahmad can lift the ceiling (prepaid credit on the OpenAI
  account → higher tier); Workers Paid would lift the Cloudflare caps too.

This build:
- `App/Features/AssistantTools+Surface.swift` — every `get_tasks` line says
  `· created today / yesterday / Fri 19 Sep` (before the done label);
  `get_insights(window: week)` early in the week appends a note that it is
  the CURRENT week (a day or two) and says nothing about last week.
- `App/Voice/BargeIn.swift` + `VoiceRealtimeClient.swift` — a
  `response.done status=failed` with `rate_limit_exceeded` → the turn is
  pending again and re-asked after the bucket's reset (`rate_limits.updated`
  reset_seconds, else the server's "try again in Ns", else 5 s; 1–30 s),
  three times, then "The assistant is busy right now — give it a minute" via
  onError. Any other failed reply → its message via onError once. Tests:
  BargeInTests 26a–b, AssistantToolsTests +2. 746 app tests green bar the
  known flake.
- Voice-proxy also logs `rate_limits.updated` (tokens remaining / limit /
  reset) after every reply, and Workers Logs are on.

## Where things stand (2026-09-20, late) — build 75: the model switched (proxy), three harness fixes

**The verdict.** Ahmad asked "harness or model?". A scratchpad bake-off
(`unstuck` scratchpad `bakeoff/run2.py`: the real voice prompt + all 70
tools, text in, fake tool results, 14 scenarios × 2 × 3 models) settled it:
qwen3.5-omni-flash-realtime 7/28 tool-first, 6 promises/claims with no tool,
and the app's forced-tool corrective rescued it 0/6 (it answered the
corrective with "Call booked … about integrity check" and once SPOKE a fake
tool result); gpt-realtime-2.1-mini 23/26, 0 promises, 4/4 facts. The
voice-proxy now relays to OpenAI's GA realtime API through a protocol
adapter (`unstuck/workers/voice-proxy/src/openai-adapter.ts`): the iOS
client is unchanged (16 kHz mic audio resampled to 24 kHz in the Worker,
transcription switched on, events renamed back). Constraint: the OpenAI org
is tier 1 — 40k TPM ≈ 4 replies a minute; each reply ~8.8k tokens (the tool
schemas). `assistant_turns.model` shows the model that ran.

**The harness fixes (this build), from Zubair's 19:01 evening call:**
- `App/Calls/CallScript.swift` `CallDayContext` + `instructions(_:now:dayContext:)`
  — the launcher (`Deps.dayContext`, `live()`) reads the local store as the
  call connects and puts "done today", "still open today", "today's plan",
  "tomorrow starts with" into the call context; the evening rule says NEVER
  ask them what got done; the morning rule reads the plan from the context.
  Completion day is the LOCAL day of `completedAt`.
- `App/Features/AssistantTools+Surface.swift` — `get_tasks(view: completed)`
  is newest first and every line says when: "done today / yesterday /
  Fri 19 Sep" (`doneWhenLabel`). The model read an undated all-time list as
  "today".
- `App/Voice/BargeIn.swift` — a `response.create` keeps the turn PENDING
  until `response.created` (`createSentAt`, 3 s grace): a create the server
  swallows is re-asked when the active reply finishes (also when the server
  ignored our cancel and the reply completed) or after the grace. His late
  "Yes." got 20 s of silence.
- Tests: CallScriptTests +3, AssistantToolsTests +1, BargeInTests 25a–c.

## Where things stand (2026-09-20, night) — build 74: the echo verdict narrowed, the corrective forces the tool

Ahmad's 15:21–15:37 Talk session read from `assistant_turns`: three real
utterances deleted as echo of the question they answered ("Have you set up
the call?" and "What is today?" right after a reply ended; "Book the cool
call now." over "…book a quick call now?" at 3 of 4 content words). The first
left the session silent (a held delete never reaches the log) and he
restarted Talk, losing the context. Since AEC came back (build 69) the log
shows zero true echoes across 7 sessions / 23 replies. Ahmad's steer: the
solution that cannot make the experience worse — so tiered, not off.

- `App/Voice/BargeIn.swift` — a completed transcript is judged by its words
  ONLY when its segment began while the reply's audio was on air (or is a
  later piece of an echo-judged segment); after the drain the words are the
  user's. On air, four words or more are echo only when every CONTENT word is
  one the model said and at most one filler is not (`echoVerbatimFrom`; the
  transcriber slips a filler into an echo — "Coming up on Friday" — but the
  user's framing adds more — "HAVE YOU set up the call?"); three or fewer
  keep the content-word scoring (the hedge for "Saturday's players"). The live-guess early cut is
  unchanged. Tests 19c / 21c / 22d flipped (they pinned pre-AEC device logs),
  24a–c added (the three utterances + the verbatim boundary).
- `App/Voice/VoiceRealtimeClient.swift` — the integrity corrective's
  `response.create` carries `response.tool_choice = required` (measured
  honoured by DashScope; spoken-only, the model answered the corrective with
  another promise and the same question, twice). New corrective text
  (verbatim on web + Android): act now with sensible defaults, never re-ask.
- Backend (web repo, dfffefa): the voice-proxy logs the turn-taking as
  `assistant_turns` role `event` (client creates/cancels, response.created,
  non-completed dones, socket closes, the primer removal) — migration 073.
  The two "same reply twice, 1.5 s apart" replies of that session are still
  unexplained (not the guard, not the server); the next one will show.
- Same change on web (`lib/voice/bargein.ts`, `realtime-client.ts`) and
  Android (`BargeIn.kt`, `VoiceRealtimeClient.kt`); contract
  `unstuck/docs/voice-turn-taking.md` §3–5 updated.

## Where things stand (2026-09-20, evening) — build 73: a promised action is a claim; the voice prompt gets the CALLS rule

Ahmad asked Talk "call me in one minute and remind me…" and no call came: the
assistant said "I'll set a reminder for one minute from now" and called no tool
(`assistant_turns`, 15:18 UTC; no `call_requests` row). Two holes, fixed in
lockstep with web (commit 40fbc94) and Android (vc98):

- `Sources/UnstuckCore/Logic/AssistantGuard.swift` — a new claim pattern: any
  `I'll / I will / I'm going to <tool verb>` (set, call, remind, book, add, move,
  mark, share…) is an action claim, so a promise made INSTEAD of a tool call is
  bounced into the real call by the existing corrective (text harness and the
  voice integrity guard share the pattern). Offers ("do you want me to call
  you?") and refusals ("I can't book that outside your hours") still pass.
  Test: `AssistantGuardTests.testPromisesOfAnActionAreClaims`.
- `App/Features/AssistantContext.swift` — the voice honesty block now carries
  the CALLS rule (verbatim from web `CALLS_RULE`): "call me at/in …" means
  `request_call` NOW with `when` from `context.today` + `context.now` ("in one
  minute" = now + 1 min), the reminders verbatim as notes, a call exists only on
  `ok`, never book an unasked call, a bare "remind me at 5" is a scheduled task.
- Rules of record: `unstuck/docs/assistant-tooling-rules.md` §2 + §3.

## Where things stand (2026-09-20, later) — calls build-out, iOS half

The iOS section of `unstuck/docs/calls-build-out.md` (backend built in parallel:
migration 072 `call_requests.kind/retries`, `notification_preferences.call_*`,
`callKind` + `endTime` on the push, `call-outcome → { ok, status, retry, snoozeUntil? }`).
Shipped as build 72 (commit a66f6e9).

- **Settings › Calls** (`CallSettingsView`): master **Calls** switch
  (`CallSettings.enabled`, device-local, default ON — enforced ON RECEIPT in
  `CallCoordinator` before the hours rule, Android order: a call that lands
  while off ends `declined` quietly + the notes as a notification with the
  honest "calls are off on this iPhone" line); hours + lead unchanged; three
  **server-backed** toggles + times (morning plan / evening wrap-up / check-in
  after a block) → `PreferencesClient.callProactivePrefs / setCallProactivePrefs`
  (`notification_preferences.call_*`), cached in `CallSettings.proactive` with
  `pendingProactivePush` (offline toggle re-pushed on the next hydrate, never
  pulled over — `AppModel.setCallProactivePrefs / applyServerCallProactivePrefs`,
  wired into `pullServerPreferencesIfNeeded` so a prefs realtime event refreshes
  it); the **VoIP nudge** (no PushKit token 10 s after a signed-in launch →
  one-time inline note with "Retry registration" → `VoipPushRegistry.retryRegistration`;
  pure policy `VoipRegistrationNudge`); **Test call** cancels a previous live
  test row first and books with kind `test`.
- **The call is the full assistant**: `CallScript.callTools` = every
  `ToolRegistry.voice` name + `ToolRegistry.call` (the launcher's
  `callToolSchemas` now resolves names from both surfaces); `CallScript.opening /
  instructions` vary by `CallSession.kind` (`IncomingCallPayload.callKind`, with
  `endTime` for after_block — `CallKind`, tolerant of a server that writes the
  kind into `kind`): requested unchanged; test; morning → get_schedule + plan;
  evening → get_tasks(completed) + carry_to_tomorrow on request; after_block →
  "<task> was on till <spoken time>. How did it go?" → done / skip / reschedule.
  The verbatim-opening line and "never claim an action without its tool result"
  hold for every kind.
- **Missed → retry-aware**: `CallsClient.outcome` returns `CallOutcomeReceipt`;
  the coordinator no longer posts "I called about X" at the 30 s timeout — the
  notification rides WITH the persisted `missed` item
  (`CallsOutcomeReporter.Item.notification`) and the reporter posts it when
  the server answers `retry: false` (or refuses the report for good), swallows
  it on `retry: true` (the server's one automatic ring-back 5 min later).
  Survives a kill (persisted with the queue).
- **Local mirror of `call_requests`** (`Sources/UnstuckSync/CallRequestsMirror.swift`,
  GRDB migration `v6_call_requests`, columns = the server's snake_case names):
  `Hydrator.hydrateCallRequests` (server-canonical; a local-only row newer than
  every server row survives — a booking whose echo the fetch predated),
  `RealtimeMirror` subscribes the table (LWW on `updated_at`),
  `CatchUpPuller` pulls it by the `updated_at` cursor + id-reconciles the
  30-day prune, `clearAll` / `localIds` know it. Readers go mirror-first:
  `MirrorFirstCallStore` (get_calls / cancel / update reads; writes through
  `CallsClient` then upsert the returned row), `CallMeSection` (+ live
  observation of the task's row), `AppModel.openCall` (live read only on a
  mirror miss). Offline `get_calls` answers from the mirror.
- **The bell's call card**: `NotificationsClient.queueCards(moment: "call")`
  → `NotificationQueueCards.entry` ("Unstuck called you about <label>" + the
  matched mirror row's notes, task deep link) merged into Recent with the
  web's `mergeRecent` rules; refetched on open and on foreground.
- **Tests**: `CallScriptTests` (per-kind openings/instructions, registry tool
  list, payload kinds, spoken time, CallSettings persistence on a throwaway
  suite, nudge policy, test-call replacement, kind decode),
  `CallCoordinatorTests` (calls switch, retry-gated miss notification, reporter
  retry true/false/rejected/relaunch), NEW `CallsMirrorTests` (real Hydrator +
  CatchUpPuller + cursors over in-memory GRDB and a fake server across a
  realtime gap; offline reads; the bell card + merge). Added to the pbxproj by
  hand (xcodegen still broken).
- **Left**: on-device validation of the ring per kind, and the Android half
  (same prefs + tool set + retry flag + the Play "calling app" declaration).

## Where things stand (2026-09-20, latest) — assistant tooling v2: one registry, executors that report real outcomes

The iOS half of the cross-platform tooling rewrite (`unstuck/docs/assistant-tooling-rules.md`,
registry `unstuck/lib/assistant/tool-registry.json`, 71 tools). NOT bumped,
not pushed, uncommitted.

- **Schemas come from the registry.** `App/Features/ToolRegistry.generated.swift`
  (generated by `node scripts/gen-tool-registry.mjs` in the web repo — never
  edit; it's in the pbxproj by hand since xcodegen is broken here) is the ONE
  source: `AssistantModel.voiceTools()` = `ToolRegistry.voice`, call mode's
  `snooze_call` = `ToolRegistry.call`, `READ_ONLY_TOOLS` / `NAVIGATION_TOOLS` /
  `STAGED_TOOLS` = the registry's sets. The hand-maintained `VOICE_TOOLS` in
  `AssistantContext.swift` is gone. The generator's Swift template got
  `nonisolated(unsafe)` on `all` (Swift 6 strict concurrency; landed in web
  commit 38216ff). `AssistantToolsTests` proves parity: every registry name has
  an executor case (none comes back as the unknown-tool error), retired names
  do, and the embedded sha256 equals the sibling repo's registry file (skips
  when the web checkout isn't next door).
- **Executors report REAL outcomes** (rules §1). The `AssistantAppState` seam's
  list writes (`addCollectionItem` → item id, `promoteItemToTask` → task id,
  rename / update / remove / item edits / `leaveCollection`), `startFocus`
  (awaited join-or-mint), `extendFocus`, `setRitual`, `finishFocus` return
  outcomes the executor maps to `error:`; `AppModelAssistantState` AWAITS the
  same `WriteThrough` calls AppModel's mutate helpers fire-and-forget (routing
  byte for byte: shared list → item RPC / owner metadata UPDATE, own list →
  whole-row upsert). Partial results are spelled out: `create_tasks` (cap 50;
  "Not created: …"), `complete_tasks` ("Not done: … (already done / not
  found)"), `carry_to_tomorrow` ("moved N … Not moved: … skipped today
  instead"), `promote_item_to_task` (loop→self downgrade said), `add_capture`
  (truncation said), `set_task_later` names the task, `set_task_recurrence`
  refuses weekly without days, `create_tag` errors if it exists,
  `promote_capture` takes the linked task's area (no more hard-coded Work),
  `forget_fact` honours the store's verdict, `update_task` takes tags / first
  step / dueAt / lifeArea ("none" clears) / later and errors on a no-op.
- **New tools:** `find_tasks` (fuzzy title search; "several match" reported by
  the executor), `set_task_reminder` (per-task lead via `NotificationPrefs` +
  scheduler resync), `finish_focus` (the Focus screen's Done path: Session row,
  totalFocused, optional completion, Live Activity ended), `recolor_list`,
  `leave_list` (server-confirmed), `share_list` (STAGED like `share_task`:
  `PendingShare.target == .list` + `listRole`, the same confirm card runs
  `AppModel.shareCollection` on the tap), `pin_list_item`, `restore_capture`,
  `get_settings`, `set_theme`, `set_focus_defaults`, `set_ambient_sound`.
  Unknown tool → `error: unknown tool "x". The tools are: <registry names>`.
- **Guards (rules §3):** `Sources/UnstuckCore/Logic/AssistantGuard.swift` is the
  web's sentence-aware `looksLikeActionClaim` (+ `refersToEarlierTurn`, the
  full verb list incl. restored / pinned / recoloured / finished / left) and
  the apology-only `stripSelfCorrection` (never blanks a reply). The harness's
  "write succeeded" = not read-only/navigation AND result `ok:`; the corrective
  is the rules' verbatim wording; the empty-final-reply ladder is the web's
  five branches (receipt → staged card → "That went through." → "Opened X." →
  lost thread). Voice instructions carry the honesty block, read-before-answer
  and "a reply with tool calls carries no claim" (register rules untouched).
- **Receipts (rules §4):** cards for finish_focus, set_task_reminder,
  recolor_list, pin_list_item, restore_capture, leave_list, set_theme,
  set_focus_defaults, set_ambient_sound.
- **Tests:** UnstuckAppTests 699 (was ~670) — all green but the pre-existing
  simulator-state flake `CrashBreadcrumbsTests.testNoReportIsOfferedAfterACleanRun`;
  UnstuckCoreTests 805 green (guard + list-share tests ported from
  `lib/assistant/receipts.test.ts`).

## Where things stand (2026-09-18) — the cut-off brain dump, and a caption that reads what was said

Two defects a reconciliation sweep confirmed were still open. NOT bumped, not
pushed, uncommitted.

- **The hidden "cut off" hint orphaned a tool result** (`App/Features/AssistantHarness.swift`).
  When `finish_reason=length` landed on a round that CALLED TOOLS, the hint was
  pushed straight after the `tool_calls` turn, so the next round sent
  `assistant(tool_calls) → user → tool` — an orphaned `tool` message, which
  DashScope 400s, killing the turn with an inline error. A big
  `create_tasks` / `complete_tasks` is exactly what hits the 1024-token cap, so
  it fired on precisely the brain dump the feature exists for. The hint now
  goes in AFTER that round's tool results.
  The same push also made `let last = working.count - 1` point at the HIDDEN
  hint on a tool-less final reply: the closing text, its receipts and their
  Undo were written onto a turn `displayTurns` never draws, and the empty-text
  fallback + `stripSelfCorrection` read the wrong turn. The real assistant turn
  is now captured as `replyIndex` BEFORE anything else is pushed, and a
  tool-less cut-off reply gets no hint at all (a dangling hidden user turn made
  the model resume the abandoned plan on the next message).
  This is web's `replyTurn` rule from `unstuck/lib/assistant/use-assistant.ts`,
  ported. Android (`core/…/logic/AssistantHarness.kt`) already had it; iOS was
  the odd one out. Proven by driving it: `AssistantHarnessTests` asserts the
  message sequence each round sends, with an `orphanedTool` window validator —
  revert the fix and 14 assertions fail, printing `["user","assistant","user","tool"]`.

- **The Talk caption lost the reply's first words, and ran segments together**
  (new `App/Voice/VoiceCaption.swift`, wired into `VoiceModeScreen`). Two
  protocol orderings the inline sink got wrong:
  `conversation.item.input_audio_transcription.completed` (the ASR of what the
  USER said) is a separate async job and routinely lands AFTER the reply's
  first `response.audio_transcript.delta`s — and the sink cleared the caption
  on EVERY user event, so the first word or two vanished. And one turn speaks
  in several segments (narrate → tool → answer); their deltas were
  concatenated raw: "Let me check.You have three today."
  The reducer now tells the two user events apart — an EMPTY user caption is
  the barge-in "new turn" signal and always clears; a NON-empty one is an ASR
  result and only clears a caption that is not the live reply it belongs to —
  and separates segments at `response.audio_transcript.done` (also emitted on
  `response.done`, so a backend that skips the transcript terminator still
  gets a break). It never doubles an existing space.
  Web (`components/assistant/voice-mode.tsx`) avoids both by clearing the
  caption on every `done`; iOS deliberately keeps the reply on screen while
  the audio plays out, so it separates instead of dropping. **Android
  `ui/assistant/VoiceModeScreen.kt` (~line 216) still has BOTH defects** —
  same one-line sink, unported.
  Proven by driving REAL server-event JSON through the real
  `VoiceRealtimeClient.handle` (`Tests/UnstuckAppTests/VoiceCaptionTests.swift`,
  9 tests); revert the reducer and it prints "left today." and
  "Let me check.You have three today." verbatim.

## Where things stand (2026-09-18) — the + creates what you're looking at

The bottom bar's coral + used to open the New-task sheet from every screen.
It now follows the surface. Same button, same coral, same position — only the
action and the VoiceOver label move. NOT bumped, not pushed, uncommitted.

- **Today / Tasks / Calendar → New task.** Unchanged, deliberately: the tour's
  `first-action` step falls back to the `new-task` anchor (on the **Tasks**
  tab, `view: .tasks`) and the anchor id is untouched.
- **Collections grid → New collection** — it opens the SAME
  `newCollectionSheet` the small "+ New" pill opens. If the Archived filter is
  on, it flips back to active first (the pill is hidden there and a new
  collection is born active — it would otherwise be created out of sight).
- **Inside a collection → the cursor goes into that collection's inline
  "Add to this collection…" field**, scrolled into view first
  (`ScrollViewReader`). Deliberately NOT a second add UI: one add path.
- **View-only share → New collection.** No "add" the server would refuse.
- **Collections tab whose store isn't up yet → New task.** The shelf is still a
  `ProgressView`; a New collection created there would be a tap into the void
  (the sheet's Create needs the store). The + offers the one thing that works
  and its label says so. That window is now transient either way — ListsView's
  `.task` is keyed on `model.db != nil`, so it RE-RUNS when the store arrives.
  The plain `.task` it replaces bailed for good on a boot that reached this tab
  first, leaving a permanent spinner and a + that silently did nothing.
- **How the scaffold knows** (`AppRouter.collectionsSurface`, `.grid` /
  `.detail(id:canEdit:)` / nil). `CollectionDetailView` is a `NavigationLink`
  destination *inside* the Collections tab, so `router.tab` can't see it — but
  the detail publishes NOTHING. **ListsView** publishes, and every part of it is
  derived, not remembered: the id is `path.last` of the `NavigationStack(path:)`
  it now owns — the stack rewrites that binding on every push and pop, Back
  button, swipe-back and a destination's own `dismiss()` included — and the
  rights come from the live row (a mid-view downgrade to viewer moves the + off
  "add" at once; a deleted / lost-access row falls back to `.grid`, which is
  also when the detail pops itself). Grid cards are `NavigationLink(value:)` and
  the deep link appends to the same `path`.
- **Retraction is not one callback.** Three independent mechanisms, because a
  missed `onDisappear` used to be enough to leave the + aimed at a collection
  that wasn't on screen: (1) ListsView republishes `surface` from its own state
  on every update; (2) `AppRouter.tab` is a computed property whose SETTER
  clears `collectionsSurface` + `collectionFabRequest` — every tab change in the
  app goes through it (`select(_:)`, the bottom nav, the palette, the assistant,
  the tour, deep links), so leaving the tab straight from an open collection
  retracts as part of the state change itself; (3) sign-out calls
  `router.clearCollectionsSurface()` from `scrubDeviceLocalUserContent` (the
  scaffold is torn down there without a tab change). Plus `fabAction` ignores
  the surface entirely off the Collections tab.
- **Handing the action back.** The New-collection sheet and the add field's
  focus are view-local (`@State` / `@FocusState`), so the scaffold parks the
  resolved action in `AppRouter.collectionFabRequest` and the owning view
  consumes + clears it. Identified (UUID) so two taps in a row both fire; each
  action has exactly one consumer, so neither view can swallow the other's.
- **Files.** `App/AppRouter.swift` (`tab`'s retracting setter, the surface enum,
  the pure `fabAction` resolver), `App/MainTabScaffold.swift` (`tapFab`),
  `App/Chrome.swift` (`fabLabel` → `CoralFab.label`),
  `App/Features/CollectionsFeature.swift` (router-owned nav `path`, the derived
  `surface`, both consumers, the scroll anchor), `App/AppModel.swift` (the
  sign-out clear).
- **Tests.** `Tests/UnstuckAppTests/FabActionTests.swift` pins the routing
  decision itself (15 cases: the three task tabs, a stale surface off-tab, the
  grid, an editable detail, target identity, view-only fallback, pop-back, the
  unbuilt shelf, labels, request identity, the live router, and four on
  retraction — leaving the tab, `select(_:)` vs. re-selecting the tab you're
  already on, dropping an unconsumed request, and sign-out).
  `AppSmokeUITests.testFabCreatesWhatYoureLookingAt` walks it on the demo seed
  — the label on every tab, the New-collection sheet opening from the +, the +
  putting the cursor back in the add field (after deliberately clearing the
  detail's auto-focus via the title-rename trick, or the test would pass with a
  + that did nothing), the pop back to the grid, and finally leaving the tab
  STRAIGHT FROM an open collection and returning, which is the walk that could
  strand the marker. It types but does NOT submit: the demo boot has no
  `SyncCoordinator`, so `AppModel.mutateCollectionItem` guards out and a
  committed item would never appear.
- **Mutation-checked.** Neutering the detail's `addFocused = true` fails the UI
  test on exactly "the + should have put the cursor back in the add field";
  removing the `tab` setter's clear fails three FabActionTests. Neither
  assertion is decorative.
- **Run (2026-09-18, iPhone 17 sim, whole `Unstuck` scheme).** `UnstuckAppTests`
  **612 / 0 failures**. `UnstuckUITests` **22 tests, 1 skipped, 2 failing** —
  exactly the two KNOWN pre-existing ones,
  `AssistantBulkUITests.testExitingTheSheetMidBulkTurnThenWalkingTheCalendar`
  and `SharePeopleCardShots.testPeopleCardMatrix`. AppSmoke 7/7, Store 1/1,
  Tour 3/3, ColdStartSoak 4/4, CrashReportAttach + HomeShots green. Package
  `swift test` not re-run — nothing under `Sources/` changed.
- **Two unit flakes worth knowing about, neither related to this work.** Running
  the UI suite first poisons the next `UnstuckAppTests` run on the same
  simulator: the UI tests leave a `MAINSTALL` line in the app container's
  `Library/Application Support/diagnostics/breadcrumbs.log`, and
  `CrashBreadcrumbs.loadPreviousRun` then hands
  `CrashBreadcrumbsTests.testNoReportIsOfferedAfterACleanRun` a non-nil
  `lastReport`. Delete that file and it is 612/0 again (verified). Separately,
  `CallsOutcomeReporterTests.testAfterThreeFailuresTheItemIsReEnqueuedAndRetried`
  `Later` is load-sensitive (a 5 s wall-clock deadline around an injected
  sleep) and failed once under full-scheme load; 6/6 on three isolated re-runs.
- NOT bumped, not pushed, uncommitted. NOTE: `Unstuck.xcodeproj` is generated —
  run `xcodegen generate` after any file add/remove or the build fails on a
  missing input (it was still referencing a deleted UITests file on arrival).

## Where things stand (2026-09-18) — the `today` tour step narrates again

The gap the hero removal left (next section: "Narration audio — PENDING") is
closed. The `today` step's copy was rewritten for the hero-less home and both
Cherry clips were regenerated from it; iOS and Android ship the SAME copy and
the SAME bytes. NOT bumped, not pushed.

- **Copy** (`App/Features/Tour/TourData.swift`, `today` step): body /
  narration / more describe what the screen actually shows — the one-line
  greeting, the "This week · … focused" pill, the assistant input pill ("ask,
  plan, or brain-dump; say it or type it, and it does it"), then the Today
  list with its area filters + Backlog, and that Focus starts from any task
  row or from inside the task. No Start-Next / hero / "pick something"
  anywhere (`testNoStepCopyNamesTheRemovedStartNextHero` still guards both
  scripts + the canned Q&A). Android `TourData.kt` now carries the identical
  strings (its today copy used to differ). This step's copy still differs
  from web `tour-data.ts`, whose home keeps its Start-Next card.
- **Clips** (`App/Resources/TourAudio/today.m4a` 23.2 s, `today-more.m4a`
  14.0 s): DashScope **qwen3-tts-flash**, voice **"Cherry"**, synthesised
  server-side through a temporary guard-protected Supabase edge helper that
  read `DASHSCOPE_API_KEY` from the function env and returned only the audio
  URL (the key never left the server; the helper was deleted from the project
  and the tree right after). Why server-side: the Supabase secrets API
  (`GET /v1/projects/…/secrets`) returns SHA-256 digests, not values, and no
  DashScope key exists on disk — there is no client-side path. Then WAV 24 kHz
  mono → gain-matched to the clips they replace (integrated −22.5 LUFS for the
  narration, −24.3 for the more — exactly the old today / today-more) →
  `afconvert -f m4af -d aac -b 56000` → AAC-LC 24 kHz mono ~56 kbps like every
  other clip. Same bytes copied to Android `res/raw/tour_today*.m4a`.
- **Pins**: `TourScript.stepsAwaitingNarration` is EMPTY again;
  `TourAudioManifestTests.testNoStepAwaitsNarration` asserts that + both
  files on disk; `testTodayClipsMatchTheStepCopy` pins the exact
  narration/more strings the clips speak (edit the copy → re-record, or it
  fails); `testEveryStepHasANarrationClip` / `testEveryTellMeMoreHasAMoreClip`
  now cover all 15 steps with no exemption.
- Verify: `TZ=UTC swift test` → 1038 tests, 2 skipped, 0 failures;
  `xcodebuild test … -only-testing:UnstuckAppTests/TourDataTests
  -only-testing:UnstuckAppTests/TourAudioManifestTests` on the iPhone sim →
  45 tests (40 + 5), 0 failures. Clip check: `ffprobe` → aac/LC, 24000 Hz,
  1 ch, 23.21 s / 13.95 s (59 / 37 words — the same ~0.4 s/word as the old
  17.9 s / 48-word clip), integrated −22.5 / −24.3 LUFS vs the old −22.5 /
  −24.3.
- Still open (pre-existing, noted below): the `today` / `finish` panels render
  COLLAPSED on a seeded 6.3" screen, so Read mode shows the title only there —
  Listen now carries the content; the panel-height design pass is separate.

## Where things stand (2026-09-18) — the "Start next" hero is gone from Today

Ahmad (2026-09-18): the lavender gradient "START NEXT" card on the home —
"<area> · <task>", the first-step headline, the estimate, the Focus button,
"Pick another" — AND its empty-state twin ("Nothing to start / You're all
clear. / Add one thing") go away completely, iOS and Android. The home is now:
top bar → date eyebrow → one-line greeting → "This week · focused" pill →
the assistant input pill → the Today list (filters + rows) and everything
below, untouched. NOT bumped (Ship does); not pushed.

- **`App/Features/TodayFeature.swift`** — `heroOrEmpty(_:hero:)`,
  `firstStepHeadline`, the per-render `vm.startNext(...)` pass, the
  `showPalette` state + its `CommandPalette` sheet (both hero buttons were
  its only Today entry points; the palette stays reachable from the Tasks /
  Calendar / Collections app bars) and the `colorScheme` env read are
  deleted. `TodayModel.startNext(liveTaskId:area:excludeIds:)` is gone;
  `rows(backlog:area:liveTaskId:)` no longer takes `startNextId` — the task
  the hero used to lift out now simply sits in the list (the live-focused
  task is still lifted into the live-session card). `writeWidgetSnapshot`
  keeps the home/lock **Start Next widget** exactly as it was (it calls
  `pickTodayHero` directly — the today-scoped pick that used to feed the
  card; `pickStartNext` / `AppModel.refreshWidgetSnapshot` untouched).
  `Palette.heroGradient` (UnstuckDesign/Tokens.swift) had no other user
  and is removed. Focus is still one long-press away on every Today row
  (context menu → Focus) and on the task editor's Focus button — neither
  changed. No analytics/telemetry was ever wired to the hero (grepped).
- **Tour** (`App/Features/Tour/TourData.swift`): `TourTargetID.startNext`
  is removed; the `today` and `finish` steps ring `.todayList` directly (no
  fallback chain — the list section is always mounted on Today). The
  `today` step's body / narration / more no longer describe Start Next
  (new copy: "Today shows only what's planned for today — a short list you
  can actually finish… Start any task from its row, or ask the assistant
  what to do first." / more: the area pills + Backlog). This is the ONE
  step whose copy now differs from web `tour-data.ts` (the web dashboard
  still has its Start-Next card). **Narration audio — PENDING**: the
  bundled Cherry clips `today.m4a` / `today-more.m4a` spoke the old copy,
  so they were removed from `App/Resources/TourAudio/` rather than narrate
  a card that isn't there — the Listen mini-link is hidden on that step
  (`TourAudioPlayer.hasAudio` → `available = false`, the designed
  degradation), every other step narrates as before.
  `TourScript.stepsAwaitingNarration = ["today"]` names the gap and
  `TourAudioManifestTests` pins it (the stale files must be absent, every
  other clip present). To close it: synthesise the new `narration` and
  `more` strings of the `today` step with DashScope **qwen3-tts-flash,
  voice "Cherry"** (the same recipe as web commit 28c0e90 — the key lives
  in the Supabase project secrets / the voice-proxy Worker, not on disk),
  `afconvert -f m4af -d aac -b 56000` to mono 24 kHz AAC like the other
  clips, drop them in as `today.m4a` / `today-more.m4a`, empty
  `stepsAwaitingNarration`, done. Android should ship the same copy + clips.
- **Tests**: `TourDataTests` — `testTodayAndFinishRingTheTodayList` (+ the
  `start-next` raw value must not linger) and
  `testNoStepCopyNamesTheRemovedStartNextHero`; `TourRound2Tests`
  manifest exemption as above. UI tests: `StoreScreenshots` and
  `AppSmokeUITests.testFocus` enter Focus by long-pressing the seeded
  "Draft the Q3 proposal" row → context menu "Focus" (the 02-focus /
  03-recap captures still work); `testFocus` also asserts there is no
  bare "Focus" button on the home. `TourUITests` step-2 lockdown probes
  the ringed row + `week-pill` instead of the hero's Focus button.
- Verify: `TZ=UTC swift test` → 1038 tests, 2 skipped, 0 failures;
  `UnstuckAppTests` on a fresh iPhone 17 container → 577 tests, 0 failures
  (`CallsOutcomeReporterTests` — the known pre-existing flaky retry-timer
  test — passed this run); `AppSmokeUITests/testFocus` +
  `TourUITests/testEssentialTourEndToEnd` green on the iPhone 17. Store
  shots regenerated on the iPhone 17 Pro Max sim (TZ America/Los_Angeles,
  reverted after) into /tmp/unstuck-shots/01..08 — 01-today is the new
  home, 02-focus / 03-recap come from the row's Focus.
- **Independent verification (same day, head 6eb92c5 + this commit).** Re-ran
  everything on a fresh container: `swift test` 1038/2 skipped/0 failures,
  `UnstuckAppTests` 577/0, `AppSmokeUITests/testFocus` +
  `TourUITests/testEssentialTourEndToEnd` 2/0, `StoreScreenshots` green.
  Drove the seeded build on the iPhone 17: no hero and no all-clear card
  between the input pill and the list, with tasks and with every task
  deleted (the plain "Nothing scheduled. Tap + to add." note is all that's
  left); Focus starts from a row's context menu AND from the editor; dark
  and AX XXXL fine. Two things worth writing down:
  - **The `today` / `finish` tour steps render a COLLAPSED panel** (title +
    controls only — no body, no "Tell me more", no "Ask a question") on a
    seeded 6.3" screen. This is PRE-EXISTING, not a side effect of the
    anchor move: the same run on the parent commit b4b8af8 collapses too
    (the hero's ring left 330pt against a 340pt panel; the list's ring
    leaves 306pt — `tourPanelPlacement`'s "collapse rather than cover the
    ring", non-negotiable #1). Worth a design pass, out of scope here.
  - Because that step is collapsed AND its clips were dropped, `today` is
    now the one step that conveys nothing but its title in BOTH modes
    (Read shows no body, Listen has no audio). Regenerating `today.m4a` /
    `today-more.m4a` — recipe above — or letting that step's panel expand
    would each fix half of it.
  - `testNoStepCopyNamesTheRemovedStartNextHero` iterated `TourScript.full`
    only, which is NOT a superset of `essential` (it drops focus, capture,
    assistant, reentry, notifications) — widened to both scripts + the
    canned `TOUR_QA` answers. All 15 distinct steps are clean.

## Where things stand (2026-09-17) — Today/home: one-line greeting, the assistant input pill, no backlog pointer; the interview moved INTO the assistant

Ahmad approved exactly four home changes (head 53dfe7a → this commit); nothing
else was redesigned, NOT bumped / archived.

- **Greeting on ONE line** (`App/Features/TodayFeature.swift` `header`):
  `GreetingName.line(greeting:firstName:)` → "Good evening Maya." (no
  line break; no name → "… Unstuck."), same `UFont.serifItalic(28)`,
  `.lineLimit(1).minimumScaleFactor(0.7)` so a long name scales instead of
  wrapping. Date eyebrow + week pill untouched. Tests: GreetingNameTests.
- **The "Nothing scheduled today / Pick something to start / N in your
  backlog →" gradient card is GONE** (`heroOrEmpty`): nothing scheduled +
  a non-empty Backlog renders nothing there (the list + its Backlog pill
  already say so). Start-Next hero and the "You're all clear" empty state
  are exactly as they were. Tour: `TourTargetID.backlogPointer` is
  removed; the today/finish steps' fallback chain is `[.todayList]`
  (`TourTargetRegistry.resolve` walks primary → fallbacks, so an account
  with no hero spotlights the list section). TourDataTests updated.
- **The gateway card is REPLACED by one input pill** directly under the
  week pill (`AssistantInputPill`, bottom of TodayFeature.swift): "✦ Ask,
  plan, or brain-dump…" with the mic on the right — drawn exactly like the
  composer the card carried (surface capsule, coral 0.55 ring, coral ✦,
  coral mic, the faded send arrow). Tapping the field (or the arrow) →
  `AppModel.openAssistant(focusComposer: true)` → the Assistant sheet
  opens and focuses ITS composer (`AssistantModel.requestComposer` /
  `takeComposerRequest`; `draft:` carries text over if a caller has one —
  the pill itself is a Button, no keyboard on the home). The mic → the
  same `router.showTalk` VoiceModeScreen cover as before. The card's
  brief, the moment, the chips, the "Personalise your assistant" pill and
  the orb eyebrow are gone from the home. `GatewayCard.swift` (only ever
  used on Today) and `GatewayCardTests.swift` are deleted; `composeBrief`
  / `pickMoment` stay in UnstuckCore (package, tested) for the web/Android
  parity they carry. Everything from the Today list down is unchanged.
- **The interview lives INSIDE the assistant** (`App/Features/
  InterviewThread.swift`). Same `InterviewMachine`, same profile-facts
  store (`source: .interview`), same done flag (`unstuck-gateway-interview-
  done`) + resume step, same `pushInterviewDone` account mirror —
  only the host changed. While the flag is not set:
  - TEXT (`AssistantSheet`): the sheet builds an `InterviewThreadDriver`
    on open; the user's FIRST send arms it (`userSent`) and the reply comes
    first — on the next `sending → false` (`turnFinished`) the driver
    appends the greeting (once) + the current question as LOCAL assistant
    turns (`AssistantTurn.interview: InterviewPromptMeta`, new optional
    field, Codable-compatible with old threads; `appendLocal` now returns
    the id). The sheet draws `InterviewPromptRow` — chips + Skip (+ the
    free-text field where the script allows it) — under the turn whose id
    is `driver.promptTurnId`; a tap echoes as a local user bubble
    (`appendLocalUser`), the machine advances, the next question is posted.
    Changing the subject mid-way: the reply comes first, then the SAME
    question is posted again underneath (the chip row moves to the fresh
    copy). Reaching the rituals picker marks done (as before); "That's me
    set up" closes with one line. A failed local save keeps the question +
    says so (`palette.red`). Stand-down (the existing ≥1-fact rule,
    `shouldAutoComplete` with the parked step) is evaluated when the
    message is SENT and only once `profileFactsHydrated` — someone the
    assistant already knows from the web is never greeted as a stranger,
    and a fact the first reply itself saves can't cancel the interview.
    Local turns never enter the model window (zero tokens).
  - VOICE (`AssistantContext.buildVoiceOpening`): the gate is now the
    interview flag (`AssistantAppState.interviewPending()`, default impl +
    `AppModelAssistantState`), not the fact count. While pending the primer
    greets, asks the seven questions one at a time (`InterviewVoice.spoken`
    keyed on the script keys — a test checks every key has a line; with
    facts already present it says to skip what they answer), saves each
    answer with `save_profile_fact`, allows skips, does the user's own
    requests first and returns, and closes with the new iOS-only
    `finish_interview` voice tool (`VOICE_TOOLS` 57 → 58; executor case in
    `runCoreTool` → `api.markInterviewDone()` = `InterviewMachine.markDone`
    + `pushInterviewDone`). The voice-proxy Worker only rewrites
    `instructions`/VAD, so the extra tool passes through. Done → the
    by-name hello as before.
  - Removed with the card: `InterviewAutoOpenGate`, `shouldAutoOpen`, the
    inline `InterviewFlowView` (and their tests); `RitualChips` (the
    picker, now in the thread) selects with the black-and-white pair.
    There is no Settings link to a standalone interview screen (there
    never was — Settings → "What Unstuck knows" is the facts panel).
- **Colour rules honoured** (memory `brand-colour-coral-only`): diff grepped —
  no `coralDeep` / `primaryDeep` / `primary` in added lines; coral only on
  the pill's ✦ / mic / ring / send (where the card's composer had it) and
  the interview's own Save / "That's me set up" buttons (ported verbatim).
  Also fixed on the way: HEAD's accent sweep had left `theme.palette.theme.
  palette.red` in 10 places (a sed over `theme.palette.coralDeep`) — the app
  target did not compile; collapsed to `theme.palette.red`.
- **Demo hooks**: `UITEST_ASSISTANT_CANNED=1` (DEBUG) installs
  `CannedAssistantScript` — one fixed reply, no tools — so a UI walk can
  send a message and reach the interview prompts. `UITests/HomeShots.swift`
  shoots 01-home-light / 02-home-dark / 03-assistant-interview into
  `HOME_SHOTS_DIR` (`TEST_RUNNER_HOME_SHOTS_DIR=…`, default
  /tmp/unstuck-home-shots).
- Verify: `TZ=UTC swift test --scratch-path .build-int` → 1038 tests, 2
  skipped, 0 failures; `UnstuckAppTests` on a fresh container → 575 tests,
  569 green with `-skip-testing:UnstuckAppTests/CallsOutcomeReporterTests`.
  That class's `testAfterThreeFailuresTheItemIsReEnqueuedAndRetriedLater`
  is a PRE-EXISTING race unrelated to this change (it fails/passes run to
  run on HEAD too): with the stub sleep, `scheduleRetry`'s timer task
  re-arms `flushTask` while `settle()` is deciding whether to return, so
  the 4th attempt sometimes lands before the "3 attempts" assertion.
  Untouched here — fix the test's `settle` (or the timer hand-off), not
  the reporter.

## Where things stand (2026-09-17) — Share screen: the People card collapses; the accent sweep; scheme-aware accent ramps

Ahmad, from a tester's screenshot before the web + Android push: (1) "the
accent colour you use doesn't match the actual colour we use for the rest of
the app", (2) someone with seven connections got seven full-width rows —
"very ugly … find a better way and collapse that list". Both fixed; NOT
bumped / archived (build 56 stays on TestFlight until he has seen it).

- **People card (`App/Features/ShareScreen.swift`)** — the per-person surface
  cards are gone. ONE 12pt `surface`/`line` card (the Share screen's own
  radius; `CardDivider` between rows), 44pt rows: monogram · name · "· Coach"
  … trailing word. The WHOLE row is the control — a Button that shares
  ("Share", `ink` semibold) or hands over ("Hand over"), or the Menu for
  someone who already has it ("Can edit" / "Can view" / "Handed over" in
  `ink2` + a chevron; Can edit ✓ / Can view / Report… / Block <email> /
  Remove or "Take it back" — verbatim, now `accessMenu`). The old `pill()`
  and the email-on-the-row are gone (the email survives in "Block <email>",
  the report dialog and Waiting to join). Eyebrow "People · N".
  **Collapse rule** — pure `sharePeopleLayout` in
  `Sources/UnstuckCore/Logic/UnifiedSharing.swift` next to `composeSharePeople`:
  shared-first (roster order inside each half), cap = max(3, pinned.count) so
  someone who already has it is NEVER hidden, hide only when it hides ≥ 2
  rows ("Show 1 more" is worse than the row), "Show N more ⌄" / "Show less ⌃"
  as the card's last row, and at ≥ 10 people the EXPANDED card gets a Find
  field (diacritic/case-insensitive prefix-of-word over name, label, email;
  searching lifts the cap and hides the disclosure). 7 people = 3 rows + "Show
  4 more" (179pt, was ~400). Constants `sharePeopleCollapsedCap = 3` /
  `sharePeopleSearchThreshold = 10` — **mirror them in the Android + web
  ports** or the three platforms collapse differently.
  **Pin-at-open** — `ShareScreenModel.pinnedIds` is fixed by the FIRST
  non-empty `load()` and never recomputed (hand-over mode pins only the
  holder), so a row you just shared changes its monogram + word IN PLACE and
  floats to the top only on the next open; `people` keeps roster order.
  `peopleExpanded` / `peopleQuery` are `@State` on the sheet (survive every
  reload, reset per presentation). Accessibility: every row/disclosure is a
  full-width 44pt target; VoiceOver labels unchanged ("Share with Maya, Can
  edit", "Maya, Can edit. Change access" + hint, "Hand over to Maya", "Maya,
  already handed over", "Maya, working"); at accessibility sizes the row
  becomes two lines (monogram · VStack{name, word}) with wrapping text;
  monogram is `@ScaledMetric`; Reduce Motion drops the 0.22s expand.
- **Accent sweep** — the People section uses NO accent token (looks the same
  under indigo / rose / forest, light + dark): the monogram is the app's
  selected / unselected chip pair (`ink` fill + `bg` letter when they hold the
  item; `bg2` / `ink2` / `line2` ring when not), never a `primary` disc. Four
  shipped dark-mode invisibilities fixed — literal white on dark `ink`
  (≈1.05:1): the People "Share"/"Hand over" pills (deleted with `pill`), the
  "Someone new" Share button (+ a 44pt hit frame), NewTaskSheet's "Copy link"
  / "Generate link" / "Send invite", plus its share-member avatar (same chip
  pair) and Off/Can edit/Can view segment; SharingFeature's "Complete" and
  "Sit with them" (`bg` on `primary`). Acceptance:
  `grep -nE "palette\.primary|\.white\b|Color\.black|#[0-9A-Fa-f]{6}" App/Features/ShareScreen.swift`
  → nothing.
- **Root cause of "doesn't match": `withAccent` applied the LIGHT ramp in DARK
  mode** (`Sources/UnstuckDesign/Tokens.swift`; the web fixed the same bug in
  `globals.css` and is the source of truth). Now `withAccent(_:dark:)` — the
  web's values verbatim: the dark block overrides `primary` / `primaryDeep` /
  `primarySoft` / `coralSoft` only; `coral` / `coralDeep` keep the light
  accent values (mirrored precisely, not "improved"). `UThemeResolver` passes
  the scheme; the old one-arg signature is deleted so it cannot come back.
  Before: rose/forest in dark = primaryDeep L 0.42 on bg 0.205 (≈1.9:1) and a
  near-white `primarySoft` capsule. **Android has the identical bug**
  (`design/…/theme/Theme.kt` `withAccent` at :114-124, called at :133) — the
  same six values per accent, `withAccent(accent, dark)`; not yet done.
- **Found in the shots, fixed before commit:** `layoutPriority(1)` on the
  name must be the OUTERMOST modifier (ahead of `fixedSize` it did nothing
  and "Priya Raghuna… · Accountab…" truncated together); the hand-over
  HOLDER's row is inert content, not a disabled Button (which greyed the
  whole row, monogram included — the spec's "a state, not a dimmed
  control"); the disclosure row dims with its siblings while a write is in
  flight; and at accessibility sizes the name and the label STACK (side by
  side, a full-width name left the label one character wide, wrapping letter
  by letter into a 1500pt row). Verified: 25/25 configs on iPhone 17
  (`scratchpad/share-shots`), the affected ones re-shot after each fix.
- **Demo transport for shots** — `UITEST_SHARE_PEOPLE="<count>,<shared>
  [,<handed>]"` (+ `UITEST_SHARE_SLOW=1`), `DemoShareTransport` in
  `App/UITestSupport.swift` (DEBUG + env-gated like every UITEST_* hook),
  wired in `makeShareScreenModel`. `UITests/SharePeopleCardShots.swift` shoots
  the whole matrix (0/1/4/7/20 people × 0/2/6/10 shared, hand-over ± holder,
  light/dark, indigo/forest, AX XXXL, expanded/search/busy/menu) from one
  test on one simulator: `TEST_RUNNER_SHARE_SHOTS_DIR=<dir> xcodebuild test …
  -only-testing:UnstuckUITests/SharePeopleCardShots`.
- **Tests:** Core `UnifiedSharingTests` +9 (order, the cap never hides a
  holder, one hidden row is not worth a disclosure, 0/1/3/4/5/7/20 cases,
  expanded + Find at ten, search lifts the cap, diacritics/case/name/label/
  email, no match, titles); Design `AccentTests` (new: indigo no-op, dark
  primaryDeep lighter than dark bg / light darker than light bg per accent at
  ≥ 4.5:1, the dark ramp swaps only what the web swaps, and `bg`-on-`ink` ≥ 12:1
  in both schemes while white on dark ink < 1.2:1); App
  `ShareScreenModelTests` +3 (`pinnedIds` fixed by the first non-empty load,
  survives share + remove, hand-over pins only the holder). Every existing
  case unchanged. `TZ=UTC swift test --scratch-path .build-int` → 1034 green (2
  skipped); `xcodebuild test … -only-testing:UnstuckAppTests` → 584 green.

## Previously (2026-09-17) — Unified sharing v1: ONE Share screen for tasks + lists (spec `unstuck/docs/unified-sharing-spec.md` §4)

Testers: "sharing a task or a collection is difficult, too many steps, not
straightforward." Before: a task could only be shared with an ACTIVE circle
member (invite → wait → come back → pick a level, two sessions), two share
UIs with two vocabularies (Off/View/Partner/Assign vs Can edit/Can view), and
iOS always said "Invited … they'll get access when they sign up" even when the
person had an account. Now — built against the §3.3 backend contract (the
`share-task` edge fn + migration 065 land separately; every call degrades
honestly until they do):

- **`App/Features/ShareScreen.swift`** (new) — `ShareScreen` + `ShareScreenModel`
  + the `ShareScreenTransport` seam (`LiveShareTransport` = AppModel's
  clients). Title "Share" + item name; **Can edit / Can view** segmented
  (default Can edit; tasks → `partner`/`view`, collections → `editor`/`viewer`);
  sections **People** (every active connection, one tap shares at the chosen
  grade; a shared person shows "Can edit / Can view / Handed over" and opens
  a picker: change / Remove / Report… / Block for list members), **Someone
  new** (email → `share-task add` / `share-collection add`; pending invites
  listed with cancel), **Share a link** (`share-task link` / `share-collection
  link` → clipboard + the system share sheet). The line under the button is
  what the server DID: "Shared with Maya — they can edit." / "Invite sent to
  x@y — waiting for them to sign up." / "Link copied — whoever opens it gets
  this task." Refusals shown: "That's you.", "You've blocked that person.",
  the rate-limit copy, "Only the owner can share this.", "Couldn't share —
  try again." Refreshes on `unstuckCollabCircleChanged` / `SharesChanged` /
  the new `unstuckCollabConnectionActivated` + foreground.
  `.handOver` mode = **"Hand over to…"** (same people picker → `task_share`
  level `assign`; "It becomes their task to do — you keep view …").
- **Entry points:** TaskEditor toolbar = a LABELLED "Share" + a ⋯ menu with
  "Hand over to…" (not for occurrences); Today + Tasks row context menus
  "Share…" (non-occurrence rows); collection card context menu "Share…"
  (owner) + the detail's Share button. **Removed:** the old `ShareSheet`
  (SharingFeature.swift) and `CollectionShareView` (CollectionsFeature.swift).
  NewTaskSheet's create-time "Share" section keeps the local picks but speaks
  the new vocabulary (Off / Can edit / Can view — no Assign).
- **Pure vocabulary + copy:** `Sources/UnstuckCore/Logic/UnifiedSharing.swift`
  — `ShareAccess` (edit/view ↔ both backends), `composeSharePeople`,
  `shareResultLine`, `ShareFailure(reason:)` (server codes → copy),
  `isEmailLike`, `handOverExplainer`.
- **Transport:** `Sources/UnstuckSync/TaskShareClient.swift` (new; `add` /
  `remove` / `list` / `link` on `share-task`, `status` decoded honestly, pure
  decoders) on `SyncCoordinator.taskShare`; `CollectionShareClient.link` +
  `shareDetailed(email:userId:role:)` + the **decoder fix**: `status` wins,
  then `ok`+`userId`, and only then the legacy `invited` flag (the old
  function set it on BOTH branches — hence "always Invited"); `ShareOutcome`
  gains `.blocked` / `.rateLimited` (a thrown 429/403 body is read, not
  collapsed to `.error`). `CircleMemberRow.invitee_email` (optional → People
  shows the address on pending rows; works before and after 065).
  `CircleClient.rpcFailureReason` maps PostgREST `raise exception` codes.
- **Realtime:** `CollabRealtime` posts `unstuckCollabConnectionActivated`
  when a trusted_circle row of mine goes `active` (pure
  `circleRowWentActive(old:new:)`); shares inserts already post SharesChanged.
- **Deep links:** `unstuck://task/<id>` whose id is NOT in my store (a task
  shared WITH me — RLS keeps the row off the device) now opens the
  read-only `SharedTaskDetailSheet` via `router.sharedDetail` (MainTabScaffold),
  not Today; pure `AppModel.taskLinkRoute`. `unstuck://collections/<id>` parks
  `router.openCollectionId`; ListsView pushes the detail once the row exists.
- **Push kinds:** `invite_claimed` / `circle_invite` join the collab thread;
  Notification Center labels for task_share / collection_share /
  invite_claimed / shared_task_done.
- **Assistant:** `share_task` accepts an email as `person` (staged as
  `PendingShare.recipientEmail`; the confirm card calls `share-task add` and
  shows the honest line); the tool description says so.
- **Tests (new):** Core `UnifiedSharingTests` (mapping, composition, copy,
  failure mapping, email resolve), Sync `TaskShareClientTests` (decoders,
  body keys, the collection decoder fix, invitee_email, went-active verdict,
  rpcFailureReason), App `UnifiedSharingScreenTests` (ShareScreenModel over a
  fake transport: sections, default grade, per-backend levels, every result
  line + refusal, hand-over, link, live-signal reload; shared-task deep-link
  routing on the in-memory AppModel; the assistant email confirm).
- **Verify:** `TZ=UTC swift test --scratch-path .build-int` → 998 green (2
  skipped); `xcodegen generate && xcodebuild test … -only-testing:UnstuckAppTests`
  → green (both counts in "How to verify"); then a simulator run: open any task →
  "Share" → People / Someone new / Share a link; long-press a row → "Share…";
  long-press a collection card → "Share…". NOT bumped / archived — a
  verifier ships after review.
- **Deployed shapes (aligned 2026-09-17 after the backend's live verify):**
  `share-task add` → `{ok, status:'shared', userId, displayName, level}` /
  `{ok, status:'invited', email, level, emailed}` / `{ok:false, reason:'self'}`,
  HTTP 400 `bad_request` · 403 `forbidden` · 429 `rate_limited` (read from
  the thrown body); `list` / `remove` → `{ok, members:[…], pending:[{id,
  email, level, createdAt}]}`; `link` → `{ok, url, expiresAt, level|role}`;
  `circle_redeem` → `{ok, granted:{task_id?|collection_id?}, owner_name,
  already_connected?}` (`CircleRedeemResult.grantedTaskId/…` — the accept
  alert now says where the item landed and pokes the shares signal).
  `share-collection add` is UNCHANGED and deliberately uniform
  (`{ok:true, invited:true, members:N}`): decoded as `ShareOutcome.accepted`
  (the `members` field is lenient — a count never sinks the decode) and the
  line stays neutral and true: "Shared with x@y — they'll see it as soon as
  they're in." A `status` field, if it ever appears, is read first.
- **Contract gaps (reported, handled defensively):** (1) `share-collection
  add` is email-only and `circle_list` carries no member emails, so a People
  tap on a LIST sends `{action:'add', collectionId, userId, role}` — the
  deployed function answers 400 `bad_request` → the screen says "Lists can't
  be shared by name yet — enter their email below." Either `add` should
  accept `userId` or `circle_list` should project `member_email`. (2) The
  spec's "Shared with Maya — she can edit." is rendered as "— they can edit."
  (no pronoun data). (3) `claim_my_pending_invites()` / `task_pending_invites`
  / `task_invite_cancel` RPCs are not called directly — the screen reads
  pending invites through `share-task list` and cancels through `remove
  {inviteId}` (same data, one transport); the sign-up claim is server-side.
  (4) `circle-invite`'s optional `taskId/taskLevel` / `collectionId/role`
  (item-carrying invites) is unused — the Share screen's link comes from
  `share-task link` / `share-collection link`, and NewTaskSheet's inline
  invite has no item yet (the task doesn't exist).
- **§2 "One place for people" — GAP CLOSED (2026-09-17, last spec gap):**
  email invites sent from the Share screen (`task_invites` /
  `collection_invites`) did not appear under Settings → People. People now
  has a **"Waiting to join"** section listing every unclaimed invite I sent,
  whichever screen sent it — one row per invite: the address, what it's for
  in the ONE vocabulary ("Draft the deck · can edit", "Groceries · can view",
  "your people"), Cancel (confirmation → `cancel_pending_invite`), and Copy
  link where the invite has a join code. Built against the backend's NEW RPC
  contract (lands separately; the screen works before and after):
  `my_pending_invites()` → setof jsonb `{kind: task|collection|circle, id,
  itemId, itemName, email, access, createdAt}` (only invites the caller sent,
  createdAt desc) and `cancel_pending_invite(p_kind, p_id)` → boolean (true
  when a row was deleted). Pieces: `PendingInvite` / `PendingInviteKind`
  (Core models), pure `pendingInviteLabel` + `composePeopleSections`
  (Core/Logic/UnifiedSharing.swift — a `circle` row the RPC reports REPLACES
  its roster pending row, matched by `trusted_circle.id` or by address, the
  roster's `invite_code` carried over; anything the RPC doesn't know — link-only
  invites, or every pending row on a pre-RPC server — stays in the roster as
  before, so nothing is ever listed twice), `CircleClient.myPendingInvites()` /
  `cancelPendingInvite(kind:id:)` with pure defensive decoders
  (`decodePendingInvites`: unknown kinds / id-less / malformed / null elements
  dropped without sinking the list, every field optional, camelCase +
  snake_case twins, numeric ids; `decodeCancelPendingInvite`: PostgREST's
  scalar `true`, plus `[true]` / `{ok}` in case the fn is reshaped; a missing
  RPC = `[]` / `false`, never a pretended success), and the new
  **`PeopleTransport` seam** in ConnectionsFeature (`LivePeopleTransport` over
  `CircleClient`; `AppModel.makeCircleModel()` builds it) so `CircleModel` is
  unit-tested with a fake. `CircleModel` now exposes `roster` (what the People
  list shows) + `waiting` next to `members` (unchanged — NewTaskSheet's picker
  source), refreshes on appear, on ALL the collab signals (`CircleChanged` /
  `SharesChanged` / `ConnectionActivated`) + foreground, and after every
  cancel (optimistic row removal, then the server's truth; a refused cancel
  brings the row back with "Couldn't cancel that invite — try again."). Tests:
  Core `PendingInvitesTests` (labels per kind + degradation, composition /
  dedupe / pre-RPC), Sync `PendingInvitesClientTests` (decoders, param keys),
  App `PeopleWaitingTests` (CircleModel over `FakePeopleTransport`: rows +
  labels, cancel per kind removes the row + calls the RPC with kind/id,
  refused cancel, dedupe with roster rows, pre-RPC roster, signal refresh).
  Counts: `swift test` → **1021 green** (2 skipped); `-only-testing:
  UnstuckAppTests` → **581 green** on a fresh container. NOT bumped / archived.
- **LIVE-VERIFIED against prod (2026-09-17), RPCs deployed.** An independent
  pass drove the real app on the "iPhone 17" simulator signed in as the demo
  account: a task's Share screen → an unknown address ("Can edit"), a list's →
  another ("Can view"), "Add someone" here → a third. Settings → People listed
  all three under **Waiting to join**, ONE row each, reading exactly
  "Write the project update · can edit" / "Groceries · can view" /
  "your people" (the circle row carrying the roster's Copy link, and the
  roster count NOT growing — the dedupe path works live). Cancel → the row
  goes and the prod row is deleted (`task_invites` / `collection_invites` /
  `trusted_circle` re-queried each time), the other invites survive; the
  confirmation says what it takes away by name. Dark mode renders; VoiceOver
  reads "Cancel invite to <address>" per row. Screens:
  `30-people-waiting.png`, `31-people-after-cancel.png`.
  **One defect found live and fixed here:** at AX XXXL both row texts were
  pinned to `lineLimit(1)`, so the address truncated to "unified-…" and what
  the invite is for to "Write the projec…" — the entire content of the row,
  and the grade the one vocabulary promises, unreadable (and the rows
  indistinguishable from each other). They now WRAP at accessibility sizes
  (`waitingRowLineLimit`, unit-tested in `PeopleWaitingTests`); the compact
  one-line row is unchanged everywhere else. Note the ROSTER's rows keep the
  old one-line rule (pre-existing, not touched here).
- **Review follow-up (2026-09-17, two low findings, both fixed):** (1)
  `CircleModel.waitingError` was cleared only at the start of the next
  `cancelPending`, never by `refresh()` — after a refused cancel the line
  "Couldn't cancel that invite — try again." stayed through every later
  collab-signal / foreground refresh until the next cancel attempt or leaving
  the screen. `refresh()` now clears it (a refresh is a fresh answer), and
  `cancelPending` sets the line AFTER its own refetch so a refused cancel is
  still shown — order matters, and `PeopleWaitingTests.
  testTheNextRefreshClearsTheRefusedCancelLine` pins both halves. (2) The
  "Copy link" button on a Waiting-to-join row carried no per-invite
  accessibility label — with the roster's pending rows on the same screen,
  VoiceOver read up to four identical "Copy link" buttons. Both the Waiting
  rows AND the roster's pending rows now use `copyInviteLinkLabel(email:
  copied:)` → "Copy invite link for <address>" / "Copied invite link for
  <address>" (the copied state is spoken; a fixed label would have hidden the
  visible "Copied!" flip), bare "Copy invite link" for a link-only roster
  invite with no address (`testCopyLinkButtonsNameTheirInvite`). No behaviour
  change beyond those two; NOT bumped / archived.
- **Known pre-existing flake fixed in passing:** `AssistantToolsTests.
  testGetTasksViewsAreDistinctAndFiltersNarrow` — every seeded task carried
  the fixed `PAST_CREATED` stamp, and `isSlipping` treats anything older
  than 21 days as slipping, so the "slipping" view grew from 1 to 6 rows once
  the calendar passed that date. The stamp is now relative to today.

### Independent LIVE verification (2026-09-17, simulator vs PROD)

An independent pass drove the real app on the "iPhone 17" simulator, signed
in as the demo account against prod, with a throwaway second account, and
walked every §2/§4 path (screenshots per step). **The screen works**: the
Today/Tasks row "Share…", the editor's labelled Share + "Hand over to…", the
collection card + detail, People / Someone new / Share a link, the pending
invite rows, Settings → People (a pending invite WITH an email shows the
address; link-only invites correctly say "Invite pending"), NewTaskSheet's
Off / Can edit / Can view, the recipient's "Shared with you", and the
`unstuck://task/<id>` push deep link opening the read-only Shared-task sheet
for a task that is not in the local store. Backend rows matched every time
(`task_shares` partner/assign, `task_invites`, both `trusted_circle`
directions, `pending_task_id` on the link row). Dark mode renders; AX XXXL
reflows without clipping; no crashes; no share-related console errors.

**Three defects were found live and fixed here:**

1. **The honest line was invisible.** `feedback` was the LAST row of the
   scroll, so after a "Someone new" share it sat below the fold *and* behind
   the keyboard — the one answer §2 promises ("Shared with …" / "Invite sent
   to …") never reached the user in the commonest path. It now renders
   directly under the access control, and `shareWithEmail()` resigns first
   responder before the round trip.
2. **The recipient still read the storage level.** "Shared with you" rows and
   the Shared-task sheet showed `partner` / `watching` — §2 says ONE
   vocabulary. `shareStatusLabel` now says "can edit" / "can view" / "yours",
   and `shareLevelLabel` "can edit" / "can view" / "handed over".
3. **A list was described as a task.** The access blurb under Can edit/Can
   view read "They can start, complete and focus on it with you." on a
   collection. `ShareAccess.blurb(for:)` is kind-aware now ("They can add,
   tick off and edit everything on the list." / "They can see the list and
   everything on it."); the bare `blurb` stays task wording for NewTaskSheet.

**Contract gap (1) in the list above is CLOSED**: the deployed
`share-collection` v22 accepts `{action:'add', collectionId, userId, role}`
and answers `{ok, status:'shared', userId, displayName, role, members:N}`;
a People tap on a LIST was verified end-to-end ("✓ Shared with Verify — they
can edit."). The `.listNeedsEmail` branch is kept only as the fallback for an
older deployment. Gaps (2)–(4) stand as written.

Still not exercised: a real push tap (simulator can't receive APNs — the deep
link was driven with `simctl openurl` instead), the `invite_claimed` sender
notification, and a link REDEEM from a second device.

Counts after the fixes: `swift test` → **999 green** (2 skipped);
`-only-testing:UnstuckAppTests` → **570 green** — *on a freshly installed app
container*.

**`UnstuckAppTests` is only green on a clean container (pre-existing, repros
at HEAD).** Run the suite twice in a row and the second run fails
`CrashBreadcrumbsTests.testNoReportIsOfferedAfterACleanRun` and, with it,
`AppModelAssistantStateTests.testArchiveCaptureWritesThroughToTheRepository
AndOutbox`. Root cause (confirmed, not guessed): the 570-test host blocks the
main thread for longer than `CrashBreadcrumbs.stallSeconds` (4 s), so the
stall detector appends a real `MAINSTALL` breadcrumb; the NEXT run's
`install()` reads it, `lastReport` is non-nil and the "a clean run offers
nothing" assertion fails — and the same starvation makes the archive test's
3-second poll for the async capture write time out. Both are test-host
artefacts, not product faults. Workaround until someone fixes the isolation:
`xcrun simctl uninstall <sim> io.unstucknow.app` before the suite.

Observation while diagnosing that (NOT changed here, no evidence it bites in
practice): `AppModel.propagateCaptureArchiveChange` fires one unstructured
`Task` per change, and Swift does not order two of those — a fast "Done" then
"Restore" could in principle reach the store in reverse. Worth a chained
write if anyone ever sees a restored capture come back archived.

## Where things stand (2026-09-17) — Talk had no audio on a real iPhone: the engine stopped itself 100 ms in (1.1.0 build 52)

Ahmad's report: tap Talk, the greeting's TEXT appears, nothing is heard, and
speaking never gets a reply. Pinpointed from the phone's own syslog over USB
(memory `ios-device-logs`; the TestFlight build, no reinstall): the socket
and the model were fine; the AVAudioEngine started, ran for ~100 ms, then iOS
re-clocked the speaker for the voice-processing unit (output 48 kHz → 44.1 kHz)
and the engine **stopped itself** (`iounit configuration changed > stopping
the engine`), posted `AVAudioEngineConfigurationChange`, and nothing restarted
it. Our mic tap went onto the dead engine (never fired → nothing uploaded →
server VAD never triggered → "Listening…" for ever) and every reply buffer
was scheduled onto it (`AVAudioPlayerNode: Engine is not running … Cannot
play yet!`). No API reported an error. The simulator never reconfigures the
IO unit, so every sim run had passed.

- **`App/Voice/VoiceAudioEngine.swift`** now observes
  `AVAudioEngineConfigurationChange` for its engine once it runs, and on it:
  retires the queued playback (generation bump; fires `onPlaybackDrained` if
  a tail was dropped so the state machine doesn't wait on "speaking"),
  removes the tap, re-reads the CURRENT hardware format, rebuilds the 16 kHz
  converter (captured by the tap itself now — no shared slot for the render
  thread), reinstalls the tap, `prepare()` + `start()`, `player.play()`, and
  recalibrates the gate (the route may have changed). A restart that fails or
  loops (`EngineRestartPolicy`: 6 per 10 s) ends the session through
  `onCaptureError` — loudly. Graph mutations are serialised by `graphLock`,
  never held with `lock` across a `removeTap`. The CallKit call path uses the
  same engine and inherits the fix.
- Tests: `VoiceAudioEngineRestartTests` (the pure loop guard + inert-before-
  start); the AVAudio half is validated on the device via the syslog lines
  `voice engine restarting after configuration change #1 hw=48000Hz` and the
  absence of `Cannot play yet`.
- Ship: build 52 — Ahmad's retest on the device: heard, understood, replied.

**Then (build 53): the reply was cut by any noise.** Same device, same session
log: the engine restarted exactly once and stayed up, so this was the barge-in
state machine. Its confirm was the TIMER ALONE: a server `speech_started`
while the model speaks ducks the reply and starts a 300 ms confirm, and the
only escape was the server's `speech_stopped` — which the server sends after
`silence_duration_ms` (600) of silence, so it can never arrive inside the
window. Every VAD blip on the loudspeaker (a tap, a chair, a cough) cancelled
the reply. Web and Android carry the identical rule (`tick → cancel`), just
less exposed (browser AEC, quieter setups).

- **`App/Voice/BargeIn.swift`**: the controller now tracks `serverSpeaking`
  (like the web client) and a confirm needs evidence from BOTH sides — the
  server is inside a speech segment AND the local gate is still open (sound
  that lasted the whole window). Otherwise it is a blip: restore, and if the
  server is still in its segment, `suppressNextResponse` (it will commit and
  reply to the blip; that reply is cancelled on creation, as the
  speech_stopped path already did). A gate-only duck the server never called
  speech restores without suppression (nothing was committed). Immediate
  cancels (gate duck + server agrees; transcription) are unchanged.
  `RMSGate.Output.levelDb` carries the sub-frame level for the log.
- Diagnostics (content-free, a handful of lines per session): `voice gate
  open|close level=…dB floor=…dB margin=…dB` from the engine, and `voice
  barge-in <event> → duck,timer300 [state gate= server=]` from the client for
  speech_started/stopped, gate open/close, interrupt, and any decisive tick.
  With the USB syslog these say exactly what interrupted a reply and why.
- Tests: `BargeInTests` 2/2b/2c rewritten around the two-sided confirm; 13
  and 14 now have the mic agree before the confirm they assert.
- TODO after device validation: port the same confirm rule to web
  `lib/voice/bargein.ts` (`tick`) and Android `core/logic/BargeIn.kt`
  (`onTick`) + their tests, so the three stay in lock-step.
- Ship: build 53 — Ahmad: "worse … it kept tripping itself".

**Then (build 54): it was interrupting itself on its own echo.** The new
diagnostics said it outright. At 14:04:52–53 the user's turn ends, the reply
starts on the loudspeaker with the gate OPEN, the server VAD hears the reply's
echo (`speechStarted → duck`), a transcription delta of that echo arrives
0.4 ms later and — via the accelerator — cancels the reply, and the server
then commits the echo as a user turn and ANSWERS it. Underneath: the RMS
gate's floor clamps at −70 dBFS because voice processing's noise suppression
leaves the idle mic near digital silence, so the gate opened 6–9 dB above the
clamp — at −65, −67, −70 dBFS, i.e. on nothing — and residual echo sailed
through. Web and Android use the same −70 clamp on raw mics (floor ≈ −50),
which is why it never showed there.

- **`BargeInProfile.halfDuplexWhilePlaying`** (speaker: true, low-echo:
  false) → `GateContext.forcedClosed` while `playbackQueued`: the gate slams
  shut, uploads digital silence, and discards its pre-roll (or the reply's
  tail would prefix the next turn). Nothing the phone plays can reach the
  server as speech. Talk-over still works while the model is only thinking
  and on earphones/Bluetooth; the Interrupt button cuts a playing reply on
  the loudspeaker; hold-to-talk's `forcedOpen` wins.
- **`RMSGate.floorMinDb` −70 → −58** on iOS (documented deviation from
  web/Android): opens at −52 idle / −49 while playing, above the VP residual.
- **Transcription accelerator** obeys the two-sided rule (`gateOpen` required)
  — deltas stream for the previous turn and for the echo.
- **Diagnostics** now report the level of the sub-frame that flipped the gate
  (it was the last sub-frame of the buffer, which read as "opened at −70").
- Tests: 5/5b (transcription with/without the mic), 11/15 updated for the
  forced-closed context, 16 (half-duplex: controller + gate incl. pre-roll
  discard + reopen). 45 voice tests green.
- Ship: build 54 — Ahmad: no self-tripping any more; the reply completed —
  but under table noise it "broke up like a laggy call".

**Then (build 55): the break-up was iOS's own voice processor.** The log for
that reply shows the client doing NOTHING — no duck, no gate open, no
restart, no player error — and the audio server flat. What attenuates the
speaker under loud near-end sound with nobody asking is the voice-processing
unit's double-talk suppressor (what a speakerphone call does when you talk
over the far end). On the loudspeaker we are half-duplex now, so its echo
canceller buys nothing there.
- **`VoiceAudioEngine.wantsVoiceProcessing(for:)`**: voice processing is
  enabled on every route EXCEPT the built-in speaker (receiver / earphones /
  Bluetooth keep AEC/NS/AGC: they run full-duplex and the earpiece leaks).
  Logged at start: `voice engine route=… voiceProcessing=…`. A mid-session
  route change keeps the setting chosen at start (documented gap: speaker →
  headphones runs without AEC, harmless; headphones → speaker keeps VP and
  the suppressor with it — half-duplex still prevents self-tripping).
- **`GateContext.forcedClosed` now spans `modelBusy`** (response.created →
  drained), not just `playbackQueued`: the queue runs dry for a moment at the
  start of a reply and between bursts (14:21:09 in the log), and each gap let
  the gate open on noise and duck the next words to −12 dB.
- **Playback-queue diagnostics**: `voice playback queued gapMs=…` /
  `voice playback drained played=…` — the log's answer to "did the audio
  itself have gaps?" if any break-up remains.
- Tests: 46 voice tests green (new: the route rule; 15/16 for the wider mute).
- Ship: build 55 uploaded; on-device retest pending Ahmad.

## Where things stand (2026-09-19, latest) — the CLIENT owns turn-taking (1.1.1 build 66)

Three phone tests over Wi-Fi (`pymobiledevice3 syslog live`, builds 64/65) and
four scripted probes against the live proxy (python `websockets`, a Supabase
JWT, a `say`-generated 16 kHz sample) settled what was wrong:
- **The server was cutting its own replies.** DashScope server_vad defaults to
  `interrupt_response:true`: the moment its VAD hears speech it cancels the
  in-flight response (`response.done status=cancelled reason=turn_detected`).
  On the loudspeaker that "speech" is the reply's own echo → replies came out
  in fragments, and no client logic could undo it after the fact. The flags
  `interrupt_response:false` + `create_response:false` ARE honoured (echoed
  back in session.updated); with them the server still segments, commits and
  transcribes (completed transcript ~300 ms after speech_stopped) but never
  cuts or answers by itself.
- **`response.create` in the same breath as `response.cancel` kills the
  socket** ("thread pool exausted max_workers 100", close 1007). Sent after
  the cancelled response.done (~300 ms later) it works.
- **Captions**: every completed input transcript was shown as the user's line,
  so the echo (sometimes transcribed as Chinese — "嘿。") replaced the reply on
  screen a second or two in. The reply's own transcript deltas legitimately
  arrive ~1 s BEFORE its first audio (text first, then speech): not a bug.

What changed (`App/Voice/BargeIn.swift`, `App/Voice/VoiceRealtimeClient.swift`):
- `TurnDetection` sends both flags off on every route (hold-to-talk stays null).
- Every reply is created by the client from a segment's COMPLETED transcript:
  real words → `.userTurn` (the only path to a user caption now) +
  `response.create`; no words / echo (≥70 % of the words the reply on air or
  the one before it said — the reference is those two replies, not a long
  tail) → `conversation.item.delete`, nothing asked, nothing shown.
- Interruption: loudspeaker = the first real words of a segment that began on
  air (or within 1.5 s of drain) cancel + flush; low-echo routes keep the
  energy DUCK→CONFIRM→CANCEL. Then `pendingCreate` holds the ask until the
  cancelled reply's done (fallback tick 1.5 s; "no active response" → ask at
  once); the Interrupt button drops a pending ask.
- A transcript whose segment we never saw begin never cuts a reply (caption
  only; a turn when idle). Hold-to-talk transcripts are caption only.
- Log: `voice response.done status=… reason=…`, and `respond` / `delete-echo`
  / `turn` in the `voice barge-in` lines.
- Tests: `BargeInTests` rewritten to the contract (45 green), `VoiceCaptionTests`
  green (late-ASR race preserved), suite 648 with 1 red —
  `CrashBreadcrumbsTests.testNoReportIsOfferedAfterACleanRun` is a
  pre-existing isolation flake (a prior run's trail in the simulator
  container; passes on a fresh simulator).
- Expected feel on the loudspeaker: the reply keeps playing while you talk over
  it and stops ~0.9 s after your last word (600 ms VAD silence + the
  transcript), then the answer starts ~0.8 s later. A stop at the FIRST word
  needs echo cancellation the gate can trust — the next step if wanted.
- Ship: 1.1.1 (66) uploaded (delivery b9e73040); on-device retest pending Ahmad.

**Then (build 67): the phone test of 66 (23:50, Wi-Fi log) — right except two
garbled echoes.** Every response.done `completed` (no server cuts), 7 echo
segments deleted, 6 real turns answered, one genuine talk-over ("How about
Tuesday?" over the tomorrow reply) worked. But two SHORT replies came back
through the mic garbled — "Saturday's clear" heard as "Saturday's players",
"Monday's open" as "Monday is open" — scored 1/2 and 2/3 against the 70 %
all-words rule, were taken for the user, cut the reply and were answered
again (the self-tripping). Echo scoring v2 (`BargeIn.swift`):
- Filler words (`stopWords`: is/the/you/how/about…) don't count; the
  transcriber adds and drops them freely and a real interruption is full of
  them ("How about Tuesday?" → only "tuesday" is judged). Filler-only
  utterances ("How about you?", "Okay.") are judged whole at 70 %.
- Plurals/possessives fold at the comparison (`stem`: mondays → monday).
- The threshold depends on WHEN the segment began: reply audio on air → half
  the content words is echo (a two-word interruption sharing a topic word can
  be repeated once the reply ends); in the 1.5 s drain grace only the tail can
  echo → 60 % ("Tuesday morning" after "Tuesday's wide open" stays a turn).
- Echo needs audio: a segment that began while the model was only THINKING
  is never echo (its transcript deltas land ~1 s before its audio, so the
  reference already holds the words). Streaming words of a known segment stop
  a busy model early; a segment we never saw begin still never cuts a reply.
- Tests: `BargeInTests` 51 (new 21a–f replay the 23:50 session), captions 9.
- Ship: 1.1.1 (67) uploaded; on-device retest pending Ahmad.

**Then (build 68): the phone test of 67 (00:04, Wi-Fi log) — "interrupted it
three times, it ignored me till it finished, then tripped itself", and no
greeting.** The garbled-echo rule held (4/5 → echo). Three findings:
- **Interruptions judged too late, and lost.** On the loudspeaker a VAD
  segment can only end when the reply pauses (its echo keeps the VAD open),
  so a verdict at the end of the segment is a verdict AFTER the reply — and
  the user's words, FIRST in the segment, were outscored by the echo of what
  played after them ("How will this be like? You've got a few tasks wrapped
  up" → 4/5 → echo). Fix: the transcriber's LIVE GUESS (`stash` on every
  transcription.delta, cumulative, first word ~200 ms in — `text` stays empty
  until the segment ends) now feeds the controller; `isEarlyInterruption`
  cuts the reply mid-segment on clear evidence: ≥ 3 words, the first content
  word not one the model said, ≥ 1 content word it never said, not echo. And
  `isEcho` gained a LEADING rule mirroring the trailing one (≥ 3 words before
  the first echoed word, with a content miss among them → theirs).
- **A segment completed in pieces.** "Coming up on." (echo) then "Day." as a
  second completed transcript for the SAME item → judged alone → cut the reply
  → answered; its echo "And Friday." landed 90 ms after the flush, outside any
  grace window → answered too. Fix: a later short piece of an echo-judged
  segment is echo; `conversation.item.delete` for echo / no-word items is
  HELD (`pendingDeletes`) until the next segment starts or a reply is asked
  for, so the user's question inside the same segment (a later completed for
  the same item, ≥ 3 words / a content miss) un-deletes it; a flush now sets
  `lastDrained` so the flushed tail's echo gets the 1.5 s grace window.
- **No greeting.** Socket open, primer + response.create sent, NOTHING back
  (no response.created, no error) until the user spoke 6 s later; the session
  before had greeted in 2 s. `scheduleOpeningWatchdog`: one more
  response.create if nothing has started 2.5 s in (log: `voice opening retry`).
- `pendingCreateFallbackMs` 1500 → 2500 (a done took 1.9 s with a tool call in flight).
- Tests: `BargeInTests` 60 (22a–e, 23a–d replay the session), captions 9.
- Ship: 1.1.1 (68) uploaded; on-device retest pending Ahmad.

**Then (build 69): the phone test of 68 (00:25) — and Ahmad's call to stop
patching case by case.** The greeting came back, the live-guess cut worked
twice within a second, the held deletes kept a question that shared its
segment with the echo. Three new misses: a pause mid-sentence got the
fragment answered and the continuation cancelled it ("kept tripping itself"
on long questions); "Alright" heard as "All right" (two unknown words) cut a
reply; the echo of "Is there anything…" caught mid-word as "Is there any" cut
another; "Have to go" cut on "go" alone.

*The holistic view.* Builds 63–68 fought an ACOUSTIC problem in the TEXT
domain: the loudspeaker's echo reaches the server, the server transcribes
it, and the client tells the user's words from the reply's by comparing text
— which a transcriber can defeat a new way every session. The structural
fix is to keep the echo out of the mic stream: **Apple voice processing
(echo cancellation) is ON for the loudspeaker again** (`VoiceAudioEngine.
wantsVoiceProcessing` → true everywhere). It was switched off in build 55
because the server kept cutting replies on residual echo — which build 66
proved was the server's own turn detection, now off. What stays, because it
is architecture rather than heuristics: the server never cuts or answers by
itself; every reply is asked for by the client from a completed transcript;
a cancel settles before the next ask; and the **turn hold** (new here):
`turnHoldMs` 500 of quiet after the user's last transcript / speech start
before `response.create`, so a pause mid-sentence is bridged (VAD 600 +
hold 500 ≈ 1.2 s) instead of answered. The text rules (echo ratio, leading /
trailing words, live-guess cut, held deletes, prefix match for a word caught
mid-word, three-letter evidence) remain as the backstop for residual echo.
Known cost of voice processing: its double-talk suppressor attenuates our
playback under loud near-end sound — a dip during a talk-over we cut anyway,
or in a loud room. If that proves unacceptable, the next structural step is
a software canceller (speex/WebRTC AEC3) fed with our own playback as the
far-end reference — a day's work, not a heuristic.
- Tests: `BargeInTests` 64 (24a–d), captions 9, engine 5.
- Ship: 1.1.1 (69) uploaded; on-device retest pending Ahmad.

**Then (build 70): 69 on the phone (00:42) — Ahmad: "I like how the agent
is performing currently, don't touch the architecture."** With echo
cancellation on there was not one echo segment in the session (a 7 s reply
included); two talk-overs cut within ~1 s of speech start; a long question
with "um"s and pauses was one turn. The only fault was the FIRST connection:
1 s after the socket opened the server sent `thread pool exausted
max_workers 100` and dropped it — the user saw "Socket is not connected"
and had to tap again (the same error hit the scripted probes; it is the
provider's capacity). Fix, outside the architecture: a server failure
BEFORE ANY REPLY (an `error` event, or a drop after the handshake) is not
surfaced — `VoiceRealtimeClient.failedBeforeAnyReply` + `onTransportEnded`
→ `VoiceModeScreen` reconnects quietly (fresh engine + client, 800 ms
apart, twice at most; log `voice reconnect #n`), and only then shows "The
voice server dropped the session twice". Tests: `VoiceReconnectTests` (3).
- Ship: 1.1.1 (70) uploaded.

## Where things stand (2026-09-12) — ONE freshness owner, and a cursor catch-up that is the correctness path

The reason live-sync bugs kept coming back: `postgres_changes` has **no
replay**, and a channel can report `SUBSCRIBED` while being permanently deaf
(both proven against production on 2026-09-12). Any client that treats realtime
as its correctness path drifts out of date at the first network gap, sleep or
doze — and iOS had *three* half-owners of "am I in step?", none of which could
see that failure.

What changed:

- **`Sources/UnstuckSync/FreshnessOwner.swift` (new) — the single owner.**
  Everything now REPORTS to it (`FreshnessSignal`) and nothing else schedules a
  refresh. Triggers: cold start after hydrate, app becoming visible, network
  regained (a real `NWPathMonitor` — iOS had none), socket (re)connect, channel
  (re)subscribe, token refresh, a 60s floor interval while visible, and manual /
  BG refresh. It coalesces overlapping triggers into ONE in-flight pull, and a
  pull can never run beside a hydrate because both go through it.
- **`Sources/UnstuckSync/CatchUpPuller.swift` (new) — cursor catch-up.**
  Per-table high-water marks (`sync_cursors`, migration `v5`) drive
  `column >= cursor` page reads instead of a full-table replace: tasks,
  collections, tags, life_areas, profile_facts on `updated_at`; sessions on
  `completed_at`; reason_logs on `at`. `cal_blocks` and `captures` have NO
  monotonic server column, so they keep the full replace (the follow-up is a
  server migration adding `updated_at` to both). Deletions are invisible to a
  cursor pull, so a paged `select=id` sweep drops local rows the server no
  longer has. Nothing ever clobbers a pending local write — tasks/profile_facts
  reuse the realtime mirror's own LWW guards, the rest skip while the outbox
  holds an un-acked op — and the cursor only advances over rows the client
  accepted a verdict on.
- **Deafness detection that does not trust channel status.** Two rules, both
  counted in `FreshnessStats`: (a) silence — nothing delivered for 10 minutes
  while visible and supposedly subscribed; (b) the stronger oracle — a catch-up
  APPLIED a row older than the 10s grace window, which a healthy channel would
  have delivered first. Either verdict rebuilds every subscription
  (`RealtimeMirror.rebuildSubscriptionsNow`).
- **The cold-launch hole is closed.** `startForegroundSafetyNet` used to
  early-return while `coordinator` was still nil — the normal cold-launch
  ordering — leaving a whole session with no periodic pull. Visibility is now
  remembered in `AppModel.foregroundVisible` and re-applied from `start()`.
- **Settings are live (migration 063).** `RealtimeMirror` subscribes
  `notification_preferences` + `user_preferences`; both events and every gap
  trigger call `AppModel.refreshServerPreferences()`, which clears the
  once-per-process guards. Notification level, reminder lead, timezone, PA
  rituals, struggles and the assistant-interview flag now reach the phone
  WITHOUT a relaunch. `sharing_preferences` is deliberately NOT subscribed —
  iOS reads no column of it. Moment dismissals stay device-local by design.
- **Tests:** `Tests/UnstuckSyncTests/CatchUpConvergenceTests.swift` simulates
  the gap (subscription down → rows written server-side → subscription back,
  no realtime event ever reported) and asserts convergence in the same process.

## Where things stand (2026-09-11, latest) — the guided tour's a11y lockdown, and a UI suite that can actually fail

The UI suite was red in three places and quietly hollow in several more. The
one PRODUCT bug behind it:

- **The tour's round-4 a11y lockdown hid surfaces the tour tells you to use.**
  `TourWindowHandle.setAccessibilityLock` set `appWindow.accessibilityElements
  Hidden = true` for the whole run, but `tourClaims` deliberately passes
  touches THROUGH on two kinds of step — `cutoutInteractive` (the ringed
  assistant launcher) and `surfaceInteractive` (the Settings → Notifications
  section a settings step opens). Sighted users could tap those; VoiceOver
  users could not find them at all, so "the Assistant lives here, bottom-right"
  and "you set how present it is" were unfollowable without sight. Fixed by
  splitting the lock in two: modality stays on for the whole run, hiding is now
  `tourHidesAppFromAccessibility(ctx:)` — a pure function that mirrors
  `tourClaims` branch for branch and answers "is there ANY pass-through region
  right now?". `TourAccessibilityHidingTests` pins the invariant, including a
  property test: wherever the app window is hidden, no probe point passes
  through. (Shipped in build 39 / commit c255625; not in a tester's hands as an
  a11y complaint yet, but it was real.)

Everything else was TEST rot, all of it the same shape — **bare label /
`firstMatch` queries that now collide with the AI gateway card on Today**,
which added a TextField ("Ask me anything…") and pushed the Start-Next hero
under the floating bottom nav:

- `app.textFields.firstMatch` inside the new-task sheet resolved to Today's
  gateway composer BEHIND the sheet (not hittable) — that was the long-standing
  `testExitWithAskKeyboardUpRestoresAppKeyWindow` failure.
- `app.staticTexts["Focus"].firstMatch` in Settings resolved to the hero's
  Focus button behind the sheet, not the Settings row.
- XCUITest reports elements UNDER the floating bottom nav as `isHittable`, so
  `testFocus` "tapped Focus" and started nothing for as long as the hero has
  been below the fold.
- `app.staticTexts["Week"/"Month"/"Day"]` match nothing (they are Buttons with
  accessibility labels), `app.staticTexts["Upcoming"]` no longer exists, and
  "End for now" opens a "How did that land?" sheet first — so the store walk's
  `03-recap` shot was a picture of the reflection sheet.
- Tour state lives in UserDefaults and outlives the in-memory seed, so a tour
  test that ended mid-run left a "Continue your tour?" card over the first
  screen of every later seeded test. `startUITestMode` now clears it unless
  `UITEST_TOUR=1`.

Fixes: stable identifiers where a label is ambiguous (`new-task-name`,
`assistant-input`, `settings-row-<label>`), every `if element.exists { … }` and
`guard … else { return }` converted to an assertion, and a `scrollIntoReach`
helper that requires an element to clear the floating nav rather than trusting
`isHittable`.

**Known, not fixed (product judgement needed):** Today's primary CTA — the
Start-Next hero's Focus button — now renders below the fold on a fresh launch,
under the gateway card, and the tour's step 2 rings a target that is mostly
off-screen. The tour has no scroll-into-view for its target.

- **Tests.** `swift test` 922 green; `-only-testing:UnstuckAppTests` 513 green
  (was 495); `-only-testing:UnstuckUITests` 15 tests, 1 skipped
  (`VoiceReproUITests`, needs credentials), 0 failures.

## Where things stand (2026-09-05) — tester round: shared tasks by schedule, interview parity, launcher on Calendar (1.1.0 build 35)

Zubair's TestFlight report on build 34: shared tasks all under Today, none on the calendar, month
shows nothing scheduled, interview re-asks at 1/5, no ✦ on Calendar, web asks 7 questions vs 5.

- **Shared tasks** — root cause was the data model: `tasks_shared_with_me()` carried no schedule and
  `cal_blocks` is owner-only. Migration 052 (web repo) now returns the owner's NEXT live block
  (`next_block_id/date/start_time/duration_minutes/done` + `estimate_min`, `life_area`) and a
  `shared_task_blocks(p_from, p_to)` range RPC (≤62 days). iOS rule set (same as web + Android): a
  shared task behaves like your own — Today only when the owner's block is today or the task is
  undated; Upcoming/Backlog by date; the group respects the life-area pill; rows show the slot.
  Day/Week/Month render read-only "shared" blocks (dashed, owner name; never drag/resize/edit/
  delete; tap → shared-task sheet with "Planned …"). Month gets per-day marks (● own planned,
  dashed ring = shared) beside the focus density. Fetch/cache: `ShareModel.sharedBlocks`
  (`Calendar+Shared.swift`), one RPC per Mon–Sun/month window, refreshed on shares-changed.
- **Interview** — now the web's 7 questions (rhythm, work, people, fixed, commitments, nogo, nudge)
  + rituals picker; "done" mirrored to `user_preferences.assistant_interview_done_at` and applied
  BEFORE the auto-open gate decides (`AppModel.applyServerInterviewFlag`), so a user onboarded on
  the web is never re-asked; the panel auto-opens once per device then shows the pill; a failed
  save keeps the step and says so ("Couldn't save that — try again"); per-question Skip + header
  "I'm done" + chevron to park (no "Skip for now").
- **Assistant launcher** on the Calendar tab (day grid padded so it never covers the last hours).

Tests: packages 810, app bundle 401 (all green).

## Where things stand (2026-09-03) — review round (3 independent reviewers → 49 findings → all fixed) + TestFlight 1.1.0 (34)

Three independent reviews (harness/contract/data; CallKit/PushKit/voice; surfaces/parity) of the
2026-09-02 build-out produced 25 + 8 + 16 findings; every one is fixed and covered by tests
(packages 782, app bundle 368, all green). What matters to know:

- **Executor writes now AWAIT the write-through** (`AppModel.*Awaiting` variants): a turn that
  creates, schedules and deletes a task leaves no ghost block; `add_capture` → `promote_capture`
  in one turn works. The UI's fire-and-forget methods wrap the awaiting ones.
- **Calls:** a duplicate VoIP push for the same callId is a state no-op (CallKit still gets its
  report); a spoken "call me back in ten" issues exactly ONE end transaction (the coordinator is
  the single source of truth; the test fake now completes CallKit actions asynchronously); call
  tools resolve tasks through the turn scratch and use the shared past-date/past-time strings;
  outcomes are persisted + retried in order; `UNSTUCK_CALL` category with an Answer action; a
  fallback call arriving while Talk is open takes over the open screen; signed-out devices drop
  calls and unregister the VoIP token.
- **Memory/surfaces:** the interview waits for the first `profile_facts` hydrate
  (`AppModel.profileFactsHydrated`); "Skip for now" parks (resumable), "I'm done" finishes;
  work-hours facts are `context` (web parity); people free text keeps "Maleek — son, 9" as one
  fact; `open_screen` goes through the deferred deep-link path (works from the sheet and Talk),
  switches calendar mode, reaches People / Areas in Settings; moments are memoised.
- **Honesty:** `unshare_task`, `set_notification_level`, `set_reminder_lead`, `save_profile_fact`
  (store failure vs filter), `update_call`/`cancel_call` (zero rows) report failure instead of
  `ok:`; ADHD struggles are canonicalised (`AppModel.canonicalStruggles`) so the engine's
  "Starting" rules fire.

Device-only validation unchanged (see the 2026-09-02 section): VoIP ring on a physical iPhone,
CallKit audio after `didActivate`, snooze re-ring, fallback-B, take-over while Talk is open.

## Where things stand (2026-09-02) — AI gateway + calls (port of the web gateway)

Plan: `../unstuck/docs/ios-gateway-plan.md`. Source of truth: the web's
`lib/assistant/*`, `components/dashboard/gateway-card.tsx`,
`components/settings/facts-panel.tsx` and the generated
`docs/assistant-tool-contract.md` (tool names + `ok:`/`error:` strings are
the contract the server prompt reads — iOS matches them byte-for-byte).

- **Memory (A0).** `profile_facts` in GRDB (`UnstuckData` Records /
  Repositories / AppDatabase) with outbox push, hydrate, realtime mirror and
  soft-delete tombstones (`UnstuckSync/ProfileFactsService.swift`, DbRowCodec,
  Hydrator, RealtimeMirror, WriteThrough); the pure `ProfileFactsLogic` in
  `UnstuckCore/Logic/ProfileFacts.swift` (save with person-only refine,
  `preferredName` / `noNamePreference` / `detectStylePreference`,
  `isInstructionLike`). Ritual prefs + dismissed moment ids live in
  `App/Features/PAPrefs.swift` (`PAPrefsStore` static get/set over the web's
  UserDefaults keys + the `@Observable PAPrefs`; ONE instance =
  `AppModel.paPrefs`, read by the gateway card, the interview picker, Settings
  and the `set_ritual` tool). `AppModel.profileFacts` is the service.
- **Engine — 56 tools, honest harness (A1).** `AssistantContext.swift` builds
  the contract-shape context (sending `profile` flips the server into profile
  mode) and `VOICE_TOOLS` (56 = 52 + the four call tools). `AssistantTools*.swift`
  run the 52 app tools with the contract strings; `App/Calls/CallTools.swift`
  runs `request_call` / `cancel_call` / `update_call` / `get_calls` (+ the
  call-level `snooze_call`) as the LAST hop of `runAssistantTool`, so text and
  voice share one dispatcher. `AssistantHarness.swift` is the honest harness:
  no synthesised "Done.", the fabrication guard + one hidden bounce,
  `stripSelfCorrection`, `READ_ONLY_TOOLS`, the `finish_reason=length` hint,
  a visible send queue. Pure ports with the web tests translated in
  `UnstuckCore/Logic`: AssistantGuard, AssistantTime, AssistantInsights,
  InsightsRead, Brief, Moments, Patterns, AssistantReceipts (receipts + undo
  for every tool — undoing a booked call cancels it through
  `CallCoordinator.shared.callsClient`, async, receipt flips once the server
  accepts).
- **Surfaces (A2).** `GatewayCard.swift` on Today (zero-token brief, ONE
  moment with its actions — `GatewayActions` / `GatewayMomentState` are pure
  and tested — the interview pill, chips, a composer whose send hands off to
  the Assistant sheet; mic inside the bar → VoiceModeScreen).
  `Interview.swift` (`InterviewMachine`: resumable, skippable, auto-done at
  ≥3 facts but never while open; `InterviewFlowView`). `FactsPanel.swift` =
  Settings → "What Unstuck knows" (list with dates, edit = forget + re-save,
  forget one / everything, add, ritual toggles). `AssistantSheet` sends while
  a turn is in flight (queued, faded pending bubble). Voice parity in
  `VoiceRealtimeClient` / `VoiceModeScreen` (opening primer, vocabulary,
  integrity corrective, English pin, name-once).
- **CallKit path (C1) — `App/Calls/*`.** `VoipPushRegistry` (PushKit; reports
  to CallKit SYNCHRONOUSLY even from a killed launch), `CallKitBridge`
  (CXProvider / CXCallController behind the `CallProviding` /
  `CallControlling` seams; the delegate conformances are `@preconcurrency`
  because both queues are main), `CallCoordinator` (the state machine — ring
  timeout, focus-busy, stale anchor, hours window, snooze, launcher grace —
  fully unit-tested against the fakes in `CallSeams.swift`),
  `AppCallEnvironment` (environment + notifier + buffered outcome reporter;
  `attach(model:client:)` from `AppModel.start`), `CallScript` (deterministic
  call opening), `IncomingCallPayload`, `CallSettings` + `CallSettingsView`
  (Settings → "Calls from Unstuck": allowed hours, default lead, Test call
  now), `CallMeSection` in the task editor ("Call me about this").
  `UnstuckSync/CallsClient.swift` = `call_requests` + `call-outcome`
  (live statuses = scheduled / snoozed / calling, like the web).
  Info.plist / entitlements carry the `voip` background mode.
- **Seams.** (1) `AppModel.installCallVoiceLauncher()` runs right after
  `CallCoordinator.shared.attach(model:client:)` in `start()`; until
  `App/Calls/RealtimeCallVoiceLauncher.swift` lands it is the no-op in
  `App/Calls/CallVoiceLauncherStub.swift` — delete the stub with it.
  (2) `CallCoordinator.shared.onFallbackAnswer` (fallback B: a tapped "call"
  alert push opens Talk with the `CallSession`) is still unset — wire it from
  the launcher. (3) The call tools reach voice through `runAssistantTool`;
  `VOICE_TOOLS` carries their schemas. (4) The VoIP dispatcher + `call-outcome`
  edge functions (C0) live in the web repo.
- **Device-only validation** (nothing here runs on the simulator): a VoIP
  push ringing CallKit on a physical iPhone (sandbox APNs under Debug),
  `provider(_:didActivate:)` → voice engine start (the silent-call rule),
  audio staying up in the background during a call, snooze re-dispatch, the
  hours window applied on receipt, "Test call now" end-to-end, the voice
  opening on a real realtime session, the gateway interview on a fresh
  account, and cross-device facts (hydrate + realtime) against the web.
- **Tests / build.** `xcodegen generate` first (the project is generated and
  files were added). Packages: `TZ=UTC swift test --scratch-path .build-int`
  (779 tests, green). App: `xcodebuild -project Unstuck.xcodeproj -scheme
  Unstuck -destination 'platform=iOS Simulator,name=iPhone 17'
  -derivedDataPath /tmp/dd-int test -only-testing:UnstuckAppTests`
  (302 tests, green). Build: the same command with `build`.
  Scratch build dirs (`.build-*/`) are git-ignored.

## Where things stand (2026-08-02) — assistant redesign (port of the web cockpit)

Source of truth: `../unstuck/components/assistant/*` + `../unstuck/lib/assistant/*`.
The bubble's dual Assistant|Feedback sheet is GONE — the ✦ launcher opens the
Assistant panel and nothing else.

- **Pure ports in UnstuckCore** (all unit-tested against the web's own cases):
  `AssistantSuggestions.swift` (`buildSuggestions` — 3 chip groups built from
  the user's real tasks/lists, same predicates + copy, real Sat/Sun dates),
  `AssistantReceipts.swift` (`deriveReceipt` from the executor's `ok: …` string
  + `planReceiptUndo`), `AssistantCheckin.swift` (`buildCheckin`),
  `AssistantShareRequest.swift` (`matchCandidate` / `normalizeLevel` /
  `resolveShareRequest` — stages, never shares), `UsableToday.swift`
  (`usableToday` + `fmtHrs`, the web's right-rail math).
- **AssistantModel** now owns ONE endless thread of `AssistantTurn` (the wire
  `ChatMessage` + `at` / `local` / `receipts`). Display persists 200 turns
  under `unstuck.assistant.thread` (the old `unstuck.assistant.history`
  `[ChatMessage]` blob migrates once); `modelWindow` derives the 40-turn model
  view per request, aligned to a user turn, local turns excluded. Receipts
  attach to the CLOSING assistant turn; `undoReceipt` / `undoAllTarget` /
  `undoAll` apply through the same write methods the UI uses. `share_task`
  resolves against a cached circle roster and appends to `pendingShares`;
  nothing leaves the device until the confirm card's tap.
- **UI**: `AssistantSheet.swift` (panel shell — header + eyebrow, ⋯ menu with
  read-aloud + Clear conversation, thread with day dividers / receipts / share
  cards, chips block sized to the viewport and scrolled to its top on open, ✦
  re-summon) and `AssistantHome.swift` (context strip NEXT/USABLE/PAUSED, chip
  groups + WrapLayout, receipt row, share confirm card + the testable
  `performConfirmedShare` seam, `assistantDayLabel`).
- **Feedback** moved to Settings → Account → "Send feedback" (`FeedbackSheet`).
- **AI kill-switch**: `settings.assistantEnabled` (Settings → Interface).
  OFF ⇒ no launcher (`AssistantLauncherModifier`), no panel (the sheet binding
  in MainTabScaffold), no voice (`voiceConfigured`), and `unstuck://assistant`
  is dropped. Everything opens through `AppModel.openAssistant()`;
  `AppRouter.showBubble` / `BubbleTab` are gone (now `showAssistant`).
- Tests: +47 UnstuckCoreTests, +13 UnstuckAppTests (558 package / 160 app, all
  green). UITest anchors updated (the Feedback toggle no longer exists).

## Where things stand (2026-07-16) — one true shared session (partner co-focus v2)

Spec: `../unstuck/docs/shared-session-spec.md` (migration 047 already applied:
`log_shared_focus` now admits the task OWNER + 12h server clamp). A
partner-shared task now has AT MOST ONE live session — same clock on every
screen, pause/resume/extend/finish from either side applies to both.

- **Pure reducer** `Sources/UnstuckCore/Logic/SharedSession.swift`:
  `SharedSessionState` (the full `timer` wire snapshot), `SharedSessionMsg`
  (all-optional receive shape), `sharedSessionStep` (apply-iff-newer LWW on
  `(rev, atMs)`, same sessionId, not locally ended), `sharedSessionAdoptable`
  (has id, !ended, 0 ≤ now−start < 12h), `canonicalElapsedSec`. 24 new tests in
  `Tests/UnstuckCoreTests/SharedSessionTests.swift`.
- **LiveSession** gained Codable-optional `sharedSessionRev` / `lastAppliedRev`
  / `lastAppliedAtMs` / `sharedSessionEndedBy` (old blobs decode);
  `FocusTimer.adopt(...)` joins an in-flight session (bypasses mint, keeps
  treatment; caller re-stamps sharedFocusLevel/prior); `start()` clears the new
  bookkeeping.
- **Wire** (`CoFocusPresenceClient`): `timer` broadcast + presence track carry
  `sessionId/rev/atMs/ended` (epoch-ms always `.rounded()` — Android Long);
  `onControl` hands EVERY incoming timer msg to the app layer;
  `broadcastEnded(_:)`; `probe(taskId:selfId:)` = one-shot join→hello→≤1.5s
  wait for an adoptable state. supabase-swift DEDUPES channels by topic, so the
  probe piggybacks on a pre-subscribed channel (never removeChannel on one it
  didn't create), and every CoFocusModel teardown registers into
  `AppModel.coFocusTeardown` so successors/probes on the same topic chain
  behind it.
- **Session-lifetime channel** (`App/AppModel+SharedSession.swift`): AppModel
  owns the CoFocusModel keyed on `cachedLiveSession` being a partner candidate;
  `refreshLiveSession()` (the existing choke point) broadcasts every local
  control as a full-state snapshot with rev+1 (rev persisted), broadcasts
  `ended:true` (rev+1) when the broadcast session disappears (finish / cancel /
  shade-End / displaced), and applies incoming controls via the reducer —
  REPLACE fields, persist WITHOUT rev bump, drive Live Activity + check-in
  side effects, never the pause-reason sheet / pause nag for a REMOTE pause.
  Calm attribution ("Ann paused" — sticky; "Ann resumed" — transient) under the
  FOCUSING label; remote end → dismiss + recap "…ended the session"
  (`RecapState.endedBy`).
- **Join-or-mint:** FocusView `.task` probes before `FocusModel` mints (owner
  partner-badge OR recipient partner level) and adopts mid-clock; adopted sids
  are registered with the signal reducer so NO session_start ping fires (only
  the minter announces); a remote `ended` fires no session_end ping.
- **Accrual = ledger-only:** every partner-shared session accrues
  `total_focused` EXCLUSIVELY via `log_shared_focus(taskId, sec, sessionId)` —
  OWNER included (skips the direct bump in `finishFocus` / displaced path;
  still writes the own Session row with id = the shared session id). Both
  sides finalize the same id → exactly-once (046 PK + 047 owner guard).
  Resurrected paths (shade-End / displaced / reap) cap at estimate+30min.
- **Leave keeps it running:** `finalizeSharedOnLeave` REMOVED; the Today live
  card now renders a row-less shared session (synthesized task, title from
  sharedWithMe) and `reopenLiveFocus` re-carries the share level. Relaunch reap
  only consumes a shared session when TRULY stale (elapsed > estimate + 30min).
- **Compat:** a `timer` without `sessionId` (old builds) stays display-only.
  Also fixed while there: extend (local AND remote) now updates the Live
  Activity estimate; pause/resume/start use the extend-aware session estimate.
- **Adversarial-review fix pass (same day, 8 findings):**
  1. *Channel teardown safety:* ALL CoFocusModel ops (start/stop/endSession +
     the adoption probe) now run on ONE app-wide FIFO chain
     (`AppModel.chainCoFocusOp` — head read/re-registered at enqueue on the
     main actor, never a stale captured task), and teardown decides at
     EXECUTION time: when `liveCoFocusTaskId` owns the topic it `detach()`es
     (new CoFocusChannel API — cancels own callbacks, keeps the topic-deduped
     channel subscribed + tracked) instead of `stop()` (untrack+removeChannel).
     So a PartnerPresence row unmounting (incl. via the live-session
     suppression) can never kill the session-lifetime channel.
  2. *Offline finish is durable:* `CircleClient.logSharedFocus` now returns
     `.ok/.notAllowed/.failure`; `AppModel.logSharedFocusDurable` routes every
     accrual — on failure it persists `{sessionId, taskId, sec, estimateMin}`
     (UserDefaults `unstuck.pendingSharedFocusLedger`) drained on foreground
     (`syncNow`) + relaunch (`start`), idempotent per sessionId; on
     `not_allowed` (share revoked mid-session) an OWNER falls back to the
     direct outbox-durable totalFocused bump.
  3. *No spurious rev+1 on rebind:* relaunch/flap seeds `lastSharedBroadcast`
     FROM the persisted session (same rev — idempotent re-broadcast); new
     persisted `LiveSession.sharedSessionAtMs` keeps the LWW atMs floor across
     relaunch (reducer floor = max(local, lastApplied)).
  4. *Adoption clock-skew:* adoptable window is now `-2min ≤ age < 12h`
     (`sharedSessionMaxSkewMs`); `FocusTimer.adopt` takes `now` and clamps the
     start to `min(start, now)` for display (the clamp is mirrored into the
     broadcast baseline so it's never mistaken for a local control).
  5. *Adopt-over-existing:* `finalizeDisplacedForAdoption` finalizes a live
     local session with a DIFFERENT id on the same task before adopting —
     capped ledger write under the OLD sessionId (+ owner Session row).
  6. *Ended never dropped:* `CoFocusChannel.broadcastEnded` queues the final
     state when the channel is still subscribing and sends it on subscribe.
  7. *finishFocus ordering:* the sharedLedger path now upserts the resolved
     task row ITSELF inside the ordered Task (await enqueue → flushNow → RPC),
     so land-row-then-RPC actually holds (no second racing saveTask op).
  8. *Parity:* `ended` is TERMINAL in the reducer (bypasses the (rev, atMs)
     LWW when sessionId matches + not locally ended); adoptable/state reject
     an EMPTY sessionId + floor estimateMin to 25; the probe's hello uses a
     RANDOM id (a same-user other-device focuser must answer — multi-device
     adoption); partner-shared sessions (minted or adopted) run with
     `priorAccumulatedSec = 0` so every device's ring shows the one session
     clock.
- **Verify:** `swift build` + `swift test` green (475 tests — reducer/adopt
  suites extended for skew, terminal-ended, empty-sid, estimate floor, clamp),
  `xcodegen generate` + simulator `xcodebuild build` green. NOT committed —
  awaiting review. Live two-device validation still pending.

## Where things stand (2026-06-27) — Siri / App Intents (4 phases)

OS-level Siri control + voice queries, built in `App/Intents/` (the `App/` glob
picks them up; **no Siri entitlement needed** for App-Shortcut intents — the
existing `WorkFocusFilter` already proved App Intents compile). 10 App Shortcuts
(`UnstuckShortcuts`), phrases use `\(.applicationName)` = "UnstuckNow"; they also
surface in Spotlight, Shortcuts, Apple Watch, CarPlay for free.

- **Reads (hands-free, no app launch):** PendingTaskCount, NextTask, TodayPlan —
  speak from the App-Group `UnstuckSnapshot` (counts + task/list names, computed
  with the SAME `visibleTasks` bucketing the UI shows). Written by
  `AppModel.refreshWidgetSnapshot()` on launch / every foreground `syncNow` /
  scenePhase `.background` / BG-refresh.
- **Writes (hands-free):** CreateTask, CaptureThought, CompleteTask (TaskEntity),
  AddToList (item + CollectionEntity). Each enqueues a `PendingWrite` to the
  App-Group queue; `AppModel.drainSiriWriteQueue()` applies them via the existing
  validated mutators → the normal outbox (one write authority). Drained on
  launch / `.active` / BG-refresh. Trade-off chosen by the user: lands in
  seconds, else on next launch (NOT instant-to-backend — that "Mode D" shared-
  keychain path is deferred).
- **Open-app actions:** StartFocus (→ `unstuck://focus-next`, Focus on the
  Start-Next pick), OpenToday, AddTask (open-app fallback). They stash a route in
  the App Group; the app consumes it on `.active` (the `WorkFocusFilter`
  reconcile pattern — a background `perform()` can't drive SwiftUI nav).
- **Ask Unstuck:** freeform → opens the app + sends the prompt to the Qwen
  assistant (`routeDeepLink "unstuck://assistant"` → `assistant.send`). Apple's
  Siri has no third-party tasks domain, so this is the real agent bridge.
- **Entities:** CollectionEntity + TaskEntity (`EntityStringQuery`) backed by the
  snapshot — resolve a spoken "Groceries"/"the taxes task" to an id, with Siri
  disambiguation.
- **Widget buttons (iOS 17):** Start-Next tile gets Done (queues a hands-free
  completion + `AppGroup.optimisticComplete` advances the tile at once) and Start
  (opens Focus). Widget intents live in `Widgets/` (App-Group only).
  `StartNextSnapshot` gained `taskId` (optional, backward-compatible).
- **Tests:** `TZ=UTC swift test` → **378/0** (new `UnstuckSharedTests`: route +
  snapshot + write-queue + optimistic-complete). `UnstuckAppTests` 53/0. App +
  widget sim build green. Pushed to `main` (Phases 1–4: 268aa5f, d2d242a,
  cc4bdb2, a72bb7c).
- **Shipped to TestFlight:** **1.0.3 (19)** archived + uploaded via the scripted
  pipeline (altool UPLOAD SUCCEEDED, delivery 26b84df4…) for real-device Siri
  validation. Recipe: rebuild a signing keychain from `build/signing/dist.{key,cer}`
  (import separately; `set-key-partition-list`; add to search list) → `xcodebuild
  archive` with `-allowProvisioningUpdates` + the ASC key (D9Z2MUP6J9) for
  automatic profiles → `-exportArchive` with `build/signing/ExportOptions-manual.plist`
  (MANUAL signing + installed store profiles — the App-Manager ASC key CAN'T cloud-sign)
  → `altool --upload-app`. App Store 1.0.2 (18) remains in review separately.
- **Real-Siri testing (device):** install the TestFlight build, then "Hey Siri,
  how many tasks do I have left in UnstuckNow / what's next / add a task / start a
  focus session / ask Unstuck …"; verify the widget Done/Start buttons. App
  Shortcuts register on first launch; phrases say "UnstuckNow".

## Where things stand (2026-06-12, latest) — App Store 1.0 submission prepped

- Build **1.0 (4)** uploaded + attached to the App Store version record;
  metadata written via the ASC API (description, subtitle, keywords, promo,
  URLs, privacy policy, Productivity category, review details + demo login);
  **4 screenshots** (Today/Focus/Calendar/Collections, 1320×2868) generated by
  the StoreScreenshots UITest on an iPhone 17 Pro Max sim and uploaded
  (display type APP_IPHONE_67 — the API rejects _69).
- TestFlight: 0.1.0 builds 1+2 expired; build 3 in beta review (external).
- Remaining (Ahmad, in ASC UI): App Privacy questionnaire, age rating,
  pricing, the final "Add for Review" click.
- Known nit: Settings shows a hardcoded "Version 0.1.0" — read it from
  Info.plist before the next build.

## Where things stand (2026-06-12, later) — remaining parity gaps closed (build 3)

- **Recap card NOW RENDERS** — `AppModel.RecapState` set in `finishFocus`,
  coral "Just now / You did the thing." card on Today between the notif
  banner and the hero, 6h window, ✕ dismisses (Android TodayScreen parity).
- **Voice proxy configured** — `VOICE_PROXY_URL` set in `Secrets.xcconfig`
  (same CF Worker as Android: `wss://unstuck-voice-proxy.justtesting6363.workers.dev`,
  written with the `$()` xcconfig comment-escape). Talk button should now be
  un-gated; on-device audio validation still pending (needs a real device).
- **Accent + Density + Larger type implemented** (the functional Android
  controls; high-contrast/keyboard-hints/chime/bell/completion stay omitted —
  dead on Android too): `Accent` enum + `Palette.withAccent` in UnstuckDesign
  (oklch values copied from Android Theme.kt), applied via
  `unstuckTheme(accent:)`; density (compact/regular/comfy) + largerType fold
  into a DynamicTypeSize step shift (`TypeScale` in UnstuckApp.swift) — all
  app fonts are `Font.custom`, which scales with it. New Settings rows:
  Interface → Accent + Density, Accessibility → Larger type.
- swift test 263/0; sim build green. CFBundleVersion 3.

## Where things stand (2026-06-12) — TestFlight LIVE + captures-in-editor parity fix

- **TestFlight is live** under Ahmad's own team `M9ULD6M5Z3`: app record
  "UnstuckNow" (`io.unstucknow.app`), build 0.1.0 (1) uploaded + in Beta App
  Review for the external group; internal testing active. Upload recipe in
  `HANDOFF-TESTFLIGHT.md` (use the signed-in Xcode session, NOT the ASC API
  key — App Manager keys can't mint the cloud distribution cert).
- **Tester-reported parity gap FIXED — captures outside Focus.** Android's
  TaskDetailSheet has a "Captures" section (list + promote/discard +
  AddCaptureRow) and NewTaskSheet has capture-a-thought drafts; the iOS
  TaskEditor had NEITHER, so captures looked "missing" to testers who never
  ran a focus session. Added: `Captures` section on the edit form (live GRDB
  observation filtered to the task), capture drafts on the new-task form
  (saved against the task on Save), shared `CaptureTagPicker` chips
  (App/Features/CaptureTagPicker.swift), and the Focus capture sheet now has
  the five-tag row instead of silently saving everything as `idea`
  (Android CaptureSheet parity). Build 0.1.0 (2).

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
TZ=UTC swift test --scratch-path .build-int  # 1038 tests green, 2 skipped (2026-09-17, Today/home + interview-in-thread)
xcodegen generate && xcodebuild -project Unstuck.xcodeproj -scheme Unstuck \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO   # app + widget
# App-layer unit tests (host: Unstuck) — 575 tests, 569 green + the pre-existing CallsOutcomeReporterTests race (2026-09-17, Today/home + interview-in-thread), on a FRESH container (uninstall first, see above):
xcodebuild test -project Unstuck.xcodeproj -scheme Unstuck \
  -destination 'platform=iOS Simulator,id=38CF1937-7E51-4CDC-B96D-97928A2D1DF3' -only-testing:UnstuckAppTests
```
